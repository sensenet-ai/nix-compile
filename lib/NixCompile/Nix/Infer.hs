{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // nix // infer
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Machine dreams hold a special vertigo."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The @infer@ command: run the inference engine ('NixCompile.Nix.Inference')
--   over a source file and render it with inline @# :: <type>@ annotations.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Infer (
    -- * Type-annotation injection (the @infer@ command)
    annotateFile,
    annotateFileWithEnv,
    annotateExpr,

    -- * Low-level
    annotateSource,
)
where

import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Expr.Types.Annotated (NExprLoc)
import NixCompile.Nix.Inference (Binding (..), InferResult (..), TypeEnv, builtinEnv, inferExprWithEnv)
import NixCompile.Nix.Parse (parseNix, parseNixFile)
import NixCompile.Nix.Types (prettyType)
import NixCompile.Safety qualified as Safety
import NixCompile.Types (Loc (..), Span (..))

-- | Annotate a file with inferred types using the default (no-import) env.
annotateFile :: FilePath -> IO (Either Text Text)
annotateFile = annotateFileWithEnv builtinEnv

-- | Annotate a file using a pre-built TypeEnv (e.g. from cross-module inference).
-- n.b. D2 from review-2: the @infer@ command must not throw away cross-module
-- knowledge by inferring with the empty env.
annotateFileWithEnv :: TypeEnv -> FilePath -> IO (Either Text Text)
annotateFileWithEnv env path = do
    readResult <- Safety.safeReadFile path
    case readResult of
        Left e -> pure $ Left (Safety.renderSafetyError e)
        Right src -> do
            parseResult <- parseNixFile path
            case parseResult of
                Left err -> pure (Left err)
                Right expr -> pure (annotateExprWithEnv env src expr)

annotateExpr :: Text -> Either Text Text
annotateExpr src = case parseNix "<input>" src of
    Left err -> Left err
    Right expr -> annotateExprWithEnv builtinEnv src expr

annotateExprWithEnv :: TypeEnv -> Text -> NExprLoc -> Either Text Text
annotateExprWithEnv env src expr =
    case Safety.analyzeDepth expr of
        Left de -> Left (Safety.renderSafetyError (Safety.SafetyDepthExceeded de))
        Right () -> case inferExprWithEnv env expr of
            Left err -> Left err
            Right (_, bindings) ->
                let res = InferResult bindings []
                 in Right $ annotateSource src res

annotateSource :: Text -> InferResult -> Text
annotateSource src InferResult{..} =
    let
        bindingAnns = map mkBindingAnn irBindings
        anns = sortBy (flip (comparing annLoc)) bindingAnns
     in
        foldl' (flip applyAnn) src anns

data Ann = Ann
    { annLoc :: !Loc
    , annText :: !Text
    }
    deriving (Eq, Show)

mkBindingAnn :: Binding -> Ann
mkBindingAnn Binding{..} =
    Ann
        { annLoc = spanStart bindSpan
        , annText = "# :: " <> prettyType bindType
        }

applyAnn :: Ann -> Text -> Text
applyAnn Ann{..} src =
    let lines_ = T.lines src
        (before, after) = splitAt (locLine annLoc - 1) lines_
        indent = getIndent (headSafe after)
     in T.unlines $ before ++ [indent <> annText] ++ after

getIndent :: Maybe Text -> Text
getIndent Nothing = ""
getIndent (Just t) = T.takeWhile (== ' ') t

headSafe :: [a] -> Maybe a
headSafe [] = Nothing
headSafe (x : _) = Just x
