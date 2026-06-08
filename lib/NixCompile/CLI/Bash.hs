{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module NixCompile.CLI.Bash (
  checkBashFile,
  checkNixFile,
  parseNixFiles,
  analyzeNixScripts,
  reportNixResults,
  checkScript,
  safeReadFile,
)
where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Exit (exitFailure, exitSuccess)

import NixCompile.Bash.Facts (extractFacts)
import NixCompile.Bash.Parse (parseBash)
import NixCompile.CLI.Check
import NixCompile.CLI.Report
import NixCompile.CLI.Types
import NixCompile.Config qualified as Config
import NixCompile.Infer.Constraint (factsToConstraints)
import NixCompile.Infer.Unify (solve)
import NixCompile.Lint.Forbidden (findViolations, violationDiagnostic)
import NixCompile.Log
import NixCompile.Nix.Parse qualified as Nix
import NixCompile.Schema.Build (validateConfigPaths)
import NixCompile.Types (Fact (BareCommand, DynamicCommand))

checkBashFile :: Config.Config -> FilePath -> AppM ()
checkBashFile config file = do
  src <- liftIO $ safeReadFile file
  case src of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "I/O error: " <> err
      liftIO exitFailure
    Right sourceText -> case parseBash sourceText of
      Left err -> do
        $(logTM) ErrorS $ logStr $ "Parse error: " <> err
        liftIO exitFailure
      Right ast -> do
        let allViolations = findViolations ast
        let (_suppressed, violations) = partitionViolations config allViolations
        unless (null violations) $
          mapM_ (emitDiagnostic . attachSnippet sourceText . violationDiagnostic) violations

        let facts = extractFacts ast :: [Fact]
        case validateConfigPaths facts of
          Left err -> do
            $(logTM) ErrorS $ logStr $ "Config error: " <> err
            liftIO exitFailure
          Right () -> pure ()
        let constraints = factsToConstraints facts
        case solve constraints of
          Left err -> do
            $(logTM) ErrorS $ logStr $ "Type error: " <> T.pack (show err)
            liftIO exitFailure
          Right _ -> pure ()

        let bareFacts = [(cmd, sourceSpan) | BareCommand cmd sourceSpan <- facts]
        let dynFacts = [(var, sourceSpan) | DynamicCommand var sourceSpan <- facts]
        let bareCount = length bareFacts
        let dynCount = length dynFacts
        let violationCount = length violations

        mapM_ (emitDiagnostic . attachSnippet sourceText . bareDiagnostic) bareFacts
        mapM_ (emitDiagnostic . attachSnippet sourceText . dynamicDiagnostic) dynFacts

        printCheckResult file (violationCount + bareCount + dynCount)

checkNixFile :: Config.Config -> FilePath -> AppM ()
checkNixFile config file = do
  nixResult <- checkFile config file
  scripts <- parseNixFiles file
  bashErrors <- analyzeNixScripts config file scripts
  let totalErrors = (case nixResult of TCFail -> 1; _ -> 0) + bashErrors
  reportNixResults file totalErrors

parseNixFiles :: FilePath -> AppM [Nix.BashScript]
parseNixFiles file = do
  result <- liftIO $ Nix.extractBashScripts file
  case result of
    -- The caller (checkNixFile / the CI type-check phase) has already parsed
    -- and reported this file; a parse failure here would only re-report it
    -- (with a doubled "Parse error: parse error:" prefix) and abort. Just
    -- yield no embedded scripts and let the earlier failure stand.
    Left _ -> pure []
    Right scripts -> do
      $(logTM) DebugS $ logStr $ T.pack $ "Found " ++ show (length scripts) ++ " shell scripts in " ++ file
      pure scripts

analyzeNixScripts :: Config.Config -> FilePath -> [Nix.BashScript] -> AppM Int
analyzeNixScripts config file scripts =
  sum <$> mapM (checkScript config file) scripts

-- A single-file check is silent on success and emits only the diagnostics (plus
-- exit code) on failure — the directory check prints the "checked N files" summary.
reportNixResults :: FilePath -> Int -> AppM ()
reportNixResults _file totalErrors
  | totalErrors > 0 = liftIO exitFailure
  | otherwise = liftIO exitSuccess

checkScript :: Config.Config -> FilePath -> Nix.BashScript -> AppM Int
checkScript configuration _file bs = do
  $(logTM) DebugS $ logStr $ "\n=== " <> Nix.bsName bs <> " ==="
  case parseBash (Nix.bsContent bs) of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "  Parse error: " <> err
      return 1
    Right ast -> do
      let allViolations = findViolations ast
      let (_, violations) = partitionViolations configuration allViolations
      unless (null violations) $
        mapM_ (emitDiagnostic . attachSnippet (Nix.bsContent bs) . violationDiagnostic) violations

      let badInterps = filter (not . Nix.intIsStorePath) (Nix.bsInterpolations bs)
      unless (null badInterps) $
        $(logTM) WarningS $
          logStr $
            "  Non-store-path interpolations (may need verification):\n"
              <> T.concat ["    ${" <> Nix.intExpr i <> "}\n" | i <- badInterps]

      let facts = extractFacts ast :: [Fact]
      configErrors <- case validateConfigPaths facts of
        Left err -> do
          $(logTM) ErrorS $ logStr $ "  Config error: " <> err
          return 1
        Right () -> pure 0
      let constraints = factsToConstraints facts
      typeErrors <- case solve constraints of
        Left err -> do
          $(logTM) ErrorS $ logStr $ "  Type error: " <> T.pack (show err)
          return 1
        Right _ -> pure 0

      let bareFacts = [(cmd, sourceSpan) | BareCommand cmd sourceSpan <- facts]
      let dynFacts = [(var, sourceSpan) | DynamicCommand var sourceSpan <- facts]
      let bareCount = length bareFacts
      let dynCount = length dynFacts

      mapM_ (emitDiagnostic . attachSnippet (Nix.bsContent bs) . bareDiagnostic) bareFacts
      mapM_ (emitDiagnostic . attachSnippet (Nix.bsContent bs) . dynamicDiagnostic) dynFacts

      let errorCount = length violations + bareCount + dynCount + typeErrors + configErrors
      return errorCount

safeReadFile :: FilePath -> IO (Either Text Text)
safeReadFile path = do
  result <- try (TIO.readFile path)
  case result of
    Left (e :: IOException) -> pure (Left (T.pack (show e)))
    Right sourceText -> pure (Right sourceText)
