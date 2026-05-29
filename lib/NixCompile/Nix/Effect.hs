{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                       // nix // effect
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Something chill and odorless, ballooning out."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // effect // algebra
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

-- ═════════════════════════════════════════════════════════════════════════════
-- coeffects (requirements)
-- ═════════════════════════════════════════════════════════════════════════════

data Coeffect
    = RequireUpstream !Text !NixType
    | RequireSelf !Text !NixType
    | RequireImport !FilePath
    deriving stock (Eq, Show, Ord, Generic)

instance FromJSON Coeffect

instance ToJSON Coeffect

-- ═════════════════════════════════════════════════════════════════════════════
-- effects (production)
-- ═════════════════════════════════════════════════════════════════════════════

data Effect
    = Define !Text !NixType
    | Override !Text !NixType
    | Modify !Text
    deriving stock (Eq, Show, Ord, Generic)

instance FromJSON Effect

instance ToJSON Effect

-- ═════════════════════════════════════════════════════════════════════════════
-- overlay algebra
-- ═════════════════════════════════════════════════════════════════════════════

data OverlaySignature = OverlaySignature
    { osCoeffects :: !(Set Coeffect)
    , osEffects :: !(Set Effect)
    }
    deriving stock (Eq, Show, Generic)

instance FromJSON OverlaySignature

instance ToJSON OverlaySignature

mergeSignatures :: OverlaySignature -> OverlaySignature -> OverlaySignature
mergeSignatures signature1 signature2 =
    OverlaySignature
        { osCoeffects = osCoeffects signature1 `Set.union` resolvedCoeffects
        , osEffects = osEffects signature1 `Set.union` osEffects signature2
        }
  where
    resolvedCoeffects = Set.filter (not . satisfiedByProduced) (osCoeffects signature2)

    satisfiedByProduced (RequireUpstream name _) = any (definesName name) (osEffects signature1)
    satisfiedByProduced _ = False

    definesName targetName (Define name _) = name == targetName
    definesName targetName (Override name _) = name == targetName
    definesName targetName (Modify name) = name == targetName

checkCompatibility :: Map Text NixType -> OverlaySignature -> [Text]
checkCompatibility baseEnv sig =
    [ "Missing upstream dependency: " <> name
    | RequireUpstream name _ <- Set.toList (osCoeffects sig)
    , not (name `Map.member` baseEnv)
    ]
