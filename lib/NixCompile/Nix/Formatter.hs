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
import Text.Megaparsec.Pos qualified as MP

data Src = Src
    { srcLines :: [Text]
    , srcDocCommentFlags :: [Bool]
    }

isBlankLine :: Text -> Bool
isBlankLine t = T.null (T.strip t)

precedingBlankCount :: Src -> Int -> Int
precedingBlankCount src target =
    let ls = take (target - 1) (srcLines src)
     in length (takeWhileEnd isBlankLine ls)

precedingBlankDoc :: Src -> NSourcePos -> Doc ann
precedingBlankDoc src spos =
    if precedingBlankCount src (lineNum spos) > 0 then hardline else mempty

precedingComments :: Src -> Int -> [Text]
precedingComments src target =
    map fst $ takeWhileEnd (\(t, isDoc) -> isCommentLike t isDoc) (take (target - 1) (zip (srcLines src) (srcDocCommentFlags src)))

isCommentLike :: Text -> Bool -> Bool
isCommentLike t inDocComment = inDocComment || isCommentLine t

isCommentLine :: Text -> Bool
isCommentLine t = case T.stripStart t of
    "" -> False
    t' -> isCommentPrefix t'
  where
    isCommentPrefix raw
        | "#" `T.isPrefixOf` raw = True
        | "/**" `T.isPrefixOf` raw = True
        | "*/" `T.isPrefixOf` raw = True
        | "* " `T.isPrefixOf` raw = True
        | "*\n" == raw = True
        | otherwise = False

markDocCommentLines :: [Text] -> [Bool]
markDocCommentLines = go False
  where
    go _ [] = []
    go inBlock (l : rest)
        | "/**" `T.isInfixOf` l = True : go True rest
        | inBlock && "*/" `T.isInfixOf` l = True : go False rest
        | inBlock = True : go True rest
        | otherwise = False : go False rest

topCommentsDoc :: Src -> Doc ann
topCommentsDoc src =
    let leading = takeWhile (\(t, isDoc) -> T.stripStart t == "" || isCommentLike t isDoc) (zip (srcLines src) (srcDocCommentFlags src))
        commentLines = map fst $ filter (\(t, isDoc) -> isCommentLike t isDoc) leading
     in if null commentLines
            then mempty
            else vcat (map (pretty . T.stripStart) commentLines) <> hardline

takeWhileEnd :: (a -> Bool) -> [a] -> [a]
takeWhileEnd p = reverse . takeWhile p . reverse

lineNum :: NSourcePos -> Int
lineNum (NSourcePos _ (NPos p) _) = MP.unPos p

formatNix :: Text -> NExprLoc -> Text
formatNix srcTxt expr =
    let rawLines = T.lines srcTxt
        docFlags = markDocCommentLines rawLines
        src = Src rawLines docFlags
     in render $ printExpr src expr

formatNixFile :: Text -> FilePath -> NExprLoc -> Text
formatNixFile srcTxt _path expr =
    let rawLines = T.lines srcTxt
        docFlags = markDocCommentLines rawLines
        src = Src rawLines docFlags
     in render $ topCommentsDoc src <> printExpr src expr

render :: Doc ann -> Text
render = PR.renderStrict . layoutSmart defaultLayoutOptions

printExpr :: Src -> NExprLoc -> Doc ann
printExpr src (Fix (Compose (AnnUnit _ e))) = printNExprF src e

isMultiline :: Doc ann -> Bool
isMultiline d = "\n" `T.isInfixOf` render d

printBindingVal :: Src -> Doc ann -> NExprLoc -> Doc ann
printBindingVal src keyDoc val =
    let valDoc = printExpr src val
        single = keyDoc <+> valDoc
        flat = render (nest 0 single)
     in if "\n" `T.isInfixOf` flat
        then keyDoc <> hardline <> "  " <> valDoc
        else single

