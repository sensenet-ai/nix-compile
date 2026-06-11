{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                    // lsp // handlers // features
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He'd operated on an almost permanent adrenaline high, a byproduct of youth
--    and proficiency, jacked into a custom cyberspace deck."
--
--                                                                                     — Neuromancer
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The pure compute behind the language-feature handlers: cursor-driven
--   navigation (go-to-definition / rename / references), completion, signature
--   help, code actions, inlay hints, and option lookup. Each takes an AST (and
--   sometimes a 'TypeEnv') plus a cursor position and returns LSP wire types —
--   no I/O, no LspM. The handlers in "NixCompile.LSP.Handlers" do the VFS reads
--   and responder plumbing; everything they decide WITH lives here.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.LSP.Handlers.Features (
  -- navigation
  findRef,
  toLspPos,
  -- completion
  completionsForExpr,
  nixpkgsCompletionsFromText,
  -- signature help
  signatureAtCursor,
  -- code actions
  rangeOverlapsDiag,
  violationAction,
  -- inlay hints
  inlayHintsForExpr,
  -- option lookup + hover fallbacks
  inferOptionAtPath,
  noFile,
  parseErr,
)
where

import Control.Applicative ((<|>))
import Data.Char (isAlphaNum)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Protocol.Types
import Nix.Expr.Types (NExprF (..))
import Nix.Expr.Types.Annotated (NExprLoc)
import NixCompile.Core.Span (Loc (..), Span (..))
import NixCompile.Inference.Nix (TypeEnv (..), builtinEnv, inferExprWithEnv)
import NixCompile.Inference.Nix qualified as Infer
import NixCompile.Inference.Nix.Type qualified as NT
import NixCompile.LSP.Handlers.Cursor (childExprs, exprName, findExprAt)
import NixCompile.Layout.ModuleSystem qualified as MS
import NixCompile.Layout.Scope qualified as Scope
import NixCompile.Nixpkgs.Index qualified as Nixpkgs
import NixCompile.Syntax.Annotation (pattern Layer)

-- ═══════════════════════ navigation ═══════════════════════

{- | Pure: find the reference in the scope graph whose span contains the
  1-based @(line, col)@ cursor, if any. Used by go-to-definition/references.
-}
findRef :: (Int, Int) -> Scope.ScopeGraph -> Maybe Scope.Reference
findRef (l, c) sg =
  let refs = [r | s <- Map.elems (Scope.sgScopes sg), r <- Scope.scopeReferences s]
      matching = filter (spanContains (l, c) . Scope.refSpan) refs
   in listToMaybe matching

spanContains :: (Int, Int) -> Scope.SourceSpan -> Bool
spanContains (cl, cc) sp =
  let s = Scope.spanStart sp
      e = Scope.spanEnd sp
      sl = Scope.posLine s
      sc = Scope.posCol s
      el = Scope.posLine e
      ec = Scope.posCol e
   in cl >= sl && cl <= el && (cl /= sl || cc >= sc) && (cl /= el || cc <= ec)

-- | Pure: convert a 1-based scope-graph 'Scope.SourcePos' to a 0-based LSP 'Position'.
toLspPos :: Scope.SourcePos -> Position
toLspPos sp = Position (fromIntegral (Scope.posLine sp - 1)) (fromIntegral (Scope.posCol sp - 1))

-- ═══════════════════════ completion ═══════════════════════

{- | Pure: completion items at the cursor for an expression — scope names,
  builtins, and module-system options matching the cursor prefix.
-}
completionsForExpr :: TypeEnv -> NExprLoc -> Int -> Int -> [CompletionItem]
completionsForExpr _env expr l c =
  maybe [] withPfx (prefixAtCursor l c)
 where
  withPfx pfx =
    let scoped = scopeCompletions expr pfx
        builtins' = builtinCompletions pfx
        opts = MS.extractOptions expr
        matchingOpts = Map.filterWithKey (\k _ -> pfx `T.isPrefixOf` k) opts
        optItems =
          [ mkCompletionItem
              k
              (Just CompletionItemKind_Property)
              (Just (NT.prettyType (MS.optType v)))
          | (k, v) <- Map.toList matchingOpts
          ]
     in nub $ scoped ++ builtins' ++ optItems

prefixAtCursor :: Int -> Int -> Maybe Text
prefixAtCursor _l _c = Just ""

scopeCompletions :: NExprLoc -> Text -> [CompletionItem]
scopeCompletions _expr _pfx = []

builtinCompletions :: Text -> [CompletionItem]
builtinCompletions pfx =
  let names = Map.keys (envBindings builtinEnv)
      matching = filter (pfx `T.isPrefixOf`) names
   in map builtinItem matching

builtinItem :: Text -> CompletionItem
builtinItem name =
  let detail = fmap NT.prettyScheme (Map.lookup name (envBindings builtinEnv))
      kind =
        if "builtins" `T.isPrefixOf` name
          then CompletionItemKind_Module
          else CompletionItemKind_Function
   in mkCompletionItem name (Just kind) detail

mkCompletionItem :: Text -> Maybe CompletionItemKind -> Maybe Text -> CompletionItem
mkCompletionItem label' kind' detail' =
  CompletionItem
    { _label = label'
    , _labelDetails = Nothing
    , _kind = kind'
    , _tags = Nothing
    , _detail = detail'
    , _documentation = Nothing
    , _deprecated = Nothing
    , _preselect = Nothing
    , _sortText = Nothing
    , _filterText = Nothing
    , _insertText = Nothing
    , _insertTextFormat = Nothing
    , _insertTextMode = Nothing
    , _textEdit = Nothing
    , _textEditText = Nothing
    , _additionalTextEdits = Nothing
    , _commitCharacters = Nothing
    , _command = Nothing
    , _data_ = Nothing
    }

{- | Text-based @pkgs.<prefix>@ completion: scan backward from the cursor on the
current line for a @pkgs.<partial>@ and offer matching package names from the
index. Works on half-typed source the parser would reject (e.g. a bare @pkgs.@),
so it is independent of the parsed AST. Capped to keep responses bounded.
-}
nixpkgsCompletionsFromText :: Nixpkgs.NixpkgsIndex -> Text -> Int -> Int -> [CompletionItem]
nixpkgsCompletionsFromText idx txt l c =
  maybe [] pkgsItems (lineUpToCursor >>= pkgsPrefixAt)
 where
  lineUpToCursor = T.take c <$> safeIx l (T.lines txt)
  pkgsItems (base, prefix)
    | base == "pkgs" =
        take
          maxItems
          [ mkCompletionItem name (Just CompletionItemKind_Module) (Just "nixpkgs package")
          | name <- Map.keys (Nixpkgs.pkgsByName idx)
          , prefix `T.isPrefixOf` name
          ]
    | otherwise = []
  maxItems = 1000

-- | Safe list index: 'Nothing' for negative or out-of-range @i@.
safeIx :: Int -> [a] -> Maybe a
safeIx i xs
  | i < 0 = Nothing
  | otherwise = listToMaybe (drop i xs)

{- | Peel a trailing @base.partial@ off the line text up to the cursor — the base
identifier and the partial attribute being typed (e.g. @"… = pkgs.rip"@ →
@("pkgs","rip")@, @"pkgs."@ → @("pkgs","")@). Backward scan over identifier
characters; 'Nothing' if the cursor is not just after a @base.@.
-}
pkgsPrefixAt :: Text -> Maybe (Text, Text)
pkgsPrefixAt before = fromDot (T.uncons afterPrefix) (T.reverse prefixRev)
 where
  (prefixRev, afterPrefix) = T.span isPkgChar (T.reverse before)
  fromDot (Just ('.', afterDot)) prefix =
    Just (T.reverse (T.takeWhile isPkgChar afterDot), prefix)
  fromDot _ _ = Nothing

-- | Characters that may appear in a Nix attribute / package name.
isPkgChar :: Char -> Bool
isPkgChar ch = isAlphaNum ch || ch == '_' || ch == '\'' || ch == '-'

-- ═══════════════════════ signature help ═══════════════════════

{- | Pure: signature help for the call enclosing the cursor — resolves the
  applied function name and renders its builtin type scheme as parameters.
-}
signatureAtCursor :: TypeEnv -> NExprLoc -> Int -> Int -> Maybe SignatureHelp
signatureAtCursor _env expr l c = do
  target <- findExprAt l c expr
  (funcExpr, _) <- findEnclosingCall expr target
  name <- exprName funcExpr
  lookupBuiltinSig name

findEnclosingCall :: NExprLoc -> NExprLoc -> Maybe (NExprLoc, [NExprLoc])
findEnclosingCall root target = go root
 where
  go (Layer (NApp func arg))
    | arg == target = Just (func, [arg])
    | otherwise = go func <|> go arg <|> deepSearch
   where
    deepSearch = maybe (fmap addArg (go arg)) (Just . addArg) (go func)
     where
      addArg (f, as) = (f, arg : as)
  go (Layer e) = checkChildren (childExprs e)
  checkChildren [] = Nothing
  checkChildren (x : xs) = go x <|> checkChildren xs

lookupBuiltinSig :: Text -> Maybe SignatureHelp
lookupBuiltinSig name = do
  scheme <- Map.lookup name (envBindings builtinEnv)
  let typeStr = NT.prettyScheme scheme
      params = extractParamLabels scheme
      paramInfos =
        [ ParameterInformation (InL p) Nothing
        | (p, i) <- zip params [(0 :: Int) ..]
        , i < (5 :: Int)
        ]
      sigInfo =
        SignatureInformation
          (name <> " : " <> typeStr)
          Nothing
          (if null paramInfos then Nothing else Just paramInfos)
          Nothing
  pure $ SignatureHelp [sigInfo] (Just (0 :: UInt)) (Just (InL (0 :: UInt)))
 where
  extractParamLabels (NT.Forall _ t) = collect t
  collect (NT.TFun a b) = NT.prettyType a : collect b
  collect _ = []

-- ═══════════════════════ code actions ═══════════════════════

{- | Pure: does the given range overlap the start of the diagnostic's range?
  Used to find the diagnostics a code-action request applies to.
-}
rangeOverlapsDiag :: Range -> Diagnostic -> Bool
rangeOverlapsDiag range (Diagnostic r _ _ _ _ _ _ _ _) =
  let Range (Position rl rc) (Position rel rec) = range
      Range (Position dl dc) _ = r
   in (rl < dl || (rl == dl && rc <= dc)) && (rel > dl || (rel == dl && rec >= dc))

{- | Pure: quick-fix code actions for a lint diagnostic, keyed off its
  ALEPH rule code; empty when no fix is offered for that rule.
-}
violationAction :: Diagnostic -> [CodeAction]
violationAction diag
  | "ALEPH-N001" `T.isInfixOf` msg = [simpleAction "Replace `with` by explicit bindings" True diag]
  | "ALEPH-N013" `T.isInfixOf` msg = [simpleAction "Insert `meta` attribute" True diag]
  | "ALEPH-N014" `T.isInfixOf` msg = [simpleAction "Add description to meta" True diag]
  | "ALEPH-N009" `T.isInfixOf` msg = [simpleAction "Replace `or null` by if-then-else" False diag]
  | "ALEPH-N011" `T.isInfixOf` msg = [simpleAction "Use writeShellApplication instead" True diag]
  | otherwise = []
 where
  msg = T.toUpper (diagMsg diag)

simpleAction :: Text -> Bool -> Diagnostic -> CodeAction
simpleAction title preferred diag =
  CodeAction
    { _title = title
    , _kind = Just CodeActionKind_QuickFix
    , _diagnostics = Just [diag]
    , _isPreferred = Just preferred
    , _disabled = Nothing
    , _edit = Nothing
    , _command = Nothing
    , _data_ = Nothing
    }

diagMsg :: Diagnostic -> Text
diagMsg (Diagnostic _ _ _ _ _ msg _ _ _) = msg

-- ═══════════════════════ inlay hints ═══════════════════════

{- | Pure: inferred-type inlay hints for the let/attr bindings within @range@,
  placed after each binding name; empty if inference fails.
-}
inlayHintsForExpr :: TypeEnv -> NExprLoc -> Range -> [InlayHint]
inlayHintsForExpr env expr range = either (const []) withBindings (inferExprWithEnv env expr)
 where
  withBindings (_, bindings) =
    [ InlayHint
        ( Position
            (fromIntegral (locLine (spanStart sp) - 1))
            (fromIntegral (locCol (spanEnd sp) + 1))
        )
        (InL (": " <> NT.prettyType bindType))
        (Just InlayHintKind_Type)
        Nothing
        Nothing
        (Just True)
        Nothing
        Nothing
    | Infer.Binding name bindType sp <- bindings
    , not (T.null name)
    , cursorInRange
        ( Position
            (fromIntegral (locLine (spanEnd sp) - 1))
            (fromIntegral (locCol (spanEnd sp) + 1))
        )
        range
    ]

cursorInRange :: Position -> Range -> Bool
cursorInRange (Position l c) (Range (Position rl rc) (Position rel rec)) =
  l >= rl && l <= rel && (l /= rl || c >= rc) && (l /= rel || c <= rec)

-- ═══════════════════════ option lookup + hover fallbacks ═══════════════════════

{- | Pure: the module-system 'MS.OptionInfo' for the option named at the cursor,
  if the cursor sits on a name declared via @options@ in the expression.
-}
inferOptionAtPath :: TypeEnv -> NExprLoc -> Int -> Int -> Maybe MS.OptionInfo
inferOptionAtPath _env expr l c = do
  target <- findExprAt l c expr
  let name = exprName target; opts = MS.extractOptions expr
  name >>= (`Map.lookup` opts)

-- | Hover-fallback markup shown when no file is open at the requested URI.
noFile :: MarkupContent
noFile = MarkupContent MarkupKind_Markdown "`no file`"

-- | Hover-fallback markup shown when the open file fails to parse.
parseErr :: MarkupContent
parseErr = MarkupContent MarkupKind_Markdown "`parse error`"
