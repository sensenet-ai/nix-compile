{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}

module NixCompile.LSP.Server (run) where

import Control.Monad.IO.Class
import Data.Text ()
import Language.LSP.Server
import NixCompile.LSP.Handlers (handlers)

run :: IO Int
run = runServer $ ServerDefinition
  { parseConfig = \_old _val -> Right ()
  , onConfigChange = const $ pure ()
  , doInitialize = \env _req -> pure (Right env)
  , staticHandlers = \_caps -> handlers
  , interpretHandler = \env -> Iso (runLspT env) liftIO
  , options = defaultOptions
  , defaultConfig = ()
  , configSection = "nix-compile"
  }
