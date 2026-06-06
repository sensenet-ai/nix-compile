{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                        // nix // types
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "The box was a universe, a poem."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // type // system
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Types (
    -- * Types
    NixType (..),
    RowTail (..),
    pattern TAttrs,
    pattern TAttrsOpen,
    TypeVar (..),

    -- * Type schemes (polymorphic types)
    Scheme (..),

    -- * Constraints
    Constraint (..),

    -- * Substitution
    Subst,
    emptySubst,
    singleSubst,
    composeSubst,
    applySubst,
    applySubstScheme,

    -- * Free variables
    freeTypeVars,
    freeTypeVarsScheme,

    -- * Pretty printing
    prettyType,
    prettyScheme,
)
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- ═════════════════════════════════════════════════════════════════════════════
-- types
-- ═════════════════════════════════════════════════════════════════════════════

newtype TypeVar = TypeVar {unTypeVar :: Int}
    deriving stock (Eq, Ord, Show, Generic)
    deriving newtype (FromJSON, ToJSON)

data NixType
    = TVar !TypeVar
    | TInt
    | TFloat
    | TBool
    | TString
    | TStrLit !Text
    | TPath
    | TNull
    | TList !NixType
    | -- | records: known fields (type, isOptional) + a row tail
      TRec !(Map Text (NixType, Bool)) !RowTail
    | TFun !NixType !NixType
    | TDerivation
    | TUnion ![NixType]
    | TAny
    deriving stock (Eq, Ord, Show, Generic)

instance FromJSON NixType

instance ToJSON NixType

{- | A record's row tail: closed (exactly the known fields) or open (at least
them). Stage 1 keeps the tail nullary — semantically identical to the old
@TAttrs@/@TAttrsOpen@. RC1 stage 2 will carry a row variable + lacks-constraints
in 'ROpen' so open records can accumulate fields across unifications.
-}
data RowTail = RClosed | ROpen
    deriving stock (Eq, Ord, Show, Generic)

instance FromJSON RowTail

instance ToJSON RowTail

{- | Back-compat views over 'TRec'. The rest of the codebase keeps matching and
building @TAttrs@/@TAttrsOpen@ while the representation moves to 'TRec'.
-}
pattern TAttrs :: Map Text (NixType, Bool) -> NixType
pattern TAttrs fields = TRec fields RClosed

pattern TAttrsOpen :: Map Text (NixType, Bool) -> NixType
pattern TAttrsOpen fields = TRec fields ROpen

