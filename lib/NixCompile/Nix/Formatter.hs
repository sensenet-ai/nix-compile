{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // nix // formatter
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "A year here and he still dreamed of cyberspace, hope fading nightly."
--
--                                                                 — Neuromancer
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                // nix // pretty // printer
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Formatter (
    formatNix,
    formatNixFile,
)
where

import Data.Fix (Fix (..))
import Data.List (intersperse)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import qualified Data.Text as T
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import Nix.Utils (Path (..))
import NixCompile.Nix.Utils (varNameText)
import Prettyprinter
import qualified Prettyprinter.Render.Text as PR

-- ═════════════════════════════════════════════════════════════════════════════
-- entry points
-- ═════════════════════════════════════════════════════════════════════════════

formatNix :: NExprLoc -> Text
formatNix = render . printExpr

formatNixFile :: FilePath -> NExprLoc -> Text
formatNixFile _path = formatNix

-- ═════════════════════════════════════════════════════════════════════════════
-- helpers
-- ═════════════════════════════════════════════════════════════════════════════

render :: Doc ann -> Text
render = PR.renderStrict . layoutSmart defaultLayoutOptions

printExpr :: NExprLoc -> Doc ann
printExpr (Fix (Compose (AnnUnit _ e))) = printNExprF e

checkGroup :: Doc ann -> Doc ann
checkGroup d =
    let flat = render d
     in if "\n" `T.isInfixOf` flat then nest 2 (line <> d) else d

isMultiline :: Doc ann -> Bool
isMultiline d = "\n" `T.isInfixOf` render d

printNExprF :: NExprF NExprLoc -> Doc ann
printNExprF = \case
    NConstant atom -> printNAtom atom
    NStr string -> printNString string
    NSym name -> pretty (varNameText name)
    NList elements -> printList elements
    NSet recursive bindings -> printSet (recursive == Recursive) bindings
    NLet bindings body -> printLet bindings body
    NIf cond then_ else_ -> printIf cond then_ else_
    NWith scope body -> printWith scope body
    NAssert cond body -> printAssert cond body
    NAbs params body -> printAbs params body
    NApp fun arg -> printApp fun arg
    NSelect alt base path -> printSelect alt base path
    NHasAttr base path -> printHasAttr base path
    NUnary NNeg _arg -> "-" <> printExpr _arg
    NUnary NNot _arg -> "!" <> printExpr _arg
    NBinary op left right -> printBinary op left right
    NEnvPath path -> printPath path
    NLiteralPath path -> printPath path
    NSynHole _ -> "<hole>"

-- ═════════════════════════════════════════════════════════════════════════════
-- atoms
-- ═════════════════════════════════════════════════════════════════════════════

printNAtom :: NAtom -> Doc ann
printNAtom = \case
    NInt i -> pretty i
    NFloat f -> pretty f
    NBool True -> "true"
    NBool False -> "false"
    NNull -> "null"
    NURI uri -> pretty uri

-- ═════════════════════════════════════════════════════════════════════════════
-- strings
-- ═════════════════════════════════════════════════════════════════════════════

printNString :: NString NExprLoc -> Doc ann
printNString = \case
    DoubleQuoted parts -> dquotes (hcat (map printStringPart parts))
    Indented _ parts -> "''" <> line <> hcat (map printIndentedPart parts) <> "''"

printStringPart :: Antiquoted Text NExprLoc -> Doc ann
printStringPart = \case
    Plain t -> pretty t
    Antiquoted e -> "${" <> printExpr e <> "}"
    EscapedNewline -> "\\" <> line

printIndentedPart :: Antiquoted Text NExprLoc -> Doc ann
printIndentedPart = \case
    Plain t -> pretty t
    Antiquoted e -> "${" <> printExpr e <> "}"
    EscapedNewline -> "\\" <> line

-- ═════════════════════════════════════════════════════════════════════════════
-- paths
-- ═════════════════════════════════════════════════════════════════════════════

-- ═════════════════════════════════════════════════════════════════════════════
-- paths
-- ═════════════════════════════════════════════════════════════════════════════

printPath :: Path -> Doc ann
printPath (Path p) =
    let pt = T.pack p
     in if "./" `T.isPrefixOf` pt || "/" `T.isPrefixOf` pt
            then pretty pt
            else "./" <> pretty pt

-- ═════════════════════════════════════════════════════════════════════════════
-- lists
-- ═════════════════════════════════════════════════════════════════════════════

printList :: [NExprLoc] -> Doc ann
printList [] = "[]"
printList elements =
    let rendered = map printListElem elements
        singleLine = brackets (hsep rendered)
     in if any isMultiline rendered || (T.length (render singleLine) > 80)
            then brackets (line <> indent 2 (vsep rendered) <> line)
            else singleLine

printListElem :: NExprLoc -> Doc ann
printListElem (Fix (Compose (AnnUnit _ e))) = case e of
    NAbs _ _ -> parens (printNExprF e)
    NLet _ _ -> parens (printNExprF e)
    NIf _ _ _ -> parens (printNExprF e)
    NWith _ _ -> parens (printNExprF e)
    NAssert _ _ -> parens (printNExprF e)
    _ -> printNExprF e

-- ═════════════════════════════════════════════════════════════════════════════
-- attribute sets
-- ═════════════════════════════════════════════════════════════════════════════

printSet :: Bool -> [Binding NExprLoc] -> Doc ann
printSet isRec bindings
    | null bindings = recPrefix <> "{ }"
    | otherwise = recPrefix <> recSep <> lbrace <> line <> indent 2 (vsep bindingDocs) <> line <> rbrace
  where
    recPrefix = if isRec then "rec" else mempty
    recSep = if isRec then space else mempty
    bindingDocs = map printBinding bindings

printBinding :: Binding NExprLoc -> Doc ann
printBinding = \case
    NamedVar path value _ ->
        printAttrPath path <+> "=" <+> checkGroup (printExpr value) <> ";"
    Inherit mScope keys _ ->
        let keyDocs = map (pretty . varNameText) keys
         in case mScope of
                Just scope ->
                    "inherit" <+> parens (printExpr scope) <+> hsep keyDocs <> ";"
                Nothing ->
                    "inherit" <+> hsep keyDocs <> ";"

-- ═════════════════════════════════════════════════════════════════════════════
-- let bindings
-- ═════════════════════════════════════════════════════════════════════════════

printLet :: [Binding NExprLoc] -> NExprLoc -> Doc ann
printLet bindings body =
    "let" <> line <> indent 2 (vsep (map printBinding bindings)) <> line <> "in" <+> printExpr body

-- ═════════════════════════════════════════════════════════════════════════════
-- conditional
-- ═════════════════════════════════════════════════════════════════════════════

printIf :: NExprLoc -> NExprLoc -> NExprLoc -> Doc ann
printIf cond then_ else_ =
    "if" <+> printExpr cond <> line <> "then" <+> printExpr then_ <> line <> "else" <+> printExpr else_

-- ═════════════════════════════════════════════════════════════════════════════
-- with
-- ═════════════════════════════════════════════════════════════════════════════

printWith :: NExprLoc -> NExprLoc -> Doc ann
printWith scope body =
    "with" <+> printExpr scope <> ";" <> line <> printExpr body

-- ═════════════════════════════════════════════════════════════════════════════
-- assert
-- ═════════════════════════════════════════════════════════════════════════════

printAssert :: NExprLoc -> NExprLoc -> Doc ann
printAssert cond body =
    "assert" <+> printExpr cond <> ";" <> line <> printExpr body

-- ═════════════════════════════════════════════════════════════════════════════
-- lambdas
-- ═════════════════════════════════════════════════════════════════════════════

printAbs :: Params NExprLoc -> NExprLoc -> Doc ann
printAbs params body = case params of
    Param name ->
        pretty (varNameText name) <> ":" <+> checkGroup (printExpr body)
    ParamSet mName _isVariadic paramSet ->
        let varNames = maybe id (\n -> (n :)) mName (map fst paramSet)
            doc = hsep (punctuate "," (map (pretty . varNameText) varNames))
         in lbrace <> space <> doc <> space <> rbrace <> ":" <+> checkGroup (printExpr body)

-- ═════════════════════════════════════════════════════════════════════════════
-- application
-- ═════════════════════════════════════════════════════════════════════════════

printApp :: NExprLoc -> NExprLoc -> Doc ann
printApp fun arg =
    let funDoc = printAppFun fun
        argDoc = printArg arg
     in funDoc <+> argDoc

printAppFun :: NExprLoc -> Doc ann
printAppFun (Fix (Compose (AnnUnit _ e))) = case e of
    NAbs _ _ -> parens (printNExprF e)
    NIf _ _ _ -> parens (printNExprF e)
    NLet _ _ -> parens (printNExprF e)
    NWith _ _ -> parens (printNExprF e)
    NAssert _ _ -> parens (printNExprF e)
    _ -> printNExprF e

printArg :: NExprLoc -> Doc ann
printArg (Fix (Compose (AnnUnit _ e))) = case e of
    NAbs _ _ -> parens (printNExprF e)
    NApp _ _ -> parens (printNExprF e)
    NIf _ _ _ -> parens (printNExprF e)
    NLet _ _ -> parens (printNExprF e)
    NWith _ _ -> parens (printNExprF e)
    NAssert _ _ -> parens (printNExprF e)
    _ -> printNExprF e

-- ═════════════════════════════════════════════════════════════════════════════
-- attribute selection
-- ═════════════════════════════════════════════════════════════════════════════

printSelect :: Maybe NExprLoc -> NExprLoc -> NAttrPath NExprLoc -> Doc ann
printSelect alt base path =
    let baseDoc = printExpr base
        pathDoc = hcat (intersperse dot (map printKeyName (NE.toList path)))
        altDoc = case alt of
            Just a -> space <> "or" <+> printExpr a
            Nothing -> mempty
     in baseDoc <> dot <> pathDoc <> altDoc

-- ═════════════════════════════════════════════════════════════════════════════
-- attribute test
-- ═════════════════════════════════════════════════════════════════════════════

printHasAttr :: NExprLoc -> NAttrPath NExprLoc -> Doc ann
printHasAttr base path =
    printExpr base <+> "?" <+> hcat (intersperse dot (map printKeyName (NE.toList path)))

-- ═════════════════════════════════════════════════════════════════════════════
-- binary operators
-- ═════════════════════════════════════════════════════════════════════════════

printBinary :: NBinaryOp -> NExprLoc -> NExprLoc -> Doc ann
printBinary op left right =
    printExpr left <+> pretty (binaryOpText op) <+> printExpr right

binaryOpText :: NBinaryOp -> Text
binaryOpText = \case
    NEq -> "=="; NNEq -> "!="; NLt -> "<"; NLte -> "<="; NGt -> ">"; NGte -> ">="
    NAnd -> "&&"; NOr -> "||"; NImpl -> "->"; NUpdate -> "//"
    NConcat -> "++"; NPlus -> "+"; NMinus -> "-"; NMult -> "*"
    NDiv -> "/"

-- ═════════════════════════════════════════════════════════════════════════════
-- key names and paths
-- ═════════════════════════════════════════════════════════════════════════════

printAttrPath :: NAttrPath NExprLoc -> Doc ann
printAttrPath path = hcat (intersperse dot (map printKeyName (NE.toList path)))

printKeyName :: NKeyName NExprLoc -> Doc ann
printKeyName = \case
    StaticKey name -> pretty (varNameText name)
    DynamicKey mk -> case mk of
        Plain str -> printNString str
        EscapedNewline -> mempty
        Antiquoted e -> "${" <> printExpr e <> "}"
