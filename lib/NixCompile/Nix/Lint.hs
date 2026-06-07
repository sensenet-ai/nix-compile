-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // NixCompile.Nix.Lint // lint
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "It was such an easy thing, death. He saw that now: It just happened."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                             // Nix // banned construct detection
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module NixCompile.Nix.Lint (
    NixViolation (..),
    ViolationType (..),
    findNixViolations,
    formatNixViolations,
    nixViolationDiagnostic,
)
where

import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Katip (Severity (ErrorS))
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import Nix.Utils (Path (..))
import NixCompile.Diagnostic (Diagnostic (..))
import NixCompile.Types (Loc (..), Span (..))

-- | A lint violation as a unified 'Diagnostic': the rule code, a one-line
-- summary, the span, and the suggestion line as @= help:@. The verbose
-- explanation from 'formatNixNote' is condensed to its final (suggestion) line.
nixViolationDiagnostic :: NixViolation -> Diagnostic
nixViolationDiagnostic v =
    Diagnostic
        { diagSeverity = ErrorS
        , diagCode = if T.null code then Nothing else Just code
        , diagSpan = Just (nvSpan v)
        , diagSummary = desc
        , diagHelp = lastLine (formatNixNote (nvType v))
        , diagSnippet = Nothing
        }
  where
    (code, desc) = case T.breakOn ": " (formatNixErrorCode (nvType v)) of
        (c, r) | not (T.null r) -> (c, T.drop 2 r)
        _ -> ("", formatNixErrorCode (nvType v))
    lastLine note = case reverse (filter (not . T.null) (map T.strip (T.lines note))) of
        (l : _) -> [l]
        [] -> []

data ViolationType
    = VWith
    | VRec
    | VSubstituteAll
    | VRawMkDerivation
    | VRawRunCommand
    | VRawWriteShellApplication
    | VWriteShellScript
    | VLongInlineString !Int
    deriving (Eq, Show)

data NixViolation = NixViolation
    { nvType :: !ViolationType
    , nvSpan :: !Span
    , nvContext :: !Text
    }
    deriving (Eq, Show)

maxInlineStringLength :: Int
maxInlineStringLength = 120

-- ── entry point ────────────────────────────────────────────────────

findNixViolations :: NExprLoc -> [NixViolation]
findNixViolations = traverseNixExpr

-- ── tree walk ──────────────────────────────────────────────────────
-- The recursive descent spine. Each node emits its local violations,
-- then recurses into all sub-expressions (and bindings where present).
-- n.b. the : vs ++ ordering matters for diagnostic stability — local
-- violations appear first so the user sees the direct problem before
-- any cascading sub-expression issues.

traverseNixExpr :: NExprLoc -> [NixViolation]
traverseNixExpr (Fix (Compose (AnnUnit srcSpan expression))) = case expression of
    NWith scope body ->
        nixViolation VWith srcSpan ("with " <> prettyExpr scope <> ";")
            : traverseNixExpr scope
            ++ traverseNixExpr body
    NSet Recursive bindings ->
        nixViolation VRec srcSpan "rec { ... }"
            : concatMap traverseNixBinding bindings
    NApp function argument ->
        checkBannedAppCall srcSpan function ++ traverseNixExpr function ++ traverseNixExpr argument
    NStr (DoubleQuoted parts) ->
        checkInlineStringLength srcSpan parts ++ concatMap nixPartExprs parts
    NStr (Indented _ parts) ->
        concatMap nixPartExprs parts
    NSet NonRecursive bindings -> concatMap traverseNixBinding bindings
    NList xs -> concatMap traverseNixExpr xs
    NLet bindings body -> concatMap traverseNixBinding bindings ++ traverseNixExpr body
    NIf c t f -> traverseNixExpr c ++ traverseNixExpr t ++ traverseNixExpr f
    NAssert c b -> traverseNixExpr c ++ traverseNixExpr b
    NAbs _ b -> traverseNixExpr b
    NSelect alt b _ -> traverseNixExpr b ++ maybe [] traverseNixExpr alt
    NHasAttr b _ -> traverseNixExpr b
    NUnary _ x -> traverseNixExpr x
    NBinary _ x y -> traverseNixExpr x ++ traverseNixExpr y
    _ -> []

-- ── binding traversal ──────────────────────────────────────────────
-- Extract sub-expressions from both named var bindings and inherit
-- clauses. Inherit without a scope is a no-op (just pulls from scope).

traverseNixBinding :: Binding NExprLoc -> [NixViolation]
traverseNixBinding = \case
    NamedVar _ expr _ -> traverseNixExpr expr
    Inherit (Just scope) _ _ -> traverseNixExpr scope
    Inherit Nothing _ _ -> []

