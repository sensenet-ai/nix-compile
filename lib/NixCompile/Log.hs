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
    let fmt _color _verb item =
            let sev = case _itemSeverity item of
                    ErrorS   -> "[ERROR] "
                    WarningS -> "[WARN] "
                    DebugS   -> "[DEBUG] "
                    _        -> ""
                msg = unLogStr (_itemMessage item)
             in Builder.fromText sev <> msg
    handleScribe <- mkHandleScribeWithFormatter fmt ColorIfTerminal stderr (permitItem minSeverity) V0
    initLogEnv "nix-compile" "production"
        >>= registerScribe "stderr" handleScribe defaultScribeSettings
        >>= \le -> runKatipContextT le () "main" action
