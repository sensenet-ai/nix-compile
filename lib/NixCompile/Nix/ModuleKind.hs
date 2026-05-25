{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                              // module kind
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--     "He'd found her, one rainy night, in an arcade."
--
--                                                                 — Neuromancer
--
-- | Detect what kind of Nix module a file is by parsing its structure.
--
-- Module kinds:
--
--   * 'NixOSModule' — { config, lib, pkgs, ... }: { options = ...; config = ...; }
--   * 'HomeModule' — Same structure, for home-manager
--   * 'Package' — { lib, stdenv, ... }: stdenv.mkDerivation { ... }
--   * 'Overlay' — final: prev: { ... }
--   * 'FlakeModule' — flake-parts module
--   * 'Library' — { lib }: { ... } (exports functions)
--   * 'Flake' — The flake.nix file itself
--   * 'Unknown' — Could not determine
--
module NixCompile.Nix.ModuleKind
  ( -- * Types
    ModuleKind (..)
  , Detection (..)

    -- * Detection
  , detectKind
  , detectKindFromFile
  , detectClassValue

    -- * Queries
  , isNixOSModule
  , isPackage
  , isOverlay
  , isFlakeModule
  ) where

import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import System.FilePath (takeFileName)

import NixCompile.Nix.Parse (parseNix)

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                     // types
-- ══════════════════════════════════════════════════════════════════════════════

-- | The kind of Nix module.
data ModuleKind
  = NixOSModule      -- ^ NixOS configuration module
  | HomeModule       -- ^ home-manager module
  | DarwinModule     -- ^ nix-darwin module
  | Package          -- ^ Derivation/package definition
  | Overlay          -- ^ Nixpkgs overlay (final: prev: ...)
  | FlakeModule      -- ^ flake-parts module
  | FlakePart        -- ^ Part of a flake (perSystem, etc.)
  | Library          -- ^ Library of functions
  | Flake            -- ^ flake.nix itself
  | Shell            -- ^ devShell or shell.nix
  | Test             -- ^ Test file
  | Unknown          -- ^ Could not determine
  deriving (Eq, Show, Ord)

-- | Detection result with confidence and evidence.
data Detection = Detection
  { detectedKind   :: !ModuleKind
  , detectedConf   :: !Int          -- ^ 0-100 confidence
  , detectedEvidence :: ![Text]     -- ^ Why we think this
  } deriving (Eq, Show)

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                 // detection
-- ══════════════════════════════════════════════════════════════════════════════

-- | Detect module kind from file path and content.
detectKindFromFile :: FilePath -> IO Detection
detectKindFromFile path = do
  content <- TIO.readFile path
  case parseNix path content of
    Left _ -> pure $ Detection Unknown 0 ["parse failed"]
    Right expr -> pure $ detectKind path expr

-- | Detect module kind from parsed expression.
detectKind :: FilePath -> NExprLoc -> Detection
detectKind path expr =
  case detectClassValue expr of
    Just cls ->
      case classToKind cls of
        Just kind -> Detection kind 100 ["_class = \"" <> cls <> "\""]
        Nothing -> Detection Unknown 0 ["unknown _class = \"" <> cls <> "\""]
    Nothing ->
      let fileName = takeFileName path
          -- Check filename first
          fileHints = detectFromFileName fileName
          -- Then check structure
          structHints = detectFromStructure expr
          -- Combine evidence
          allHints = fileHints ++ structHints
          -- Pick best match
      in selectBest allHints

-- | Extract the declared _class attribute, if present.
detectClassValue :: NExprLoc -> Maybe Text
detectClassValue = go
  where
    go (Fix (Compose (AnnUnit _ e))) = case e of
      NSet _ bindings -> findInBindings bindings
      NAbs _ body -> go body
      NLet _ body -> go body
      NWith _ body -> go body
      _ -> Nothing

    findInBindings bindings = listToMaybe (mapMaybe extractClass bindings)

    extractClass :: Binding NExprLoc -> Maybe Text
    extractClass = \case
      NamedVar (StaticKey name :| []) valExpr _
        | varNameText name == "_class" -> extractStringValue valExpr
      _ -> Nothing

    extractStringValue :: NExprLoc -> Maybe Text
    extractStringValue (Fix (Compose (AnnUnit _ e))) = case e of
      NStr (DoubleQuoted [Plain t]) -> Just t
      NStr (Indented _ [Plain t]) -> Just t
      _ -> Nothing

    varNameText :: VarName -> Text
    varNameText = coerce

classToKind :: Text -> Maybe ModuleKind
classToKind cls = case cls of
  "flake" -> Just FlakeModule
  "nixos" -> Just NixOSModule
  "home" -> Just HomeModule
  "homeManager" -> Just HomeModule
  "darwin" -> Just DarwinModule
  "package" -> Just Package
  "overlay" -> Just Overlay
  "lib" -> Just Library
  "shell" -> Just Shell
  _ -> Nothing

-- ══════════════════════════════════════════════════════════════════════════════
--                                                       // filename detection
-- ══════════════════════════════════════════════════════════════════════════════

detectFromFileName :: String -> [(ModuleKind, Int, Text)]
detectFromFileName name = case name of
  "flake.nix"   -> [(Flake, 100, "filename is flake.nix")]
  "shell.nix"   -> [(Shell, 90, "filename is shell.nix")]
  "default.nix" -> []  -- Could be anything
  "package.nix" -> [(Package, 80, "filename is package.nix")]
  "module.nix"  -> [(NixOSModule, 60, "filename is module.nix")]
  "overlay.nix" -> [(Overlay, 80, "filename is overlay.nix")]
  "test.nix"    -> [(Test, 80, "filename is test.nix")]
  _ | "-test.nix" `T.isSuffixOf` T.pack name -> [(Test, 70, "filename ends in -test.nix")]
    | "-module.nix" `T.isSuffixOf` T.pack name -> [(NixOSModule, 60, "filename ends in -module.nix")]
    | otherwise -> []

-- ══════════════════════════════════════════════════════════════════════════════
--                                                      // structure detection
-- ══════════════════════════════════════════════════════════════════════════════

detectFromStructure :: NExprLoc -> [(ModuleKind, Int, Text)]
detectFromStructure expr = case unwrap expr of
  -- Overlay pattern: final: prev: { ... }
  NAbs param1 body1 | isOverlayParam param1 ->
    case unwrap body1 of
      NAbs param2 _ | isOverlayParam param2 ->
        [(Overlay, 95, "two-argument function (final: prev:)")]
      _ -> []

  -- Function with { ... } @ pattern
  NAbs param body ->
    let paramNames = getParamNames param
        bodyHints = detectFromBody body
        paramHints = detectFromParams paramNames
    in paramHints ++ bodyHints

  -- Direct attrset (rare for modules)
  NSet _ bindings ->
    detectFromBindings bindings

  _ -> []

-- | Check if a parameter looks like an overlay param.
isOverlayParam :: Params NExprLoc -> Bool
isOverlayParam (Param name) =
  let n = coerce name :: Text
  in n `elem` ["final", "prev", "self", "super"]
isOverlayParam _ = False

-- | Get parameter names from a function.
getParamNames :: Params NExprLoc -> [Text]
getParamNames = \case
  Param name -> [coerce name]
  ParamSet _ _ params ->
    map (\(name, _) -> coerce name) params

-- | Detect from parameter names.
detectFromParams :: [Text] -> [(ModuleKind, Int, Text)]
detectFromParams params
  | hasNixOSParams params = [(NixOSModule, 70, "has config/lib/pkgs params")]
  | hasPackageParams params = [(Package, 70, "has stdenv/fetchurl params")]
  | hasFlakeModuleParams params = [(FlakeModule, 60, "has flake-parts params")]
  | otherwise = []
  where
    hasNixOSParams ps = all (`elem` ps) ["config", "lib"]
      || all (`elem` ps) ["config", "pkgs"]
    hasPackageParams ps = "stdenv" `elem` ps
      || "mkDerivation" `elem` ps
      || "fetchurl" `elem` ps
      || "fetchFromGitHub" `elem` ps
    hasFlakeModuleParams ps = all (`elem` ps) ["config", "lib", "flake-parts-lib"]
      || "self" `elem` ps && "inputs" `elem` ps

-- | Detect from function body.
detectFromBody :: NExprLoc -> [(ModuleKind, Int, Text)]
detectFromBody body = case unwrap body of
  NSet _ bindings -> detectFromBindings bindings
  NLet _ inner -> detectFromBody inner
  NWith _ inner -> detectFromBody inner
  _ -> []

-- | Detect from top-level bindings.
detectFromBindings :: [Binding NExprLoc] -> [(ModuleKind, Int, Text)]
detectFromBindings bindings =
  let attrNames = mapMaybe getBindingName bindings
  in detectFromAttrNames attrNames

-- | Get binding name if it's a simple named binding.
getBindingName :: Binding NExprLoc -> Maybe Text
getBindingName = \case
  NamedVar (StaticKey name :| []) _ _ -> Just (coerce name)
  _ -> Nothing

-- | Detect from attribute names in the body.
detectFromAttrNames :: [Text] -> [(ModuleKind, Int, Text)]
detectFromAttrNames names
  -- NixOS/home-manager module pattern
  | hasOptions && hasConfig = [(NixOSModule, 85, "has options and config attrs")]
  | hasOptions = [(NixOSModule, 60, "has options attr")]

  -- Package pattern
  | hasMkDeriv = [(Package, 90, "calls mkDerivation or similar")]
  | hasPname && hasVersion = [(Package, 75, "has pname and version")]

  -- flake-parts module pattern
  | hasFlakeConfig = [(FlakeModule, 80, "has flake-parts config pattern")]

  -- Shell pattern
  | hasShellAttrs = [(Shell, 70, "has shell-like attrs")]

  -- Library pattern
  | hasLibExports = [(Library, 50, "exports library functions")]

  | otherwise = []
  where
    hasOptions = "options" `elem` names
    hasConfig = "config" `elem` names
    hasMkDeriv = any (`elem` names) ["mkDerivation", "stdenv.mkDerivation", "buildPythonPackage", "buildGoModule"]
    hasPname = "pname" `elem` names
    hasVersion = "version" `elem` names
    hasFlakeConfig = "perSystem" `elem` names || "flake" `elem` names
    hasShellAttrs = "buildInputs" `elem` names && "shellHook" `elem` names
    hasLibExports = any (`elem` names) ["mkOption", "mkIf", "mapAttrs", "filterAttrs"]

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                   // helpers
-- ══════════════════════════════════════════════════════════════════════════════

unwrap :: NExprLoc -> NExprF NExprLoc
unwrap (Fix (Compose (AnnUnit _ e))) = e

-- | Select the best detection from hints.
selectBest :: [(ModuleKind, Int, Text)] -> Detection
selectBest [] = Detection Unknown 0 []
selectBest hints =
  let sorted = reverse $ nub hints  -- Remove dups, prefer later (structure over filename)
      (kind, conf, _) = maximumBy' (\(_, c, _) -> c) sorted
      allEvidence = [e | (k, _, e) <- hints, k == kind]
  in Detection kind conf allEvidence

maximumBy' :: Ord b => (a -> b) -> [a] -> a
maximumBy' _ [x] = x
maximumBy' f (x:xs) = go x (f x) xs
  where
    go best _ [] = best
    go best bestVal (y:ys) =
      let yVal = f y
      in if yVal > bestVal then go y yVal ys else go best bestVal ys
maximumBy' _ [] = error "maximumBy': empty list"

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                   // queries
-- ══════════════════════════════════════════════════════════════════════════════

isNixOSModule :: Detection -> Bool
isNixOSModule d = detectedKind d `elem` [NixOSModule, HomeModule, DarwinModule]

isPackage :: Detection -> Bool
isPackage d = detectedKind d == Package

isOverlay :: Detection -> Bool
isOverlay d = detectedKind d == Overlay

isFlakeModule :: Detection -> Bool
isFlakeModule d = detectedKind d `elem` [FlakeModule, FlakePart]
