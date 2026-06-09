{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
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

module NixCompile.Inference.Nix.Type (
  -- * Types
  NixType (..),
  RowTail (..),
  pattern TAttrs,
  pattern TAttrsOpen,
  tRecOpenAnon,
  anonRowVar,
  isAnonRowVar,
  rowTailVars,
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

{- | A record's row tail: closed (exactly the known fields) or open with a row
**variable** standing for "at least these fields, plus whatever @r@ resolves to".
The row var lets open records accumulate fields across unifications (RC1); its
lacks-constraints (which labels it must NOT gain) live in a side store in the
inference state ('NixCompile.Inference.Nix').
-}
data RowTail = RClosed | ROpen !TypeVar
  deriving stock (Eq, Ord, Show, Generic)

instance FromJSON RowTail

instance ToJSON RowTail

{- | Closed-record view: bidirectional, so @TAttrs m@ both matches and builds
@TRec m RClosed@.
-}
pattern TAttrs :: Map Text (NixType, Bool) -> NixType
pattern TAttrs fields = TRec fields RClosed

{- | Open-record view. Matching ignores the row variable; building uses the
anonymous sentinel ('anonRowVar') — fine for pure/display and test construction.
Inference sites that need field accumulation build @TRec m (ROpen r)@ with a
FRESH @r@ instead (see 'NixCompile.Inference.Nix.mkOpenRec').
-}
pattern TAttrsOpen :: Map Text (NixType, Bool) -> NixType
pattern TAttrsOpen fields <- TRec fields (ROpen _)
  where
    TAttrsOpen fields = TRec fields (ROpen anonRowVar)

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

-- | the row variable in an open tail, if any
rowTailVars :: RowTail -> Set TypeVar
rowTailVars (ROpen r) = Set.singleton r
rowTailVars RClosed = Set.empty

{- | Sentinel row variable for "anonymous open" records built in PURE contexts
(flake/module display types) that have no fresh-var supply. Unification must never
bind it (see 'isAnonRowVar'), so such records behave like the old tail-less open
attrset — no field accumulation. Negative id can never collide with the inference
supply (which counts up from 0).
-}
anonRowVar :: TypeVar
anonRowVar = TypeVar (-1)

isAnonRowVar :: TypeVar -> Bool
isAnonRowVar v = v == anonRowVar

{- | build an open record with the anonymous tail (pure-context helper for
flake/module types; the inference engine uses fresh row vars instead)
-}
tRecOpenAnon :: Map Text (NixType, Bool) -> NixType
tRecOpenAnon m = TRec m (ROpen anonRowVar)

applySubst :: Subst -> NixType -> NixType
applySubst s = go
 where
  go (TVar v) = resolveVar v (Map.lookup v s)
  go (TList t) = TList (go t)
  go (TRec m tail_) = resolveRec (Map.map (\(t, o) -> (go t, o)) m) tail_
  go (TFun a b) = TFun (go a) (go b)
  go (TUnion ts) = TUnion (map go ts)
  go t = t

  -- a self-map {v ↦ TVar v} is the identity; returning it (instead of chasing)
  -- avoids an infinite loop. `instantiate` produces such maps whenever a fresh
  -- var collides with a scheme's quantified var index (both draw from 0,1,…),
  -- which is why applying ANY polymorphic builtin (head/map/filter/…) to an
  -- argument used to hang inference.
  resolveVar v (Just (TVar v')) | v' == v = TVar v
  resolveVar _ (Just t) = go t
  resolveVar v Nothing = TVar v

  resolveRec m' RClosed = TRec m' RClosed
  resolveRec m' (ROpen r) = resolveRow m' r (Map.lookup r s)

  resolveRow m' r Nothing = TRec m' (ROpen r)
  resolveRow m' r (Just (TVar r')) | r' == r = TRec m' (ROpen r) -- self-map: identity
  resolveRow m' _ (Just (TVar r')) = TRec m' (ROpen r') -- tail var renamed
  -- row var bound to a record: merge known fields (disjoint by lacks) and
  -- continue resolving the bound row's own tail
  resolveRow m' _ (Just (TRec m2 tail2)) = go (TRec (Map.union m' m2) tail2)
  resolveRow m' r (Just _) = TRec m' (ROpen r) -- defensive: non-row binding

applySubstScheme :: Subst -> Scheme -> Scheme
applySubstScheme s (Forall vars t) =
  Forall vars (applySubst (foldr Map.delete s vars) t)

-- ═════════════════════════════════════════════════════════════════════════════
-- free type variables
-- ═════════════════════════════════════════════════════════════════════════════

freeTypeVars :: NixType -> Set TypeVar
freeTypeVars (TVar v) = Set.singleton v
freeTypeVars (TList t) = freeTypeVars t
freeTypeVars (TRec m tail_) =
  Set.unions (map (freeTypeVars . fst) (Map.elems m)) `Set.union` rowTailVars tail_
freeTypeVars (TFun a b) = freeTypeVars a `Set.union` freeTypeVars b
freeTypeVars (TUnion ts) = Set.unions (map freeTypeVars ts)
freeTypeVars _ = Set.empty

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
  go (TVar v) = Map.findWithDefault ("t" <> T.pack (show (unTypeVar v))) v mapping
  go TInt = "Int"
  go TFloat = "Float"
  go TBool = "Bool"
  go TString = "String"
  go (TStrLit s) = "\"" <> truncLit s <> "\""
  go TPath = "Path"
  go TNull = "Null"
  go (TList t) = "[" <> go t <> "]"
  go (TRec m RClosed) = prettyAttrs m
  go (TRec m (ROpen r)) = prettyAttrs m <> " | " <> Map.findWithDefault ".." r mapping
  go (TFun a b) = prettyArg a <> " -> " <> go b
  go TDerivation = "Derivation"
  go (TUnion ts) = T.intercalate " | " (map go ts)
  go TAny = "Any"

  prettyArg t@(TFun _ _) = "(" <> go t <> ")"
  prettyArg t = go t

  -- A 'TStrLit' carries the literal's full text; cap it in type display so a
  -- giant string literal doesn't become a giant type (e.g. `infer` on a file
  -- with a 200 KB string was emitting a 200 KB `# :: "…"` annotation).
  truncLit s
    | T.length s <= 40 = s
    | otherwise = T.take 39 s <> "…"

  prettyAttrs m
    | Map.null m = "{}"
    | otherwise = "{ " <> T.intercalate ", " (map prettyField (Map.toList m)) <> " }"

  prettyField (k, (v, opt)) = k <> (if opt then "?" else "") <> " : " <> go v
