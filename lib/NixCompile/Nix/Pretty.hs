{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // nix // pretty
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "It was such an easy thing, death."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // pretty // printing
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Pretty (
    annotateSource,
)
where

import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import NixCompile.Nix.Infer (Binding (..), InferResult (..))
import NixCompile.Nix.Types (prettyType)
import NixCompile.Types (Loc (..), Span (..))

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
