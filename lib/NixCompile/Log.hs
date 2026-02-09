{-# LANGUAGE OverloadedStrings #-}
module NixCompile.Log
  ( AppM
  , runLog
  , logStr
  , module Katip
  ) where

import Katip hiding (logStr)
import qualified Katip
import System.IO (stderr)
import Data.Text (Text)

type AppM = KatipContextT IO

logStr :: Text -> Katip.LogStr
logStr = Katip.logStr

runLog :: Severity -> AppM a -> IO a
runLog minSeverity action = do
  handleScribe <- mkHandleScribe ColorIfTerminal stderr (permitItem minSeverity) V2
  initLogEnv "nix-compile" "production"
    >>= registerScribe "stderr" handleScribe defaultScribeSettings
    >>= \le -> runKatipContextT le () "main" action
