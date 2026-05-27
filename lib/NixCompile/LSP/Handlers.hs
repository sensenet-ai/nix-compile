{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module NixCompile.LSP.Handlers
  ( handlers,
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

handlers :: Handlers (LspM ())
handlers =
  mconcat
    [ notificationHandler SMethod_Initialized $ \_not ->
        sendNotification SMethod_WindowLogMessage $
          LogMessageParams MessageType_Info "nix-compile LSP ready",
      notificationHandler SMethod_TextDocumentDidOpen $ \(notif :: TNotificationMessage 'Method_TextDocumentDidOpen) -> do
        let TNotificationMessage _ _ (DidOpenTextDocumentParams (TextDocumentItem uri _ _ txt)) = notif
        let diags = lintFile txt
        sendNotification SMethod_TextDocumentPublishDiagnostics $
          PublishDiagnosticsParams uri Nothing diags,
      notificationHandler SMethod_TextDocumentDidChange $ \(notif :: TNotificationMessage 'Method_TextDocumentDidChange) -> do
        let TNotificationMessage _ _ params = notif
        let DidChangeTextDocumentParams
              { _textDocument = VersionedTextDocumentIdentifier {_uri = uri},
                _contentChanges = cs
              } = params
        let txt = case cs of
              (c : _) -> case c of
                TextDocumentContentChangeEvent (InL (TextDocumentContentChangePartial _r _l t)) -> t
                TextDocumentContentChangeEvent (InR (TextDocumentContentChangeWholeDocument t)) -> t
              _ -> ""
        let diags = lintFile txt
        sendNotification SMethod_TextDocumentPublishDiagnostics $
          PublishDiagnosticsParams uri Nothing diags,
      notificationHandler SMethod_TextDocumentDidSave $ \(notif :: TNotificationMessage 'Method_TextDocumentDidSave) -> do
        let TNotificationMessage _ _ (DidSaveTextDocumentParams (TextDocumentIdentifier uri) txt) = notif
        case txt of
          Just t -> do
            let diags = lintFile t
            sendNotification SMethod_TextDocumentPublishDiagnostics $
              PublishDiagnosticsParams uri Nothing diags
          Nothing -> return (),
      requestHandler SMethod_TextDocumentHover $ \req responder -> do
        let TRequestMessage _ _ _ params = req
        let HoverParams textDoc pos _workDone = params
        let TextDocumentIdentifier uri = textDoc
        let Position l c = pos
        mvf <- getVirtualFile (toNormalizedUri uri)
        case mvf of
          Nothing -> responder $ Right $ InL $ Hover {_contents = InL noFile, _range = Nothing}
          Just vf -> do
            let txt = virtualFileText vf
            case parseNixTextLoc txt of
              Left _ -> responder $ Right $ InL $ Hover {_contents = InL parseErr, _range = Nothing}
              Right expr ->
                let contents = case inferExprAt expr (fromIntegral l) (fromIntegral c) of
                      Nothing -> MarkupContent MarkupKind_Markdown "`no expression at cursor`"
                      Just t -> MarkupContent MarkupKind_Markdown ("`: " <> t <> "`")
                 in responder $ Right $ InL $ Hover {_contents = InL contents, _range = Nothing},
      requestHandler SMethod_TextDocumentDefinition $ \req responder -> do
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
                           in responder $ Right $ InL (Definition (InL loc)),
      requestHandler SMethod_TextDocumentRename renameHandler
    ]

findRef :: (Int, Int) -> Scope.ScopeGraph -> Maybe Scope.Reference
findRef (l, c) sg =
  let refs =
        [ r
        | s <- Map.elems (Scope.sgScopes sg),
          r <- Scope.scopeReferences s
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
  case mvf of
    Nothing -> responder $ Right $ InR Null
    Just vf -> do
      let txt = virtualFileText vf
      case parseNixTextLoc txt of
        Left _ -> responder $ Right $ InR Null
        Right expr ->
          let sg = Scope.fromNixExpr Nothing expr
              cursorLine = fromIntegral l + 1
              cursorCol = fromIntegral c + 1
           in case findRef (cursorLine, cursorCol) sg of
                Nothing -> responder $ Right $ InR Null
                Just ref -> case Scope.resolve sg ref of
                  Left _ -> responder $ Right $ InR Null
                  Right decl ->
                    let allRefs = Scope.findReferences sg decl
                        declEdit =
                          TextEdit
                            (Range (toLspPos (Scope.spanStart (Scope.declSpan decl))) (toLspPos (Scope.spanEnd (Scope.declSpan decl))))
                            newName
                        refEdits =
                          [ TextEdit
                              (Range (toLspPos (Scope.spanStart (Scope.refSpan r))) (toLspPos (Scope.spanEnd (Scope.refSpan r))))
                              newName
                          | r <- allRefs
                          ]
                        wsEdit =
                          WorkspaceEdit
                            { _changes = Just (Map.singleton uri (declEdit : refEdits)),
                              _documentChanges = Nothing,
                              _changeAnnotations = Nothing
                            }
                     in responder $ Right $ InL wsEdit

noFile :: MarkupContent
noFile = MarkupContent MarkupKind_Markdown "`no file`"

parseErr :: MarkupContent
parseErr = MarkupContent MarkupKind_Markdown "`parse error`"

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
inferExprAt expr l c = do
  target <- findExprAt l c expr
  case Infer.inferExpr target of
    Right (t, _) -> Just (NT.prettyType t)
    Left _ -> Just "TYPE_ERROR"

lintFile :: T.Text -> [Diagnostic]
lintFile txt =
  case parseNixTextLoc txt of
    Left _ -> []
    Right expr ->
      map toNixDiag (findNixViolations expr)

toNixDiag :: NixViolation -> Diagnostic
toNixDiag NixViolation {nvType = vt, nvSpan = sp, nvContext = ctx} =
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
        { _range = Range (Position 0 0) (Position 0 0),
          _severity = Just DiagnosticSeverity_Error,
          _code = Nothing,
          _codeDescription = Nothing,
          _source = Just "nix-compile",
          _message = msg,
          _tags = Nothing,
          _relatedInformation = Nothing,
          _data_ = Nothing
        }
  | otherwise =
      Diagnostic
        { _range =
            Range
              (Position (fromIntegral (line - 1)) (fromIntegral (col - 1)))
              (Position (fromIntegral (endL - 1)) (fromIntegral (endC - 1))),
          _severity = Just DiagnosticSeverity_Error,
          _code = Nothing,
          _codeDescription = Nothing,
          _source = Just "nix-compile",
          _message = msg,
          _tags = Nothing,
          _relatedInformation = Nothing,
          _data_ = Nothing
        }
