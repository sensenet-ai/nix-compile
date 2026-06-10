{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                                   // nix // infer
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Machine dreams hold a special vertigo."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The @infer@ command: run the inference engine ('NixCompile.Inference.Nix')
--   over a source file and render it with inline @# :: <type>@ annotations.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Inference.Nix.Annotate (
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
import NixCompile.Core.Safety qualified as Safety
import NixCompile.Core.Span (Loc (..), Span (..))
import NixCompile.Inference.Nix (
  Binding (..),
  InferResult (..),
  TypeEnv,
  builtinEnv,
  inferExprWithEnv,
 )
import NixCompile.Inference.Nix.Type (prettyType)
import NixCompile.Syntax.Parse (parseNix, parseNixFile)

-- | Annotate a file with inferred types using the default (no-import) env.
annotateFile :: FilePath -> IO (Either Text Text)
annotateFile = annotateFileWithEnv builtinEnv

{- | Annotate a file using a pre-built TypeEnv (e.g. from cross-module inference).
n.b. D2 from review-2: the @infer@ command must not throw away cross-module
knowledge by inferring with the empty env.
-}
annotateFileWithEnv :: TypeEnv -> FilePath -> IO (Either Text Text)
annotateFileWithEnv env path = do
  readResult <- Safety.safeReadFile path
  either (pure . Left . Safety.renderSafetyError) fromSrc readResult
 where
  fromSrc src = do
    parseResult <- parseNixFile path
    pure $ either Left (annotateExprWithEnv env src) parseResult

-- | parse and annotate an in-memory expression source string with the default env.
annotateExpr :: Text -> Either Text Text
annotateExpr src = either Left (annotateExprWithEnv builtinEnv src) (parseNix "<input>" src)

annotateExprWithEnv :: TypeEnv -> Text -> NExprLoc -> Either Text Text
annotateExprWithEnv env src expr =
  either onDepth (const inferred) (Safety.analyzeDepth expr)
 where
  onDepth de = Left (Safety.renderSafetyError (Safety.SafetyDepthExceeded de))
  inferred = either Left fromBindings (inferExprWithEnv env expr)
  fromBindings (_, bindings) = Right $ annotateSource src (InferResult bindings [])

{- | inject @# :: \<type\>@ comment lines into source text from an inference result,
applying annotations bottom-up so earlier line offsets stay valid.
-}
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
