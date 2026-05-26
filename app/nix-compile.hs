{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- nix-compile - CLI for compile-time Nix type inference
--
-- Usage:
--   nix-compile parse <script>       Parse and show facts
--   nix-compile infer <script>       Infer types and show schema
--   nix-compile check <script>       Check for policy violations
--   nix-compile lint <script>        Check for forbidden constructs
--   nix-compile emit <script>       Generate emit-config bash function
--   nix-compile nix <file.nix>       Check embedded bash in Nix files
module Main (main) where

-- hnix imports for detectUnsupported function

import Control.Applicative ((<|>))
import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.QSemN (newQSemN, signalQSemN, waitQSemN)
import Control.Exception (IOException, SomeException, bracket_, try)
import Control.Monad (foldM, forM_, unless)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Fix (Fix (..))
import Data.Functor.Compose (Compose (..))
import Data.List (isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nix.Expr.Types
import Nix.Expr.Types.Annotated (AnnUnit (..), NExprLoc)
import NixCompile hiding (Severity)
import NixCompile.Bash.Facts (extractFacts)
import NixCompile.Bash.Parse (parseBash)
import NixCompile.Config qualified as Config
import NixCompile.Emit.Config (emitConfigFunction)
import NixCompile.Infer.Constraint (factsToConstraints)
import NixCompile.Infer.Unify (solve)
import NixCompile.Lint.Forbidden (Violation (..), findViolations, formatViolationsAt)
import NixCompile.Log
import NixCompile.Nix.Flake qualified as Flake
import NixCompile.Nix.Format qualified as NixFmt
import NixCompile.Nix.Infer qualified
import NixCompile.Nix.Layout qualified as Layout
import NixCompile.Nix.Lint qualified as Lint
import NixCompile.Nix.LintDerivation qualified as Derivation
import NixCompile.Nix.LintPackages qualified as LintPackages
import NixCompile.Nix.LintPatterns qualified as LintPatterns
import NixCompile.Nix.Module qualified as Mod
import NixCompile.Nix.Parse qualified as Nix
import NixCompile.Nix.Scope qualified as Scope
import NixCompile.Nix.Types qualified
import NixCompile.Schema.Build (validateConfigPaths)
import System.Directory (canonicalizePath, doesDirectoryExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (makeRelative, takeDirectory, takeExtension, (</>))

data TCResult = TCOk | TCFail | TCSkip
  deriving (Eq, Show)

main :: IO ()
main = runLog InfoS $ do
  args <- liftIO getArgs
  let (mConfigPath, restArgs) = parseConfigArg args
  config <- case mConfigPath of
    Just path -> either (const Config.defaultConfig) id <$> liftIO (Config.loadConfig path)
    Nothing -> pure Config.defaultConfig
  $(logTM) InfoS $
    logStr $
      "Config: profile="
        <> Config.configProfile config
        <> " overrides="
        <> T.pack (show (length (Config.configOverrides config)))
        <> " ignores="
        <> T.pack (show (length (Config.configExtraIgnores config)))
  case restArgs of
    ["lint", file] -> cmdLint config file
    ["check", file] -> cmdCheck config file
    ["infer", file] -> cmdInfer file
    ["parse", file] -> cmdParse file
    ["emit", file] -> cmdEmit file
    ["nix", file] -> cmdNix config file
    ["fmt", file] -> cmdFmt file
    ["typecheck", path] -> cmdTypeCheck config path
    ["flake"] -> cmdFlake "."
    ["flake", dir] -> cmdFlake dir
    ["graph"] -> cmdGraph config "." False
    ["graph", dir] -> cmdGraph config dir False
    ["graph", "--dot"] -> cmdGraph config "." True
    ["graph", "--dot", dir] -> cmdGraph config dir True
    ["graph", dir, "--dot"] -> cmdGraph config dir True
    ["scope", file] -> cmdScope file
    ["scope", "--json", file] -> cmdScopeJSON file
    ["scope", "--dhall", file] -> cmdScopeDhall file
    ["--help"] -> liftIO usage
    ["-h"] -> liftIO usage
    [] -> liftIO usage
    _ -> do
      $(logTM) ErrorS $ logStr $ T.pack $ "Unknown command: " ++ unwords restArgs
      liftIO usage
      liftIO exitFailure

parseConfigArg :: [String] -> (Maybe FilePath, [String])
parseConfigArg ("--config" : path : rest) = (Just path, rest)
parseConfigArg args = (Nothing, args)

usage :: IO ()
usage = do
  putStrLn "nix-compile - compile-time type checker for Nix expressions"
  putStrLn ""
  putStrLn "Usage:"
  putStrLn "  nix-compile lint <script.sh>    Check for forbidden constructs (heredocs, eval, etc)"
  putStrLn "  nix-compile check <script.sh>   Full check (lint + policy + types)"
  putStrLn "  nix-compile infer <script.sh>   Infer types and show schema (JSON)"
  putStrLn "  nix-compile parse <script.sh>   Parse and show extracted facts"
  putStrLn "  nix-compile emit <script.sh>    Generate emit-config bash function (use: emit-config <json|yaml|toml>)"
  putStrLn "  nix-compile nix <file.nix>      Check embedded bash in Nix files"
  putStrLn "  nix-compile fmt <file.nix>      Add type annotations to Nix file"
  putStrLn "  nix-compile typecheck <path>    Recursively infer and check types for all Nix files"
  putStrLn "  nix-compile flake [dir]         Analyze a flake"
  putStrLn "  nix-compile graph [--dot] [dir] Show module dependency graph (exits 1 on violations)"
  putStrLn "  nix-compile scope <file.nix>    Show scope graph (declarations, references, edges)"
  putStrLn "  nix-compile scope --json <file> Emit scope graph as JSON (for zeitschrift)"
  putStrLn "  nix-compile scope --dhall <file> Emit scope graph as Dhall (for zeitschrift)"
  putStrLn ""
  putStrLn "Bash policy checks (enforced by `check` and `nix`; no escape hatch):"
  putStrLn "  - heredocs (<<, <<-)"
  putStrLn "  - here-strings (<<<)"
  putStrLn "  - eval"
  putStrLn "  - backticks (`cmd`)"
  putStrLn "  - bare commands (external commands must use store paths; shell builtins allowed)"
  putStrLn "  - dynamic commands ($cmd)"
  putStrLn ""
  putStrLn "Forbidden Nix constructs (no escape hatch):"
  putStrLn "  - with expr;  (obscures scope, breaks tooling)"
  putStrLn "  - rec { }     (enables non-termination, breaks analysis)"
  putStrLn "  - \"str\".attr  (breaks hnix parser)"
  putStrLn ""
  putStrLn "Examples:"
  putStrLn "  nix-compile lint ./deploy.sh"
  putStrLn "  nix-compile check ./scripts/*.sh"
  putStrLn "  nix-compile infer ./deploy.sh | jq '.env'"
  putStrLn "  nix-compile nix ./default.nix"

partitionViolations :: Config.Config -> [Violation] -> ([Violation], [Violation])
partitionViolations config = foldr go ([], [])
  where
    go v (suppressed, active)
      | Config.isSuppressed config (Config.bashRuleId (vType v)) = (v : suppressed, active)
      | otherwise = (suppressed, v : active)

partitionNixViolations :: Config.Config -> [Lint.NixViolation] -> ([Lint.NixViolation], [Lint.NixViolation])
partitionNixViolations config = foldr go ([], [])
  where
    go v (suppressed, active)
      | Config.isSuppressed config (Config.nixRuleId (Lint.nvType v)) = (v : suppressed, active)
      | otherwise = (suppressed, v : active)

partitionDerivViolations :: Config.Config -> [Derivation.DerivViolation] -> ([Derivation.DerivViolation], [Derivation.DerivViolation])
partitionDerivViolations config = foldr go ([], [])
  where
    go v (suppressed, active)
      | Config.isSuppressed config (Config.derivRuleId (Derivation.dvType v)) = (v : suppressed, active)
      | otherwise = (suppressed, v : active)

partitionPackageViolations :: Config.Config -> [LintPackages.PackageViolation] -> ([LintPackages.PackageViolation], [LintPackages.PackageViolation])
partitionPackageViolations config = foldr go ([], [])
  where
    go v (suppressed, active)
      | Config.isSuppressed config (Config.packageRuleId (LintPackages.pvCode v)) = (v : suppressed, active)
      | otherwise = (suppressed, v : active)

partitionPatternViolations :: Config.Config -> [LintPatterns.PatternViolation] -> ([LintPatterns.PatternViolation], [LintPatterns.PatternViolation])
partitionPatternViolations config = foldr go ([], [])
  where
    go v (suppressed, active)
      | Config.isSuppressed config (Config.patternRuleId (LintPatterns.pvType v)) = (v : suppressed, active)
      | otherwise = (suppressed, v : active)

-- ============================================================================
-- Pretty-printing for bash policy violations
-- ============================================================================

formatBareCommand :: T.Text -> (T.Text, Span) -> T.Text
formatBareCommand src (cmd, sp) =
  let tok = locLine (spanStart sp)
   in T.unlines
        [ "error[ALEPH-B005]: bare command not allowed: " <> cmd,
          "  --> " <> src <> ":" <> T.pack (show tok),
          "",
          "  Use an explicit store path for external commands:",
          "    /nix/store/...-pkg/bin/" <> cmd
        ]

formatDynamicCommand :: T.Text -> (T.Text, Span) -> T.Text
formatDynamicCommand src (var, sp) =
  let tok = locLine (spanStart sp)
   in T.unlines
        [ "error[ALEPH-B006]: dynamic command not allowed: $" <> var,
          "  --> " <> src <> ":" <> T.pack (show tok),
          "",
          "  Dynamic command selection is not statically analyzable.",
          "  Use a known store path or a case statement over a small allowlist."
        ]

-- | Indent every line of a multi-line block.
indentBlock :: T.Text -> T.Text -> T.Text
indentBlock prefix block =
  T.unlines [prefix <> line | line <- T.lines block]

cmdParse :: FilePath -> AppM ()
cmdParse file = do
  result <- liftIO $ parseScriptFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right script -> do
      liftIO $ putStrLn "Facts:"
      liftIO $ mapM_ print (scriptFacts script)

cmdInfer :: FilePath -> AppM ()
cmdInfer file = do
  result <- liftIO $ parseScriptFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right script -> do
      liftIO $ BL.putStrLn (encode (scriptSchema script))

-- | Safe file read that catches encoding errors
safeReadFile :: FilePath -> IO (Either T.Text T.Text)
safeReadFile path = do
  result <- try (TIO.readFile path)
  case result of
    Left (e :: IOException) -> pure (Left (T.pack (show e)))
    Right txt -> pure (Right txt)

suppressedSuffix :: [Violation] -> T.Text
suppressedSuffix [] = ""
suppressedSuffix ss = " (" <> T.pack (show (length ss)) <> " suppressed)"

-- | Lint for forbidden constructs only (heredocs, eval, backticks)
cmdLint :: Config.Config -> FilePath -> AppM ()
cmdLint config file = do
  src <- liftIO $ safeReadFile file
  case src of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "I/O error: " <> err
      liftIO exitFailure
    Right txt -> case parseBash txt of
      Left err -> do
        $(logTM) ErrorS $ logStr $ "Parse error: " <> err
        liftIO exitFailure
      Right ast -> do
        let allViolations = findViolations ast
        let (suppressed, active) = partitionViolations config allViolations
        if null active
          then do
            $(logTM) InfoS $ logStr $ T.pack file <> ": OK" <> suppressedSuffix suppressed
            liftIO exitSuccess
          else do
            $(logTM) ErrorS $ logStr $ formatViolationsAt (T.pack file) active
            $(logTM) ErrorS $ logStr $ "\n" <> T.pack (show (length active)) <> " error(s) in " <> T.pack file <> suppressedSuffix suppressed
            liftIO exitFailure

-- | Full check: lint + bare commands + type inference
cmdCheck :: Config.Config -> FilePath -> AppM ()
cmdCheck config file = do
  src <- liftIO $ safeReadFile file
  case src of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "I/O error: " <> err
      liftIO exitFailure
    Right txt -> case parseBash txt of
      Left err -> do
        $(logTM) ErrorS $ logStr $ "Parse error: " <> err
        liftIO exitFailure
      Right ast -> do
        let allViolations = findViolations ast
        let (_suppressed, violations) = partitionViolations config allViolations
        unless (null violations) $ do
          $(logTM) ErrorS $ logStr $ formatViolationsAt (T.pack file) violations
          liftIO $ putStrLn ""

        -- Then do type inference and check policy violations
        let facts = extractFacts ast
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

        let bareFacts = [(cmd, sp) | BareCommand cmd sp <- facts]
        let dynFacts = [(var, sp) | DynamicCommand var sp <- facts]
        let bareCount = length bareFacts
        let dynCount = length dynFacts
        let violationCount = length violations

        -- Report bare commands
        unless (null bareFacts) $ do
          liftIO $ TIO.putStrLn ""
          liftIO $ TIO.putStrLn "Bare commands (external commands must use store paths; shell builtins allowed):"
          liftIO $ mapM_ (TIO.putStr . formatBareCommand (T.pack file)) bareFacts

        -- Report dynamic commands
        unless (null dynFacts) $ do
          liftIO $ TIO.putStrLn ""
          liftIO $ TIO.putStrLn "Dynamic commands (cannot analyze):"
          liftIO $ mapM_ (TIO.putStr . formatDynamicCommand (T.pack file)) dynFacts

        let totalErrors = violationCount + bareCount + dynCount
        if totalErrors > 0
          then do
            $(logTM) ErrorS $ logStr $ T.pack $ "\n" ++ show totalErrors ++ " error(s) in " ++ file
            liftIO exitFailure
          else do
            $(logTM) InfoS $ logStr $ T.pack $ file ++ ": OK"
            liftIO exitSuccess

cmdEmit :: FilePath -> AppM ()
cmdEmit file = do
  result <- liftIO $ parseScriptFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right script -> do
      liftIO $ TIO.putStr $ emitConfigFunction (scriptSchema script)

-- | Check embedded bash scripts in Nix files
cmdNix :: Config.Config -> FilePath -> AppM ()
cmdNix config file = do
  result <- liftIO $ Nix.extractBashScripts file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right scripts -> do
      $(logTM) InfoS $ logStr $ T.pack $ "Found " ++ show (length scripts) ++ " shell scripts in " ++ file
      totalErrors <- sum <$> mapM (checkScript config) scripts
      if totalErrors > 0
        then do
          $(logTM) ErrorS $ logStr $ T.pack $ "\n" ++ show totalErrors ++ " total error(s)"
          liftIO exitFailure
        else do
          $(logTM) InfoS $ logStr $ T.pack $ file ++ ": OK"
          liftIO exitSuccess
  where
    checkScript :: Config.Config -> Nix.BashScript -> AppM Int
    checkScript cfg bs = do
      $(logTM) InfoS $ logStr $ "\n=== " <> Nix.bsName bs <> " ==="
      -- Parse and check the bash content
      case parseBash (Nix.bsContent bs) of
        Left err -> do
          $(logTM) ErrorS $ logStr $ "  Parse error: " <> err
          return 1
        Right ast -> do
          -- Check for forbidden constructs (filter suppressed)
          let allViolations = findViolations ast
          let (_, violations) = partitionViolations cfg allViolations
          unless (null violations) $ do
            let srcLabel = T.pack file <> ":" <> Nix.bsName bs
            $(logTM) ErrorS $ logStr $ formatViolationsAt srcLabel violations

          -- Check for non-store-path interpolations
          let badInterps = filter (not . Nix.intIsStorePath) (Nix.bsInterpolations bs)
          unless (null badInterps) $ do
            $(logTM) WarningS $ logStr "  Non-store-path interpolations (may need verification):"
            liftIO $ mapM_ (\i -> putStrLn $ "    ${" ++ T.unpack (Nix.intExpr i) ++ "}") badInterps

          -- Type inference and policy checks
          let facts = extractFacts ast
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

          let bareFacts = [(cmd, sp) | BareCommand cmd sp <- facts]
          let dynFacts = [(var, sp) | DynamicCommand var sp <- facts]
          let bareCount = length bareFacts
          let dynCount = length dynFacts

          unless (null bareFacts) $ do
            $(logTM) ErrorS $ logStr "  Bare commands (external commands must use store paths; shell builtins allowed):"
            let srcLabel = T.pack file <> ":" <> Nix.bsName bs
            liftIO $ mapM_ (TIO.putStr . indentBlock "  " . formatBareCommand srcLabel) bareFacts

          unless (null dynFacts) $ do
            $(logTM) ErrorS $ logStr "  Dynamic commands (cannot analyze):"
            let srcLabel = T.pack file <> ":" <> Nix.bsName bs
            liftIO $ mapM_ (TIO.putStr . indentBlock "  " . formatDynamicCommand srcLabel) dynFacts

          let errorCount = length violations + bareCount + dynCount + typeErrors + configErrors
          if errorCount == 0
            then $(logTM) InfoS "  OK"
            else $(logTM) ErrorS $ logStr $ T.pack $ "  " ++ show errorCount ++ " error(s)"
          return errorCount

-- | Recursively type check a directory or single file in parallel
cmdTypeCheck :: Config.Config -> FilePath -> AppM ()
cmdTypeCheck config path = do
  isDir <- liftIO $ doesDirectoryExist path
  files <-
    if isDir
      then liftIO $ findAllNixFiles config path
      else do
        let f = path
        if Config.isIgnored config f
          then return []
          else return [f]

  $(logTM) InfoS $
    logStr $
      T.unlines
        [ "",
          "================================================================",
          "  nix-compile typecheck",
          "  " <> T.pack (show (length files) <> " files"),
          "================================================================",
          ""
        ]

  -- We don't use MVar for logging anymore, we use Katip
  -- But we need to pass the logging environment to the threads
  env <- getLogEnv
  ctx <- getKatipContext
  ns <- getKatipNamespace

  -- Bound parallelism to avoid exhausting file descriptors on large repos
  let maxConcurrency = 16 :: Int
  sem <- liftIO $ newQSemN maxConcurrency
  results <- liftIO $ forConcurrently files $ \file ->
    bracket_ (waitQSemN sem 1) (signalQSemN sem 1) $
      checkFileWrapper (env, ctx, ns) file
  let okCount = length [() | r <- results, r == TCOk]
  let skipCount = length [() | r <- results, r == TCSkip]
  let failCount = length [() | r <- results, r == TCFail]

  pViolations <- liftIO $ LintPackages.checkPackageDirs files
  let (_, activePkg) = partitionPackageViolations config pViolations
  let pkgCount = length activePkg

  unless (null activePkg) $ do
    $(logTM) ErrorS $
      logStr $
        T.unlines
          [ "",
            "================================================================",
            "  Package Directories Missing default.nix",
            ""
          ]
    $(logTM) ErrorS $ logStr $ formatPackageViolations activePkg

  $(logTM) InfoS $
    logStr $
      T.unlines
        [ "",
          "================================================================",
          "  Summary",
          "  " <> T.pack (show okCount <> " passed"),
          "  " <> T.pack (show skipCount <> " skipped (unsupported constructs)"),
          "  " <> T.pack (show failCount <> " failed"),
          "  " <> T.pack (show pkgCount <> " package directory violations"),
          "================================================================",
          ""
        ]

  if failCount == 0 && null activePkg
    then liftIO exitSuccess
    else liftIO exitFailure
  where
    findAllNixFiles :: Config.Config -> FilePath -> IO [FilePath]
    findAllNixFiles cfg root = do
      canonRoot <- canonicalizePath root
      let go found _ [] = return found
          go found visited (d : worklist) = do
            canon <- canonicalizePath d
            if canon `Set.member` visited
              then go found visited worklist
              else
                if not (canonRoot `isPrefixOf` canon)
                  then go found visited worklist
                  else do
                    let relD = makeRelative canonRoot canon
                    if Config.isIgnored cfg relD
                      then go found (Set.insert canon visited) worklist
                      else do
                        entries <- listDirectory d
                        (nixFiles, subdirs) <-
                          foldM
                            ( \(fs, ds) entry -> do
                                let fullPath = d </> entry
                                if entry `elem` [".git", ".direnv", "node_modules", ".cache", ".lake", "result", "result-lib", "target"]
                                  then return (fs, ds)
                                  else do
                                    isD <- doesDirectoryExist fullPath
                                    if isD
                                      then return (fs, fullPath : ds)
                                      else return (if takeExtension fullPath == ".nix" then fullPath : fs else fs, ds)
                            )
                            ([], [])
                            entries
                        go (nixFiles ++ found) (Set.insert canon visited) (subdirs ++ worklist)
      allFiles <- go [] Set.empty [root]
      return $ filter (not . Config.isIgnored cfg . makeRelative canonRoot) allFiles

    checkFileWrapper :: (LogEnv, LogContexts, Namespace) -> FilePath -> IO TCResult
    checkFileWrapper (le, ctx, ns) file = runKatipContextT le ctx ns (checkFile file)

    checkFile :: FilePath -> AppM TCResult
    checkFile file = do
      -- First check if file uses unsupported constructs
      parseRes <- liftIO $ Nix.parseNixFile file
      case parseRes of
        Left err -> do
          $(logTM) ErrorS $
            logStr $
              T.unlines
                [ "",
                  "━━━ " <> cross <> " " <> T.pack file <> " ━━━",
                  "",
                  "  PARSE ERROR: " <> err,
                  ""
                ]
          return TCFail
        Right expr ->
          case detectUnsupported expr of
            Just reason -> do
              -- Skip files with unsupported constructs
              $(logTM) InfoS $ logStr $ skip <> " " <> T.pack file <> " (unsupported: " <> reason <> ")"
              return TCSkip
            Nothing -> do
              -- Check for Nix lint violations (with, rec)
              let nixViolations = Lint.findNixViolations expr
              let (_, nixActive) = partitionNixViolations config nixViolations
              unless (null nixActive) $ do
                $(logTM) ErrorS $
                  logStr $
                    T.unlines
                      [ "",
                        "━━━ " <> cross <> " " <> T.pack file <> " ━━━",
                        "",
                        "  NIX LINT VIOLATIONS:",
                        ""
                      ]
                $(logTM) ErrorS $ logStr $ Lint.formatNixViolations nixActive

              -- Check for derivation quality violations (missing-meta, missing-description)
              let derivViolations = Derivation.findDerivViolations file expr
              let (_, derivActive) = partitionDerivViolations config derivViolations
              unless (null derivActive) $ do
                $(logTM) WarningS $
                  logStr $
                    T.unlines
                      [ "",
                        "━━━ " <> cross <> " " <> T.pack file <> " ━━━",
                        "",
                        "  DERIVATION QUALITY VIOLATIONS:",
                        ""
                      ]
                $(logTM) WarningS $ logStr $ Derivation.formatDerivViolations derivActive
              -- Check for pattern violations (or-null-fallback, translateAttrs)
              let patternViolations = LintPatterns.findPatternViolations expr
              let (_, patternActive) = partitionPatternViolations config patternViolations
              unless (null patternActive) $ do
                $(logTM) WarningS $
                  logStr $
                    T.unlines
                      [ "",
                        "━━━ " <> cross <> " " <> T.pack file <> " ━━━",
                        "",
                        "  PATTERN VIOLATIONS:",
                        ""
                      ]
                $(logTM) WarningS $ logStr $ LintPatterns.formatPatternViolations patternActive
              -- Type check the file
              result <- liftIO $ try $ case NixCompile.Nix.Infer.inferExpr expr of
                Left err -> return $ Left err
                Right (t, _) -> return $ Right (NixCompile.Nix.Types.prettyType t)

              case result of
                Left (e :: SomeException) -> do
                  $(logTM) ErrorS $
                    logStr $
                      T.unlines
                        [ "",
                          "━━━ " <> cross <> " " <> T.pack file <> " ━━━",
                          "",
                          "  INTERNAL ERROR (this is a bug in nix-compile):",
                          "",
                          T.unlines $ map ("     " <>) $ T.lines $ T.pack $ show e
                        ]
                  return TCFail
                Right (Left err) -> do
                  $(logTM) ErrorS $
                    logStr $
                      T.unlines
                        [ "",
                          "━━━ " <> cross <> " " <> T.pack file <> " ━━━",
                          "",
                          formatError err,
                          ""
                        ]
                  return TCFail
                Right (Right _t) ->
                  if null nixActive && null derivActive && null patternActive
                    then do
                      $(logTM) InfoS $ logStr $ check <> " " <> T.pack file
                      return TCOk
                    else do
                      $(logTM) InfoS $ logStr $ cross <> " " <> T.pack file <> " (lint violations)"
                      return TCFail
      where
        check = "[OK]"
        cross = "[XX]"
        skip = "[SKIP]"

        formatError :: T.Text -> T.Text
        formatError err =
          let lines' = T.lines err
           in case lines' of
                (first : rest) -> T.unlines $ ("  ERROR: " <> first) : map ("         " <>) rest
                [] -> "  ERROR: unknown error"

        -- Detect unsupported constructs that are fundamentally incompatible with static analysis
        detectUnsupported :: NExprLoc -> Maybe T.Text
        detectUnsupported (Fix (Compose (AnnUnit _ expr))) = case expr of
          -- Dynamic attribute access
          NSelect _ _ (DynamicKey _ :| _) -> Just "dynamic attribute access"
          -- Dynamic imports (NImport removed in hnix 0.17.0)
          -- NImport path -> case path of
          --   Fix (Compose (AnnUnit _ (NStr _))) -> Just "dynamic import"
          --   _ -> Nothing
          -- Recursively check sub-expressions
          NAbs _ body -> detectUnsupported body
          NLet bindings body ->
            foldl (<|>) (detectUnsupported body) (map detectUnsupportedBinding bindings)
          NSet _ bindings ->
            foldl (<|>) Nothing (map detectUnsupportedBinding bindings)
          NList elems ->
            foldl (<|>) Nothing (map detectUnsupported elems)
          NBinary _ left right ->
            detectUnsupported left <|> detectUnsupported right
          NUnary _ arg -> detectUnsupported arg
          NSelect _ base _ -> detectUnsupported base
          NHasAttr base attrPath ->
            if hasDynamicKey attrPath
              then Just "dynamic attribute test"
              else detectUnsupported base
          NApp fun arg -> detectUnsupported fun <|> detectUnsupported arg
          NIf cond t f -> detectUnsupported cond <|> detectUnsupported t <|> detectUnsupported f
          NAssert cond body -> detectUnsupported cond <|> detectUnsupported body
          _ -> Nothing

        detectUnsupportedBinding :: Binding NExprLoc -> Maybe T.Text
        detectUnsupportedBinding binding = case binding of
          NamedVar _ expr _ -> detectUnsupported expr
          Inherit _ _ _ -> Nothing

        hasDynamicKey :: NAttrPath NExprLoc -> Bool
        hasDynamicKey = any isDynamicKey
          where
            isDynamicKey (DynamicKey _) = True
            isDynamicKey _ = False

formatPackageViolations :: [LintPackages.PackageViolation] -> T.Text
formatPackageViolations [] = ""
formatPackageViolations vs =
  T.unlines
    [ "ALEPH-P001: Package directories must contain a `default.nix` file:",
      ""
    ]
    <> T.unlines (map (\v -> "  " <> T.pack (LintPackages.pvPath v)) vs)

-- | Format a Nix file with type annotations
cmdFmt :: FilePath -> AppM ()
cmdFmt file = do
  result <- liftIO $ NixFmt.formatFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right formatted -> do
      liftIO $ TIO.putStr formatted

-- | Analyze a flake
cmdFlake :: FilePath -> AppM ()
cmdFlake dir = do
  result <- liftIO $ Flake.parseFlakeDir dir
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right flake -> do
      liftIO $ putStrLn "=== Flake ==="
      liftIO $ putStrLn $ "Path: " ++ Flake.flakePath flake
      liftIO $ TIO.putStrLn $ "Description: " <> maybe "(none)" id (Flake.flakeDescription flake)

      liftIO $ putStrLn "\n=== Inputs ==="
      liftIO $ mapM_ printInput (Map.toList $ Flake.flakeInputs flake)

      liftIO $ putStrLn "\n=== Inferred Type ==="
      let types = Flake.inferFlake flake
      liftIO $ TIO.putStrLn $ "outputs : " <> prettyType (Flake.ftOutputsType types)
  where
    printInput (name, input) = do
      TIO.putStr $ "  " <> name <> " : FlakeInput"
      case Flake.inputUrl input of
        Just url -> TIO.putStrLn $ " = \"" <> url <> "\""
        Nothing -> case Flake.inputFollows input of
          Just follows -> TIO.putStrLn $ " (follows " <> follows <> ")"
          Nothing -> putStrLn ""

    prettyType = NixCompile.Nix.Types.prettyType

-- | Show module dependency graph
cmdGraph :: Config.Config -> FilePath -> Bool -> AppM ()
cmdGraph config dir asDot = do
  result <- liftIO $ Mod.buildModuleGraphFromFlake dir
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right graph -> do
      let rootDir = takeDirectory (Mod.mgRoot graph)
      let filtered = filterGraph config rootDir graph
      let allGraphPaths =
            Map.keys (Mod.mgModules filtered)
              ++ map Mod.pfPath (Mod.mgFailures filtered)
              ++ map Mod.lfPath (Mod.mgLintFailures filtered)
              ++ map Mod.layPath (Mod.mgLayoutFailures filtered)
      if asDot
        then liftIO $ printDot rootDir filtered
        else do
          pViolations <- liftIO $ LintPackages.checkPackageDirs allGraphPaths
          let (_, activePkg') = partitionPackageViolations config pViolations
          let patViolations = concatMap LintPatterns.findPatternViolations (map Mod.modExpr (Map.elems (Mod.mgModules filtered)))
          liftIO $ printGraph rootDir filtered activePkg' patViolations
          if Mod.hasViolations filtered || not (null activePkg') || not (null patViolations)
            then liftIO exitFailure
            else liftIO exitSuccess
  where
    filterGraph :: Config.Config -> FilePath -> Mod.ModuleGraph -> Mod.ModuleGraph
    filterGraph cfg rootDir g =
      let keep p = not (Config.isIgnored cfg (makeRelative rootDir p))
          keepMod m = keep (Mod.modPath m)
          keepFail pf = keep (Mod.pfPath pf)
          keepLint lf = keep (Mod.lfPath lf)
          keepLay lf = keep (Mod.layPath lf)
       in g
            { Mod.mgModules = Map.filter keepMod (Mod.mgModules g),
              Mod.mgOrder = filter keep (Mod.mgOrder g),
              Mod.mgFailures = filter keepFail (Mod.mgFailures g),
              Mod.mgLintFailures = filter keepLint (Mod.mgLintFailures g),
              Mod.mgLayoutFailures = filter keepLay (Mod.mgLayoutFailures g)
            }
    printGraph :: FilePath -> Mod.ModuleGraph -> [LintPackages.PackageViolation] -> [LintPatterns.PatternViolation] -> IO ()
    printGraph rootDir graph pkgViolations patternViolations = do
      putStrLn "=== Module Graph ==="
      putStrLn $ "Root: " ++ makeRelative rootDir (Mod.mgRoot graph)
      putStrLn $ "Modules: " ++ show (Map.size (Mod.mgModules graph))

      let parseFailures = Mod.mgFailures graph
      let lintFailures = Mod.mgLintFailures graph
      let layoutFailures = Mod.mgLayoutFailures graph
      let lintViolationCount = sum (map (length . Mod.lfViolations) lintFailures)
      let layoutViolationCount = sum (map (length . Mod.layViolations) layoutFailures)
      let pkgViolationCount = length pkgViolations
      let patternVCount = length patternViolations

      if null parseFailures && null lintFailures && null layoutFailures && null pkgViolations && null patternViolations
        then putStrLn ""
        else do
          if not (null parseFailures)
            then do
              putStrLn $ "Parse failures: " ++ show (length parseFailures)
              putStrLn ""
              putStrLn "=== Parse Failures (banned syntax) ==="
              mapM_ (printParseFailure rootDir) parseFailures
              putStrLn ""
            else return ()

          if not (null lintFailures)
            then do
              putStrLn $ "Lint violations: " ++ show lintViolationCount ++ " in " ++ show (length lintFailures) ++ " files"
              putStrLn ""
              putStrLn "=== Lint Failures (with/rec banned) ==="
              mapM_ (printLintFailure rootDir) lintFailures
              putStrLn ""
            else return ()

          if not (null patternViolations)
            then do
              putStrLn $ "Pattern violations: " ++ show patternVCount
              putStrLn ""
              putStrLn "=== Pattern Violations (or-null, translateAttrs) ==="
              mapM_ (printPatternViolation rootDir) patternViolations
              putStrLn ""
            else return ()

          if not (null layoutFailures)
            then do
              putStrLn $ "Layout violations: " ++ show layoutViolationCount ++ " in " ++ show (length layoutFailures) ++ " files"
              putStrLn ""
              putStrLn "=== Layout Failures (directory structure) ==="
              mapM_ (printLayoutFailure rootDir) layoutFailures
              putStrLn ""
            else return ()

          if not (null pkgViolations)
            then do
              putStrLn $ "Package violations: " ++ show pkgViolationCount
              putStrLn ""
              putStrLn "=== Package Failures (default.nix missing) ==="
              mapM_ (printPackageViolation rootDir) pkgViolations
              putStrLn ""
            else return ()

      putStrLn "=== Topological Order (dependencies first) ==="
      mapM_ (\p -> putStrLn $ "  " ++ makeRelative rootDir p) (Mod.mgOrder graph)
      putStrLn ""

      putStrLn "=== Import Graph ==="
      mapM_ (printModuleImports rootDir) (Map.elems (Mod.mgModules graph))

      putStrLn ""
      putStrLn "=== Module Types ==="
      mapM_ (printModuleType rootDir graph) (Mod.mgOrder graph)

    printParseFailure :: FilePath -> Mod.ParseFailure -> IO ()
    printParseFailure rootDir pf = do
      let path = makeRelative rootDir (Mod.pfPath pf)
      TIO.putStrLn $ "  " <> T.pack path <> ":"
      -- Extract just the first line of the error (location info)
      let errLines = T.lines (Mod.pfError pf)
      case errLines of
        (l : _) -> TIO.putStrLn $ "    " <> l
        [] -> return ()

    printLintFailure :: FilePath -> Mod.LintFailure -> IO ()
    printLintFailure rootDir lf = do
      let path = makeRelative rootDir (Mod.lfPath lf)
      TIO.putStrLn $ "  " <> T.pack path <> ":"
      mapM_ printViolation (Mod.lfViolations lf)

    printViolation :: Lint.NixViolation -> IO ()
    printViolation v = do
      let loc = Lint.nvSpan v
      let code = case Lint.nvType v of
            Lint.VWith -> "ALEPH-N001"
            Lint.VRec -> "ALEPH-N002"
            Lint.VSubstituteAll -> "ALEPH-N005"
            Lint.VRawMkDerivation -> "ALEPH-N006"
            Lint.VRawRunCommand -> "ALEPH-N007"
            Lint.VRawWriteShellApplication -> "ALEPH-N008"
            Lint.VWriteShellScript -> "ALEPH-N011"
            Lint.VLongInlineString _ -> "ALEPH-N012"
      TIO.putStrLn $
        "    "
          <> T.pack (show (locLine (spanStart loc)))
          <> ":"
          <> T.pack (show (locCol (spanStart loc)))
          <> " "
          <> code
          <> ": "
          <> Lint.nvContext v

    locLine (Loc l _) = l
    locCol (Loc _ c) = c
    spanStart (Span s _ _) = s

    printLayoutFailure :: FilePath -> Mod.LayoutFailure -> IO ()
    printLayoutFailure rootDir lf = do
      let path = makeRelative rootDir (Mod.layPath lf)
      TIO.putStrLn $ "  " <> T.pack path <> ":"
      mapM_ printLayoutViolation (Mod.layViolations lf)

    printLayoutViolation :: Layout.LayoutViolation -> IO ()
    printLayoutViolation v = do
      let code = case Layout.lvCode v of
            Layout.L001 -> "ALEPH-L001"
            Layout.L002 -> "ALEPH-L002"
            Layout.L003 -> "ALEPH-L003"
            Layout.L004 -> "ALEPH-L004"
            Layout.L005 -> "ALEPH-L005"
      case Layout.lvSpan v of
        Just loc ->
          TIO.putStrLn $
            "    "
              <> T.pack (show (locLine (spanStart loc)))
              <> ":"
              <> T.pack (show (locCol (spanStart loc)))
              <> " "
              <> code
              <> ": "
              <> Layout.lvMessage v
        Nothing ->
          TIO.putStrLn $ "    " <> code <> ": " <> Layout.lvMessage v

    printPackageViolation :: FilePath -> LintPackages.PackageViolation -> IO ()
    printPackageViolation rootDir v = do
      let path = makeRelative rootDir (LintPackages.pvPath v)
      TIO.putStrLn $ "  " <> T.pack path
      let code = case LintPackages.pvCode v of
            LintPackages.P001 -> "ALEPH-P001"
      TIO.putStrLn $ "    " <> code <> ": " <> LintPackages.pvMessage v

    printPatternViolation :: FilePath -> LintPatterns.PatternViolation -> IO ()
    printPatternViolation _ v = do
      let loc = LintPatterns.pvSpan v
      let code = case LintPatterns.pvType v of
            LintPatterns.VOrNullFallback -> "ALEPH-N009"
            LintPatterns.VAttrTranslation -> "ALEPH-N010"
      TIO.putStrLn $
        "    "
          <> T.pack (show (locLine (spanStart loc)))
          <> ":"
          <> T.pack (show (locCol (spanStart loc)))
          <> " "
          <> code
          <> ": "
          <> LintPatterns.pvContext v

    printModuleImports :: FilePath -> Mod.Module -> IO ()
    printModuleImports rootDir m = do
      let path = makeRelative rootDir (Mod.modPath m)
      let imports = Mod.modImports m
      if null imports
        then return ()
        else do
          putStrLn $ path ++ ":"
          mapM_ (\imp -> putStrLn $ "  -> " ++ makeRelative rootDir (Mod.impPath imp)) imports

    printModuleType :: FilePath -> Mod.ModuleGraph -> FilePath -> IO ()
    printModuleType rootDir graph path =
      case Map.lookup path (Mod.mgModules graph) of
        Nothing -> return ()
        Just m -> do
          let relPath = makeRelative rootDir path
          TIO.putStrLn $ T.pack relPath <> " : " <> NixCompile.Nix.Types.prettyType (Mod.modType m)

    printDot :: FilePath -> Mod.ModuleGraph -> IO ()
    printDot rootDir graph = do
      putStrLn "digraph modules {"
      putStrLn "  rankdir=LR;"
      putStrLn "  node [shape=box];"
      putStrLn ""
      mapM_ (printDotEdges rootDir) (Map.elems (Mod.mgModules graph))
      putStrLn "}"

    printDotEdges :: FilePath -> Mod.Module -> IO ()
    printDotEdges rootDir m = do
      let path = makeRelative rootDir (Mod.modPath m)
      mapM_
        ( \imp -> do
            let impPath = makeRelative rootDir (Mod.impPath imp)
            putStrLn $ "  \"" ++ path ++ "\" -> \"" ++ impPath ++ "\";"
        )
        (Mod.modImports m)

-- | Show scope graph for a Nix file
cmdScope :: FilePath -> AppM ()
cmdScope file = do
  result <- liftIO $ Nix.parseNixFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right expr -> do
      let sg = Scope.fromNixFile file expr
      liftIO $ printScopeGraph sg

-- | Emit scope graph as JSON (for zeitschrift)
cmdScopeJSON :: FilePath -> AppM ()
cmdScopeJSON file = do
  result <- liftIO $ Nix.parseNixFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right expr -> do
      let sg = Scope.fromNixFile file expr
      liftIO $ BL.putStrLn $ encode sg

-- | Emit scope graph as Dhall (for zeitschrift)
cmdScopeDhall :: FilePath -> AppM ()
cmdScopeDhall file = do
  result <- liftIO $ Nix.parseNixFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right expr -> do
      let sg = Scope.fromNixFile file expr
      liftIO $ TIO.putStrLn $ Scope.toDhall sg

printScopeGraph :: Scope.ScopeGraph -> IO ()
printScopeGraph sg = do
  putStrLn "=== Scope Graph ==="
  putStrLn $ "File: " ++ maybe "(none)" id (Scope.sgFile sg)
  putStrLn $ "Scopes: " ++ show (Map.size (Scope.sgScopes sg))
  putStrLn ""

  -- Print scopes with their contents
  forM_ (Map.elems (Scope.sgScopes sg)) $ \scope -> do
    putStrLn $
      "Scope "
        ++ show (Scope.unScopeId (Scope.scopeId scope))
        ++ " ("
        ++ show (Scope.scopeKind scope)
        ++ "):"

    -- Declarations
    let decls = Scope.scopeDeclarations scope
    unless (null decls) $ do
      putStrLn "  Declarations:"
      forM_ decls $ \d -> do
        TIO.putStrLn $
          "    "
            <> Scope.declName d
            <> maybe "" (\t -> " : " <> t) (Scope.declType d)

    -- References
    let refs = Scope.scopeReferences scope
    unless (null refs) $ do
      putStrLn "  References:"
      forM_ refs $ \r -> do
        TIO.putStrLn $ "    " <> Scope.refName r <> " (" <> T.pack (show (Scope.refKind r)) <> ")"

    -- Edges
    let edges = Scope.scopeEdges scope
    unless (null edges) $ do
      putStrLn "  Edges:"
      forM_ edges $ \e -> do
        putStrLn $
          "    -> "
            ++ show (Scope.unScopeId (Scope.edgeTarget e))
            ++ " ("
            ++ show (Scope.edgeLabel e)
            ++ ")"

    putStrLn ""

  -- Resolution summary
  case Scope.resolveAll sg of
    Left errors -> do
      putStrLn $ "=== Unresolved References (" ++ show (length errors) ++ ") ==="
      forM_ errors $ \case
        Scope.Unresolved ref -> TIO.putStrLn $ "  " <> Scope.refName ref
        Scope.Ambiguous ref _ -> TIO.putStrLn $ "  " <> Scope.refName ref <> " (ambiguous)"
    Right resolved -> do
      putStrLn $ "=== All " ++ show (length resolved) ++ " references resolved ==="
