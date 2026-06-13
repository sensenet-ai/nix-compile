{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                              // layout // closure
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He followed the thing back along every wire it touched, until the whole
--    shape of it stood in his head at once."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   ONE reachability closure, shared by @check@ / @infer@ / @lsp@, so they stop
--   disagreeing about which files a file depends on and what those files are.
--
--   The graph follows three edge kinds, each discovered from the AST with no
--   evaluation ('discoverEdges'):
--
--     * 'EImport'      — @import ./path@ (the canonical 'findImports' walker);
--     * 'EFlakeImport' — a flake-parts @imports = [ ./a.nix … ]@ list;
--     * 'ECallPackage' — a top-level @x = callPackage ./path { }@ binding.
--
--   'buildTypeClosure' walks that graph from a root file — bounded to the
--   enclosing project (flake.nix / .git), eval-free, cycle-guarded, resolving
--   @./dir@ to @./dir/default.nix@ — and infers every reachable file's type in
--   dependency order, threading each file's dependency types into the next. The
--   result populates two env maps: 'envImportTypes' (what @import ./p@ yields) and
--   'envCallPackageTypes' (the RESULT of @callPackage ./p { }@ — its function
--   applied to its auto-filled args), so a one-shot CLI @infer@ resolves both
--   cross-module forms synchronously, no async project cache needed.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Layout.Closure (
  -- * Edges
  EdgeKind (..),
  Edge (..),
  discoverEdges,

  -- * The closure
  Closure (..),
  buildTypeClosure,

  -- * Consuming it
  importEnvFor,
  closureEnv,
)
where

import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Expr.Types.Annotated (NExprLoc)
import NixCompile.Core.Safety (safeParseNixFile)
import NixCompile.Inference.Nix (
  TypeEnv,
  builtinEnv,
  extendCallPackage,
  extendImport,
  inferExprWithEnv,
 )
import NixCompile.Inference.Nix.Type (NixType (..))
import NixCompile.Layout.Edge (Edge (..), EdgeKind (..), discoverEdges)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist)
import System.FilePath (pathSeparator, takeDirectory, (</>))

-- ── the closure ─────────────────────────────────────────────────────

{- | A resolved dependency: its kind, the canonical path it points at (an existing
file inside the project), and the raw path text as written at the use site.
-}
type Dep = (EdgeKind, FilePath, Text)

-- | One reachable file: its parsed expression and its resolved dependencies.
data Node = Node
  { nodeExpr :: !NExprLoc
  , nodeDeps :: ![Dep]
  }

{- | The synchronous, file-rooted type closure: every file reachable from the root
(bounded to the enclosing project), each with its inferred type and its resolved
dependency edges.
-}
data Closure = Closure
  { clTypes :: !(Map FilePath NixType)
  -- ^ canonical path ↦ inferred type of that file's expression
  , clDeps :: !(Map FilePath [Dep])
  -- ^ canonical path ↦ its resolved dependency edges
  , clRoot :: !FilePath
  -- ^ the canonical root the closure was built from
  }

