{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // nix // compile // config
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Credit me with a certain talent for obtaining desired results."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // config // dhall
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Config (
    Severity (..),
    RuleOverride (..),
    Config (..),
    loadConfig,
    defaultConfig,
    effectiveSeverity,
    effectiveLayout,
    configIgnores,
    isIgnored,
    isSuppressed,
    bashRuleId,
    nixRuleId,
    derivRuleId,
    packageRuleId,
    patternRuleId,
    typeCheckRuleId,
)
where

import Control.Exception (SomeException, try)
import GHC.Generics (Generic)

import Data.Text (Text)
import Data.Text qualified as T
import Dhall (FromDhall, InterpretOptions (..), defaultInterpretOptions, genericAutoWith)
import Dhall qualified
import System.FilePath qualified as FP

import NixCompile.Lint.Forbidden qualified as Bash
import NixCompile.Nix.LayoutConvention (Convention, layoutFromName)
import NixCompile.Nix.Lint qualified as NixLint
import NixCompile.Nix.LintDerivation qualified as Deriv
import NixCompile.Nix.LintPackages qualified as LintPackages
import NixCompile.Nix.LintPatterns qualified as LintPatterns

-- ────────────────────────────────────────────────────────────────────────────
-- Types
-- ────────────────────────────────────────────────────────────────────────────

data Severity
    = SevOff
    | SevInfo
    | SevWarning
    | SevError
    deriving stock (Eq, Ord, Show, Generic)

instance FromDhall Severity where
    autoWith _norm =
        genericAutoWith
            (defaultInterpretOptions{constructorModifier = T.drop 3})

data RuleOverride = RuleOverride
    { overrideId :: !Text
    , overrideSeverity :: !Severity
    , overrideReason :: !(Maybe Text)
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
    { configProfile :: !Text
    , configLayout :: !Text
    , configExtraIgnores :: ![Text]
    , configOverrides :: ![RuleOverride]
    }
    deriving stock (Eq, Show, Generic)

instance FromDhall Config where
    autoWith _norm =
        genericAutoWith
            ( defaultInterpretOptions
                { fieldModifier = \case
                    "configProfile" -> "profile"
                    "configLayout" -> "layout"
                    "configExtraIgnores" -> "extra-ignores"
                    "configOverrides" -> "overrides"
                    n -> n
                }
            )

-- ────────────────────────────────────────────────────────────────────────────
-- Defaults
-- ────────────────────────────────────────────────────────────────────────────

defaultConfig :: Config
defaultConfig =
    Config
        { configProfile = "standard"
        , configLayout = "straylight"
        , configExtraIgnores = []
        , configOverrides = []
        }

-- ────────────────────────────────────────────────────────────────────────────
-- Queries
-- ────────────────────────────────────────────────────────────────────────────

effectiveLayout :: Config -> Convention
effectiveLayout = layoutFromName . configLayout

-- ────────────────────────────────────────────────────────────────────────────
-- Loading
-- ────────────────────────────────────────────────────────────────────────────

loadConfig :: FilePath -> IO (Either Text Config)
loadConfig path = do
    result <- try (Dhall.inputFile Dhall.auto path)
    case result of
        Left (e :: SomeException) -> pure (Left (T.pack (show e)))
        Right config -> pure (Right config)

-- ────────────────────────────────────────────────────────────────────────────
-- Queries
-- ────────────────────────────────────────────────────────────────────────────

effectiveSeverity :: Config -> Text -> Maybe Severity
effectiveSeverity config ruleId =
    case filter ((== ruleId) . overrideId) (configOverrides config) of
        override : _ -> Just (overrideSeverity override)
        [] -> Nothing

configIgnores :: Config -> [Text]
configIgnores = configExtraIgnores

isIgnored :: Config -> FilePath -> Bool
isIgnored config filePath = any (`matchGlob` normalisedPath) (configExtraIgnores config)
  where
    normalisedPath = FP.normalise filePath

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

typeCheckRuleId :: Text
typeCheckRuleId = "type-check-failure"

-- ────────────────────────────────────────────────────────────────────────────
-- Internal: glob matching
-- ────────────────────────────────────────────────────────────────────────────

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
    go chars =
        let (literal, rest') = break (`elem` ("*/" :: String)) chars
         in if null literal
                then go rest'
                else Lit literal : go rest'

charMatch :: String -> String -> Bool
charMatch [] [] = True
charMatch ('*' : pat) [] = charMatch pat []
charMatch ('*' : pat) string@(_ : rest) = charMatch pat string || charMatch ('*' : pat) rest
charMatch (char : pat) (otherChar : rest) = char == otherChar && charMatch pat rest
charMatch _ _ = False

tokensToPattern :: [Token] -> String
tokensToPattern [] = []
tokensToPattern (GlobStar : rest) = '*' : '*' : tokensToPattern rest
tokensToPattern (Star : rest) = '*' : tokensToPattern rest
tokensToPattern (Lit literal : rest) = literal <> tokensToPattern rest

splitComponents :: String -> [[Token]]
splitComponents = map tokenise . splitOn '/'

splitOn :: Char -> String -> [String]
splitOn _ [] = [""]
splitOn delimiter string =
    let (before, after) = break (== delimiter) string
     in before : case after of
            "" -> []
            _ : rest -> splitOn delimiter rest

matchComponents :: [[Token]] -> [String] -> Bool
matchComponents [] [] = True
matchComponents [] _ = False
matchComponents (component : remainingComponents) segments
    | null component = matchComponents remainingComponents segments
    | [GlobStar] <- component = matchGlobStar remainingComponents segments
    | segment : remainingSegments <- segments =
        charMatch (tokensToPattern component) segment
            && matchComponents remainingComponents remainingSegments
    | otherwise = False
  where
    matchGlobStar remainingComponentPatterns [] =
        matchComponents remainingComponentPatterns []
    matchGlobStar remainingComponentPatterns globSegments@(_ : _) =
        matchComponents remainingComponentPatterns globSegments
            || matchComponents (component : remainingComponentPatterns) (drop 1 globSegments)

matchGlob :: Text -> FilePath -> Bool
matchGlob patternText filePath
    | '/' `elem` globPattern = matchComponents (splitComponents globPattern) segments
    | otherwise = any (charMatch globPattern) segments
  where
    globPattern = T.unpack patternText
    segments = FP.splitDirectories filePath
