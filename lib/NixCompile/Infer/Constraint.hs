{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                    // infer // constraint
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "At least, he thought, as the duster's angry gibberish faded behind him,
--    the gangs gave you some structure. If you were Gothick and the Kasuals
--    chopped you out, it made sense. Maybe the ultimate reasons behind it
--    were crazy, but there were rules."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                       // facts to // constraints
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Infer.Constraint (
  factsToConstraints,
  factToConstraints,
)
where

import NixCompile.Bash.Builtins (lookupArgType)
import NixCompile.Types

-- | Convert all facts to constraints
factsToConstraints :: [Fact] -> [Constraint]
factsToConstraints = concatMap factToConstraints

-- | Convert a single fact to constraints
factToConstraints :: Fact -> [Constraint]
factToConstraints = \case
  DefaultIs variable literal _ ->
    [TVar (TypeVar variable) :~: literalType literal]
  DefaultFrom variable otherVariable _ ->
    [TVar (TypeVar variable) :~: TVar (TypeVar otherVariable)]
  Required _ _ ->
    []
  AssignFrom variable otherVariable _ ->
    [TVar (TypeVar variable) :~: TVar (TypeVar otherVariable)]
  AssignLit variable literal _ ->
    [TVar (TypeVar variable) :~: literalType literal]
  ConfigAssign _ _ _ _ ->
    []
  ConfigLit _ _ _ ->
    []
  ConfigTemplate _ _ _ _ ->
    []
  CmdArg command argumentName variableName _ ->
    case lookupArgType command argumentName of
      Just resolvedType -> [TVar (TypeVar variableName) :~: resolvedType]
      Nothing -> []
  UsesStorePath _ _ ->
    []
  BareCommand _ _ ->
    []
  DynamicCommand _ _ ->
    []
