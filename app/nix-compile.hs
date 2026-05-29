-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // app // nix-compile // main
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "They set a slamhound on Turner's trail in New Delhi, slotted it to his
--    pheromones and the color of his hair."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // Main // CLI entry point
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Control.Applicative ((<|>))
import Control.Concurrent.QSemN (newQSemN, signalQSemN, waitQSemN)
import Control.Exception (IOException, SomeException, bracket_, try)
import Control.Monad (foldM, forM_, unless, when)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Functor.Compose (Compose (..))
import Data.List (isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)

import Control.Concurrent.Async (forConcurrently)
import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Fix (Fix (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nix.Expr.Types
import Nix.Expr.Types.Annotated (AnnUnit (..), NExprLoc)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (makeRelative, takeDirectory, takeExtension, (</>))

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

data TCResult = TCOk | TCFail | TCSkip
    deriving (Eq, Show)

main :: IO ()
main = runLog InfoS $ do
    commandArguments <- liftIO getArgs
    let (maybeConfigPath, commandAndArgs) = parseConfigArg commandArguments
    loadedConfig <- loadConfiguration maybeConfigPath
    $(logTM) InfoS $
        logStr $
            "Config: profile="
                <> Config.configProfile loadedConfig
                <> " overrides="
                <> T.pack (show (length (Config.configOverrides loadedConfig)))
                <> " ignores="
                <> T.pack (show (length (Config.configExtraIgnores loadedConfig)))
    dispatchCommand loadedConfig commandAndArgs

loadConfiguration :: Maybe FilePath -> AppM Config.Config
loadConfiguration (Just configPath) = do
    result <- liftIO $ Config.loadConfig configPath
    case result of
        Left errorMessage -> do
            $(logTM) WarningS $ logStr $ "Failed to load config: " <> errorMessage
            pure Config.defaultConfig
        Right configuration -> pure configuration
loadConfiguration Nothing = do
    configFileExists <- liftIO $ doesFileExist ".nix-compile.dhall"
    if configFileExists
        then do
            result <- liftIO $ Config.loadConfig ".nix-compile.dhall"
            case result of
                Left errorMessage -> do
                    $(logTM) WarningS $ logStr $ "Failed to load .nix-compile.dhall: " <> errorMessage
                    pure Config.defaultConfig
                Right configuration -> pure configuration
        else pure Config.defaultConfig

dispatchCommand :: Config.Config -> [String] -> AppM ()
dispatchCommand config ("graph" : args) =
    let (dir, asDot) = parseGraphArgs args
     in cmdGraph config dir asDot
dispatchCommand config ["lint", file] = cmdLint config file
dispatchCommand config ["check", file] = cmdCheck config file
dispatchCommand _ ["infer", file] = cmdInfer file
dispatchCommand _ ["parse", file] = cmdParse file
dispatchCommand _ ["emit", file] = cmdEmit file
dispatchCommand config ["nix", file] = cmdNix config file
dispatchCommand _ ["fmt", file] = cmdFmt file
dispatchCommand config ["typecheck", path] = cmdTypeCheck config path
dispatchCommand _ ["flake"] = cmdFlake "."
dispatchCommand _ ["flake", dir] = cmdFlake dir
dispatchCommand _ ["scope", file] = cmdScope file
dispatchCommand _ ["scope", "--json", file] = cmdScopeJSON file
dispatchCommand _ ["scope", "--dhall", file] = cmdScopeDhall file
dispatchCommand config ["ci"] = cmdCI config "."
dispatchCommand config ["ci", dir] = cmdCI config dir
dispatchCommand _ ["--help"] = liftIO usage
dispatchCommand _ ["-h"] = liftIO usage
dispatchCommand _ [] = liftIO usage
dispatchCommand _ unknownArgs = do
    $(logTM) ErrorS $ logStr $ T.pack $ "Unknown command: " ++ unwords unknownArgs
    liftIO usage
    liftIO exitFailure

parseConfigArg :: [String] -> (Maybe FilePath, [String])
parseConfigArg ("--config" : path : rest) = (Just path, rest)
parseConfigArg args = (Nothing, args)

parseGraphArgs :: [String] -> (FilePath, Bool)
parseGraphArgs ["--dot", dir] = (dir, True)
parseGraphArgs [dir, "--dot"] = (dir, True)
parseGraphArgs ["--dot"] = (".", True)
parseGraphArgs [dir] = (dir, False)
parseGraphArgs _ = (".", False)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CI: unified pass/fail across all checks
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data CICounts = CICounts
    { ciFilesScanned :: !Int
    , ciTypePass :: !Int
    , ciTypeFail :: !Int
    , ciTypeSkip :: !Int
    , ciLintViolations :: !Int
    , ciPackageViolations :: !Int
    , ciBashViolations :: !Int
    , ciGraphFailures :: !Int
    }

emptyCICounts :: CICounts
emptyCICounts = CICounts 0 0 0 0 0 0 0 0

cmdCI :: Config.Config -> FilePath -> AppM ()
cmdCI config dir = do
    $(logTM) InfoS $ logStr "\n═══════════════════════════════════════════════════════════════════════════════"
    $(logTM) InfoS $ logStr "  nix-compile ci"
    $(logTM) InfoS $ logStr $ "  " <> T.pack dir
    $(logTM) InfoS $ logStr "═══════════════════════════════════════════════════════════════════════════════"

    counts <- runCIPhases config dir
    reportCISummary counts

runCIPhases :: Config.Config -> FilePath -> AppM CICounts
runCIPhases config dir = do
    let flakePath = dir </> "flake.nix"
    hasFlake <- liftIO $ doesFileExist flakePath

    -- phase 1: typecheck all nix files (already parallelised)
    typeCounts <- runTypeCheckPhase config dir

    -- phase 2: module graph + lint violations
    graphCounts <- if hasFlake
        then runGraphPhase config flakePath
        else pure emptyCICounts

    -- phase 3: embedded bash analysis
    bashCounts <- if hasFlake
        then runNixPhase config flakePath
        else pure emptyCICounts

    -- phase 4: package directory checks
    files <- liftIO $ collectFiles config dir
    pkgCounts <- runPackagePhase config files

    pure $
        CICounts
            { ciFilesScanned = ciFilesScanned typeCounts
            , ciTypePass = ciTypePass typeCounts
            , ciTypeFail = ciTypeFail typeCounts
            , ciTypeSkip = ciTypeSkip typeCounts
            , ciLintViolations = ciLintViolations graphCounts
            , ciPackageViolations = pkgCounts
            , ciBashViolations = ciBashViolations bashCounts
            , ciGraphFailures = ciGraphFailures graphCounts
            }

runTypeCheckPhase :: Config.Config -> FilePath -> AppM CICounts
runTypeCheckPhase config dir = do
    files <- liftIO $ collectFiles config dir
    printTypeCheckHeader files

    loggingEnv <- getLogEnv
    loggingCtx <- getKatipContext
    loggingNamespace <- getKatipNamespace

    let maxConcurrency = 16 :: Int
    concurrencySemaphore <- liftIO $ newQSemN maxConcurrency
    results <- liftIO $ forConcurrently files $ \file ->
        bracket_ (waitQSemN concurrencySemaphore 1) (signalQSemN concurrencySemaphore 1) $
            wrapCheckFile config (loggingEnv, loggingCtx, loggingNamespace) file

    let okCount = length [() | result <- results, result == TCOk]
    let skipCount = length [() | result <- results, result == TCSkip]
    let failCount = length [() | result <- results, result == TCFail]

    pure $
        CICounts
            { ciFilesScanned = length files
            , ciTypePass = okCount
            , ciTypeFail = failCount
            , ciTypeSkip = skipCount
            , ciLintViolations = 0
            , ciPackageViolations = 0
            , ciBashViolations = 0
            , ciGraphFailures = 0
            }

runGraphPhase :: Config.Config -> FilePath -> AppM CICounts
runGraphPhase _config flakePath = do
    graphResult <- liftIO $ Mod.buildModuleGraphFromFlake (takeDirectory flakePath)
    case graphResult of
        Left err -> do
            $(logTM) ErrorS $ logStr $ "Graph error: " <> err
            pure $ emptyCICounts{ciGraphFailures = 1}
        Right graph ->
            let lintCount = sum (map (length . Mod.lfViolations) (Mod.mgLintFailures graph))
                layoutCount = sum (map (length . Mod.layViolations) (Mod.mgLayoutFailures graph))
             in if Mod.hasViolations graph
                    then do
                        $(logTM) ErrorS $
                            logStr $
                                "\nGraph violations: "
                                    <> T.pack (show lintCount)
                                    <> " lint, "
                                    <> T.pack (show layoutCount)
                                    <> " layout"
                                    <> " across "
                                    <> T.pack (show (length (Mod.mgLintFailures graph)))
                                    <> " files"
                        mapM_ reportGraphFailure (Mod.mgLintFailures graph)
                        pure $
                            emptyCICounts
                                { ciLintViolations = lintCount + layoutCount
                                , ciGraphFailures = length (Mod.mgFailures graph)
                                }
                    else pure emptyCICounts
  where
    reportGraphFailure lf = do
        $(logTM) ErrorS $ logStr $ "  " <> T.pack (Mod.lfPath lf) <> ": " <> T.pack (show (length (Mod.lfViolations lf))) <> " violations"
        $(logTM) ErrorS $ logStr $ Lint.formatNixViolations (Mod.lfViolations lf)

runNixPhase :: Config.Config -> FilePath -> AppM CICounts
runNixPhase config flakePath = do
    scripts <- parseNixFiles flakePath
    totalErrors <- sum <$> mapM (checkScript config flakePath) scripts
    pure $
        emptyCICounts
            { ciBashViolations = totalErrors
            }

runPackagePhase :: Config.Config -> [FilePath] -> AppM Int
runPackagePhase config files = do
    packageViolations <- liftIO $ LintPackages.checkPackageDirs files
    let (_, active) = partitionPackageViolations config packageViolations
    unless (null active) $ do
        $(logTM) ErrorS $
            logStr $
                T.unlines
                    [ ""
                    , "Package directory violations:"
                    ]
        $(logTM) ErrorS $ logStr $ formatPackageViolations active
    pure $ length active

reportCISummary :: CICounts -> AppM ()
reportCISummary counts = do
    let totalFailures =
            ciTypeFail counts
                + ciLintViolations counts
                + ciPackageViolations counts
                + ciBashViolations counts
                + ciGraphFailures counts
    $(logTM) InfoS $ logStr ""
    $(logTM) InfoS $
        logStr $
            T.unlines
                [ "═══════════════════════════════════════════════════════════════════════════════"
                , "  CI Summary"
                , "  " <> T.pack (show (ciFilesScanned counts)) <> " files scanned"
                , "  "
                    <> T.pack (show (ciTypePass counts))
                    <> " passed"
                    <> (if ciTypeSkip counts > 0 then ", " <> T.pack (show (ciTypeSkip counts)) <> " skipped" else "")
                    <> (if ciTypeFail counts > 0 then ", " <> T.pack (show (ciTypeFail counts)) <> " failed" else "")
                , if ciLintViolations counts > 0
                    then "  " <> T.pack (show (ciLintViolations counts)) <> " lint violations"
                    else ""
                , if ciPackageViolations counts > 0
                    then "  " <> T.pack (show (ciPackageViolations counts)) <> " package violations"
                    else ""
                , if ciBashViolations counts > 0
                    then "  " <> T.pack (show (ciBashViolations counts)) <> " bash violations"
                    else ""
                , if ciGraphFailures counts > 0
                    then "  " <> T.pack (show (ciGraphFailures counts)) <> " graph failures"
                    else ""
                , "═══════════════════════════════════════════════════════════════════════════════"
                ]
    if totalFailures == 0
        then do
            $(logTM) InfoS $ logStr "\n  ALL GREEN"
            liftIO exitSuccess
        else do
            $(logTM) ErrorS $ logStr $ "\n  " <> T.pack (show totalFailures) <> " total issue(s)"
            liftIO exitFailure

usage :: IO ()
usage = do
    putStrLn "nix-compile - compile-time type checker for Nix expressions"
    putStrLn ""
    putStrLn "Usage:"
    putStrLn "  nix-compile ci [dir]            Run all checks: typecheck + graph + lint + bash + packages"
    putStrLn "  nix-compile typecheck <path>    Recursively infer and check types for all Nix files"
    putStrLn "  nix-compile graph [--dot] [dir] Show module dependency graph (exits 1 on violations)"
    putStrLn "  nix-compile flake [dir]         Analyze a flake"
    putStrLn "  nix-compile nix <file.nix>      Check embedded bash in Nix files"
    putStrLn "  nix-compile lint <script.sh>    Check for forbidden constructs (heredocs, eval, etc)"
    putStrLn "  nix-compile check <script.sh>   Full check (lint + policy + types)"
    putStrLn "  nix-compile infer <script.sh>   Infer types and show schema (JSON)"
    putStrLn "  nix-compile parse <script.sh>   Parse and show extracted facts"
    putStrLn "  nix-compile emit <script.sh>    Generate emit-config bash function (use: emit-config <json|yaml|toml>)"
    putStrLn "  nix-compile fmt <file.nix>      Add type annotations to Nix file"
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

-- ──────────────────────────────────────────────────────────────────────────────
-- Pretty-printing for bash policy violations
-- ──────────────────────────────────────────────────────────────────────────────

formatBareCommand :: T.Text -> (T.Text, Span) -> T.Text
formatBareCommand src (cmd, sourceSpan) =
    let tok = locLine (spanStart sourceSpan)
     in T.unlines
            [ "error[ALEPH-B005]: bare command not allowed: " <> cmd
            , "  --> " <> src <> ":" <> T.pack (show tok)
            , ""
            , "  Use an explicit store path for external commands:"
            , "    /nix/store/...-pkg/bin/" <> cmd
            ]

formatDynamicCommand :: T.Text -> (T.Text, Span) -> T.Text
formatDynamicCommand src (var, sourceSpan) =
    let tok = locLine (spanStart sourceSpan)
     in T.unlines
            [ "error[ALEPH-B006]: dynamic command not allowed: $" <> var
            , "  --> " <> src <> ":" <> T.pack (show tok)
            , ""
            , "  Dynamic command selection is not statically analyzable."
            , "  Use a known store path or a case statement over a small allowlist."
            ]

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

safeReadFile :: FilePath -> IO (Either T.Text T.Text)
safeReadFile path = do
    result <- try (TIO.readFile path)
    case result of
        Left (e :: IOException) -> pure (Left (T.pack (show e)))
        Right sourceText -> pure (Right sourceText)

suppressedSuffix :: [Violation] -> T.Text
suppressedSuffix [] = ""
suppressedSuffix suppressed = " (" <> T.pack (show (length suppressed)) <> " suppressed)"

cmdLint :: Config.Config -> FilePath -> AppM ()
cmdLint config file = do
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
                let (suppressed, active) = partitionViolations config allViolations
                if null active
                    then do
                        $(logTM) InfoS $ logStr $ T.pack file <> ": OK" <> suppressedSuffix suppressed
                        liftIO exitSuccess
                    else do
                        $(logTM) ErrorS $ logStr $ formatViolationsAt (T.pack file) active
                        $(logTM) ErrorS $ logStr $ "\n" <> T.pack (show (length active)) <> " error(s) in " <> T.pack file <> suppressedSuffix suppressed
                        liftIO exitFailure

reportBareCommands :: FilePath -> [(T.Text, Span)] -> AppM ()
reportBareCommands file bareFacts
    | null bareFacts = pure ()
    | otherwise = do
        liftIO $ TIO.putStrLn ""
        liftIO $ TIO.putStrLn "Bare commands (external commands must use store paths; shell builtins allowed):"
        liftIO $ mapM_ (TIO.putStr . formatBareCommand (T.pack file)) bareFacts

reportDynamicCommands :: FilePath -> [(T.Text, Span)] -> AppM ()
reportDynamicCommands file dynFacts
    | null dynFacts = pure ()
    | otherwise = do
        liftIO $ TIO.putStrLn ""
        liftIO $ TIO.putStrLn "Dynamic commands (cannot analyze):"
        liftIO $ mapM_ (TIO.putStr . formatDynamicCommand (T.pack file)) dynFacts

printCheckResult :: FilePath -> Int -> AppM ()
printCheckResult file totalErrors
    | totalErrors > 0 = do
        $(logTM) ErrorS $ logStr $ T.pack $ "\n" ++ show totalErrors ++ " error(s) in " ++ file
        liftIO exitFailure
    | otherwise = do
        $(logTM) InfoS $ logStr $ T.pack $ file ++ ": OK"
        liftIO exitSuccess

cmdCheck :: Config.Config -> FilePath -> AppM ()
cmdCheck config file = do
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
                unless (null violations) $ do
                    $(logTM) ErrorS $ logStr $ formatViolationsAt (T.pack file) violations
                    liftIO $ putStrLn ""

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

                let bareFacts = [(cmd, sourceSpan) | BareCommand cmd sourceSpan <- facts]
                let dynFacts = [(var, sourceSpan) | DynamicCommand var sourceSpan <- facts]
                let bareCount = length bareFacts
                let dynCount = length dynFacts
                let violationCount = length violations

                reportBareCommands file bareFacts
                reportDynamicCommands file dynFacts

                printCheckResult file (violationCount + bareCount + dynCount)

cmdEmit :: FilePath -> AppM ()
cmdEmit file = do
    result <- liftIO $ parseScriptFile file
    case result of
        Left err -> do
            $(logTM) ErrorS $ logStr $ "Error: " <> err
            liftIO exitFailure
        Right script -> do
            liftIO $ TIO.putStr $ emitConfigFunction (scriptSchema script)

-- ── Nix subcommand ────────────────────────────────────────────────
-- extracts embedded bash from Nix files and runs the full check pipeline

cmdNix :: Config.Config -> FilePath -> AppM ()
-- n.b. three-phase pipeline: parse → analyze → report
cmdNix config file = do
    scripts <- parseNixFiles file
    totalErrors <- analyzeNixScripts config file scripts
    reportNixResults file totalErrors

parseNixFiles :: FilePath -> AppM [Nix.BashScript]
-- phase 1: extract all bash scripts baked into the Nix file
parseNixFiles file = do
    result <- liftIO $ Nix.extractBashScripts file
    case result of
        Left err -> do
            $(logTM) ErrorS $ logStr $ "Parse error: " <> err
            liftIO exitFailure
        Right scripts -> do
            $(logTM) InfoS $ logStr $ T.pack $ "Found " ++ show (length scripts) ++ " shell scripts in " ++ file
            pure scripts

analyzeNixScripts :: Config.Config -> FilePath -> [Nix.BashScript] -> AppM Int
-- phase 2: run the full check pipeline on every embedded script, sum errors
analyzeNixScripts config file scripts =
    sum <$> mapM (checkScript config file) scripts

reportNixResults :: FilePath -> Int -> AppM ()
-- phase 3: summary — pass/fail with total error count
reportNixResults file totalErrors
    | totalErrors > 0 = do
        $(logTM) ErrorS $ logStr $ T.pack $ "\n" ++ show totalErrors ++ " total error(s)"
        liftIO exitFailure
    | otherwise = do
        $(logTM) InfoS $ logStr $ T.pack $ file ++ ": OK"
        liftIO exitSuccess

checkScript :: Config.Config -> FilePath -> Nix.BashScript -> AppM Int
-- run lint, interpolation check, config validation, type inference, and bare/dynamic cmd detection on one script
checkScript configuration file bs = do
    $(logTM) InfoS $ logStr $ "\n=== " <> Nix.bsName bs <> " ==="
    case parseBash (Nix.bsContent bs) of
        Left err -> do
            $(logTM) ErrorS $ logStr $ "  Parse error: " <> err
            return 1
        Right ast -> do
            -- lint: forbidden constructs
            let allViolations = findViolations ast
            let (_, violations) = partitionViolations configuration allViolations
            unless (null violations) $ do
                let srcLabel = T.pack file <> ":" <> Nix.bsName bs
                $(logTM) ErrorS $ logStr $ formatViolationsAt srcLabel violations

            -- n.b. non-store-path interpolations are warnings, not errors
            let badInterps = filter (not . Nix.intIsStorePath) (Nix.bsInterpolations bs)
            unless (null badInterps) $ do
                $(logTM) WarningS $ logStr "  Non-store-path interpolations (may need verification):"
                liftIO $ mapM_ (\i -> putStrLn $ "    ${" ++ T.unpack (Nix.intExpr i) ++ "}") badInterps

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

            let bareFacts = [(cmd, sourceSpan) | BareCommand cmd sourceSpan <- facts]
            let dynFacts = [(var, sourceSpan) | DynamicCommand var sourceSpan <- facts]
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

printTypeCheckHeader :: [FilePath] -> AppM ()
printTypeCheckHeader files =
    $(logTM) InfoS $
        logStr $
            T.unlines
                [ ""
                , "═══════════════════════════════════════════════════════════════════════════════"
                , "  nix-compile typecheck"
                , "  " <> T.pack (show (length files) <> " files")
                , "═══════════════════════════════════════════════════════════════════════════════"
                , ""
                ]

printTypeCheckSummary :: Int -> Int -> Int -> Int -> AppM ()
printTypeCheckSummary okCount skipCount failCount packageViolationCount =
    $(logTM) InfoS $
        logStr $
            T.unlines
                [ ""
                , "═══════════════════════════════════════════════════════════════════════════════"
                , "  Summary"
                , "  " <> T.pack (show okCount <> " passed")
                , "  " <> T.pack (show skipCount <> " skipped (unsupported constructs)")
                , "  " <> T.pack (show failCount <> " failed")
                , "  " <> T.pack (show packageViolationCount <> " package directory violations")
                , "═══════════════════════════════════════════════════════════════════════════════"
                , ""
                ]

reportPackageDirViolations :: Config.Config -> [FilePath] -> AppM [LintPackages.PackageViolation]
reportPackageDirViolations config files = do
    packageViolations <- liftIO $ LintPackages.checkPackageDirs files
    let (_, activePackageViolations) = partitionPackageViolations config packageViolations
    unless (null activePackageViolations) $ do
        $(logTM) ErrorS $
            logStr $
                T.unlines
                    [ ""
                    , "═══════════════════════════════════════════════════════════════════════════════"
                    , "  Package Directories Missing default.nix"
                    , ""
                    ]
        $(logTM) ErrorS $ logStr $ formatPackageViolations activePackageViolations
    pure activePackageViolations

cmdTypeCheck :: Config.Config -> FilePath -> AppM ()
cmdTypeCheck config path = do
    files <- liftIO $ collectFiles config path
    printTypeCheckHeader files

    loggingEnv <- getLogEnv
    loggingCtx <- getKatipContext
    loggingNamespace <- getKatipNamespace

    let maxConcurrency = 16 :: Int
    concurrencySemaphore <- liftIO $ newQSemN maxConcurrency
    results <- liftIO $ forConcurrently files $ \file ->
        bracket_ (waitQSemN concurrencySemaphore 1) (signalQSemN concurrencySemaphore 1) $
            wrapCheckFile config (loggingEnv, loggingCtx, loggingNamespace) file
    let okCount = length [() | result <- results, result == TCOk]
    let skipCount = length [() | result <- results, result == TCSkip]
    let failCount = length [() | result <- results, result == TCFail]

    activePackageViolations <- reportPackageDirViolations config files
    let packageViolationCount = length activePackageViolations

    printTypeCheckSummary okCount skipCount failCount packageViolationCount

    if failCount == 0 && null activePackageViolations
        then liftIO exitSuccess
        else liftIO exitFailure

collectFiles :: Config.Config -> FilePath -> IO [FilePath]
collectFiles config path = do
    isDirectory <- doesDirectoryExist path
    if isDirectory
        then collectNixFilesRecursive config path
        else pure $ if Config.isIgnored config path then [] else [path]

collectNixFilesRecursive :: Config.Config -> FilePath -> IO [FilePath]
collectNixFilesRecursive config root = do
    canonicalRoot <- canonicalizePath root
    let ignoredDirs = Set.fromList [".git", ".direnv", "node_modules", ".cache", ".lake", "result", "result-lib", "target"]
    allFiles <- walkDirectory canonicalRoot ignoredDirs [] Set.empty [root]
    pure $ filter (not . Config.isIgnored config . makeRelative canonicalRoot) allFiles

walkDirectory :: FilePath -> Set.Set FilePath -> [FilePath] -> Set.Set FilePath -> [FilePath] -> IO [FilePath]
walkDirectory _canonicalRoot _ignoredDirs accumulatedFiles _visited [] = pure accumulatedFiles
walkDirectory canonicalRoot ignoredDirs accumulatedFiles visited (directory : worklist) = do
    canonical <- canonicalizePath directory
    if canonical `Set.member` visited || not (canonicalRoot `isPrefixOf` canonical)
        then walkDirectory canonicalRoot ignoredDirs accumulatedFiles visited worklist
        else do
            entries <- listDirectory directory
            (nixFiles, subDirectories) <- classifyEntries directory ignoredDirs entries
            walkDirectory
                canonicalRoot
                ignoredDirs
                (nixFiles ++ accumulatedFiles)
                (Set.insert canonical visited)
                (subDirectories ++ worklist)

classifyEntries :: FilePath -> Set.Set FilePath -> [FilePath] -> IO ([FilePath], [FilePath])
classifyEntries basePath ignoredDirs entries =
    foldM
        ( \(nixFiles, subDirectories) entry -> do
            let fullPath = basePath </> entry
            if entry `elem` Set.toList ignoredDirs
                then pure (nixFiles, subDirectories)
                else do
                    isDirectory <- doesDirectoryExist fullPath
                    if isDirectory
                        then pure (nixFiles, fullPath : subDirectories)
                        else pure (if takeExtension fullPath == ".nix" then fullPath : nixFiles else nixFiles, subDirectories)
        )
        ([], [])
        entries

wrapCheckFile :: Config.Config -> (LogEnv, LogContexts, Namespace) -> FilePath -> IO TCResult
wrapCheckFile config (loggingEnv, loggingContext, loggingNamespace) file =
    runKatipContextT loggingEnv loggingContext loggingNamespace (checkFile config file)

checkFile :: Config.Config -> FilePath -> AppM TCResult
checkFile config file = do
    parseResult <- liftIO $ Nix.parseNixFile file
    case parseResult of
        Left parseError -> do
            $(logTM) ErrorS $
                logStr $
                    T.unlines
                        [ ""
                        , "━━━ " <> crossMarker <> " " <> T.pack file <> " ━━━"
                        , ""
                        , "  PARSE ERROR: " <> parseError
                        , ""
                        ]
            return TCFail
        Right expression ->
            case detectUnsupportedConstruct expression of
                Just reason -> do
                    $(logTM) InfoS $ logStr $ skipMarker <> " " <> T.pack file <> " (unsupported: " <> reason <> ")"
                    return TCSkip
                Nothing -> checkWithViolations config file expression

checkWithViolations :: Config.Config -> FilePath -> NExprLoc -> AppM TCResult
checkWithViolations config file expression = do
    let nixViolations = Lint.findNixViolations expression
    let (_, activeNixViolations) = partitionNixViolations config nixViolations
    let derivViolations = Derivation.findDerivViolations file expression
    let (_, activeDerivViolations) = partitionDerivViolations config derivViolations
    let patternViolations = LintPatterns.findPatternViolations expression
    let (_, activePatternViolations) = partitionPatternViolations config patternViolations

    reportNixLintViolations file activeNixViolations
    reportDerivViolations file activeDerivViolations
    reportPatternViolations file activePatternViolations

    typeCheckResult <- performTypeCheck expression
    case typeCheckResult of
        TCFail -> return TCFail
        TCOk | null activeNixViolations && null activeDerivViolations && null activePatternViolations -> do
            $(logTM) InfoS $ logStr $ okMarker <> " " <> T.pack file
            return TCOk
        _ -> do
            $(logTM) InfoS $ logStr $ crossMarker <> " " <> T.pack file <> " (lint violations)"
            return TCFail

okMarker :: Text
okMarker = "[OK]"

crossMarker :: Text
crossMarker = "[XX]"

skipMarker :: Text
skipMarker = "[SKIP]"

reportNixLintViolations :: FilePath -> [Lint.NixViolation] -> AppM ()
reportNixLintViolations file violations
    | null violations = pure ()
    | otherwise = do
        $(logTM) ErrorS $
            logStr $
                T.unlines
                    [ ""
                    , "━━━ " <> crossMarker <> " " <> T.pack file <> " ━━━"
                    , ""
                    , "  NIX LINT VIOLATIONS:"
                    , ""
                    ]
        $(logTM) ErrorS $ logStr $ Lint.formatNixViolations violations

reportDerivViolations :: FilePath -> [Derivation.DerivViolation] -> AppM ()
reportDerivViolations file violations
    | null violations = pure ()
    | otherwise = do
        $(logTM) WarningS $
            logStr $
                T.unlines
                    [ ""
                    , "━━━ " <> crossMarker <> " " <> T.pack file <> " ━━━"
                    , ""
                    , "  DERIVATION QUALITY VIOLATIONS:"
                    , ""
                    ]
        $(logTM) WarningS $ logStr $ Derivation.formatDerivViolations violations

reportPatternViolations :: FilePath -> [LintPatterns.PatternViolation] -> AppM ()
reportPatternViolations file violations
    | null violations = pure ()
    | otherwise = do
        $(logTM) WarningS $
            logStr $
                T.unlines
                    [ ""
                    , "━━━ " <> crossMarker <> " " <> T.pack file <> " ━━━"
                    , ""
                    , "  PATTERN VIOLATIONS:"
                    , ""
                    ]
        $(logTM) WarningS $ logStr $ LintPatterns.formatPatternViolations violations

performTypeCheck :: NExprLoc -> AppM TCResult
performTypeCheck expression = do
    result <- liftIO $ try $ case NixCompile.Nix.Infer.inferExpr expression of
        Left typeError -> return $ Left typeError
        Right (type_, _) -> return $ Right (NixCompile.Nix.Types.prettyType type_)
    case result of
        Left (exception :: SomeException) -> do
            $(logTM) ErrorS $
                logStr $
                    T.unlines
                        [ ""
                        , "  INTERNAL ERROR (this is a bug in nix-compile):"
                        , ""
                        , T.unlines $ map ("     " <>) $ T.lines $ T.pack $ show exception
                        ]
            return TCFail
        Right (Left typeError) -> do
            $(logTM) ErrorS $
                logStr $
                    T.unlines
                        [ ""
                        , formatTypeError typeError
                        , ""
                        ]
            return TCFail
        Right (Right _) -> return TCOk

formatTypeError :: Text -> Text
formatTypeError errorText =
    case T.lines errorText of
        (firstLine : remainingLines) -> T.unlines $ ("  ERROR: " <> firstLine) : map ("         " <>) remainingLines
        [] -> "  ERROR: unknown error"

detectUnsupportedConstruct :: NExprLoc -> Maybe Text
detectUnsupportedConstruct (Fix (Compose (AnnUnit _ expression))) = case expression of
    NSelect _ _ (DynamicKey _ :| _) -> Just "dynamic attribute access"
    NAbs _ body -> detectUnsupportedConstruct body
    NLet bindings body ->
        foldl (<|>) (detectUnsupportedConstruct body) (map detectUnsupportedBinding bindings)
    NSet _ bindings ->
        foldl (<|>) Nothing (map detectUnsupportedBinding bindings)
    NList elements ->
        foldl (<|>) Nothing (map detectUnsupportedConstruct elements)
    NBinary _ left right ->
        detectUnsupportedConstruct left <|> detectUnsupportedConstruct right
    NUnary _ arg -> detectUnsupportedConstruct arg
    NSelect _ base _ -> detectUnsupportedConstruct base
    NHasAttr base attributePath
        | any isDynamicKey attributePath -> Just "dynamic attribute test"
        | otherwise -> detectUnsupportedConstruct base
    NApp function arg -> detectUnsupportedConstruct function <|> detectUnsupportedConstruct arg
    NIf cond thenBranch elseBranch -> detectUnsupportedConstruct cond <|> detectUnsupportedConstruct thenBranch <|> detectUnsupportedConstruct elseBranch
    NAssert cond body -> detectUnsupportedConstruct cond <|> detectUnsupportedConstruct body
    _ -> Nothing
  where
    isDynamicKey (DynamicKey _) = True
    isDynamicKey _ = False

detectUnsupportedBinding :: Binding NExprLoc -> Maybe Text
detectUnsupportedBinding (NamedVar _ expression _) = detectUnsupportedConstruct expression
detectUnsupportedBinding (Inherit _ _ _) = Nothing

formatPackageViolations :: [LintPackages.PackageViolation] -> T.Text
formatPackageViolations [] = ""
formatPackageViolations violations =
    T.unlines
        [ "ALEPH-P001: Package directories must contain a `default.nix` file:"
        , ""
        ]
        <> T.unlines (map (\violation -> "  " <> T.pack (LintPackages.pvPath violation)) violations)

cmdFmt :: FilePath -> AppM ()
cmdFmt file = do
    result <- liftIO $ NixFmt.formatFile file
    case result of
        Left err -> do
            $(logTM) ErrorS $ logStr $ "Error: " <> err
            liftIO exitFailure
        Right formatted -> do
            liftIO $ TIO.putStr formatted

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

cmdGraph :: Config.Config -> FilePath -> Bool -> AppM ()
cmdGraph config dir asDot = do
    result <- liftIO $ Mod.buildModuleGraphFromFlake dir
    case result of
        Left err -> do
            $(logTM) ErrorS $ logStr $ "Error: " <> err
            liftIO exitFailure
        Right graph -> do
            let rootDir = takeDirectory (Mod.mgRoot graph)
            let filtered = filterModuleGraph config rootDir graph
            if asDot
                then liftIO $ printDotGraph rootDir filtered
                else do
                    violations <- liftIO $ collectGraphViolations config filtered
                    liftIO $ printModuleGraph config rootDir filtered violations
                    when (graphHasViolations filtered violations) $
                        liftIO exitFailure
                    liftIO exitSuccess

filterModuleGraph :: Config.Config -> FilePath -> Mod.ModuleGraph -> Mod.ModuleGraph
filterModuleGraph config rootDir moduleGraph =
    let shouldKeep path = not (Config.isIgnored config (makeRelative rootDir path))
     in moduleGraph
            { Mod.mgModules = Map.filter (shouldKeep . Mod.modPath) (Mod.mgModules moduleGraph)
            , Mod.mgOrder = filter shouldKeep (Mod.mgOrder moduleGraph)
            , Mod.mgFailures = filter (shouldKeep . Mod.pfPath) (Mod.mgFailures moduleGraph)
            , Mod.mgLintFailures = filter (shouldKeep . Mod.lfPath) (Mod.mgLintFailures moduleGraph)
            , Mod.mgLayoutFailures = filter (shouldKeep . Mod.layPath) (Mod.mgLayoutFailures moduleGraph)
            }

allModulePaths :: Mod.ModuleGraph -> [FilePath]
allModulePaths graph =
    Map.keys (Mod.mgModules graph)
        ++ map Mod.pfPath (Mod.mgFailures graph)
        ++ map Mod.lfPath (Mod.mgLintFailures graph)
        ++ map Mod.layPath (Mod.mgLayoutFailures graph)

collectGraphViolations :: Config.Config -> Mod.ModuleGraph -> IO ([LintPackages.PackageViolation], [LintPatterns.PatternViolation])
collectGraphViolations config graph = do
    let allGraphPaths = allModulePaths graph
    packageViolations <- LintPackages.checkPackageDirs allGraphPaths
    let (_, activePackageViolations) = partitionPackageViolations config packageViolations
    let patternViolations = concatMap LintPatterns.findPatternViolations (map Mod.modExpr (Map.elems (Mod.mgModules graph)))
    pure (activePackageViolations, patternViolations)

graphHasViolations :: Mod.ModuleGraph -> ([LintPackages.PackageViolation], [LintPatterns.PatternViolation]) -> Bool
graphHasViolations graph (packageViolations, patternViolations) =
    Mod.hasViolations graph || not (null packageViolations) || not (null patternViolations)

printModuleGraph :: Config.Config -> FilePath -> Mod.ModuleGraph -> ([LintPackages.PackageViolation], [LintPatterns.PatternViolation]) -> IO ()
printModuleGraph config rootDir graph (packageViolations, patternViolations) = do
    putStrLn "=== Module Graph ==="
    putStrLn $ "Root: " ++ makeRelative rootDir (Mod.mgRoot graph)
    putStrLn $ "Modules: " ++ show (Map.size (Mod.mgModules graph))

    printModuleDetails config rootDir graph packageViolations patternViolations
    printModuleTree rootDir graph

printModuleDetails :: Config.Config -> FilePath -> Mod.ModuleGraph -> [LintPackages.PackageViolation] -> [LintPatterns.PatternViolation] -> IO ()
printModuleDetails config rootDir graph packageViolations patternViolations = do
    let parseFailures = Mod.mgFailures graph
    let lintFailures = Mod.mgLintFailures graph
    let layoutFailures = Mod.mgLayoutFailures graph
    let layoutViolationCount = sum (map (length . Mod.layViolations) layoutFailures)
    let packageViolationCount = length packageViolations
    let patternViolationCount = length patternViolations
    unless (null parseFailures && null lintFailures && null layoutFailures && null packageViolations && null patternViolations) $ do
        printParseFailuresSection rootDir parseFailures
        printLintFailuresSection config rootDir lintFailures
        printPatternViolationsSection rootDir patternViolations patternViolationCount
        printLayoutFailuresSection rootDir layoutFailures layoutViolationCount
        printPackageViolationsSection rootDir packageViolations packageViolationCount

printModuleTree :: FilePath -> Mod.ModuleGraph -> IO ()
printModuleTree rootDir graph = do
    putStrLn "=== Topological Order (dependencies first) ==="
    mapM_ (\path -> putStrLn $ "  " ++ makeRelative rootDir path) (Mod.mgOrder graph)
    putStrLn ""
    putStrLn "=== Import Graph ==="
    mapM_ (printModuleImports rootDir) (Map.elems (Mod.mgModules graph))
    putStrLn ""
    putStrLn "=== Module Types ==="
    mapM_ (printModuleType rootDir graph) (Mod.mgOrder graph)

printParseFailuresSection :: FilePath -> [Mod.ParseFailure] -> IO ()
printParseFailuresSection rootDir parseFailures
    | null parseFailures = pure ()
    | otherwise = do
        putStrLn $ "Parse failures: " ++ show (length parseFailures)
        putStrLn ""
        putStrLn "=== Parse Failures (banned syntax) ==="
        mapM_ (printParseFailure rootDir) parseFailures
        putStrLn ""

printParseFailure :: FilePath -> Mod.ParseFailure -> IO ()
printParseFailure rootDir parseFailure = do
    let relativePath = makeRelative rootDir (Mod.pfPath parseFailure)
    TIO.putStrLn $ "  " <> T.pack relativePath <> ":"
    case T.lines (Mod.pfError parseFailure) of
        (firstLine : _) -> TIO.putStrLn $ "    " <> firstLine
        [] -> pure ()

printLintFailuresSection :: Config.Config -> FilePath -> [Mod.LintFailure] -> IO ()
printLintFailuresSection config rootDir lintFailures
    | null lintFailures = pure ()
    | otherwise = do
        let filteredFailures =
                [ failure{Mod.lfViolations = activeViolations}
                | failure <- lintFailures
                , let (_, activeViolations) = partitionNixViolations config (Mod.lfViolations failure)
                , not (null activeViolations)
                ]
        let totalViolations = sum (map (length . Mod.lfViolations) filteredFailures)
        putStrLn $ "Lint violations: " ++ show totalViolations ++ " in " ++ show (length filteredFailures) ++ " files"
        putStrLn ""
        putStrLn "=== Lint Failures (with/rec banned) ==="
        mapM_ (printLintFailure rootDir) filteredFailures
        putStrLn ""

printLintFailure :: FilePath -> Mod.LintFailure -> IO ()
printLintFailure rootDir lintFailure = do
    let path = makeRelative rootDir (Mod.lfPath lintFailure)
    TIO.putStrLn $ "  " <> T.pack path <> ":"
    mapM_ printNixViolation (Mod.lfViolations lintFailure)

printNixViolation :: Lint.NixViolation -> IO ()
printNixViolation violation = do
    let location = Lint.nvSpan violation
    let code = case Lint.nvType violation of
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
            <> T.pack (show (locLine (spanStart location)))
            <> ":"
            <> T.pack (show (locCol (spanStart location)))
            <> " "
            <> code
            <> ": "
            <> Lint.nvContext violation

printPatternViolationsSection :: FilePath -> [LintPatterns.PatternViolation] -> Int -> IO ()
printPatternViolationsSection _rootDir patternViolations count
    | null patternViolations = pure ()
    | otherwise = do
        putStrLn $ "Pattern violations: " ++ show count
        putStrLn ""
        putStrLn "=== Pattern Violations (or-null, translateAttrs) ==="
        mapM_ printPatternViolation patternViolations
        putStrLn ""

printPatternViolation :: LintPatterns.PatternViolation -> IO ()
printPatternViolation patternViolation = do
    let location = LintPatterns.pvSpan patternViolation
    let code = case LintPatterns.pvType patternViolation of
            LintPatterns.VOrNullFallback -> "ALEPH-N009"
            LintPatterns.VAttrTranslation -> "ALEPH-N010"
    TIO.putStrLn $
        "    "
            <> T.pack (show (locLine (spanStart location)))
            <> ":"
            <> T.pack (show (locCol (spanStart location)))
            <> " "
            <> code
            <> ": "
            <> LintPatterns.pvContext patternViolation

printLayoutFailuresSection :: FilePath -> [Mod.LayoutFailure] -> Int -> IO ()
printLayoutFailuresSection rootDir layoutFailures count
    | null layoutFailures = pure ()
    | otherwise = do
        putStrLn $ "Layout violations: " ++ show count ++ " in " ++ show (length layoutFailures) ++ " files"
        putStrLn ""
        putStrLn "=== Layout Failures (directory structure) ==="
        mapM_ (printLayoutFailure rootDir) layoutFailures
        putStrLn ""

printLayoutFailure :: FilePath -> Mod.LayoutFailure -> IO ()
printLayoutFailure rootDir layoutFailure = do
    let path = makeRelative rootDir (Mod.layPath layoutFailure)
    TIO.putStrLn $ "  " <> T.pack path <> ":"
    mapM_ printLayoutViolation (Mod.layViolations layoutFailure)

printLayoutViolation :: Layout.LayoutViolation -> IO ()
printLayoutViolation layoutViolation = do
    let code = case Layout.lvCode layoutViolation of
            Layout.L001 -> "ALEPH-L001"
            Layout.L002 -> "ALEPH-L002"
            Layout.L003 -> "ALEPH-L003"
            Layout.L004 -> "ALEPH-L004"
            Layout.L005 -> "ALEPH-L005"
    case Layout.lvSpan layoutViolation of
        Just location ->
            TIO.putStrLn $
                "    "
                    <> T.pack (show (locLine (spanStart location)))
                    <> ":"
                    <> T.pack (show (locCol (spanStart location)))
                    <> " "
                    <> code
                    <> ": "
                    <> Layout.lvMessage layoutViolation
        Nothing ->
            TIO.putStrLn $ "    " <> code <> ": " <> Layout.lvMessage layoutViolation

printPackageViolationsSection :: FilePath -> [LintPackages.PackageViolation] -> Int -> IO ()
printPackageViolationsSection rootDir packageViolations count
    | null packageViolations = pure ()
    | otherwise = do
        putStrLn $ "Package violations: " ++ show count
        putStrLn ""
        putStrLn "=== Package Failures (default.nix missing) ==="
        mapM_ (printPackageViolation rootDir) packageViolations
        putStrLn ""

printPackageViolation :: FilePath -> LintPackages.PackageViolation -> IO ()
printPackageViolation rootDir packageViolation = do
    let path = makeRelative rootDir (LintPackages.pvPath packageViolation)
    TIO.putStrLn $ "  " <> T.pack path
    let code = case LintPackages.pvCode packageViolation of
            LintPackages.P001 -> "ALEPH-P001"
    TIO.putStrLn $ "    " <> code <> ": " <> LintPackages.pvMessage packageViolation

printModuleImports :: FilePath -> Mod.Module -> IO ()
printModuleImports rootDir module_ = do
    let path = makeRelative rootDir (Mod.modPath module_)
    let imports = Mod.modImports module_
    unless (null imports) $ do
        putStrLn $ path ++ ":"
        mapM_ (\imp -> putStrLn $ "  -> " ++ makeRelative rootDir (Mod.impPath imp)) imports

printModuleType :: FilePath -> Mod.ModuleGraph -> FilePath -> IO ()
printModuleType rootDir graph path =
    case Map.lookup path (Mod.mgModules graph) of
        Nothing -> pure ()
        Just module_ -> do
            let relativePath = makeRelative rootDir path
            TIO.putStrLn $ T.pack relativePath <> " : " <> NixCompile.Nix.Types.prettyType (Mod.modType module_)

printDotGraph :: FilePath -> Mod.ModuleGraph -> IO ()
printDotGraph rootDir moduleGraph = do
    putStrLn "digraph modules {"
    putStrLn "  rankdir=LR;"
    putStrLn "  node [shape=box];"
    putStrLn ""
    mapM_ (printDotEdges rootDir) (Map.elems (Mod.mgModules moduleGraph))
    putStrLn "}"

printDotEdges :: FilePath -> Mod.Module -> IO ()
printDotEdges rootDir module_ = do
    let path = makeRelative rootDir (Mod.modPath module_)
    mapM_
        ( \imp -> do
            let importPath = makeRelative rootDir (Mod.impPath imp)
            putStrLn $ "  \"" ++ path ++ "\" -> \"" ++ importPath ++ "\";"
        )
        (Mod.modImports module_)

cmdScope :: FilePath -> AppM ()
cmdScope file = do
    result <- liftIO $ Nix.parseNixFile file
    case result of
        Left err -> do
            $(logTM) ErrorS $ logStr $ "Parse error: " <> err
            liftIO exitFailure
        Right expr -> do
            let scopeGraph = Scope.fromNixFile file expr
            liftIO $ printScopeGraph scopeGraph

cmdScopeJSON :: FilePath -> AppM ()
cmdScopeJSON file = do
    result <- liftIO $ Nix.parseNixFile file
    case result of
        Left err -> do
            $(logTM) ErrorS $ logStr $ "Parse error: " <> err
            liftIO exitFailure
        Right expr -> do
            let scopeGraph = Scope.fromNixFile file expr
            liftIO $ BL.putStrLn $ encode scopeGraph

cmdScopeDhall :: FilePath -> AppM ()
cmdScopeDhall file = do
    result <- liftIO $ Nix.parseNixFile file
    case result of
        Left err -> do
            $(logTM) ErrorS $ logStr $ "Parse error: " <> err
            liftIO exitFailure
        Right expr -> do
            let scopeGraph = Scope.fromNixFile file expr
            liftIO $ TIO.putStrLn $ Scope.toDhall scopeGraph

printScopeGraph :: Scope.ScopeGraph -> IO ()
printScopeGraph scopeGraph = do
    putStrLn "=== Scope Graph ==="
    putStrLn $ "File: " ++ maybe "(none)" id (Scope.sgFile scopeGraph)
    putStrLn $ "Scopes: " ++ show (Map.size (Scope.sgScopes scopeGraph))
    putStrLn ""

    forM_ (Map.elems (Scope.sgScopes scopeGraph)) $ \scope -> do
        putStrLn $
            "Scope "
                ++ show (Scope.unScopeId (Scope.scopeId scope))
                ++ " ("
                ++ show (Scope.scopeKind scope)
                ++ "):"

        let decls = Scope.scopeDeclarations scope
        unless (null decls) $ do
            putStrLn "  Declarations:"
            forM_ decls $ \declaration -> do
                TIO.putStrLn $
                    "    "
                        <> Scope.declName declaration
                        <> maybe "" (\typeLabel -> " : " <> typeLabel) (Scope.declType declaration)

        let refs = Scope.scopeReferences scope
        unless (null refs) $ do
            putStrLn "  References:"
            forM_ refs $ \reference -> do
                TIO.putStrLn $ "    " <> Scope.refName reference <> " (" <> T.pack (show (Scope.refKind reference)) <> ")"

        let edges = Scope.scopeEdges scope
        unless (null edges) $ do
            putStrLn "  Edges:"
            forM_ edges $ \edge -> do
                putStrLn $
                    "    -> "
                        ++ show (Scope.unScopeId (Scope.edgeTarget edge))
                        ++ " ("
                        ++ show (Scope.edgeLabel edge)
                        ++ ")"

        putStrLn ""

    case Scope.resolveAll scopeGraph of
        Left errors -> do
            putStrLn $ "=== Unresolved References (" ++ show (length errors) ++ ") ==="
            forM_ errors $ \case
                Scope.Unresolved ref -> TIO.putStrLn $ "  " <> Scope.refName ref
                Scope.Ambiguous ref _ -> TIO.putStrLn $ "  " <> Scope.refName ref <> " (ambiguous)"
        Right resolved -> do
            putStrLn $ "=== All " ++ show (length resolved) ++ " references resolved ==="