precedingCommentsDoc :: Src -> NSourcePos -> Doc ann
precedingCommentsDoc src spos =
    let ln = lineNum spos
        comments = precedingComments src ln
     in if null comments
            then mempty
            else vcat (map (\c -> pretty (T.stripStart c)) comments) <> hardline

printNExprF :: Src -> NExprF NExprLoc -> Doc ann
printNExprF src = \case
    NConstant atom -> printNAtom atom
    NStr string -> printNString src string
    NSym name -> pretty (varNameText name)
    NList elements -> printList src elements
    NSet recursive bindings -> printSet src (recursive == Recursive) bindings
    NLet bindings body -> printLet src bindings body
    NIf cond then_ else_ -> printIf src cond then_ else_
    NWith scope body -> printWith src scope body
    NAssert cond body -> printAssert src cond body
    NAbs params body -> printAbs src params body
    NApp fun arg -> printApp src fun arg
    NSelect alt base path -> printSelect src alt base path
    NHasAttr base path -> printHasAttr src base path
    NUnary NNeg _arg -> "-" <> printExpr src _arg
    NUnary NNot _arg -> "!" <> printExpr src _arg
    NBinary op left right -> printBinary src op left right
    NEnvPath path -> printPath path
    NLiteralPath path -> printPath path
    NSynHole _ -> "<hole>"

printNAtom :: NAtom -> Doc ann
printNAtom = \case
    NInt i -> pretty i
    NFloat f -> pretty f
    NBool True -> "true"
    NBool False -> "false"
    NNull -> "null"
    NURI uri -> pretty uri

printNString :: Src -> NString NExprLoc -> Doc ann
printNString src = \case
    DoubleQuoted parts -> dquotes (hcat (map (printStringPart src) parts))
    Indented _ parts -> "''" <> line <> indent 2 (hcat (map (printIndentedPart src) parts)) <> line <> "''"

printStringPart :: Src -> Antiquoted Text NExprLoc -> Doc ann
printStringPart src = \case
    Plain t -> pretty (escapeString t)
    Antiquoted e -> "${" <> printExpr src e <> "}"
    EscapedNewline -> mempty

printIndentedPart :: Src -> Antiquoted Text NExprLoc -> Doc ann
printIndentedPart src = \case
    Plain t -> pretty (escapeIndentedString t)
    Antiquoted e -> "${" <> printExpr src e <> "}"
    EscapedNewline -> "\\" <> line

escapeIndentedString :: Text -> Text
escapeIndentedString = T.replace "$" "''$"

escapeString :: Text -> Text
escapeString = T.concatMap $ \c -> case c of
    '"' -> "\\\""
    '\\' -> "\\\\"
    '$' -> "\\$"
    ch -> T.singleton ch

printPath :: Path -> Doc ann
printPath (Path p) =
    let pt = T.pack p
     in if "./" `T.isPrefixOf` pt || "/" `T.isPrefixOf` pt
            then pretty pt
            else "./" <> pretty pt

printList :: Src -> [NExprLoc] -> Doc ann
printList _src [] = "[]"
printList src elements =
    let rendered = map (printListElem src) elements
        singleLine = brackets (hsep rendered)
     in if any isMultiline rendered || (T.length (render singleLine) > 80)
            then brackets (line <> indent 2 (vsep rendered) <> line)
            else singleLine

printListElem :: Src -> NExprLoc -> Doc ann
printListElem src (Fix (Compose (AnnUnit _ e))) = case e of
    NAbs _ _ -> parens (printNExprF src e)
    NLet _ _ -> parens (printNExprF src e)
    NIf _ _ _ -> parens (printNExprF src e)
    NWith _ _ -> parens (printNExprF src e)
    NAssert _ _ -> parens (printNExprF src e)
    _ -> printNExprF src e

