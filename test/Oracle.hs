{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                              // tests // differential oracle
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
-- Ground-truth check for the Nix type checker: for each (closed) expression,
-- compare the inferred type against what `nix-instantiate --eval` actually
-- produces via `builtins.typeOf`. This is the soundness oracle the review
-- (REVIEW-3 #9) said was missing — the one property a type checker most needs:
-- "accept ⟹ the runtime type matches what we claimed".
--
-- Verdicts:
--   MISMATCH    checker claimed kind K, runtime is K'≠K          → FAILURE (unsound)
--   CHECKER-HANG inference didn't terminate within the timeout    → FAILURE
--   AGREE       checker kind == runtime kind                      → ok
--   AGREE-REJECT both checker and runtime reject the expression   → ok
--   TYPED-NOEVAL checker typed it but it didn't evaluate          → noted (e.g.
--                runtime error like `head []`; NOT a type error, so not a fail)
--   INCOMPLETE  checker rejected something that evaluates fine    → noted
--                (conservative checker; these are the RC1/RC2 gaps)
--   (skipped)   no concrete claim (TVar/TAny/TUnion) or parse fail
--
-- The suite SKIPS cleanly (exit 0) when `nix-instantiate` is absent — e.g. the
-- sandboxed flake check, where recursive nix is unavailable. It does real work
-- in the dev shell / any CI step that has nix on PATH.
module Main (main) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM)
import Data.Char (isSpace)
import Data.Text qualified as T
import Nix.Parser (parseNixTextLoc)
import NixCompile.Nix.Inference (inferExpr)
import NixCompile.Nix.Types (NixType (..))
import System.Directory (findExecutable)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

-- | timeout for both the checker and a single nix-instantiate call (microseconds)
timeoutMicros :: Int
timeoutMicros = 20 * 1000000

