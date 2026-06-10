-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                 // NixCompile.Docs.Types // types
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He raised himself on one elbow to look at her."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                             // Docs // shared documentation types
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module NixCompile.Docs.Types (
  DocItem (..),
  DocKind (..),
)
where

import Data.Text (Text)
import GHC.Generics (Generic)

import Data.Aeson (ToJSON (..), object, (.=))

import NixCompile.Core.Span (Span)

data DocItem = DocItem
  { docName :: Text
  , docDescription :: Text
  , docType :: Maybe Text
  , docSpan :: Span
  , docKind :: DocKind
  }
  deriving (Eq, Show, Generic)

instance ToJSON DocItem where
  toJSON d =
    object
      [ "name" .= docName d
      , "description" .= docDescription d
      , "type" .= docType d
      , "span" .= docSpan d
      , "kind" .= docKind d
      ]

data DocKind = Function | Variable | Option | Attribute
  deriving (Eq, Show, Generic)

instance ToJSON DocKind where
  toJSON = toJSON . show
