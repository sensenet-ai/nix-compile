{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                        // inference // nix // lib
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "The library was a sea of information, and he was learning to swim."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   Polymorphic schemes for the nixpkgs `lib` namespace — the library record
--   threaded through every flake-parts / NixOS module as the `lib` parameter.
--   A pure table; consumed by 'NixCompile.Inference.Nix.Builtins' to back the
--   `lib.<name>` selection path.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Inference.Nix.Lib (
  libSchemeTable,
)
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import NixCompile.Inference.Nix.Type

{- | Polymorphic schemes for the nixpkgs `lib` namespace, the library record
threaded through every flake-parts module and NixOS module as the `lib`
parameter. Like the builtins table these are SCHEMES (instantiated fresh per
use), so a single `lib.mkIf` may be applied at many result types — the whole
point: `{ lib }: { a = lib.mkIf c { x = 1; }; b = lib.mkIf c 2; }` must check.

Modeled structurally where the shape is stable (mkIf/mkMerge/mkDefault/… are
`a -> a`-shaped) and left permissive (TAny) where the real type is an
options-DSL value we don't model. There is no oracle coverage for module code
(it isn't a closed term), so permissive entries can't introduce soundness
mismatches — they only avoid false positives.
-}
libSchemeTable :: Map Text Scheme
libSchemeTable =
  Map.fromList
    [ -- module-system combinators: thread a value through unchanged
      ("mkIf", scheme1 (\a -> TFun TBool (TFun a a)))
    , ("mkMerge", scheme1 (\a -> TFun (TList a) a))
    , ("mkDefault", scheme1 (\a -> TFun a a))
    , ("mkForce", scheme1 (\a -> TFun a a))
    , ("mkOverride", scheme1 (\a -> TFun TInt (TFun a a)))
    , ("mkBefore", scheme1 (\a -> TFun a a))
    , ("mkAfter", scheme1 (\a -> TFun a a))
    , ("mkOptionDefault", scheme1 (\a -> TFun a a))
    , -- conditional attrset / list helpers
      ("optionalAttrs", scheme1 (\a -> TFun TBool (TFun a a)))
    , ("optional", scheme1 (\a -> TFun TBool (TFun a (TList a))))
    , ("optionals", scheme1 (\a -> TFun TBool (TFun (TList a) (TList a))))
    , ("optionalString", Forall [] (TFun TBool (TFun TString TString)))
    , -- string helpers
      ("concatStringsSep", Forall [] (TFun TString (TFun (TList TString) TString)))
    , ("makeBinPath", scheme1 (\a -> TFun (TList a) TString))
    , ("getExe", Forall [] (TFun TDerivation TString))
    , ("getExe'", Forall [] (TFun TDerivation (TFun TString TString)))
    , -- list/attr utilities whose precise row type we don't model: permissive
      ("mkOption", Forall [] (TFun TAny TAny))
    , ("mkEnableOption", Forall [] (TFun TString TAny))
    , ("mkPackageOption", Forall [] (TFun TAny TAny))
    , ("mapAttrs", Forall [] (TFun (TFun TString (TFun TAny TAny)) (TFun TAny TAny)))
    , ("filterAttrs", Forall [] (TFun (TFun TString (TFun TAny TBool)) (TFun TAny TAny)))
    , ("recursiveUpdate", Forall [] (TFun TAny (TFun TAny TAny)))
    , ("genAttrs", Forall [] (TFun (TList TString) (TFun TAny TAny)))
    , ("nameValuePair", Forall [] (TFun TString (TFun TAny TAny)))
    ]
 where
  scheme1 builder = let a = TypeVar 0 in Forall [a] (builder (TVar a))
