{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                // inference // nix // scheme
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "A scheme, a plan, a thing of beauty and precision."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The two halves of Hindley-Milner let-polymorphism: 'instantiate' hands each
--   use-site a fresh copy of a scheme's quantified vars, and 'generalize' closes
--   a type over the vars the environment does not mention. Both run in the Infer
--   monad ('Constraint').
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Inference.Nix.Scheme (
  instantiate,
  generalize,
  applyCurrentSubstScheme,
)
where

import Control.Monad.State.Strict (gets)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import NixCompile.Inference.Nix.Constraint
import NixCompile.Inference.Nix.Environment
import NixCompile.Inference.Nix.Type

{- | instantiate a polymorphic scheme by replacing each quantified var with a fresh type var
this is HM-style let-polymorphism: each use-site gets its own copy
-}
instantiate :: Scheme -> Infer NixType
instantiate (Forall vars t) = do
  freshVars <- mapM (const freshVar) vars
  let subst = Map.fromList (zip vars freshVars)
  pure $ applySubst subst t

{- | generalize (close over) free type vars not free in the environment
this implements HM let-polymorphism: only quantify vars the env doesn't mention
-}
generalize :: TypeEnv -> NixType -> Infer Scheme
generalize environment t = do
  t' <- applyCurrentSubst t
  envSchemes <- mapM applyCurrentSubstScheme (Map.elems (envBindings environment))
  let freeInEnv = Set.unions (map freeTypeVarsScheme envSchemes)
  let freeInT = freeTypeVars t'
  let vars = Set.toList (freeInT `Set.difference` freeInEnv)
  pure $ Forall vars t'

-- | apply current subst to all type variables in a scheme
applyCurrentSubstScheme :: Scheme -> Infer Scheme
applyCurrentSubstScheme s = do
  subst <- gets inferSubst
  pure $ applySubstScheme subst s
