{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // nix // module
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "And the next. And ever was."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // module // graph
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Layout.Graph (
  -- * Module graph
  ModuleGraph (..),
  Module (..),
  Import (..),
  ParseFailure (..),
  LintFailure (..),
  LayoutFailure (..),

  -- * Building
  buildModuleGraph,
  buildModuleGraphFromFlake,

  -- * Queries
  moduleImports,
  moduleDependents,
  topologicalOrder,
  hasViolations,
  totalViolationCount,
  moduleTypes,

  -- * Import extraction
  findImports,
)
where

import Control.Monad (foldM)
import Data.Coerce (coerce)
import Data.List (isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Expr.Types hiding (Binding)
import Nix.Expr.Types qualified as Nix
import Nix.Expr.Types.Annotated
import Nix.Utils qualified as NixPath
import NixCompile.Layout.Convention (Convention, LayoutError, validateFileFromExpr)
import NixCompile.Lint.Nix (NixViolation, findNixViolations)
import NixCompile.Nix.Inference (builtinEnv, extendImport, inferExpr, inferExprWithEnv)
import NixCompile.Nix.Types
import NixCompile.Nix.Utils (srcSpanToSpan, pattern Layer, pattern LayerAnn)
import NixCompile.Safety qualified as Safety
import NixCompile.Types (Span)
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (normalise, pathSeparator, takeDirectory, (</>))

-- ═════════════════════════════════════════════════════════════════════════════
-- types
-- ═════════════════════════════════════════════════════════════════════════════

data Module = Module
  { modPath :: !FilePath
  , modExpr :: !NExprLoc
  , modType :: !NixType
  , modImports :: ![Import]
  }
  deriving (Show)

data Import = Import
  { impPath :: !FilePath
  , impRawPath :: !Text
  , impArgs :: !(Maybe NExprLoc)
  , impSpan :: !Span
  }
  deriving (Show)

data ParseFailure = ParseFailure
  { pfPath :: !FilePath
  , pfError :: !Text
  }
  deriving (Show)

data LintFailure = LintFailure
  { lfPath :: !FilePath
  , lfViolations :: ![NixViolation]
  }
  deriving (Show)

data LayoutFailure = LayoutFailure
  { layPath :: !FilePath
  , layViolations :: ![LayoutError]
  }
  deriving (Show)

data ModuleGraph = ModuleGraph
  { mgModules :: !(Map FilePath Module)
  , mgRoot :: !FilePath
  , mgOrder :: ![FilePath]
  , mgFailures :: ![ParseFailure]
  , mgLintFailures :: ![LintFailure]
  , mgLayoutFailures :: ![LayoutFailure]
  , mgModuleTypes :: !(Map FilePath NixType)
  }
  deriving (Show)

-- ═════════════════════════════════════════════════════════════════════════════
-- building
-- ═════════════════════════════════════════════════════════════════════════════

data BuildState = BuildState
  { bsModules :: !(Map FilePath Module)
  , bsFailures :: ![ParseFailure]
  , bsLintFailures :: ![LintFailure]
  , bsLayoutFailures :: ![LayoutFailure]
  }

-- ── entry points ─────────────────────────────────────────────────

{- | build a complete module graph starting from a root nix file
resolves imports transitively, computes topological order, collects failures,
then infers types in topological order with cross-module type propagation
-}
buildModuleGraph :: Convention -> FilePath -> IO (Either Text ModuleGraph)
buildModuleGraph conv rootPath = do
  canonRoot <- canonicalizePath rootPath
  let rootDir = takeDirectory canonRoot
  finalState <- buildModules conv rootDir canonRoot Set.empty (BuildState Map.empty [] [] [])
  let order = computeOrder canonRoot (bsModules finalState)
  let moduleGraph =
        ModuleGraph
          { mgModules = bsModules finalState
          , mgRoot = canonRoot
          , mgOrder = order
          , mgFailures = reverse (bsFailures finalState)
          , mgLintFailures = reverse (bsLintFailures finalState)
          , mgLayoutFailures = reverse (bsLayoutFailures finalState)
          , mgModuleTypes = Map.empty
          }
  finalGraph <- inferModuleTypes moduleGraph
  pure $ Right finalGraph

-- | build module graph starting from flake.nix in the given directory
buildModuleGraphFromFlake :: Convention -> FilePath -> IO (Either Text ModuleGraph)
buildModuleGraphFromFlake conv dir = do
  let flakePath = dir </> "flake.nix"
  exists <- doesFileExist flakePath
  if exists
    then buildModuleGraph conv flakePath
    else pure $ Left $ "No flake.nix found in " <> T.pack dir

-- ── recursive module loading ─────────────────────────────────────

-- | build modules by recursively walking imports, guarding against cycles via visited set
buildModules :: Convention -> FilePath -> FilePath -> Set FilePath -> BuildState -> IO BuildState
buildModules conv _rootDir path visited state
  | path `Set.member` visited = pure state
  | otherwise = processFile conv path visited state

{- | parse a single file and, on success, process its imports.
n.b. routes through Safety.safeParseNixFile (review-2 C4) — catches StackOverflow
from megaparsec recursion on adversarial input, IO errors, and parse errors,
all as structured ParseFailures.
-}
processFile :: Convention -> FilePath -> Set FilePath -> BuildState -> IO BuildState
processFile conv path visited state = do
  fileExists <- doesFileExist path
  if not fileExists
    then pure state
    else do
      parseResult <- Safety.safeParseNixFile path
      either onParseError (processParsedFile conv path visited state) parseResult
 where
  onParseError e =
    pure $ state{bsFailures = ParseFailure path (Safety.renderSafetyError e) : bsFailures state}

-- ── process a successfully parsed file ───────────────────────────

{- | extract imports, run type inference / lint / layout checks, then recurse.
n.b. fixed from review-2:
  * routes through Safety.analyzeDepth so a hostile module can't OOM the loader.
  * still produces a partial graph on depth-overflow (records as ParseFailure) so
    subsequent files still get processed.
-}
processParsedFile :: Convention -> FilePath -> Set FilePath -> BuildState -> NExprLoc -> IO BuildState
processParsedFile conv path visited state expr =
  either onDepthExceeded (const (processParsedFile' conv path visited state expr)) (Safety.analyzeDepth expr)
 where
  onDepthExceeded de =
    pure $
      state
        { bsFailures =
            ParseFailure path (Safety.renderSafetyError (Safety.SafetyDepthExceeded de)) : bsFailures state
        }

processParsedFile' :: Convention -> FilePath -> Set FilePath -> BuildState -> NExprLoc -> IO BuildState
processParsedFile' conv path visited state expr = do
  let rootDir = takeDirectory path
  let imports = findImports rootDir expr
  let moduleType = either (const TAny) fst (inferExpr expr)
  let lintViolations = findNixViolations expr
  let layoutViolations = validateFileFromExpr conv rootDir path expr

  let moduleDefinition =
        Module
          { modPath = path
          , modExpr = expr
          , modType = moduleType
          , modImports = imports
          }

  let withModule = state{bsModules = Map.insert path moduleDefinition (bsModules state)}
  let withLint = recordLintFailures path lintViolations withModule
  let withLayout = recordLayoutFailures path layoutViolations withLint
  let updatedVisited = Set.insert path visited

  foldM (processImport conv (takeDirectory path) updatedVisited) withLayout imports

-- | record lint violations only if non-empty (avoids cluttering failure list)
recordLintFailures :: FilePath -> [NixViolation] -> BuildState -> BuildState
recordLintFailures path violations state
  | null violations = state
  | otherwise = state{bsLintFailures = LintFailure path violations : bsLintFailures state}

recordLayoutFailures :: FilePath -> [LayoutError] -> BuildState -> BuildState
recordLayoutFailures path violations state
  | null violations = state
  | otherwise = state{bsLayoutFailures = LayoutFailure path violations : bsLayoutFailures state}

-- ── import processing ────────────────────────────────────────────

{- | process a single import: check existence, enforce root-boundary, recurse
n.b. imports outside rootDir are silently skipped (vendored deps boundary)
-}
processImport :: Convention -> FilePath -> Set FilePath -> BuildState -> Import -> IO BuildState
processImport conv rootDir visited state importBinding = do
  exists <- doesFileExist (impPath importBinding)
  if not exists
    then pure state
    else do
      canonPath <- canonicalizePath (impPath importBinding)
      let rootPrefix = rootDir ++ [pathSeparator]
      if rootPrefix `isPrefixOf` canonPath || canonPath == rootDir
        then buildModules conv rootDir canonPath visited state
        else pure state

-- ═════════════════════════════════════════════════════════════════════════════
-- import finding
-- ═════════════════════════════════════════════════════════════════════════════

-- ── import finding: walk AST for `import ./path` calls ───────────

-- | walk an entire expression tree looking for import calls
findImports :: FilePath -> NExprLoc -> [Import]
findImports baseDir = walkExpr
 where
  walkExpr :: NExprLoc -> [Import]
  walkExpr (LayerAnn srcSpan (NApp func arg)) = processApplication baseDir srcSpan func arg walkExpr
  walkExpr (Layer (NLet bindings body)) = concatMap walkBinding bindings ++ walkExpr body
  walkExpr (Layer (NSet _ bindings)) = concatMap walkBinding bindings
  walkExpr (Layer (NIf cond thenBranch elseBranch)) = walkExpr cond ++ walkExpr thenBranch ++ walkExpr elseBranch
  walkExpr (Layer (NWith scope body)) = walkExpr scope ++ walkExpr body
  walkExpr (Layer (NAssert cond body)) = walkExpr cond ++ walkExpr body
  walkExpr (Layer (NAbs _ body)) = walkExpr body
  walkExpr (Layer (NList elements)) = concatMap walkExpr elements
  walkExpr (Layer (NSelect _ base _)) = walkExpr base
  walkExpr (Layer (NBinary _ left right)) = walkExpr left ++ walkExpr right
  walkExpr (Layer (NUnary _ operand)) = walkExpr operand
  walkExpr _ = []

  walkBinding :: Nix.Binding NExprLoc -> [Import]
  walkBinding (Nix.NamedVar _ expr _) = walkExpr expr
  walkBinding (Nix.Inherit (Just scope) _ _) = walkExpr scope
  walkBinding (Nix.Inherit Nothing _ _) = []

-- ── import application analysis ──────────────────────────────────

{- | given an application node, determine if it's an import and extract its parts
handles: import ./path, builtins.import ./path, import ./path (arg)
-}
processApplication :: FilePath -> SrcSpan -> NExprLoc -> NExprLoc -> (NExprLoc -> [Import]) -> [Import]
processApplication baseDir srcSpan func arg continue
  | Just (rawPath, Nothing) <- unwrapImportExpression func = makeImport baseDir rawPath (Just arg) srcSpan ++ continue arg
  | Just (rawPath, Just inner) <- unwrapImportExpression func = makeImport baseDir rawPath (Just arg) srcSpan ++ continue inner ++ continue arg
  | Just () <- checkImportBuiltin func = makeImport baseDir (extractImportPath arg) Nothing srcSpan
  | otherwise = continue func ++ continue arg

-- | check if an expression is literally the `import` builtin (or builtins.import)
checkImportBuiltin :: NExprLoc -> Maybe ()
checkImportBuiltin (Layer (NSym name))
  | nixVarNameText name == "import" = Just ()
checkImportBuiltin (Layer (NSelect _ _ (attr :| rest)))
  | nixVarNameText (nixKeyName (last (attr : rest))) == "import" = Just ()
checkImportBuiltin _ = Nothing

{- | try to unwrap a nested import expression: import (./path + args)
returns (path, maybe inner-arg-expr)
-}
unwrapImportExpression :: NExprLoc -> Maybe (Text, Maybe NExprLoc)
unwrapImportExpression (Layer (NApp func pathExpr)) = unwrapImportHelper func pathExpr
unwrapImportExpression _ = Nothing

-- | helper to unwrap import at the head of a chain of applications
unwrapImportHelper :: NExprLoc -> NExprLoc -> Maybe (Text, Maybe NExprLoc)
unwrapImportHelper func pathExpr
  | Layer (NSym name) <- func
  , nixVarNameText name == "import" =
      Just (extractImportPath pathExpr, Nothing)
  | Just (path, Nothing) <- unwrapImportExpression func
  , not (T.null path) =
      Just (path, Just pathExpr)
  | Just () <- checkImportBuiltin func = Just (extractImportPath pathExpr, Nothing)
  | otherwise = Nothing

-- | extract the file path text from an import argument expression
extractImportPath :: NExprLoc -> Text
extractImportPath (Layer (NLiteralPath (NixPath.Path p))) = T.pack p
extractImportPath (Layer (NStr (DoubleQuoted [Plain t]))) = t
extractImportPath (Layer (NStr (Indented _ [Plain t]))) = t
extractImportPath _ = ""

-- ── key & name helpers ───────────────────────────────────────────

nixKeyName :: NKeyName r -> VarName
nixKeyName (StaticKey key) = key
nixKeyName (DynamicKey _) = VarName ""

nixVarNameText :: VarName -> Text
nixVarNameText = coerce

-- | construct an Import record from a raw path string and source location
makeImport :: FilePath -> Text -> Maybe NExprLoc -> SrcSpan -> [Import]
makeImport baseDirectory rawPath arguments srcSpan
  | T.null rawPath = []
  | otherwise =
      let resolvedPath = resolveImportPath baseDirectory (T.unpack rawPath)
       in [ Import
              { impPath = resolvedPath
              , impRawPath = rawPath
              , impArgs = arguments
              , impSpan = srcSpanToSpan srcSpan
              }
          ]

-- | resolve a relative or absolute import path against the base directory
resolveImportPath :: FilePath -> FilePath -> FilePath
resolveImportPath _ path@('/' : _) = path
resolveImportPath baseDir path = normalise (baseDir </> path)

-- ═════════════════════════════════════════════════════════════════════════════
-- queries
-- ═════════════════════════════════════════════════════════════════════════════

-- | look up the imports of a specific module by path
moduleImports :: ModuleGraph -> FilePath -> [Import]
moduleImports mg path = maybe [] modImports (Map.lookup path (mgModules mg))

-- | find all modules that directly import the given path
moduleDependents :: ModuleGraph -> FilePath -> [FilePath]
moduleDependents mg path =
  [ modPath m
  | m <- Map.elems (mgModules mg)
  , any (\i -> impPath i == path) (modImports m)
  ]

-- | expose the pre-computed topological order
topologicalOrder :: ModuleGraph -> [FilePath]
topologicalOrder = mgOrder

-- | look up the inferred type for a module
moduleTypes :: ModuleGraph -> Map FilePath NixType
moduleTypes = mgModuleTypes

-- | does this graph have any failures at all (parse, lint, or layout)?
hasViolations :: ModuleGraph -> Bool
hasViolations mg =
  not (null (mgFailures mg))
    || not (null (mgLintFailures mg))
    || not (null (mgLayoutFailures mg))

-- | total count of all violations across all categories
totalViolationCount :: ModuleGraph -> Int
totalViolationCount mg =
  length (mgFailures mg)
    + sum (map (length . lfViolations) (mgLintFailures mg))
    + sum (map (length . layViolations) (mgLayoutFailures mg))

-- ── topological type inference ───────────────────────────────────

{- | infer types for all modules in topological order, propagating types through imports
dependencies are inferred first, their types are fed into importers via TypeEnv
-}
inferModuleTypes :: ModuleGraph -> IO ModuleGraph
inferModuleTypes mg = do
  let order = mgOrder mg
  (finalTypes, _) <- foldM inferOneModule (Map.empty, Map.empty) order
  -- update each module's modType with the cross-module inferred type
  let updatedModules =
        Map.mapWithKey
          (\p m -> maybe m (\t -> m{modType = t}) (Map.lookup p finalTypes))
          (mgModules mg)
  pure mg{mgModuleTypes = finalTypes, mgModules = updatedModules}
 where
  inferOneModule :: (Map FilePath NixType, Map FilePath [FilePath]) -> FilePath -> IO (Map FilePath NixType, Map FilePath [FilePath])
  inferOneModule (types, pendingDeps) path = do
    let imports = maybe [] modImports (Map.lookup path (mgModules mg))
    -- insert types for both raw import paths (as written in the code) and resolved paths
    canonicImports <- mapM (canonicalizePath . impPath) imports
    let rawPaths = map (T.unpack . impRawPath) imports
        resolvedPaths = map impPath imports
        -- n.b. look up in `types` by resolved path, then insert for both raw and resolved keys
        env =
          foldr
            (\p e -> maybe e (\t -> extendImport p t e) (Map.lookup p types))
            builtinEnv
            (resolvedPaths ++ canonicImports)
        finalEnv =
          foldr
            (\(raw, resolved) e -> maybe e (\t -> extendImport raw t e) (Map.lookup resolved types))
            env
            (zip rawPaths resolvedPaths)
        keep = pure (types, pendingDeps)
        inferInto m =
          either
            (const keep)
            (\(t, _) -> pure (Map.insert path t types, pendingDeps))
            (inferExprWithEnv finalEnv (modExpr m))
    maybe keep inferInto (Map.lookup path (mgModules mg))

{- | compute a DFS-based topological order starting from the root module
n.b. result is reversed so root appears first
-}
computeOrder :: FilePath -> Map FilePath Module -> [FilePath]
computeOrder root modules = reverse $ snd $ dfs Set.empty [] root
 where
  dfs :: Set FilePath -> [FilePath] -> FilePath -> (Set FilePath, [FilePath])
  dfs visited order path
    | path `Set.member` visited = (visited, order)
    | otherwise = maybe (visited, order) recurse (Map.lookup path modules)
   where
    recurse m =
      let visited' = Set.insert path visited
          (visited'', order') = foldl go (visited', order) (map impPath (modImports m))
       in (visited'', path : order')

  go (v, o) p = dfs v o p
