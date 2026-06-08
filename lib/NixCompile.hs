{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // nix // compile // api
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "As her fingers closed around the cool brass knob, it seemed to squirm,
--    sliding along a touch spectrum of texture and temperature in the first
--    second of contact. Then it became metal again, green-painted iron,
--    sweeping out and down, along a line of perspective, an old railing she
--    grasped now in wonder. A few drops of rain blew into her face."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                          // top-level // api
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile (
  -- * Parsing
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

  -- * Config
  Config.Config (..),
  Config.RuleOverride (..),
  Config.loadConfig,
  Config.defaultConfig,
  Config.effectiveSeverity,
  Config.configIgnores,
  Config.isIgnored,
  Config.isSuppressed,
  Config.bashRuleId,
  Config.nixRuleId,
  Config.derivRuleId,

  -- * Re-exports
  module NixCompile.Types,
)
where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import NixCompile.Bash.Facts (extractFacts)
import NixCompile.Bash.Parse (parseBash, parseBashWithFilename)
import NixCompile.Config qualified as Config
import NixCompile.Infer.Constraint (factsToConstraints)
import NixCompile.Infer.Unify (solve)
import NixCompile.Schema.Build (buildSchema, validateConfigPaths)
import NixCompile.Types

{- | Parse a bash script and extract its schema.

This variant has no filename context, so spans in the returned 'Script'
will have 'spanFile = Nothing'.
-}
parseScript :: Text -> Either Text Script
parseScript = parseScriptWithFile Nothing

{- | Parse a bash script file.

When parsing from a file, we propagate the file path into 'Span's
(best-effort; bash spans are still "token id" based).
-}
parseScriptFile :: FilePath -> IO (Either Text Script)
parseScriptFile path = do
  result <- try (TIO.readFile path)
  case result of
    Left (e :: IOException) -> return $ Left $ T.pack $ show e
    Right src -> return (parseScriptWithFile (Just path) src)

-- | Internal worker that allows attaching a file path to spans.
parseScriptWithFile :: Maybe FilePath -> Text -> Either Text Script
parseScriptWithFile mFile src = do
  ast <- case mFile of
    Nothing -> parseBash src
    Just file -> parseBashWithFilename file src
  let facts0 = extractFacts ast
      facts = attachFileToFacts mFile facts0
      constraints = factsToConstraints facts
  validateConfigPaths facts
  subst <- case solve constraints of
    Left err -> Left (T.pack (show err))
    Right s -> Right s
  let schema = buildSchema facts subst
  Right
    Script
      { scriptSource = src
      , scriptFacts = facts
      , scriptSchema = schema
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
  ConfigTemplate p parts q sp -> ConfigTemplate p parts q (attachFileToSpan mFile sp)
  CmdArg c a v sp -> CmdArg c a v (attachFileToSpan mFile sp)
  UsesStorePath p sp -> UsesStorePath p (attachFileToSpan mFile sp)
  BareCommand c sp -> BareCommand c (attachFileToSpan mFile sp)
  DynamicCommand v sp -> DynamicCommand v (attachFileToSpan mFile sp)

attachFileToSpan :: Maybe FilePath -> Span -> Span
attachFileToSpan Nothing sp = sp
attachFileToSpan (Just file) sp = sp{spanFile = Just file}
