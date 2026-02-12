{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}

-- |
-- Module      : NixCompile.Nix.Pretty
-- Description : Pretty print Nix AST (formatter)
--
-- Implements a standard formatter for Nix code using prettyprinter.
module NixCompile.Nix.Pretty
  ( prettyNix,
  )
where

import Data.Fix (Fix(..))
import qualified Data.List.NonEmpty as NE
import Data.Coerce (coerce)
import Data.Text (Text)
import Nix.Atoms (NAtom(..))
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import NixCompile.Pretty

-- | Pretty print a Nix expression
prettyNix :: NExprLoc -> Doc AnsiStyle
prettyNix (Fix (Compose (AnnUnit _ expr))) = prettyExprF (fmap prettyNix expr)

prettyExprF :: NExprF (Doc AnsiStyle) -> Doc AnsiStyle
prettyExprF = \case
  NConstant atom -> prettyAtom atom
  NStr str -> prettyString str
  NSym name -> prettyName name
  NList [] -> styleMuted "[]"
  NList xs -> 
    group $ vsep
      [ styleMuted "["
      , indent 2 (vsep xs)
      , styleMuted "]"
      ]
  NSet recMode bindings ->
    let recPrefix = case recMode of
          Recursive -> styleKeyword "rec "
          NonRecursive -> ""
    in if null bindings
       then recPrefix <> styleMuted "{}"
       else group $ vsep
              [ recPrefix <> styleMuted "{"
              , indent 2 (vsep (map prettyBinding bindings))
              , styleMuted "}"
              ]
  NLet bindings body ->
    vsep
      [ styleKeyword "let"
      , indent 2 (vsep (map prettyBinding bindings))
      , styleKeyword "in"
      , body
      ]
  NIf cond t f ->
    group $ vsep
      [ styleKeyword "if" <+> cond
      , styleKeyword "then" <+> t
      , styleKeyword "else" <+> f
      ]
  NWith scope body ->
    styleKeyword "with" <+> scope <> styleMuted ";" <+> body
  NAssert cond body ->
    styleKeyword "assert" <+> cond <> styleMuted ";" <+> body
  NAbs params body ->
    prettyParams params <> styleMuted ":" <+> body
  NApp fun arg ->
    -- TODO: handle precedence paren logic
    fun <+> arg
  NSelect alt base path ->
    let pBase = base -- TODO: parens
        pPath = hcat (punctuate dot (map prettyKey (NE.toList path)))
        orAlt = case alt of
          Just d -> space <> styleKeyword "or" <+> d
          Nothing -> mempty
    in pBase <> dot <> pPath <> orAlt
  NHasAttr base path ->
    base <+> styleOperator "?" <+> hcat (punctuate dot (map prettyKey (NE.toList path)))
  NBinary op l r ->
    l <+> prettyOp op <+> r -- TODO: precedence
  NUnary op x ->
    prettyUnaryOp op <> x
  NLiteralPath p -> stylePath (pretty (show p))
  NEnvPath p -> stylePath (pretty ("<" ++ show p ++ ">"))
  NSynHole name -> styleError ("^" <> prettyName name)

prettyAtom :: NAtom -> Doc AnsiStyle
prettyAtom = \case
  NInt n -> styleType (pretty n)
  NFloat f -> styleType (pretty f)
  NBool True -> styleKeyword "true"
  NBool False -> styleKeyword "false"
  NNull -> styleKeyword "null"
  NURI u -> styleString (pretty u)

prettyString :: NString (Doc AnsiStyle) -> Doc AnsiStyle
prettyString = \case
  DoubleQuoted parts -> styleString "\"" <> hcat (map prettyPart parts) <> styleString "\""
  Indented _ parts -> styleString "''" <> line <> hcat (map prettyPart parts) <> styleString "''"
  where
    prettyPart (Plain t) = styleString (pretty t)
    prettyPart EscapedNewline = styleString "\\n"
    prettyPart (Antiquoted e) = styleMuted "${" <> e <> styleMuted "}"

prettyBinding :: Binding (Doc AnsiStyle) -> Doc AnsiStyle
prettyBinding = \case
  NamedVar path expr _pos ->
    let key = hcat (punctuate dot (map prettyKey (NE.toList path)))
    in key <+> equals <+> expr <> styleMuted ";"
  Inherit mscope names _pos ->
    let scopeDoc = maybe "" (\s -> parens s <+> "") mscope
    in styleKeyword "inherit" <+> scopeDoc <> hsep (map prettyName names) <> styleMuted ";"

prettyParams :: Params (Doc AnsiStyle) -> Doc AnsiStyle
prettyParams = \case
  Param name -> prettyName name
  ParamSet mname variadic pset ->
    let items = [ prettyName n <> maybe "" (\val -> styleOperator "?" <+> val) v
                | (n, v) <- pset
                ]
        items' = if variadic == Variadic then items ++ ["..."] else items
        prefix = case mname of
          Just n -> prettyName n <+> symbol "@" <+> ""
          Nothing -> ""
    in prefix <> list items'

prettyKey :: NKeyName (Doc AnsiStyle) -> Doc AnsiStyle
prettyKey = \case
  StaticKey t -> prettyName t
  DynamicKey (Plain t) -> prettyString t -- simplified
  DynamicKey _ -> "${...}"

prettyName :: VarName -> Doc AnsiStyle
prettyName = styleVar . pretty . (coerce :: VarName -> Text)

prettyOp :: NBinaryOp -> Doc AnsiStyle
prettyOp = styleOperator . pretty . show -- Placeholder

prettyUnaryOp :: NUnaryOp -> Doc AnsiStyle
prettyUnaryOp = styleOperator . pretty . show -- Placeholder

styleOperator :: Doc AnsiStyle -> Doc AnsiStyle
styleOperator = annotate (color Yellow)

symbol :: Doc AnsiStyle -> Doc AnsiStyle
symbol = annotate (color Yellow)
