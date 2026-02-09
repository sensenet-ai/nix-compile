{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import NixCompile (parseScript, Script(..), Schema(..), EnvSpec(..), Type(..))
import NixCompile.Nix.Infer (inferFile)
import NixCompile.Nix.Layout (findLayoutViolations, LayoutViolation(..), LayoutCode(..))
import NixCompile.Nix.Lint (findNixViolations, NixViolation(..), ViolationType(..))
import NixCompile.Nix.Parse (parseNixFile)
import NixCompile.Types (Fact(..))
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (replaceExtension)

-- | Run all fixture tests
main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--bless"] -> do
      putStrLn "Blessing fixture outputs..."
      blessFixtures
      putStrLn "All fixtures blessed."
    _ -> runTests

-- | Run all fixture tests
runTests :: IO ()
runTests = do
  putStrLn "Running fixture tests..."
  results <- sequence
    [ testCheckByName
    , testCheckByNameOutput
    , testQemuCommon
    , testKernel
    , testGpuBrokerLayoutValid
    , testGpuBrokerLayoutInvalid
    , testBuiltinsTypeInference
    ]
  
  if all id results
    then do
      putStrLn "All fixture tests passed."
      exitSuccess
    else do
      putStrLn "Some fixture tests failed."
      exitFailure

-- | Bless all fixture outputs
blessFixtures :: IO ()
blessFixtures = do
  -- Bless bash fixtures
  let bashFixtures = 
        [ "test/fixtures/bash/check-by-name.sh"
        , "test/fixtures/bash/nativelink-integration.sh"
        , "test/fixtures/bash/builtins-type-inference.sh"
        ]
  mapM_ blessBashFixture bashFixtures
  
  -- Bless nix fixtures
  let nixFixtures = 
        [ "test/fixtures/nix/qemu-common.nix"
        , "test/fixtures/nix/kernel.nix"
        , "test/fixtures/nix/isospin-main.nix"
        ]
  mapM_ blessNixFixture nixFixtures
  
  putStrLn "All fixtures blessed."

-- | Bless a bash fixture (regenerate expected outputs)
blessBashFixture :: FilePath -> IO ()
blessBashFixture path = do
  putStrLn $ "Blessing " ++ path ++ "..."
  src <- TIO.readFile path
  case parseScript src of
    Left err -> putStrLn $ "  Parse error: " ++ show err
    Right script -> do
      let parseOutput = T.pack $ "Facts:\n" ++ unlines (map show (scriptFacts script))
      let inferOutput = T.pack $ show (scriptSchema script)
      TIO.writeFile (replaceExtension path "parse.expected") parseOutput
      TIO.writeFile (replaceExtension path "infer.expected") inferOutput
      putStrLn "  Done."

-- | Bless a nix fixture (regenerate expected outputs)
blessNixFixture :: FilePath -> IO ()
blessNixFixture path = do
  putStrLn $ "Blessing " ++ path ++ "..."
  -- Parse
  parseRes <- parseNixFile path
  case parseRes of
    Left err -> putStrLn $ "  Parse error: " ++ show err
    Right expr -> do
      let violations = findNixViolations expr
      let parseOutput = T.pack $ "Violations:\n" ++ unlines (map show violations)
      TIO.writeFile (replaceExtension path "parse.expected") parseOutput
      
      -- Infer
      inferRes <- inferFile path
      case inferRes of
        Left err -> putStrLn $ "  Infer error: " ++ show err
        Right schema -> do
          let inferOutput = T.pack $ show schema
          TIO.writeFile (replaceExtension path "infer.expected") inferOutput
          putStrLn "  Done."

-- | Test: maintainers/scripts/check-by-name.sh
-- Expect:
--   - Parse: Success
--   - Schema: Contains inferred env vars
--   - Policy: Should fail check (bare commands, dynamic commands)
testCheckByName :: IO Bool
testCheckByName = do
  putStr "testCheckByName... "
  src <- TIO.readFile "test/fixtures/bash/check-by-name.sh"
  case parseScript src of
    Left err -> do
      putStrLn $ "FAILED: Parse error: " ++ show err
      return False
    Right script -> do
      let schema = scriptSchema script
      let facts = scriptFacts script
      
      -- Check extracted variables
      let env = schemaEnv schema
      let hasBaseBranch = "baseBranch" `Map.member` env
      let hasRepo = "repo" `Map.member` env
      
      -- Check policy violations (should be present)
      -- parseScript doesn't run policy checks directly, but we can inspect facts
      let bareCommands = [c | BareCommand c _ <- facts]
      let dynamicCommands = [v | DynamicCommand v _ <- facts]
      
      let hasBareGit = any ("git" `T.isInfixOf`) bareCommands
      let hasDynamic = not (null dynamicCommands)
      
      if hasBaseBranch && hasRepo && hasBareGit && not hasDynamic
        then do
          putStrLn "OK"
          return True
        else do
          putStrLn "FAILED"
          putStrLn $ "  Has baseBranch: " ++ show hasBaseBranch
          putStrLn $ "  Has repo: " ++ show hasRepo
          putStrLn $ "  Has bare git: " ++ show hasBareGit
          putStrLn $ "  Has dynamic cmds: " ++ show hasDynamic
          return False

-- | Test: check-by-name.sh output matches expected
-- This test compares actual tool output against expected files
testCheckByNameOutput :: IO Bool
testCheckByNameOutput = do
  putStr "testCheckByNameOutput... "
  
  -- Test parse output
  let parseExpectedPath = "test/fixtures/bash/check-by-name.parse.expected"
  
  -- Run tool and capture output
  src <- TIO.readFile "test/fixtures/bash/check-by-name.sh"
  case parseScript src of
    Left err -> do
      putStrLn $ "FAILED: Parse error: " ++ show err
      return False
    Right script -> do
      let actualParse = T.pack $ "Facts:\n" ++ unlines (map show (scriptFacts script))
      expectedParse <- TIO.readFile parseExpectedPath
      
      if actualParse == expectedParse
        then do
          -- Test infer output
          let inferExpectedPath = "test/fixtures/bash/check-by-name.infer.expected"
          let actualInfer = T.pack $ show (scriptSchema script)
          expectedInfer <- TIO.readFile inferExpectedPath
          
          if actualInfer == expectedInfer
            then do
              putStrLn "OK"
              return True
            else do
              putStrLn "FAILED: Infer output mismatch"
              return False
        else do
          putStrLn "FAILED: Parse output mismatch"
          return False

-- | Test: nixos/lib/qemu-common.nix
-- Expect:
--   - Parse: Success
--   - Infer: Success
--   - Lint: Failure (contains 'rec' and 'with')
testQemuCommon :: IO Bool
testQemuCommon = do
  putStr "testQemuCommon... "
  let path = "test/fixtures/nix/qemu-common.nix"
  
  -- Inference check
  inferRes <- inferFile path
  inferOk <- case inferRes of
    Left err -> do
      putStrLn $ "Inference failed: " ++ show err
      return False
    Right _ -> return True
    
  -- Lint check
  parseRes <- parseNixFile path
  lintOk <- case parseRes of
    Left err -> do
      putStrLn $ "Parse failed: " ++ show err
      return False
    Right expr -> do
      let violations = findNixViolations expr
      let hasRec = any (\v -> nvType v == VRec) violations
      let hasWith = any (\v -> nvType v == VWith) violations
      
      if hasRec && hasWith
        then return True
        else do
          putStrLn $ "Lint check failed (expected violations): rec=" ++ show hasRec ++ ", with=" ++ show hasWith
          return False

  if inferOk && lintOk
    then do
      putStrLn "OK"
      return True
    else do
      putStrLn "FAILED"
      return False

-- | Test: lib/kernel.nix
-- Expect:
--   - Parse: Success
--   - Infer: Success
--   - Lint: Success (clean)
testKernel :: IO Bool
testKernel = do
  putStr "testKernel... "
  let path = "test/fixtures/nix/kernel.nix"
  
  -- Inference check
  inferRes <- inferFile path
  inferOk <- case inferRes of
    Left err -> do
      putStrLn $ "Inference failed: " ++ show err
      return False
    Right _ -> return True
    
  -- Lint check
  parseRes <- parseNixFile path
  lintOk <- case parseRes of
    Left err -> do
      putStrLn $ "Parse failed: " ++ show err
      return False
    Right expr -> do
      let violations = findNixViolations expr
      if null violations
        then return True
        else do
          putStrLn $ "Lint check failed (expected no violations): " ++ show violations
          return False

  if inferOk && lintOk
    then do
      putStrLn "OK"
      return True
    else do
      putStrLn "FAILED"
      return False

-- | Test: test/fixtures/nix/modules/flake/gpu-broker.nix
-- Expect:
--   - Parse: Success
--   - Layout: Success (correct directory for _class = "flake")
testGpuBrokerLayoutValid :: IO Bool
testGpuBrokerLayoutValid = do
  putStr "testGpuBrokerLayoutValid... "
  let path = "test/fixtures/nix/modules/flake/gpu-broker.nix"
  
  parseRes <- parseNixFile path
  case parseRes of
    Left err -> do
      putStrLn $ "Parse failed: " ++ show err
      return False
    Right expr -> do
      let violations = findLayoutViolations path expr
      if null violations
        then do
          putStrLn "OK"
          return True
        else do
          putStrLn $ "Layout check failed (expected no violations): " ++ show violations
          return False

-- | Test: test/fixtures/nix/modules/nixos/gpu-broker.nix
-- Expect:
--   - Parse: Success
--   - Layout: Failure (directory implies "nixos", file has "flake")
testGpuBrokerLayoutInvalid :: IO Bool
testGpuBrokerLayoutInvalid = do
  putStr "testGpuBrokerLayoutInvalid... "
  let path = "test/fixtures/nix/modules/nixos/gpu-broker.nix"
  
  parseRes <- parseNixFile path
  case parseRes of
    Left err -> do
      putStrLn $ "Parse failed: " ++ show err
      return False
    Right expr -> do
      let violations = findLayoutViolations path expr
      let hasWrongClass = any (\v -> lvCode v == L004) violations
      
      if hasWrongClass
        then do
          putStrLn "OK"
          return True
        else do
          putStrLn $ "Layout check failed (expected L004): " ++ show violations
          return False

-- | Test: builtins-type-inference.sh
-- Verify that command argument types flow back to env var types
-- 
-- Example: curl --connect-timeout "$TIMEOUT" → TIMEOUT :: TInt
testBuiltinsTypeInference :: IO Bool
testBuiltinsTypeInference = do
  putStr "testBuiltinsTypeInference... "
  src <- TIO.readFile "test/fixtures/bash/builtins-type-inference.sh"
  case parseScript src of
    Left err -> do
      putStrLn $ "FAILED: Parse error: " ++ show err
      return False
    Right script -> do
      let schema = scriptSchema script
      let env = schemaEnv schema
      
      -- Check inferred types from curl
      let checkType var expectedTy = 
            case Map.lookup var env of
              Just spec -> envType spec == expectedTy
              Nothing -> False
      
      -- curl flags -> TInt
      let curlInts = all (\v -> checkType v TInt) 
            ["CONNECT_TIMEOUT", "MAX_TIME", "RETRY_COUNT", "RETRY_DELAY"]
      
      -- curl -o -> TPath
      let curlPath = checkType "OUTPUT_FILE" TPath
      
      -- wget -t/-T -> TInt, -O -> TPath
      let wgetInts = all (\v -> checkType v TInt)
            ["WGET_RETRIES", "WGET_TIMEOUT"]
      let wgetPath = checkType "WGET_OUTPUT" TPath
      
      -- ssh -p -> TInt, -i -> TPath
      let sshPort = checkType "SSH_PORT" TInt
      let sshKey = checkType "SSH_KEY" TPath
      
      -- find -maxdepth/-mindepth -> TInt
      let findInts = all (\v -> checkType v TInt)
            ["MAX_DEPTH", "MIN_DEPTH"]
      
      -- timeout/sleep positional -> TInt
      let timeInts = all (\v -> checkType v TInt)
            ["TIMEOUT_SECONDS", "SLEEP_SECONDS"]
      
      -- parallel -j/--timeout -> TInt
      let parallelInts = all (\v -> checkType v TInt)
            ["NUM_JOBS", "JOB_TIMEOUT"]
      
      -- Report failures
      let failures = filter (not . snd)
            [ ("curl int flags", curlInts)
            , ("curl -o path", curlPath)
            , ("wget int flags", wgetInts)
            , ("wget -O path", wgetPath)
            , ("ssh -p int", sshPort)
            , ("ssh -i path", sshKey)
            , ("find depth ints", findInts)
            , ("timeout/sleep ints", timeInts)
            , ("parallel ints", parallelInts)
            ]
      
      if null failures
        then do
          putStrLn "OK"
          return True
        else do
          putStrLn "FAILED"
          mapM_ (\(name, _) -> putStrLn $ "  Failed: " ++ name) failures
          -- Debug: show what we actually got
          putStrLn "  Inferred schema:"
          mapM_ (\(var, spec) -> 
            putStrLn $ "    " ++ T.unpack var ++ " :: " ++ show (envType spec)
            ) (Map.toList env)
          return False
