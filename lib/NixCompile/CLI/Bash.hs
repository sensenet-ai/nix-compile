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
import NixCompile.Bash.Types (Fact (BareCommand, DynamicCommand))
import NixCompile.CLI.Check
import NixCompile.CLI.Report
import NixCompile.CLI.Types
import NixCompile.Core.Config qualified as Config
import NixCompile.Core.Draw qualified as Draw
import NixCompile.Core.Log
import NixCompile.Inference.Bash.Constraint (factsToConstraints)
import NixCompile.Inference.Bash.Schema (validateConfigPaths)
import NixCompile.Inference.Bash.Unify (solve)
import NixCompile.Lint.Forbidden (findViolations, violationDiagnostic)
import NixCompile.Syntax.Parse qualified as Nix

checkBashFile :: Config.Config -> FilePath -> AppM ()
checkBashFile config file = do
  src <- liftIO $ safeReadFile file
  either (abort . ("I/O error: " <>)) onSource src
 where
  abort :: Text -> AppM a
  abort msg = do
    $(logTM) ErrorS $ logStr msg
    liftIO exitFailure

  onSource sourceText =
    either (abort . ("Parse error: " <>)) (onAST sourceText) (parseBash sourceText)

  onAST sourceText ast = do
    let allViolations = findViolations ast
    let (_suppressed, violations) = partitionViolations config allViolations
    unless (null violations) $
      mapM_ (emitDiagnostic . attachSnippet sourceText . violationDiagnostic) violations

    let facts = extractFacts ast :: [Fact]
    either (abort . ("Config error: " <>)) pure (validateConfigPaths facts)
    let constraints = factsToConstraints facts
    either (abort . typeErrorMsg) (const (pure ())) (solve constraints)

    let bareFacts = [(cmd, sourceSpan) | BareCommand cmd sourceSpan <- facts]
    let dynFacts = [(var, sourceSpan) | DynamicCommand var sourceSpan <- facts]
    let bareCount = length bareFacts
    let dynCount = length dynFacts
    let violationCount = length violations

    mapM_ (emitDiagnostic . attachSnippet sourceText . bareDiagnostic) bareFacts
    mapM_ (emitDiagnostic . attachSnippet sourceText . dynamicDiagnostic) dynFacts

    printCheckResult file (violationCount + bareCount + dynCount)

  typeErrorMsg err = "Type error: " <> T.pack (show err)

checkNixFile :: Config.Config -> FilePath -> AppM ()
checkNixFile config file = do
  nixResult <- checkFile config file
  scripts <- parseNixFiles file
  bashErrors <- analyzeNixScripts config file scripts
  reportNixResults file (tcFailCount nixResult + bashErrors)
 where
  tcFailCount TCFail = 1
  tcFailCount _ = 0

parseNixFiles :: FilePath -> AppM [Nix.BashScript]
parseNixFiles file = do
  result <- liftIO $ Nix.extractBashScripts file
  -- The caller (checkNixFile / the CI type-check phase) has already parsed and
  -- reported this file; a parse failure here would only re-report it (with a
  -- doubled "Parse error: parse error:" prefix) and abort. On Left, just yield
  -- no embedded scripts and let the earlier failure stand.
  either (const (pure [])) onScripts result
 where
  onScripts scripts = do
    $(logTM) DebugS $
      logStr $
        T.pack $
          "Found " ++ show (length scripts) ++ " shell scripts in " ++ file
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
  $(logTM) DebugS $ logStr $ "\n" <> Draw.framed Draw.Double (Nix.bsName bs)
  either onParseError onAST (parseBash (Nix.bsContent bs))
 where
  onParseError err = do
    $(logTM) ErrorS $ logStr $ "  Parse error: " <> err
    return 1

  -- log an error at the given prefix and count it as one error
  countedError prefix err = do
    $(logTM) ErrorS $ logStr $ prefix <> err
    return (1 :: Int)

  onAST ast = do
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
    configErrors <-
      either (countedError "  Config error: ") (const (pure 0)) (validateConfigPaths facts)
    let constraints = factsToConstraints facts
    typeErrors <-
      either (countedError "  Type error: " . T.pack . show) (const (pure 0)) (solve constraints)

    let bareFacts = [(cmd, sourceSpan) | BareCommand cmd sourceSpan <- facts]
    let dynFacts = [(var, sourceSpan) | DynamicCommand var sourceSpan <- facts]
    let bareCount = length bareFacts
    let dynCount = length dynFacts

    mapM_ (emitDiagnostic . attachSnippet (Nix.bsContent bs) . bareDiagnostic) bareFacts
    mapM_ (emitDiagnostic . attachSnippet (Nix.bsContent bs) . dynamicDiagnostic) dynFacts

    return (length violations + bareCount + dynCount + typeErrors + configErrors)

safeReadFile :: FilePath -> IO (Either Text Text)
safeReadFile path = do
  result <- try (TIO.readFile path) :: IO (Either IOException Text)
  pure (either (Left . T.pack . show) Right result)
