{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                // inference // nix // environment
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "A name is a powerful thing, in the hands of those who know how to use it."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The typing environment threaded through inference: name → scheme bindings,
--   the enclosing `with` scope, and the per-file imported-module types. Pure
--   data + accessors, no Infer monad — it sits at the bottom of the engine's
--   dependency graph so everything above can name it.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Inference.Nix.Environment (
  TypeEnv (..),
  emptyEnv,
  extendEnv,
  lookupEnv,
  extendImport,
  extendImports,
  lookupImport,
)
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import NixCompile.Inference.Nix.Type

{- | the typing environment threaded through inference: name → scheme bindings,
the enclosing @with@ scope, per-file imported-module types, and the lenient /
module-param mode flags.
-}
data TypeEnv = TypeEnv
  { envBindings :: Map Text Scheme
  , envWith :: Maybe NixType
  , envImportTypes :: Map FilePath NixType
  , envLenient :: Bool
  {- ^ when True, treat unbound names as fresh polymorphic vars instead of
    errors. Used for backwards compatibility with libraries that mention
    builtins we don't yet model. Default: False (strict).
  -}
  , envModuleParams :: Bool
  {- ^ when True, lambda parameters whose names are well-known external module
    / flake inputs (self, inputs, config, pkgs, the @-bound input set, …) are
    typed as dynamic ('TAny') rather than fresh inference vars. These values are
    supplied by the flake / module system, not by the file under analysis, so
    inferring precise types for them only produces false positives (e.g. the
    self-referential @inputs in `mkFlake { inherit inputs; }`). Matched by name
    so ordinary inner lambdas (`x: x + 1`) keep precise inference. Default: False.
  -}
  }
  deriving (Eq, Show)

-- | the empty environment: no bindings, no @with@, no imports, strict mode.
emptyEnv :: TypeEnv
emptyEnv = TypeEnv Map.empty Nothing Map.empty False False

{- | extend the env with one name → scheme binding
n.b. this shadows — if a name already exists the new scheme wins
-}
extendEnv :: Text -> Scheme -> TypeEnv -> TypeEnv
extendEnv name scheme environment =
  environment{envBindings = Map.insert name scheme (envBindings environment)}

-- | look up a name; returns Nothing if absent (type defaults to fresh var downstream)
lookupEnv :: Text -> TypeEnv -> Maybe Scheme
lookupEnv name environment = Map.lookup name (envBindings environment)

-- | register the exported type of an imported file
extendImport :: FilePath -> NixType -> TypeEnv -> TypeEnv
extendImport path t env = env{envImportTypes = Map.insert path t (envImportTypes env)}

-- | extend env with multiple imported modules at once
extendImports :: Map FilePath NixType -> TypeEnv -> TypeEnv
extendImports imports env = env{envImportTypes = Map.union imports (envImportTypes env)}

-- | look up a previously imported module's type
lookupImport :: FilePath -> TypeEnv -> Maybe NixType
lookupImport path env = Map.lookup path (envImportTypes env)
