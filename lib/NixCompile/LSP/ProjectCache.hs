{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                  // LSP // project cache
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Like time, you know. It's like a — there are no words for it. But it's
--    in the world, and you can have your hand in there and pull things out,
--    but you can't just see them."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   Non-blocking, per-file, content-addressed project cache for the LSP.
--   Replaces the all-or-nothing ModuleGraph cache:
--
--     * Lookups never block. If the file's entry is missing or stale,
--       handlers fall back to single-file inference.
--     * Worker pool (one per capability) processes a TQueue of FilePaths.
--       Each worker parses, infers, writes the cache entry, and enqueues
--       the file's imports — implicit BFS from the roots outward.
--     * Per-file content hashing: a no-op save (timestamp churn only) is
--       detected and short-circuited.
--     * Reverse-dependency map is maintained. On invalidation we mark the
--       file and all its reverse-deps stale (status = Stale); we do NOT
--       eagerly recompute. Subsequent enqueues recompute lazily.
--
--   See doc/src/lsp-project-cache.md for the full design write-up.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.LSP.ProjectCache (
  -- * Cache
  ProjectCache,
  newProjectCache,

  -- * Worker pool
  startWorkers,
  stopWorkers,

  -- * Lookup (non-blocking)
  FileEntry (..),
  EntryStatus (..),
  lookupFile,
  snapshotFiles,
  buildEnvForFile,

  -- * Mutation
  enqueueFile,
  enqueueFiles,
  markStale,
  invalidateFile,

  -- * Stats
  ProjectCacheStats (..),
  statsOf,
)
where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.STM
import Control.Exception (SomeException, try)
import Control.Monad (forM_, replicateM, unless)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Conc (getNumCapabilities)
import Nix.Expr.Types (Binding (..), NExprF (..), NKeyName (..))
import Nix.Expr.Types.Annotated (NExprLoc)
import Nix.Utils qualified as NixUtils
import NixCompile.Core.Safety qualified as Safety
import NixCompile.Nix.Inference (
  TypeEnv (..),
  builtinEnv,
  extendImport,
  inferExprWithEnv,
 )
import NixCompile.Nix.Types (NixType (..))
import NixCompile.Syntax.Annotation (varNameText, pattern Layer)
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (normalise, takeDirectory, (</>))

-- ─────────────────────────────────────────────────────────────────────────────
-- Data
-- ─────────────────────────────────────────────────────────────────────────────

{- | Per-file cache entry. Keyed by the file's canonical path; invalidated by
content hash. Status discriminates "we have a fresh result" from "we know
this entry is stale and will be recomputed when something asks".
-}
data FileEntry = FileEntry
  { feExpr :: !NExprLoc
  , feType :: !NixType
  , feImports :: ![FilePath]
  -- ^ canonical paths of files this entry imports (transitively follow for BFS)
  , feHash :: !BS.ByteString
  , feStatus :: !EntryStatus
  }

instance Show FileEntry where
  show e = "FileEntry { feType = " <> show (feType e) <> ", feStatus = " <> show (feStatus e) <> " }"

data EntryStatus
  = -- | the entry reflects the current on-disk (or last-saved) content
    Fresh
  | -- | the file or a transitive dependency has changed; next consumer will trigger recompute
    Stale
  | -- | a worker has the file in flight
    Computing
  deriving (Eq, Show)

{- | Project cache: per-file entries + reverse-dependency map + work queue.

Invariants:
  * 'pcFiles' keys are always canonical paths (use 'canonicalizePath' before insert).
  * If F's entry has F.imports = [I1, I2, ...], then for each I, F ∈ pcReverse[I].
  * 'pcInflight' tracks which files have been claimed by a worker; an enqueue
    of an already-inflight file is a no-op.
-}
data ProjectCache = ProjectCache
  { pcFiles :: !(TVar (Map FilePath FileEntry))
  , pcReverse :: !(TVar (Map FilePath (Set FilePath)))
  , pcQueue :: !(TQueue FilePath)
  , pcInflight :: !(TVar (Set FilePath))
  , pcWorkerThreads :: !(TVar [ThreadId])
  , pcRoot :: !(TVar (Maybe FilePath))
  -- ^ project root (directory containing flake.nix); set by the LSP on initialize
  }

newProjectCache :: IO ProjectCache
newProjectCache = atomically $ do
  files <- newTVar Map.empty
  rev <- newTVar Map.empty
  q <- newTQueue
  inf <- newTVar Set.empty
  ths <- newTVar []
  root <- newTVar Nothing
  pure
    ProjectCache
      { pcFiles = files
      , pcReverse = rev
      , pcQueue = q
      , pcInflight = inf
      , pcWorkerThreads = ths
      , pcRoot = root
      }

-- ─────────────────────────────────────────────────────────────────────────────
-- Worker pool
-- ─────────────────────────────────────────────────────────────────────────────

{- | Spawn @n@ worker threads that drain the queue. Idempotent — calling twice
without 'stopWorkers' in between just gives you @2n@ workers (don't).
-}
startWorkers :: ProjectCache -> IO ()
startWorkers pc = do
  n <- getNumCapabilities
  threads <- replicateM (max 1 n) (forkIO (workerLoop pc))
  atomically $ modifyTVar' (pcWorkerThreads pc) (threads ++)

stopWorkers :: ProjectCache -> IO ()
stopWorkers pc = do
  threads <- atomically $ do
    ts <- readTVar (pcWorkerThreads pc)
    writeTVar (pcWorkerThreads pc) []
    pure ts
  mapM_ killThread threads

{- | One worker iteration: pull a file from the queue, parse + infer + write
back. Failures are logged-and-discarded (we can't surface them through the LSP
in a sensible way from a background thread).

The worker does:
  1. Read the file (Safety.safeReadFile, catches StackOverflow and IO errors)
  2. Hash content. If hash matches existing Fresh entry, skip (no-op edit).
  3. Parse + analyzeDepth. If either fails, write a Stale-by-default empty entry.
  4. Build the env from imports' current cache state (whatever's available;
     missing imports default to TAny). Run inferExprWithEnv.
  5. Update pcFiles atomically; update pcReverse for new imports.
  6. Enqueue the imports (BFS expansion).
-}
workerLoop :: ProjectCache -> IO ()
workerLoop pc = do
  fp <- atomically $ do
    f <- readTQueue (pcQueue pc)
    modifyTVar' (pcInflight pc) (Set.insert f)
    pure f
  _ <- try @SomeException (processFile pc fp)
  atomically $ modifyTVar' (pcInflight pc) (Set.delete fp)
  workerLoop pc

processFile :: ProjectCache -> FilePath -> IO ()
processFile pc fp = do
  exists <- doesFileExist fp
  unless (not exists) $ do
    srcResult <- Safety.safeReadFile fp
    -- Left: IO failure; leave any existing entry alone.
    either (const (pure ())) fromSrc srcResult
 where
  fromSrc src = do
    let h = SHA256.hash (TE.encodeUtf8 src)
    existing <- atomically $ Map.lookup fp <$> readTVar (pcFiles pc)
    if maybe False (\e -> feStatus e == Fresh && feHash e == h) existing
      then pure () -- already have a fresh entry for this content
      else recompute pc fp src h

  recompute pcArg fpArg src h = do
    parseRes <- Safety.safeParseNixText src
    either (const (pure ())) afterParse parseRes
   where
    afterParse expr = either (const (pure ())) (const (afterDepth expr)) (Safety.analyzeDepth expr)
    afterDepth expr = do
      let baseDir = takeDirectory fpArg
      let imports = collectImports baseDir expr
      canonImports <- mapM canonicalizePath imports
      env <- envFromImports pcArg canonImports
      let resultType = either (const TAny) fst (inferExprWithEnv env expr)
      let entry =
            FileEntry
              { feExpr = expr
              , feType = resultType
              , feImports = canonImports
              , feHash = h
              , feStatus = Fresh
              }
      updateCache pcArg fpArg entry
      -- BFS: enqueue any imports we don't yet have entries for
      forM_ canonImports (enqueueFile pcArg)

-- | Update both pcFiles and the reverse-dependency map atomically.
updateCache :: ProjectCache -> FilePath -> FileEntry -> IO ()
updateCache pc fp entry = atomically $ do
  -- Look up the prior entry so we can compute reverse-dep delta.
  oldFiles <- readTVar (pcFiles pc)
  let oldImports = maybe Set.empty (Set.fromList . feImports) (Map.lookup fp oldFiles)
  let newImports = Set.fromList (feImports entry)
  -- Edges removed: stop tracking fp as a reverse-dep of those files.
  let removed = Set.difference oldImports newImports
  -- Edges added: add fp as a reverse-dep of those files.
  let added = Set.difference newImports oldImports

  modifyTVar' (pcReverse pc) $ \rev ->
    let stripped = Set.foldl' (\acc i -> Map.adjust (Set.delete fp) i acc) rev removed
        extended = Set.foldl' (\acc i -> Map.insertWith Set.union i (Set.singleton fp) acc) stripped added
     in extended

  modifyTVar' (pcFiles pc) (Map.insert fp entry)

{- | Build a TypeEnv that includes whatever cached import types we have. Missing
imports default to TAny (they'll be filled in when the worker processes
them, but we don't block waiting).
-}
envFromImports :: ProjectCache -> [FilePath] -> IO TypeEnv
envFromImports pc imports = do
  files <- atomically (readTVar (pcFiles pc))
  let addImport fp acc
        | Just e <- Map.lookup fp files, feStatus e == Fresh = extendImport fp (feType e) acc
        | otherwise = acc
  pure (foldr addImport builtinEnv imports)

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

{- | Non-blocking lookup. Returns 'Just' iff the entry is 'Fresh'. Stale or
absent entries return 'Nothing' (and don't trigger anything — that's the
caller's job via 'enqueueFile' if they want a recompute).
-}
lookupFile :: ProjectCache -> FilePath -> IO (Maybe FileEntry)
lookupFile pc fp = do
  canon <- canonicalizePath fp
  files <- atomically (readTVar (pcFiles pc))
  pure $ freshOnly (Map.lookup canon files)
 where
  freshOnly (Just e) | feStatus e == Fresh = Just e
  freshOnly _ = Nothing

snapshotFiles :: ProjectCache -> IO (Map FilePath FileEntry)
snapshotFiles pc = atomically (readTVar (pcFiles pc))

{- | Construct a TypeEnv for the given file using the cache's current state.
Never blocks. Files we don't have entries for are simply absent from the env
(callers see them as 'TAny' through 'inferAppWithImport' via 'lookupImport'
returning 'Nothing' → which is the fallback to 'TAny' anyway).
-}
buildEnvForFile :: ProjectCache -> FilePath -> IO TypeEnv
buildEnvForFile pc fp = do
  canon <- canonicalizePath fp
  files <- atomically (readTVar (pcFiles pc))
  -- Collect (canonical-path, raw-import-path-as-written) pairs for any
  -- import entries we have, and extend the env via 'extendImport' so that
  -- both keying conventions hit.
  let addImport impFp acc
        | Just ie <- Map.lookup impFp files, feStatus ie == Fresh = extendImport impFp (feType ie) acc
        | otherwise = acc
  pure $ maybe builtinEnv (\e -> foldr addImport builtinEnv (feImports e)) (Map.lookup canon files)

{- | Enqueue a file for processing. If it's already in the queue (or in flight,
or fresh), this is a no-op. Canonicalises the path before queueing.
-}
enqueueFile :: ProjectCache -> FilePath -> IO ()
enqueueFile pc fp = do
  canon <- canonicalizePath fp
  atomically $ do
    files <- readTVar (pcFiles pc)
    inflight <- readTVar (pcInflight pc)
    let alreadyFresh = maybe False ((== Fresh) . feStatus) (Map.lookup canon files)
        inFlight = Set.member canon inflight
    unless (alreadyFresh || inFlight) $
      writeTQueue (pcQueue pc) canon

enqueueFiles :: ProjectCache -> [FilePath] -> IO ()
enqueueFiles pc = mapM_ (enqueueFile pc)

{- | Mark a file and the transitive closure of its reverse-deps as stale.
Does NOT recompute — that's lazy, triggered by the next enqueue or lookup.
Idempotent.
-}
markStale :: ProjectCache -> FilePath -> IO ()
markStale pc fp = do
  canon <- canonicalizePath fp
  atomically $ do
    rev <- readTVar (pcReverse pc)
    let closure = reverseClosure rev canon
    modifyTVar' (pcFiles pc) $ \files ->
      Set.foldl'
        (\acc f -> Map.adjust (\e -> e{feStatus = Stale}) f acc)
        files
        closure

{- | The transitive closure of reverse-deps reachable from a starting file,
including the file itself. Pure (TVar reads only, no recursion in STM).
-}
reverseClosure :: Map FilePath (Set FilePath) -> FilePath -> Set FilePath
reverseClosure rev start = go (Set.singleton start) [start]
 where
  go !acc [] = acc
  go !acc (x : xs) =
    let neighbours = Map.findWithDefault Set.empty x rev
        new = Set.difference neighbours acc
        acc' = Set.union acc new
     in go acc' (Set.toList new ++ xs)

{- | Invalidate a single file: mark it + reverse-deps stale, then enqueue the
file itself for immediate recompute. The reverse-deps recompute lazily on
their next access.
-}
invalidateFile :: ProjectCache -> FilePath -> IO ()
invalidateFile pc fp = do
  markStale pc fp
  enqueueFile pc fp

-- ─────────────────────────────────────────────────────────────────────────────
-- Stats (for debugging / logging)
-- ─────────────────────────────────────────────────────────────────────────────

data ProjectCacheStats = ProjectCacheStats
  { pcsFiles :: !Int
  , pcsFresh :: !Int
  , pcsStale :: !Int
  , pcsInflight :: !Int
  , pcsWorkers :: !Int
  }
  deriving (Eq, Show)

statsOf :: ProjectCache -> IO ProjectCacheStats
statsOf pc = atomically $ do
  files <- readTVar (pcFiles pc)
  inflight <- readTVar (pcInflight pc)
  threads <- readTVar (pcWorkerThreads pc)
  let total = Map.size files
      fresh = Map.size (Map.filter ((== Fresh) . feStatus) files)
      stale = Map.size (Map.filter ((== Stale) . feStatus) files)
  pure
    ProjectCacheStats
      { pcsFiles = total
      , pcsFresh = fresh
      , pcsStale = stale
      , pcsInflight = Set.size inflight
      , pcsWorkers = length threads
      }

-- ─────────────────────────────────────────────────────────────────────────────
-- Internal: import discovery (lightweight version of Module.findImports)
-- ─────────────────────────────────────────────────────────────────────────────

-- We re-export this rather than importing Module.findImports to avoid a
-- circular dependency (Module imports things that don't need this cache).

collectImports :: FilePath -> NExprLoc -> [FilePath]
collectImports baseDir = goExpr
 where
  goExpr (Layer (NApp f a)) = processApp f a ++ goExpr f ++ goExpr a
  goExpr (Layer (NList xs)) = concatMap goExpr xs
  goExpr (Layer (NSet _ bs)) = concatMap goBinding bs
  goExpr (Layer (NLet bs body)) = concatMap goBinding bs ++ goExpr body
  goExpr (Layer (NIf c t e)) = goExpr c ++ goExpr t ++ goExpr e
  goExpr (Layer (NWith s b)) = goExpr s ++ goExpr b
  goExpr (Layer (NAssert c b)) = goExpr c ++ goExpr b
  goExpr (Layer (NAbs _ b)) = goExpr b
  goExpr (Layer (NSelect _ b _)) = goExpr b
  goExpr (Layer (NBinary _ l r)) = goExpr l ++ goExpr r
  goExpr (Layer (NUnary _ x)) = goExpr x
  goExpr _ = []

  goBinding (NamedVar _ e _) = goExpr e
  goBinding (Inherit (Just s) _ _) = goExpr s
  goBinding (Inherit Nothing _ _) = []

  processApp f a
    | isImportCall f = maybe [] (\p -> [resolvePath baseDir (T.unpack p)]) (extractPath a)
    | otherwise = []

  isImportCall (Layer (NSym n)) = varNameText n == ("import" :: Text)
  isImportCall (Layer (NSelect _ _ attrs))
    | StaticKey k NE.:| _ <- attrs = varNameText k == ("import" :: Text)
  isImportCall _ = False

  extractPath (Layer (NLiteralPath (NixUtils.Path p))) = Just (T.pack p)
  extractPath _ = Nothing

  resolvePath base p
    | take 1 p == "/" = p
    | otherwise = normalise (base </> p)
