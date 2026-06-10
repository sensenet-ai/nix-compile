{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}

module NixCompile.LSP.Handlers (
  handlers,
  lintFile,
  fullLint,
  toNixDiag,
  nixCode,
  spToDiagnostic,
  NixViolation (..),
  ViolationType (..),
  findExprAt,
  inferExprAt,
  semanticLegend,
)
where

import Control.Applicative ((<|>))
import Control.Concurrent.Async (Async, async, waitCatch)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeException, try)
import Control.Exception qualified as Exc
import Control.Monad.IO.Class (MonadIO (..))
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types
import Language.LSP.Server
import Language.LSP.VFS (virtualFileText)
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types (Binding (..), NExprF (..), NKeyName (..))
import Nix.Expr.Types.Annotated (NExprLoc)
import Nix.Parser (parseNixTextLoc)
import NixCompile.Core.Safety qualified as Safety
import NixCompile.Core.Span (Loc (..), Span (..))
import NixCompile.Inference.Nix (TypeEnv (..), builtinEnv, extendImport, inferExprWithEnv)
import NixCompile.Inference.Nix qualified as Infer
import NixCompile.Inference.Nix.Type qualified as NT
import NixCompile.LSP.Handlers.Cursor (
  childExprs,
  exprName,
  findExprAt,
  inferExprAt,
  inferExprAtWithEnv,
 )
import NixCompile.LSP.Handlers.Diagnostics (
  NixViolation (..),
  ViolationType (..),
  diagnosticsForExpr,
  nixCode,
  spToDiagnostic,
  toNixDiag,
 )
import NixCompile.LSP.ProjectCache qualified as PC
import NixCompile.Layout.Convention (straylight)
import NixCompile.Layout.Graph qualified as Mod
import NixCompile.Layout.ModuleSystem qualified as MS
import NixCompile.Layout.Scope qualified as Scope
import NixCompile.Syntax.Annotation (srcSpanToSpan, varNameText, pattern Layer, pattern LayerAnn)
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.IO.Unsafe (unsafePerformIO)

