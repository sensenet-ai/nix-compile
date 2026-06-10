{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                                  // bash // types
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He had a feel for the shape of the data, the way a sculptor feels the
--    stone."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The shared vocabulary of the bash analysis pipeline: the small type
--   language ('Type' / 'Subst' / 'Constraint') its Hindley-Milner solver runs
--   on, the 'Fact's the parser observes, the 'Command' / config / store-path
--   model, and the 'Schema' those facts resolve into. Source locations live in
--   'NixCompile.Core.Span'; everything here is bash-pipeline-specific.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Bash.Types (
  -- * Types
  Type (..),
  TypeVar (..),

  -- * Constraints
  Constraint (..),
  Subst,
  emptySubst,
  singleSubst,
  composeSubst,
  applySubst,

  -- * Literals
  Literal (..),
  literalType,

  -- * Facts (observations from parsing)
  Fact (..),
  Quoted (..),

  -- * Config paths
  ConfigPath,
  ConfigPart (..),

  -- * Commands
  Command (..),
  Arg (..),

  -- * Store paths
  StorePath (..),
  isStorePath,

  -- * Schema (final output)
  Schema (..),
  EnvSpec (..),
  mergeEnvSpec,
  ConfigSpec (..),
  mergeConfigSpec,
  CommandSpec (..),
  emptySchema,
  mergeSchemas,

  -- * Scripts
  Script (..),

  -- * Errors
  TypeError (..),
)
where

import GHC.Generics (Generic)

import Control.Applicative ((<|>))
import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import NixCompile.Core.Span (Span (..))

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Types
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

newtype TypeVar = TypeVar {unTypeVar :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

data Type
  = TInt
  | TString
  | TBool
  | TPath
  | TNumeric
  | TVar TypeVar
  deriving stock (Eq, Ord, Show, Generic)

instance FromJSON Type
instance ToJSON Type

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Constraints
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data Constraint = Type :~: Type
  deriving stock (Eq, Show, Generic)

infix 4 :~:

type Subst = Map TypeVar Type

emptySubst :: Subst
emptySubst = Map.empty

singleSubst :: TypeVar -> Type -> Subst
singleSubst = Map.singleton

composeSubst :: Subst -> Subst -> Subst
composeSubst substitution1 substitution2 =
  Map.map (applySubst substitution1) substitution2 `Map.union` substitution1

applySubst :: Subst -> Type -> Type
applySubst substitution = go
 where
  go (TVar variable) = maybe (TVar variable) go (Map.lookup variable substitution)
  go typ = typ

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Literals
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data Literal
  = LitInt !Int
  | LitString !Text
  | LitBool !Bool
  | LitPath !StorePath
  deriving stock (Eq, Show, Generic)

instance FromJSON Literal
instance ToJSON Literal

literalType :: Literal -> Type
literalType (LitInt _) = TInt
literalType (LitString _) = TString
literalType (LitBool _) = TBool
literalType (LitPath _) = TPath

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Facts
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data Quoted = Quoted | Unquoted
  deriving stock (Eq, Show, Generic)

instance FromJSON Quoted
instance ToJSON Quoted

type ConfigPath = [Text]

data ConfigPart
  = ConfigText !Text
  | ConfigVar !Text
  | ConfigVarDefault !Text !Text
  | ConfigVarRequired !Text
  | ConfigVarAlternate !Text !Text
  deriving stock (Eq, Show, Generic)

instance FromJSON ConfigPart
instance ToJSON ConfigPart

data Fact
  = DefaultIs !Text !Literal !Span
  | DefaultFrom !Text !Text !Span
  | Required !Text !Span
  | AssignFrom !Text !Text !Span
  | AssignLit !Text !Literal !Span
  | ConfigAssign !ConfigPath !Text !Quoted !Span
  | ConfigLit !ConfigPath !Literal !Span
  | ConfigTemplate !ConfigPath ![ConfigPart] !Quoted !Span
  | CmdArg !Text !Text !Text !Span
  | UsesStorePath !StorePath !Span
  | BareCommand !Text !Span
  | DynamicCommand !Text !Span
  deriving stock (Eq, Show, Generic)

instance FromJSON Fact
instance ToJSON Fact

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Commands
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data Arg
  = ArgLit !Text
  | ArgVar !Text
  | ArgFlag !Text
  deriving stock (Eq, Show, Generic)

instance FromJSON Arg
instance ToJSON Arg

data Command = Command
  { cmdName :: !Text
  , cmdPath :: !(Maybe StorePath)
  , cmdArgs :: ![Arg]
  , cmdSpan :: !Span
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON Command
instance ToJSON Command

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Store Paths
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

newtype StorePath = StorePath {unStorePath :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

isStorePath :: Text -> Bool
isStorePath text =
  "/nix/store/" `T.isPrefixOf` text
    && not (".." `T.isInfixOf` text)
    && not ("//" `T.isInfixOf` text)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Schema
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data EnvSpec = EnvSpec
  { envType :: !Type
  , envRequired :: !Bool
  , envDefault :: !(Maybe Literal)
  , envSpan :: !Span
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON EnvSpec
instance ToJSON EnvSpec

mergeEnvSpec :: EnvSpec -> EnvSpec -> EnvSpec
mergeEnvSpec envSpec1 envSpec2 =
  EnvSpec
    { envType = envType envSpec1
    , envRequired = envRequired envSpec1 || envRequired envSpec2
    , -- keep envSpec1's default if it has one, else fall back to envSpec2's
      envDefault = envDefault envSpec1 <|> envDefault envSpec2
    , envSpan = envSpan envSpec1
    }

mergeConfigSpec :: ConfigSpec -> ConfigSpec -> ConfigSpec
mergeConfigSpec _ configSpec2 = configSpec2

data ConfigSpec = ConfigSpec
  { cfgType :: !Type
  , cfgFrom :: !(Maybe Text)
  , cfgQuoted :: !(Maybe Quoted)
  , cfgLit :: !(Maybe Literal)
  , cfgTemplate :: !(Maybe [ConfigPart])
  , cfgSpan :: !Span
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON ConfigSpec
instance ToJSON ConfigSpec

data CommandSpec = CommandSpec
  { cmdSpecName :: !Text
  , cmdSpecPath :: !(Maybe StorePath)
  , cmdSpecSpan :: !Span
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON CommandSpec
instance ToJSON CommandSpec

data Schema = Schema
  { schemaEnv :: !(Map Text EnvSpec)
  , schemaConfig :: !(Map ConfigPath ConfigSpec)
  , schemaCommands :: ![CommandSpec]
  , schemaStorePaths :: !(Set StorePath)
  , schemaBareCommands :: ![Text]
  , schemaDynamicCommands :: ![Text]
  , schemaDefaultedVars :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON Schema
instance ToJSON Schema

emptySchema :: Schema
emptySchema =
  Schema
    { schemaEnv = Map.empty
    , schemaConfig = Map.empty
    , schemaCommands = []
    , schemaStorePaths = Set.empty
    , schemaBareCommands = []
    , schemaDynamicCommands = []
    , schemaDefaultedVars = []
    }

mergeSchemas :: Schema -> Schema -> Schema
mergeSchemas schema1 schema2 =
  Schema
    { schemaEnv = Map.unionWith mergeEnvSpec (schemaEnv schema1) (schemaEnv schema2)
    , schemaConfig = schemaConfig schema1 `Map.union` schemaConfig schema2
    , schemaCommands = schemaCommands schema1 ++ schemaCommands schema2
    , schemaStorePaths = schemaStorePaths schema1 `Set.union` schemaStorePaths schema2
    , schemaBareCommands = schemaBareCommands schema1 ++ schemaBareCommands schema2
    , schemaDynamicCommands = schemaDynamicCommands schema1 ++ schemaDynamicCommands schema2
    , schemaDefaultedVars = schemaDefaultedVars schema1 ++ schemaDefaultedVars schema2
    }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Scripts
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data Script = Script
  { scriptSource :: !Text
  , scriptFacts :: ![Fact]
  , scriptSchema :: !Schema
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON Script
instance ToJSON Script

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Errors
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data TypeError
  = Mismatch !Type !Type !Span
  | OccursCheck !TypeVar !Type !Span
  | Ambiguous !TypeVar !Span
  deriving stock (Eq, Show, Generic)

instance FromJSON TypeError
instance ToJSON TypeError
