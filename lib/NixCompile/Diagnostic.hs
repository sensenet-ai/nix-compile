{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // nix // diagnostic
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   One diagnostic model for every checker (nix lint, bash lint, type, layout,
--   package, parse) and one pure renderer. See doc/design/output-rework.md.
--
--   The renderer is deliberately a pure 'Diagnostic -> Text' so the visual style
--   (currently rustc/clippy carets-and-gutter) is cheap to change and easy to
--   golden-test. Colour and stream routing live in the katip layer, not here.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Diagnostic (
    Diagnostic (..),
    Snippet (..),
    severityWord,
    renderDiagnostic,
)
where

import Data.List (stripPrefix)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Katip (Severity (..))
import NixCompile.Types (Loc (..), Span (..))

-- | A single source line plus the caret range to underline within it.
data Snippet = Snippet
    { snLine :: !Int
    -- ^ 1-based source line number
    , snText :: !Text
    -- ^ the source line (no trailing newline)
    , snCol :: !Int
    -- ^ 1-based column where the underline starts
    , snWidth :: !Int
    -- ^ underline width in columns (rendered as at least one caret)
    }
    deriving (Eq, Show)

{- | A finding from any checker. @diagSpan@ drives the @file:line:col@ location
line; @diagSnippet@ (optional) adds the source line + caret block.
-}
data Diagnostic = Diagnostic
    { diagSeverity :: !Severity
    , diagCode :: !(Maybe Text)
    , diagSpan :: !(Maybe Span)
    , diagSummary :: !Text
    , diagHelp :: ![Text]
    , diagSnippet :: !(Maybe Snippet)
    }
    deriving (Eq, Show)

severityWord :: Severity -> Text
severityWord = \case
    DebugS -> "debug"
    InfoS -> "note"
    WarningS -> "warning"
    ErrorS -> "error"
    _ -> "note"

tshow :: Int -> Text
tshow = T.pack . show

{- | Render a diagnostic in the rustc/clippy idiom. With @color@ on, the severity
tag is bold-coloured, the gutter/arrow/@=@ are blue, and the carets take the
severity colour (selective styling, like rustc — not a single flat colour). With
@color@ off the output is plain (and byte-identical to the golden test), e.g.

@
error[ALEPH-N001]: `with` expression is not allowed
  --> flake.nix:90:7
   |
90 |   with pkgs; [ git ];
   |   ^^^^^^^^^
   = help: use `inherit (pkgs) git;` instead
@
-}
renderDiagnostic :: Bool -> Diagnostic -> Text
renderDiagnostic color d =
    T.intercalate "\n" (header : locLines <> snippetBlock <> helpLines)
  where
    sty :: Text -> Text -> Text
    sty codes t
        | color = "\ESC[" <> codes <> "m" <> t <> "\ESC[0m"
        | otherwise = t
    sevCodes = case diagSeverity d of
        ErrorS -> "1;31" -- bold red
        WarningS -> "1;33" -- bold yellow
        DebugS -> "1;36" -- bold cyan
        _ -> "1;36"
    sev = sty sevCodes
    bold = sty "1"
    blue = sty "1;34" -- gutter / arrow / `=`
    header = sev (severityWord (diagSeverity d) <> codePart) <> bold (": " <> diagSummary d)
    codePart = maybe "" (\c -> "[" <> c <> "]") (diagCode d)

    gutterW = case diagSnippet d of
        Just s -> T.length (tshow (snLine s))
        Nothing -> case diagSpan d of
            Just sp -> T.length (tshow (locLine (spanStart sp)))
            Nothing -> 1
    pad n = T.replicate (max 0 n) " "
    bar = blue (pad gutterW <> " |")

    locLines = case diagSpan d of
        Nothing -> []
        Just sp ->
            [ pad gutterW
                <> blue "--> "
                <> T.pack (stripDot (fromMaybe "<input>" (spanFile sp)))
                <> ":"
                <> tshow (locLine (spanStart sp))
                <> ":"
                <> tshow (locCol (spanStart sp))
            ]
    stripDot p = fromMaybe p (stripPrefix "./" p)

    snippetBlock = case diagSnippet d of
        Nothing -> []
        Just s ->
            [ bar
            , blue (T.justifyRight gutterW ' ' (tshow (snLine s)) <> " |") <> " " <> snText s
            , bar <> " " <> pad (snCol s - 1) <> sev (T.replicate (max 1 (snWidth s)) "^")
            ]

    helpLines = map (\h -> blue (pad gutterW <> " =") <> " " <> bold "help:" <> " " <> h) (diagHelp d)
