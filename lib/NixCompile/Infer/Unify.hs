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

{- | Solve constraints and return final substitution
This is the main entry point
-}
solve :: [Constraint] -> Either TypeError Subst
solve = unifyAll
