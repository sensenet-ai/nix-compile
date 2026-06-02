{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                            // bench
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "The clock above the bar was beating like a pulse, like a metronome."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   Microbenchmarks for the hot paths:
--     1. escapeForParamExpansion  (C1 escape function)
--     2. parseNixExpr             (hnix wrapper)
--     3. analyzeDepth             (depth precondition)
--     4. inferExprWithEnv         (HM core)
--     5. combinedLintSafe         (single-pass lint walk)
--     6. safety-pipeline          (parse + analyze + infer end-to-end)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module Main (main) where

import Control.DeepSeq (NFData (..))
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Expr.Types.Annotated (NExprLoc)
import NixCompile.Bash.Patterns (escapeForParamExpansion)
import NixCompile.Nix.Infer (builtinEnv, inferExprWithEnv)
import NixCompile.Nix.LintCombined qualified as LC
import NixCompile.Nix.Parse (parseNixExpr)
import NixCompile.Safety qualified as Safety
import Test.Tasty.Bench

-- ── input generators ──────────────────────────────────────────────

-- | let x0 = 0; x1 = x0 + 1; ...; xN = xN-1 + 1; in xN
letChain :: Int -> Text
letChain n =
    "let "
        <> T.concat
            [ "x" <> T.pack (show i) <> " = " <> previous i <> "; "
            | i <- [0 .. n - 1]
            ]
        <> "in x"
        <> T.pack (show (n - 1))
  where
    previous 0 = "0"
    previous i = "x" <> T.pack (show (i - 1)) <> " + 1"

-- | { k0 = 0; k1 = 1; ...; kN-1 = N-1; }
attrSet :: Int -> Text
attrSet n =
    "{ "
        <> T.concat ["k" <> T.pack (show i) <> " = " <> T.pack (show i) <> "; " | i <- [0 .. n - 1]]
        <> "}"

-- | [0 1 2 ... N-1]
listLit :: Int -> Text
listLit n = "[" <> T.intercalate " " [T.pack (show i) | i <- [0 .. n - 1]] <> "]"

-- | f (f (f (... 0 ...))) at depth n
appChain :: Int -> Text
appChain n = T.replicate n "f (" <> "0" <> T.replicate n ")"

mixedWorkload :: Int -> Text
mixedWorkload n =
    T.unlines
        [ "let"
        , "  inc = x: x + 1;"
        , "  double = x: x + x;"
        , "  data = " <> attrSet n <> ";"
        , "  xs = " <> listLit n <> ";"
        , "in"
        , "  { result = data; }"
        ]

-- ── pre-parse helpers ──────────────────────────────────────────────

-- | Pre-parse benchmark input once; force the AST so the timing measures
-- only the function under test, not parsing.
parseFixture :: Text -> NExprLoc
parseFixture src = case parseNixExpr src of
    Right e -> e
    Left err -> error ("benchmark fixture failed to parse: " <> T.unpack err)

-- ── NFData wrappers (tasty-bench's nf requires it) ─────────────────

newtype Whnf a = Whnf a

instance NFData (Whnf a) where
    rnf (Whnf _) = ()

-- ── benchmarks ─────────────────────────────────────────────────────

main :: IO ()
main =
    defaultMain
        [ bgroup
            "escapeForParamExpansion"
            [ bench "safe-10char" $ nf escapeForParamExpansion "localhost"
            , bench "safe-100char" $ nf escapeForParamExpansion (T.replicate 100 "a")
            , bench "malicious-short" $ nf escapeForParamExpansion "$(touch /tmp/x)"
            , bench "malicious-50" $ nf escapeForParamExpansion (T.replicate 10 "$(id)")
            ]
        , bgroup
            "parseNixExpr"
            [ bench "let-chain-10" $ nf parseStr (letChain 10)
            , bench "let-chain-50" $ nf parseStr (letChain 50)
            , bench "attrset-10" $ nf parseStr (attrSet 10)
            , bench "attrset-100" $ nf parseStr (attrSet 100)
            , bench "list-100" $ nf parseStr (listLit 100)
            , bench "app-chain-50" $ nf parseStr (appChain 50)
            , bench "mixed-50" $ nf parseStr (mixedWorkload 50)
            ]
        , let !astLet10 = parseFixture (letChain 10)
              !astLet50 = parseFixture (letChain 50)
              !astAttr100 = parseFixture (attrSet 100)
              !astList1000 = parseFixture (listLit 1000)
              !astApp50 = parseFixture (appChain 50)
              !astApp150 = parseFixture (appChain 150)
              !astMixed50 = parseFixture (mixedWorkload 50)
           in bgroup
                "analyzeDepth"
                [ bench "let-chain-10" $ nf analyzeWHNF astLet10
                , bench "let-chain-50" $ nf analyzeWHNF astLet50
                , bench "attrset-100" $ nf analyzeWHNF astAttr100
                , bench "list-1000" $ nf analyzeWHNF astList1000
                , bench "app-chain-50" $ nf analyzeWHNF astApp50
                , bench "app-chain-150" $ nf analyzeWHNF astApp150
                , bench "mixed-50" $ nf analyzeWHNF astMixed50
                ]
        , let !astLet10 = parseFixture (letChain 10)
              !astLet50 = parseFixture (letChain 50)
              !astAttr10 = parseFixture (attrSet 10)
              !astAttr100 = parseFixture (attrSet 100)
              !astMixed10 = parseFixture (mixedWorkload 10)
              !astMixed50 = parseFixture (mixedWorkload 50)
           in bgroup
                "inferExprWithEnv"
                [ bench "let-chain-10" $ nf inferWHNF astLet10
                , bench "let-chain-50" $ nf inferWHNF astLet50
                , bench "attrset-10" $ nf inferWHNF astAttr10
                , bench "attrset-100" $ nf inferWHNF astAttr100
                , bench "mixed-10" $ nf inferWHNF astMixed10
                , bench "mixed-50" $ nf inferWHNF astMixed50
                ]
        , let !astLet10 = parseFixture (letChain 10)
              !astLet50 = parseFixture (letChain 50)
              !astAttr100 = parseFixture (attrSet 100)
              !astList1000 = parseFixture (listLit 1000)
              !astMixed50 = parseFixture (mixedWorkload 50)
           in bgroup
                "combinedLintSafe"
                [ bench "let-chain-10" $ nf lintWHNF astLet10
                , bench "let-chain-50" $ nf lintWHNF astLet50
                , bench "attrset-100" $ nf lintWHNF astAttr100
                , bench "list-1000" $ nf lintWHNF astList1000
                , bench "mixed-50" $ nf lintWHNF astMixed50
                ]
        , bgroup
            "safety-pipeline"
            [ -- parse → analyzeDepth → infer end-to-end
              bench "let-chain-10" $ nf safetyPipelineResult (letChain 10)
            , bench "let-chain-50" $ nf safetyPipelineResult (letChain 50)
            , bench "mixed-10" $ nf safetyPipelineResult (mixedWorkload 10)
            , bench "mixed-50" $ nf safetyPipelineResult (mixedWorkload 50)
            ]
        ]
  where
    parseStr s = case parseNixExpr s of
        Right _ -> True
        Left _ -> False

    analyzeWHNF expr = case Safety.analyzeDepth expr of
        Right _ -> True
        Left _ -> False

    inferWHNF expr = case inferExprWithEnv builtinEnv expr of
        Right _ -> True
        Left _ -> False

    lintWHNF expr = case LC.combinedLintSafe "<bench>" expr of
        LC.LintOk _ -> True
        LC.LintDepthExceeded _ -> False

    safetyPipelineResult src = case parseNixExpr src of
        Left _ -> False
        Right expr -> case Safety.analyzeDepth expr of
            Left _ -> False
            Right () -> case inferExprWithEnv builtinEnv expr of
                Left _ -> False
                Right _ -> True
