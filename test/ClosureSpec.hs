{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                     // tests // layout // closure
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He traced every wire the box touched, and the whole shape came clear."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The one reachability closure shared by check / infer / lsp. Two layers:
--
--     * 'discoverEdges' tags all three edge kinds from the AST, eval-free —
--       @import ./a@, a flake-parts @imports = [ … ]@ list, a top-level
--       @callPackage ./p { }@;
--     * 'closureEnv' walks a real temp tree from a root file and threads each
--       dependency's inferred type into the next, so a cross-module @import@
--       resolves to the dependency's actual record type (across a @../@ sibling,
--       which the old dir-bounded graph could not reach) — and a file with no
--       in-project imports leaves the base env untouched.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module ClosureSpec (closureTests) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import NixCompile.Core.Safety (safeParseNixText)
import NixCompile.Inference.Nix (TypeEnv (..), builtinEnv)
import NixCompile.Inference.Nix.Type (prettyType)
import NixCompile.Layout.Closure (Edge (..), EdgeKind (..), closureEnv, discoverEdges)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- ── helpers ────────────────────────────────────────────────────────

-- | The edges discovered in a snippet (parsed against a fixed base directory).
edgesOf :: Text -> IO [Edge]
edgesOf src = do
  parsed <- safeParseNixText src
  pure (either (const []) (discoverEdges "/proj") parsed)

{- | A two-file project under a temp root marked by @flake.nix@; returns the
cross-module env for @main.nix@.
-}
withTree :: Text -> Text -> (TypeEnv -> IO a) -> IO a
withTree dep main act =
  withSystemTempDirectory "closure" $ \dir -> do
    TIO.writeFile (dir </> "flake.nix") ""
    TIO.writeFile (dir </> "dep.nix") dep
    TIO.writeFile (dir </> "main.nix") main
    env <- closureEnv builtinEnv (dir </> "main.nix")
    act env

-- ── edge discovery ─────────────────────────────────────────────────

-- | @import ./a.nix@ is one 'EImport' edge naming the raw path.
testImportEdge :: IO Bool
testImportEdge = do
  es <- edgesOf "import ./a.nix"
  pure (any (\e -> edgeKind e == EImport && edgeRaw e == "./a.nix") es)

-- | A flake-parts @imports = [ … ]@ list yields one 'EFlakeImport' per element.
testFlakeEdges :: IO Bool
testFlakeEdges = do
  es <- edgesOf "{ imports = [ ./m.nix ./n.nix ]; }"
  pure (length (filter ((== EFlakeImport) . edgeKind) es) == 2)

-- | A top-level @callPackage ./p { }@ binding is one 'ECallPackage' edge.
testCallPackageEdge :: IO Bool
testCallPackageEdge = do
  es <- edgesOf "{ foo = callPackage ./pkg.nix { }; }"
  pure (any (\e -> edgeKind e == ECallPackage && edgeRaw e == "./pkg.nix") es)

-- ── the type closure ───────────────────────────────────────────────

-- | A cross-module @import@ resolves to the dependency's actual record type.
testCrossModuleType :: IO Bool
testCrossModuleType =
  withTree "{ a = 1; b = \"x\"; }\n" "import ./dep.nix\n" $ \env ->
    pure (any recordWithFields (Map.elems (envImportTypes env)))
 where
  recordWithFields t = "a" `T.isInfixOf` rendered t && "b" `T.isInfixOf` rendered t
  rendered = prettyType

{- | A @callPackage ./dep.nix { }@ site resolves to the package's RESULT type (the
body of @dep.nix@'s function), not the function itself.
-}
testCallPackageResult :: IO Bool
testCallPackageResult =
  withTree depFn callerFn $ \env ->
    pure (any (T.isInfixOf "nm" . prettyType) (Map.elems (envCallPackageTypes env)))
 where
  depFn = "{ stdenv }: { nm = 1; }\n"
  callerFn = "{ callPackage }: { p = callPackage ./dep.nix { }; }\n"

-- | A file with no in-project imports leaves the base env's import types untouched.
testNoImportsIsBase :: IO Bool
testNoImportsIsBase =
  withTree "{ a = 1; }\n" "{ x = 1; }\n" $ \env ->
    pure (envImportTypes env == envImportTypes builtinEnv)

-- ── runner ──────────────────────────────────────────────────────────

-- | The shared-closure tests (edge discovery hermetic; type flow on a temp tree).
closureTests :: [(String, IO Bool)]
closureTests =
  [ ("closure_discovers_import_edge", testImportEdge)
  , ("closure_discovers_flake_imports", testFlakeEdges)
  , ("closure_discovers_callpackage_edge", testCallPackageEdge)
  , ("closure_cross_module_type_flows", testCrossModuleType)
  , ("closure_callpackage_result_type_flows", testCallPackageResult)
  , ("closure_no_imports_is_base_env", testNoImportsIsBase)
  ]