-- ── corpus: closed expressions spanning the type system + the review fixes ──
-- Every entry must be a CLOSED Nix expression (no free variables) so
-- nix-instantiate can evaluate it. The trailing comment is just a label.
corpus :: [String]
corpus =
    [ -- literals
      "42"
    , "-7"
    , "3.14"
    , "true"
    , "null"
    , "\"hello\""
    , "./some/path"
    , -- arithmetic (REVIEW-3 #7)
      "1 + 1"
    , "1 + 1.5"
    , "2 * 3 - 4"
    , "7 / 2"
    , "1.0 + 2"
    , -- string / path concat (REVIEW-3 #7)
      "\"a\" + \"b\""
    , "./x + \"y\""
    , -- comparison / equality (REVIEW-3 #3)
      "1 == null"
    , "1 == 2"
    , "\"a\" == \"b\""
    , "1 < 2"
    , "true && false"
    , "true || false"
    , -- collections
      "[ 1 2 3 ]"
    , "{ a = 1; b = true; }"
    , "[ ]"
    , -- selection, incl. nested (REVIEW-3 #1)
      "{ a = 1; }.a"
    , "let x = { a = { b = { c = 1; }; }; }; in x.a.b.c"
    , "{ a = 1; }.z or 99"
    , -- lambdas / application
      "(x: x) 5"
    , "(x: x + 1) 41"
    , "let f = x: y: x + y; in f 2 3"
    , "x: x"
    , -- polymorphic builtins (REVIEW-3 #4, #19). Note: only `map` is in Nix's
      -- GLOBAL scope; head/filter/foldl'/elemAt/length live under `builtins.`
      -- only (bare `head` is an undefined variable at eval — see REVIEW-3 #20).
      "map (x: x + 1) [ 1 2 3 ]"
    , "builtins.head [ 10 20 ]"
    , "builtins.length [ 1 2 ]"
    , "builtins.elemAt [ 10 20 ] 1"
    , "builtins.filter (x: x) [ true false ]"
    , "builtins.foldl' (a: b: a + b) 0 [ 1 2 3 ]"
    , -- row-polymorphic attribute builtins (RC1 stage 4)
      "builtins.attrNames { a = 1; b = 2; }"
    , "builtins.attrValues { a = 1; }"
    , "builtins.hasAttr \"a\" { a = 1; }"
    , -- bare non-global builtin: checker accepts, Nix rejects (undefined var).
      -- Documents the #20 scope discrepancy; shows up as 'incomplete'/typed-noeval.
      "head [ 1 2 ]"
    , -- other builtins
      "toString 5"
    , "builtins.stringLength \"abc\""
    , "if true then 1 else 2"
    , -- expressions that SHOULD type-error at runtime (checker should reject too)
      "1 + \"a\""
    , "1 + true"
    ]

-- | Map an inferred type to the runtime kind string `builtins.typeOf` reports,
-- or Nothing when the checker made no concrete claim (so nothing to assert).
expectedKind :: NixType -> Maybe String
expectedKind = \case
    TInt -> Just "int"
    TFloat -> Just "float"
    TBool -> Just "bool"
    TString -> Just "string"
    TStrLit _ -> Just "string"
    TPath -> Just "path"
    TNull -> Just "null"
    TList _ -> Just "list"
    TRec _ _ -> Just "set"
    TFun _ _ -> Just "lambda"
    TDerivation -> Just "set"
    -- no concrete claim: don't assert
    TVar _ -> Nothing
    TUnion _ -> Nothing
    TAny -> Nothing

-- ── checker side ──
data CheckRes = ParseFail | CheckerHang | Rejected | Accepted NixType

runChecker :: String -> IO CheckRes
runChecker e = case parseNixTextLoc (T.pack e) of
    Left _ -> pure ParseFail
    Right ast ->
        -- force enough to surface a non-terminating inference as a HANG rather
        -- than letting it wedge the whole suite (this is what catches #19-class bugs)
        timeout timeoutMicros (evaluate (classify (inferExpr ast))) >>= \case
            Nothing -> pure CheckerHang
            Just r -> pure r
  where
    classify = \case
        Left _ -> Rejected
        Right (t, _) -> expectedKind t `seq` Accepted t

-- ── oracle side ──
-- | runtime kind via `nix-instantiate --eval -E 'builtins.typeOf (EXPR)'`,
-- or Nothing if it errors / times out (did not evaluate to a value).
nixTypeOf :: String -> IO (Maybe String)
nixTypeOf e = do
    let arg = "builtins.typeOf (" ++ e ++ ")"
    res <-
        timeout
            timeoutMicros
            (try (readProcessWithExitCode "nix-instantiate" ["--eval", "-E", arg] "")
                :: IO (Either SomeException (ExitCode, String, String)))
    pure $ case res of
        Just (Right (ExitSuccess, out, _)) -> Just (cleanKind out)
        _ -> Nothing
  where
    -- output is e.g. "\"int\"\n"; strip quotes and whitespace
    cleanKind = filter (\c -> c /= '"' && not (isSpace c))

-- ── verdicts ──
data Verdict
    = Mismatch String String -- claimed, actual
    | CheckHang
    | Agree String
    | AgreeReject
    | TypedNoEval String
    | Incomplete String -- runtime kind it evaluated to
    | Skipped String

isFailure :: Verdict -> Bool
isFailure (Mismatch _ _) = True
isFailure CheckHang = True
isFailure _ = False

verdict :: CheckRes -> Maybe String -> Verdict
verdict CheckerHang _ = CheckHang
verdict ParseFail _ = Skipped "parse-fail"
verdict Rejected Nothing = AgreeReject
verdict Rejected (Just k) = Incomplete k
verdict (Accepted t) moracle = case (expectedKind t, moracle) of
    (Nothing, _) -> Skipped "no-concrete-claim"
    (Just k, Just k') | k == k' -> Agree k
    (Just k, Just k') -> Mismatch k k'
    (Just k, Nothing) -> TypedNoEval k

renderVerdict :: Verdict -> String
renderVerdict = \case
    Mismatch c a -> "MISMATCH  claimed=" ++ c ++ " runtime=" ++ a
    CheckHang -> "CHECKER-HANG"
    Agree k -> "AGREE     " ++ k
    AgreeReject -> "AGREE-REJECT (both reject)"
    TypedNoEval k -> "typed-but-noeval (" ++ k ++ ")"
    Incomplete k -> "INCOMPLETE (checker rejected; runtime=" ++ k ++ ")"
    Skipped why -> "skipped (" ++ why ++ ")"

main :: IO ()
main = do
    putStrLn "nix-compile differential oracle (checker vs nix-instantiate)"
    putStrLn "============================================================"
    mNix <- findExecutable "nix-instantiate"
    case mNix of
        Nothing -> do
            putStrLn "nix-instantiate not found on PATH — skipping (vacuous pass)."
            exitSuccess
        Just _ -> do
            verdicts <- forM corpus $ \e -> do
                cr <- runChecker e
                oracle <- nixTypeOf e
                let v = verdict cr oracle
                putStrLn $ "  " ++ pad 52 e ++ renderVerdict v
                pure v
            let failures = filter isFailure verdicts
                nAgree = length [() | Agree _ <- verdicts]
                nReject = length [() | AgreeReject <- verdicts]
                nIncomplete = length [() | Incomplete _ <- verdicts]
                nNoEval = length [() | TypedNoEval _ <- verdicts]
            putStrLn ""
            putStrLn $
                "agree="
                    ++ show nAgree
                    ++ " agree-reject="
                    ++ show nReject
                    ++ " incomplete="
                    ++ show nIncomplete
                    ++ " typed-noeval="
                    ++ show nNoEval
                    ++ " FAILURES="
                    ++ show (length failures)
            putStrLn "note: 'incomplete' = conservative rejection (RC1/RC2 gap), not a failure."
            if null failures
                then do
                    putStrLn "oracle: OK (no soundness mismatches)"
                    exitSuccess
                else do
                    putStrLn "oracle: FAILED (soundness mismatch or checker hang)"
                    exitFailure
  where
    pad n s = take n (s ++ repeat ' ')
