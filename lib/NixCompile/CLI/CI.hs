{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wwarn=unused-imports #-}

module NixCompile.CLI.CI (
    cmdCI,
    runCIPhases,
    runTypeCheckPhase,
    runGraphPhase,
    runNixPhase,
    runPackagePhase,
    reportCISummary,
    printTypeCheckHeader,
    collectFiles,
    wrapCheckFile,
)
where

import Control.Concurrent.QSemN (newQSemN, signalQSemN, waitQSemN)
import GHC.Conc (getNumCapabilities)
import Control.Exception (bracket_)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.QSemN (newQSemN, signalQSemN, waitQSemN)
import GHC.Conc (getNumCapabilities)
import Control.Exception (bracket_)
import Control.Monad (foldM, unless)
import Control.Concurrent.Async (forConcurrently)
import Data.List (isPrefixOf)
import Data.Set qualified as Set
import Data.Text qualified as T
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (makeRelative, takeDirectory, takeExtension, (</>))

import NixCompile.CLI.Bash
import NixCompile.CLI.Check
import NixCompile.CLI.Report
import NixCompile.CLI.Types
import NixCompile.Config qualified as Config
import NixCompile.Log
import NixCompile.Nix.Lint qualified as Lint
import NixCompile.Nix.LintPackages qualified as LintPackages
import NixCompile.Nix.Module qualified as Mod

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

    typeCounts <- runTypeCheckPhase config dir

    graphCounts <- if hasFlake
        then runGraphPhase config flakePath
        else pure emptyCICounts

    bashCounts <- if hasFlake
        then runNixPhase config flakePath
        else pure emptyCICounts

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

    numCapabilities <- liftIO getNumCapabilities
    let maxConcurrency = numCapabilities
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
