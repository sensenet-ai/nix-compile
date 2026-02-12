{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : EmitConfigSpec
-- Description : Tests for emit-config generation
--
-- These tests verify that the Haskell emit-config generator produces
-- correct bash commands that output valid JSON/YAML/TOML.
module Main (main) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import System.Exit (exitFailure, exitSuccess)
import NixCompile.Emit.Config
import NixCompile.Types
import NixCompile.Pretty (toText)

-- | Empty span for tests
testSpan :: Span
testSpan = Span (Loc 1 1) (Loc 1 1) Nothing

-- | Test schema with a string and int config value
testSchema :: Schema
testSchema = emptySchema
  { schemaConfig = Map.fromList
      [ (["server", "host"], ConfigSpec
          { cfgType = TString
          , cfgFrom = Just "HOST"
          , cfgLit = Nothing
          , cfgQuoted = Just Quoted
          , cfgSpan = testSpan
          })
      , (["server", "port"], ConfigSpec
          { cfgType = TInt
          , cfgFrom = Just "PORT"
          , cfgLit = Nothing
          , cfgQuoted = Nothing
          , cfgSpan = testSpan
          })
      , (["debug"], ConfigSpec
          { cfgType = TBool
          , cfgFrom = Nothing
          , cfgLit = Just (LitBool True)
          , cfgQuoted = Nothing
          , cfgSpan = testSpan
          })
      ]
  }

-- | Test that JSON output has correct structure
testJsonOutput :: Bool
testJsonOutput =
  let json = emitConfigJson testSchema
   in -- JSON should contain printf, proper quoting
      T.isInfixOf "printf" json
      && T.isInfixOf "server" json
      && T.isInfixOf "host" json
      && T.isInfixOf "port" json
      && T.isInfixOf "$HOST" json  -- String var should be expanded
      && T.isInfixOf "$PORT" json  -- Int var should be expanded
      && T.isInfixOf "true" json   -- Boolean literal

-- | Test that YAML output has correct structure
testYamlOutput :: Bool
testYamlOutput =
  let yaml = emitConfigYaml testSchema
   in T.isInfixOf "printf" yaml
      && T.isInfixOf "server:" yaml
      && T.isInfixOf "  host:" yaml  -- Proper indentation
      && T.isInfixOf "  port:" yaml

-- | Test that TOML output has correct structure
testTomlOutput :: Bool
testTomlOutput =
  let toml = emitConfigToml testSchema
   in T.isInfixOf "printf" toml
      && T.isInfixOf "[server]" toml
      && T.isInfixOf "host = " toml
      && T.isInfixOf "port = " toml

-- | Test config key validation
testKeyValidation :: Bool
testKeyValidation =
  isValidConfigKey "validKey"
  && isValidConfigKey "valid_key"
  && isValidConfigKey "valid-key"
  && isValidConfigKey "_private"
  && not (isValidConfigKey "")
  && not (isValidConfigKey "123start")
  && not (isValidConfigKey "has space")
  && not (isValidConfigKey "has.dot")

-- | Test that invalid keys are detected
testInvalidKeyDetection :: Bool
testInvalidKeyDetection =
  let badSchema = Map.singleton ["bad.key"] (ConfigSpec TString Nothing Nothing Nothing testSpan)
   in not (null (validateConfigKeys badSchema))

-- | Test JSON escape function correctness
-- The escape function must produce valid JSON when run
testJsonEscapeInOutput :: Bool
testJsonEscapeInOutput =
  let func = toText (emitConfigFunction testSchema)
   in -- The generated bash should have the correct escape pattern
      -- s=${s//\"/\\\"} which replaces " with \"
      -- In Haskell literal: s=${s//\\\"/\\\\\\\"} (pattern: \" replacement: \\\")
      T.isInfixOf "s=${s//\\\"" func  -- Has the quote pattern
      && T.isInfixOf "__nix_compile_escape_json" func  -- Has the function

-- | Run all tests
main :: IO ()
main = do
  putStrLn "=== EmitConfig Generator Tests ==="
  results <- sequence
    [ check "JSON output structure" testJsonOutput
    , check "YAML output structure" testYamlOutput
    , check "TOML output structure" testTomlOutput
    , check "Config key validation" testKeyValidation
    , check "Invalid key detection" testInvalidKeyDetection
    , check "JSON escape function" testJsonEscapeInOutput
    ]
  if and results
    then do
      putStrLn "=== All tests passed ==="
      exitSuccess
    else do
      putStrLn "=== Some tests failed ==="
      exitFailure
  where
    check name True = do
      putStrLn $ "  ✓ " ++ name
      return True
    check name False = do
      putStrLn $ "  ✗ " ++ name ++ " FAILED"
      return False
