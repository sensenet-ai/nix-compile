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
    formatExpr,
)
where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nix.Expr.Types.Annotated (NExprLoc)
import Nix.Parser (parseNixFileLoc, parseNixTextLoc)
import Nix.Utils qualified as Nix
import NixCompile.Nix.Infer (InferResult (..), inferExpr)
import NixCompile.Nix.Pretty (annotateSource)

-- ═════════════════════════════════════════════════════════════════════════════
-- formatting
-- ═════════════════════════════════════════════════════════════════════════════

formatFile :: FilePath -> IO (Either Text Text)
formatFile path = do
    readResult <- try (TIO.readFile path)
    case readResult of
        Left (e :: IOException) -> return $ Left $ T.pack $ show e
        Right src -> formatFile' path src

formatFile' :: FilePath -> Text -> IO (Either Text Text)
formatFile' path src = do
    result <- try (parseNixFileLoc (Nix.Path path))
    case result of
        Left (e :: IOException) -> pure $ Left (T.pack $ show e)
        Right (Right expr) -> pure $ formatExpr' src expr
        Right (Left doc) -> pure $ Left (T.pack $ show doc)

formatExpr :: Text -> Either Text Text
formatExpr src = case parseNixTextLoc src of
    Left doc -> Left (T.pack $ show doc)
    Right expr -> formatExpr' src expr

formatExpr' :: Text -> NExprLoc -> Either Text Text
formatExpr' src expr =
    case inferExpr expr of
        Left err -> Left err
        Right (_, bindings) ->
            let res = InferResult bindings []
             in Right $ annotateSource src res
