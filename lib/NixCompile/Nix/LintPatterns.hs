-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                      // NixCompile.Nix.LintPatterns // lint
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "There was some magic chemistry in that impending darkness, something that
--    let him glimpse the infinite desirability of that room"
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                             // Nix // pattern-based lint rules
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module NixCompile.Nix.LintPatterns (
    PatternViolationType (..),
    PatternViolation (..),
    findPatternViolations,
    formatPatternViolations,
)
where

import Data.Fix (Fix (..))
import Data.List.NonEmpty (toList)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import NixCompile.Nix.Utils (srcSpanToSpan, varNameText)
import NixCompile.Types (Loc (..), Span (..))

data PatternViolationType
    = VOrNullFallback
    | VAttrTranslation
    deriving (Eq, Show)

data PatternViolation = PatternViolation
    { pvType :: !PatternViolationType
    , pvSpan :: !Span
    , pvContext :: !Text
    }
    deriving (Eq, Show)

-- ── entry point ────────────────────────────────────────────────────

findPatternViolations :: NExprLoc -> [PatternViolation]
findPatternViolations = traversePatternExpr

-- ── tree walk ──────────────────────────────────────────────────────
-- Local-prioritized traversal: each node's pattern violations are
-- emitted before sub-expression violations.

traversePatternExpr :: NExprLoc -> [PatternViolation]
traversePatternExpr (Fix (Compose (AnnUnit srcSpan expression))) =
    localPatternViolations srcSpan expression ++ concatMap traversePatternExpr (patternSubExprs expression)

-- ── local node checks ──────────────────────────────────────────────
-- Two pattern rules fire at a single AST node:
--   1. `or null` fallback on attribute selection
--   2. Translation function calls (translateAttrs, mapAttrsToList, etc.)

localPatternViolations :: SrcSpan -> NExprF NExprLoc -> [PatternViolation]
localPatternViolations sourceSpan (NSelect (Just defaultExpr) base path)
    | isNullExpr defaultExpr =
        [ PatternViolation
            { pvType = VOrNullFallback
            , pvSpan = srcSpanToSpan sourceSpan
            , pvContext = fmtSelect base path
            }
        ]
localPatternViolations sourceSpan (NApp function _)
    | isTranslateCall function =
        [ PatternViolation
            { pvType = VAttrTranslation
            , pvSpan = srcSpanToSpan sourceSpan
            , pvContext = fmtCall function
            }
        ]
localPatternViolations _ _ = []

-- ── null-expression detection ──────────────────────────────────────
-- n.b. `NSym "null"` is included because the parser may or may not
-- resolve `null` to `NConstant NNull` depending on context.
-- !? is there a case where the binder shadows `null`? That would be
-- pathological but technically possible.

isNullExpr :: NExprLoc -> Bool
isNullExpr (Fix (Compose (AnnUnit _ (NConstant NNull)))) = True
isNullExpr (Fix (Compose (AnnUnit _ (NSym name)))) = varNameText name == "null"
isNullExpr _ = False

-- ── translation-function detection ─────────────────────────────────
-- Matches bare calls (`translateAttrs ...`) and qualified calls
-- (`lib.translateAttrs ...`). Only the final key is checked.

isTranslateCall :: NExprLoc -> Bool
isTranslateCall (Fix (Compose (AnnUnit _ (NSym name)))) =
    varNameText name `elem` translateFuncNames
isTranslateCall (Fix (Compose (AnnUnit _ (NSelect _ _ path))))
    | let leaf = NE.last path =
        case leaf of
            StaticKey k -> varNameText k `elem` translateFuncNames
            DynamicKey _ -> False
isTranslateCall _ = False

translateFuncNames :: [Text]
translateFuncNames = ["translateAttrs", "mapAttrsToList", "mapAttrsFlatten"]

-- ── formatting helpers ─────────────────────────────────────────────
-- Produce human-readable summaries of the offending expression for
-- embedding in the violation context.

fmtSelect :: NExprLoc -> NE.NonEmpty (NKeyName NExprLoc) -> Text
fmtSelect base path =
    prettyShort base <> "." <> attrPathText (toList path) <> " or null"

attrPathText :: [NKeyName NExprLoc] -> Text
attrPathText [StaticKey k] = varNameText k
attrPathText (StaticKey k : ks) = varNameText k <> "." <> attrPathText ks
attrPathText (_ : ks) = "‥." <> attrPathText ks
attrPathText [] = ""

