{-# LANGUAGE DuplicateRecordFields #-}
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

import Data.ByteString.Lazy qualified as LBS
import Data.List (sort)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Language.LSP.Protocol.Types (CompletionItem (..))
import Nix.Expr.Types.Annotated (NExprLoc)
import Nix.Parser (parseNixTextLoc)
import NixCompile.Core.Span (Span (..))
import NixCompile.LSP.Handlers.Cursor (selectAtCursor)
import NixCompile.LSP.Handlers.Features (nixpkgsCompletionsFromText)
import NixCompile.LSP.Handlers.Project (nixpkgsRootFromLock)
import NixCompile.Nixpkgs.Index (buildNixpkgsIndex, lookupPackage)
import NixCompile.Nixpkgs.StorePath (fixedOutputSourcePath)
import System.Directory (canonicalizePath, createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
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

-- | The label of a completion item.
completionLabel :: CompletionItem -> Text
completionLabel CompletionItem{_label = l} = l

{- | @pkgs.<prefix>@ completion offers exactly the matching package names — and
works off raw text, including a prefix the parser would choke on.
-}
testCompletionPrefix :: IO Bool
testCompletionPrefix =
  withSystemTempDirectory "nixpkgs-idx" $ \root -> do
    seedPackage root "ri" "ripgrep"
    seedPackage root "ri" "ripgrep-all"
    seedPackage root "he" "hello"
    idx <- buildNixpkgsIndex root
    -- "  x = pkgs.rip" with the cursor at end (col 14) → prefix "rip"
    let labels = map completionLabel (nixpkgsCompletionsFromText idx "  x = pkgs.rip" 0 14)
    pure (sort labels == ["ripgrep", "ripgrep-all"])

-- | A non-@pkgs@ base yields no nixpkgs completions (caller's own list stands).
testCompletionNonPkgs :: IO Bool
testCompletionNonPkgs =
  withSystemTempDirectory "nixpkgs-idx" $ \root -> do
    seedPackage root "ri" "ripgrep"
    idx <- buildNixpkgsIndex root
    pure (null (nixpkgsCompletionsFromText idx "  y = foo.bar" 0 13))

{- | A legacy @name = callPackage <path> { }@ binding in all-packages.nix
resolves (syntactic parse, no eval); the relative path is canonicalised.
-}
testAllPackagesResolves :: IO Bool
testAllPackagesResolves =
  withSystemTempDirectory "nixpkgs-idx" $ \root -> do
    let toolFile = root </> "pkgs" </> "tools" </> "mytool.nix"
        apFile = root </> "pkgs" </> "top-level" </> "all-packages.nix"
    createDirectoryIfMissing True (takeDirectory toolFile)
    writeFile toolFile "{ }\n"
    createDirectoryIfMissing True (takeDirectory apFile)
    writeFile apFile "{ }:\nwith pkgs;\n{\n  mytool = callPackage ../tools/mytool.nix { };\n}\n"
    idx <- buildNixpkgsIndex root
    want <- canonicalizePath toolFile
    pure $ case lookupPackage idx "mytool" of
      Just sp -> spanFile sp == Just want
      Nothing -> False

-- ── flake.lock → nixpkgs store path (no eval) ──────────────────────

-- | A known (narHash, store path) vector: nixpkgs rev 64c08a7 as locked here.
vecNarHash :: Text
vecNarHash = "sha256-tpyBcxPpcQb8ukyNF7DoCwfSY3VPsxHoYwj00Cayv5o="

vecStorePath :: FilePath
vecStorePath = "/nix/store/81sr43harc753claf8bzyv3mrnjzq652-source"

{- | The fixed-output store-path computation, pinned to the known vector. If this
flips, the @makeFixedOutputPath@ math drifted from Nix.
-}
testStorePathVector :: IO Bool
testStorePathVector = pure (fixedOutputSourcePath vecNarHash == Just vecStorePath)

-- | Construct a minimal flake.lock with one nixpkgs node's @locked@ object.
flakeLock :: Text -> LBS.ByteString
flakeLock lockedObj =
  LBS.fromStrict . TE.encodeUtf8 $
    "{\"nodes\":{\"root\":{\"inputs\":{\"nixpkgs\":\"nixpkgs\"}},"
      <> "\"nixpkgs\":{\"locked\":"
      <> lockedObj
      <> "}},\"root\":\"root\"}"

-- | A github nixpkgs input resolves via its narHash to the realized store path.
testLockGithub :: IO Bool
testLockGithub =
  pure (nixpkgsRootFromLock lock == Just vecStorePath)
 where
  lock = flakeLock ("{\"type\":\"github\",\"narHash\":\"" <> vecNarHash <> "\"}")

-- | A path-type nixpkgs input resolves to its literal directory.
testLockPath :: IO Bool
testLockPath =
  pure
    ( nixpkgsRootFromLock (flakeLock "{\"type\":\"path\",\"path\":\"/local/nixpkgs\"}")
        == Just "/local/nixpkgs"
    )

-- ── runner ─────────────────────────────────────────────────────────

-- | The nixpkgs-index / cursor-recognizer / completion tests.
nixpkgsIndexTests :: [(String, IO Bool)]
nixpkgsIndexTests =
  [ ("nixpkgs_byname_resolves", testByNameResolves)
  , ("nixpkgs_byname_miss", testByNameMiss)
  , ("nixpkgs_no_byname_dir", testNoByNameDir)
  , ("nixpkgs_select_recognized", testSelectRecognized)
  , ("nixpkgs_select_first_segment", testSelectFirstSegment)
  , ("nixpkgs_select_ignores_bare_sym", testSelectIgnoresBareSym)
  , ("nixpkgs_completion_prefix", testCompletionPrefix)
  , ("nixpkgs_completion_non_pkgs", testCompletionNonPkgs)
  , ("nixpkgs_allpackages_resolves", testAllPackagesResolves)
  , ("nixpkgs_storepath_known_vector", testStorePathVector)
  , ("nixpkgs_lock_github_input", testLockGithub)
  , ("nixpkgs_lock_path_input", testLockPath)
  ]
