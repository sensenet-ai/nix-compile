-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                            // app // NixCompile // CLI // Types
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{-# LANGUAGE OverloadedStrings #-}

module NixCompile.CLI.Types (
  TCResult (..),
  CICounts (..),
  emptyCICounts,
  okMarker,
  crossMarker,
  unsupMarker,
)
where

import Data.Text (Text)

-- ── check result ────────────────────────────────────────────────────

data TCResult = TCOk | TCFail | TCSkip
  deriving (Eq, Show)

-- ── CI aggregate counts ─────────────────────────────────────────────

data CICounts = CICounts
  { ciFilesScanned :: !Int
  , ciTypePass :: !Int
  , ciTypeFail :: !Int
  , ciTypeSkip :: !Int
  , ciLintViolations :: !Int
  , ciPackageViolations :: !Int
  , ciBashViolations :: !Int
  , ciGraphFailures :: !Int
  , ciLayoutViolations :: !Int
  }

emptyCICounts :: CICounts
emptyCICounts = CICounts 0 0 0 0 0 0 0 0 0

-- ── status markers ──────────────────────────────────────────────────

okMarker :: Text
okMarker = "[OK]"

crossMarker :: Text
crossMarker = "[XX]"

unsupMarker :: Text
unsupMarker = "[UNC]"
