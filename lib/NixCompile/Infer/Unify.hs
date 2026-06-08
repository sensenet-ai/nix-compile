{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                    // infer // unification
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "His tan was dark and even. The angular patchwork left by the Dutchman's
--    grafts was gone, and she had taught him the unity of his body. Mornings,
--    when he met the green eyes in the bathroom mirror, they were his own,
--    and the Dutchman no longer troubled his dreams with bad jokes and a dry
--    cough."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                       // bash // unify
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Infer.Unify (
  unify,
  unifyAll,
  solve,
)
where

import Control.Monad (foldM)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import NixCompile.Types

-- | Unify two types, producing a substitution
unify :: Type -> Type -> Either TypeError Subst
unify type1 type2 = case (type1, type2) of
  (TInt, TInt) -> Right emptySubst
  (TString, TString) -> Right emptySubst
  (TBool, TBool) -> Right emptySubst
  (TPath, TPath) -> Right emptySubst
  (TNumeric, TInt) -> Right emptySubst
  (TInt, TNumeric) -> Right emptySubst
  (TNumeric, TBool) -> Right emptySubst
  (TBool, TNumeric) -> Right emptySubst
  (TNumeric, TNumeric) -> Right emptySubst
  (TVar typeVariable, typeValue) -> bindVar typeVariable typeValue
  (typeValue, TVar typeVariable) -> bindVar typeVariable typeValue
  _ -> Left (Mismatch type1 type2 emptySpan)
 where
  emptySpan = Span (Loc 0 0) (Loc 0 0) Nothing

bindVar :: TypeVar -> Type -> Either TypeError Subst
bindVar typeVariable typeValue
  | typeValue == TVar typeVariable = Right emptySubst
  | occursIn typeVariable typeValue = Left (OccursCheck typeVariable typeValue emptySpan)
  | otherwise = Right (singleSubst typeVariable typeValue)
 where
  emptySpan = Span (Loc 0 0) (Loc 0 0) Nothing

occursIn :: TypeVar -> Type -> Bool
occursIn typeVariable = \case
  TVar typeVariable' -> typeVariable == typeVariable'
  _ -> False

unifyAll :: [Constraint] -> Either TypeError Subst
unifyAll = foldM unifyConstraint emptySubst
 where
  unifyConstraint substitution (constraintType1 :~: constraintType2) = do
    let type1' = applySubst substitution constraintType1
        type2' = applySubst substitution constraintType2
    substitution' <- unify type1' type2'
    Right (composeSubst substitution' substitution)

{- | Solve a constraint set (the main entry point).

Unlike the pairwise fold ('unifyAll'), this collects each type variable's
constraints and resolves the variable to the JOIN (least upper bound) of its
concrete constraints in the @{TInt, TBool} <: TNumeric@ lattice. That makes
solving **order-independent and complete**: @[TInt ~ a, a ~ TBool]@ resolves
@a = TNumeric@ instead of failing on whichever order binds @a@ first
(REVIEW-3 #6 — the fold could not loosen an already-bound variable, since
'composeSubst' is left-biased). A bare concrete~concrete constraint still
requires compatibility, so @TInt@ and @TBool@ stay disjoint without a bridging
variable.
-}
solve :: [Constraint] -> Either TypeError Subst
solve constraints = do
  groupType <- foldM gather Map.empty constraints
  pure $ Map.fromList [(v, t) | v <- allTypeVars, Just t <- [Map.lookup (rep v) groupType]]
 where
  allTypeVars = nub [v | (l :~: r) <- constraints, v <- tvarsOf l ++ tvarsOf r]
  tvarsOf (TVar v) = [v]
  tvarsOf _ = []

  -- union-find over variables linked by var~var constraints
  uf = foldl' link (Map.fromList [(v, v) | v <- allTypeVars]) [(a, b) | (TVar a :~: TVar b) <- constraints]
  link m (a, b) =
    let ra = findIn m a
        rb = findIn m b
     in if ra == rb then m else Map.insert ra rb m
  findIn m v = let parent = Map.findWithDefault v v m in if parent == v then v else findIn m parent
  rep = findIn uf

  -- accumulate each group's resolved concrete type; check concrete~concrete
  gather acc (l :~: r) = case (l, r) of
    (TVar _, TVar _) -> Right acc -- handled by union-find
    (TVar a, t) -> addConcrete (rep a) t acc
    (t, TVar a) -> addConcrete (rep a) t acc
    (t1, t2)
      | compatible t1 t2 -> Right acc
      | otherwise -> Left (Mismatch t1 t2 emptySpan)

  addConcrete groupRep t acc = case Map.lookup groupRep acc of
    Nothing -> Right (Map.insert groupRep t acc)
    Just current -> case joinTypes current t of
      Just joined -> Right (Map.insert groupRep joined acc)
      Nothing -> Left (Mismatch current t emptySpan)

  -- least upper bound in the numeric lattice (Nothing if incompatible)
  joinTypes a b
    | a == b = Just a
    | numeric a && numeric b = Just TNumeric
    | otherwise = Nothing
  numeric t = t == TInt || t == TBool || t == TNumeric

  -- concrete~concrete: equal, or bridged by an explicit TNumeric (TInt and
  -- TBool are NOT directly compatible — only a shared variable joins them)
  compatible a b = a == b || (a == TNumeric && numeric b) || (b == TNumeric && numeric a)

  emptySpan = Span (Loc 0 0) (Loc 0 0) Nothing
