{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                      // NixCompile.Nix.LintCombined // walk
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He touched the jaws and cheekbones, and it was like she was standing
--    right there, the actual woman, behind the face like a wall."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                          // Nix // single-pass combined lint
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.LintCombined (
    LintBundle (..),
    emptyBundle,
    combinedLint,
)
where

import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import Nix.Utils (Path (..))
import NixCompile.Nix.Lint (
    NixViolation (..),
    ViolationType (VLongInlineString, VRawMkDerivation, VRawRunCommand, VRawWriteShellApplication, VRec, VSubstituteAll, VWith, VWriteShellScript),
 )
import NixCompile.Nix.LintDerivation (
    DerivViolation (..),
    DerivViolationType (VMissingDescription, VMissingMeta),
 )
import NixCompile.Nix.LintPatterns (
    PatternViolation (..),
    PatternViolationType (VAttrTranslation, VOrNullFallback),
 )
import NixCompile.Nix.Utils (varNameText)
import NixCompile.Types (Loc (..), Span (..))

data LintBundle = LintBundle
    { lbNix :: ![NixViolation]
    , lbDeriv :: ![DerivViolation]
    , lbPattern :: ![PatternViolation]
    }
    deriving (Eq, Show)

emptyBundle :: LintBundle
emptyBundle = LintBundle [] [] []

-- ── entry point ────────────────────────────────────────────────────
-- Single AST walk collecting all three violation categories.
-- Replaces three separate traversals.

combinedLint :: FilePath -> NExprLoc -> LintBundle
combinedLint filePath = walkExpr (0 :: Int)
  where
    maxDepth :: Int
    maxDepth = 200

    walkExpr depth (Fix (Compose (AnnUnit srcSpan expression)))
        | depth > maxDepth = emptyBundle
        | otherwise =
            let d = depth + 1
                local = localViolations filePath srcSpan expression
                rest = concatBundle (map (walkExpr d) (childExprs expression))
             in combineBundle local (combineBundle (concatBundle (map (walkBinding d) (bindingsOf expression))) rest)

    walkBinding depth = \case
        NamedVar _ expr _ -> walkExpr depth expr
        Inherit (Just scope) _ _ -> walkExpr depth scope
        Inherit Nothing _ _ -> emptyBundle

-- ── per-node violation checks ──────────────────────────────────────

localViolations :: FilePath -> SrcSpan -> NExprF NExprLoc -> LintBundle
localViolations filePath srcSpan expression =
    mconcat
        [ nixViolations srcSpan expression
        , derivViolations filePath srcSpan expression
        , patternViolations srcSpan expression
        ]

-- ── Nix lint checks ────────────────────────────────────────────────

nixViolations :: SrcSpan -> NExprF NExprLoc -> LintBundle
nixViolations srcSpan = \case
    NWith _scope _body ->
        LintBundle [nv VWith "with ..."] [] []
    NSet Recursive _ ->
        LintBundle [nv VRec "rec { ... }"] [] []
    NApp func _arg ->
        let banned = bannedApp srcSpan func
         in if null banned then emptyBundle else LintBundle banned [] []
    NStr (DoubleQuoted parts) ->
        LintBundle (longString srcSpan parts) [] []
    NStr (Indented _ _) -> emptyBundle
    _ -> emptyBundle
  where
    nv typ ctx =
        NixViolation
            { nvType = typ
            , nvSpan = toSpan srcSpan
            , nvContext = ctx
            }

maxInlineStringLength :: Int
maxInlineStringLength = 120

longString :: SrcSpan -> [Antiquoted Text NExprLoc] -> [NixViolation]
longString srcSpan parts
    | len > maxInlineStringLength =
        [ NixViolation (VLongInlineString len) (toSpan srcSpan) ("inline string of length " <> T.pack (show len))
        ]
    | otherwise = []
  where
    len = sum (map partLen parts)
    partLen (Plain t) = T.length t
    partLen _ = 0

bannedApp :: SrcSpan -> NExprLoc -> [NixViolation]
bannedApp srcSpan f = case leafName f of
    Just "substituteAll" -> [mkNV VSubstituteAll "substituteAll ..."]
    Just "mkDerivation" -> [mkNV VRawMkDerivation "mkDerivation { ... }"]
    Just "runCommand" -> [mkNV VRawRunCommand "runCommand ..."]
    Just "writeShellApplication" -> [mkNV VRawWriteShellApplication "writeShellApplication { ... }"]
    Just n | n == "writeShellScript" || n == "writeShellScriptBin" -> [mkNV VWriteShellScript (n <> " ...")]
    _ -> []
  where
    mkNV typ ctx = NixViolation typ (toSpan srcSpan) ctx

-- ── Derivation lint checks ─────────────────────────────────────────

derivViolations :: FilePath -> SrcSpan -> NExprF NExprLoc -> LintBundle
derivViolations filePath srcSpan = \case
    NApp func arg | isMkDeriv func -> checkDerivMeta filePath srcSpan arg
    _ -> emptyBundle
  where
    isMkDeriv = isMkDerivationCall

isMkDerivationCall :: NExprLoc -> Bool
isMkDerivationCall (Fix (Compose (AnnUnit _ (NSym name)))) = varNameText name == "mkDerivation"
isMkDerivationCall (Fix (Compose (AnnUnit _ (NSelect _ _ attrs))))
    | StaticKey key :| _ <- attrs = varNameText key == "mkDerivation"
isMkDerivationCall _ = False

checkDerivMeta :: FilePath -> SrcSpan -> NExprLoc -> LintBundle
checkDerivMeta filePath srcSpan (Fix (Compose (AnnUnit _ (NSet _ bindings)))) =
    let hasMeta = any isMetaBinding bindings
        metaBody = findMetaBody bindings
        hasDesc = maybe False hasDescription metaBody
     in LintBundle
            []
            ( (if not hasMeta then [DerivViolation VMissingMeta filePath (toSpan srcSpan)] else [])
                ++ ( if hasMeta && not hasDesc
                        then [DerivViolation VMissingDescription filePath (toSpan srcSpan)]
                        else []
                   )
            )
            []
  where
    isMetaBinding (NamedVar (StaticKey name :| _) _ _) = varNameText name == "meta"
    isMetaBinding _ = False
    findMetaBody [] = Nothing
    findMetaBody (NamedVar (StaticKey n :| _) e _ : _) | varNameText n == "meta" = Just e
    findMetaBody (_ : rest) = findMetaBody rest
    hasDescription (Fix (Compose (AnnUnit _ (NSet _ bss)))) =
        any (\case NamedVar (StaticKey n :| _) _ _ -> varNameText n == "description"; _ -> False) bss
    hasDescription _ = False
checkDerivMeta _ srcSpan _ = LintBundle [] [DerivViolation VMissingMeta "<buffer>" (toSpan srcSpan)] []

-- ── Pattern lint checks ────────────────────────────────────────────

patternViolations :: SrcSpan -> NExprF NExprLoc -> LintBundle
patternViolations srcSpan = \case
    NSelect (Just defaultExpr) _ _ -- NSelect alt base path
        | isNullExpr defaultExpr ->
            LintBundle [] [] [PatternViolation VOrNullFallback (toSpan srcSpan) "or null fallback"]
    NApp func _
        | isTranslateCall func ->
            LintBundle [] [] [PatternViolation VAttrTranslation (toSpan srcSpan) "attribute translation call"]
    _ -> emptyBundle
  where
    isNullExpr (Fix (Compose (AnnUnit _ (NConstant NNull)))) = True
    isNullExpr (Fix (Compose (AnnUnit _ (NSym name)))) = varNameText name == ("null" :: Text)
    isNullExpr _ = False

    isTranslateCall (Fix (Compose (AnnUnit _ (NSym name)))) =
        varNameText name `elem` (["translateAttrs", "mapAttrsToList", "mapAttrsFlatten"] :: [Text])
    isTranslateCall (Fix (Compose (AnnUnit _ (NSelect _ _ attrs))))
        | StaticKey key :| _ <- attrs =
            varNameText key `elem` (["translateAttrs", "mapAttrsToList", "mapAttrsFlatten"] :: [Text])
    isTranslateCall _ = False

-- ── helpers ────────────────────────────────────────────────────────

-- | Extract all immediate child expressions from a node (same pattern across all linters).
childExprs :: NExprF NExprLoc -> [NExprLoc]
childExprs = \case
    NConstant _ -> []
    NStr parts -> stringExprs parts
    NLiteralPath _ -> []
    NEnvPath _ -> []
    NSym _ -> []
    NList xs -> xs
    NSet _ bindings -> concatMap bindingExprs bindings
    NLet bindings body -> concatMap bindingExprs bindings ++ [body]
    NIf c t f -> [c, t, f]
    NWith scope body -> [scope, body]
    NAssert c b -> [c, b]
    NAbs _ b -> [b]
    NApp f a -> [f, a]
    NSelect alt b path -> b : maybe id (:) alt [] ++ pathExprs path
    NHasAttr b path -> b : pathExprs path
    NUnary _ x -> [x]
    NBinary _ x y -> [x, y]
    NSynHole _ -> []

bindingExprs :: Binding NExprLoc -> [NExprLoc]
bindingExprs (NamedVar _ e _) = [e]
bindingExprs (Inherit (Just scope) _ _) = [scope]
bindingExprs (Inherit Nothing _ _) = []

bindingsOf :: NExprF NExprLoc -> [Binding NExprLoc]
bindingsOf = \case
    NSet _ bs -> bs
    NLet bs _ -> bs
    _ -> []

stringExprs :: NString NExprLoc -> [NExprLoc]
stringExprs (DoubleQuoted parts) = [e | Antiquoted e <- parts]
stringExprs (Indented _ parts) = [e | Antiquoted e <- parts]

pathExprs :: NAttrPath NExprLoc -> [NExprLoc]
pathExprs path = [e | DynamicKey (Antiquoted e) <- NE.toList path]

-- | Leaf symbol name of an expression (for banned-function detection).
leafName :: NExprLoc -> Maybe Text
leafName (Fix (Compose (AnnUnit _ (NSym name)))) = Just (varNameText name)
leafName (Fix (Compose (AnnUnit _ (NSelect _ _ attrs))))
    | StaticKey key :| _ <- attrs = Just (varNameText key)
leafName _ = Nothing

-- | hnix SrcSpan -> our Span
toSpan :: SrcSpan -> Span
toSpan srcSpan =
    let begin = getSpanBegin srcSpan
        end = getSpanEnd srcSpan
        fileFromBegin = case begin of NSourcePos path _ _ -> Just (coerce path)
     in Span
            { spanStart = Loc (srcPosLine begin) (srcPosCol begin)
            , spanEnd = Loc (srcPosLine end) (srcPosCol end)
            , spanFile = fileFromBegin
            }
  where
    srcPosLine (NSourcePos _ (NPos l) _) = fromIntegral (unPos l)
    srcPosCol (NSourcePos _ _ (NPos c)) = fromIntegral (unPos c)

-- ── Bundle combinators ─────────────────────────────────────────────

combineBundle :: LintBundle -> LintBundle -> LintBundle
combineBundle (LintBundle n1 d1 p1) (LintBundle n2 d2 p2) =
    LintBundle (n1 ++ n2) (d1 ++ d2) (p1 ++ p2)

concatBundle :: [LintBundle] -> LintBundle
concatBundle = foldr combineBundle emptyBundle

instance Semigroup LintBundle where
    (<>) = combineBundle

instance Monoid LintBundle where
    mempty = emptyBundle
