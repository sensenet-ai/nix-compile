{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : NixCompile.Nix.Effect
Description : Effect/Coeffect algebra for Nix Overlays

Models an Overlay as a transformation in a Coeffect calculus.

The Overlay Function `final: prev: { ... }` is decomposed into:
  1. Coeffects (Requirements):
     - `prev`: The "Past" (Upstream dependencies)
     - `final`: The "Future" (Recursive/Fixpoint dependencies)
  2. Effects (Production):
     - The attributes defined in the returned set.

This allows us to statically analyze overlays for:
  - Missing upstream dependencies (prev.foo undefined)
  - Cycles (final.a depends on final.a)
  - Type compatibility (overriding Int with String)
-}
module NixCompile.Nix.Effect (
    -- * Core Types
    Coeffect (..),
    Effect (..),
    OverlaySignature (..),

    -- * Algebra
    mergeSignatures,
    checkCompatibility,
)
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import NixCompile.Nix.Types (NixType)

-- ============================================================================
-- Coeffects (Requirements)
-- ============================================================================

-- | A Coeffect represents a dependency on the environment context.
data Coeffect
    = -- | Accessing `prev.pkg`
      RequireUpstream !Text !NixType
    | -- | Accessing `final.pkg`
      RequireSelf !Text !NixType
    | -- | Importing a file
      RequireImport !FilePath
    deriving stock (Eq, Show, Ord, Generic)

instance FromJSON Coeffect

instance ToJSON Coeffect

-- ============================================================================
-- Effects (Production)
-- ============================================================================

-- | An Effect represents a modification to the environment.
data Effect
    = -- | New package `foo = ...`
      Define !Text !NixType
    | -- | Replacing `prev.foo` (shadowing)
      Override !Text !NixType
    | -- | `foo.overrideAttrs (...)` (preserves identity)
      Modify !Text
    deriving stock (Eq, Show, Ord, Generic)

instance FromJSON Effect

instance ToJSON Effect

-- ============================================================================
-- Overlay Algebra
-- ============================================================================

-- | The static signature of an Overlay.
data OverlaySignature = OverlaySignature
    { osCoeffects :: !(Set Coeffect)
    -- ^ What it reads
    , osEffects :: !(Set Effect)
    -- ^ What it writes
    }
    deriving stock (Eq, Show, Generic)

instance FromJSON OverlaySignature

instance ToJSON OverlaySignature

{- | Merge two signatures (composition of overlays)
This models `composeExtensions` in Nixpkgs.

(f1 `compose` f2) means f1 runs, then f2 runs on top.
f2 sees the effects of f1 as its "upstream".
-}
mergeSignatures :: OverlaySignature -> OverlaySignature -> OverlaySignature
mergeSignatures s1 s2 =
    OverlaySignature
        { osCoeffects = osCoeffects s1 `Set.union` resolvedCoeffects
        , osEffects = osEffects s1 `Set.union` osEffects s2
        }
  where
    -- If s2 requires upstream 'x', and s1 defines 'x', the requirement is satisfied (internalized).
    -- Otherwise, it propagates upwards.
    -- (This is a simplification; strictly, s2 reads the result of s1 applied to base)
    resolvedCoeffects = Set.filter (not . isSatisfiedBy (osEffects s1)) (osCoeffects s2)

    isSatisfiedBy :: Set Effect -> Coeffect -> Bool
    isSatisfiedBy effects (RequireUpstream name _) =
        any (defines name) effects
    isSatisfiedBy _ _ = False

    defines :: Text -> Effect -> Bool
    defines name (Define n _) = n == name
    defines name (Override n _) = n == name
    defines name (Modify n) = n == name

-- | Check if an overlay is compatible with a base environment (row polymorphism).
checkCompatibility :: Map Text NixType -> OverlaySignature -> [Text]
checkCompatibility baseEnv sig =
    [ "Missing upstream dependency: " <> name
    | RequireUpstream name _ <- Set.toList (osCoeffects sig)
    , not (name `Map.member` baseEnv)
    ]