-- ── banned function calls ──────────────────────────────────────────
-- Detect calls to functions that are banned at the project level.
-- These each have a distinct ViolationType so the formatter can emit
-- specific remediation guidance.

checkBannedAppCall :: SrcSpan -> NExprLoc -> [NixViolation]
checkBannedAppCall srcSpan f = case leafSym f of
    Just name
        | name == "substituteAll" ->
            [nixViolation VSubstituteAll srcSpan "substituteAll ..."]
        | name == "mkDerivation" ->
            [nixViolation VRawMkDerivation srcSpan "mkDerivation { ... }"]
        | name == "runCommand" ->
            [nixViolation VRawRunCommand srcSpan "runCommand ..."]
        | name == "writeShellApplication" ->
            [nixViolation VRawWriteShellApplication srcSpan "writeShellApplication { ... }"]
        | name == "writeShellScript" || name == "writeShellScriptBin" ->
            [nixViolation VWriteShellScript srcSpan (name <> " ...")]
        | otherwise -> []
    Nothing -> []

-- ── inline string length ───────────────────────────────────────────
-- Long inline strings clutter source files and should be extracted to
-- separate files. The threshold is defined by `maxInlineStringLength`.

checkInlineStringLength :: SrcSpan -> [Antiquoted Text NExprLoc] -> [NixViolation]
checkInlineStringLength srcSpan parts
    | stringLength > maxInlineStringLength =
        [ nixViolation
            (VLongInlineString stringLength)
            srcSpan
            ("inline string of length " <> T.pack (show stringLength))
        ]
    | otherwise = []
  where
    stringLength = sum (map nixPartLength parts)

-- ── leaf-symbol extraction ─────────────────────────────────────────
-- Resolve an expression to its "leaf name" — either a bare symbol or
-- the final segment of a select chain (e.g., `lib.mkDerivation` -> mkDerivation).
-- !? this doesn't handle `with`-imported names or recursive attr lookups

leafSym :: NExprLoc -> Maybe Text
leafSym (Fix (Compose (AnnUnit _ expr))) = case expr of
    NSym name -> Just (coerce name)
    NSelect _ _base (StaticKey key :| _) -> Just (coerce key)
    _ -> Nothing

-- ── string part helpers ────────────────────────────────────────────

nixPartLength :: Antiquoted Text NExprLoc -> Int
nixPartLength (Plain text) = T.length text
nixPartLength _ = 0

nixPartExprs :: Antiquoted Text NExprLoc -> [NixViolation]
nixPartExprs (Antiquoted expr) = traverseNixExpr expr
nixPartExprs _ = []

-- ── span conversion ────────────────────────────────────────────────
-- hnix's SrcSpan uses NSourcePos with megaparsec's Pos type. We
-- unwrap to our own Span type which strips out megaparsec details.

toSpan :: SrcSpan -> Span
toSpan srcSpan =
    let begin = getSpanBegin srcSpan
        end = getSpanEnd srcSpan
        fileFromBegin = case begin of
            NSourcePos path _ _ -> Just (coerce path)
     in Span
            { spanStart = Loc (srcPosLine begin) (srcPosCol begin)
            , spanEnd = Loc (srcPosLine end) (srcPosCol end)
            , spanFile = fileFromBegin
            }
  where
    srcPosLine (NSourcePos _ (NPos l) _) = fromIntegral (unPos l)
    srcPosCol (NSourcePos _ _ (NPos c)) = fromIntegral (unPos c)

-- ── pretty-printing for context ────────────────────────────────────
-- Produces a short, human-readable summary of a sub-expression for
-- embedding in violation context messages. Not intended to be valid
-- Nix — just enough for a developer to locate the problem.

prettyExpr :: NExprLoc -> Text
prettyExpr (Fix (Compose (AnnUnit _ expr))) = case expr of
    NSym name -> coerce name
    NSelect _ base _ -> prettyExpr base <> ".‥"
    _ -> "‥"

-- ── violation construction ─────────────────────────────────────────

