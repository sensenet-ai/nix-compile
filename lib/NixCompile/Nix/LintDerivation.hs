{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : NixCompile.Nix.LintDerivation
-- Description : Derivation quality lint rules
--
-- Detects derivation expressions missing required metadata:
--   - @missing-meta@: @mkDerivation { ... }@ without a @meta@ attribute
--   - @missing-description@: @meta = { ... }@ without a @description@ key
--
-- These are configurable via the Dhall config under the rule IDs
-- @"missing-meta"@ and @"missing-description"@.
module NixCompile.Nix.LintDerivation
  ( -- * Violations
    DerivViolationType (..),
    DerivViolation (..),

    -- * Detection
    findDerivViolations,

    -- * Formatting
    formatDerivViolations,

    -- * Config
    derivRuleId,
  )
where

import Data.Fix (Fix (..))
import Data.Functor.Compose (Compose (..))
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Expr.Types
import Nix.Expr.Types.Annotated (AnnUnit (..), NExprLoc, SrcSpan)
import NixCompile.Nix.Utils (srcSpanToSpan, varNameText)
import NixCompile.Types (Loc (..), Span (..))

-- | Type of derivation quality violation
data DerivViolationType
  = VMissingMeta
  | VMissingDescription
  deriving (Eq, Show)

-- | A derivation quality violation found in Nix source
data DerivViolation = DerivViolation
  { dvType :: !DerivViolationType,
    dvPath :: !FilePath,
    dvSpan :: !Span
  }
  deriving (Eq, Show)

-- | Find all derivation quality violations in a parsed Nix expression
findDerivViolations :: FilePath -> NExprLoc -> [DerivViolation]
findDerivViolations filePath = go
  where
    go :: NExprLoc -> [DerivViolation]
    go (Fix (Compose (AnnUnit srcSpan e))) = case e of
      NApp func arg ->
        checkDeriv srcSpan func arg ++ go func ++ go arg
      NSet _ bindings -> concatMap goBinding bindings
      NLet bindings body -> concatMap goBinding bindings ++ go body
      NList xs -> concatMap go xs
      NIf c t f -> go c ++ go t ++ go f
      NAssert c b -> go c ++ go b
      NAbs _ b -> go b
      NWith scope body -> go scope ++ go body
      NSelect alt b _ -> maybe [] go alt ++ go b
      NHasAttr b _ -> go b
      NUnary _ x -> go x
      NBinary _ x y -> go x ++ go y
      _ -> []

    goBinding :: Binding NExprLoc -> [DerivViolation]
    goBinding = \case
      NamedVar _ expr _ -> go expr
      Inherit (Just scope) _ _ -> go scope
      Inherit Nothing _ _ -> []

    checkDeriv :: SrcSpan -> NExprLoc -> NExprLoc -> [DerivViolation]
    checkDeriv sp func arg
      | isMkDerivationCall func = checkArg sp arg
      | otherwise = []

    isMkDerivationCall :: NExprLoc -> Bool
    isMkDerivationCall (Fix (Compose (AnnUnit _ (NSym name)))) =
      varNameText name == "mkDerivation"
    isMkDerivationCall (Fix (Compose (AnnUnit _ (NSelect _ _ (StaticKey k :| []))))) =
      varNameText k == "mkDerivation"
    isMkDerivationCall _ = False

    checkArg :: SrcSpan -> NExprLoc -> [DerivViolation]
    checkArg sp (Fix (Compose (AnnUnit _ (NSet _ bindings)))) =
      checkMeta sp bindings
    checkArg _ (Fix (Compose (AnnUnit _ (NSym _)))) = []
    checkArg _ _ = []

    checkMeta :: SrcSpan -> [Binding NExprLoc] -> [DerivViolation]
    checkMeta sp bindings =
      case findMetaBinding bindings of
        Nothing ->
          [ DerivViolation
              { dvType = VMissingMeta,
                dvPath = filePath,
                dvSpan = srcSpanToSpan sp
              }
          ]
        Just (NamedVar _ metaVal _) ->
          let metaVios = case metaVal of
                Fix (Compose (AnnUnit msp (NSet _ metaBindings))) ->
                  if any isDescriptionBinding metaBindings
                    then []
                    else
                      [ DerivViolation
                          { dvType = VMissingDescription,
                            dvPath = filePath,
                            dvSpan = srcSpanToSpan msp
                          }
                      ]
                _ -> []
           in metaVios ++ go metaVal
        _ -> []

    findMetaBinding :: [Binding NExprLoc] -> Maybe (Binding NExprLoc)
    findMetaBinding = find $ \case
      NamedVar (StaticKey name :| []) _ _ -> varNameText name == "meta"
      _ -> False

    isDescriptionBinding :: Binding NExprLoc -> Bool
    isDescriptionBinding (NamedVar (StaticKey name :| []) _ _) = varNameText name == "description"
    isDescriptionBinding _ = False

-- | Map a violation type to its config rule ID
derivRuleId :: DerivViolationType -> Text
derivRuleId = \case
  VMissingMeta -> "missing-meta"
  VMissingDescription -> "missing-description"

-- | Format violations for display
formatDerivViolations :: [DerivViolation] -> Text
formatDerivViolations = T.unlines . map formatOne
  where
    formatOne v =
      T.unlines
        [ formatLoc (dvSpan v) <> ": " <> errorCode (dvType v),
          "  " <> contextLine (dvType v),
          "",
          note (dvType v)
        ]

    formatLoc span' =
      let line = T.pack (show (locLine (spanStart span')))
          col = T.pack (show (locCol (spanStart span')))
       in case spanFile span' of
            Just f -> T.pack f <> ":" <> line <> ":" <> col
            Nothing -> line <> ":" <> col

    errorCode VMissingMeta = "ALEPH-N013: missing `meta`"
    errorCode VMissingDescription = "ALEPH-N014: missing `description` in meta"

    contextLine VMissingMeta = "mkDerivation call without meta attribute"
    contextLine VMissingDescription = "meta = { ... } without description key"

    note VMissingMeta =
      T.unlines
        [ "  Derivations should include a `meta` attribute for package metadata.",
          "",
          "  Add:  meta = with lib; { ... };"
        ]
    note VMissingDescription =
      T.unlines
        [ "  The `meta` attribute should include a `description`.",
          "",
          "  Add:  meta = with lib; { description = \"...\"; ... };"
        ]
