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
--
--   Goal: byte-for-byte PARITY with nixfmt (RFC 166). We own the formatter so
--   we can diverge later, but first we match. The layout is STRUCTURAL, not
--   width-driven the way a generic Wadler/Leijen printer is:
--
--     * attribute sets and lists EXPAND (one item per line) when they have ≥2
--       items, when any item is itself multiline, or when the inline form would
--       exceed the 100-column page width; otherwise they stay inline. Empty
--       collections render as `{ }` / `[ ]`.
--     * a set/list literal in "tail" position (a binding RHS, a lambda body, a
--       function argument) is ABSORBED — its opening bracket sits on the same
--       line as the preceding `=` / `:` / function, with the body indented two
--       and the closing bracket aligned to the construct.
--     * `let … in` and `with …;` / `assert …;` put their body on the next line
--       at the same indent.
--     * `if` stays on one line unless a part is multiline (or it overflows).
--
--   We render to `Text` with an explicit current-indent column threaded through,
--   rather than using a width-based `Doc` engine, because nixfmt's expansion
--   rules are mostly count/structure based and a generic printer cannot match
--   them.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Formatter (
    formatNix,
    formatNixFile,
)
where

import Data.Fix (Fix (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import Nix.Utils (Path (..))
import NixCompile.Nix.Utils (varNameText)
import Text.Megaparsec.Pos qualified as MP

-- ── page width (nixfmt default) ────────────────────────────────────
pageWidth :: Int
pageWidth = 100

-- ── source metadata (for comment / blank-line preservation) ────────
data Src = Src
    { srcLines :: [Text]
    , srcDocCommentFlags :: [Bool]
    }

isBlankLine :: Text -> Bool
isBlankLine t = T.null (T.strip t)

-- | number of blank source lines immediately preceding @target@ (1-based line)
precedingBlankCount :: Src -> Int -> Int
precedingBlankCount src target =
    let ls = take (target - 1) (srcLines src)
     in length (takeWhileEnd isBlankLine ls)

-- | the source position carried by a binding (NamedVar or Inherit)
bindingPos :: Binding NExprLoc -> NSourcePos
bindingPos = \case
    NamedVar _ _ p -> p
    Inherit _ _ p -> p

-- | True if a single blank line separated this binding from the previous source
-- construct — nixfmt preserves exactly one such blank between items.
hasPrecedingBlank :: Src -> Binding NExprLoc -> Bool
hasPrecedingBlank src b = precedingBlankCount src (lineNum (bindingPos b)) > 0

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

topComments :: Src -> [Text]
topComments src =
    let leading = takeWhile (\(t, isDoc) -> T.stripStart t == "" || isCommentLike t isDoc) (zip (srcLines src) (srcDocCommentFlags src))
     in map (T.stripStart . fst) $ filter (\(t, isDoc) -> isCommentLike t isDoc) leading

takeWhileEnd :: (a -> Bool) -> [a] -> [a]
takeWhileEnd p = reverse . takeWhile p . reverse

lineNum :: NSourcePos -> Int
lineNum (NSourcePos _ (NPos p) _) = MP.unPos p

-- ── entry points ───────────────────────────────────────────────────

formatNix :: Text -> NExprLoc -> Text
formatNix srcTxt expr =
    let src = mkSrc srcTxt
     in fmtExpr src 0 expr <> "\n"

formatNixFile :: Text -> FilePath -> NExprLoc -> Text
formatNixFile srcTxt _path expr =
    let src = mkSrc srcTxt
        tops = topComments src
        topDoc = if null tops then "" else T.unlines tops
     in topDoc <> fmtExpr src 0 expr <> "\n"

mkSrc :: Text -> Src
mkSrc srcTxt =
    let rawLines = T.lines srcTxt
     in Src rawLines (markDocCommentLines rawLines)

-- ── indentation helpers ────────────────────────────────────────────

-- | newline followed by @n@ spaces of indentation
nl :: Int -> Text
nl n = "\n" <> T.replicate n " "

multiline :: Text -> Bool
multiline = T.isInfixOf "\n"

-- | inline width starting at column @i@ (only meaningful for single-line text)
fits :: Int -> Text -> Bool
fits i t = i + T.length t <= pageWidth

-- ── core: render an expression assuming it begins at column @i@ ─────
--   The FIRST line carries no leading indentation (the caller positions it);
--   every continuation line is already indented to its absolute column.

fmtExpr :: Src -> Int -> NExprLoc -> Text
fmtExpr src i (Fix (Compose (AnnUnit _ e))) = fmtF src i e

fmtF :: Src -> Int -> NExprF NExprLoc -> Text
fmtF src i = \case
    NConstant atom -> fmtAtom atom
    NStr str -> fmtString src i str
    NSym name -> varNameText name
    NList elements -> fmtList src i elements
    NSet recursive bindings -> fmtSet src i (recursive == Recursive) bindings
    NLet bindings body -> fmtLet src i bindings body
    NIf cond then_ else_ -> fmtIf src i cond then_ else_
    NWith scope body -> "with " <> fmtExpr src i scope <> ";" <> nl i <> fmtExpr src i body
    NAssert cond body -> "assert " <> fmtExpr src i cond <> ";" <> nl i <> fmtExpr src i body
    NAbs params body -> fmtAbs src i params body
    NApp fun arg -> fmtApp src i fun arg
    NSelect alt base path -> fmtSelect src i alt base path
    NHasAttr base path -> fmtExpr src i base <> " ? " <> fmtAttrPath src path
    NUnary NNeg arg -> "-" <> fmtUnaryArg src i arg
    NUnary NNot arg -> "!" <> fmtUnaryArg src i arg
    NBinary op left right -> fmtBinary src i op left right
    NEnvPath path -> fmtEnvPath path
    NLiteralPath path -> fmtPath path
    NSynHole _ -> "<hole>"

fmtAtom :: NAtom -> Text
fmtAtom = \case
    NInt n -> T.pack (show n)
    NFloat f -> T.pack (show f)
    NBool True -> "true"
    NBool False -> "false"
    NNull -> "null"
    NURI uri -> uri

-- ── lists ───────────────────────────────────────────────────────────

fmtList :: Src -> Int -> [NExprLoc] -> Text
fmtList _ _ [] = "[ ]"
fmtList src i elements =
    let items = map (fmtListElem src (i + 2)) elements
        inline = "[ " <> T.intercalate " " items <> " ]"
     in if length elements >= 2 || any multiline items || not (fits i inline)
            then "[" <> T.concat (map (\t -> nl (i + 2) <> t) items) <> nl i <> "]"
            else inline

-- | a compound element shares the list's bracket grammar, so applications,
-- lambdas, operators etc. must be parenthesised to stay a single element.
fmtListElem :: Src -> Int -> NExprLoc -> Text
fmtListElem src i e@(Fix (Compose (AnnUnit _ inner))) = case inner of
    NAbs _ _ -> paren src i e
    NApp _ _ -> paren src i e
    NLet _ _ -> paren src i e
    NIf _ _ _ -> paren src i e
    NWith _ _ -> paren src i e
    NAssert _ _ -> paren src i e
    NBinary _ _ _ -> paren src i e
    NUnary _ _ -> paren src i e
    NHasAttr _ _ -> paren src i e
    NSelect (Just _) _ _ -> paren src i e
    _ -> fmtF src i inner

-- ── attribute sets ──────────────────────────────────────────────────

fmtSet :: Src -> Int -> Bool -> [Binding NExprLoc] -> Text
fmtSet src i isRec bindings
    | null bindings = pre <> "{ }"
    | otherwise =
        let bs = map (fmtBinding src (i + 2)) bindings
            inline = pre <> "{ " <> T.intercalate " " bs <> " }"
         in if length bindings >= 2 || any multiline bs || not (fits i inline)
                then expandedSet src i pre bindings
                else inline
  where
    pre = if isRec then "rec " else ""

-- | render a set's bindings one per line at @i+2@, closing brace at @i@, with a
-- single blank line preserved between bindings where the source had one.
expandedSet :: Src -> Int -> Text -> [Binding NExprLoc] -> Text
expandedSet src i pre bindings =
    pre <> "{" <> T.concat (zipWith item [0 ..] bindings) <> nl i <> "}"
  where
    item :: Int -> Binding NExprLoc -> Text
    item idx b = blank idx b <> nl (i + 2) <> fmtBinding src (i + 2) b
    blank idx b = if idx > 0 && hasPrecedingBlank src b then "\n" else ""

-- | a binding rendered as a block starting at column @i@. Preceding comment
-- lines (if any) are emitted first, each at column @i@.
fmtBinding :: Src -> Int -> Binding NExprLoc -> Text
fmtBinding src i = \case
    NamedVar path value spos ->
        commentPrefix src i spos
            <> fmtAttrPath src path
            <> " = "
            <> fmtBindingValue src i value
            <> ";"
    Inherit mScope keys _ ->
        let keyDocs = T.concat (map (\k -> " " <> varNameText k) keys)
         in case mScope of
                Just scope -> "inherit (" <> fmtExpr src i scope <> ")" <> keyDocs <> ";"
                Nothing -> "inherit" <> keyDocs <> ";"

-- | A non-empty set literal that is the direct RHS of a binding (an attrset
-- binding or a @let@ binding) is ALWAYS expanded — nixfmt expands bound sets to
-- surface structure, even single-binding ones (`a = { b = 1; }` → multiline).
-- This does NOT apply to lambda bodies, function arguments, or list elements
-- (handled by the normal fit rules), nor to empty sets (`a = { }` stays inline)
-- or list values (`a = [ 1 ]` stays inline).
fmtBindingValue :: Src -> Int -> NExprLoc -> Text
fmtBindingValue src i val@(Fix (Compose (AnnUnit _ inner))) = case inner of
    NSet recursive bindings
        | not (null bindings) ->
            expandedSet src i (if recursive == Recursive then "rec " else "") bindings
    _ -> fmtExpr src i val

-- | comment lines that immediately precede a binding, each on its own line at
-- the binding's indent. (Blank-line preservation is deliberately omitted for
-- now; nixfmt keeps a single separating blank — a later refinement.)
commentPrefix :: Src -> Int -> NSourcePos -> Text
commentPrefix src i spos =
    let cs = map T.stripStart (precedingComments src (lineNum spos))
     in T.concat [c <> nl i | c <- cs]

-- ── let / if ────────────────────────────────────────────────────────

fmtLet :: Src -> Int -> [Binding NExprLoc] -> NExprLoc -> Text
fmtLet src i bindings body =
    "let"
        <> T.concat (zipWith item [0 ..] bindings)
        <> nl i
        <> "in"
        <> nl i
        <> fmtExpr src i body
  where
    item :: Int -> Binding NExprLoc -> Text
    item idx b = blank idx b <> nl (i + 2) <> fmtBinding src (i + 2) b
    blank idx b = if idx > 0 && hasPrecedingBlank src b then "\n" else ""

fmtIf :: Src -> Int -> NExprLoc -> NExprLoc -> NExprLoc -> Text
fmtIf src i cond then_ else_ =
    let condT = fmtExpr src i cond
        thenInline = fmtExpr src i then_
        elseInline = fmtExpr src i else_
        inline = "if " <> condT <> " then " <> thenInline <> " else " <> elseInline
     in if not (multiline condT) && not (multiline thenInline) && not (multiline elseInline) && fits i inline
            then inline
            else
                "if "
                    <> condT
                    <> " then"
                    <> nl (i + 2)
                    <> fmtExpr src (i + 2) then_
                    <> nl i
                    <> "else"
                    <> nl (i + 2)
                    <> fmtExpr src (i + 2) else_

-- ── lambdas ─────────────────────────────────────────────────────────

fmtAbs :: Src -> Int -> Params NExprLoc -> NExprLoc -> Text
fmtAbs src i params body = paramT <> ": " <> fmtExpr src i body
  where
    paramT = case params of
        Param name -> varNameText name
        ParamSet mName variadic formals ->
            let formalDocs = map fmtFormal formals
                variadicDoc = case variadic of
                    Variadic -> ["..."]
                    _ -> []
                inner = T.intercalate ", " (formalDocs <> variadicDoc)
                setDoc = if T.null inner then "{ }" else "{ " <> inner <> " }"
                atDoc = maybe "" (\n -> "@" <> varNameText n) mName
             in setDoc <> atDoc
    fmtFormal (n, Nothing) = varNameText n
    fmtFormal (n, Just d) = varNameText n <> " ? " <> fmtExpr src i d

-- ── application ─────────────────────────────────────────────────────

fmtApp :: Src -> Int -> NExprLoc -> NExprLoc -> Text
fmtApp src i fun arg = fmtAppFun src i fun <> " " <> fmtArg src i arg

fmtAppFun :: Src -> Int -> NExprLoc -> Text
fmtAppFun src i e@(Fix (Compose (AnnUnit _ inner))) = case inner of
    NAbs _ _ -> paren src i e
    NIf _ _ _ -> paren src i e
    NLet _ _ -> paren src i e
    NWith _ _ -> paren src i e
    NAssert _ _ -> paren src i e
    NBinary _ _ _ -> paren src i e
    NUnary _ _ -> paren src i e
    _ -> fmtF src i inner

fmtArg :: Src -> Int -> NExprLoc -> Text
fmtArg src i e@(Fix (Compose (AnnUnit _ inner))) = case inner of
    NAbs _ _ -> paren src i e
    NApp _ _ -> paren src i e
    NIf _ _ _ -> paren src i e
    NLet _ _ -> paren src i e
    NWith _ _ -> paren src i e
    NAssert _ _ -> paren src i e
    NBinary _ _ _ -> paren src i e
    NUnary _ _ -> paren src i e
    NSelect (Just _) _ _ -> paren src i e
    _ -> fmtF src i inner

-- ── select / hasAttr / binary / unary ──────────────────────────────

fmtSelect :: Src -> Int -> Maybe NExprLoc -> NExprLoc -> NAttrPath NExprLoc -> Text
fmtSelect src i alt base path =
    fmtSelectBase src i base
        <> "."
        <> fmtAttrPath src path
        <> maybe "" (\a -> " or " <> fmtSelectAlt src i a) alt

fmtSelectBase :: Src -> Int -> NExprLoc -> Text
fmtSelectBase src i e@(Fix (Compose (AnnUnit _ inner))) = case inner of
    NApp _ _ -> paren src i e
    NSelect _ _ _ -> paren src i e
    NAbs _ _ -> paren src i e
    NIf _ _ _ -> paren src i e
    NLet _ _ -> paren src i e
    NWith _ _ -> paren src i e
    NAssert _ _ -> paren src i e
    NBinary _ _ _ -> paren src i e
    NUnary _ _ -> paren src i e
    _ -> fmtF src i inner

fmtSelectAlt :: Src -> Int -> NExprLoc -> Text
fmtSelectAlt src i e@(Fix (Compose (AnnUnit _ inner))) = case inner of
    NAbs _ _ -> paren src i e
    NLet _ _ -> paren src i e
    NIf _ _ _ -> paren src i e
    NWith _ _ -> paren src i e
    NAssert _ _ -> paren src i e
    NBinary _ _ _ -> paren src i e
    _ -> fmtF src i inner

fmtBinary :: Src -> Int -> NBinaryOp -> NExprLoc -> NExprLoc -> Text
fmtBinary src i op left right =
    fmtExpr src i left <> " " <> binaryOpText op <> " " <> fmtBinaryArg src i right

fmtBinaryArg :: Src -> Int -> NExprLoc -> Text
fmtBinaryArg src i e@(Fix (Compose (AnnUnit _ inner))) = case inner of
    NAbs _ _ -> paren src i e
    NIf _ _ _ -> paren src i e
    NLet _ _ -> paren src i e
    NWith _ _ -> paren src i e
    NAssert _ _ -> paren src i e
    NBinary _ _ _ -> paren src i e
    NUnary _ _ -> paren src i e
    _ -> fmtF src i inner

fmtUnaryArg :: Src -> Int -> NExprLoc -> Text
fmtUnaryArg src i e@(Fix (Compose (AnnUnit _ inner))) = case inner of
    NBinary _ _ _ -> paren src i e
    NIf _ _ _ -> paren src i e
    NLet _ _ -> paren src i e
    NWith _ _ -> paren src i e
    NAssert _ _ -> paren src i e
    NAbs _ _ -> paren src i e
    _ -> fmtF src i inner

binaryOpText :: NBinaryOp -> Text
binaryOpText = \case
    NEq -> "=="
    NNEq -> "!="
    NLt -> "<"
    NLte -> "<="
    NGt -> ">"
    NGte -> ">="
    NAnd -> "&&"
    NOr -> "||"
    NImpl -> "->"
    NUpdate -> "//"
    NConcat -> "++"
    NPlus -> "+"
    NMinus -> "-"
    NMult -> "*"
    NDiv -> "/"

-- | wrap a sub-expression in parentheses (rendered at the inner column)
paren :: Src -> Int -> NExprLoc -> Text
paren src i e = "(" <> fmtExpr src i e <> ")"

-- ── attribute paths / keys / strings / paths ───────────────────────

fmtAttrPath :: Src -> NAttrPath NExprLoc -> Text
fmtAttrPath src path = T.intercalate "." (map (fmtKeyName src) (NE.toList path))

fmtKeyName :: Src -> NKeyName NExprLoc -> Text
fmtKeyName src = \case
    StaticKey name -> varNameText name
    DynamicKey mk -> case mk of
        Plain str -> fmtString src 0 str
        EscapedNewline -> ""
        Antiquoted e -> "${" <> fmtExpr src 0 e <> "}"

fmtString :: Src -> Int -> NString NExprLoc -> Text
fmtString src i = \case
    DoubleQuoted parts -> "\"" <> T.concat (map (fmtStringPart src) parts) <> "\""
    Indented _ parts ->
        "''"
            <> nl (i + 2)
            <> T.concat (map (fmtIndentedPart src) parts)
            <> nl i
            <> "''"

fmtStringPart :: Src -> Antiquoted Text NExprLoc -> Text
fmtStringPart src = \case
    Plain t -> escapeString t
    Antiquoted e -> "${" <> fmtExpr src 0 e <> "}"
    EscapedNewline -> ""

fmtIndentedPart :: Src -> Antiquoted Text NExprLoc -> Text
fmtIndentedPart src = \case
    Plain t -> escapeIndentedString t
    Antiquoted e -> "${" <> fmtExpr src 0 e <> "}"
    EscapedNewline -> "\\\n"

escapeIndentedString :: Text -> Text
escapeIndentedString = T.replace "$" "''$"

escapeString :: Text -> Text
escapeString = T.concatMap $ \c -> case c of
    '"' -> "\\\""
    '\\' -> "\\\\"
    '$' -> "\\$"
    ch -> T.singleton ch

fmtPath :: Path -> Text
fmtPath (Path p) =
    let pt = T.pack p
     in if "./" `T.isPrefixOf` pt || "/" `T.isPrefixOf` pt
            then pt
            else "./" <> pt

fmtEnvPath :: Path -> Text
fmtEnvPath (Path p) = "<" <> T.pack p <> ">"
