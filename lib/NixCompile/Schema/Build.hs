{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                    // schema // builders
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Someone brought the machine here, welded it to the dome, and wired it
--    to the traces of memory. And spilled, somehow, all the worn sad evidence
--    of a family's humanity, and left it all to be stirred, to be sorted by
--    a poet. To be sealed away in boxes. I know of no more extraordinary work
--    than this. No more complex gesture..."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // schema // from facts
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Schema.Build (
  buildSchema,
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

{- | Validate config paths before building a tree.
A config tree cannot represent a path as both a leaf and a branch:
  config.server="$HOST"
  config.server.port=$PORT
Reject these prefix conflicts instead of silently dropping one side.
-}
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
        { schemaEnv = envSchema
        , schemaConfig = buildConfigSchema facts subst
        , schemaCommands = buildCommandSchema facts
        , schemaStorePaths = collectStorePaths facts
        , schemaBareCommands = collectBareCommands facts
        , schemaDynamicCommands = collectDynamicCommands facts
        , schemaDefaultedVars = defaulted
        }

-- | Build environment variable schema
buildEnvSchema :: [Fact] -> Subst -> Map Text EnvSpec
buildEnvSchema facts subst = Map.fromListWith mergeEnvSpec (concatMap factToEnvSpec facts)
 where
  factToEnvSpec = \case
    DefaultIs variable literal sourceSpan ->
      [(variable, EnvSpec (resolveType subst variable) False (Just literal) sourceSpan)]
    DefaultFrom variable _ sourceSpan ->
      [(variable, EnvSpec (resolveType subst variable) False Nothing sourceSpan)]
    Required variable sourceSpan ->
      [(variable, EnvSpec (resolveType subst variable) True Nothing sourceSpan)]
    AssignLit variable literal sourceSpan ->
      [(variable, EnvSpec (resolveType subst variable) False (Just literal) sourceSpan)]
    AssignFrom variable _ sourceSpan ->
      [(variable, EnvSpec (resolveType subst variable) False Nothing sourceSpan)]
    ConfigAssign _ variable _ sourceSpan ->
      [(variable, EnvSpec (resolveType subst variable) False Nothing sourceSpan)]
    ConfigTemplate _ parts _ sourceSpan ->
      [ (variable, EnvSpec (resolveType subst variable) False Nothing sourceSpan)
      | variable <- configPartVars parts
      ]
    CmdArg _ _ variable sourceSpan ->
      [(variable, EnvSpec (resolveType subst variable) False Nothing sourceSpan)]
    _ -> []

configPartVars :: [ConfigPart] -> [Text]
configPartVars = concatMap $ \case
  ConfigVar var -> [var]
  ConfigVarDefault var _ -> [var]
  ConfigVarRequired var -> [var]
  ConfigVarAlternate var _ -> [var]
  ConfigText _ -> []

-- | Build config schema
buildConfigSchema :: [Fact] -> Subst -> Map ConfigPath ConfigSpec
buildConfigSchema facts subst = Map.fromListWith mergeConfigSpec (concatMap factToConfigSpec facts)
 where
  factToConfigSpec = \case
    ConfigAssign path variable quoted sourceSpan ->
      [(path, ConfigSpec (resolveType subst variable) (Just variable) (Just quoted) Nothing Nothing sourceSpan)]
    ConfigLit path literal sourceSpan ->
      [(path, ConfigSpec (literalType literal) Nothing Nothing (Just literal) Nothing sourceSpan)]
    ConfigTemplate path parts quoted sourceSpan ->
      [(path, ConfigSpec TString Nothing (Just quoted) Nothing (Just parts) sourceSpan)]
    _ -> []

-- | Build command schema
buildCommandSchema :: [Fact] -> [CommandSpec]
buildCommandSchema facts = concatMap factToCommandSpec facts
 where
  factToCommandSpec = \case
    UsesStorePath storePath sourceSpan ->
      [CommandSpec (extractName storePath) (Just storePath) sourceSpan]
    BareCommand command sourceSpan ->
      [CommandSpec command Nothing sourceSpan]
    _ -> []
  extractName :: StorePath -> Text
  extractName (StorePath path) =
    case reverse (T.splitOn "/" path) of
      (command : _) | not (T.null command) -> command
      _ -> path

-- | Collect store paths
collectStorePaths :: [Fact] -> Set StorePath
collectStorePaths facts = Set.fromList [storePath | UsesStorePath storePath _ <- facts]

-- | Collect bare commands
collectBareCommands :: [Fact] -> [Text]
collectBareCommands facts = [command | BareCommand command _ <- facts]

-- | Collect dynamic commands
collectDynamicCommands :: [Fact] -> [Text]
collectDynamicCommands facts = [variable | DynamicCommand variable _ <- facts]

{- | Resolve a variable's type from substitution.
Returns the resolved type and whether a default was applied (TVar -> TString).
-}
resolveType :: Subst -> Text -> Type
resolveType substitution variable =
  applyDefaults (applySubst substitution (TVar (TypeVar variable)))

-- | Check whether a variable's type was defaulted (unresolved TVar -> TString).
wasDefaulted :: Subst -> Text -> Bool
wasDefaulted substitution variable =
  case applySubst substitution (TVar (TypeVar variable)) of
    TVar _ -> True
    _ -> False

{- | Apply defaults: TNumeric -> TInt, TVar -> TString.
Unresolved type variables become TString as a conservative default.
Use 'wasDefaulted' to detect when this occurs.
-}
applyDefaults :: Type -> Type
applyDefaults = \case
  TNumeric -> TInt
  TVar _ -> TString
  typeValue -> typeValue
