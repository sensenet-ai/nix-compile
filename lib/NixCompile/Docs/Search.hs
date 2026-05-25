{-# LANGUAGE OverloadedStrings #-}

module NixCompile.Docs.Search
  ( search,
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import NixCompile.Docs.Types

-- | Simple localized search
search :: Text -> [DocItem] -> [DocItem]
search query items = filter (matches (T.toLower query)) items

matches :: Text -> DocItem -> Bool
matches q item =
  q `T.isInfixOf` T.toLower (docName item)
    || q `T.isInfixOf` T.toLower (docDescription item)
