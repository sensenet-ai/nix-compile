{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                       // nix // format
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He was good as new. How good was that?"
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // formatting //
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Format (
    -- * Formatting
    formatFile,
    formatFileWithEnv,
    formatExpr,
)
where

import Data.Text (Text)
import Nix.Expr.Types.Annotated (NExprLoc)
import NixCompile.Nix.Infer (InferResult (..), TypeEnv, builtinEnv, inferExprWithEnv)
import NixCompile.Nix.Parse (parseNix, parseNixFile)
import NixCompile.Nix.Annotate (annotateSource)
import NixCompile.Safety qualified as Safety

-- ═════════════════════════════════════════════════════════════════════════════
-- formatting
-- ═════════════════════════════════════════════════════════════════════════════

-- | Format a file with the default (no-import) environment.
formatFile :: FilePath -> IO (Either Text Text)
formatFile = formatFileWithEnv builtinEnv

-- | Format a file using a pre-built TypeEnv (e.g. from cross-module inference).
-- n.b. D2 from review-2: previously the `infer` command threw away any
-- cross-module knowledge by calling 'inferExpr' with the empty env.
formatFileWithEnv :: TypeEnv -> FilePath -> IO (Either Text Text)
formatFileWithEnv env path = do
    readResult <- Safety.safeReadFile path
    case readResult of
        Left e -> pure $ Left (Safety.renderSafetyError e)
        Right src -> do
            parseResult <- parseNixFile path
            case parseResult of
                Left err -> pure (Left err)
                Right expr -> pure (formatExprWithEnv env src expr)

formatExpr :: Text -> Either Text Text
formatExpr src = case parseNix "<input>" src of
    Left err -> Left err
    Right expr -> formatExprWithEnv builtinEnv src expr

formatExprWithEnv :: TypeEnv -> Text -> NExprLoc -> Either Text Text
formatExprWithEnv env src expr =
    case Safety.analyzeDepth expr of
        Left de -> Left (Safety.renderSafetyError (Safety.SafetyDepthExceeded de))
        Right () -> case inferExprWithEnv env expr of
            Left err -> Left err
            Right (_, bindings) ->
                let res = InferResult bindings []
                 in Right $ annotateSource src res
