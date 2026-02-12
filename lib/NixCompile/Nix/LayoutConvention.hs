{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                       // layout convention
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--     "Wintermute was hive mind, decision maker, effecting change in
--      the world outside."
--
--                                                                 — Neuromancer
--
-- | Directory layout, file naming, and attribute naming convention enforcement.
--
-- Conventions define:
--   * Where files live (directory structure)
--   * What files are called (file naming)
--   * What attributes are called (export naming)
--   * What identifiers are called (code naming)
--
-- The key insight: if everything is a flake module, we get uniform structure.
-- Parse once, analyze everything.
--
module NixCompile.Nix.LayoutConvention
  ( -- * Conventions
    Convention (..)
  , ConventionRule (..)
  , straylight
  , nixpkgsByName
  , flakeParts
  , nixosConfig

    -- * Validation
  , validateLayout
  , validateFile
  , validateAttrName
  , validateIdentifier

    -- * Results
  , LayoutError (..)
  , ErrorCode (..)

    -- * Naming
  , NamingConvention (..)
  , isValidName
  , toKebabCase
  , toSnakeCase
  ) where

import Data.Char (isAlphaNum, isLower, isUpper, toLower)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath (takeFileName, splitDirectories, makeRelative)

import NixCompile.Nix.ModuleKind

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                     // types
-- ══════════════════════════════════════════════════════════════════════════════

-- | A layout convention defines where things should live and what they're called.
data Convention = Convention
  { convName          :: !Text
  , convDescription   :: !Text
  , convRules         :: ![ConventionRule]
  , convFileNaming    :: !NamingConvention   -- ^ File name convention
  , convAttrNaming    :: !NamingConvention   -- ^ Attribute name convention
  , convIdentNaming   :: !NamingConvention   -- ^ Identifier convention
  , convRequireFlakeMod :: !Bool             -- ^ Require everything to be flake module
  } deriving (Eq, Show)

-- | A single rule mapping module kind to expected location.
data ConventionRule = ConventionRule
  { ruleKind        :: !ModuleKind
  , rulePattern     :: !PathPattern
  , ruleForbidden   :: ![PathPattern]
  , ruleExportName  :: !(Maybe Text)  -- ^ Required export path (e.g., "perSystem.packages")
  } deriving (Eq, Show)

-- | Path pattern for matching.
data PathPattern
  = Prefix [String]
  | Contains [String]
  | Exact [String]
  | AnyOf [PathPattern]
  | None
  deriving (Eq, Show)

-- | Naming convention for identifiers.
data NamingConvention
  = KebabCase     -- ^ kebab-case (lisp-case) — straylight
  | SnakeCase     -- ^ snake_case
  | CamelCase     -- ^ camelCase — nixpkgs
  | PascalCase    -- ^ PascalCase
  | NoNaming      -- ^ No enforcement
  deriving (Eq, Show)

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                   // errors
-- ══════════════════════════════════════════════════════════════════════════════

data ErrorCode
  = E001  -- ^ File in wrong location
  | E002  -- ^ File in forbidden location
  | E003  -- ^ Wrong file name convention
  | E004  -- ^ Wrong attribute name convention
  | E005  -- ^ Wrong identifier convention
  | E006  -- ^ Not a flake module (when required)
  | E007  -- ^ Missing required export
  deriving (Eq, Show)

data LayoutError = LayoutError
  { errCode      :: !ErrorCode
  , errPath      :: !FilePath
  , errKind      :: !ModuleKind
  , errMessage   :: !Text
  , errExpected  :: !(Maybe Text)
  } deriving (Eq, Show)

-- ══════════════════════════════════════════════════════════════════════════════
--                                                      // straylight convention
-- ══════════════════════════════════════════════════════════════════════════════

-- | Straylight/aleph convention.
--
-- Everything is a flake module. Uniform structure.
--
-- Structure:
--   nix/
--     modules/
--       flake/      # flake-parts modules → perSystem.*, flake.*
--       nixos/      # NixOS modules → flake.nixosModules.*
--       home/       # home-manager modules → flake.homeModules.*
--       darwin/     # nix-darwin modules → flake.darwinModules.*
--     packages/     # Packages → perSystem.packages.*
--     overlays/     # Overlays → flake.overlays.*
--     lib/          # Library → flake.lib.*
--   flake.nix
--
-- Naming: kebab-case everywhere (files, attrs, identifiers)
--
straylight :: Convention
straylight = Convention
  { convName = "straylight"
  , convDescription = "Straylight/aleph: module layout with kebab-case everywhere"
  , convRules =
      [ ConventionRule
          { ruleKind = FlakeModule
          , rulePattern = Prefix ["nix", "modules", "flake"]
          , ruleForbidden = [Prefix ["nix", "packages"]]
          , ruleExportName = Nothing  -- varies
          }
      , ConventionRule
          { ruleKind = NixOSModule
          , rulePattern = Prefix ["nix", "modules", "nixos"]
          , ruleForbidden = [Prefix ["nix", "packages"]]
          , ruleExportName = Just "flake.nixosModules"
          }
      , ConventionRule
          { ruleKind = HomeModule
          , rulePattern = AnyOf
              [ Prefix ["nix", "modules", "home"]
              , Prefix ["nix", "modules", "home-manager"]
              ]
          , ruleForbidden = [Prefix ["nix", "packages"]]
          , ruleExportName = Just "flake.homeModules"
          }
      , ConventionRule
          { ruleKind = DarwinModule
          , rulePattern = Prefix ["nix", "modules", "darwin"]
          , ruleForbidden = []
          , ruleExportName = Just "flake.darwinModules"
          }
      , ConventionRule
          { ruleKind = Package
          , rulePattern = Prefix ["nix", "packages"]
          , ruleForbidden = [Prefix ["nix", "modules"]]
          , ruleExportName = Just "perSystem.packages"
          }
      , ConventionRule
          { ruleKind = Overlay
          , rulePattern = Prefix ["nix", "overlays"]
          , ruleForbidden = []
          , ruleExportName = Just "flake.overlays"
          }
      , ConventionRule
          { ruleKind = Library
          , rulePattern = Prefix ["nix", "lib"]
          , ruleForbidden = []
          , ruleExportName = Just "flake.lib"
          }
      , ConventionRule
          { ruleKind = Shell
          , rulePattern = Prefix ["nix", "shells"]
          , ruleForbidden = []
          , ruleExportName = Just "perSystem.devShells"
          }
      , ConventionRule
          { ruleKind = Flake
          , rulePattern = Exact ["flake.nix"]
          , ruleForbidden = []
          , ruleExportName = Nothing
          }
      ]
  , convFileNaming = KebabCase
  , convAttrNaming = KebabCase
  , convIdentNaming = KebabCase
  , convRequireFlakeMod = False
  }

-- ══════════════════════════════════════════════════════════════════════════════
--                                                     // other conventions
-- ══════════════════════════════════════════════════════════════════════════════

nixpkgsByName :: Convention
nixpkgsByName = Convention
  { convName = "nixpkgs-by-name"
  , convDescription = "Nixpkgs pkgs/by-name layout"
  , convRules =
      [ ConventionRule
          { ruleKind = Package
          , rulePattern = Prefix ["pkgs", "by-name"]
          , ruleForbidden = []
          , ruleExportName = Nothing
          }
      ]
  , convFileNaming = NoNaming
  , convAttrNaming = CamelCase  -- nixpkgs uses camelCase
  , convIdentNaming = CamelCase
  , convRequireFlakeMod = False
  }

flakeParts :: Convention
flakeParts = Convention
  { convName = "flake-parts"
  , convDescription = "Standard flake-parts layout"
  , convRules =
      [ ConventionRule
          { ruleKind = FlakeModule
          , rulePattern = AnyOf [Prefix ["modules"], Prefix ["flake-modules"]]
          , ruleForbidden = []
          , ruleExportName = Nothing
          }
      , ConventionRule
          { ruleKind = NixOSModule
          , rulePattern = AnyOf [Prefix ["modules", "nixos"], Prefix ["nixos-modules"]]
          , ruleForbidden = []
          , ruleExportName = Just "flake.nixosModules"
          }
      , ConventionRule
          { ruleKind = Package
          , rulePattern = Prefix ["packages"]
          , ruleForbidden = []
          , ruleExportName = Just "perSystem.packages"
          }
      , ConventionRule
          { ruleKind = Overlay
          , rulePattern = Prefix ["overlays"]
          , ruleForbidden = []
          , ruleExportName = Just "flake.overlays"
          }
      ]
  , convFileNaming = NoNaming
  , convAttrNaming = NoNaming
  , convIdentNaming = NoNaming
  , convRequireFlakeMod = False
  }

nixosConfig :: Convention
nixosConfig = Convention
  { convName = "nixos-config"
  , convDescription = "NixOS system configuration layout"
  , convRules =
      [ ConventionRule
          { ruleKind = NixOSModule
          , rulePattern = AnyOf [Prefix ["modules"], Prefix ["hosts"]]
          , ruleForbidden = []
          , ruleExportName = Nothing
          }
      , ConventionRule
          { ruleKind = HomeModule
          , rulePattern = AnyOf [Prefix ["users"], Prefix ["home"]]
          , ruleForbidden = []
          , ruleExportName = Nothing
          }
      ]
  , convFileNaming = NoNaming
  , convAttrNaming = NoNaming
  , convIdentNaming = NoNaming
  , convRequireFlakeMod = False
  }

-- ══════════════════════════════════════════════════════════════════════════════
--                                                           // naming validation
-- ══════════════════════════════════════════════════════════════════════════════

-- | Check if a name is valid for a convention.
isValidName :: NamingConvention -> String -> Bool
isValidName NoNaming _ = True
isValidName KebabCase s = isKebabCase s
isValidName SnakeCase s = isSnakeCase s
isValidName CamelCase s = isCamelCase s
isValidName PascalCase s = isPascalCase s

isKebabCase :: String -> Bool
isKebabCase [] = False
isKebabCase s = all validChar s && not (badPattern s)
  where
    validChar c = isLower c || c >= '0' && c <= '9' || c == '-'
    badPattern x = "--" `isPrefixOf` x || "--" `isSuffixOf` x || "-" `isPrefixOf` x || "-" `isSuffixOf` x

isSnakeCase :: String -> Bool
isSnakeCase [] = False
isSnakeCase s = all validChar s && not (badPattern s)
  where
    validChar c = isLower c || c >= '0' && c <= '9' || c == '_'
    badPattern x = "__" `isPrefixOf` x || "__" `isSuffixOf` x

isCamelCase :: String -> Bool
isCamelCase [] = False
isCamelCase (c:cs) = isLower c && all (\x -> isAlphaNum x) cs

isPascalCase :: String -> Bool
isPascalCase [] = False
isPascalCase (c:cs) = isUpper c && all (\x -> isAlphaNum x) cs

-- | Convert to kebab-case.
toKebabCase :: String -> String
toKebabCase = go False
  where
    go _ [] = []
    go prev (c:cs)
      | isUpper c = (if prev then ['-', toLower c] else [toLower c]) ++ go True cs
      | c == '_' = '-' : go False cs
      | otherwise = c : go (isLower c) cs

-- | Convert to snake_case.
toSnakeCase :: String -> String
toSnakeCase = go False
  where
    go _ [] = []
    go prev (c:cs)
      | isUpper c = (if prev then ['_', toLower c] else [toLower c]) ++ go True cs
      | c == '-' = '_' : go False cs
      | otherwise = c : go (isLower c) cs

-- | Validate an attribute name.
validateAttrName :: Convention -> Text -> Maybe LayoutError
validateAttrName conv name =
  let s = T.unpack name
  in if isValidName (convAttrNaming conv) s
    then Nothing
    else Just $ LayoutError
      { errCode = E004
      , errPath = ""
      , errKind = Unknown
      , errMessage = "Attribute name '" <> name <> "' violates naming convention"
      , errExpected = Just $ T.pack $ suggestName (convAttrNaming conv) s
      }

-- | Validate an identifier.
validateIdentifier :: Convention -> Text -> Maybe LayoutError
validateIdentifier conv name =
  let s = T.unpack name
  in if isValidName (convIdentNaming conv) s
    then Nothing
    else Just $ LayoutError
      { errCode = E005
      , errPath = ""
      , errKind = Unknown
      , errMessage = "Identifier '" <> name <> "' violates naming convention"
      , errExpected = Just $ T.pack $ suggestName (convIdentNaming conv) s
      }

suggestName :: NamingConvention -> String -> String
suggestName KebabCase s = toKebabCase s
suggestName SnakeCase s = toSnakeCase s
suggestName _ s = s

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                // validation
-- ══════════════════════════════════════════════════════════════════════════════

-- | Validate a single file against a convention.
validateFile :: Convention -> FilePath -> FilePath -> Detection -> [LayoutError]
validateFile conv root path detection =
  let relPath = makeRelative root path
      kind = detectedKind detection
      components = splitDirectories relPath
      fileName = takeFileName path
  in concat
    [ validateLocation conv relPath components kind
    , validateForbidden conv relPath components kind
    , validateFileName conv relPath fileName
    , validateFlakeModReq conv relPath kind detection
    ]

-- | Validate multiple files.
validateLayout :: Convention -> FilePath -> [(FilePath, Detection)] -> [LayoutError]
validateLayout conv root files =
  concatMap (\(path, det) -> validateFile conv root path det) files

validateLocation :: Convention -> FilePath -> [String] -> ModuleKind -> [LayoutError]
validateLocation conv relPath components kind =
  case findRuleForKind (convRules conv) kind of
    Nothing -> []
    Just rule ->
      if matchesPattern (rulePattern rule) components
        then []
        else [LayoutError
          { errCode = E001
          , errPath = relPath
          , errKind = kind
          , errMessage = "File in wrong location for " <> T.pack (show kind)
          , errExpected = Just $ patternDescription (rulePattern rule)
          }]

validateForbidden :: Convention -> FilePath -> [String] -> ModuleKind -> [LayoutError]
validateForbidden conv relPath components kind =
  case findRuleForKind (convRules conv) kind of
    Nothing -> []
    Just rule ->
      let violations = filter (`matchesPattern` components) (ruleForbidden rule)
      in map (\pat -> LayoutError
          { errCode = E002
          , errPath = relPath
          , errKind = kind
          , errMessage = "File in forbidden location"
          , errExpected = Just $ "not in " <> patternDescription pat
          }) violations

validateFileName :: Convention -> FilePath -> String -> [LayoutError]
validateFileName conv relPath fileName =
  let baseName = dropNixExtension fileName
  in if isValidName (convFileNaming conv) baseName
    then []
    else [LayoutError
      { errCode = E003
      , errPath = relPath
      , errKind = Unknown
      , errMessage = "File name violates naming convention"
      , errExpected = Just $ T.pack $ suggestName (convFileNaming conv) baseName <> ".nix"
      }]

validateFlakeModReq :: Convention -> FilePath -> ModuleKind -> Detection -> [LayoutError]
validateFlakeModReq conv relPath kind _detection =
  if convRequireFlakeMod conv && kind /= Flake && kind /= FlakeModule && kind /= Unknown
    then [LayoutError
      { errCode = E006
      , errPath = relPath
      , errKind = kind
      , errMessage = "File must be a flake module (convention requires uniform structure)"
      , errExpected = Just "flake-parts module structure"
      }]
    else []

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                   // helpers
-- ══════════════════════════════════════════════════════════════════════════════

findRuleForKind :: [ConventionRule] -> ModuleKind -> Maybe ConventionRule
findRuleForKind rules kind =
  case filter ((== kind) . ruleKind) rules of
    (r:_) -> Just r
    [] -> Nothing

matchesPattern :: PathPattern -> [String] -> Bool
matchesPattern None _ = True
matchesPattern (Exact expected) actual = actual == expected
matchesPattern (Prefix expected) actual = expected `isPrefixOf` actual
matchesPattern (Contains expected) actual = any (`elem` actual) expected
matchesPattern (AnyOf patterns) actual = any (`matchesPattern` actual) patterns

patternDescription :: PathPattern -> Text
patternDescription None = "anywhere"
patternDescription (Exact comps) = T.pack $ joinPath comps
patternDescription (Prefix comps) = T.pack $ joinPath comps <> "/..."
patternDescription (Contains comps) = "containing " <> T.pack (show comps)
patternDescription (AnyOf pats) = T.intercalate " or " (map patternDescription pats)

joinPath :: [String] -> String
joinPath = foldr1 (\a b -> a ++ "/" ++ b)

dropNixExtension :: String -> String
dropNixExtension s
  | ".nix" `isSuffixOf` s = take (length s - 4) s
  | otherwise = s