{- | Build the type closure rooted at a file. Eval-free, cycle-guarded, bounded to
the enclosing project root (the nearest @flake.nix@ / @.git@ ancestor, else the
file's own directory) so it never wanders into the Nix store. Files that fail to
parse contribute nothing and are skipped; a dependency that fails to type-check
simply does not enrich its importers (degrade, never lie).
-}
buildTypeClosure :: FilePath -> IO Closure
buildTypeClosure rootPath = do
  canonRoot <- canonicalizePath rootPath
  projRoot <- projectRootFor canonRoot
  nodes <- loadReachable projRoot Map.empty [canonRoot]
  let order = topoOrder canonRoot nodes
      types = foldl' (inferOne nodes) Map.empty order
  pure Closure{clTypes = types, clDeps = Map.map nodeDeps nodes, clRoot = canonRoot}

{- | Parse + edge-discover every file transitively reachable from the worklist,
following all three edge kinds, guarded by the accumulated map's keys.
-}
loadReachable :: FilePath -> Map FilePath Node -> [FilePath] -> IO (Map FilePath Node)
loadReachable _ acc [] = pure acc
loadReachable projRoot acc (p : rest)
  | p `Map.member` acc = loadReachable projRoot acc rest
  | otherwise = do
      parsed <- safeParseNixFile p
      either skip viaExpr parsed
 where
  skip _ = loadReachable projRoot acc rest
  viaExpr expr = do
    deps <- catMaybes <$> mapM (resolveDep projRoot) (discoverEdges (takeDirectory p) expr)
    let node = Node{nodeExpr = expr, nodeDeps = deps}
        next = map tgt deps ++ rest
    loadReachable projRoot (Map.insert p node acc) next
  tgt (_, t, _) = t

{- | Resolve one edge to an existing in-project file (or drop it): @./dir@ becomes
@./dir/default.nix@, the target must exist and live under the project root.
-}
resolveDep :: FilePath -> Edge -> IO (Maybe Dep)
resolveDep projRoot (Edge kind path raw) = do
  mFile <- resolveExisting path
  maybe (pure Nothing) underProject mFile
 where
  underProject file = do
    canon <- canonicalizePath file
    pure (if underRoot projRoot canon then Just (kind, canon, raw) else Nothing)

-- | A path as-is if it is a file, its @default.nix@ if it is a directory, else nothing.
resolveExisting :: FilePath -> IO (Maybe FilePath)
resolveExisting path = do
  isFile <- doesFileExist path
  if isFile then pure (Just path) else viaDir
 where
  viaDir = do
    isDir <- doesDirectoryExist path
    if not isDir then pure Nothing else viaDefault
  viaDefault = do
    let dn = path </> "default.nix"
    hasDn <- doesFileExist dn
    pure (if hasDn then Just dn else Nothing)

-- | Is the canonical path at or under the project root (separator-guarded)?
underRoot :: FilePath -> FilePath -> Bool
underRoot projRoot p = p == projRoot || (projRoot ++ [pathSeparator]) `isPrefixOf` p

-- | The nearest ancestor holding a @flake.nix@ or @.git@; the file's own dir if none.
projectRootFor :: FilePath -> IO FilePath
projectRootFor file = go (takeDirectory file)
 where
  fallback = takeDirectory file
  go dir = do
    hasFlake <- doesFileExist (dir </> "flake.nix")
    hasGit <- doesDirectoryExist (dir </> ".git")
    let parent = takeDirectory dir
    if hasFlake || hasGit
      then pure dir
      else if parent == dir then pure fallback else go parent

-- | Dependency-first (post-order) traversal of the reachable graph from the root.
topoOrder :: FilePath -> Map FilePath Node -> [FilePath]
topoOrder root nodes = reverse (snd (go Set.empty [] root))
 where
  go visited acc path
    | path `Set.member` visited = (visited, acc)
    | otherwise =
        let visited' = Set.insert path visited
            deps = maybe [] (map depTarget . nodeDeps) (Map.lookup path nodes)
            (visited'', acc') = foldl' step (visited', acc) deps
         in (visited'', path : acc')
  step (v, a) = go v a
  depTarget (_, t, _) = t

-- | Infer one file's type with its already-inferred dependencies in scope.
inferOne :: Map FilePath Node -> Map FilePath NixType -> FilePath -> Map FilePath NixType
inferOne nodes acc path = maybe acc viaNode (Map.lookup path nodes)
 where
  viaNode node =
    either
      (const acc)
      (\(t, _) -> Map.insert path t acc)
      (inferExprWithEnv (extendDeps builtinEnv acc (nodeDeps node)) (nodeExpr node))

-- ── consuming the closure ───────────────────────────────────────────

{- | Extend a base env with the cross-module types a file depends on. An @import@ /
flake-import contributes the dependency's own type, keyed by BOTH the canonical path
and the raw text as written (inference's 'lookupImport' keys on the literal). A
@callPackage ./p@ contributes the package's RESULT type — the dependency is a
function @{ … }: package@, and @callPackage@ applies it, so the call site has the
function's result — keyed by the raw path under 'envCallPackageTypes'.
-}
extendDeps :: TypeEnv -> Map FilePath NixType -> [Dep] -> TypeEnv
extendDeps base known = foldl' add base
 where
  add env (ECallPackage, canon, raw) =
    maybe env (\t -> extendCallPackage (T.unpack raw) (callResult t) env) (Map.lookup canon known)
  add env (_, canon, raw) =
    maybe env extend (Map.lookup canon known)
   where
    extend t = extendImport (T.unpack raw) t (extendImport canon t env)

{- | The result of applying a package function: @callPackage f@ supplies @f@'s
arguments, so the call yields @f@'s codomain. A non-function degrades to itself.
-}
callResult :: NixType -> NixType
callResult (TFun _ r) = r
callResult t = t

-- | The cross-module inference env for one file already in a closure.
importEnvFor :: TypeEnv -> Closure -> FilePath -> TypeEnv
importEnvFor base cl file =
  extendDeps base (clTypes cl) (Map.findWithDefault [] file (clDeps cl))

{- | Build the closure rooted at a file and return its cross-module inference env: a
one-call seam for the CLI @infer@ / @check@ path. Best-effort — a file with no
in-project imports just yields @base@ unchanged.
-}
closureEnv :: TypeEnv -> FilePath -> IO TypeEnv
closureEnv base file = do
  cl <- buildTypeClosure file
  canon <- canonicalizePath file
  pure (importEnvFor base cl canon)
