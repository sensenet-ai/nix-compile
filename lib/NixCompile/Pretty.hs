{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : NixCompile.Pretty
-- Description : Unified pretty printing infrastructure
--
-- This module re-exports commonly used prettyprinter types and defines
-- the standard styling for the application (colors, indentation).
module NixCompile.Pretty
  ( -- * Re-exports
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

import Data.Text (Text)
import Prettyprinter
import Prettyprinter.Render.Terminal
import System.IO (stdout, stderr)

-- ============================================================================
-- Styles
-- ============================================================================

-- | Types (e.g. Int, Path)
styleType :: Doc AnsiStyle -> Doc AnsiStyle
styleType = annotate (color Cyan)

-- | Variables (e.g. port, config)
styleVar :: Doc AnsiStyle -> Doc AnsiStyle
styleVar = annotate (color Blue)

-- | Keywords (e.g. let, in, if)
styleKeyword :: Doc AnsiStyle -> Doc AnsiStyle
styleKeyword = annotate (color Magenta <> bold)

-- | String literals
styleString :: Doc AnsiStyle -> Doc AnsiStyle
styleString = annotate (color Green)

-- | Paths (/nix/store/...)
stylePath :: Doc AnsiStyle -> Doc AnsiStyle
stylePath = annotate (color Yellow)

-- | Errors
styleError :: Doc AnsiStyle -> Doc AnsiStyle
styleError = annotate (color Red <> bold)

-- | Warnings
styleWarning :: Doc AnsiStyle -> Doc AnsiStyle
styleWarning = annotate (color Yellow <> bold)

-- | Info messages
styleInfo :: Doc AnsiStyle -> Doc AnsiStyle
styleInfo = annotate (color Blue <> bold)

-- | Success messages
styleSuccess :: Doc AnsiStyle -> Doc AnsiStyle
styleSuccess = annotate (color Green <> bold)

-- | Muted/Dim text (comments, delimiters)
styleMuted :: Doc AnsiStyle -> Doc AnsiStyle
styleMuted = annotate (color Black <> bold) -- often looks gray on terminals

-- ============================================================================
-- Helpers
-- ============================================================================

-- | Render a document to stdout with ANSI codes
renderStdOut :: Doc AnsiStyle -> IO ()
renderStdOut = renderIO stdout . layoutSmart defaultLayoutOptions

-- | Render a document to stderr with ANSI codes
renderStdErr :: Doc AnsiStyle -> IO ()
renderStdErr = renderIO stderr . layoutSmart defaultLayoutOptions . annotate (color Red)

-- | Render to plain text (stripping ANSI codes)
toText :: Doc AnsiStyle -> Text
toText = renderStrict . layoutSmart defaultLayoutOptions

-- ============================================================================
-- Layout Helpers
-- ============================================================================

-- | A standard indented block
-- header {
--   body
-- }
block :: Doc AnsiStyle -> Doc AnsiStyle -> Doc AnsiStyle
block header body =
  vsep
    [ header <+> lbrace
    , indent 2 body
    , rbrace
    ]

-- | A property key-value pair
-- key = value;
property :: Doc AnsiStyle -> Doc AnsiStyle -> Doc AnsiStyle
property key value = key <+> equals <+> value <> semi
