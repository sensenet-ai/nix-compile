{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                       // lsp // handlers
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "As the night came on, Turner found the edge again. It seemed like a
--    long time since he'd been there, but when it clicked in, it was like
--    he'd never left. It was that superhuman synchromesh flow that stimulants
--    only approximated. He could only score for it on the site of a major
--    defection, one where he was in command, and then only in the final hours
--    before the actual move."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                               // lsp // request // handlers
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.LSP.Handlers (
    handlers,
    lintFile,
    toNixDiag,
    nixCode,
    spToDiagnostic,
    NixViolation (..),
    ViolationType (..),
    findExprAt,
    inferExprAt,
)
where

import Data.Fix (Fix (..))
import Data.Functor.Compose (Compose (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe, maybeToList)
import Data.Text qualified as T
import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types
import Language.LSP.Server
import Language.LSP.VFS (virtualFileText)
import Nix.Expr.Types (Binding (..), NExprF (..), Params (..))
import Nix.Expr.Types.Annotated (AnnUnit (..), NExprLoc)
import Nix.Parser (parseNixTextLoc)
import NixCompile.Nix.Infer qualified as Infer
import NixCompile.Nix.Lint (NixViolation (..), ViolationType (..), findNixViolations)
import NixCompile.Nix.Scope qualified as Scope
import NixCompile.Nix.Types qualified as NT
import NixCompile.Nix.Utils (srcSpanToSpan)
import NixCompile.Types (Loc (..), Span (..))

-- ── LSP handler registry ──────────────────────────────────────────
handlers :: Handlers (LspM ())
handlers =
    mconcat
        [ notificationHandler SMethod_Initialized initializedHandler
        , notificationHandler SMethod_TextDocumentDidOpen documentOpenHandler
        , notificationHandler SMethod_TextDocumentDidChange documentChangeHandler
        , notificationHandler SMethod_TextDocumentDidSave documentSaveHandler
        , requestHandler SMethod_TextDocumentHover hoverHandler
        , requestHandler SMethod_TextDocumentDefinition definitionHandler
        , requestHandler SMethod_TextDocumentRename renameHandler
        ]

-- ── document lifecycle ────────────────────────────────────────────
-- these fire on every open/change/save and must be fast

initializedHandler :: TNotificationMessage 'Method_Initialized -> LspM () ()
-- n.b. single ack message, no virtual file access needed
initializedHandler _not =
    sendNotification SMethod_WindowLogMessage $
        LogMessageParams MessageType_Info "nix-compile LSP ready"

documentOpenHandler :: TNotificationMessage 'Method_TextDocumentDidOpen -> LspM () ()
-- full re-lint on open; the file text comes directly in the notification
documentOpenHandler notif = do
    let TNotificationMessage _ _ (DidOpenTextDocumentParams (TextDocumentItem uri _ _ txt)) = notif
    let diags = lintFile txt
    sendNotification SMethod_TextDocumentPublishDiagnostics $
        PublishDiagnosticsParams uri Nothing diags

documentChangeHandler :: TNotificationMessage 'Method_TextDocumentDidChange -> LspM () ()
-- incremental or full changes; we grab the last (or only) content change
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
    let diags = lintFile txt
    sendNotification SMethod_TextDocumentPublishDiagnostics $
        PublishDiagnosticsParams uri Nothing diags

documentSaveHandler :: TNotificationMessage 'Method_TextDocumentDidSave -> LspM () ()
-- n.b. the save notification may omit the text payload; re-lint only when present
documentSaveHandler notif = do
    let TNotificationMessage _ _ (DidSaveTextDocumentParams (TextDocumentIdentifier uri) txt) = notif
    case txt of
        Just t -> do
            let diags = lintFile t
            sendNotification SMethod_TextDocumentPublishDiagnostics $
                PublishDiagnosticsParams uri Nothing diags
        Nothing -> return ()

-- ── workspace queries ─────────────────────────────────────────────
-- these are user-initiated and can afford to be slower

hoverHandler req responder = do
    let TRequestMessage _ _ _ params = req
    let HoverParams textDoc pos _workDone = params
    let TextDocumentIdentifier uri = textDoc
    let Position l c = pos
    mvf <- getVirtualFile (toNormalizedUri uri)
    case mvf of
        Nothing -> responder $ Right $ InL $ Hover{_contents = InL noFile, _range = Nothing}
        Just vf -> do
            let txt = virtualFileText vf
            case parseNixTextLoc txt of
                Left _ -> responder $ Right $ InL $ Hover{_contents = InL parseErr, _range = Nothing}
                Right expr ->
                    let contents = case inferExprAt expr (fromIntegral l) (fromIntegral c) of
                            Nothing -> MarkupContent MarkupKind_Markdown "`no expression at cursor`"
                            Just t -> MarkupContent MarkupKind_Markdown ("`: " <> t <> "`")
                     in responder $ Right $ InL $ Hover{_contents = InL contents, _range = Nothing}

definitionHandler req responder = do
    let TRequestMessage _ _ _ params = req
    let DefinitionParams textDoc pos _workDone _partialResult = params
    let TextDocumentIdentifier uri = textDoc
    let Position l c = pos
    mvf <- getVirtualFile (toNormalizedUri uri)
    case mvf of
        Nothing -> responder $ Right $ InR $ InR Null
        Just vf -> do
            let txt = virtualFileText vf
            case parseNixTextLoc txt of
                Left _ -> responder $ Right $ InR $ InR Null
                Right expr ->
                    let sg = Scope.fromNixExpr Nothing expr
                        cursorLine = fromIntegral l + 1
                        cursorCol = fromIntegral c + 1
                     in case findRef (cursorLine, cursorCol) sg of
                            Nothing -> responder $ Right $ InR $ InR Null
                            Just ref -> case Scope.resolve sg ref of
                                Left _ -> responder $ Right $ InR $ InR Null
                                Right decl ->
                                    let loc = toLspLocation uri (Scope.declSpan decl)
                                     in responder $ Right $ InL (Definition (InL loc))

-- ── reference helpers ─────────────────────────────────────────────

findRef :: (Int, Int) -> Scope.ScopeGraph -> Maybe Scope.Reference
findRef (l, c) sg =
    let refs =
            [ r
            | s <- Map.elems (Scope.sgScopes sg)
            , r <- Scope.scopeReferences s
            ]
        matching = filter (spanContains (l, c) . Scope.refSpan) refs
     in case matching of
            [] -> Nothing
            (r : _) -> Just r

spanContains :: (Int, Int) -> Scope.SourceSpan -> Bool
spanContains (cursorLine, cursorCol) sp =
    let start = Scope.spanStart sp
        end = Scope.spanEnd sp
        sl = Scope.posLine start
        sc = Scope.posCol start
        el = Scope.posLine end
        ec = Scope.posCol end
     in cursorLine >= sl
            && cursorLine <= el
            && (cursorLine /= sl || cursorCol >= sc)
            && (cursorLine /= el || cursorCol <= ec)

toLspLocation :: Uri -> Scope.SourceSpan -> Location
toLspLocation uri sp =
    Location
        uri
        (Range (toLspPos (Scope.spanStart sp)) (toLspPos (Scope.spanEnd sp)))

toLspPos :: Scope.SourcePos -> Position
toLspPos sp =
    Position
        (fromIntegral (Scope.posLine sp - 1))
        (fromIntegral (Scope.posCol sp - 1))

-- ── rename handler ────────────────────────────────────────────────
-- n.b. this resolves all references to a declaration and builds a WorkspaceEdit
renameHandler ::
    TRequestMessage 'Method_TextDocumentRename ->
    (Either (TResponseError 'Method_TextDocumentRename) (WorkspaceEdit |? Null) -> LspT () IO ()) ->
    LspM () ()
renameHandler req responder = do
    let TRequestMessage _ _ _ params = req
    let RenameParams _workDone textDoc pos newName = params
    let TextDocumentIdentifier uri = textDoc
    let Position l c = pos
    mvf <- getVirtualFile (toNormalizedUri uri)
    renameWithVF mvf l c newName uri
  where
    renameWithVF Nothing _ _ _ _ = responder $ Right $ InR Null
    renameWithVF (Just vf) l_ c_ newName_ uri_ = renameInFile vf l_ c_ newName_ uri_

    renameInFile vf l_ c_ newName_ uri_
        | Right expr <- parseNixTextLoc (virtualFileText vf) = renameInExpr expr l_ c_ newName_ uri_
        | otherwise = responder $ Right $ InR Null

    renameInExpr expr l_ c_ newName_ uri_
        | Just ref <- findRef (cursorLine, cursorCol) sg = resolveAndRename sg ref newName_ uri_
        | otherwise = responder $ Right $ InR Null
      where
        sg = Scope.fromNixExpr Nothing expr
        cursorLine = fromIntegral l_ + 1
        cursorCol = fromIntegral c_ + 1

    resolveAndRename sg ref newName_ uri_
        | Right decl <- Scope.resolve sg ref = doRename sg decl newName_ uri_
        | otherwise = responder $ Right $ InR Null

    doRename sg decl newName_ uri_ =
        let allRefs = Scope.findReferences sg decl
            declEdit =
                TextEdit
                    (Range (toLspPos (Scope.spanStart (Scope.declSpan decl))) (toLspPos (Scope.spanEnd (Scope.declSpan decl))))
                    newName_
            refEdits =
                [ TextEdit
                    (Range (toLspPos (Scope.spanStart (Scope.refSpan r))) (toLspPos (Scope.spanEnd (Scope.refSpan r))))
                    newName_
                | r <- allRefs
                ]
            wsEdit =
                WorkspaceEdit
                    { _changes = Just (Map.singleton uri_ (declEdit : refEdits))
                    , _documentChanges = Nothing
                    , _changeAnnotations = Nothing
                    }
         in responder $ Right $ InL wsEdit

-- ── hover display constants ───────────────────────────────────────

noFile :: MarkupContent
noFile = MarkupContent MarkupKind_Markdown "`no file`"

parseErr :: MarkupContent
parseErr = MarkupContent MarkupKind_Markdown "`parse error`"

-- ── expression tree traversal ─────────────────────────────────────

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
        | otherwise =
            case mapMaybe go (subExprs e) of
                [] -> Just e
                (child : _) -> Just child

    subExprs (Fix (Compose (AnnUnit _ e))) = case e of
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
        NAbs (ParamSet _ _ formals) b ->
            [d | (_, Just d) <- formals] ++ [b]
        NApp f' a -> [f', a]
        NSelect mDef obj _path -> maybeToList mDef ++ [obj]
        NHasAttr e1 _ -> [e1]
        NUnary _ e1 -> [e1]
        NBinary _ e1 e2 -> [e1, e2]
        NSynHole _ -> []

    bindingExprs (NamedVar _ e _) = [e]
    bindingExprs (Inherit mScope _ _) = maybeToList mScope

inferExprAt :: NExprLoc -> Int -> Int -> Maybe T.Text
-- n.b. wraps Infer.inferExpr to produce a display-friendly type string (or "TYPE_ERROR")
inferExprAt expr l c = do
    target <- findExprAt l c expr
    case Infer.inferExpr target of
        Right (t, _) -> Just (NT.prettyType t)
        Left _ -> Just "TYPE_ERROR"

-- ── diagnostics ───────────────────────────────────────────────────

lintFile :: T.Text -> [Diagnostic]
-- parse-and-lint; returns empty on parse failure since we can't lint garbage
lintFile txt =
    case parseNixTextLoc txt of
        Left _ -> []
        Right expr ->
            map toNixDiag (findNixViolations expr)

toNixDiag :: NixViolation -> Diagnostic
toNixDiag NixViolation{nvType = vt, nvSpan = sp, nvContext = ctx} =
    spToDiagnostic (nixCode vt <> ": " <> ctx) sp

nixCode :: ViolationType -> T.Text
nixCode = \case
    VWith -> "ALEPH-N001"
    VRec -> "ALEPH-N002"
    VSubstituteAll -> "ALEPH-N005"
    VRawMkDerivation -> "ALEPH-N006"
    VRawRunCommand -> "ALEPH-N007"
    VRawWriteShellApplication -> "ALEPH-N008"
    VWriteShellScript -> "ALEPH-N011"
    VLongInlineString n -> "ALEPH-N012 (" <> T.pack (show n) <> " chars)"

spToDiagnostic :: T.Text -> Span -> Diagnostic
spToDiagnostic msg (Span (Loc line col) (Loc endL endC) _)
    | line <= 0 && col <= 0 =
        Diagnostic
            { _range = Range (Position 0 0) (Position 0 0)
            , _severity = Just DiagnosticSeverity_Error
            , _code = Nothing
            , _codeDescription = Nothing
            , _source = Just "nix-compile"
            , _message = msg
            , _tags = Nothing
            , _relatedInformation = Nothing
            , _data_ = Nothing
            }
    | otherwise =
        Diagnostic
            { _range =
                Range
                    (Position (fromIntegral (line - 1)) (fromIntegral (col - 1)))
                    (Position (fromIntegral (endL - 1)) (fromIntegral (endC - 1)))
            , _severity = Just DiagnosticSeverity_Error
            , _code = Nothing
            , _codeDescription = Nothing
            , _source = Just "nix-compile"
            , _message = msg
            , _tags = Nothing
            , _relatedInformation = Nothing
            , _data_ = Nothing
            }
