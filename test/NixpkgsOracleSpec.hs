{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                     // tests // nixpkgs // oracle
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Ask the box the right question and it draws you a map."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The eval→inference bridge ('buildPkgsOracle'), driven by a FAKE EvalBackend
--   (canned spines + field types, no nix) so the whole thing is hermetic:
--
--     * it collects exactly the @pkgs.<path>@ references in a file (and nothing
--       rooted elsewhere);
--     * a scalar leaf gets its real type;
--     * a set-valued path becomes a closed record of its spine, with a field
--       enriched to the scalar type it was also referenced at;
--     * an unresolvable path is skipped, not invented.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixpkgsOracleSpec (nixpkgsOracleTests) where

import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nix.Expr.Types.Annotated (NExprLoc)
import Nix.Parser (parseNixTextLoc)
import NixCompile.Inference.Nix.Type (NixType (..), pattern TAttrs)
import NixCompile.Nixpkgs.Eval (EvalBackend (..), EvalError (..))
import NixCompile.Nixpkgs.Index (emptyIndex)
import NixCompile.Nixpkgs.Oracle (buildPkgsOracle, collectPkgsChains, isScalarType)

-- ── helpers ────────────────────────────────────────────────────────

parse :: Text -> NExprLoc
parse src = either (\e -> error ("NixpkgsOracleSpec parse: " <> show e)) id (parseNixTextLoc src)

{- | A fake backend: spines and field types come from lookup tables; anything
absent is an eval failure ('Left'). The index argument is ignored.
-}
fakeBackend :: Map [Text] [Text] -> Map ([Text], Text) NixType -> EvalBackend
fakeBackend spines fieldTypes =
  EvalBackend
    { backendName = "fake"
    , evalSpine = \_ path -> pure (maybe (Left Unsupported) Right (Map.lookup path spines))
    , evalFieldType = \_ path field ->
        pure (maybe (Left Unsupported) Right (Map.lookup (path, field) fieldTypes))
    }

oracleFor :: Map [Text] [Text] -> Map ([Text], Text) NixType -> Text -> IO (Map [Text] NixType)
oracleFor spines fieldTypes src =
  buildPkgsOracle (fakeBackend spines fieldTypes) (emptyIndex "/fake") (parse src)

-- ── tests ──────────────────────────────────────────────────────────

-- | Collection finds the pkgs-rooted selects and ignores everything else.
testCollectChains :: IO Bool
testCollectChains =
  pure
    ( sort (collectPkgsChains (parse "{ a = pkgs.hello.pname; b = pkgs.ripgrep; c = foo.bar; }"))
        == [["hello", "pname"], ["ripgrep"]]
    )

-- | A scalar leaf path is pinned to its real type.
testScalarLeaf :: IO Bool
testScalarLeaf = do
  oracle <- oracleFor Map.empty (Map.singleton (["hello"], "pname") TString) "pkgs.hello.pname"
  pure (Map.lookup ["hello", "pname"] oracle == Just TString)

{- | A set-valued path becomes a closed record of its spine, and the field that
was ALSO referenced as a scalar leaf is enriched to that scalar type.
-}
testRecordWithEnrichment :: IO Bool
testRecordWithEnrichment = do
  let spines = Map.singleton ["hello"] ["pname", "version"]
      fieldTypes =
        Map.fromList
          [ (([], "hello"), TAny) -- pkgs.hello is a set
          , ((["hello"], "pname"), TString) -- pkgs.hello.pname is a string
          ]
  oracle <- oracleFor spines fieldTypes "{ a = pkgs.hello; b = pkgs.hello.pname; }"
  let want =
        TAttrs (Map.fromList [("pname", (TString, False)), ("version", (TAny, False))])
  pure
    ( Map.lookup ["hello"] oracle == Just want
        && Map.lookup ["hello", "pname"] oracle == Just TString
    )

-- | An unresolvable path (both spine and field type fail) yields no entry.
testUnresolvableSkipped :: IO Bool
testUnresolvableSkipped = do
  oracle <- oracleFor Map.empty Map.empty "pkgs.ghost.thing"
  pure (Map.null oracle)

-- | Scalar classification: scalars/lists yes, sets/functions/unknown no.
testScalarClassification :: IO Bool
testScalarClassification =
  pure
    ( all isScalarType [TString, TInt, TBool, TPath, TList TString]
        && not (any isScalarType [TAny, TAttrs Map.empty, TFun TInt TInt])
    )

-- ── runner ─────────────────────────────────────────────────────────

-- | The eval→inference oracle-bridge tests (hermetic; fake backend only).
nixpkgsOracleTests :: [(String, IO Bool)]
nixpkgsOracleTests =
  [ ("oracle_collect_chains", testCollectChains)
  , ("oracle_scalar_leaf", testScalarLeaf)
  , ("oracle_record_with_enrichment", testRecordWithEnrichment)
  , ("oracle_unresolvable_skipped", testUnresolvableSkipped)
  , ("oracle_scalar_classification", testScalarClassification)
  ]
