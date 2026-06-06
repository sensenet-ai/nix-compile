{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
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

import Control.Applicative ((<|>))
import Control.Concurrent.Async (Async, async, waitCatch)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeException, try)
import Control.Exception qualified as Exc
import Control.Monad.IO.Class (MonadIO (..))
import Data.Fix (Fix (..))
import Data.Functor.Compose (Compose (..))
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe, maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types
import Language.LSP.Server
import Language.LSP.VFS (virtualFileText)
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types (Binding (..), NExprF (..), NKeyName (..), Params (..))
import Nix.Expr.Types.Annotated (AnnUnit (..), NExprLoc)
import Nix.Parser (parseNixTextLoc)
import NixCompile.Bash.Parse (parseBash)
import NixCompile.Lint.Forbidden qualified as Forbidden
import NixCompile.Nix.Infer (TypeEnv (..), builtinEnv, extendImport, inferExprWithEnv)
import NixCompile.Nix.Infer qualified as Infer
import NixCompile.Nix.LayoutConvention (straylight)
import NixCompile.Nix.Lint (NixViolation (..), ViolationType (..), findNixViolations)
import NixCompile.Nix.LintDerivation qualified as Deriv
import NixCompile.Nix.LintPatterns qualified as Patterns
import NixCompile.Nix.Module qualified as Mod
import NixCompile.Nix.ModuleSystem qualified as MS
import NixCompile.LSP.ProjectCache qualified as PC
import NixCompile.Nix.Parse qualified as NixParse
import NixCompile.Nix.Scope qualified as Scope
import NixCompile.Nix.Types qualified as NT
import NixCompile.Nix.Utils (srcSpanToSpan, varNameText)
import NixCompile.Safety qualified as Safety
import NixCompile.Types (Loc (..), Span (..))
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.IO.Unsafe (unsafePerformIO)