nixViolation :: ViolationType -> SrcSpan -> Text -> NixViolation
nixViolation typ srcSpan ctx =
    NixViolation
        { nvType = typ
        , nvSpan = toSpan srcSpan
        , nvContext = ctx
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                           // output formatting
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

formatNixViolations :: [NixViolation] -> Text
formatNixViolations = T.unlines . map formatOneNixViolation

formatOneNixViolation :: NixViolation -> Text
formatOneNixViolation v =
    T.unlines
        [ formatNixLoc (nvSpan v) <> ": " <> formatNixErrorCode (nvType v)
        , "  " <> nvContext v
        , ""
        , formatNixNote (nvType v)
        ]

formatNixLoc :: Span -> Text
formatNixLoc span' =
    let line = T.pack (show (locLine (spanStart span')))
        col = T.pack (show (locCol (spanStart span')))
     in case spanFile span' of
            Just f -> T.pack f <> ":" <> line <> ":" <> col
            Nothing -> line <> ":" <> col

-- ── error codes ────────────────────────────────────────────────────
-- Each violation type maps to an ALEPH-Nxxx code that is stable across
-- releases. Used by CI to suppress known issues and by editors to
-- provide quickfix links.

formatNixErrorCode :: ViolationType -> Text
formatNixErrorCode VWith = "ALEPH-N001: `with` expression"
formatNixErrorCode VRec = "ALEPH-N002: `rec` attrset"
formatNixErrorCode VSubstituteAll = "ALEPH-N005: `substituteAll`"
formatNixErrorCode VRawMkDerivation = "ALEPH-N006: raw `mkDerivation`"
formatNixErrorCode VRawRunCommand = "ALEPH-N007: raw `runCommand`"
formatNixErrorCode VRawWriteShellApplication = "ALEPH-N008: raw `writeShellApplication`"
formatNixErrorCode VWriteShellScript = "ALEPH-N011: `writeShellScript`"
formatNixErrorCode (VLongInlineString n) = "ALEPH-N012: long inline string (" <> T.pack (show n) <> " chars)"

-- ── remediation notes ──────────────────────────────────────────────
-- These are the full-text explanations shown to the user after the
-- one-line error header. Each note explains why the construct is
-- banned and what to use instead.

formatNixNote :: ViolationType -> Text
formatNixNote VWith =
    T.unlines
        [ "  `with` is banned because it:"
        , "    - Obscures where names come from"
        , "    - Breaks tooling (go-to-definition, autocomplete)"
        , "    - Creates shadowing hazards"
        , "    - Makes type inference unsound"
        , ""
        , "  Use `inherit (expr) name1 name2;` instead."
        ]
formatNixNote VRec =
    T.unlines
        [ "  `rec` is banned because it:"
        , "    - Enables infinite loops (non-termination)"
        , "    - Complicates static analysis"
        , "    - Makes evaluation order-dependent"
        , "    - Breaks referential transparency"
        , ""
        , "  Use `let` bindings or explicit function arguments instead."
        ]
formatNixNote VSubstituteAll =
    T.unlines
        [ "  `substituteAll` is banned because it:"
        , "    - Copies all derivation dependencies into the store"
        , "    - Is needlessly expensive for single-variable substitution"
        , "    - Should be replaced with the simpler `substitute` approach"
        , ""
        , "  Use `substituteInPlace` or `substitute` with explicit values instead."
        ]
formatNixNote VRawMkDerivation =
    T.unlines
        [ "  Raw `mkDerivation` is banned because it:"
        , "    - Bypasses language-specific wrappers"
        , "    - Misses important build phases and hooks"
        , ""
        , "  Use a language-specific wrapper (stdenv.mkDerivation, buildPythonPackage, etc.)."
        ]
formatNixNote VRawRunCommand =
    T.unlines
        [ "  Raw `runCommand` is banned because it:"
        , "    - Creates derivations without proper package metadata"
        , "    - Bypasses build system conventions"
        , ""
        , "  Use `runCommandWith` or a proper derivation wrapper instead."
        ]
formatNixNote VRawWriteShellApplication =
    T.unlines
        [ "  Raw `writeShellApplication` is banned because it:"
        , "    - Should be declared via the module system"
        , "    - Bypasses shell script linting and type checking"
        , ""
        , "  Use `aleph.shell.writeShellApplication` or the nix-compile wrapper instead."
        ]
formatNixNote VWriteShellScript =
    T.unlines
        [ "  `writeShellScript` is banned because it:"
        , "    - Lacks runtime metadata (name, runtime inputs, description)"
        , "    - Bypasses the module system for shell applications"
        , ""
        , "  Use `writeShellApplication` which requires explicit metadata."
        ]
formatNixNote (VLongInlineString n) =
    T.unlines
        [ "  Inline strings longer than " <> T.pack (show maxInlineStringLength) <> " characters are banned"
        , "    because they:"
        , "    - Clutter source files"
        , "    - Are hard to review and maintain"
        , "    - Should be extracted to separate files"
        , ""
        , "  Current string length: " <> T.pack (show n) <> " characters."
        , ""
        , "  Use a file reference (e.g., `builtins.readFile ./data.txt`) instead."
        ]
