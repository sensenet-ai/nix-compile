{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                    // NixCompile.Nix.LintDerivation // lint
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He was good as new. How good was that?"
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                          // Nix // derivation quality lint rules
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.LintDerivation (
    DerivViolationType (..),
    DerivViolation (..),
    findDerivViolations,
    formatDerivViolations,
    derivViolationDiagnostic,
    derivRuleId,
)
where

import Data.Fix (Fix (..))
import Data.Functor.Compose (Compose (..))
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Katip (Severity (WarningS))
import Nix.Expr.Types
import Nix.Expr.Types.Annotated (AnnUnit (..), NExprLoc, SrcSpan)
import NixCompile.Diagnostic (Diagnostic (..))
import NixCompile.Nix.Utils (srcSpanToSpan, varNameText)
import NixCompile.Types (Loc (..), Span (..))

-- | Derivation-quality violation as a unified 'Diagnostic' (a warning).
derivViolationDiagnostic :: DerivViolation -> Diagnostic
derivViolationDiagnostic dv =
    Diagnostic
        { diagSeverity = WarningS
        , diagCode = if T.null code then Nothing else Just code
        , diagSpan = Just (dvSpan dv)
        , diagSummary = desc
        , diagHelp = lastLine (formatDerivNote (dvType dv))
        , diagSnippet = Nothing
        }
  where
    (code, desc) = case T.breakOn ": " (formatDerivErrorCode (dvType dv)) of
        (c, r) | not (T.null r) -> (c, T.drop 2 r)
        _ -> ("", formatDerivErrorCode (dvType dv))
    lastLine note = case reverse (filter (not . T.null) (map T.strip (T.lines note))) of
        (l : _) -> [l]
        [] -> []

data DerivViolationType
    = VMissingMeta
    | VMissingDescription
    deriving (Eq, Show)

data DerivViolation = DerivViolation
    { dvType :: !DerivViolationType
    , dvPath :: !FilePath
    , dvSpan :: !Span
    }
    deriving (Eq, Show)

-- ── entry point ────────────────────────────────────────────────────

findDerivViolations :: FilePath -> NExprLoc -> [DerivViolation]
findDerivViolations filePath = traverseDerivExpr filePath

-- ── tree walk ──────────────────────────────────────────────────────
-- We need the file path threaded through for diagnostic messages, so
-- it's passed explicitly rather than captured in a closure.

traverseDerivExpr :: FilePath -> NExprLoc -> [DerivViolation]
traverseDerivExpr filePath (Fix (Compose (AnnUnit srcSpan expression))) = case expression of
    NApp func arg ->
        checkDerivCall filePath srcSpan func arg ++ traverseDerivExpr filePath func ++ traverseDerivExpr filePath arg
    NSet _ bindings -> concatMap (traverseDerivBinding filePath) bindings
    NLet bindings body -> concatMap (traverseDerivBinding filePath) bindings ++ traverseDerivExpr filePath body
    NList xs -> concatMap (traverseDerivExpr filePath) xs
    NIf c t f -> traverseDerivExpr filePath c ++ traverseDerivExpr filePath t ++ traverseDerivExpr filePath f
    NAssert c b -> traverseDerivExpr filePath c ++ traverseDerivExpr filePath b
    NAbs _ b -> traverseDerivExpr filePath b
    NWith scope body -> traverseDerivExpr filePath scope ++ traverseDerivExpr filePath body
    NSelect alt b _ -> maybe [] (traverseDerivExpr filePath) alt ++ traverseDerivExpr filePath b
    NHasAttr b _ -> traverseDerivExpr filePath b
    NUnary _ x -> traverseDerivExpr filePath x
    NBinary _ x y -> traverseDerivExpr filePath x ++ traverseDerivExpr filePath y
    _ -> []

traverseDerivBinding :: FilePath -> Binding NExprLoc -> [DerivViolation]
traverseDerivBinding filePath = \case
    NamedVar _ expr _ -> traverseDerivExpr filePath expr
    Inherit (Just scope) _ _ -> traverseDerivExpr filePath scope
    Inherit Nothing _ _ -> []

-- ── mkDerivation inspection ────────────────────────────────────────
-- When we spot an `NApp` whose function is `mkDerivation` (or
-- `stdenv.mkDerivation`, etc.), we inspect the argument for required
-- metadata fields.

checkDerivCall :: FilePath -> SrcSpan -> NExprLoc -> NExprLoc -> [DerivViolation]
checkDerivCall filePath sourceSpan function argument
    | isMkDerivationCall function = checkDerivArg filePath sourceSpan argument
    | otherwise = []

-- ── mkDerivation call detection ────────────────────────────────────
-- Matches both bare `mkDerivation` and qualified `attrset.mkDerivation`.

isMkDerivationCall :: NExprLoc -> Bool
isMkDerivationCall (Fix (Compose (AnnUnit _ (NSym name)))) =
    varNameText name == "mkDerivation"
-- the FINAL key of the path is what's applied, so `a.b.c.mkDerivation` counts —
-- not just a single-key `x.mkDerivation` (REVIEW-3 #26)
isMkDerivationCall (Fix (Compose (AnnUnit _ (NSelect _ _ path)))) =
    case NE.last path of
        StaticKey key -> varNameText key == "mkDerivation"
        _ -> False
isMkDerivationCall _ = False

-- ── argument inspection ────────────────────────────────────────────
-- The argument to `mkDerivation` must be an attrset. If it's a
-- variable reference (NSym), we skip — the attrset might be defined
-- elsewhere and we can't verify statically.

checkDerivArg :: FilePath -> SrcSpan -> NExprLoc -> [DerivViolation]
checkDerivArg filePath sourceSpan (Fix (Compose (AnnUnit _ (NSet _ bindings)))) =
    checkDerivMeta filePath sourceSpan bindings
checkDerivArg _ _ (Fix (Compose (AnnUnit _ (NSym _)))) = []
checkDerivArg _ _ _ = []

-- ── meta-attribute validation ──────────────────────────────────────
-- Two checks in one pass:
--   1. Does the attrset have a `meta` binding at all?
--   2. If meta exists, does it contain a `description` key?
-- The meta value itself is also traversed for nested violations.

checkDerivMeta :: FilePath -> SrcSpan -> [Binding NExprLoc] -> [DerivViolation]
checkDerivMeta filePath sourceSpan bindings = checkFoundMeta
  where
    found = findMetaBinding bindings

    checkFoundMeta
        | Nothing <- found = [missingMetaViolation]
        | Just (NamedVar _ metaValue _) <- found =
            checkDerivDescription filePath metaValue ++ traverseDerivExpr filePath metaValue
        | otherwise = []

    missingMetaViolation =
        DerivViolation
            { dvType = VMissingMeta
            , dvPath = filePath
            , dvSpan = srcSpanToSpan sourceSpan
            }

-- ── description key check ──────────────────────────────────────────
-- If `meta` resolves to an attrset literal, verify it has a
-- `description` key. Dynamic or referenced meta values are skipped
-- (conservative — we only flag what we can prove).

checkDerivDescription :: FilePath -> NExprLoc -> [DerivViolation]
checkDerivDescription filePath metaValue
    | Fix (Compose (AnnUnit metaSpan (NSet _ metaBindings))) <- metaValue
    , not (any isDescriptionBinding metaBindings) =
        [ DerivViolation
            { dvType = VMissingDescription
            , dvPath = filePath
            , dvSpan = srcSpanToSpan metaSpan
            }
        ]
    | otherwise = []

findMetaBinding :: [Binding NExprLoc] -> Maybe (Binding NExprLoc)
findMetaBinding = find $ \case
    NamedVar (StaticKey bindingName :| []) _ _ -> varNameText bindingName == "meta"
    _ -> False

isDescriptionBinding :: Binding NExprLoc -> Bool
isDescriptionBinding (NamedVar (StaticKey bindingName :| []) _ _) = varNameText bindingName == "description"
isDescriptionBinding _ = False

derivRuleId :: DerivViolationType -> Text
derivRuleId = \case
    VMissingMeta -> "missing-meta"
    VMissingDescription -> "missing-description"

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                           // output formatting
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

formatDerivViolations :: [DerivViolation] -> Text
formatDerivViolations = T.unlines . map formatOneDerivViolation

formatOneDerivViolation :: DerivViolation -> Text
formatOneDerivViolation dv =
    T.unlines
        [ formatDerivLoc (dvSpan dv) <> ": " <> formatDerivErrorCode (dvType dv)
        , "  " <> formatDerivContext (dvType dv)
        , ""
        , formatDerivNote (dvType dv)
        ]

formatDerivLoc :: Span -> Text
formatDerivLoc span' =
    let line = T.pack (show (locLine (spanStart span')))
        col = T.pack (show (locCol (spanStart span')))
     in case spanFile span' of
            Just f -> T.pack f <> ":" <> line <> ":" <> col
            Nothing -> line <> ":" <> col

formatDerivErrorCode :: DerivViolationType -> Text
formatDerivErrorCode VMissingMeta = "ALEPH-N013: missing `meta`"
formatDerivErrorCode VMissingDescription = "ALEPH-N014: missing `description` in meta"

formatDerivContext :: DerivViolationType -> Text
formatDerivContext VMissingMeta = "mkDerivation call without meta attribute"
formatDerivContext VMissingDescription = "meta = { ... } without description key"

formatDerivNote :: DerivViolationType -> Text
formatDerivNote VMissingMeta =
    T.unlines
        [ "  Derivations should include a `meta` attribute for package metadata."
        , ""
        , "  Add:  meta = with lib; { ... };"
        ]
formatDerivNote VMissingDescription =
    T.unlines
        [ "  The `meta` attribute should include a `description`."
        , ""
        , "  Add:  meta = with lib; { description = \"...\"; ... };"
        ]