printSet :: Src -> Bool -> [Binding NExprLoc] -> Doc ann
printSet src isRec bindings
    | null bindings = recPrefix <> "{ }"
    | otherwise = recPrefix <> recSep <> lbrace <> hardline <> indent 2 (vcat bindingDocs) <> hardline <> rbrace
  where
    recPrefix = if isRec then "rec" else mempty
    recSep = if isRec then space else mempty
    bindingDocs = map (printBinding src) bindings

printBinding :: Src -> Binding NExprLoc -> Doc ann
printBinding src = \case
    NamedVar path value spos ->
        let blankDoc = precedingBlankDoc src spos
            commentDoc = precedingCommentsDoc src spos
         in blankDoc <> commentDoc <> printBindingVal src (printAttrPath src path <+> "=") value <> ";"
    Inherit mScope keys _ ->
        let keyDocs = map (pretty . varNameText) keys
         in case mScope of
                Just scope ->
                    "inherit" <+> parens (printExpr src scope) <+> hsep keyDocs <> ";"
                Nothing ->
                    "inherit" <+> hsep keyDocs <> ";"

printLet :: Src -> [Binding NExprLoc] -> NExprLoc -> Doc ann
printLet src bindings body =
    "let" <> hardline <> indent 2 (vcat (map (printBinding src) bindings)) <> hardline <> "in" <+> printExpr src body

printIf :: Src -> NExprLoc -> NExprLoc -> NExprLoc -> Doc ann
printIf src cond then_ else_ =
    "if" <+> printExpr src cond <> hardline <> "then" <+> printExpr src then_ <> hardline <> "else" <+> printExpr src else_

printWith :: Src -> NExprLoc -> NExprLoc -> Doc ann
printWith src scope body =
    "with" <+> printExpr src scope <> ";" <> hardline <> printExpr src body

printAssert :: Src -> NExprLoc -> NExprLoc -> Doc ann
printAssert src cond body =
    "assert" <+> printExpr src cond <> ";" <> hardline <> printExpr src body

printAbs :: Src -> Params NExprLoc -> NExprLoc -> Doc ann
printAbs src params body = case params of
    Param name ->
        printBindingVal src (pretty (varNameText name) <> ":") body
    ParamSet mName isVariadic paramSet ->
        let
            varNames = map fst paramSet
            namesDoc = hsep (punctuate "," (map (pretty . varNameText) varNames))
            variadicDoc = case isVariadic of
                Variadic ->
                    if null paramSet then mempty <> "..."
                    else if not (null paramSet) then "," <+> "..."
                    else mempty
                _ -> mempty
            atDoc = maybe mempty (\n -> mempty <+> "@" <+> pretty (varNameText n)) mName
            doc = namesDoc <> variadicDoc
            key = lbrace <> space <> doc <> space <> rbrace <> atDoc <> ":"
         in printBindingVal src key body

printApp :: Src -> NExprLoc -> NExprLoc -> Doc ann
printApp src fun arg =
    let funDoc = printAppFun src fun
        argDoc = printArg src arg
     in funDoc <+> argDoc

printAppFun :: Src -> NExprLoc -> Doc ann
printAppFun src (Fix (Compose (AnnUnit _ e))) = case e of
    NAbs _ _ -> parens (printNExprF src e)
    NIf _ _ _ -> parens (printNExprF src e)
    NLet _ _ -> parens (printNExprF src e)
    NWith _ _ -> parens (printNExprF src e)
    NAssert _ _ -> parens (printNExprF src e)
    _ -> printNExprF src e

printArg :: Src -> NExprLoc -> Doc ann
printArg src (Fix (Compose (AnnUnit _ e))) = case e of
    NAbs _ _ -> parens (printNExprF src e)
    NApp _ _ -> parens (printNExprF src e)
    NIf _ _ _ -> parens (printNExprF src e)
    NLet _ _ -> parens (printNExprF src e)
    NWith _ _ -> parens (printNExprF src e)
    NAssert _ _ -> parens (printNExprF src e)
    NBinary _ _ _ -> parens (printNExprF src e)
    NUnary _ _ -> parens (printNExprF src e)
    NSelect (Just _) _ _ -> parens (printNExprF src e)
    _ -> printNExprF src e

