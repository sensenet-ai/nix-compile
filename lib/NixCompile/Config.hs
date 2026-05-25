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
import System.FilePath qualified as FP

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

data Severity
  = SevError
  | SevWarning
  | SevInfo
  | SevOff
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
    go cs =
      let (lit, rest) = break (`elem` ("*" :: String)) cs
       in if null lit then go rest else Lit lit : go rest

charMatch :: String -> String -> Bool
charMatch [] [] = True
charMatch ('*' : pat) [] = all (== '*') pat
charMatch ('*' : pat) (_ : rest) = charMatch pat rest || charMatch ('*' : pat) rest
charMatch (c : pat) (d : rest) = c == d && charMatch pat rest
charMatch _ _ = False

matchSegments :: [Token] -> [String] -> Bool
matchSegments [] [] = True
matchSegments [GlobStar] _ = True
matchSegments (GlobStar : rest) segs =
  any (matchSegments rest) (tails segs)
matchSegments (Star : rest) (_ : segs) = matchSegments rest segs
matchSegments (Lit l : rest) (s : segs) = charMatch l s && matchSegments rest segs
matchSegments _ _ = False

matchGlob :: Text -> FilePath -> Bool
matchGlob pattern fp =
  let pat = T.unpack pattern
      segs = FP.splitDirectories fp
   in if '/' `elem` pat
        then matchSegments (tokenise pat) segs
        else any (charMatch pat) segs

tails :: [a] -> [[a]]
tails [] = [[]]
tails xs@(_ : xt) = xs : tails xt
