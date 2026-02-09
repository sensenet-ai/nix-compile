{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import NixCompile (parseScript, Script(..), Schema(..), EnvSpec(..), Type(..))
import NixCompile.Bash.Parse (parseBash)
import NixCompile.Lint.Forbidden (findViolations, Violation(..), ViolationType(..))
import NixCompile.Nix.Lint (findNixViolations, NixViolation(..))
import qualified NixCompile.Nix.Lint as NixLint
import NixCompile.Nix.Parse (parseNixFile, extractBashScripts, BashScript(..), Interpolation(..))
import NixCompile.Types (Fact(..))
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  putStrLn "Running more fixture tests..."
  results <- sequence
    [ testNativelinkIntegration
    , testIsospinMain
    , testCrossLangInference
    ]
  
  if all id results
    then do
      putStrLn "All additional fixture tests passed."
      exitSuccess
    else do
      putStrLn "Some additional fixture tests failed."
      exitFailure

-- | Test: test/fixtures/bash/nativelink-integration.sh
-- Expect:
--   - Parse: Success
--   - Policy: Heavy violations (heredocs, bare commands)
testNativelinkIntegration :: IO Bool
testNativelinkIntegration = do
  putStr "testNativelinkIntegration... "
  src <- TIO.readFile "test/fixtures/bash/nativelink-integration.sh"
  
  -- Check for forbidden constructs (heredocs, etc.)
  let lintViolations = case parseBash src of
        Right ast -> findViolations ast
        Left _ -> []
  
  let hasHeredoc = any (\v -> vType v == VHeredoc) lintViolations

  case parseScript src of
    Left err -> do
      putStrLn $ "FAILED: Parse error: " ++ show err
      return False
    Right script -> do
      let facts = scriptFacts script
      
      -- Check for specific expected facts
      let bareCommands = [c | BareCommand c _ <- facts]
      
      let hasDocker = any ("docker" `T.isInfixOf`) bareCommands
      let hasBazel = any ("bazel" `T.isInfixOf`) bareCommands
      
      -- Note: Arrays are currently not extracted as Facts, so we skip checking them explicitly via Facts.
      -- But the script parses successfully, which is part of the test.
      
      if hasDocker && hasBazel && hasHeredoc
        then do
          putStrLn "OK"
          return True
        else do
          putStrLn "FAILED"
          putStrLn $ "  Has docker: " ++ show hasDocker
          putStrLn $ "  Has bazel: " ++ show hasBazel
          putStrLn $ "  Has heredoc: " ++ show hasHeredoc
          return False

-- | Test: test/fixtures/nix/isospin-main.nix
-- Expect:
--   - Parse: Success
--   - Lint: Failure (rec, with)
--   - Bash Extraction: Success (> 10 scripts)
testIsospinMain :: IO Bool
testIsospinMain = do
  putStr "testIsospinMain... "
  let path = "test/fixtures/nix/isospin-main.nix"
  
  -- Parse Nix
  parseRes <- parseNixFile path
  case parseRes of
    Left err -> do
      putStrLn $ "FAILED: Parse error: " ++ show err
      return False
    Right expr -> do
      -- Lint check
      let violations = findNixViolations expr
      let hasRec = any (\v -> nvType v == NixLint.VRec) violations
      let hasWith = any (\v -> nvType v == NixLint.VWith) violations
      
      -- Bash extraction
      scriptsRes <- extractBashScripts path
      case scriptsRes of
        Left err -> do
          putStrLn $ "FAILED: Bash extraction error: " ++ show err
          return False
        Right scripts -> do
          let scriptCount = length scripts
          let hasManyScripts = scriptCount > 10
          
          -- Check a specific script (e.g., "boot-vm") for violations
          let checkScript = filter (\s -> bsName s == "boot-vm") scripts
          
          hasViolations <- case checkScript of
                [s] -> do
                  let src = bsContent s
                  case parseScript src of
                     Right sc -> do
                       let facts = scriptFacts sc
                       let bare = [c | BareCommand c _ <- facts]
                       -- We expect 'sudo' and 'buck2' to be bare commands
                       return $ any ("sudo" `T.isInfixOf`) bare && any ("buck2" `T.isInfixOf`) bare
                     Left _ -> return False
                _ -> do
                  putStrLn $ "DEBUG: 'boot-vm' script not found. Scripts: " ++ show (map bsName scripts)
                  return False

          if hasRec && hasWith && hasManyScripts && hasViolations
            then do
              putStrLn "OK"
              return True
            else do
              putStrLn "FAILED"
              putStrLn $ "  Has rec: " ++ show hasRec
              putStrLn $ "  Has with: " ++ show hasWith
              putStrLn $ "  Script count: " ++ show scriptCount
              putStrLn $ "  Script violations found: " ++ show hasViolations
              return False

-- | Test: cross-lang-inference.nix
-- Verify that bash command arg types flow back to Nix interpolation types
--
-- Example: curl --connect-timeout "${config.timeout}" 
--          should infer config.timeout :: TInt in Nix
testCrossLangInference :: IO Bool
testCrossLangInference = do
  putStr "testCrossLangInference... "
  let path = "test/fixtures/nix/cross-lang-inference.nix"
  
  scriptsRes <- extractBashScripts path
  case scriptsRes of
    Left err -> do
      putStrLn $ "FAILED: Extraction error: " ++ show err
      return False
    Right scripts -> do
      -- Analyze each script and check for cross-language type inference
      results <- mapM checkScriptTypes scripts
      
      let hasInferredTypes = any (not . null) results
      let allResults = concat results
      
      -- We expect to find types inferred for interpolations
      -- At minimum: config.timeout :: TInt, config.retries :: TInt, config.output :: TPath
      let hasTimeoutInt = any (\(expr, ty) -> "timeout" `T.isInfixOf` expr && ty == TInt) allResults
      let hasRetriesInt = any (\(expr, ty) -> "retries" `T.isInfixOf` expr && ty == TInt) allResults  
      let hasOutputPath = any (\(expr, ty) -> "output" `T.isInfixOf` expr && ty == TPath) allResults
      
      if hasInferredTypes && hasTimeoutInt && hasRetriesInt && hasOutputPath
        then do
          putStrLn "OK"
          return True
        else do
          putStrLn "FAILED"
          putStrLn $ "  Has any inferred types: " ++ show hasInferredTypes
          putStrLn $ "  timeout :: TInt: " ++ show hasTimeoutInt
          putStrLn $ "  retries :: TInt: " ++ show hasRetriesInt
          putStrLn $ "  output :: TPath: " ++ show hasOutputPath
          putStrLn $ "  All inferred types:"
          mapM_ (\(expr, ty) -> putStrLn $ "    ${" ++ T.unpack expr ++ "} :: " ++ show ty) allResults
          return False
  where
    -- Check a script and return inferred types for its interpolations
    checkScriptTypes :: BashScript -> IO [(T.Text, Type)]
    checkScriptTypes bs = do
      let content = bsContent bs
      case parseScript content of
        Left _ -> return []
        Right script -> do
          let schema = scriptSchema script
          let interps = bsInterpolations bs
          -- Find types for __nix_interp_N__ variables that map back to interpolations
          let interpTypes = 
                [ (intExpr interp, envType spec)
                | interp <- interps
                , let varName = "__nix_interp_" <> T.pack (show (intIndex interp)) <> "__"
                , Just spec <- [Map.lookup varName (schemaEnv schema)]
                , envType spec /= TString  -- Only non-default types
                ]
          return interpTypes
