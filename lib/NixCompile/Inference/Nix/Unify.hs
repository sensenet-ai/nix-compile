{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                 // inference // nix // unify
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "The matrix has its roots in primitive arcade games, in early graphics
--    programs and military experimentation with cranial jacks."
--
--                                                                 — Neuromancer
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The constraint solver: row-variable-aware unification over 'NixType', the
--   occurs check, and the join ('mergeTypes') used to combine branch / element
--   types. Runs in the Infer monad ('Constraint'); knows nothing of the AST.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Inference.Nix.Unify (
  unify,
  mergeTypes,
  fieldConstraint,
  bindRowVar,
)
where

import Control.Monad (forM, forM_, unless)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import NixCompile.Inference.Nix.Constraint
import NixCompile.Inference.Nix.Type

-- ── unify: the core constraint solver ────────────────────────────

-- | report a mismatch between expected and actual types
typeMismatch :: NixType -> NixType -> Infer a
typeMismatch type1 type2 =
  throwTypeError $ "type mismatch: expected " <> prettyType type1 <> ", got " <> prettyType type2

{- | handle __functor protocol: if attrs has __functor, unify against its return type
n.b. this is how nix makes callable attribute sets
-}
unifyFunctor :: NixType -> NixType -> Infer ()
unifyFunctor funT attrsT
  | TAttrs m <- attrsT = lookupFunctor funT m
  | TAttrsOpen m <- attrsT = lookupFunctor funT m
  | otherwise = typeMismatch funT attrsT
 where
  lookupFunctor ft m = dispatch (Map.lookup "__functor" m)
   where
    dispatch (Just (TFun _ innerT, _)) = unify innerT ft
    dispatch (Just (ftFunctor, _)) = throwTypeError $ "__functor must be a function, got " <> prettyType ftFunctor
    dispatch Nothing = typeMismatch ft attrsT

-- | apply current subst, then unify the normalised forms
unify :: NixType -> NixType -> Infer ()
unify type1 type2 = do
  t1' <- applyCurrentSubst type1
  t2' <- applyCurrentSubst type2
  unify' t1' t2'

{- | structural unification — must be applied AFTER current substitution.
n.b. clause order is load-bearing: the patterns overlap (TFun/TFun before
the functor-protocol TFun/attrs, TUnion before that), exactly as the old
top-to-bottom `case (type1, type2)` required.
-}
unify' :: NixType -> NixType -> Infer ()
-- variable cases: bind one to the other (with occurs check)
unify' (TVar v) t = bindVar v t
unify' t (TVar v) = bindVar v t
-- TAny unifies with everything (dynamic / unknown)
unify' TAny _ = pure ()
unify' _ TAny = pure ()
-- base types: identical only
unify' TInt TInt = pure ()
unify' TFloat TFloat = pure ()
unify' TBool TBool = pure ()
unify' TString TString = pure ()
unify' (TStrLit _) (TStrLit _) = pure ()
unify' TString (TStrLit _) = pure ()
unify' (TStrLit _) TString = pure ()
unify' TPath TPath = pure ()
unify' TNull TNull = pure ()
unify' TDerivation TDerivation = pure ()
-- compound types: recurse structurally
unify' (TList a) (TList b) = unify a b
unify' (TFun a1 b1) (TFun a2 b2) = unify a1 a2 >> unify b1 b2
unify' (TRec m1 tl1) (TRec m2 tl2) = unifyRec m1 tl1 m2 tl2
-- union: check membership
unify' (TUnion ts) t = unifyUnion ts t
unify' t (TUnion ts) = unifyUnion ts t
-- function vs attrset: try functor protocol
unify' (TFun argT retT) attrsT = unifyFunctor (TFun argT retT) attrsT
unify' attrsT (TFun argT retT) = unifyFunctor (TFun argT retT) attrsT
unify' type1 type2 = typeMismatch type1 type2

-- | bind a type variable to a concrete type (with occurs check)
bindVar :: TypeVar -> NixType -> Infer ()
bindVar v t
  | t == TVar v = pure ()
  | occursCheck v t =
      throwTypeError $ "infinite type: " <> prettyType (TVar v) <> " occurs in " <> prettyType t
  | otherwise = addSubst v t

-- | occurs check: does v appear free inside t? (prevents infinite types)
occursCheck :: TypeVar -> NixType -> Bool
occursCheck v (TVar typeVariable') = v == typeVariable'
occursCheck v (TList t) = occursCheck v t
occursCheck v (TFun a b) = occursCheck v a || occursCheck v b
occursCheck v (TRec m tail_) =
  any (occursCheck v . fst) (Map.elems m) || rowHas tail_
 where
  rowHas (ROpen r) = v == r
  rowHas RClosed = False
occursCheck v (TUnion ts) = any (occursCheck v) ts
occursCheck _ _ = False

-- | unify two closed attr sets: all keys must match, required fields must exist
unifyAttrs :: Map Text (NixType, Bool) -> Map Text (NixType, Bool) -> Infer ()
unifyAttrs m1 m2 = forM_ (Set.toList allKeys) reconcile
 where
  allKeys = Set.union (Map.keysSet m1) (Map.keysSet m2)
  reconcile k = step (Map.lookup k m1) (Map.lookup k m2)
   where
    step (Just (t1, _)) (Just (t2, _)) = unify t1 t2
    step (Just (_, False)) Nothing = throwTypeError $ "missing required field: " <> k
    step Nothing (Just (_, False)) = throwTypeError $ "unexpected field (required in other): " <> k
    step _ _ = pure ()

{- | Unify two records, row-variable aware (RC1 core).

  * closed/closed: exact — delegated to 'unifyAttrs'.
  * open/closed: the open side's own required fields must exist in the closed
    side; the open tail var then absorbs the closed side's extra fields and is
    bound CLOSED.
  * open/open: common fields unified, and the two tail vars are bound to a
    SHARED fresh tail carrying each side's extra fields — so the field UNION is
    preserved across the unification (the old 'unifyAttrsOpenOpen' discarded it).

  The anonymous sentinel row var ('isAnonRowVar') is never bound, so pure
  flake/module display types keep their old open-world behavior.
-}
unifyRec :: Map Text (NixType, Bool) -> RowTail -> Map Text (NixType, Bool) -> RowTail -> Infer ()
unifyRec m1 tl1 m2 tl2 = dispatch tl1 tl2
 where
  dispatch RClosed RClosed = unifyAttrs m1 m2
  dispatch (ROpen r1) RClosed = unifyCommon >> closeAgainst r1 only1 only2
  dispatch RClosed (ROpen r2) = unifyCommon >> closeAgainst r2 only2 only1
  dispatch (ROpen r1) (ROpen r2)
    | isAnonRowVar r1 || isAnonRowVar r2 = unifyCommon
    | otherwise = do
        unifyCommon
        r3 <- freshTypeVar
        bindRowVar r1 (TRec only2 (ROpen r3))
        bindRowVar r2 (TRec only1 (ROpen r3))
  only1 = Map.difference m1 m2 -- fields known only on the left
  only2 = Map.difference m2 m1 -- fields known only on the right
  unifyCommon =
    mapM_ (\((t1, _), (t2, _)) -> unify t1 t2) (Map.elems (Map.intersectionWith (,) m1 m2))
  -- an open record (tail var r, own-only fields `openOnly`) meeting a closed
  -- side whose extras are `closedExtra`
  closeAgainst r openOnly closedExtra = do
    forM_ (Map.toList openOnly) $ \(k, (_, optional)) ->
      unless optional $
        throwTypeError ("closed record missing field required by open record: " <> k)
    unless (isAnonRowVar r) $ bindRowVar r (TRec closedExtra RClosed)

-- | bind a row variable (with row-occurs check; never binds the anon sentinel)
bindRowVar :: TypeVar -> NixType -> Infer ()
bindRowVar r t
  | isAnonRowVar r = pure ()
  | occursCheck r t =
      throwTypeError $ "recursive row type: " <> prettyType (TVar r) <> " occurs in " <> prettyType t
  | otherwise = addSubst r t

{- | unify a union (sum) type against a concrete type
single-element unions delegate; multi-element checks membership
-}
unifyUnion :: [NixType] -> NixType -> Infer ()
unifyUnion [] _ = pure ()
unifyUnion [t'] t = unify t' t
unifyUnion ts t = do
  t' <- applyCurrentSubst t
  ts' <- mapM applyCurrentSubst ts
  checkUnionMembership t' ts'
 where
  -- flatten nested unions so membership sees the leaves (REVIEW-3 #25)
  flatten (TUnion us) = concatMap flatten us
  flatten x = [x]
  checkUnionMembership t' ts'
    | TVar _ <- t' = pure ()
    | t' `elem` concatMap flatten ts' = pure ()
    | otherwise =
        throwTypeError $
          "type mismatch: expected one of "
            <> T.intercalate " | " (map prettyType ts)
            <> ", got "
            <> prettyType t'

-- ── type merging (for branches / polymorphic result combination) ──

{- | merge two types into their least upper bound (join)
differs from unify in that it produces a result rather than asserting equality
-}
mergeTypes :: NixType -> NixType -> Infer NixType
mergeTypes type1 type2 = do
  t1' <- applyCurrentSubst type1
  t2' <- applyCurrentSubst type2
  merge t1' t2'
 where
  -- variable on either side: bind and return
  merge (TVar v) t = bindVar v t >> pure t
  merge t (TVar v) = bindVar v t >> pure t
  -- TAny absorbs anything
  merge TAny _ = pure TAny
  merge _ TAny = pure TAny
  -- attrs: merge field-by-field
  merge (TAttrs m1) (TAttrs m2) = mergeAttrs m1 m2
  merge (TList e1) (TList e2) = TList <$> mergeTypes e1 e2
  merge (TFun a1 b1) (TFun a2 b2) = do
    unify a1 a2
    res <- mergeTypes b1 b2
    pure $ TFun a1 res
  -- identical base types: return as-is
  merge a b | a == b = pure a
  -- otherwise: produce a union
  merge a b = pure $ TUnion [a, b]

-- | merge two attr types field-by-field, marking optional any field present in only one
mergeAttrs :: Map Text (NixType, Bool) -> Map Text (NixType, Bool) -> Infer NixType
mergeAttrs m1 m2 = do
  fields <- forM (Set.toList keys) field
  pure $ TAttrs (Map.fromList fields)
 where
  keys = Set.union (Map.keysSet m1) (Map.keysSet m2)
  field k = combine (Map.lookup k m1) (Map.lookup k m2)
   where
    combine (Just (t1, o1)) (Just (t2, o2)) = do
      t <- mergeTypes t1 t2
      pure (k, (t, o1 || o2))
    combine (Just (t1, _)) Nothing = pure (k, (t1, True))
    combine Nothing (Just (t2, _)) = pure (k, (t2, True))
    combine Nothing Nothing = throwTypeError $ "internal error: key " <> k <> " missing from both attr sets"

{- | constrain a field in a scope type to a specific type
used by `with` scope resolution
-}
fieldConstraint :: Text -> NixType -> NixType -> Infer ()
fieldConstraint name scopeT valueT
  | TAttrs m <- scopeT = lookupAndUnify name valueT m
  | TAttrsOpen m <- scopeT = lookupAndUnify name valueT m
  | TVar _ <- scopeT = do
      r <- freshTypeVar
      let fieldType = TRec (Map.singleton name (valueT, False)) (ROpen r)
      unify scopeT fieldType
  | otherwise = pure ()
 where
  lookupAndUnify k v m = maybe (pure ()) (\(ft, _) -> unify v ft) (Map.lookup k m)
