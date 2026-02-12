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
    extractInterpTypes,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import NixCompile.Types

-- | Build schema from facts and type substitution
buildSchema :: [Fact] -> Subst -> Schema
buildSchema facts subst =
  Schema
    { schemaEnv = buildEnvSchema facts subst,
      schemaConfig = buildConfigSchema facts subst,
      schemaCommands = buildCommandSchema facts,
      schemaStorePaths = collectStorePaths facts,
      schemaBareCommands = collectBareCommands facts,
      schemaDynamicCommands = collectDynamicCommands facts
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
      -- Command argument usage: infer type from builtin database
      CmdArg _ _ var sp ->
        [(var, EnvSpec (resolveType subst var) False Nothing sp)]
      -- Command positional argument: infer type from builtin database
      CmdPositional _ _ var sp ->
        [(var, EnvSpec (resolveType subst var) False Nothing sp)]
      -- Observed variable: register in env but not required
      Observed var sp ->
        [(var, EnvSpec (resolveType subst var) False Nothing sp)]
      _ -> []

-- | Merge two env specs (prefer required, keep first default)
mergeEnvSpec :: EnvSpec -> EnvSpec -> EnvSpec
mergeEnvSpec e1 e2 =
  EnvSpec
    { envType = envType e1, -- take first (arbitrary)
      envRequired = envRequired e1 || envRequired e2,
      envDefault = envDefault e1 <|> envDefault e2,
      envSpan = envSpan e1
    }
  where
    Nothing <|> b = b
    a <|> _ = a

-- | Build config schema
buildConfigSchema :: [Fact] -> Subst -> Map ConfigPath ConfigSpec
buildConfigSchema facts subst = Map.fromList (concatMap go facts)
  where
    go = \case
      ConfigAssign path var quoted sp ->
        [(path, ConfigSpec (resolveType subst var) (Just var) (Just quoted) Nothing sp)]
      ConfigLit path lit sp ->
        [(path, ConfigSpec (literalType lit) Nothing Nothing (Just lit) sp)]
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

-- | Extract types inferred for Nix interpolation placeholders
-- Returns a map from interpolation index to inferred type
-- Only includes interpolations where we actually inferred a concrete type
extractInterpTypes :: Schema -> Map Int Type
extractInterpTypes schema = Map.fromList
  [ (idx, envType spec)
  | (var, spec) <- Map.toList (schemaEnv schema)
  , "__nix_interp_" `T.isPrefixOf` var
  , "__" `T.isSuffixOf` var
  , Just idx <- [parseInterpIndex var]
  , envType spec /= TString  -- Only report if we inferred something specific
  ]
  where
    parseInterpIndex :: Text -> Maybe Int
    parseInterpIndex t = 
      let middle = T.drop 13 (T.dropEnd 2 t)  -- Drop "__nix_interp_" and "__"
      in case TR.decimal middle of
           Right (n, "") -> Just n
           _ -> Nothing

-- | Resolve a variable's type from substitution
resolveType :: Subst -> Text -> Type
resolveType subst var =
  applyDefaults (applySubst subst (TVar (TypeVar var)))

-- | Apply defaults: unresolved type variables become TString
applyDefaults :: Type -> Type
applyDefaults = \case
  TVar _ -> TString -- unresolved becomes string
  t -> t
