{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : NixCompile.Nix.Types
-- Description : Type system for Nix expressions
--
-- A Hindley-Milner style type system for a subset of Nix.
-- We infer types from:
--   - Default values in function parameters
--   - Builtin function signatures
--   - Operators
--   - Literal values
--
-- The goal is to make Nix feel like a typed language, with
-- type signatures generated as comments.
module NixCompile.Nix.Types
  ( -- * Types
    NixType (..),
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
    prettyTypeDoc,
    prettySchemeDoc,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import NixCompile.Pretty

-- ============================================================================
-- Types
-- ============================================================================

-- | Type variables for unification
newtype TypeVar = TypeVar { unTypeVar :: Int }
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | Nix types
data NixType
  = TVar !TypeVar              -- Type variable (for inference)
  | TInt                       -- Integers
  | TFloat                     -- Floats  
  | TBool                      -- Booleans
  | TString                    -- Strings
  | TStrLit !Text              -- String literal (singleton type)
  | TPath                      -- Paths (including store paths)
  | TNull                      -- null
  | TList !NixType             -- Lists (homogeneous)
  | TAttrs !(Map Text (NixType, Bool)) -- Attribute sets (type, isOptional)
  | TAttrsOpen !(Map Text (NixType, Bool)) -- Open attrset
  | TFun !NixType !NixType     -- Functions
  | TDerivation                -- Derivations (special)
  | TUnion ![NixType]          -- Union types (for builtins that accept multiple)
  | TAny                       -- Top type (unknown, accepts anything)
  deriving stock (Eq, Ord, Show, Generic)

instance FromJSON NixType
instance ToJSON NixType

-- | Type scheme (polymorphic type with quantified variables)
-- e.g., forall a. a -> a
data Scheme = Forall ![TypeVar] !NixType
  deriving stock (Eq, Show, Generic)

instance FromJSON Scheme
instance ToJSON Scheme

-- ============================================================================
-- Constraints
-- ============================================================================

-- | Type constraint
data Constraint
  = NixType :~: NixType  -- Equality constraint
  deriving stock (Eq, Show, Generic)

infix 4 :~:

-- ============================================================================
-- Substitution
-- ============================================================================

-- | Substitution from type variables to types
type Subst = Map TypeVar NixType

emptySubst :: Subst
emptySubst = Map.empty

singleSubst :: TypeVar -> NixType -> Subst
singleSubst = Map.singleton

-- | Compose substitutions (apply s1 then s2)
composeSubst :: Subst -> Subst -> Subst
composeSubst s1 s2 = Map.map (applySubst s1) s2 `Map.union` s1

-- | Apply substitution to a type
applySubst :: Subst -> NixType -> NixType
applySubst s = go
  where
    go = \case
      TVar v -> Map.findWithDefault (TVar v) v s
      TList t -> TList (go t)
      TAttrs m -> TAttrs (Map.map (\(t, o) -> (go t, o)) m)
      TAttrsOpen m -> TAttrsOpen (Map.map (\(t, o) -> (go t, o)) m)
      TFun a b -> TFun (go a) (go b)
      TUnion ts -> TUnion (map go ts)
      t -> t

-- | Apply substitution to a scheme
applySubstScheme :: Subst -> Scheme -> Scheme
applySubstScheme s (Forall vars t) = 
  Forall vars (applySubst (foldr Map.delete s vars) t)

-- ============================================================================
-- Free type variables
-- ============================================================================

-- | Get free type variables in a type
freeTypeVars :: NixType -> Set TypeVar
freeTypeVars = \case
  TVar v -> Set.singleton v
  TList t -> freeTypeVars t
  TAttrs m -> Set.unions (map (freeTypeVars . fst) (Map.elems m))
  TAttrsOpen m -> Set.unions (map (freeTypeVars . fst) (Map.elems m))
  TFun a b -> freeTypeVars a `Set.union` freeTypeVars b
  TUnion ts -> Set.unions (map freeTypeVars ts)
  _ -> Set.empty

-- | Get free type variables in a scheme
freeTypeVarsScheme :: Scheme -> Set TypeVar
freeTypeVarsScheme (Forall vars t) = 
  freeTypeVars t `Set.difference` Set.fromList vars

-- ============================================================================
-- Pretty Printing
-- ============================================================================

-- | Pretty print a type using normalized variable names (a, b, c...)
prettyType :: NixType -> Text
prettyType t = toText (prettyTypeDoc t)

-- | Pretty print a type scheme
prettyScheme :: Scheme -> Text
prettyScheme s = toText (prettySchemeDoc s)

-- | Pretty print a type (as Doc)
prettyTypeDoc :: NixType -> Doc AnsiStyle
prettyTypeDoc t = prettyTypeWith mapping t
  where
    vars = Set.toAscList (freeTypeVars t)
    names = map T.singleton ['a'..'z'] ++ [ "t" <> T.pack (show i) | i <- [1..] :: [Int] ]
    mapping = Map.fromList $ zip vars names

-- | Pretty print a scheme (as Doc)
prettySchemeDoc :: Scheme -> Doc AnsiStyle
prettySchemeDoc (Forall [] t) = prettyTypeDoc t
prettySchemeDoc (Forall vars t) =
  let
    free = Set.toAscList (freeTypeVars t `Set.difference` Set.fromList vars)
    allVars = vars ++ free
    names = map T.singleton ['a'..'z'] ++ [ "t" <> T.pack (show i) | i <- [1..] :: [Int] ]
    mapping = Map.fromList $ zip allVars names

    prettyVar v = pretty (Map.findWithDefault "?" v mapping)
  in
    styleKeyword "forall" <+> hsep (map prettyVar vars) <> "." <+> prettyTypeWith mapping t

-- | Internal helper: pretty print with variable mapping
prettyTypeWith :: Map TypeVar Text -> NixType -> Doc AnsiStyle
prettyTypeWith mapping = go
  where
    go = \case
      TVar v -> styleVar $ pretty (Map.findWithDefault ("t" <> T.pack (show (unTypeVar v))) v mapping)
      TInt -> styleType "Int"
      TFloat -> styleType "Float"
      TBool -> styleType "Bool"
      TString -> styleType "String"
      TStrLit s -> styleString ("\"" <> pretty s <> "\"")
      TPath -> styleType "Path"
      TNull -> styleType "Null"
      TList t -> list [go t]
      TAttrs m -> prettyAttrs m
      TAttrsOpen m -> prettyAttrsOpen m
      TFun a b -> 
        let aDoc = case a of
              TFun _ _ -> parens (go a)
              _ -> go a
        in aDoc <+> "->" <+> go b
      TDerivation -> styleType "Derivation"
      TUnion ts -> align $ sep (punctuate " |" (map go ts))
      TAny -> styleType "Any"

    prettyAttrs m 
      | Map.null m = "{}"
      | otherwise = 
          group $ vsep
            [ "{"
            , indent 2 (vsep (punctuate comma (map prettyField (Map.toList m))))
            , "}"
            ]
            
    prettyAttrsOpen m
      | Map.null m = "{ ... }"
      | otherwise =
          group $ vsep
            [ "{"
            , indent 2 (vsep (punctuate comma (map prettyField (Map.toList m) ++ ["..."])))
            , "}"
            ]
    
    prettyField (k, (v, opt)) = 
      let key = if opt then pretty k <> "?" else pretty k
      in styleVar key <+> ":" <+> go v
