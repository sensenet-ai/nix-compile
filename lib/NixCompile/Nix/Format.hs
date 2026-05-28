{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : NixCompile.Nix.Format
Description : Format Nix files with type annotations

Adds type signature comments to Nix functions and bindings.
The goal is to make Nix feel like a typed language.

Example output:

@
# mkService : { port : Int, host : String } -> Derivation
mkService = { port ? 8080, host ? "localhost" }:
  pkgs.writeShellApplication { ... };
@
-}
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

-- ============================================================================
-- Formatting
-- ============================================================================

-- | Format a Nix file with type annotations
formatFile :: FilePath -> IO (Either Text Text)
formatFile path = do
    -- Read original source
    readResult <- try (TIO.readFile path)
    case readResult of
        Left (e :: IOException) -> return $ Left $ T.pack $ show e
        Right src -> formatFile' path src

formatFile' :: FilePath -> Text -> IO (Either Text Text)
formatFile' path src = do
    -- Parse and extract annotations
    result <- try (parseNixFileLoc (Nix.Path path))
    case result of
        Left (e :: IOException) -> pure $ Left (T.pack $ show e)
        Right (Right expr) -> pure $ formatExpr' src expr
        Right (Left doc) -> pure $ Left (T.pack $ show doc)

-- | Format a Nix expression (from text)
formatExpr :: Text -> Either Text Text
formatExpr src = case parseNixTextLoc src of
    Left doc -> Left (T.pack $ show doc)
    Right expr -> formatExpr' src expr

-- | Internal formatter using pre-parsed expression
formatExpr' :: Text -> NExprLoc -> Either Text Text
formatExpr' src expr =
    case inferExpr expr of
        Left err -> Left err
        Right (_, bindings) ->
            let res = InferResult bindings [] -- We don't track top-level functions separately here
             in Right $ annotateSource src res
