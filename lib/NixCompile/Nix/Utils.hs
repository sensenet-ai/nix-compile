{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : NixCompile.Nix.Utils
-- Description : Shared utility functions for Nix modules
--
-- Common functions used across NixCompile.Nix.* modules.
-- Consolidates duplicated code.
module NixCompile.Nix.Utils
  ( -- * VarName extraction
    varNameText,
    
    -- * Key extraction
    keyText,
    
    -- * Span conversion
    toSpan,
    srcSpanToSpan,
  )
where

import Data.Coerce (coerce)
import Data.Text (Text)
import Nix.Expr.Types (VarName(..), NKeyName(..), NSourcePos(..), NPos(..))
import Nix.Expr.Types.Annotated (SrcSpan(..))
import Nix.Utils (Path(..))
import NixCompile.Types (Span(..), Loc(..))
import Text.Megaparsec.Pos (unPos)

-- | Extract Text from VarName newtype
varNameText :: VarName -> Text
varNameText = coerce

-- | Extract Text from NKeyName
keyText :: NKeyName r -> Text
keyText (StaticKey k) = varNameText k
keyText (DynamicKey _) = ""

-- | Convert hnix SrcSpan to our Span type
srcSpanToSpan :: SrcSpan -> Span
srcSpanToSpan srcSpan =
  let
    begin = getSpanBegin srcSpan
    end = getSpanEnd srcSpan
    fileFromBegin = case begin of
      NSourcePos path _ _ -> Just (coerce path)
  in
  Span
    { spanStart = Loc (sourceLine begin) (sourceCol begin)
    , spanEnd = Loc (sourceLine end) (sourceCol end)
    , spanFile = fileFromBegin
    }
  where
    getSpanBegin (SrcSpan begin _) = begin
    getSpanEnd (SrcSpan _ end) = end
    sourceLine (NSourcePos _ (NPos l) _) = fromIntegral (unPos l)
    sourceCol (NSourcePos _ _ (NPos c)) = fromIntegral (unPos c)

-- | Alias for srcSpanToSpan with different argument order
toSpan :: SrcSpan -> Maybe FilePath -> Span
toSpan srcSpan mFile =
  let sp = srcSpanToSpan srcSpan
  in case mFile of
       Just f -> sp { spanFile = Just f }
       Nothing -> sp
