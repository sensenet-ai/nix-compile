{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                  // lsp // handlers // diagnostics
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Information sickness. He'd read about it, the price of too much knowing."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The lint → LSP 'Diagnostic' layer: run every checker (nix lint, derivation
--   lint, pattern lint, embedded-bash lint) over a parsed expression and render
--   each finding as an editor diagnostic. Pure (no parsing, no IO) — the
--   handler module owns the parse and hands us the 'NExprLoc'.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.LSP.Handlers.Diagnostics (
  -- * Whole-expression diagnostics
  diagnosticsForExpr,

  -- * Single-finding rendering (used across handlers / tests)
  toNixDiag,
  nixCode,
  spToDiagnostic,

  -- * Re-exported nix-lint vocabulary
  NixViolation (..),
  ViolationType (..),
)
where

import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Protocol.Types
import Nix.Expr.Types.Annotated (NExprLoc)
import NixCompile.Bash.Parse (parseBash)
import NixCompile.Core.Span (Loc (..), Span (..))
import NixCompile.Lint.Derivation qualified as Deriv
import NixCompile.Lint.Forbidden qualified as Forbidden
import NixCompile.Lint.Nix (NixViolation (..), ViolationType (..), findNixViolations)
import NixCompile.Lint.Patterns qualified as Patterns
import NixCompile.Syntax.Parse qualified as NixParse

{- | Every diagnostic for a parsed expression: nix lint + derivation lint +
pattern lint + embedded-bash lint, in one list. @path@ labels derivation
findings (the buffer/file the expression came from).
-}
diagnosticsForExpr :: FilePath -> NExprLoc -> [Diagnostic]
diagnosticsForExpr path expr =
  concat [nixVios' expr, derivVios' path expr, patternVios' expr, embeddedBashDiags expr]

nixVios' :: NExprLoc -> [Diagnostic]
nixVios' expr = map toNixDiag (findNixViolations expr)

derivVios' :: FilePath -> NExprLoc -> [Diagnostic]
derivVios' path expr = map toDerivDiag (Deriv.findDerivViolations path expr)

toDerivDiag :: Deriv.DerivViolation -> Diagnostic
toDerivDiag dv =
  spToDiagnostic
    (Deriv.derivRuleId (Deriv.dvType dv) <> ": " <> derivMsg (Deriv.dvType dv))
    (Deriv.dvSpan dv)
 where
  derivMsg Deriv.VMissingMeta = "mkDerivation call without meta attribute"
  derivMsg Deriv.VMissingDescription = "meta = { ... } without description key"

patternVios' :: NExprLoc -> [Diagnostic]
patternVios' expr = map toPatternDiag (Patterns.findPatternViolations expr)

toPatternDiag :: Patterns.PatternViolation -> Diagnostic
toPatternDiag pv =
  spToDiagnostic
    (patternRuleId (Patterns.pvType pv) <> ": " <> Patterns.pvContext pv)
    (Patterns.pvSpan pv)
 where
  patternRuleId Patterns.VOrNullFallback = "or-null-fallback"
  patternRuleId Patterns.VAttrTranslation = "no-translate-attrs-outside-prelude"

embeddedBashDiags :: NExprLoc -> [Diagnostic]
embeddedBashDiags expr = concatMap bashDiagFromCall (NixParse.findShellScriptCalls expr)

bashDiagFromCall :: NixParse.ShellScriptCall -> [Diagnostic]
bashDiagFromCall ssc = maybe [] withContent (NixParse.extractString (NixParse.sscBody ssc))
 where
  withContent (content, _, _) = either (const []) withAst (parseBash content)
  withAst ast = map (toBashDiag (NixParse.sscName ssc)) (Forbidden.findViolations ast)

toBashDiag :: Text -> Forbidden.Violation -> Diagnostic
toBashDiag scriptName v =
  spToDiagnostic
    ( bashErrorCode (Forbidden.vType v)
        <> ": "
        <> bashLabel (Forbidden.vType v)
        <> " in embedded script '"
        <> scriptName
        <> "'"
    )
    (Forbidden.vSpan v)
 where
  bashLabel Forbidden.VHeredoc = "heredoc (<<) not allowed"
  bashLabel Forbidden.VHereString = "here-string (<<<) not allowed"
  bashLabel Forbidden.VEval = "eval not allowed"
  bashLabel Forbidden.VBacktick = "backticks (`...`) not allowed"

bashErrorCode :: Forbidden.ViolationType -> Text
bashErrorCode Forbidden.VHeredoc = "ALEPH-B001"
bashErrorCode Forbidden.VHereString = "ALEPH-B002"
bashErrorCode Forbidden.VEval = "ALEPH-B003"
bashErrorCode Forbidden.VBacktick = "ALEPH-B004"

toNixDiag :: NixViolation -> Diagnostic
toNixDiag NixViolation{nvType = vt, nvSpan = sp, nvContext = ctx} =
  spToDiagnostic (nixCode vt <> ": " <> ctx) sp

nixCode :: ViolationType -> Text
nixCode VWith = "ALEPH-N001"
nixCode VRec = "ALEPH-N002"
nixCode VSubstituteAll = "ALEPH-N005"
nixCode VRawMkDerivation = "ALEPH-N006"
nixCode VRawRunCommand = "ALEPH-N007"
nixCode VRawWriteShellApplication = "ALEPH-N008"
nixCode VWriteShellScript = "ALEPH-N011"
nixCode (VLongInlineString n) = "ALEPH-N012 (" <> T.pack (show n) <> " chars)"

spToDiagnostic :: Text -> Span -> Diagnostic
spToDiagnostic msg (Span (Loc line col) (Loc endL endC) _) =
  -- n.b. ShellCheck positions are 0-based; megaparsec positions are 1-based.
  -- Clamp to zero rather than wrap unsigned underflow (B4 from review-2).
  Diagnostic
    { _range =
        Range
          (Position (clampU32 (line - 1)) (clampU32 (col - 1)))
          (Position (clampU32 (endL - 1)) (clampU32 (endC - 1)))
    , _severity = Just DiagnosticSeverity_Error
    , _code = Nothing
    , _codeDescription = Nothing
    , _source = Just "nix-compile"
    , _message = msg
    , _tags = Nothing
    , _relatedInformation = Nothing
    , _data_ = Nothing
    }
 where
  clampU32 :: Int -> UInt
  clampU32 n
    | n < 0 = 0
    | otherwise = fromIntegral n
