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
  )
where

import Data.Text qualified as T
import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types
import Language.LSP.Server
import Nix.Parser (parseNixTextLoc)
import NixCompile.Nix.Lint (NixViolation (..), ViolationType (..), findNixViolations)
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
      requestHandler SMethod_TextDocumentHover $ \req responder -> do
        let TRequestMessage _ _ _ params = req
        let HoverParams _doc pos _workDone = params
        let Position l c = pos
        let contents =
              MarkupContent MarkupKind_Markdown $
                "`: " <> T.pack (show l) <> ":" <> T.pack (show c) <> "`"
        responder $ Right $ InL $ Hover {_contents = InL contents, _range = Nothing}
    ]

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