{-# COMPLETE
    TVar
    , TInt
    , TFloat
    , TBool
    , TString
    , TStrLit
    , TPath
    , TNull
    , TList
    , TAttrs
    , TAttrsOpen
    , TFun
    , TDerivation
    , TUnion
    , TAny
    #-}

data Scheme = Forall ![TypeVar] !NixType
    deriving stock (Eq, Show, Generic)

instance FromJSON Scheme

instance ToJSON Scheme

-- ═════════════════════════════════════════════════════════════════════════════
-- constraints
-- ═════════════════════════════════════════════════════════════════════════════

data Constraint
    = NixType :~: NixType
    deriving stock (Eq, Show, Generic)

infix 4 :~:

-- ═════════════════════════════════════════════════════════════════════════════
-- substitution
-- ═════════════════════════════════════════════════════════════════════════════

type Subst = Map TypeVar NixType

emptySubst :: Subst
emptySubst = Map.empty

singleSubst :: TypeVar -> NixType -> Subst
singleSubst = Map.singleton

composeSubst :: Subst -> Subst -> Subst
composeSubst substitution1 substitution2 =
    Map.map (applySubst substitution1) substitution2 `Map.union` substitution1

applySubst :: Subst -> NixType -> NixType
applySubst s = go
  where
    go = \case
        TVar v -> case Map.lookup v s of
            -- a self-map {v ↦ TVar v} is the identity; returning it (instead of
            -- chasing) avoids an infinite loop. `instantiate` produces such maps
            -- whenever a fresh var collides with a scheme's quantified var index
            -- (both draw from 0,1,…), which is why applying ANY polymorphic builtin
            -- (head/map/filter/…) to an argument used to hang inference.
            Just (TVar v') | v' == v -> TVar v
            Just t -> go t
            Nothing -> TVar v
        TList t -> TList (go t)
        TAttrs m -> TAttrs (Map.map (\(t, o) -> (go t, o)) m)
        TAttrsOpen m -> TAttrsOpen (Map.map (\(t, o) -> (go t, o)) m)
        TFun a b -> TFun (go a) (go b)
        TUnion ts -> TUnion (map go ts)
        t -> t

applySubstScheme :: Subst -> Scheme -> Scheme
applySubstScheme s (Forall vars t) =
    Forall vars (applySubst (foldr Map.delete s vars) t)

-- ═════════════════════════════════════════════════════════════════════════════
-- free type variables
-- ═════════════════════════════════════════════════════════════════════════════

freeTypeVars :: NixType -> Set TypeVar
freeTypeVars = \case
    TVar v -> Set.singleton v
    TList t -> freeTypeVars t
    TAttrs m -> Set.unions (map (freeTypeVars . fst) (Map.elems m))
    TAttrsOpen m -> Set.unions (map (freeTypeVars . fst) (Map.elems m))
    TFun a b -> freeTypeVars a `Set.union` freeTypeVars b
    TUnion ts -> Set.unions (map freeTypeVars ts)
    _ -> Set.empty

freeTypeVarsScheme :: Scheme -> Set TypeVar
freeTypeVarsScheme (Forall vars t) =
    freeTypeVars t `Set.difference` Set.fromList vars

-- ═════════════════════════════════════════════════════════════════════════════
-- pretty printing
-- ═════════════════════════════════════════════════════════════════════════════

prettyType :: NixType -> Text
prettyType t = prettyTypeWith mapping t
  where
    vars = Set.toAscList (freeTypeVars t)
    names = map T.singleton ['a' .. 'z'] ++ ["t" <> T.pack (show i) | i <- [1 ..] :: [Int]]
    mapping = Map.fromList $ zip vars names

prettyScheme :: Scheme -> Text
prettyScheme (Forall [] t) = prettyType t
prettyScheme (Forall vars t) =
    let
        free = Set.toAscList (freeTypeVars t `Set.difference` Set.fromList vars)
        allVars = vars ++ free
        names = map T.singleton ['a' .. 'z'] ++ ["t" <> T.pack (show i) | i <- [1 ..] :: [Int]]
        mapping = Map.fromList $ zip allVars names

        prettyVar v = Map.findWithDefault "?" v mapping
     in
        "forall " <> T.intercalate " " (map prettyVar vars) <> ". " <> prettyTypeWith mapping t

prettyTypeWith :: Map TypeVar Text -> NixType -> Text
prettyTypeWith mapping = go
  where
    go = \case
        TVar v -> Map.findWithDefault ("t" <> T.pack (show (unTypeVar v))) v mapping
        TInt -> "Int"
        TFloat -> "Float"
        TBool -> "Bool"
        TString -> "String"
        TStrLit s -> "\"" <> s <> "\""
        TPath -> "Path"
        TNull -> "Null"
        TList t -> "[" <> go t <> "]"
        TAttrs m -> prettyAttrs m
        TAttrsOpen m -> prettyAttrs m <> " | ..."
        TFun a b -> prettyArg a <> " -> " <> go b
        TDerivation -> "Derivation"
        TUnion ts -> T.intercalate " | " (map go ts)
        TAny -> "Any"

    prettyArg t@(TFun _ _) = "(" <> go t <> ")"
    prettyArg t = go t

    prettyAttrs m
        | Map.null m = "{}"
        | otherwise = "{ " <> T.intercalate ", " (map prettyField (Map.toList m)) <> " }"

    prettyField (k, (v, opt)) = k <> (if opt then "?" else "") <> " : " <> go v
