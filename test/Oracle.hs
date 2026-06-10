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
-- Ground truth comes from a FROZEN GOLDEN ('goldenTable') — each corpus entry's
-- runtime kind, captured once from `nix-instantiate`. So the suite does real
-- soundness work even with no nix on PATH (e.g. the sandboxed flake check): it
-- still flags the checker claiming a kind the runtime disagrees with. When nix
-- IS present it additionally re-runs the live differential and fails on any
-- drift between the golden and real nix, so the table cannot silently rot.
-- Refresh the golden after editing 'corpus': `… nix-compile-oracle -- --dump-golden`.
module Main (main) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM, unless)
import Data.Char (isSpace)
import Data.List (intercalate)
import Data.Maybe (catMaybes, fromMaybe, isNothing)
import Data.Text qualified as T
import Nix.Parser (parseNixTextLoc)
import NixCompile.Inference.Nix (inferExpr)
import NixCompile.Inference.Nix.Type (NixType (..))
import System.Directory (findExecutable)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
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

{- | Map an inferred type to the runtime kind string `builtins.typeOf` reports,
or Nothing when the checker made no concrete claim (so nothing to assert).
-}
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

{- | runtime kind via `nix-instantiate --eval -E 'builtins.typeOf (EXPR)'`,
or Nothing if it errors / times out (did not evaluate to a value).
-}
nixTypeOf :: String -> IO (Maybe String)
nixTypeOf e = do
  let arg = "builtins.typeOf (" ++ e ++ ")"
  res <-
    timeout
      timeoutMicros
      ( try (readProcessWithExitCode "nix-instantiate" ["--eval", "-E", arg] "") ::
          IO (Either SomeException (ExitCode, String, String))
      )
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

{- | Frozen ground truth: each corpus entry paired with the runtime kind
'nix-instantiate' reports for it ('Just' a @builtins.typeOf@ string, or 'Nothing'
when it does not evaluate to a value — e.g. @head []@ or a runtime type error).

These kinds are STABLE (@builtins.typeOf 42@ is always @"int"@), so freezing them
lets the soundness check run hermetically — no nix in the loop — and still catch
the one thing that matters: the checker claiming a kind the runtime disagrees
with (MISMATCH). The live differential ('nixTypeOf') runs whenever nix IS present
and re-verifies this table, so it cannot silently rot.

Refresh after changing 'corpus' (needs nix on PATH):

    cabal run -v0 nix-compile-oracle -- --dump-golden
-}
goldenTable :: [(String, Maybe String)]
goldenTable =
  [ ("42", Just "int")
  , ("-7", Just "int")
  , ("3.14", Just "float")
  , ("true", Just "bool")
  , ("null", Just "null")
  , ("\"hello\"", Just "string")
  , ("./some/path", Just "path")
  , ("1 + 1", Just "int")
  , ("1 + 1.5", Just "float")
  , ("2 * 3 - 4", Just "int")
  , ("7 / 2", Just "int")
  , ("1.0 + 2", Just "float")
  , ("\"a\" + \"b\"", Just "string")
  , ("./x + \"y\"", Just "path")
  , ("1 == null", Just "bool")
  , ("1 == 2", Just "bool")
  , ("\"a\" == \"b\"", Just "bool")
  , ("1 < 2", Just "bool")
  , ("true && false", Just "bool")
  , ("true || false", Just "bool")
  , ("[ 1 2 3 ]", Just "list")
  , ("{ a = 1; b = true; }", Just "set")
  , ("[ ]", Just "list")
  , ("{ a = 1; }.a", Just "int")
  , ("let x = { a = { b = { c = 1; }; }; }; in x.a.b.c", Just "int")
  , ("{ a = 1; }.z or 99", Just "int")
  , ("(x: x) 5", Just "int")
  , ("(x: x + 1) 41", Just "int")
  , ("let f = x: y: x + y; in f 2 3", Just "int")
  , ("x: x", Just "lambda")
  , ("map (x: x + 1) [ 1 2 3 ]", Just "list")
  , ("builtins.head [ 10 20 ]", Just "int")
  , ("builtins.length [ 1 2 ]", Just "int")
  , ("builtins.elemAt [ 10 20 ] 1", Just "int")
  , ("builtins.filter (x: x) [ true false ]", Just "list")
  , ("builtins.foldl' (a: b: a + b) 0 [ 1 2 3 ]", Just "int")
  , ("builtins.attrNames { a = 1; b = 2; }", Just "list")
  , ("builtins.attrValues { a = 1; }", Just "list")
  , ("builtins.hasAttr \"a\" { a = 1; }", Just "bool")
  , ("head [ 1 2 ]", Nothing)
  , ("toString 5", Just "string")
  , ("builtins.stringLength \"abc\"", Just "int")
  , ("if true then 1 else 2", Just "int")
  , ("1 + \"a\"", Nothing)
  , ("1 + true", Nothing)
  ]