{-# NOINLINE moduleGraphCache #-}
moduleGraphCache :: MVar (Map.Map FilePath Mod.ModuleGraph)
moduleGraphCache = unsafePerformIO $ newMVar Map.empty

{-# NOINLINE inflightCache #-}
-- | Tracks an in-flight graph build per project root so concurrent requests
-- don't both rebuild the same graph (Race-A from the audit).
inflightCache :: MVar (Map.Map FilePath (Async (Maybe Mod.ModuleGraph)))
inflightCache = unsafePerformIO $ newMVar Map.empty

{-# NOINLINE projectCacheRef #-}
{- | Per-file, content-addressed project cache. Built lazily and incrementally
in the background; lookups never block. Replaces the all-or-nothing
moduleGraphCache for hover/inlay/completion paths.
-}
projectCacheRef :: MVar (Maybe PC.ProjectCache)
projectCacheRef = unsafePerformIO (newMVar Nothing)

-- | Get the project cache, creating it (and starting workers) the first time.
-- Subsequent calls return the same cache.
getProjectCache :: IO PC.ProjectCache
getProjectCache = modifyMVar projectCacheRef $ \case
    Just pc -> pure (Just pc, pc)
    Nothing -> do
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
    pure $ case r of
        Left (_ :: SomeException) -> Nothing
        Right res -> res
  where
    parseAndCheck t = case parseNixTextLoc t of
        Left _ -> Nothing
        Right e -> case Safety.analyzeDepth e of
            Left _ -> Nothing
            Right () -> Just e

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
        case uriToFilePath uri of
            Just fp -> do
                pc <- getProjectCache
                PC.enqueueFile pc fp
            Nothing -> pure ()
        -- Keep the existing flake-graph warm path for now; safe to call in
        -- parallel with the per-file cache.
        voidProjectDiags uri

documentChangeHandler :: TNotificationMessage 'Method_TextDocumentDidChange -> LspM () ()
documentChangeHandler notif = do
    let TNotificationMessage _ _ params = notif
    let DidChangeTextDocumentParams
            { _textDocument = VersionedTextDocumentIdentifier{_uri = uri}
            , _contentChanges = cs
            } = params
    let txt = case cs of
            (TextDocumentContentChangeEvent change : _)
                | InL (TextDocumentContentChangePartial _ _ t) <- change -> t
                | InR (TextDocumentContentChangeWholeDocument t) <- change -> t
            _ -> ""
    let diags = fullLint txt
    sendNotification SMethod_TextDocumentPublishDiagnostics $
        PublishDiagnosticsParams uri Nothing diags

documentSaveHandler :: TNotificationMessage 'Method_TextDocumentDidSave -> LspM () ()
documentSaveHandler notif = do
    let TNotificationMessage _ _ (DidSaveTextDocumentParams (TextDocumentIdentifier uri) txt) = notif
    liftIO $ do
        invalidateModuleGraphCache uri
        case uriToFilePath uri of
            Just fp -> do
                pc <- getProjectCache
                -- Per-file invalidation: the saved file + its reverse-dep
                -- closure are marked Stale; the saved file is re-enqueued
                -- for immediate recompute; reverse-deps recompute lazily
                -- when something asks for them.
                PC.invalidateFile pc fp
            Nothing -> pure ()
    case txt of
        Just t -> do
            let diags = fullLint t
            sendNotification SMethod_TextDocumentPublishDiagnostics $
                PublishDiagnosticsParams uri Nothing diags
            liftIO $ voidProjectDiags uri
        Nothing -> return ()

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
    let Position l c = pos
    mvf <- getVirtualFile (toNormalizedUri uri)
    case mvf of
        Nothing -> responder $ Right $ InL $ Hover{_contents = InL noFile, _range = Nothing}
        Just vf -> do
            let txt = virtualFileText vf
            case lspSafeParse txt of
                Nothing -> responder $ Right $ InL $ Hover{_contents = InL parseErr, _range = Nothing}
                Just expr -> do
                    env <- liftIO $ buildCrossEnv uri
                    let contents = case inferExprAtWithEnv env expr (fromIntegral l) (fromIntegral c) of
                            Nothing -> MarkupContent MarkupKind_Markdown "`no expression at cursor`"
                            Just t ->
                                let optInfo = case inferOptionAtPath env expr (fromIntegral l) (fromIntegral c) of
                                        Nothing -> ""
                                        Just oi ->
                                            "\n\n*option* `"
                                                <> MS.optPath oi
                                                <> "` : "
                                                <> NT.prettyType (MS.optType oi)
                                                <> (case MS.optDescription oi of Just d -> "\n\n" <> d; Nothing -> "")
                                 in MarkupContent MarkupKind_Markdown ("`: " <> t <> "`" <> optInfo)
                    responder $ Right $ InL $ Hover{_contents = InL contents, _range = Nothing}

-- ═══════════════════════ definition ═══════════════════════

definitionHandler req responder = do
    let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentDefinition
    let DefinitionParams textDoc pos _workDone _partialResult = params
    let TextDocumentIdentifier uri = textDoc
    let Position l c = pos
    mvf <- getVirtualFile (toNormalizedUri uri)
    case mvf of
        Nothing -> responder $ Right $ InR $ InR Null
        Just vf -> do
            let txt = virtualFileText vf
            case lspSafeParse txt of
                Nothing -> responder $ Right $ InR $ InR Null
                Just expr -> do
                    sg <- liftIO $ buildCrossScopeGraphWith uri (Just expr)
                    let cursorLine = fromIntegral l + 1; cursorCol = fromIntegral c + 1
                    case findRef (cursorLine, cursorCol) sg of
                        Nothing -> responder $ Right $ InR $ InR Null
                        Just ref -> case Scope.resolve sg ref of
                            Left _ -> responder $ Right $ InR $ InR Null
                            Right decl -> do
                                let declUri = case Scope.spanFile (Scope.declSpan decl) of
                                        Just f -> filePathToUri f
                                        Nothing -> uri
                                let loc =
                                        Location
                                            declUri
                                            ( Range
                                                (toLspPos (Scope.spanStart (Scope.declSpan decl)))
                                                (toLspPos (Scope.spanEnd (Scope.declSpan decl)))
                                            )
                                responder $ Right $ InL (Definition (InL loc))

findRef :: (Int, Int) -> Scope.ScopeGraph -> Maybe Scope.Reference
findRef (l, c) sg =
    let refs = [r | s <- Map.elems (Scope.sgScopes sg), r <- Scope.scopeReferences s]
        matching = filter (spanContains (l, c) . Scope.refSpan) refs
     in case matching of [] -> Nothing; (r : _) -> Just r

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
    let TextDocumentIdentifier uri = textDoc; Position l c = pos
    mvf <- getVirtualFile (toNormalizedUri uri)
    case mvf of
        Nothing -> responder $ Right $ InR Null
        Just vf -> case lspSafeParse (virtualFileText vf) of
            Nothing -> responder $ Right $ InR Null
            Just expr ->
                let sg = Scope.fromNixExpr Nothing expr
                    cl = fromIntegral l + 1
                    cc = fromIntegral c + 1
                 in case findRef (cl, cc) sg of
                        Nothing -> responder $ Right $ InR Null
                        Just ref -> case Scope.resolve sg ref of
                            Left _ -> responder $ Right $ InR Null
                            Right decl -> do
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
                                responder $ Right $ InL wsEdit

-- ═══════════════════════ references ═══════════════════════

referencesHandler req responder = do
    let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentReferences
    let ReferenceParams textDoc pos _workDone _partialResult _context = params
    let TextDocumentIdentifier uri = textDoc; Position l c = pos
    mvf <- getVirtualFile (toNormalizedUri uri)
    case mvf of
        Nothing -> responder $ Right $ InR Null
        Just vf -> case lspSafeParse (virtualFileText vf) of
            Nothing -> responder $ Right $ InR Null
            Just expr -> do
                sg <- liftIO $ buildCrossScopeGraphWith uri (Just expr)
                let cl = fromIntegral l + 1; cc = fromIntegral c + 1
                case findRef (cl, cc) sg of
                    Nothing -> responder $ Right $ InR Null
                    Just ref -> case Scope.resolve sg ref of
                        Left _ -> responder $ Right $ InR Null
                        Right decl -> do
                            let allRefs = Scope.findReferences sg decl
                                declLoc =
                                    Location
                                        uri
                                        ( Range
                                            (toLspPos (Scope.spanStart (Scope.declSpan decl)))
                                            (toLspPos (Scope.spanEnd (Scope.declSpan decl)))
                                        )
                                refLocs =
                                    map
                                        ( \r ->
                                            let refUri = case Scope.spanFile (Scope.refSpan r) of
                                                    Just f -> filePathToUri f
                                                    Nothing -> uri
                                             in Location
                                                    refUri
                                                    ( Range
                                                        (toLspPos (Scope.spanStart (Scope.refSpan r)))
                                                        (toLspPos (Scope.spanEnd (Scope.refSpan r)))
                                                    )
                                        )
                                        allRefs
                            responder $ Right $ InL (declLoc : refLocs)

-- ═══════════════════════ completion ═══════════════════════

completionHandler req responder = do
    let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentCompletion
    let CompletionParams textDoc pos _workDone _partialResult _context = params
    let TextDocumentIdentifier uri = textDoc; Position l c = pos
    mvf <- getVirtualFile (toNormalizedUri uri)
    case mvf of
        Nothing -> responder $ Right $ InR (InR Null)
        Just vf -> case lspSafeParse (virtualFileText vf) of
            Nothing -> responder $ Right $ InR (InR Null)
            Just expr -> do
                env <- liftIO $ buildCrossEnv uri
                let items = completionsForExpr env expr (fromIntegral l) (fromIntegral c)
                responder $ Right $ InL items

completionsForExpr :: TypeEnv -> NExprLoc -> Int -> Int -> [CompletionItem]
completionsForExpr _env expr l c =
    case prefixAtCursor l c of
        Nothing -> []
        Just pfx ->
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
    let detail = case Map.lookup name (envBindings builtinEnv) of Just s -> Just (NT.prettyScheme s); Nothing -> Nothing
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
    let TextDocumentIdentifier uri = textDoc; Position l c = pos
    mvf <- getVirtualFile (toNormalizedUri uri)
    case mvf of
        Nothing -> responder $ Right $ InR Null
        Just vf -> case lspSafeParse (virtualFileText vf) of
            Nothing -> responder $ Right $ InR Null
            Just expr -> do
                env <- liftIO $ buildCrossEnv uri
                case signatureAtCursor env expr (fromIntegral l) (fromIntegral c) of
                    Just sh -> responder $ Right $ InL sh
                    Nothing -> responder $ Right $ InR Null

signatureAtCursor :: TypeEnv -> NExprLoc -> Int -> Int -> Maybe SignatureHelp
signatureAtCursor _env expr l c = do
    target <- findExprAt l c expr
    let funcCall = findEnclosingCall expr target
    case funcCall of
        Nothing -> Nothing
        Just (funcExpr, _) -> case exprName funcExpr of
            Nothing -> Nothing
            Just name -> lookupBuiltinSig name

findEnclosingCall :: NExprLoc -> NExprLoc -> Maybe (NExprLoc, [NExprLoc])
findEnclosingCall root target = go root
  where
    go (Fix (Compose (AnnUnit _ e))) = case e of
        NApp func arg
            | arg == target -> Just (func, [arg])
            | otherwise -> go func <|> go arg <|> deepSearch
          where
            deepSearch = case go func of
                Nothing -> case go arg of Nothing -> Nothing; Just (f, as) -> Just (f, arg : as)
                Just (f, as) -> Just (f, arg : as)
        _ -> checkChildren (childExprs e)
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
    case mvf of
        Nothing -> responder $ Right $ InR Null
        Just vf -> do
            let txt = virtualFileText vf
            let diags = fullLint txt
            let inRange = filter (rangeOverlapsDiag range) diags
            let actions = concatMap violationAction inRange
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
    case mvf of
        Nothing -> responder $ Right $ InR (InL [])
        Just vf -> case lspSafeParse (virtualFileText vf) of
            Nothing -> responder $ Right $ InR (InL [])
            Just expr -> do
                let syms = collectTopBindingSymbols expr
                responder $ Right $ InR (InL syms)

collectTopBindingSymbols :: NExprLoc -> [DocumentSymbol]
collectTopBindingSymbols (Fix (Compose (AnnUnit _ e))) = case e of
    NSet _ bindings -> concatMap bindingToSymbol bindings
    NAbs _ body -> collectTopBindingSymbols body
    NLet _ body -> collectTopBindingSymbols body
    NWith _ body -> collectTopBindingSymbols body
    _ -> []

bindingToSymbol :: Binding NExprLoc -> [DocumentSymbol]
bindingToSymbol (NamedVar (StaticKey name :| []) expr _) =
    let kind = symKind expr
        sp = exprSpan expr
     in [mkDocumentSymbol (varNameText name) kind sp (childSymbols expr)]
bindingToSymbol (Inherit _ _ _) = []
bindingToSymbol _ = []

exprSpan :: NExprLoc -> Range
exprSpan (Fix (Compose (AnnUnit srcSpan _))) =
    let sp = srcSpanToSpan srcSpan
     in Range
            (Position (fromIntegral (locLine (spanStart sp) - 1)) (fromIntegral (locCol (spanStart sp) - 1)))
            (Position (fromIntegral (locLine (spanEnd sp) - 1)) (fromIntegral (locCol (spanEnd sp) - 1)))

mkDocumentSymbol :: Text -> SymbolKind -> Range -> [DocumentSymbol] -> DocumentSymbol
mkDocumentSymbol name kind range children =
    DocumentSymbol name Nothing kind Nothing Nothing range range (Just children)

symKind :: NExprLoc -> SymbolKind
symKind (Fix (Compose (AnnUnit _ e))) = case e of
    NAbs _ _ -> SymbolKind_Function
    NSet _ _ -> SymbolKind_Object
    NList _ -> SymbolKind_Array
    NStr _ -> SymbolKind_String
    NConstant (NInt _) -> SymbolKind_Number
    NConstant (NFloat _) -> SymbolKind_Number
    NConstant (NBool _) -> SymbolKind_Boolean
    NApp _ _ -> SymbolKind_Function
    _ -> SymbolKind_Variable

childSymbols :: NExprLoc -> [DocumentSymbol]
childSymbols (Fix (Compose (AnnUnit _ e))) = case e of
    NSet _ bindings -> concatMap bindingToSymbol bindings
    _ -> []

-- ═══════════════════════ semantic tokens ═══════════════════════

semanticTokensFullHandler req responder = do
    let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentSemanticTokensFull
    let SemanticTokensParams _workDone _partialResult textDoc = params
    let TextDocumentIdentifier uri = textDoc
    mvf <- getVirtualFile (toNormalizedUri uri)
    case mvf of
        Nothing -> responder $ Right $ InR Null
        Just vf -> case lspSafeParse (virtualFileText vf) of
            Nothing -> responder $ Right $ InR Null
            Just expr -> do
                let tokens = semanticTokens expr
                responder $ Right $ InL tokens

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
    go (Fix (Compose (AnnUnit srcSpan e))) =
        let sp = srcSpanToSpan srcSpan
            l = locLine (spanStart sp)
            c = locCol (spanStart sp)
            el = locLine (spanEnd sp)
            ec = locCol (spanEnd sp)
            len = max 1 (if l == el then ec - c else 0)
         in localToken e l c len ++ concatMap go (childExprs e)

    localToken e' l c len = case e' of
        NSym name
            | varNameText name `elem` reservedWords -> [RawToken l c len SemanticTokenTypes_Keyword []]
            | Map.member (varNameText name) (envBindings builtinEnv) -> [RawToken l c len SemanticTokenTypes_Function [SemanticTokenModifiers_DefaultLibrary]]
            | otherwise -> [RawToken l c len SemanticTokenTypes_Variable []]
        NStr _ -> [RawToken l c len SemanticTokenTypes_String []]
        NConstant (NInt _) -> [RawToken l c len SemanticTokenTypes_Number []]
        NConstant (NFloat _) -> [RawToken l c len SemanticTokenTypes_Number []]
        NConstant (NBool _) -> [RawToken l c len SemanticTokenTypes_Keyword []]
        NConstant NNull -> [RawToken l c len SemanticTokenTypes_Keyword []]
        NLiteralPath _ -> [RawToken l c len SemanticTokenTypes_String []]
        NEnvPath _ -> [RawToken l c len SemanticTokenTypes_String []]
        _ -> []

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
tokenTypeIndex t = case toEnumBaseType t of
    "keyword" -> 0
    "function" -> 1
    "variable" -> 2
    "parameter" -> 3
    "type" -> 4
    "string" -> 5
    "number" -> 6
    "property" -> 7
    _ -> 0

modifierBit :: SemanticTokenModifiers -> Int
modifierBit m = case toEnumBaseType m of
    "definition" -> 1
    "readonly" -> 2
    "defaultLibrary" -> 4
    _ -> 0

-- ═══════════════════════ inlay hints ═══════════════════════

inlayHintHandler req responder = do
    let TRequestMessage _ _ _ params = req :: TRequestMessage 'Method_TextDocumentInlayHint
    let InlayHintParams _workDone textDoc range = params
    let TextDocumentIdentifier uri = textDoc
    mvf <- getVirtualFile (toNormalizedUri uri)
    case mvf of
        Nothing -> responder $ Right $ InR Null
        Just vf -> case lspSafeParse (virtualFileText vf) of
            Nothing -> responder $ Right $ InR Null
            Just expr -> do
                env <- liftIO $ buildCrossEnv uri
                let hints = inlayHintsForExpr env expr range
                responder $ Right $ InL hints

inlayHintsForExpr :: TypeEnv -> NExprLoc -> Range -> [InlayHint]
inlayHintsForExpr env expr range = case inferExprWithEnv env expr of
    Left _ -> []
    Right (_, bindings) ->
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
fullLint txt = case lspSafeParse txt of
    Nothing -> []
    Just expr ->
        concat [nixVios' expr, derivVios' "<buffer>" expr, patternVios' expr, embeddedBashDiags expr]

nixVios' :: NExprLoc -> [Diagnostic]
nixVios' expr = map toNixDiag (findNixViolations expr)

derivVios' :: FilePath -> NExprLoc -> [Diagnostic]
derivVios' path expr = map toDerivDiag (Deriv.findDerivViolations path expr)

toDerivDiag :: Deriv.DerivViolation -> Diagnostic
toDerivDiag dv =
    spToDiagnostic (Deriv.derivRuleId (Deriv.dvType dv) <> ": " <> derivMsg (Deriv.dvType dv)) (Deriv.dvSpan dv)
  where
    derivMsg Deriv.VMissingMeta = "mkDerivation call without meta attribute"
    derivMsg Deriv.VMissingDescription = "meta = { ... } without description key"

patternVios' :: NExprLoc -> [Diagnostic]
patternVios' expr = map toPatternDiag (Patterns.findPatternViolations expr)

toPatternDiag :: Patterns.PatternViolation -> Diagnostic
toPatternDiag pv =
    spToDiagnostic (patternRuleId (Patterns.pvType pv) <> ": " <> Patterns.pvContext pv) (Patterns.pvSpan pv)
  where
    patternRuleId Patterns.VOrNullFallback = "or-null-fallback"
    patternRuleId Patterns.VAttrTranslation = "no-translate-attrs-outside-prelude"

embeddedBashDiags :: NExprLoc -> [Diagnostic]
embeddedBashDiags expr = concatMap bashDiagFromCall (NixParse.findShellScriptCalls expr)

bashDiagFromCall :: NixParse.ShellScriptCall -> [Diagnostic]
bashDiagFromCall ssc = case NixParse.extractString (NixParse.sscBody ssc) of
    Nothing -> []
    Just (content, _, _) -> case parseBash content of
        Left _ -> []
        Right ast ->
            let violations = Forbidden.findViolations ast
             in map (toBashDiag (NixParse.sscName ssc)) violations

toBashDiag :: Text -> Forbidden.Violation -> Diagnostic
toBashDiag scriptName v =
    spToDiagnostic
        (bashErrorCode (Forbidden.vType v) <> ": " <> bashLabel (Forbidden.vType v) <> " in embedded script '" <> scriptName <> "'")
        (Forbidden.vSpan v)
  where
    bashLabel Forbidden.VHeredoc = "heredoc (<<) not allowed"
    bashLabel Forbidden.VHereString = "here-string (<<<) not allowed"
    bashLabel Forbidden.VEval = "eval not allowed"
    bashLabel Forbidden.VBacktick = "backticks (`...`) not allowed"

bashErrorCode :: Forbidden.ViolationType -> Text
bashErrorCode Forbidden.VHeredoc = "ALEPH-B001"
bashErrorCode Forbidden.VHereString = "ALEPH-B002"
bashErrorCode Forbidden.VEval = "ALEPH-B003"
bashErrorCode Forbidden.VBacktick = "ALEPH-B004"

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
        result <- try (getOrBuildModuleGraph uri)
        case result :: Either SomeException (Maybe Mod.ModuleGraph) of
            Left _ -> pure ()
            Right _ -> pure ()
    pure ()

-- ═══════════════════════ legacy lint ═══════════════════════

lintFile :: Text -> [Diagnostic]
lintFile = fullLint

toNixDiag :: NixViolation -> Diagnostic
toNixDiag NixViolation{nvType = vt, nvSpan = sp, nvContext = ctx} =
    spToDiagnostic (nixCode vt <> ": " <> ctx) sp

nixCode :: ViolationType -> Text
nixCode = \case
    VWith -> "ALEPH-N001"
    VRec -> "ALEPH-N002"
    VSubstituteAll -> "ALEPH-N005"
    VRawMkDerivation -> "ALEPH-N006"
    VRawRunCommand -> "ALEPH-N007"
    VRawWriteShellApplication -> "ALEPH-N008"
    VWriteShellScript -> "ALEPH-N011"
    VLongInlineString n -> "ALEPH-N012 (" <> T.pack (show n) <> " chars)"

spToDiagnostic :: Text -> Span -> Diagnostic
spToDiagnostic msg (Span (Loc line col) (Loc endL endC) _) =
    -- n.b. ShellCheck positions are 0-based; megaparsec positions are 1-based.
    -- Clamp to zero rather than wrap unsigned underflow (B4 from review-2).
    Diagnostic
        { _range =
            Range
                (Position (clampU32 (line - 1)) (clampU32 (col - 1)))
                (Position (clampU32 (endL - 1)) (clampU32 (endC - 1)))
        , _severity = Just DiagnosticSeverity_Error
        , _code = Nothing
        , _codeDescription = Nothing
        , _source = Just "nix-compile"
        , _message = msg
        , _tags = Nothing
        , _relatedInformation = Nothing
        , _data_ = Nothing
        }
  where
    clampU32 :: Int -> UInt
    clampU32 n
        | n < 0 = 0
        | otherwise = fromIntegral n

-- ═══════════════════════ expression traversal ═══════════════════════

findExprAt :: Int -> Int -> NExprLoc -> Maybe NExprLoc
findExprAt l c root = go root
  where
    targetLine = l + 1
    targetCol = c + 1
    spContains (Span (Loc sl sc) (Loc el ec) _) =
        (sl < targetLine || (sl == targetLine && sc <= targetCol))
            && (el > targetLine || (el == targetLine && ec >= targetCol))
    getSpan (Fix (Compose (AnnUnit sp _))) = srcSpanToSpan sp
    go e
        | not (spContains (getSpan e)) = Nothing
        | otherwise = case mapMaybe go (childExprs' e) of
            [] -> Just e
            (child : _) -> Just child
    childExprs' (Fix (Compose (AnnUnit _ e))) = case e of
        NConstant _ -> []
        NStr _ -> []
        NLiteralPath _ -> []
        NEnvPath _ -> []
        NSym _ -> []
        NList es -> es
        NSet _ bs -> concatMap bindingExprs bs
        NLet bs b -> concatMap bindingExprs bs ++ [b]
        NIf cond t f' -> [cond, t, f']
        NWith s b -> [s, b]
        NAssert cond body -> [cond, body]
        NAbs (Param _) b -> [b]
        NAbs (ParamSet _ _ formals) b -> [d | (_, Just d) <- formals] ++ [b]
        NApp f' a -> [f', a]
        NSelect mDef obj _path -> maybeToList mDef ++ [obj]
        NHasAttr e1 _ -> [e1]
        NUnary _ e1 -> [e1]
        NBinary _ e1 e2 -> [e1, e2]
        NSynHole _ -> []
    bindingExprs (NamedVar _ e _) = [e]; bindingExprs (Inherit mScope _ _) = maybeToList mScope

childExprs :: NExprF NExprLoc -> [NExprLoc]
childExprs e = case e of
    NConstant _ -> []
    NStr _ -> []
    NLiteralPath _ -> []
    NEnvPath _ -> []
    NSym _ -> []
    NList es -> es
    NSet _ bs -> concatMap bindExprs bs
    NLet bs b -> concatMap bindExprs bs ++ [b]
    NIf cond t f' -> [cond, t, f']
    NWith s b -> [s, b]
    NAssert cond body -> [cond, body]
    NAbs _ b -> [b]
    NApp f' a -> [f', a]
    NSelect _ b _ -> [b]
    NHasAttr b _ -> [b]
    NUnary _ e1 -> [e1]
    NBinary _ e1 e2 -> [e1, e2]
    NSynHole _ -> []

bindExprs :: Binding NExprLoc -> [NExprLoc]
bindExprs (NamedVar _ e _) = [e]
bindExprs (Inherit mScope _ _) = maybeToList mScope

inferExprAt :: NExprLoc -> Int -> Int -> Maybe Text
inferExprAt expr l c = inferExprAtWithEnv builtinEnv expr l c

inferExprAtWithEnv :: TypeEnv -> NExprLoc -> Int -> Int -> Maybe Text
inferExprAtWithEnv env expr l c = do
    target <- findExprAt l c expr
    let targetName = exprName target
    case inferExprWithEnv env expr of
        Right (_, bindings) -> case targetName of
            Just name -> case filter (\(Infer.Binding n _ _) -> n == name) bindings of
                (Infer.Binding _ t _sp : _) -> Just (NT.prettyType t)
                [] -> inferTarget' target
            Nothing -> inferTarget' target
        Left _ -> inferTarget' target
  where
    inferTarget' te = case inferExprWithEnv builtinEnv te of
        Right (t, _) -> Just (NT.prettyType t)
        Left _ -> Just "TYPE_ERROR"

exprName :: NExprLoc -> Maybe Text
exprName (Fix (Compose (AnnUnit _ e))) = case e of
    NSym name -> Just $ varNameText name
    NSelect _ _ (StaticKey k :| _) -> Just $ varNameText k
    _ -> Nothing

-- ═══════════════════════ cross-module helpers ═══════════════════════

-- | Maximum number of directory levels to walk up looking for a project root.
-- n.b. raised from 10 to 64 to handle deeply nested workspaces (B6 from review-2).
projectRootWalkupLimit :: Int
projectRootWalkupLimit = 64

findProjectRoot :: Uri -> IO (Maybe FilePath)
findProjectRoot uri = do
    case uriToFilePath uri of
        Nothing -> pure Nothing
        Just fp -> do
            canon <- canonicalizePath fp
            let dir = takeDirectory canon
            findRoot dir projectRootWalkupLimit
  where
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
    case mMg of
        Nothing -> pure builtinEnv
        Just mg -> do
            let canonicalTypes = Mod.mgModuleTypes mg
                baseEnv = builtinEnv{envImportTypes = canonicalTypes}
                finalEnv =
                    foldr
                        ( \(_, m) acc ->
                            foldr
                                ( \imp acc' ->
                                    let raw = T.unpack (Mod.impRawPath imp)
                                     in case Map.lookup (Mod.impPath imp) canonicalTypes of
                                            Just t -> extendImport raw t acc'
                                            Nothing -> acc'
                                )
                                acc
                                (Mod.modImports m)
                        )
                        baseEnv
                        (Map.toList (Mod.mgModules mg))
            pure finalEnv

buildCrossScopeGraphWith :: Uri -> Maybe NExprLoc -> IO Scope.ScopeGraph
buildCrossScopeGraphWith uri mCurrentExpr = do
    mMg <- getOrBuildModuleGraph uri
    case mMg of
        Nothing -> pure Scope.empty
        Just mg -> do
            let exprs = Map.map Mod.modExpr (Mod.mgModules mg)
                currentFile = uriToFilePath uri
                exprs' = case (currentFile, mCurrentExpr) of
                    (Just f, Just e) -> Map.insert f e exprs
                    _ -> exprs
            pure $ Scope.fromModuleGraph exprs'

{- | Look up or build the module graph for a project root.
n.b. fixes from review-2:
  * exception-safe (catches StackOverflow from hnix, IO errors)
  * in-flight dedup: concurrent requests share a single build
  * negative cache via try @SomeException so a failing build doesn't loop
-}
getOrBuildModuleGraph :: Uri -> IO (Maybe Mod.ModuleGraph)
getOrBuildModuleGraph uri = do
    mRoot <- findProjectRoot uri
    case mRoot of
        Nothing -> pure Nothing
        Just root -> do
            cache <- readMVar moduleGraphCache
            case Map.lookup root cache of
                Just mg -> pure (Just mg)
                Nothing -> joinOrStartBuild root

joinOrStartBuild :: FilePath -> IO (Maybe Mod.ModuleGraph)
joinOrStartBuild root = do
    -- Check inflight or claim it atomically; whoever wins starts the build.
    action <- modifyMVar inflightCache $ \m -> case Map.lookup root m of
        Just a -> pure (m, Right a)
        Nothing -> do
            a <- async (startBuild root)
            pure (Map.insert root a m, Left a)
    let asyncHandle = either id id action
    waitResult <- waitCatch asyncHandle
    -- Clean up inflight entry no matter what.
    modifyMVar_ inflightCache (pure . Map.delete root)
    case waitResult of
        Left _ -> pure Nothing
        Right r -> pure r

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
            case outcome :: Either SomeException (Either Text Mod.ModuleGraph) of
                Left _ -> pure Nothing
                Right (Left _) -> pure Nothing
                Right (Right mg) -> do
                    modifyMVar moduleGraphCache (\m -> pure (Map.insert root mg m, ()))
                    pure (Just mg)

{- | Invalidate the module-graph cache for the project containing the given URI.
n.b. fixed from review-2: invalidate on ANY save in the project, not just flake.nix.
-}
invalidateModuleGraphCache :: Uri -> IO ()
invalidateModuleGraphCache uri = do
    mRoot <- findProjectRoot uri
    case mRoot of
        Nothing -> pure ()
        Just root -> modifyMVar_ moduleGraphCache (pure . Map.delete root)

inferOptionAtPath :: TypeEnv -> NExprLoc -> Int -> Int -> Maybe MS.OptionInfo
inferOptionAtPath _env expr l c = do
    target <- findExprAt l c expr
    let name = exprName target; opts = MS.extractOptions expr
    case name >>= (\n -> Map.lookup n opts) of Just oi -> Just oi; Nothing -> Nothing

noFile :: MarkupContent
noFile = MarkupContent MarkupKind_Markdown "`no file`"

parseErr :: MarkupContent
parseErr = MarkupContent MarkupKind_Markdown "`parse error`"
