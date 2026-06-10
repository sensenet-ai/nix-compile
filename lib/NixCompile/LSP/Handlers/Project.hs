{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                    // lsp // handlers // project
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "The whole of the matrix, the sum of all the corporate data."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   Project-wide state and cross-module typing for the LSP: the global,
--   content-addressed project cache and the (legacy) per-root module-graph
--   cache with in-flight build dedup, plus the cross-module 'TypeEnv' /
--   'Scope.ScopeGraph' builders the position features consult. All the
--   `unsafePerformIO` CAFs that back the server's caches live HERE, behind a
--   small functional surface — nothing else touches the mutable state.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
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
        let parent = takeDirectory dir in if parent == dir then pure Nothing else findRoot parent (n - 1)

{- | Build a TypeEnv enriched with cross-module type information.

Order of preference, non-blocking:

  1. Project cache (per-file, content-addressed): consult first. Whatever's
     'Fresh' goes into the env. Stale or missing entries are simply absent;
     the inference engine treats absent imports as opaque and proceeds.
  2. Module-graph cache (legacy, all-or-nothing): used as a backstop only
     when the project cache has nothing useful. This will be removed once
     the per-file cache stabilises.
  3. 'builtinEnv': always.

Crucially, this function never blocks. If the project cache is still warming,
hover/definition still return immediately with single-file precision.
-}
buildCrossEnv :: Uri -> IO TypeEnv
buildCrossEnv uri = do
  pc <- getProjectCache
  snap <- PC.snapshotFiles pc
  let pcEnv =
        Map.foldlWithKey'
          ( \acc fp entry ->
              if PC.feStatus entry == PC.Fresh
                then extendImport fp (PC.feType entry) acc
                else acc
          )
          builtinEnv
          snap
  -- If the per-file cache hasn't produced anything for this project yet,
  -- fall back to the legacy module-graph cache so we don't regress the
  -- first hover.
  if Map.null snap
    then legacyBuildCrossEnv uri
    else pure pcEnv

legacyBuildCrossEnv :: Uri -> IO TypeEnv
legacyBuildCrossEnv uri = do
  mMg <- getOrBuildModuleGraph uri
  maybe (pure builtinEnv) withMg mMg
 where
  withMg mg = pure finalEnv
   where
    canonicalTypes = Mod.mgModuleTypes mg
    baseEnv = builtinEnv{envImportTypes = canonicalTypes}
    finalEnv =
      foldr
        ( \(_, m) acc ->
            foldr
              ( \imp acc' ->
                  let raw = T.unpack (Mod.impRawPath imp)
                   in maybe acc' (\t -> extendImport raw t acc') (Map.lookup (Mod.impPath imp) canonicalTypes)
              )
              acc
              (Mod.modImports m)
        )
        baseEnv
        (Map.toList (Mod.mgModules mg))

buildCrossScopeGraphWith :: Uri -> Maybe NExprLoc -> IO Scope.ScopeGraph
buildCrossScopeGraphWith uri mCurrentExpr = do
  mMg <- getOrBuildModuleGraph uri
  maybe (pure Scope.empty) withMg mMg
 where
  withMg mg =
    let exprs = Map.map Mod.modExpr (Mod.mgModules mg)
        currentFile = uriToFilePath uri
        exprs' = maybe exprs (\(f, e) -> Map.insert f e exprs) ((,) <$> currentFile <*> mCurrentExpr)
     in pure $ Scope.fromModuleGraph exprs'

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
