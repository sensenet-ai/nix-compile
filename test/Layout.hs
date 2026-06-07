{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                  // tests // layout
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   Fixture-driven layout-convention enforcement (doc/design/layout-enforcement.md).
--   For each convention, every file under <conv>/pass/ must yield no layout
--   errors, and every file under <conv>/fail/ must yield at least one. The
--   convention root is the pass/ (or fail/) dir, so a fixture's path relative to
--   it is what the rules see (e.g. flake-modules/website/default.nix).
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module Main (main) where

import Control.Monad (forM)
import NixCompile.Nix.LayoutConvention (Convention, allFlakeModule, validateFileFromExpr)
import NixCompile.Nix.Parse (parseNixFile)
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (takeExtension, (</>))

-- | All .nix files under a directory, recursively.
nixFiles :: FilePath -> IO [FilePath]
nixFiles dir = do
    entries <- listDirectory dir
    fmap concat $ forM entries $ \e -> do
        let p = dir </> e
        isDir <- doesDirectoryExist p
        if isDir
            then nixFiles p
            else pure [p | takeExtension p == ".nix"]

{- | Check one pass/ or fail/ tree. Returns the number of files that behaved as
expected and the number that did not.
-}
checkTree :: Convention -> FilePath -> Bool -> IO (Int, Int)
checkTree conv root expectClean = do
    files <- nixFiles root
    oks <- forM files $ \f -> do
        parsed <- parseNixFile f
        case parsed of
            Left err -> do
                putStrLn $ "  PARSE FAIL " <> f <> ": " <> show err
                pure False
            Right expr -> do
                let errs = validateFileFromExpr conv root f expr
                    behaved = if expectClean then null errs else not (null errs)
                if behaved
                    then pure True
                    else do
                        putStrLn $
                            "  WRONG "
                                <> f
                                <> " — expected "
                                <> (if expectClean then "clean" else "a violation")
                                <> ", got "
                                <> show (length errs)
                                <> " error(s)"
                        pure False
    pure (length (filter id oks), length (filter not oks))

main :: IO ()
main = do
    putStrLn "Running layout-convention fixture tests..."
    (pPass, pBad) <- checkTree allFlakeModule "test/fixtures/layout/all-flake-module/pass" True
    (fPass, fBad) <- checkTree allFlakeModule "test/fixtures/layout/all-flake-module/fail" False
    putStrLn $
        "all-flake-module: pass-tree "
            <> show pPass
            <> "/"
            <> show (pPass + pBad)
            <> " clean, fail-tree "
            <> show fPass
            <> "/"
            <> show (fPass + fBad)
            <> " flagged"
    if pBad == 0 && fBad == 0
        then do putStrLn "All layout fixture tests passed."; exitSuccess
        else do putStrLn "Some layout fixture tests failed."; exitFailure
