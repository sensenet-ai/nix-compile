{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                      // tests // nixpkgs // index
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "A map of the territory, drawn in light."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The nixpkgs-hop: the by-name index resolves an attribute name to its
--   defining package.nix (hermetic, on a synthetic by-name tree — no real
--   nixpkgs needed), and the cursor recognizer spots a `pkgs.<name>` select.
--   Together these are the go-to-def vertical slice into all of nixpkgs.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixpkgsIndexSpec (nixpkgsIndexTests) where

import Data.Maybe (isNothing)
import Data.Text (Text)
import Nix.Expr.Types.Annotated (NExprLoc)
import Nix.Parser (parseNixTextLoc)
import NixCompile.Core.Span (Span (..))
import NixCompile.LSP.Handlers.Cursor (selectAtCursor)
import NixCompile.Nixpkgs.Index (buildNixpkgsIndex, lookupPackage)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- ── helpers ────────────────────────────────────────────────────────

parse :: Text -> NExprLoc
parse src = either (\e -> error ("NixpkgsIndexSpec parse: " <> show e)) id (parseNixTextLoc src)

-- | Lay down a synthetic @pkgs/by-name/<shard>/<name>/package.nix@ under @root@.
seedPackage :: FilePath -> FilePath -> String -> IO ()
seedPackage root shard name = do
  let dir = root </> "pkgs" </> "by-name" </> shard </> name
  createDirectoryIfMissing True dir
  writeFile (dir </> "package.nix") "{ }\n"

-- ── tests ──────────────────────────────────────────────────────────

{- | A by-name package resolves to its package.nix; the shard is derived from
the on-disk layout, so the index reflects whatever sharding nixpkgs used.
-}
testByNameResolves :: IO Bool
testByNameResolves =
  withSystemTempDirectory "nixpkgs-idx" $ \root -> do
    seedPackage root "ri" "ripgrep"
    seedPackage root "he" "hello"
    idx <- buildNixpkgsIndex root
    let want = root </> "pkgs" </> "by-name" </> "ri" </> "ripgrep" </> "package.nix"
    pure $ case lookupPackage idx "ripgrep" of
      Just sp -> spanFile sp == Just want
      Nothing -> False

-- | A name with no by-name entry resolves to Nothing (caller falls back).
testByNameMiss :: IO Bool
testByNameMiss =
  withSystemTempDirectory "nixpkgs-idx" $ \root -> do
    seedPackage root "he" "hello"
    idx <- buildNixpkgsIndex root
    pure (isNothing (lookupPackage idx "not-a-package"))

-- | Missing @pkgs/by-name@ (older nixpkgs) yields an empty, harmless index.
testNoByNameDir :: IO Bool
testNoByNameDir =
  withSystemTempDirectory "nixpkgs-idx" $ \root -> do
    idx <- buildNixpkgsIndex root
    pure (isNothing (lookupPackage idx "hello"))

-- | The cursor recognizer spots `pkgs.<name>` and returns (base, firstKey).
testSelectRecognized :: IO Bool
testSelectRecognized =
  -- `pkgs.hello`: cursor (0-based) col 6 sits inside `hello` (p=0..3 . =4 hello=5..)
  pure (selectAtCursor 0 6 (parse "pkgs.hello") == Just ("pkgs", "hello"))

-- | The recognizer returns the FIRST key of a multi-segment select.
testSelectFirstSegment :: IO Bool
testSelectFirstSegment =
  pure
    (selectAtCursor 0 6 (parse "pkgs.python3Packages.requests") == Just ("pkgs", "python3Packages"))

-- | A bare symbol (no select) is not a pkgs hop.
testSelectIgnoresBareSym :: IO Bool
testSelectIgnoresBareSym =
  pure (isNothing (selectAtCursor 0 1 (parse "pkgs")))

-- ── runner ─────────────────────────────────────────────────────────

-- | The nixpkgs-index / cursor-recognizer tests.
nixpkgsIndexTests :: [(String, IO Bool)]
nixpkgsIndexTests =
  [ ("nixpkgs_byname_resolves", testByNameResolves)
  , ("nixpkgs_byname_miss", testByNameMiss)
  , ("nixpkgs_no_byname_dir", testNoByNameDir)
  , ("nixpkgs_select_recognized", testSelectRecognized)
  , ("nixpkgs_select_first_segment", testSelectFirstSegment)
  , ("nixpkgs_select_ignores_bare_sym", testSelectIgnoresBareSym)
  ]
