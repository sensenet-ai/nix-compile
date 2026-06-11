{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                              // nixpkgs // index
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "She knew the names of all the streets, the addresses of every door,
--    though she had never walked there once."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   A static symbol index over a nixpkgs checkout — attribute name to defining
--   file — built WITHOUT evaluating Nix. The killer-feature substrate: from a
--   `pkgs.<name>` reference in any file we hop straight to the package's source.
--
--   Source 1 (here): `pkgs/by-name/<shard>/<name>/package.nix`, where the shard
--   is the first two characters of the name, lowercased. This is pure path math
--   — a directory scan, no parser — and covers the bulk of modern nixpkgs
--   (20k+ packages). Sources 2 (all-packages.nix callPackage parse) and 3 (the
--   lib graph) layer on later; the by-name map alone is the dominant target set.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nixpkgs.Index (
  -- * Index
  NixpkgsIndex (..),
  Location,
  emptyIndex,
  buildNixpkgsIndex,

  -- * Sources
  byNameEntries,

  -- * Query
  lookupPackage,
)
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import NixCompile.Core.Span (Loc (..), Span (..))
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

{- | Where a nixpkgs symbol is defined: a file with a span. For by-name packages
the span is the head of @package.nix@ (refined to the derivation later).
-}
type Location = Span

{- | A static, eval-free symbol index over one nixpkgs checkout. Keyed by the
checkout root so a cache can hold several. Currently carries the by-name package
map; lib and all-packages maps join it as further sources land.
-}
data NixpkgsIndex = NixpkgsIndex
  { nixpkgsRoot :: !FilePath
  , pkgsByName :: !(Map Text Location)
  -- ^ package attribute name → its @pkgs/by-name/…/package.nix@
  }

-- | An empty index for a root (no entries scanned).
emptyIndex :: FilePath -> NixpkgsIndex
emptyIndex root = NixpkgsIndex root Map.empty

{- | Build the index for a nixpkgs checkout. Pure IO — a directory walk, no Nix
evaluation and no parsing — so it cannot fail on adversarial package contents.
-}
buildNixpkgsIndex :: FilePath -> IO NixpkgsIndex
buildNixpkgsIndex root = do
  byName <- byNameEntries root
  pure (NixpkgsIndex root (Map.fromList byName))

{- | Scan @pkgs/by-name@ into @(name, location)@ pairs. The layout is
@pkgs/by-name/<shard>/<name>/package.nix@ with @shard = toLower (take 2 name)@;
we read the directory structure directly rather than reproduce the sharding, so
the rule never drifts. Missing @by-name@ (older nixpkgs) yields an empty list.
-}
byNameEntries :: FilePath -> IO [(Text, Location)]
byNameEntries root = do
  let byNameDir = root </> "pkgs" </> "by-name"
  present <- doesDirectoryExist byNameDir
  if not present
    then pure []
    else do
      shards <- listDirectory byNameDir
      concat <$> mapM (shardEntries byNameDir) shards
 where
  shardEntries byNameDir shard = do
    let shardDir = byNameDir </> shard
    isDir <- doesDirectoryExist shardDir
    if not isDir
      then pure []
      else do
        names <- listDirectory shardDir
        catMaybes <$> mapM (pkgEntry shardDir) names
  pkgEntry shardDir name = do
    let pkgFile = shardDir </> name </> "package.nix"
    ok <- doesFileExist pkgFile
    pure (if ok then Just (T.pack name, headSpan pkgFile) else Nothing)
  headSpan f = Span (Loc 1 1) (Loc 1 1) (Just f)

-- | Look up a package attribute name in the by-name map.
lookupPackage :: NixpkgsIndex -> Text -> Maybe Location
lookupPackage idx name = Map.lookup name (pkgsByName idx)
