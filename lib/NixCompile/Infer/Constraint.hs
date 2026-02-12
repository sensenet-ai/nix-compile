{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : NixCompile.Infer.Constraint
-- Description : Generate type constraints from facts
--
-- Transforms observations (Facts) into equality constraints for unification.
-- Constraints carry source locations for error reporting.
module NixCompile.Infer.Constraint
  ( factsToConstraints,
    factToConstraints,
    factsToLocatedConstraints,
    factToLocatedConstraints,
  )
where

import NixCompile.Bash.Builtins (lookupArgType, lookupPositionalType)
import NixCompile.Types

-- | Convert all facts to located constraints (preferred API)
factsToLocatedConstraints :: [Fact] -> [LocatedConstraint]
factsToLocatedConstraints = concatMap factToLocatedConstraints

-- | Convert a single fact to located constraints
factToLocatedConstraints :: Fact -> [LocatedConstraint]
factToLocatedConstraints = \case
  -- VAR has a literal default: VAR ~ type(literal)
  DefaultIs var lit sp ->
    [LocatedConstraint (TVar (TypeVar var) :~: literalType lit) sp]
  -- VAR defaults to OTHER: VAR ~ OTHER
  DefaultFrom var other sp ->
    [LocatedConstraint (TVar (TypeVar var) :~: TVar (TypeVar other)) sp]
  -- VAR is required: no type constraint, just existence
  Required _ _ ->
    []
  -- VAR = OTHER: VAR ~ OTHER
  AssignFrom var other sp ->
    [LocatedConstraint (TVar (TypeVar var) :~: TVar (TypeVar other)) sp]
  -- VAR = literal: VAR ~ type(literal)
  AssignLit var lit sp ->
    [LocatedConstraint (TVar (TypeVar var) :~: literalType lit) sp]
  -- config.x.y = $VAR or "$VAR": no type constraint on VAR
  ConfigAssign _ _ _ _ ->
    []
  -- config.x.y = literal: no variable constraint
  ConfigLit _ _ _ ->
    []
  -- Command arg with known type: look up in builtins
  CmdArg cmd argName varName sp ->
    case lookupArgType cmd argName of
      Just ty -> [LocatedConstraint (TVar (TypeVar varName) :~: ty) sp]
      Nothing -> []
  -- Command positional arg with known type: look up in builtins
  CmdPositional cmd pos varName sp ->
    case lookupPositionalType cmd pos of
      Just ty -> [LocatedConstraint (TVar (TypeVar varName) :~: ty) sp]
      Nothing -> []
  -- Store path usage: no type constraint
  UsesStorePath _ _ ->
    []
  -- Bare command: no type constraint
  BareCommand _ _ ->
    []
  -- Dynamic command: no type constraint
  DynamicCommand _ _ ->
    []
  -- Observed variable: no type constraint
  Observed _ _ ->
    []

-- | Legacy API: Convert all facts to unlocated constraints
factsToConstraints :: [Fact] -> [Constraint]
factsToConstraints = concatMap factToConstraints

-- | Legacy API: Convert a single fact to unlocated constraints
factToConstraints :: Fact -> [Constraint]
factToConstraints fact =
  map lcConstraint (factToLocatedConstraints fact)
