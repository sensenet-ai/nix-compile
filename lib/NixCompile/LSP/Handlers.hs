-- yellow: lsp-types promoted 'Method_* symbols only (see HOUSE_STYLE)
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
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

import Control.Exception (SomeException, try)
import Control.Exception qualified as Exc
import Control.Monad.IO.Class (MonadIO (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types
import Language.LSP.Server
import Language.LSP.VFS (virtualFileText)
import Nix.Expr.Types.Annotated (NExprLoc)
import Nix.Parser (parseNixTextLoc)
import NixCompile.Core.Safety qualified as Safety
import NixCompile.Inference.Nix.Type qualified as NT
import NixCompile.LSP.Handlers.Cursor (
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
import NixCompile.LSP.Handlers.Features (
  completionsForExpr,
  findRef,
  inferOptionAtPath,
  inlayHintsForExpr,
  noFile,
  parseErr,
  rangeOverlapsDiag,
  signatureAtCursor,
  toLspPos,
  violationAction,
 )
import NixCompile.LSP.Handlers.Project (
  buildCrossEnv,
  buildCrossScopeGraphWith,
  getProjectCache,
  invalidateModuleGraphCache,
  voidProjectDiags,
 )
import NixCompile.LSP.Handlers.SemanticTokens (semanticLegend, semanticTokens)
import NixCompile.LSP.Handlers.Symbols (collectTopBindingSymbols)
import NixCompile.LSP.ProjectCache qualified as PC
import NixCompile.Layout.ModuleSystem qualified as MS
import NixCompile.Layout.Scope qualified as Scope
import System.IO.Unsafe (unsafePerformIO)

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

-- ═══════════════════════ diagnostics engine ═══════════════════════

fullLint :: Text -> [Diagnostic]
fullLint txt = maybe [] (diagnosticsForExpr "<buffer>") (lspSafeParse txt)

-- ═══════════════════════ legacy lint ═══════════════════════

lintFile :: Text -> [Diagnostic]
lintFile = fullLint
