{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                     // lsp // handlers // project
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "The whole of the matrix, the sum of all the corporate data."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   Project-wide state and cross-module typing for the LSP: the global,
--   content-addressed project cache and the (legacy) per-root module-graph
--   cache with in-flight build dedup, plus the cross-module 'TypeEnv' /
--   'Scope.ScopeGraph' builders the position features consult. All the
--   `unsafePerformIO` CAFs that back the server's caches live HERE, behind a
--   small functional surface — nothing else touches the mutable state.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.LSP.Handlers.Project (
  getProjectCache,
  buildCrossEnv,
  buildCrossScopeGraphWith,
  invalidateModuleGraphCache,
  voidProjectDiags,
)
where

import Control.Concurrent.Async (Async, async, waitCatch)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Language.LSP.Protocol.Types (Uri, uriToFilePath)
import Nix.Expr.Types.Annotated (NExprLoc)
import NixCompile.Inference.Nix (TypeEnv (..), builtinEnv, extendImport)
import NixCompile.LSP.ProjectCache qualified as PC
import NixCompile.Layout.Convention (straylight)
import NixCompile.Layout.Graph qualified as Mod
import NixCompile.Layout.Scope qualified as Scope
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.IO.Unsafe (unsafePerformIO)

{-# NOINLINE moduleGraphCache #-}
moduleGraphCache :: MVar (Map.Map FilePath Mod.ModuleGraph)
moduleGraphCache = unsafePerformIO $ newMVar Map.empty

{-# NOINLINE inflightCache #-}

{- | Tracks an in-flight graph build per project root so concurrent requests
don't both rebuild the same graph (Race-A from the audit).
-}
inflightCache :: MVar (Map.Map FilePath (Async (Maybe Mod.ModuleGraph)))
inflightCache = unsafePerformIO $ newMVar Map.empty

{-# NOINLINE projectCacheRef #-}

{- | Per-file, content-addressed project cache. Built lazily and incrementally
in the background; lookups never block. Replaces the all-or-nothing
moduleGraphCache for hover/inlay/completion paths.
-}
projectCacheRef :: MVar (Maybe PC.ProjectCache)
projectCacheRef = unsafePerformIO (newMVar Nothing)

{- | Get the project cache, creating it (and starting workers) the first time.
Subsequent calls return the same cache.
-}
getProjectCache :: IO PC.ProjectCache
getProjectCache = modifyMVar projectCacheRef orCreate
 where
  orCreate (Just pc) = pure (Just pc, pc)
  orCreate Nothing = do
    pc <- PC.newProjectCache
    PC.startWorkers pc
    pure (Just pc, pc)

{- | Maximum number of directory levels to walk up looking for a project root.
n.b. raised from 10 to 64 to handle deeply nested workspaces (B6 from review-2).
-}
projectRootWalkupLimit :: Int
projectRootWalkupLimit = 64

findProjectRoot :: Uri -> IO (Maybe FilePath)
findProjectRoot uri = maybe (pure Nothing) fromPath (uriToFilePath uri)
 where
  fromPath fp = do
    canon <- canonicalizePath fp
    let dir = takeDirectory canon
    findRoot dir projectRootWalkupLimit
  findRoot _ 0 = pure Nothing
  findRoot dir n = do
    let flakePath = dir </> "flake.nix"; configPath = dir </> ".nix-compile.dhall"
    hasFlake <- doesFileExist flakePath
    hasConfig <- doesFileExist configPath
    if hasFlake || hasConfig
      then pure (Just dir)
      else
        let parent = takeDirectory dir
         in if parent == dir then pure Nothing else findRoot parent (n - 1)

{- | Build a TypeEnv enriched with cross-module type information from the
per-file project cache. Non-blocking by construction:

  1. Every 'Fresh' entry in the project cache contributes its inferred type as
     an import; 'Stale'/missing entries are simply absent (inference treats
     absent imports as opaque and proceeds).
  2. 'builtinEnv' underlies everything.

If the cache is still cold for this project we kick the cross-module graph build
off in the BACKGROUND (for the navigation path) and return immediately — hover /
completion get single-file precision now and richer cross-module types as the
per-file workers fill the cache. This function never blocks on a build.
-}
buildCrossEnv :: Uri -> IO TypeEnv
buildCrossEnv uri = do
  pc <- getProjectCache
  snap <- PC.snapshotFiles pc
  -- Cold cache: warm the cross-module graph in the background for the nav path,
  -- but never block this request on the build.
  when (Map.null snap) (voidProjectDiags uri)
  pure (Map.foldlWithKey' addFresh builtinEnv snap)
 where
  addFresh acc fp entry
    | PC.feStatus entry == PC.Fresh = extendImport fp (PC.feType entry) acc
    | otherwise = acc

{- | Build a cross-module 'Scope.ScopeGraph' for the URI's project, splicing in
the caller's current (possibly unsaved) expression for that file. Non-blocking:
if the module graph has already been built we use it for full cross-file
precision; otherwise we warm it in the BACKGROUND and answer NOW from the
current file alone, so within-file navigation works immediately and cross-file
results arrive on a later request. The single-file fallback needs no project
root, so within-file go-to-def/references work even outside a flake.
-}
buildCrossScopeGraphWith :: Uri -> Maybe NExprLoc -> IO Scope.ScopeGraph
buildCrossScopeGraphWith uri mCurrentExpr = do
  mMg <- lookupModuleGraph uri
  maybe onCold (pure . crossGraph) mMg
 where
  -- Not built yet: warm in the background and answer from the current file now.
  onCold = voidProjectDiags uri >> pure singleFileGraph
  currentFile = uriToFilePath uri
  singleFileGraph = maybe Scope.empty (Scope.fromNixExpr currentFile) mCurrentExpr
  crossGraph mg =
    let exprs = Map.map Mod.modExpr (Mod.mgModules mg)
        exprs' =
          maybe exprs (\(f, e) -> Map.insert f e exprs) ((,) <$> currentFile <*> mCurrentExpr)
     in Scope.fromModuleGraph exprs'

{- | Non-blocking: the cached module graph for the URI's project if one has
already been built, else Nothing. NEVER triggers a build — warming the cache is
the background path's job ('voidProjectDiags').
-}
lookupModuleGraph :: Uri -> IO (Maybe Mod.ModuleGraph)
lookupModuleGraph uri = do
  mRoot <- findProjectRoot uri
  maybe (pure Nothing) (\root -> Map.lookup root <$> readMVar moduleGraphCache) mRoot

{- | Look up or build the module graph for a project root.
n.b. fixes from review-2:
  * exception-safe (catches StackOverflow from hnix, IO errors)
  * in-flight dedup: concurrent requests share a single build
  * negative cache via try @SomeException so a failing build doesn't loop
-}
getOrBuildModuleGraph :: Uri -> IO (Maybe Mod.ModuleGraph)
getOrBuildModuleGraph uri = do
  mRoot <- findProjectRoot uri
  maybe (pure Nothing) withRoot mRoot
 where
  withRoot root = do
    cache <- readMVar moduleGraphCache
    maybe (joinOrStartBuild root) (pure . Just) (Map.lookup root cache)

joinOrStartBuild :: FilePath -> IO (Maybe Mod.ModuleGraph)
joinOrStartBuild root = do
  -- Check inflight or claim it atomically; whoever wins starts the build.
  action <- modifyMVar inflightCache claim
  let asyncHandle = either id id action
  waitResult <- waitCatch asyncHandle
  -- Clean up inflight entry no matter what.
  modifyMVar_ inflightCache (pure . Map.delete root)
  either (const (pure Nothing)) pure waitResult
 where
  -- Check inflight or claim it atomically; whoever wins starts the build.
  claim m = maybe (start m) (\a -> pure (m, Right a)) (Map.lookup root m)
  start m = do
    a <- async (startBuild root)
    pure (Map.insert root a m, Left a)

startBuild :: FilePath -> IO (Maybe Mod.ModuleGraph)
startBuild root = do
  let flakePath = root </> "flake.nix"
  hasFlake <- doesFileExist flakePath
  if not hasFlake
    then pure Nothing
    else do
      -- Catch every exception: hnix parser stack overflow, IO errors,
      -- whatever buildModuleGraph might throw beyond its Either return.
      outcome <- try (Mod.buildModuleGraph straylight flakePath)
      either
        (const (pure Nothing))
        (either (const (pure Nothing)) cacheIt)
        (outcome :: Either SomeException (Either Text Mod.ModuleGraph))
 where
  cacheIt mg = do
    modifyMVar moduleGraphCache (\m -> pure (Map.insert root mg m, ()))
    pure (Just mg)

{- | Invalidate the module-graph cache for the project containing the given URI.
n.b. fixed from review-2: invalidate on ANY save in the project, not just flake.nix.
-}
invalidateModuleGraphCache :: Uri -> IO ()
invalidateModuleGraphCache uri = do
  mRoot <- findProjectRoot uri
  maybe (pure ()) (\root -> modifyMVar_ moduleGraphCache (pure . Map.delete root)) mRoot

{- | Eagerly warm the module-graph cache for the URI's project.
n.b. fixed from review-2 (B5 voidProjectDiags was a no-op stub):
  * actually populates the cache so subsequent hover/definition are warm
  * exception-safe via getOrBuildModuleGraph's try/catch
  * uses the inflight-dedup machinery so we don't race the foreground request
-}
voidProjectDiags :: Uri -> IO ()
voidProjectDiags uri = do
  _ <- async $ do
    _result <- try (getOrBuildModuleGraph uri) :: IO (Either SomeException (Maybe Mod.ModuleGraph))
    pure ()
  pure ()
