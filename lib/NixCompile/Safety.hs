{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                          // safety
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He was good as new. How good was that?"
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                              // single source of safety
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Safety (
    -- * Constants
    maxRecursionDepth,

    -- * Errors
    SafetyError (..),
    DepthError (..),
    renderSafetyError,

    -- * Depth analysis
    analyzeDepth,
    analyzeDepthWith,

    -- * Exception-safe wrappers
    safeParseNixText,
    safeParseNixFile,
    safeReadFile,
    safeIO,
    safeIOWith,

    -- * Combined analysis
    safeAnalyze,
)
where

import Control.Exception (Exception, SomeException, evaluate, fromException, try)
import Control.Exception qualified as Exc
import Data.Fix (Fix (..))
import Data.Functor.Compose (Compose (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nix.Expr.Types
import Nix.Expr.Types.Annotated (AnnUnit (..), NExprLoc)
import Nix.Parser (parseNixFileLoc, parseNixTextLoc)
import Nix.Utils (Path (..))
import System.IO.Error (isDoesNotExistError)

-- ── single-source depth constant ──────────────────────────────────
-- Every guard in the codebase reads from here. Do not duplicate.

maxRecursionDepth :: Int
maxRecursionDepth = 200

-- ── errors ────────────────────────────────────────────────────────

data DepthError = DepthError
    { deDepth :: !Int
    , deContext :: !Text
    }
    deriving (Eq, Show)

data SafetyError
    = SafetyDepthExceeded !DepthError
    | SafetyParseFailed !Text
    | SafetyStackOverflow
    | SafetyInternalException !Text
    | SafetyIOError !Text
    deriving (Eq, Show)

instance Exception SafetyError

renderSafetyError :: SafetyError -> Text
renderSafetyError = \case
    SafetyDepthExceeded (DepthError d ctx) ->
        "depth limit exceeded (" <> T.pack (show d) <> " > " <> T.pack (show maxRecursionDepth)
            <> ") at "
            <> ctx
    SafetyParseFailed t -> "parse error: " <> t
    SafetyStackOverflow -> "stack overflow — input too deeply nested for parser"
    SafetyInternalException t -> "internal exception: " <> t
    SafetyIOError t -> "I/O error: " <> t

-- ── depth analysis ────────────────────────────────────────────────
-- Walks EVERY Fix unwrap. Cannot be bypassed by NWith/NStr/NSynHole.
-- Strictly counts depth on every recursion regardless of constructor.

analyzeDepth :: NExprLoc -> Either DepthError ()
analyzeDepth = analyzeDepthWith maxRecursionDepth

analyzeDepthWith :: Int -> NExprLoc -> Either DepthError ()
analyzeDepthWith limit = go 0
  where
    go :: Int -> NExprLoc -> Either DepthError ()
    go !d (Fix (Compose (AnnUnit _ expr)))
        | d > limit = Left (DepthError d (constructorTag expr))
        | otherwise = walk (d + 1) expr

    walk :: Int -> NExprF NExprLoc -> Either DepthError ()
    walk d = \case
        NConstant _ -> Right ()
        NSym _ -> Right ()
        NLiteralPath _ -> Right ()
        NEnvPath _ -> Right ()
        NSynHole _ -> Right ()
        NStr (DoubleQuoted parts) -> mapM_ (goAnti d) parts
        NStr (Indented _ parts) -> mapM_ (goAnti d) parts
        NList xs -> mapM_ (go d) xs
        NSet _ bs -> mapM_ (goBinding d) bs
        NLet bs body -> mapM_ (goBinding d) bs >> go d body
        NIf c t e -> go d c >> go d t >> go d e
        NWith s b -> go d s >> go d b
        NAssert c b -> go d c >> go d b
        NAbs p b -> goParams d p >> go d b
        NApp f a -> go d f >> go d a
        NSelect alt b path -> go d b >> mapM_ (go d) alt >> goPath d path
        NHasAttr b path -> go d b >> goPath d path
        NUnary _ x -> go d x
        NBinary _ x y -> go d x >> go d y

    goAnti d (Antiquoted e) = go d e
    goAnti _ _ = Right ()

    goBinding d (NamedVar path e _) = goPath d path >> go d e
    goBinding d (Inherit ms _ _) = maybe (Right ()) (go d) ms

    goPath d path = goPath' d (toList' path)
    goPath' d ks = mapM_ (goKey d) ks
    goKey d (DynamicKey (Antiquoted e)) = go d e
    goKey _ _ = Right ()

    goParams _ (Param _) = Right ()
    goParams d (ParamSet _ _ items) =
        mapM_ (\(_, mDef) -> maybe (Right ()) (go d) mDef) items

    toList' (k :| ks) = k : ks

    constructorTag = \case
        NSet _ _ -> "attrset"
        NList _ -> "list"
        NApp _ _ -> "application"
        NLet _ _ -> "let"
        NWith _ _ -> "with"
        NIf _ _ _ -> "if"
        NStr (DoubleQuoted _) -> "string interpolation"
        NStr (Indented _ _) -> "indented-string interpolation"
        NAbs _ _ -> "lambda"
        NBinary _ _ _ -> "binary operator"
        NUnary _ _ -> "unary operator"
        NSelect _ _ _ -> "attribute select"
        NHasAttr _ _ -> "attribute test"
        NAssert _ _ -> "assertion"
        NSynHole _ -> "syntax hole"
        NConstant _ -> "constant"
        NSym _ -> "symbol"
        NLiteralPath _ -> "path"
        NEnvPath _ -> "env path"

-- ── exception-safe wrappers ───────────────────────────────────────
-- Every parse/IO call goes through one of these. They catch StackOverflow
-- and other async exceptions that try @IOException misses.

-- | catch every exception including StackOverflow; return SafetyError.
safeIO :: IO a -> IO (Either SafetyError a)
safeIO = safeIOWith mempty

safeIOWith :: Text -> IO a -> IO (Either SafetyError a)
safeIOWith prefix action = do
    result <- try (action >>= evaluate)
    pure $ case result of
        Right v -> Right v
        Left (e :: SomeException) -> Left (classify prefix e)
  where
    classify pfx e
        | Just Exc.StackOverflow <- fromException e = SafetyStackOverflow
        | Just (ioe :: IOError) <- fromException e
        , isDoesNotExistError ioe =
            SafetyIOError (pfx <> T.pack (show ioe))
        | Just (ioe :: IOError) <- fromException e =
            SafetyIOError (pfx <> T.pack (show ioe))
        | otherwise = SafetyInternalException (pfx <> T.pack (show e))

-- | safely read a UTF-8 file; converts every failure mode to SafetyError.
safeReadFile :: FilePath -> IO (Either SafetyError Text)
safeReadFile path = safeIOWith (T.pack path <> ": ") (TIO.readFile path)

-- | safely parse a Nix text buffer; catches stack overflows from megaparsec.
safeParseNixText :: Text -> IO (Either SafetyError NExprLoc)
safeParseNixText src = do
    r <- safeIO (evaluate (parseNixTextLoc src))
    pure $ case r of
        Left e -> Left e
        Right (Left doc) -> Left (SafetyParseFailed (T.pack (show doc)))
        Right (Right expr) -> Right expr

-- | safely parse a Nix file; catches stack overflows, missing files, parse errors.
safeParseNixFile :: FilePath -> IO (Either SafetyError NExprLoc)
safeParseNixFile path = do
    r <- safeIO (parseNixFileLoc (Path path))
    pure $ case r of
        Left e -> Left e
        Right (Left doc) -> Left (SafetyParseFailed (T.pack (show doc)))
        Right (Right expr) -> Right expr

-- ── combined: parse + depth ──────────────────────────────────────

{- | full safety pipeline: parse, then check depth, then return AST.
Every public entry point should funnel through this (or 'analyzeDepth' if the
AST is already in hand).
-}
safeAnalyze :: NExprLoc -> Either SafetyError NExprLoc
safeAnalyze expr = case analyzeDepth expr of
    Left de -> Left (SafetyDepthExceeded de)
    Right () -> Right expr