fmtCall :: NExprLoc -> Text
fmtCall (Fix (Compose (AnnUnit _ (NSym name)))) = varNameText name <> " call"
fmtCall (Fix (Compose (AnnUnit _ (NSelect _ _ path))))
    | let leaf = NE.last path =
        case leaf of
            StaticKey k -> varNameText k <> " call"
            DynamicKey _ -> "translateAttrs call"
fmtCall _ = "translateAttrs call"

prettyShort :: NExprLoc -> Text
prettyShort (Fix (Compose (AnnUnit _ (NSym name)))) = varNameText name
prettyShort (Fix (Compose (AnnUnit _ (NSelect _ b path)))) =
    case lastStaticKey path of
        Just k -> prettyShort b <> "." <> k
        Nothing -> "‥"
prettyShort _ = "‥"

lastStaticKey :: NE.NonEmpty (NKeyName NExprLoc) -> Maybe Text
lastStaticKey path =
    case NE.last path of
        StaticKey k -> Just (varNameText k)
        DynamicKey _ -> Nothing

-- ── sub-expression enumeration ─────────────────────────────────────
-- Maps each NExpr constructor to its list of child expressions that
-- need recursive linting. This is the traversal "shape" — every node
-- type must be listed or it won't be visited.

patternSubExprs :: NExprF NExprLoc -> [NExprLoc]
patternSubExprs = \case
    NConstant _ -> []
    NStr _ -> []
    NList xs -> xs
    NSet _ bindings -> concatMap patternBindingExprs bindings
    NLet bindings body -> body : concatMap patternBindingExprs bindings
    NIf c t f -> [c, t, f]
    NWith s b -> [s, b]
    NAssert c b -> [c, b]
    NAbs _ b -> [b]
    NApp f x -> [f, x]
    NSelect mDef b path ->
        b : maybeToList mDef ++ [e | DynamicKey (Antiquoted e) <- toList path]
    NHasAttr b path ->
        b : [e | DynamicKey (Antiquoted e) <- toList path]
    NUnary _ x -> [x]
    NBinary _ x y -> [x, y]
    NSym _ -> []
    NLiteralPath _ -> []
    NEnvPath _ -> []
    NSynHole _ -> []

patternBindingExprs :: Binding NExprLoc -> [NExprLoc]
patternBindingExprs = \case
    NamedVar _ expr _ -> [expr]
    Inherit (Just scope) _ _ -> [scope]
    Inherit Nothing _ _ -> []

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                           // output formatting
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

formatPatternViolations :: [PatternViolation] -> Text
formatPatternViolations = T.unlines . map formatOnePatternViolation

formatOnePatternViolation :: PatternViolation -> Text
formatOnePatternViolation pv =
    T.unlines
        [ formatPatternLoc (pvSpan pv) <> ": " <> formatPatternErrorCode (pvType pv)
        , "  " <> pvContext pv
        , ""
        , formatPatternNote (pvType pv)
        ]

formatPatternLoc :: Span -> Text
formatPatternLoc span' =
    let line = T.pack (show (locLine (spanStart span')))
        col = T.pack (show (locCol (spanStart span')))
     in case spanFile span' of
            Just f -> T.pack f <> ":" <> line <> ":" <> col
            Nothing -> line <> ":" <> col

formatPatternErrorCode :: PatternViolationType -> Text
formatPatternErrorCode VOrNullFallback = "ALEPH-N009: `or null` fallback"
formatPatternErrorCode VAttrTranslation = "ALEPH-N010: attribute translation call"

formatPatternNote :: PatternViolationType -> Text
formatPatternNote VOrNullFallback =
    T.unlines
        [ "  Implicit `or null` fallbacks silently swallow attribute errors."
        , "  This can mask real bugs when expected fields are missing."
        , ""
        , "  Instead, use the attribute dot operator @. to surface"
        , "  type-checkable errors, or use explicit null checks."
        , ""
        , "  Before:  x.y or null"
        , "  After:   if x ? y then x.y else null"
        ]
formatPatternNote VAttrTranslation =
    T.unlines
        [ "  Attribute translation functions should only be used in prelude files."
        , "  translateAttrs/mapAttrsToList circumvents the type system and"
        , "  should be centralized in the designated prelude directory."
        , ""
        , "  Move translation logic to lib/prelude/ or use"
        , "  known attribute sets instead."
        ]
