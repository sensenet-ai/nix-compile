{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : NixCompile.Schema.Build
-- Description : Build schema from facts and substitution
--
-- Takes the raw facts and solved type substitution and produces
-- the final schema with resolved types.
module NixCompile.Schema.Build
  ( buildSchema,
    resolveType,
    wasDefaulted,
    validateConfigPaths,
  )
where

import Data.List (tails)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import NixCompile.Types

-- | Validate config paths before building a tree.
-- A config tree cannot represent a path as both a leaf and a branch:
--   config.server="$HOST"
--   config.server.port=$PORT
-- Reject these prefix conflicts instead of silently dropping one side.
validateConfigPaths :: [Fact] -> Either Text ()
validateConfigPaths facts =
  case [(a, b) | (a : rest) <- tails paths, b <- rest, conflicts a b] of
    [] -> Right ()
    ((a, b) : _) ->
      Left $ "conflicting config paths: " <> pathText a <> " and " <> pathText b
  where
    paths = [p | ConfigAssign p _ _ _ <- facts] ++ [p | ConfigLit p _ _ <- facts] ++ [p | ConfigTemplate p _ _ _ <- facts]

    conflicts a b = a /= b && (a `isPrefixOfPath` b || b `isPrefixOfPath` a)

    isPrefixOfPath [] _ = True
    isPrefixOfPath _ [] = False
    isPrefixOfPath (x : xs) (y : ys) = x == y && isPrefixOfPath xs ys

    pathText = T.intercalate "."

-- | Build schema from facts and type substitution
buildSchema :: [Fact] -> Subst -> Schema
buildSchema facts subst =
  let envSchema = buildEnvSchema facts subst
      defaulted = filter (wasDefaulted subst) (Map.keys envSchema)
   in Schema
        { schemaEnv = envSchema,
          schemaConfig = buildConfigSchema facts subst,
          schemaCommands = buildCommandSchema facts,
          schemaStorePaths = collectStorePaths facts,
          schemaBareCommands = collectBareCommands facts,
          schemaDynamicCommands = collectDynamicCommands facts,
          schemaDefaultedVars = defaulted
        }

-- | Build environment variable schema
buildEnvSchema :: [Fact] -> Subst -> Map Text EnvSpec
buildEnvSchema facts subst = Map.fromListWith mergeEnvSpec (concatMap go facts)
  where
    go = \case
      DefaultIs var lit sp ->
        [(var, EnvSpec (resolveType subst var) False (Just lit) sp)]
      DefaultFrom var _ sp ->
        [(var, EnvSpec (resolveType subst var) False Nothing sp)]
      Required var sp ->
        [(var, EnvSpec (resolveType subst var) True Nothing sp)]
      AssignLit var lit sp ->
        [(var, EnvSpec (resolveType subst var) False (Just lit) sp)]
      AssignFrom var _ sp ->
        [(var, EnvSpec (resolveType subst var) False Nothing sp)]
      ConfigAssign _ var _ sp ->
        [(var, EnvSpec (resolveType subst var) False Nothing sp)]
      ConfigTemplate _ parts _ sp ->
        [ (var, EnvSpec (resolveType subst var) False Nothing sp)
        | var <- configPartVars parts
        ]
      -- Command argument usage: infer type from builtin database
      CmdArg _ _ var sp ->
        [(var, EnvSpec (resolveType subst var) False Nothing sp)]
      _ -> []

configPartVars :: [ConfigPart] -> [Text]
configPartVars = concatMap $ \case
  ConfigVar var -> [var]
  ConfigVarDefault var _ -> [var]
  ConfigVarRequired var -> [var]
  ConfigVarAlternate var _ -> [var]
  ConfigText _ -> []

-- | Build config schema
-- Uses Map.fromList which keeps the last entry for duplicate keys,
-- matching bash runtime semantics where the last assignment wins.
buildConfigSchema :: [Fact] -> Subst -> Map ConfigPath ConfigSpec
buildConfigSchema facts subst = Map.fromList (concatMap go facts)
  where
    go = \case
      ConfigAssign path var quoted sp ->
        [(path, ConfigSpec (resolveType subst var) (Just var) (Just quoted) Nothing Nothing sp)]
      ConfigLit path lit sp ->
        [(path, ConfigSpec (literalType lit) Nothing Nothing (Just lit) Nothing sp)]
      ConfigTemplate path parts quoted sp ->
        [(path, ConfigSpec TString Nothing (Just quoted) Nothing (Just parts) sp)]
      _ -> []

-- | Build command schema
buildCommandSchema :: [Fact] -> [CommandSpec]
buildCommandSchema facts = concatMap go facts
  where
    go = \case
      UsesStorePath storePath sp ->
        [CommandSpec (extractName storePath) (Just storePath) sp]
      BareCommand cmd sp ->
        [CommandSpec cmd Nothing sp]
      _ -> []
    extractName :: StorePath -> Text
    extractName (StorePath p) =
      -- /nix/store/hash-name/bin/cmd -> cmd
      case reverse (T.splitOn "/" p) of
        (cmd : _) | not (T.null cmd) -> cmd
        _ -> p

-- | Collect store paths
collectStorePaths :: [Fact] -> Set StorePath
collectStorePaths facts = Set.fromList [sp | UsesStorePath sp _ <- facts]

-- | Collect bare commands
collectBareCommands :: [Fact] -> [Text]
collectBareCommands facts = [cmd | BareCommand cmd _ <- facts]

-- | Collect dynamic commands
collectDynamicCommands :: [Fact] -> [Text]
collectDynamicCommands facts = [var | DynamicCommand var _ <- facts]

-- | Resolve a variable's type from substitution.
-- Returns the resolved type and whether a default was applied (TVar -> TString).
resolveType :: Subst -> Text -> Type
resolveType subst var =
  applyDefaults (applySubst subst (TVar (TypeVar var)))

-- | Check whether a variable's type was defaulted (unresolved TVar -> TString).
wasDefaulted :: Subst -> Text -> Bool
wasDefaulted subst var =
  case applySubst subst (TVar (TypeVar var)) of
    TVar _ -> True
    _ -> False

-- | Apply defaults: TNumeric -> TInt, TVar -> TString.
-- Unresolved type variables become TString as a conservative default.
-- Use 'wasDefaulted' to detect when this occurs.
applyDefaults :: Type -> Type
applyDefaults = \case
  TNumeric -> TInt
  TVar _ -> TString -- unresolved becomes string (conservative)
  t -> t
