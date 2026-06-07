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

{- | Directory layout, file naming, and attribute naming convention enforcement.

Conventions define:
  * Where files live (directory structure)
  * What files are called (file naming)
  * What attributes are called (export naming)
  * What identifiers are called (code naming)

The key insight: if everything is a flake module, we get uniform structure.
Parse once, analyze everything.
-}
module NixCompile.Nix.LayoutConvention (
    -- * Conventions
    Convention (..),
    ConventionRule (..),
    straylight,
    nixpkgsByName,
    flakeParts,
    nixosConfig,
    allFlakeModule,

    -- * Validation
    validateLayout,
    validateFile,
    validateFileExpr,
    validateFileFromExpr,
    validateAttrName,
    validateIdentifier,

    -- * Convention lookup
    layoutFromName,

    -- * Universal checks
    isIndexFile,
    isMainFile,
    checkBannedFiles,
    checkClassAttr,

    -- * Results
    LayoutError (..),
    ErrorCode (..),

    -- * Naming
    NamingConvention (..),
    isValidName,
    toKebabCase,
    toSnakeCase,
    dropNixExtension,
)
where

import Data.Char (isAlphaNum, isLower, isUpper, toLower)
import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.List (isPrefixOf, isSuffixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import Nix.Utils qualified as NixPath
import NixCompile.Nix.ModuleKind
import NixCompile.Types (Loc (..), Span (..))
import System.FilePath (makeRelative, splitDirectories, takeFileName)

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                     // types
-- ══════════════════════════════════════════════════════════════════════════════

-- | A layout convention defines where things should live and what they're called.
data Convention = Convention
    { convName :: !Text
    , convDescription :: !Text
    , convRules :: ![ConventionRule]
    , convFileNaming :: !NamingConvention
    -- ^ File name convention
    , convAttrNaming :: !NamingConvention
    -- ^ Attribute name convention
    , convIdentNaming :: !NamingConvention
    -- ^ Identifier convention
    , convRequireFlakeMod :: !Bool
    -- ^ Require everything to be flake module
    }
    deriving (Eq, Show)

-- | A single rule mapping module kind to expected location.
data ConventionRule = ConventionRule
    { ruleKind :: !ModuleKind
    , rulePattern :: !PathPattern
    , ruleForbidden :: ![PathPattern]
    , ruleExportName :: !(Maybe Text)
    -- ^ Required export path (e.g., "perSystem.packages")
    }
    deriving (Eq, Show)

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
    = -- | kebab-case (lisp-case) — straylight
      KebabCase
    | -- | snake_case
      SnakeCase
    | -- | camelCase — nixpkgs
      CamelCase
    | -- | PascalCase
      PascalCase
    | -- | No enforcement
      NoNaming
    deriving (Eq, Show)

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                   // errors
-- ══════════════════════════════════════════════════════════════════════════════

data ErrorCode
    = -- | File in wrong location for its module kind
      E001
    | -- | File in forbidden location
      E002
    | -- | Wrong file name convention
      E003
    | -- | Wrong attribute name convention
      E004
    | -- | Wrong identifier convention
      E005
    | -- | Must be flake module but isn't
      E006
    | -- | _index.nix files are banned
      E007
    | -- | _main.nix files are banned
      E008
    | -- | Missing required _class attribute
      E009
    | -- | _class value doesn't match location
      E010
    deriving (Eq, Show)

data LayoutError = LayoutError
    { errCode :: !ErrorCode
    , errPath :: !FilePath
    , errKind :: !ModuleKind
    , errMessage :: !Text
    , errExpected :: !(Maybe Text)
    }
    deriving (Eq, Show)

-- ══════════════════════════════════════════════════════════════════════════════
--                                                      // straylight convention
-- ══════════════════════════════════════════════════════════════════════════════

{- | Straylight/aleph convention.

Everything is a flake module. Uniform structure.

Structure:
  nix/
    modules/
      flake/      # flake-parts modules → perSystem.*, flake.*
      nixos/      # NixOS modules → flake.nixosModules.*
      home/       # home-manager modules → flake.homeModules.*
      darwin/     # nix-darwin modules → flake.darwinModules.*
    packages/     # Packages → perSystem.packages.*
    overlays/     # Overlays → flake.overlays.*
    lib/          # Library → flake.lib.*
  flake.nix

Naming: kebab-case everywhere (files, attrs, identifiers)
-}
straylight :: Convention
straylight =
    Convention
        { convName = "straylight"
        , convDescription = "Straylight/aleph: module layout with kebab-case everywhere"
        , convRules =
            [ ConventionRule
                { ruleKind = FlakeModule
                , rulePattern = Prefix ["nix", "modules", "flake"]
                , ruleForbidden = [Prefix ["nix", "packages"]]
                , ruleExportName = Nothing -- varies
                }
            , ConventionRule
                { ruleKind = NixOSModule
                , rulePattern = Prefix ["nix", "modules", "nixos"]
                , ruleForbidden = [Prefix ["nix", "packages"]]
                , ruleExportName = Just "flake.nixosModules"
                }
            , ConventionRule
                { ruleKind = HomeModule
                , rulePattern =
                    AnyOf
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
nixpkgsByName =
    Convention
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
        , convAttrNaming = CamelCase -- nixpkgs uses camelCase
        , convIdentNaming = CamelCase
        , convRequireFlakeMod = False
        }

flakeParts :: Convention
flakeParts =
    Convention
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
nixosConfig =
    Convention
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

{- | The all-flake-module convention (modeled on github:nixified-ai/flake):
every .nix under flake-modules/ is a flake-parts module wiring its children
via `imports`, with leaf package.nix derivations. Requires every recognized
file to be a flake module or a package (convRequireFlakeMod).
-}
allFlakeModule :: Convention
allFlakeModule =
    Convention
        { convName = "all-flake-module"
        , convDescription = "Every .nix is a flake-parts module under flake-modules/ (nixified-ai)"
        , convRules =
            [ ConventionRule
                { ruleKind = FlakeModule
                , rulePattern = Prefix ["flake-modules"]
                , ruleForbidden = []
                , ruleExportName = Nothing
                }
            , ConventionRule
                { ruleKind = Package
                , rulePattern = Prefix ["flake-modules"]
                , ruleForbidden = []
                , ruleExportName = Nothing
                }
            ]
        , convFileNaming = NoNaming
        , convAttrNaming = NoNaming
        , convIdentNaming = NoNaming
        , convRequireFlakeMod = True
        }

-- | Look up a convention by name. Defaults to 'straylight' if unrecognised.
layoutFromName :: Text -> Convention
layoutFromName = \case
    "straylight" -> straylight
    "nixpkgs-by-name" -> nixpkgsByName
    "flake-parts" -> flakeParts
    "nixos-config" -> nixosConfig
    "all-flake-module" -> allFlakeModule
    _ -> straylight

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
isCamelCase (c : cs) = isLower c && all (\x -> isAlphaNum x) cs

isPascalCase :: String -> Bool
isPascalCase [] = False
isPascalCase (c : cs) = isUpper c && all (\x -> isAlphaNum x) cs

-- | Convert to kebab-case.
toKebabCase :: String -> String
toKebabCase = go False
  where
    go _ [] = []
    go prev (c : cs)
        | isUpper c = (if prev then ['-', toLower c] else [toLower c]) ++ go True cs
        | c == '_' = '-' : go False cs
        | otherwise = c : go (isLower c) cs

-- | Convert to snake_case.
toSnakeCase :: String -> String
toSnakeCase = go False
  where
    go _ [] = []
    go prev (c : cs)
        | isUpper c = (if prev then ['_', toLower c] else [toLower c]) ++ go True cs
        | c == '-' = '_' : go False cs
        | otherwise = c : go (isLower c) cs

-- | Validate an attribute name.
validateAttrName :: Convention -> Text -> Maybe LayoutError
validateAttrName conv name =
    let s = T.unpack name
     in if isValidName (convAttrNaming conv) s
            then Nothing
            else
                Just $
                    LayoutError
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
            else
                Just $
                    LayoutError
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
--                                                     // universal checks
-- ══════════════════════════════════════════════════════════════════════════════
-- Checks that apply regardless of convention: banned file names, _class
-- attribute validation.

isIndexFile :: FilePath -> Bool
isIndexFile path = takeFileName path == "_index.nix"

isMainFile :: FilePath -> Bool
isMainFile path = takeFileName path == "_main.nix"

checkBannedFiles :: FilePath -> [LayoutError]
checkBannedFiles path
    | isIndexFile path =
        [ LayoutError
            { errCode = E007
            , errPath = path
            , errKind = Unknown
            , errMessage = "_index.nix files are banned; module graph is derived from directory structure"
            , errExpected = Nothing
            }
        ]
    | isMainFile path =
        [ LayoutError
            { errCode = E008
            , errPath = path
            , errKind = Unknown
            , errMessage = "_main.nix files are banned; use explicit imports in flake.nix"
            , errExpected = Nothing
            }
        ]
    | otherwise = []

classForPath :: FilePath -> Maybe Text
classForPath path = findClass (splitDirectories path)
  where
    findClass (x : y : _)
        | x == "modules" = classForDir (dropSlash y)
    findClass (_ : rest) = findClass rest
    findClass [] = Nothing
    dropSlash s
        | "/" `isSuffixOf` s = dropSlash (take (length s - 1) s)
        | otherwise = s
    classForDir = \case
        "flake" -> Just "flake"
        "nixos" -> Just "nixos"
        "home" -> Just "home"
        "home-manager" -> Just "home"
        "darwin" -> Just "darwin"
        _ -> Nothing

findClassAttrWithSpan :: NExprLoc -> Maybe (Text, Span)
findClassAttrWithSpan = go
  where
    go (Fix (Compose (AnnUnit _ e))) = case e of
        NSet _ bindings -> findInBindings bindings
        NAbs _ body -> go body
        NLet _ body -> go body
        NWith _ body -> go body
        _ -> Nothing
    findInBindings bindings =
        let classes = mapMaybe extractClass bindings
         in listToMaybe classes
    extractClass :: Binding NExprLoc -> Maybe (Text, Span)
    extractClass = \case
        NamedVar (StaticKey name :| []) valExpr _
            | varNameText name == "_class" -> extractStringValue valExpr
        _ -> Nothing
    extractStringValue :: NExprLoc -> Maybe (Text, Span)
    extractStringValue (Fix (Compose (AnnUnit srcSpan e'))) = case e' of
        NStr (DoubleQuoted [Plain t]) -> Just (t, toSpan srcSpan)
        NStr (Indented _ [Plain t]) -> Just (t, toSpan srcSpan)
        _ -> Nothing
    varNameText :: VarName -> Text
    varNameText = coerce

toSpan :: SrcSpan -> Span
toSpan srcSpan =
    let begin = getSpanBegin srcSpan
        end = getSpanEnd srcSpan
     in Span
            { spanStart = Loc (srcPosLine begin) (srcPosCol begin)
            , spanEnd = Loc (srcPosLine end) (srcPosCol end)
            , spanFile = case begin of
                NSourcePos path _ _ -> Just (coerce path)
            }
  where
    srcPosLine (NSourcePos _ (NPos l) _) = fromIntegral (unPos l)
    srcPosCol (NSourcePos _ _ (NPos c)) = fromIntegral (unPos c)

checkClassAttr :: FilePath -> NExprLoc -> [LayoutError]
checkClassAttr path expr = case classForPath path of
    Nothing -> []
    Just expected ->
        case findClassAttrWithSpan expr of
            Nothing ->
                [ LayoutError
                    { errCode = E009
                    , errPath = path
                    , errKind = Unknown
                    , errMessage = "Module missing _class attribute; expected _class = \"" <> expected <> "\""
                    , errExpected = Just expected
                    }
                ]
            Just (actual, _sp)
                | actual /= expected ->
                    [ LayoutError
                        { errCode = E010
                        , errPath = path
                        , errKind = Unknown
                        , errMessage = "Wrong _class: got \"" <> actual <> "\", expected \"" <> expected <> "\""
                        , errExpected = Just expected
                        }
                    ]
                | otherwise -> []

{- | Validate a file with its parsed AST, running universal checks only.
For use by the module graph builder which already has the AST.
-}
validateFileExpr :: FilePath -> NExprLoc -> [LayoutError]
validateFileExpr path expr =
    concat
        [ checkBannedFiles path
        , checkClassAttr path expr
        ]

{- | Full validation: convention-specific rules plus universal checks.
Takes the project root for relative path computation.
-}
validateFileFromExpr :: Convention -> FilePath -> FilePath -> NExprLoc -> [LayoutError]
validateFileFromExpr conv root path expr =
    validateFile conv root path (detectKind path expr)
        ++ checkClassAttr path expr

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
            [ checkBannedFiles path
            , validateLocation conv relPath components kind
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
                else
                    [ LayoutError
                        { errCode = E001
                        , errPath = relPath
                        , errKind = kind
                        , errMessage = "File in wrong location for " <> T.pack (show kind)
                        , errExpected = Just $ patternDescription (rulePattern rule)
                        }
                    ]

validateForbidden :: Convention -> FilePath -> [String] -> ModuleKind -> [LayoutError]
validateForbidden conv relPath components kind =
    case findRuleForKind (convRules conv) kind of
        Nothing -> []
        Just rule ->
            let violations = filter (`matchesPattern` components) (ruleForbidden rule)
             in map
                    ( \pat ->
                        LayoutError
                            { errCode = E002
                            , errPath = relPath
                            , errKind = kind
                            , errMessage = "File in forbidden location"
                            , errExpected = Just $ "not in " <> patternDescription pat
                            }
                    )
                    violations

validateFileName :: Convention -> FilePath -> String -> [LayoutError]
validateFileName conv relPath fileName =
    let baseName = dropNixExtension fileName
     in if isValidName (convFileNaming conv) baseName
            then []
            else
                [ LayoutError
                    { errCode = E003
                    , errPath = relPath
                    , errKind = Unknown
                    , errMessage = "File name violates naming convention"
                    , errExpected = Just $ T.pack $ suggestName (convFileNaming conv) baseName <> ".nix"
                    }
                ]

validateFlakeModReq :: Convention -> FilePath -> ModuleKind -> Detection -> [LayoutError]
validateFlakeModReq conv relPath kind _detection =
    -- Under a uniform-structure convention every recognized file must be a flake
    -- module, the flake itself, or a package.nix leaf; anything else (a stray
    -- NixOS module, overlay, bare attrset, or raw expression) is rejected.
    if convRequireFlakeMod conv && kind `notElem` [Flake, FlakeModule, Package]
        then
            [ LayoutError
                { errCode = E006
                , errPath = relPath
                , errKind = kind
                , errMessage = "File must be a flake module or package (convention requires uniform structure)"
                , errExpected = Just "flake-parts module or package.nix"
                }
            ]
        else []

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                   // helpers
-- ══════════════════════════════════════════════════════════════════════════════

findRuleForKind :: [ConventionRule] -> ModuleKind -> Maybe ConventionRule
findRuleForKind rules kind =
    case filter ((== kind) . ruleKind) rules of
        (r : _) -> Just r
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