{-# NOINLINE moduleGraphCache #-}
moduleGraphCache :: MVar (Map.Map FilePath Mod.ModuleGraph)
moduleGraphCache = unsafePerformIO $ newMVar Map.empty

{-# NOINLINE inflightCache #-}

{- | Tracks an in-flight graph build per project root so concurrent requests
don't both rebuild the same graph (Race-A from the audit).
-}
inflightCache :: MVar (Map.Map FilePath (Async (Maybe Mod.ModuleGraph)))
inflightCache = unsafePerformIO $ newMVar Map.empty

{-# NOINLINE projectCacheRef #-}

{- | Per-file, content-addressed project cache. Built lazily and incrementally
in the background; lookups never block. Replaces the all-or-nothing
moduleGraphCache for hover/inlay/completion paths.
-}
projectCacheRef :: MVar (Maybe PC.ProjectCache)
projectCacheRef = unsafePerformIO (newMVar Nothing)

{- | Get the project cache, creating it (and starting workers) the first time.
Subsequent calls return the same cache.
-}
getProjectCache :: IO PC.ProjectCache
getProjectCache = modifyMVar projectCacheRef orCreate
 where
  orCreate (Just pc) = pure (Just pc, pc)
  orCreate Nothing = do
    pc <- PC.newProjectCache
    PC.startWorkers pc
    pure (Just pc, pc)

{- | Parse text inside an LSP handler. Returns Nothing on parse failure,
depth overflow, or stack overflow — handlers respond gracefully instead of
crashing the whole server.
-}
lspSafeParse :: Text -> Maybe NExprLoc
lspSafeParse txt = unsafePerformIO $ do
  -- `evaluate` only forces to WHNF, so a bottom buried in the lazy hnix AST used
  -- to escape this `try` and detonate later when a handler (or `analyzeDepth`,
  -- which ran OUTSIDE the try) forced it. Run the depth walk — which traverses
  -- the whole tree — INSIDE the evaluated thunk so any such bottom is forced, and
  -- therefore caught, here.
  r <- try (Exc.evaluate (parseAndCheck txt))
  pure $ either (\(_ :: SomeException) -> Nothing) id r
 where
  parseAndCheck t = either (const Nothing) checkDepth (parseNixTextLoc t)
  checkDepth e = either (const Nothing) (const (Just e)) (Safety.analyzeDepth e)

handlers :: Handlers (LspM ())
handlers =
  mconcat
    [ notificationHandler SMethod_Initialized initializedHandler
    , notificationHandler SMethod_TextDocumentDidOpen documentOpenHandler
    , notificationHandler SMethod_TextDocumentDidChange documentChangeHandler
    , notificationHandler SMethod_TextDocumentDidSave documentSaveHandler
    , notificationHandler SMethod_TextDocumentDidClose documentCloseHandler
    , requestHandler SMethod_TextDocumentHover hoverHandler
    , requestHandler SMethod_TextDocumentDefinition definitionHandler
    , requestHandler SMethod_TextDocumentRename renameHandler
    , requestHandler SMethod_TextDocumentReferences referencesHandler
    , requestHandler SMethod_TextDocumentCompletion completionHandler
    , requestHandler SMethod_TextDocumentSignatureHelp signatureHelpHandler
    , requestHandler SMethod_TextDocumentCodeAction codeActionHandler
    , requestHandler SMethod_TextDocumentDocumentSymbol documentSymbolHandler
    , requestHandler SMethod_TextDocumentSemanticTokensFull semanticTokensFullHandler
    , requestHandler SMethod_TextDocumentInlayHint inlayHintHandler
    ]

semanticLegend :: SemanticTokensLegend
semanticLegend =
  SemanticTokensLegend
    ["keyword", "function", "variable", "parameter", "type", "string", "number", "property"]
    ["definition", "readonly", "defaultLibrary"]

-- ═══════════════════════ lifecycle ═══════════════════════

initializedHandler :: TNotificationMessage 'Method_Initialized -> LspM () ()
initializedHandler _not = do
  -- Eagerly construct the project cache so its workers are running and
  -- ready to drain enqueued files as soon as the first didOpen lands.
  -- Cheap: just spawns N idle threads.
  _ <- liftIO getProjectCache
  sendNotification SMethod_WindowLogMessage $
    LogMessageParams MessageType_Info "nix-compile LSP — panopticon online"

documentOpenHandler :: TNotificationMessage 'Method_TextDocumentDidOpen -> LspM () ()
documentOpenHandler notif = do
  let TNotificationMessage _ _ (DidOpenTextDocumentParams (TextDocumentItem uri _ _ txt)) = notif
  -- Single-file diagnostics: always available, never blocks.
  let diags = fullLint txt
  sendNotification SMethod_TextDocumentPublishDiagnostics $
    PublishDiagnosticsParams uri Nothing diags
  -- BFS seed: the currently-open file is the highest priority. Workers will
  -- pick it up, expand to its imports, etc. This replaces voidProjectDiags
  -- as the "warm the cache" entry point.
  liftIO $ do
    maybe (pure ()) enqueue (uriToFilePath uri)
    -- Keep the existing flake-graph warm path for now; safe to call in
    -- parallel with the per-file cache.
    voidProjectDiags uri
 where
  enqueue fp = do
    pc <- getProjectCache
    PC.enqueueFile pc fp

documentChangeHandler :: TNotificationMessage 'Method_TextDocumentDidChange -> LspM () ()
documentChangeHandler notif = do
  let TNotificationMessage _ _ params = notif
  let DidChangeTextDocumentParams
        { _textDocument = VersionedTextDocumentIdentifier{_uri = uri}
        , _contentChanges = cs
        } = params
  let txt = firstChangeText cs
  let diags = fullLint txt
  sendNotification SMethod_TextDocumentPublishDiagnostics $
    PublishDiagnosticsParams uri Nothing diags

firstChangeText :: [TextDocumentContentChangeEvent] -> Text
firstChangeText (TextDocumentContentChangeEvent change : _)
  | InL (TextDocumentContentChangePartial _ _ t) <- change = t
  | InR (TextDocumentContentChangeWholeDocument t) <- change = t
firstChangeText _ = ""

documentSaveHandler :: TNotificationMessage 'Method_TextDocumentDidSave -> LspM () ()
documentSaveHandler notif = do
  let TNotificationMessage _ _ (DidSaveTextDocumentParams (TextDocumentIdentifier uri) txt) = notif
  liftIO $ do
    invalidateModuleGraphCache uri
    maybe (pure ()) invalidate (uriToFilePath uri)
  maybe (return ()) (publish uri) txt
 where
  -- Per-file invalidation: the saved file + its reverse-dep closure are
  -- marked Stale; the saved file is re-enqueued for immediate recompute;
  -- reverse-deps recompute lazily when something asks for them.
  invalidate fp = do
    pc <- getProjectCache
    PC.invalidateFile pc fp
  publish uri t = do
    let diags = fullLint t
    sendNotification SMethod_TextDocumentPublishDiagnostics $
      PublishDiagnosticsParams uri Nothing diags
    liftIO $ voidProjectDiags uri

documentCloseHandler :: TNotificationMessage 'Method_TextDocumentDidClose -> LspM () ()
documentCloseHandler notif = do
  let TNotificationMessage _ _ (DidCloseTextDocumentParams (TextDocumentIdentifier uri)) = notif
  sendNotification SMethod_TextDocumentPublishDiagnostics $
    PublishDiagnosticsParams uri Nothing []

-- ═══════════════════════ hover ═══════════════════════

hoverHandler req responder = do
  let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentHover
  let HoverParams textDoc pos _workDone = params
  let TextDocumentIdentifier uri = textDoc
  mvf <- getVirtualFile (toNormalizedUri uri)
  maybe (hover noFile) (withVf uri pos) mvf
 where
  hover markup = responder $ Right $ InL $ Hover{_contents = InL markup, _range = Nothing}
  withVf uri pos vf = maybe (hover parseErr) (withExpr uri pos) (lspSafeParse (virtualFileText vf))
  withExpr uri (Position l c) expr = do
    env <- liftIO $ buildCrossEnv uri
    hover (maybe noExpr (contents env expr l c) (inferExprAtWithEnv env expr (fromIntegral l) (fromIntegral c)))
  noExpr = MarkupContent MarkupKind_Markdown "`no expression at cursor`"
  contents env expr l c t =
    MarkupContent MarkupKind_Markdown ("`: " <> t <> "`" <> optInfo)
   where
    optInfo = maybe "" renderOpt (inferOptionAtPath env expr (fromIntegral l) (fromIntegral c))
    renderOpt oi =
      "\n\n*option* `"
        <> MS.optPath oi
        <> "` : "
        <> NT.prettyType (MS.optType oi)
        <> maybe "" ("\n\n" <>) (MS.optDescription oi)

-- ═══════════════════════ definition ═══════════════════════

definitionHandler req responder = do
  let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentDefinition
  let DefinitionParams textDoc pos _workDone _partialResult = params
  let TextDocumentIdentifier uri = textDoc
  mvf <- getVirtualFile (toNormalizedUri uri)
  maybe nullResp (withExpr uri pos) (mvf >>= lspSafeParse . virtualFileText)
 where
  nullResp = responder $ Right $ InR $ InR Null
  withExpr uri (Position l c) expr = do
    sg <- liftIO $ buildCrossScopeGraphWith uri (Just expr)
    let cursorLine = fromIntegral l + 1; cursorCol = fromIntegral c + 1
    maybe nullResp (resolveRef uri sg) (findRef (cursorLine, cursorCol) sg)
  resolveRef uri sg ref = either (const nullResp) (emitDecl uri) (Scope.resolve sg ref)
  emitDecl uri decl =
    let declUri = maybe uri filePathToUri (Scope.spanFile (Scope.declSpan decl))
        loc =
          Location
            declUri
            ( Range
                (toLspPos (Scope.spanStart (Scope.declSpan decl)))
                (toLspPos (Scope.spanEnd (Scope.declSpan decl)))
            )
     in responder $ Right $ InL (Definition (InL loc))

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

toLspPos :: Scope.SourcePos -> Position
toLspPos sp = Position (fromIntegral (Scope.posLine sp - 1)) (fromIntegral (Scope.posCol sp - 1))

-- ═══════════════════════ rename ═══════════════════════

renameHandler ::
  TRequestMessage 'Method_TextDocumentRename ->
  (Either (TResponseError 'Method_TextDocumentRename) (WorkspaceEdit |? Null) -> LspT () IO ()) ->
  LspM () ()
renameHandler req responder = do
  let TRequestMessage _ _ _ params = req
  let RenameParams _workDone textDoc pos newName = params
  let TextDocumentIdentifier uri = textDoc
  mvf <- getVirtualFile (toNormalizedUri uri)
  maybe nullResp (withExpr uri pos newName) (mvf >>= lspSafeParse . virtualFileText)
 where
  nullResp = responder $ Right $ InR Null
  withExpr uri (Position l c) newName expr =
    let sg = Scope.fromNixExpr Nothing expr
        cl = fromIntegral l + 1
        cc = fromIntegral c + 1
     in maybe nullResp (resolveRef uri sg newName) (findRef (cl, cc) sg)
  resolveRef uri sg newName ref = either (const nullResp) (emitEdit uri sg newName) (Scope.resolve sg ref)
  emitEdit uri sg newName decl =
    let allRefs = Scope.findReferences sg decl
        declEdit =
          TextEdit
            ( Range
                (toLspPos (Scope.spanStart (Scope.declSpan decl)))
                (toLspPos (Scope.spanEnd (Scope.declSpan decl)))
            )
            newName
        refEdits =
          [ TextEdit
              ( Range
                  (toLspPos (Scope.spanStart (Scope.refSpan r)))
                  (toLspPos (Scope.spanEnd (Scope.refSpan r)))
              )
              newName
          | r <- allRefs
          ]
        wsEdit =
          WorkspaceEdit
            { _changes = Just (Map.singleton uri (declEdit : refEdits))
            , _documentChanges = Nothing
            , _changeAnnotations = Nothing
            }
     in responder $ Right $ InL wsEdit

-- ═══════════════════════ references ═══════════════════════

referencesHandler req responder = do
  let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentReferences
  let ReferenceParams textDoc pos _workDone _partialResult _context = params
  let TextDocumentIdentifier uri = textDoc
  mvf <- getVirtualFile (toNormalizedUri uri)
  maybe nullResp (withExpr uri pos) (mvf >>= lspSafeParse . virtualFileText)
 where
  nullResp = responder $ Right $ InR Null
  withExpr uri (Position l c) expr = do
    sg <- liftIO $ buildCrossScopeGraphWith uri (Just expr)
    let cl = fromIntegral l + 1; cc = fromIntegral c + 1
    maybe nullResp (resolveRef uri sg) (findRef (cl, cc) sg)
  resolveRef uri sg ref = either (const nullResp) (emitRefs uri sg) (Scope.resolve sg ref)
  emitRefs uri sg decl =
    let allRefs = Scope.findReferences sg decl
        declLoc =
          Location
            uri
            ( Range
                (toLspPos (Scope.spanStart (Scope.declSpan decl)))
                (toLspPos (Scope.spanEnd (Scope.declSpan decl)))
            )
        refLocs = map (refLoc uri) allRefs
     in responder $ Right $ InL (declLoc : refLocs)
  refLoc uri r =
    let refUri = maybe uri filePathToUri (Scope.spanFile (Scope.refSpan r))
     in Location
          refUri
          ( Range
              (toLspPos (Scope.spanStart (Scope.refSpan r)))
              (toLspPos (Scope.spanEnd (Scope.refSpan r)))
          )

-- ═══════════════════════ completion ═══════════════════════

completionHandler req responder = do
  let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentCompletion
  let CompletionParams textDoc pos _workDone _partialResult _context = params
  let TextDocumentIdentifier uri = textDoc
  mvf <- getVirtualFile (toNormalizedUri uri)
  maybe nullResp (withExpr uri pos) (mvf >>= lspSafeParse . virtualFileText)
 where
  nullResp = responder $ Right $ InR (InR Null)
  withExpr uri (Position l c) expr = do
    env <- liftIO $ buildCrossEnv uri
    let items = completionsForExpr env expr (fromIntegral l) (fromIntegral c)
    responder $ Right $ InL items

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
          [ mkCompletionItem k (Just CompletionItemKind_Property) (Just (NT.prettyType (MS.optType v)))
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
      kind = if "builtins" `T.isPrefixOf` name then CompletionItemKind_Module else CompletionItemKind_Function
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

-- ═══════════════════════ signature help ═══════════════════════

signatureHelpHandler req responder = do
  let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentSignatureHelp
  let SignatureHelpParams{_textDocument = textDoc, _position = pos} = params
  let TextDocumentIdentifier uri = textDoc
  mvf <- getVirtualFile (toNormalizedUri uri)
  maybe nullResp (withExpr uri pos) (mvf >>= lspSafeParse . virtualFileText)
 where
  nullResp = responder $ Right $ InR Null
  withExpr uri (Position l c) expr = do
    env <- liftIO $ buildCrossEnv uri
    maybe nullResp (responder . Right . InL) (signatureAtCursor env expr (fromIntegral l) (fromIntegral c))

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
      paramInfos = [ParameterInformation (InL p) Nothing | (p, i) <- zip params [(0 :: Int) ..], i < (5 :: Int)]
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

codeActionHandler req responder = do
  let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentCodeAction
  let CodeActionParams _workDone _partialResult textDoc range _context = params
  let TextDocumentIdentifier uri = textDoc
  mvf <- getVirtualFile (toNormalizedUri uri)
  maybe nullResp (withVf range) mvf
 where
  nullResp = responder $ Right $ InR Null
  withVf range vf = do
    let txt = virtualFileText vf
        diags = fullLint txt
        inRange = filter (rangeOverlapsDiag range) diags
        actions = concatMap violationAction inRange
    responder $ Right $ InL (map InR actions)

rangeOverlapsDiag :: Range -> Diagnostic -> Bool
rangeOverlapsDiag range (Diagnostic r _ _ _ _ _ _ _ _) =
  let Range (Position rl rc) (Position rel rec) = range
      Range (Position dl dc) _ = r
   in (rl < dl || (rl == dl && rc <= dc)) && (rel > dl || (rel == dl && rec >= dc))

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

-- ═══════════════════════ document symbols ═══════════════════════

documentSymbolHandler req responder = do
  let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentDocumentSymbol
  let DocumentSymbolParams _workDone _partialResult textDoc = params
  let TextDocumentIdentifier uri = textDoc
  mvf <- getVirtualFile (toNormalizedUri uri)
  maybe emptyResp withExpr (mvf >>= lspSafeParse . virtualFileText)
 where
  emptyResp = responder $ Right $ InR (InL [])
  withExpr expr = responder $ Right $ InR (InL (collectTopBindingSymbols expr))

collectTopBindingSymbols :: NExprLoc -> [DocumentSymbol]
collectTopBindingSymbols (Layer (NSet _ bindings)) = concatMap bindingToSymbol bindings
collectTopBindingSymbols (Layer (NAbs _ body)) = collectTopBindingSymbols body
collectTopBindingSymbols (Layer (NLet _ body)) = collectTopBindingSymbols body
collectTopBindingSymbols (Layer (NWith _ body)) = collectTopBindingSymbols body
collectTopBindingSymbols _ = []

bindingToSymbol :: Binding NExprLoc -> [DocumentSymbol]
bindingToSymbol (NamedVar (StaticKey name :| []) expr _) =
  let kind = symKind expr
      sp = exprSpan expr
   in [mkDocumentSymbol (varNameText name) kind sp (childSymbols expr)]
bindingToSymbol (Inherit{}) = []
bindingToSymbol _ = []

exprSpan :: NExprLoc -> Range
exprSpan (LayerAnn srcSpan _) =
  let sp = srcSpanToSpan srcSpan
   in Range
        (Position (fromIntegral (locLine (spanStart sp) - 1)) (fromIntegral (locCol (spanStart sp) - 1)))
        (Position (fromIntegral (locLine (spanEnd sp) - 1)) (fromIntegral (locCol (spanEnd sp) - 1)))

mkDocumentSymbol :: Text -> SymbolKind -> Range -> [DocumentSymbol] -> DocumentSymbol
mkDocumentSymbol name kind range children =
  DocumentSymbol name Nothing kind Nothing Nothing range range (Just children)

symKind :: NExprLoc -> SymbolKind
symKind (Layer (NAbs _ _)) = SymbolKind_Function
symKind (Layer (NSet _ _)) = SymbolKind_Object
symKind (Layer (NList _)) = SymbolKind_Array
symKind (Layer (NStr _)) = SymbolKind_String
symKind (Layer (NConstant (NInt _))) = SymbolKind_Number
symKind (Layer (NConstant (NFloat _))) = SymbolKind_Number
symKind (Layer (NConstant (NBool _))) = SymbolKind_Boolean
symKind (Layer (NApp _ _)) = SymbolKind_Function
symKind _ = SymbolKind_Variable

childSymbols :: NExprLoc -> [DocumentSymbol]
childSymbols (Layer (NSet _ bindings)) = concatMap bindingToSymbol bindings
childSymbols _ = []

-- ═══════════════════════ semantic tokens ═══════════════════════

semanticTokensFullHandler req responder = do
  let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentSemanticTokensFull
  let SemanticTokensParams _workDone _partialResult textDoc = params
  let TextDocumentIdentifier uri = textDoc
  mvf <- getVirtualFile (toNormalizedUri uri)
  maybe nullResp withExpr (mvf >>= lspSafeParse . virtualFileText)
 where
  nullResp = responder $ Right $ InR Null
  withExpr expr = responder $ Right $ InL (semanticTokens expr)

data RawToken = RawToken
  { rtLine :: Int
  , rtCol :: Int
  , rtLen :: Int
  , rtType :: SemanticTokenTypes
  , rtMods :: [SemanticTokenModifiers]
  }
  deriving (Eq, Show)

instance Ord RawToken where
  compare a b = compare (rtLine a, rtCol a) (rtLine b, rtCol b)

semanticTokens :: NExprLoc -> SemanticTokens
semanticTokens expr =
  let raw = collectTokens expr
      sorted = sort raw
      encoded = encToken sorted
   in SemanticTokens Nothing encoded

collectTokens :: NExprLoc -> [RawToken]
collectTokens = go
 where
  go (LayerAnn srcSpan e) =
    let sp = srcSpanToSpan srcSpan
        l = locLine (spanStart sp)
        c = locCol (spanStart sp)
        el = locLine (spanEnd sp)
        ec = locCol (spanEnd sp)
        len = max 1 (if l == el then ec - c else 0)
     in localToken e l c len ++ concatMap go (childExprs e)

  localToken (NSym name) l c len
    | varNameText name `elem` reservedWords = [RawToken l c len SemanticTokenTypes_Keyword []]
    | Map.member (varNameText name) (envBindings builtinEnv) = [RawToken l c len SemanticTokenTypes_Function [SemanticTokenModifiers_DefaultLibrary]]
    | otherwise = [RawToken l c len SemanticTokenTypes_Variable []]
  localToken (NStr _) l c len = [RawToken l c len SemanticTokenTypes_String []]
  localToken (NConstant (NInt _)) l c len = [RawToken l c len SemanticTokenTypes_Number []]
  localToken (NConstant (NFloat _)) l c len = [RawToken l c len SemanticTokenTypes_Number []]
  localToken (NConstant (NBool _)) l c len = [RawToken l c len SemanticTokenTypes_Keyword []]
  localToken (NConstant NNull) l c len = [RawToken l c len SemanticTokenTypes_Keyword []]
  localToken (NLiteralPath _) l c len = [RawToken l c len SemanticTokenTypes_String []]
  localToken (NEnvPath _) l c len = [RawToken l c len SemanticTokenTypes_String []]
  localToken _ _ _ _ = []

reservedWords :: [Text]
reservedWords = ["if", "then", "else", "let", "in", "with", "rec", "inherit", "assert", "import"]

encToken :: [RawToken] -> [UInt]
encToken tokens = go tokens (0, 0) []
 where
  go [] _ acc = reverse acc
  go (t : ts) (prevLine, prevCol) acc =
    let dLine = fromIntegral (rtLine t - prevLine)
        dCol = if rtLine t == prevLine then fromIntegral (rtCol t - prevCol) else fromIntegral (rtCol t)
        tIdx = fromIntegral (tokenTypeIndex (rtType t))
        bits = sum [modifierBit m | m <- rtMods t]
     in go ts (rtLine t, rtCol t) (acc ++ [dLine, dCol, fromIntegral (rtLen t), tIdx, fromIntegral bits])

tokenTypeIndex :: SemanticTokenTypes -> Int
tokenTypeIndex = idx . toEnumBaseType
 where
  idx "keyword" = 0
  idx "function" = 1
  idx "variable" = 2
  idx "parameter" = 3
  idx "type" = 4
  idx "string" = 5
  idx "number" = 6
  idx "property" = 7
  idx _ = 0

modifierBit :: SemanticTokenModifiers -> Int
modifierBit = bit . toEnumBaseType
 where
  bit "definition" = 1
  bit "readonly" = 2
  bit "defaultLibrary" = 4
  bit _ = 0

-- ═══════════════════════ inlay hints ═══════════════════════

inlayHintHandler req responder = do
  let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentInlayHint
  let InlayHintParams _workDone textDoc range = params
  let TextDocumentIdentifier uri = textDoc
  mvf <- getVirtualFile (toNormalizedUri uri)
  maybe nullResp (withExpr uri range) (mvf >>= lspSafeParse . virtualFileText)
 where
  nullResp = responder $ Right $ InR Null
  withExpr uri range expr = do
    env <- liftIO $ buildCrossEnv uri
    responder $ Right $ InL (inlayHintsForExpr env expr range)

inlayHintsForExpr :: TypeEnv -> NExprLoc -> Range -> [InlayHint]
inlayHintsForExpr env expr range = either (const []) withBindings (inferExprWithEnv env expr)
 where
  withBindings (_, bindings) =
    [ InlayHint
        (Position (fromIntegral (locLine (spanStart sp) - 1)) (fromIntegral (locCol (spanEnd sp) + 1)))
        (InL (": " <> NT.prettyType bindType))
        (Just InlayHintKind_Type)
        Nothing
        Nothing
        (Just True)
        Nothing
        Nothing
    | Infer.Binding name bindType sp <- bindings
    , not (T.null name)
    , cursorInRange (Position (fromIntegral (locLine (spanEnd sp) - 1)) (fromIntegral (locCol (spanEnd sp) + 1))) range
    ]

cursorInRange :: Position -> Range -> Bool
cursorInRange (Position l c) (Range (Position rl rc) (Position rel rec)) =
  l >= rl && l <= rel && (l /= rl || c >= rc) && (l /= rel || c <= rec)

-- ═══════════════════════ diagnostics engine ═══════════════════════

fullLint :: Text -> [Diagnostic]
fullLint txt = maybe [] (diagnosticsForExpr "<buffer>") (lspSafeParse txt)

-- ═══════════════════════ project-wide diagnostics ═══════════════════════

{- | Eagerly warm the module-graph cache for the URI's project.
n.b. fixed from review-2 (B5 voidProjectDiags was a no-op stub):
  * actually populates the cache so subsequent hover/definition are warm
  * exception-safe via getOrBuildModuleGraph's try/catch
  * uses the inflight-dedup machinery so we don't race the foreground request
-}
voidProjectDiags :: Uri -> IO ()
voidProjectDiags uri = do
  _ <- async $ do
    _result <- try (getOrBuildModuleGraph uri) :: IO (Either SomeException (Maybe Mod.ModuleGraph))
    pure ()
  pure ()

-- ═══════════════════════ legacy lint ═══════════════════════

lintFile :: Text -> [Diagnostic]
lintFile = fullLint

-- ═══════════════════════ cross-module helpers ═══════════════════════

{- | Maximum number of directory levels to walk up looking for a project root.
n.b. raised from 10 to 64 to handle deeply nested workspaces (B6 from review-2).
-}
projectRootWalkupLimit :: Int
projectRootWalkupLimit = 64

findProjectRoot :: Uri -> IO (Maybe FilePath)
findProjectRoot uri = maybe (pure Nothing) fromPath (uriToFilePath uri)
 where
  fromPath fp = do
    canon <- canonicalizePath fp
    let dir = takeDirectory canon
    findRoot dir projectRootWalkupLimit
  findRoot _ 0 = pure Nothing
  findRoot dir n = do
    let flakePath = dir </> "flake.nix"; configPath = dir </> ".nix-compile.dhall"
    hasFlake <- doesFileExist flakePath
    hasConfig <- doesFileExist configPath
    if hasFlake || hasConfig
      then pure (Just dir)
      else let parent = takeDirectory dir in if parent == dir then pure Nothing else findRoot parent (n - 1)

{- | Build a TypeEnv enriched with cross-module type information.

Order of preference, non-blocking:

  1. Project cache (per-file, content-addressed): consult first. Whatever's
     'Fresh' goes into the env. Stale or missing entries are simply absent;
     the inference engine treats absent imports as opaque and proceeds.
  2. Module-graph cache (legacy, all-or-nothing): used as a backstop only
     when the project cache has nothing useful. This will be removed once
     the per-file cache stabilises.
  3. 'builtinEnv': always.

Crucially, this function never blocks. If the project cache is still warming,
hover/definition still return immediately with single-file precision.
-}
buildCrossEnv :: Uri -> IO TypeEnv
buildCrossEnv uri = do
  pc <- getProjectCache
  snap <- PC.snapshotFiles pc
  let pcEnv =
        Map.foldlWithKey'
          ( \acc fp entry ->
              if PC.feStatus entry == PC.Fresh
                then extendImport fp (PC.feType entry) acc
                else acc
          )
          builtinEnv
          snap
  -- If the per-file cache hasn't produced anything for this project yet,
  -- fall back to the legacy module-graph cache so we don't regress the
  -- first hover.
  if Map.null snap
    then legacyBuildCrossEnv uri
    else pure pcEnv

legacyBuildCrossEnv :: Uri -> IO TypeEnv
legacyBuildCrossEnv uri = do
  mMg <- getOrBuildModuleGraph uri
  maybe (pure builtinEnv) withMg mMg
 where
  withMg mg = pure finalEnv
   where
    canonicalTypes = Mod.mgModuleTypes mg
    baseEnv = builtinEnv{envImportTypes = canonicalTypes}
    finalEnv =
      foldr
        ( \(_, m) acc ->
            foldr
              ( \imp acc' ->
                  let raw = T.unpack (Mod.impRawPath imp)
                   in maybe acc' (\t -> extendImport raw t acc') (Map.lookup (Mod.impPath imp) canonicalTypes)
              )
              acc
              (Mod.modImports m)
        )
        baseEnv
        (Map.toList (Mod.mgModules mg))

buildCrossScopeGraphWith :: Uri -> Maybe NExprLoc -> IO Scope.ScopeGraph
buildCrossScopeGraphWith uri mCurrentExpr = do
  mMg <- getOrBuildModuleGraph uri
  maybe (pure Scope.empty) withMg mMg
 where
  withMg mg =
    let exprs = Map.map Mod.modExpr (Mod.mgModules mg)
        currentFile = uriToFilePath uri
        exprs' = maybe exprs (\(f, e) -> Map.insert f e exprs) ((,) <$> currentFile <*> mCurrentExpr)
     in pure $ Scope.fromModuleGraph exprs'

{- | Look up or build the module graph for a project root.
n.b. fixes from review-2:
  * exception-safe (catches StackOverflow from hnix, IO errors)
  * in-flight dedup: concurrent requests share a single build
  * negative cache via try @SomeException so a failing build doesn't loop
-}
getOrBuildModuleGraph :: Uri -> IO (Maybe Mod.ModuleGraph)
getOrBuildModuleGraph uri = do
  mRoot <- findProjectRoot uri
  maybe (pure Nothing) withRoot mRoot
 where
  withRoot root = do
    cache <- readMVar moduleGraphCache
    maybe (joinOrStartBuild root) (pure . Just) (Map.lookup root cache)

joinOrStartBuild :: FilePath -> IO (Maybe Mod.ModuleGraph)
joinOrStartBuild root = do
  -- Check inflight or claim it atomically; whoever wins starts the build.
  action <- modifyMVar inflightCache claim
  let asyncHandle = either id id action
  waitResult <- waitCatch asyncHandle
  -- Clean up inflight entry no matter what.
  modifyMVar_ inflightCache (pure . Map.delete root)
  either (const (pure Nothing)) pure waitResult
 where
  -- Check inflight or claim it atomically; whoever wins starts the build.
  claim m = maybe (start m) (\a -> pure (m, Right a)) (Map.lookup root m)
  start m = do
    a <- async (startBuild root)
    pure (Map.insert root a m, Left a)

startBuild :: FilePath -> IO (Maybe Mod.ModuleGraph)
startBuild root = do
  let flakePath = root </> "flake.nix"
  hasFlake <- doesFileExist flakePath
  if not hasFlake
    then pure Nothing
    else do
      -- Catch every exception: hnix parser stack overflow, IO errors,
      -- whatever buildModuleGraph might throw beyond its Either return.
      outcome <- try (Mod.buildModuleGraph straylight flakePath)
      either (const (pure Nothing)) (either (const (pure Nothing)) cacheIt) (outcome :: Either SomeException (Either Text Mod.ModuleGraph))
 where
  cacheIt mg = do
    modifyMVar moduleGraphCache (\m -> pure (Map.insert root mg m, ()))
    pure (Just mg)

{- | Invalidate the module-graph cache for the project containing the given URI.
n.b. fixed from review-2: invalidate on ANY save in the project, not just flake.nix.
-}
invalidateModuleGraphCache :: Uri -> IO ()
invalidateModuleGraphCache uri = do
  mRoot <- findProjectRoot uri
  maybe (pure ()) (\root -> modifyMVar_ moduleGraphCache (pure . Map.delete root)) mRoot

inferOptionAtPath :: TypeEnv -> NExprLoc -> Int -> Int -> Maybe MS.OptionInfo
inferOptionAtPath _env expr l c = do
  target <- findExprAt l c expr
  let name = exprName target; opts = MS.extractOptions expr
  name >>= (`Map.lookup` opts)

noFile :: MarkupContent
noFile = MarkupContent MarkupKind_Markdown "`no file`"

parseErr :: MarkupContent
parseErr = MarkupContent MarkupKind_Markdown "`parse error`"
