{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}

module NixCompile.LSP.Handlers
  ( handlers,
  )
where

import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types
import Language.LSP.Server
import qualified Data.Text as T

handlers :: Handlers (LspM ())
handlers = mconcat
  [ notificationHandler SMethod_Initialized $ \_not -> do
      sendNotification SMethod_WindowLogMessage $
        LogMessageParams MessageType_Info "nix-compile LSP initialized"
  , requestHandler SMethod_TextDocumentHover $ \req responder -> do
      let TRequestMessage _ _ _ params = req
      let HoverParams _doc pos _workDone = params
      let Position l c = pos
      let msg = "Hovering at " <> T.pack (show l) <> ":" <> T.pack (show c)
      let ms = makeMarkdown msg
      responder $ Right $ InL $ Hover { _contents = InL ms, _range = Nothing }
  ]

makeMarkdown :: T.Text -> MarkupContent
makeMarkdown x = MarkupContent MarkupKind_Markdown x