-- | Ground truth for an entry from the frozen table, if present.
goldenFor :: String -> Maybe (Maybe String)
goldenFor e = lookup e goldenTable

main :: IO ()
main = do
  args <- getArgs
  if "--dump-golden" `elem` args then dumpGolden else runOracle

{- | Regenerate 'goldenTable' from the live oracle and print it as Haskell source
to paste back in. Requires nix-instantiate on PATH (it is the source of truth).
-}
dumpGolden :: IO ()
dumpGolden = do
  mNix <- findExecutable "nix-instantiate"
  case mNix of
    Nothing -> hPutStrLn stderr "--dump-golden requires nix-instantiate on PATH" >> exitFailure
    Just _ -> do
      rows <- forM corpus $ \e -> do k <- nixTypeOf e; pure (e, k)
      putStrLn "goldenTable :: [(String, Maybe String)]"
      putStrLn ("goldenTable =\n  [ " ++ intercalate "\n  , " (map show rows) ++ "\n  ]")

runOracle :: IO ()
runOracle = do
  putStrLn "nix-compile differential oracle (checker vs nix-instantiate)"
  putStrLn "============================================================"
  -- Every corpus entry must have a frozen ground truth; a missing one means the
  -- corpus grew without a `--dump-golden` refresh, which we fail on loudly.
  let missing = [e | e <- corpus, isNothing (goldenFor e)]
  unless (null missing) $ do
    putStrLn "oracle: FAILED — corpus entries missing from goldenTable (run -- --dump-golden):"
    mapM_ (\e -> putStrLn ("  " ++ e)) missing
    exitFailure

  -- Hermetic verdicts: the (pure) checker vs the frozen ground truth.
  verdicts <- forM corpus $ \e -> do
    cr <- runChecker e
    let v = verdict cr (concatGolden (goldenFor e))
    putStrLn $ "  " ++ pad 52 e ++ renderVerdict v
    pure v

  -- When nix IS present, re-verify the frozen table against the live oracle so
  -- it cannot silently drift from real nix semantics.
  mNix <- findExecutable "nix-instantiate"
  drift <- maybe (pure []) (const driftReport) mNix

  let failures = filter isFailure verdicts
      nAgree = length [() | Agree _ <- verdicts]
      nReject = length [() | AgreeReject <- verdicts]
      nIncomplete = length [() | Incomplete _ <- verdicts]
      nNoEval = length [() | TypedNoEval _ <- verdicts]
  putStrLn ""
  putStrLn (maybe "ground truth: frozen golden (no nix on PATH)" (const "ground truth: frozen golden + live nix drift-check") mNix)
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
      ++ " drift="
      ++ show (length drift)
  putStrLn "note: 'incomplete' = conservative rejection (RC1/RC2 gap), not a failure."
  unless (null drift) $ do
    putStrLn "oracle: golden DRIFT — frozen kinds disagree with live nix (refresh with -- --dump-golden):"
    mapM_ (putStrLn . ("  " ++)) drift
  if null failures && null drift
    then putStrLn "oracle: OK (no soundness mismatches)" >> exitSuccess
    else putStrLn "oracle: FAILED (soundness mismatch, checker hang, or golden drift)" >> exitFailure
 where
  pad n s = take n (s ++ repeat ' ')
  -- a present-but-Nothing golden entry means "did not evaluate"; flatten the
  -- Maybe (Maybe String) lookup (absence already failed loudly above).
  concatGolden Nothing = Nothing
  concatGolden (Just g) = g

{- | Compare every frozen golden kind against a fresh live nix-instantiate run;
return a human-readable line for each entry where they disagree.
-}
driftReport :: IO [String]
driftReport = fmap catMaybes $ forM corpus $ \e -> do
  live <- nixTypeOf e
  pure $ case goldenFor e of
    Just g | g == live -> Nothing
    Just g -> Just (pad 52 e ++ "golden=" ++ showKind g ++ " live=" ++ showKind live)
    Nothing -> Nothing
 where
  pad n s = take n (s ++ repeat ' ')
  showKind = fromMaybe "<noeval>"
