{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : NixCompile
-- Description : Top-level API for nix-compile
--
-- Shell scripts as data structures.
--
-- @
-- import NixCompile
--
-- main = do
--   script <- parseScript "PORT=\"\${PORT:-8080}\"\nconfig.server.port=\$PORT"
--   print (scriptSchema script)
-- @
module NixCompile
  ( -- * Parsing
    parseScript,
    parseScriptFile,

    -- * Schema
    Schema (..),
    EnvSpec (..),
    ConfigSpec (..),
    CommandSpec (..),

    -- * Types
    Type (..),
    Literal (..),
    StorePath (..),

    -- * Errors
    TypeError (..),
    LintError (..),
    Severity (..),

    -- * Re-exports
    module NixCompile.Types,
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import NixCompile.Types
import NixCompile.Bash.Parse (parseBash, parseBashWithFilename)
import NixCompile.Bash.Facts (extractFacts)
import NixCompile.Infer.Constraint (factsToConstraints)
import NixCompile.Infer.Unify (solve)
import NixCompile.Schema.Build (buildSchema)

-- | Parse a bash script and extract its schema.
--
-- This variant has no filename context, so spans in the returned 'Script'
-- will have 'spanFile = Nothing'.
parseScript :: Text -> Either Text Script
parseScript = parseScriptWithFile Nothing

-- | Parse a bash script file.
--
-- When parsing from a file, we propagate the file path into 'Span's
-- (best-effort; bash spans are still "token id" based).
parseScriptFile :: FilePath -> IO (Either Text Script)
parseScriptFile path = do
  src <- TIO.readFile path
  return (parseScriptWithFile (Just path) src)

-- | Internal worker that allows attaching a file path to spans.
parseScriptWithFile :: Maybe FilePath -> Text -> Either Text Script
parseScriptWithFile mFile src = do
  ast <- case mFile of
    Nothing -> parseBash src
    Just file -> parseBashWithFilename file src
  let facts0 = extractFacts ast
      facts = attachFileToFacts mFile facts0
      constraints = factsToConstraints facts
  subst <- case solve constraints of
    Left err -> Left (T.pack (show err))
    Right s -> Right s
  let schema = buildSchema facts subst
  Right Script
    { scriptSource = src,
      scriptFacts = facts,
      scriptSchema = schema
    }

-- | Propagate a file path into all spans, for more useful diagnostics.
attachFileToFacts :: Maybe FilePath -> [Fact] -> [Fact]
attachFileToFacts mFile = map (attachFileToFact mFile)

attachFileToFact :: Maybe FilePath -> Fact -> Fact
attachFileToFact mFile = \case
  DefaultIs v lit sp -> DefaultIs v lit (attachFileToSpan mFile sp)
  DefaultFrom v o sp -> DefaultFrom v o (attachFileToSpan mFile sp)
  Required v sp -> Required v (attachFileToSpan mFile sp)
  AssignFrom v o sp -> AssignFrom v o (attachFileToSpan mFile sp)
  AssignLit v lit sp -> AssignLit v lit (attachFileToSpan mFile sp)
  ConfigAssign p v q sp -> ConfigAssign p v q (attachFileToSpan mFile sp)
  ConfigLit p lit sp -> ConfigLit p lit (attachFileToSpan mFile sp)
  CmdArg c a v sp -> CmdArg c a v (attachFileToSpan mFile sp)
  UsesStorePath p sp -> UsesStorePath p (attachFileToSpan mFile sp)
  BareCommand c sp -> BareCommand c (attachFileToSpan mFile sp)
  DynamicCommand v sp -> DynamicCommand v (attachFileToSpan mFile sp)

attachFileToSpan :: Maybe FilePath -> Span -> Span
attachFileToSpan Nothing sp = sp
attachFileToSpan (Just file) sp = sp {spanFile = Just file}

