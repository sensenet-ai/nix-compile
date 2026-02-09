{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : NixCompile.Infer.Unify
-- Description : Hindley-Milner unification for bash types
--
-- Standard unification algorithm. Nothing fancy.
--
-- The key insight: we don't need polymorphism. Bash variables are monomorphic.
-- So this is just first-order unification, which is simple and decidable.
module NixCompile.Infer.Unify
  ( unify,
    unifyAt,
    unifyAll,
    unifyAllLocated,
    solve,
    solveLocated,
  )
where

import Control.Monad (foldM)
import NixCompile.Types

-- | Unify two types at a given source location
-- This is the primary API - use when you have span information
unifyAt :: Span -> Type -> Type -> Either TypeError Subst
unifyAt sp t1 t2 = case (t1, t2) of
  -- Same concrete types
  (TInt, TInt) -> Right emptySubst
  (TString, TString) -> Right emptySubst
  (TBool, TBool) -> Right emptySubst
  (TPath, TPath) -> Right emptySubst
  -- Type variable on left: bind it
  (TVar v, t) -> bindVarAt sp v t
  -- Type variable on right: bind it
  (t, TVar v) -> bindVarAt sp v t
  -- Mismatch - use the provided span for the error
  _ -> Left (Mismatch t1 t2 sp)

-- | Legacy API: unify without span (uses empty span for errors)
unify :: Type -> Type -> Either TypeError Subst
unify = unifyAt emptySpan
  where
    emptySpan = Span (Loc 0 0) (Loc 0 0) Nothing

-- | Bind a type variable at a given source location
bindVarAt :: Span -> TypeVar -> Type -> Either TypeError Subst
bindVarAt sp v t
  | t == TVar v = Right emptySubst -- v ~ v is trivial
  | occursIn v t = Left (OccursCheck v t sp)
  | otherwise = Right (singleSubst v t)

-- | Does a type variable occur in a type?
-- For our simple type language, this only matters for TVar
occursIn :: TypeVar -> Type -> Bool
occursIn v = \case
  TVar v' -> v == v'
  _ -> False

-- | Unify a list of located constraints, accumulating substitutions
-- This is the preferred API when you have span information
unifyAllLocated :: [LocatedConstraint] -> Either TypeError Subst
unifyAllLocated = foldM go emptySubst
  where
    go s (LocatedConstraint (t1 :~: t2) sp) = do
      let t1' = applySubst s t1
          t2' = applySubst s t2
      s' <- unifyAt sp t1' t2'
      Right (composeSubst s' s)

-- | Legacy API: unify a list of unlocated constraints
unifyAll :: [Constraint] -> Either TypeError Subst
unifyAll = unifyAllLocated . map (\c -> LocatedConstraint c emptySpan)
  where
    emptySpan = Span (Loc 0 0) (Loc 0 0) Nothing

-- | Solve located constraints and return final substitution
-- This is the preferred entry point
solveLocated :: [LocatedConstraint] -> Either TypeError Subst
solveLocated = unifyAllLocated

-- | Legacy API: solve unlocated constraints
solve :: [Constraint] -> Either TypeError Subst
solve = unifyAll
