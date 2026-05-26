{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module NixCompile.Config
  ( Severity (..),
    RuleOverride (..),
    Config (..),
    loadConfig,
    defaultConfig,
    effectiveSeverity,
    configIgnores,
    isIgnored,
    isSuppressed,
    bashRuleId,
    nixRuleId,
    derivRuleId,
    packageRuleId,
    patternRuleId,
  )
where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import Data.Text qualified as T
import Dhall (FromDhall, InterpretOptions (..), defaultInterpretOptions, genericAutoWith)
import Dhall qualified
import GHC.Generics (Generic)
import NixCompile.Lint.Forbidden qualified as Bash
import NixCompile.Nix.Lint qualified as NixLint
import NixCompile.Nix.LintDerivation qualified as Deriv
import NixCompile.Nix.LintPackages qualified as LintPackages
import NixCompile.Nix.LintPatterns qualified as LintPatterns
import System.FilePath qualified as FP

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

data Severity
  = SevOff
  | SevInfo
  | SevWarning
  | SevError
  deriving stock (Eq, Ord, Show, Generic)

instance FromDhall Severity where
  autoWith _norm =
    genericAutoWith
      (defaultInterpretOptions {constructorModifier = T.drop 3})

data RuleOverride = RuleOverride
  { overrideId :: !Text,
    overrideSeverity :: !Severity,
    overrideReason :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance FromDhall RuleOverride where
  autoWith _norm =
    genericAutoWith
      ( defaultInterpretOptions
          { fieldModifier = \case
              "overrideId" -> "id"
              "overrideSeverity" -> "severity"
              "overrideReason" -> "reason"
              n -> n
          }
      )

data Config = Config
  { configProfile :: !Text,
    configExtraIgnores :: ![Text],
    configOverrides :: ![RuleOverride]
  }
  deriving stock (Eq, Show, Generic)

instance FromDhall Config where
  autoWith _norm =
    genericAutoWith
      ( defaultInterpretOptions
          { fieldModifier = \case
              "configProfile" -> "profile"
              "configExtraIgnores" -> "extra-ignores"
              "configOverrides" -> "overrides"
              n -> n
          }
      )

-------------------------------------------------------------------------------
-- Defaults
-------------------------------------------------------------------------------

defaultConfig :: Config
defaultConfig =
  Config
    { configProfile = "standard",
      configExtraIgnores = [],
      configOverrides = []
    }

-------------------------------------------------------------------------------
-- Loading
-------------------------------------------------------------------------------

loadConfig :: FilePath -> IO (Either Text Config)
loadConfig path = do
  result <- try (Dhall.input Dhall.auto (T.pack path))
  case result of
    Left (e :: SomeException) -> pure (Left (T.pack (show e)))
    Right config -> pure (Right config)

-------------------------------------------------------------------------------
-- Queries
-------------------------------------------------------------------------------

effectiveSeverity :: Config -> Text -> Maybe Severity
effectiveSeverity config ruleId =
  case filter ((== ruleId) . overrideId) (configOverrides config) of
    o : _ -> Just (overrideSeverity o)
    [] -> Nothing

configIgnores :: Config -> [Text]
configIgnores = configExtraIgnores

isIgnored :: Config -> FilePath -> Bool
isIgnored config path = any (`matchGlob` npath) (configExtraIgnores config)
  where
    npath = FP.normalise path

isSuppressed :: Config -> Text -> Bool
isSuppressed config ruleId = effectiveSeverity config ruleId == Just SevOff

bashRuleId :: Bash.ViolationType -> Text
bashRuleId = \case
  Bash.VHeredoc -> "no-heredoc-in-inline-bash"
  Bash.VHereString -> "no-heredoc-in-inline-bash"
  Bash.VEval -> "no-eval"
  Bash.VBacktick -> "no-backtick"

nixRuleId :: NixLint.ViolationType -> Text
nixRuleId = \case
  NixLint.VWith -> "with-lib"
  NixLint.VRec -> "rec-anywhere"
  NixLint.VSubstituteAll -> "no-substitute-all"
  NixLint.VRawMkDerivation -> "no-raw-mkderivation"
  NixLint.VRawRunCommand -> "no-raw-runcommand"
  NixLint.VRawWriteShellApplication -> "no-raw-writeshellapplication"
  NixLint.VWriteShellScript -> "prefer-write-shell-application"
  NixLint.VLongInlineString _ -> "long-inline-string"

derivRuleId :: Deriv.DerivViolationType -> Text
derivRuleId = Deriv.derivRuleId

packageRuleId :: LintPackages.PackageViolationCode -> Text
packageRuleId = \case
  LintPackages.P001 -> "default-nix-in-packages"

patternRuleId :: LintPatterns.PatternViolationType -> Text
patternRuleId = \case
  LintPatterns.VOrNullFallback -> "or-null-fallback"
  LintPatterns.VAttrTranslation -> "no-translate-attrs-outside-prelude"

-------------------------------------------------------------------------------
-- Internal: glob matching
-------------------------------------------------------------------------------

data Token
  = GlobStar
  | Star
  | Lit !String
  deriving (Show)

tokenise :: String -> [Token]
tokenise = go
  where
    go [] = []
    go ('*' : '*' : rest) = GlobStar : go rest
    go ('*' : rest) = Star : go rest
    go ('/' : rest) = go rest
    go cs =
      let (lit, rest') = break (`elem` ("*/" :: String)) cs
       in if null lit
            then go rest'
            else Lit lit : go rest'

charMatch :: String -> String -> Bool
charMatch [] [] = True
charMatch ('*' : pat) [] = charMatch pat []
charMatch ('*' : pat) str@(_ : rest) = charMatch pat str || charMatch ('*' : pat) rest
charMatch (c : pat) (d : rest) = c == d && charMatch pat rest
charMatch _ _ = False

tokensToPattern :: [Token] -> String
tokensToPattern [] = []
tokensToPattern (GlobStar : rest) = '*' : '*' : tokensToPattern rest
tokensToPattern (Star : rest) = '*' : tokensToPattern rest
tokensToPattern (Lit l : rest) = l <> tokensToPattern rest

splitComponents :: String -> [[Token]]
splitComponents = map tokenise . splitOn '/'

splitOn :: Char -> String -> [String]
splitOn _ [] = [""]
splitOn c s =
  let (before, after) = break (== c) s
   in before : case after of
        "" -> []
        _ : rest -> splitOn c rest

matchComponents :: [[Token]] -> [String] -> Bool
matchComponents [] [] = True
matchComponents [] _ = False
matchComponents (comp : crest) segs = case comp of
  [] -> matchComponents crest segs
  [GlobStar] -> matchGlobStar crest segs
  pattern ->
    case segs of
      seg : srest -> charMatch (tokensToPattern pattern) seg && matchComponents crest srest
      [] -> False
  where
    matchGlobStar restC [] = matchComponents restC []
    matchGlobStar restC sgs@(_ : _) = matchComponents restC sgs || matchComponents (comp : restC) (drop 1 sgs)

matchGlob :: Text -> FilePath -> Bool
matchGlob pattern fp
  | '/' `elem` pat = matchComponents (splitComponents pat) segs
  | otherwise = any (charMatch pat) segs
  where
    pat = T.unpack pattern
    segs = FP.splitDirectories fp
