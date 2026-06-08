{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // nix // compile // log
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Doors opened, closed behind him. Wheels left ferroconcrete, drinks
--    arrived, dinner was served."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // core // logging
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Log (
  AppM,
  runLog,
  logStr,
  module Katip,
)
where

import System.IO (stderr)

import Data.Text (Text)
import Data.Text.Lazy.Builder qualified as Builder
import Katip hiding (logStr)
import Katip qualified

type AppM = KatipContextT IO

logStr :: Text -> Katip.LogStr
logStr = Katip.logStr

runLog :: Severity -> AppM a -> IO a
runLog minSeverity action = do
  -- No severity text prefix: diagnostics already carry their own
  -- "error[CODE]:" / "warning[CODE]:" word (see NixCompile.Diagnostic), and
  -- ColorIfTerminal still colours each line by severity on a TTY. A "[ERROR]"
  -- prefix here only doubled up ("[ERROR] error[TYPE]: …"). Debug lines keep a
  -- marker since they have no inherent one and only appear under -vv.
  let fmt _color _verb item =
        let pfx = case _itemSeverity item of
              DebugS -> "[debug] "
              _ -> ""
            msg = unLogStr (_itemMessage item)
         in Builder.fromText pfx <> msg
  handleScribe <- mkHandleScribeWithFormatter fmt ColorIfTerminal stderr (permitItem minSeverity) V0
  initLogEnv "nix-compile" "production"
    >>= registerScribe "stderr" handleScribe defaultScribeSettings
    >>= \le -> runKatipContextT le () "main" action