printSelect :: Src -> Maybe NExprLoc -> NExprLoc -> NAttrPath NExprLoc -> Doc ann
printSelect src alt base path =
    let baseDoc = printSelectBase src base
        pathDoc = hcat (intersperse dot (map (printKeyName src) (NE.toList path)))
        altDoc = case alt of
            Just a -> space <> "or" <+> printSelectAlt src a
            Nothing -> mempty
     in baseDoc <> dot <> pathDoc <> altDoc

printSelectBase :: Src -> NExprLoc -> Doc ann
printSelectBase src (Fix (Compose (AnnUnit _ e))) = case e of
    NApp _ _ -> parens (printNExprF src e)
    NSelect _ _ _ -> parens (printNExprF src e)
    NAbs _ _ -> parens (printNExprF src e)
    NIf _ _ _ -> parens (printNExprF src e)
    NLet _ _ -> parens (printNExprF src e)
    NWith _ _ -> parens (printNExprF src e)
    NAssert _ _ -> parens (printNExprF src e)
    NBinary _ _ _ -> parens (printNExprF src e)
    _ -> printNExprF src e

printSelectAlt :: Src -> NExprLoc -> Doc ann
printSelectAlt src (Fix (Compose (AnnUnit _ e))) = case e of
    NAbs _ _ -> parens (printNExprF src e)
    NLet _ _ -> parens (printNExprF src e)
    NIf _ _ _ -> parens (printNExprF src e)
    NWith _ _ -> parens (printNExprF src e)
    NAssert _ _ -> parens (printNExprF src e)
    NBinary _ _ _ -> parens (printNExprF src e)
    _ -> printNExprF src e

printHasAttr :: Src -> NExprLoc -> NAttrPath NExprLoc -> Doc ann
printHasAttr src base path =
    printExpr src base <+> "?" <+> hcat (intersperse dot (map (printKeyName src) (NE.toList path)))

printBinary :: Src -> NBinaryOp -> NExprLoc -> NExprLoc -> Doc ann
printBinary src op left right =
    printExpr src left <+> pretty (binaryOpText op) <+> printBinaryArg src right

printBinaryArg :: Src -> NExprLoc -> Doc ann
printBinaryArg src (Fix (Compose (AnnUnit _ e))) = case e of
    NAbs _ _ -> parens (printNExprF src e)
    NIf _ _ _ -> parens (printNExprF src e)
    NLet _ _ -> parens (printNExprF src e)
    NWith _ _ -> parens (printNExprF src e)
    NAssert _ _ -> parens (printNExprF src e)
    NBinary _ _ _ -> parens (printNExprF src e)
    NUnary _ _ -> parens (printNExprF src e)
    _ -> printNExprF src e

binaryOpText :: NBinaryOp -> Text
binaryOpText = \case
    NEq -> "=="; NNEq -> "!="; NLt -> "<"; NLte -> "<="; NGt -> ">"; NGte -> ">="
    NAnd -> "&&"; NOr -> "||"; NImpl -> "->"; NUpdate -> "//"
    NConcat -> "++"; NPlus -> "+"; NMinus -> "-"; NMult -> "*"
    NDiv -> "/"

printAttrPath :: Src -> NAttrPath NExprLoc -> Doc ann
printAttrPath src path = hcat (intersperse dot (map (printKeyName src) (NE.toList path)))

printKeyName :: Src -> NKeyName NExprLoc -> Doc ann
printKeyName src = \case
    StaticKey name -> pretty (varNameText name)
    DynamicKey mk -> case mk of
        Plain str -> printNString src str
        EscapedNewline -> mempty
        Antiquoted e -> "${" <> printExpr src e <> "}"
