{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // nix // compile // pretty
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "The box was a universe, a poem, frozen on the boundaries of human
--    experience."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // output // rendering
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Pretty (
  -- * Re-exports
  module Prettyprinter,
  module Prettyprinter.Render.Terminal,

  -- * Standard Styles
  styleType,
  styleVar,
  styleKeyword,
  styleString,
  stylePath,
  styleError,
  styleWarning,
  styleInfo,
  styleSuccess,
  styleMuted,

  -- * Helpers
  renderStdOut,
  renderStdErr,
  toText,

  -- * Layout Helpers
  block,
  property,
)
where

import System.IO (stderr, stdout)

import Data.Text (Text)
import Prettyprinter
import Prettyprinter.Render.Terminal

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Styles
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

styleType :: Doc AnsiStyle -> Doc AnsiStyle
styleType = annotate (color Cyan)

styleVar :: Doc AnsiStyle -> Doc AnsiStyle
styleVar = annotate (color Blue)

styleKeyword :: Doc AnsiStyle -> Doc AnsiStyle
styleKeyword = annotate (color Magenta <> bold)

styleString :: Doc AnsiStyle -> Doc AnsiStyle
styleString = annotate (color Green)

stylePath :: Doc AnsiStyle -> Doc AnsiStyle
stylePath = annotate (color Yellow)

styleError :: Doc AnsiStyle -> Doc AnsiStyle
styleError = annotate (color Red <> bold)

styleWarning :: Doc AnsiStyle -> Doc AnsiStyle
styleWarning = annotate (color Yellow <> bold)

styleInfo :: Doc AnsiStyle -> Doc AnsiStyle
styleInfo = annotate (color Blue <> bold)

styleSuccess :: Doc AnsiStyle -> Doc AnsiStyle
styleSuccess = annotate (color Green <> bold)

styleMuted :: Doc AnsiStyle -> Doc AnsiStyle
styleMuted = annotate (color Black <> bold)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Helpers
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

renderStdOut :: Doc AnsiStyle -> IO ()
renderStdOut = renderIO stdout . layoutSmart defaultLayoutOptions

renderStdErr :: Doc AnsiStyle -> IO ()
renderStdErr = renderIO stderr . layoutSmart defaultLayoutOptions . annotate (color Red)

toText :: Doc AnsiStyle -> Text
toText = renderStrict . layoutSmart defaultLayoutOptions

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Layout Helpers
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

block :: Doc AnsiStyle -> Doc AnsiStyle -> Doc AnsiStyle
block header body =
  vsep
    [ header <+> lbrace
    , indent 2 body
    , rbrace
    ]

property :: Doc AnsiStyle -> Doc AnsiStyle -> Doc AnsiStyle
property key value = key <+> equals <+> value <> semi
