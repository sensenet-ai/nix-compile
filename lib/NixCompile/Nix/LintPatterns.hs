{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : NixCompile.Nix.LintPatterns
-- Description : Pattern-based lint rules (or-null-fallback, translateAttrs)
--
-- Detects:
--   - @x.y or null@ implicit fallback patterns (ALEPH-N003)
--   - @translateAttrs@ / @mapAttrsToList@ calls (ALEPH-N004)
module NixCompile.Nix.LintPatterns
  ( -- * Violations
    PatternViolationType (..),
    PatternViolation (..),

    -- * Detection
    findPatternViolations,

    -- * Formatting
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
  { pvType :: !PatternViolationType,
    pvSpan :: !Span,
    pvContext :: !Text
  }
  deriving (Eq, Show)

findPatternViolations :: NExprLoc -> [PatternViolation]
findPatternViolations = go
  where
    go (Fix (Compose (AnnUnit srcSpan e))) =
      localViolations srcSpan e ++ concatMap go (subExprs e)

    localViolations sp (NSelect (Just def) base path)
      | isNullExpr def =
          [ PatternViolation
              { pvType = VOrNullFallback,
                pvSpan = srcSpanToSpan sp,
                pvContext = fmtSelect base path
              }
          ]
    localViolations sp (NApp fun _)
      | isTranslateCall fun =
          [ PatternViolation
              { pvType = VAttrTranslation,
                pvSpan = srcSpanToSpan sp,
                pvContext = fmtCall fun
              }
          ]
    localViolations _ _ = []

    isNullExpr (Fix (Compose (AnnUnit _ (NConstant NNull)))) = True
    isNullExpr (Fix (Compose (AnnUnit _ (NSym name)))) = varNameText name == "null"
    isNullExpr _ = False

    isTranslateCall (Fix (Compose (AnnUnit _ (NSym name)))) =
      varNameText name `elem` transFuncs
    isTranslateCall (Fix (Compose (AnnUnit _ (NSelect _ _ path))))
      | let leaf = NE.last path =
          case leaf of
            StaticKey k -> varNameText k `elem` transFuncs
            DynamicKey _ -> False
    isTranslateCall _ = False

    transFuncs :: [Text]
    transFuncs = ["translateAttrs", "mapAttrsToList", "mapAttrsFlatten"]

    fmtSelect base path =
      prettyShort base <> "." <> attrPathText (toList path) <> " or null"

    attrPathText [StaticKey k] = varNameText k
    attrPathText (StaticKey k : ks) = varNameText k <> "." <> attrPathText ks
    attrPathText (_ : ks) = "‥." <> attrPathText ks
    attrPathText [] = ""

    fmtCall (Fix (Compose (AnnUnit _ (NSym name)))) = varNameText name <> " call"
    fmtCall (Fix (Compose (AnnUnit _ (NSelect _ _ path))))
      | let leaf = NE.last path =
          case leaf of
            StaticKey k -> varNameText k <> " call"
            DynamicKey _ -> "translateAttrs call"
    fmtCall _ = "translateAttrs call"

    prettyShort (Fix (Compose (AnnUnit _ (NSym name)))) = varNameText name
    prettyShort (Fix (Compose (AnnUnit _ (NSelect _ b path)))) =
      case lastStaticKey path of
        Just k -> prettyShort b <> "." <> k
        Nothing -> "‥"
    prettyShort _ = "‥"

    lastStaticKey path =
      case NE.last path of
        StaticKey k -> Just (varNameText k)
        DynamicKey _ -> Nothing

    subExprs = \case
      NConstant _ -> []
      NStr _ -> []
      NList xs -> xs
      NSet _ bindings -> concatMap bindingExprs bindings
      NLet bindings body -> body : concatMap bindingExprs bindings
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

    bindingExprs = \case
      NamedVar _ expr _ -> [expr]
      Inherit (Just scope) _ _ -> [scope]
      Inherit Nothing _ _ -> []

formatPatternViolations :: [PatternViolation] -> Text
formatPatternViolations = T.unlines . map formatOne
  where
    formatOne v =
      T.unlines
        [ formatLoc (pvSpan v) <> ": " <> errorCode (pvType v),
          "  " <> pvContext v,
          "",
          note (pvType v)
        ]

    formatLoc span' =
      let line = T.pack (show (locLine (spanStart span')))
          col = T.pack (show (locCol (spanStart span')))
       in case spanFile span' of
            Just f -> T.pack f <> ":" <> line <> ":" <> col
            Nothing -> line <> ":" <> col

    errorCode VOrNullFallback = "ALEPH-N009: `or null` fallback"
    errorCode VAttrTranslation = "ALEPH-N010: attribute translation call"

    note VOrNullFallback =
      T.unlines
        [ "  Implicit `or null` fallbacks silently swallow attribute errors.",
          "  This can mask real bugs when expected fields are missing.",
          "",
          "  Instead, use the attribute dot operator @. to surface",
          "  type-checkable errors, or use explicit null checks.",
          "",
          "  Before:  x.y or null",
          "  After:   if x ? y then x.y else null"
        ]
    note VAttrTranslation =
      T.unlines
        [ "  Attribute translation functions should only be used in prelude files.",
          "  translateAttrs/mapAttrsToList circumvents the type system and",
          "  should be centralized in the designated prelude directory.",
          "",
          "  Move translation logic to lib/prelude/ or use",
          "  known attribute sets instead."
        ]
