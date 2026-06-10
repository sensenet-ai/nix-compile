{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                          // core // span
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "the matrix, cyberspace, where the great corporate hotcores burned
--    like neon novas, data so dense you suffered sensory overload if you
--    tried to apprehend more than the merest outline."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   Source locations: the one vocabulary every checker, parser, and inference
--   pass agrees on. A 'Loc' is a (line, column); a 'Span' is a start/end pair
--   with an optional originating file. Foundational and dependency-free — both
--   the nix frontend and the bash pipeline point their diagnostics here.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Core.Span (
  Loc (..),
  Span (..),
)
where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)

data Loc = Loc
  { locLine :: !Int
  , locCol :: !Int
  }
  deriving stock (Eq, Ord, Show, Generic)

instance FromJSON Loc
instance ToJSON Loc

data Span = Span
  { spanStart :: !Loc
  , spanEnd :: !Loc
  , spanFile :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON Span
instance ToJSON Span
