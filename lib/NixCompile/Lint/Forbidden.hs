{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : NixCompile.Lint.Forbidden
-- Description : Detect forbidden bash constructs
--
-- Detects constructs that are banned in nix-compile:
--   - Heredocs (<<, <<-)
--   - Here-strings (<<<)
--   - eval
--   - Backticks (`cmd`)
--
-- These are errors, not warnings. No escape hatch.
module NixCompile.Lint.Forbidden
  ( -- * Types
    Violation (..),
    ViolationType (..),

    -- * Detection
    findViolations,

    -- * Formatting
    formatViolation,
    formatViolations,
    formatViolationAt,
    formatViolationsAt,
  )
where

import Control.Monad.Reader (Reader, runReader, ask)
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import NixCompile.Bash.Parse (BashAST(..))
import NixCompile.Types (Loc (..), Span (..))
import qualified ShellCheck.AST as SA
import ShellCheck.Interface (Position(..))

-- | Type of violation
data ViolationType
  = VHeredoc -- ^ << or <<-
  | VHereString -- ^ <<<
  | VEval -- ^ eval command
  | VBacktick -- ^ `cmd` syntax
  deriving (Eq, Show)

-- | A detected violation
data Violation = Violation
  { vType :: !ViolationType,
    vSpan :: !Span,
    vContext :: !Text -- ^ The offending code snippet
  }
  deriving (Eq, Show)

-- | Find all forbidden constructs in a bash AST
findViolations :: BashAST -> [Violation]
findViolations (BashAST root posMap) = runReader (go root) posMap

go :: SA.Token -> Reader (Map SA.Id (Position, Position)) [Violation]
go _tok@(SA.OuterToken scId inner) = do
  local <- localViolations scId inner
  rest <- mapM go (toList inner)
  pure (local ++ concat rest)

-- | Check a single node for violations
localViolations :: SA.Id -> SA.InnerToken SA.Token -> Reader (Map SA.Id (Position, Position)) [Violation]
localViolations scId inner = do
  sp <- mkSpan scId
  case inner of
    -- Heredoc: << EOF or <<- EOF
    SA.Inner_T_HereDoc {} ->
      pure [Violation VHeredoc sp "heredoc (<<)"]
    -- Here-string: <<< "string"
    SA.Inner_T_HereString {} ->
      pure [Violation VHereString sp "here-string (<<<)"]
    -- Backticks: `cmd`
    SA.Inner_T_Backticked {} ->
      pure [Violation VBacktick sp "backticks (`...`)"]
    -- Simple command: check for eval or dangerous source
    SA.Inner_T_SimpleCommand _ wrds -> do
      evals <- checkForEval scId wrds
      sources <- checkForSource scId wrds
      pure (evals ++ sources)
    _ -> pure []

-- | Check if a command is 'eval'
checkForEval :: SA.Id -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Violation]
checkForEval scId wrds
  | isEvalInvocation wrds = do
      sp <- mkSpan scId
      pure [Violation VEval sp "eval"]
  | otherwise = pure []

-- | Check for dangerous 'source' invocations (eval equivalents)
--   - source /dev/stdin
--   - source <(...)
--   - . /dev/stdin
checkForSource :: SA.Id -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Violation]
checkForSource scId wrds = case wrds of
  (cmd : arg : _) | isSource (tokenToText cmd) -> do
    if isDangerousSourceArg arg
      then do
        sp <- mkSpan scId
        pure [Violation VEval sp "source /dev/stdin (eval equivalent)"]
      else pure []
  _ -> pure []
  where
    isSource t = t == "source" || t == "." || t == "builtin source" || t == "command source"
    
    isDangerousSourceArg :: SA.Token -> Bool
    isDangerousSourceArg tok = 
      let t = tokenToText tok
      in t == "/dev/stdin" || containsProcSub tok

    -- | Check if token contains a process substitution (recursively)
    containsProcSub :: SA.Token -> Bool
    containsProcSub (SA.OuterToken _ inner) = case inner of
      SA.Inner_T_ProcSub {} -> True
      SA.Inner_T_NormalWord parts -> any containsProcSub parts
      SA.Inner_T_DoubleQuoted parts -> any containsProcSub parts
      _ -> False

-- | Detect eval in common "escape hatch" forms.
--
-- We treat these as equivalent:
--   - eval ...
--   - builtin eval ...
--   - command eval ...
isEvalInvocation :: [SA.Token] -> Bool
isEvalInvocation toks =
  case map tokenToText toks of
    ("eval" : _) -> True
    ("builtin" : "eval" : _) -> True
    ("command" : "eval" : _) -> True
    _ -> False

-- | Extract the text content of a token (simplified, for lint checks)
tokenToText :: SA.Token -> Text
tokenToText (SA.OuterToken _ inner) = case inner of
  SA.Inner_T_NormalWord [SA.OuterToken _ (SA.Inner_T_Literal s)] -> T.pack s
  SA.Inner_T_Literal s -> T.pack s
  _ -> ""

-- | Make a span from token ID using the position map
mkSpan :: SA.Id -> Reader (Map SA.Id (Position, Position)) Span
mkSpan scId = do
  posMap <- ask
  case Map.lookup scId posMap of
    Just (start, end) ->
      pure $ Span
        (Loc (fromIntegral $ posLine start) (fromIntegral $ posColumn start))
        (Loc (fromIntegral $ posLine end) (fromIntegral $ posColumn end))
        (Just (posFile start))
    Nothing ->
      -- Fallback if ID not found (shouldn't happen for valid AST nodes)
      let (SA.Id n) = scId
       in pure $ Span (Loc n 0) (Loc n 0) Nothing

-- | Format a single violation for display.
formatViolationAt :: Text -> Violation -> Text
formatViolationAt src Violation {..} =
  let typeStr = case vType of
        VHeredoc -> "heredoc"
        VHereString -> "here-string"
        VEval -> "eval"
        VBacktick -> "backtick"
      line = locLine (spanStart vSpan)
      errCode = case vType of
        VHeredoc -> "ALEPH-B001"
        VHereString -> "ALEPH-B002"
        VEval -> "ALEPH-B003"
        VBacktick -> "ALEPH-B004"
      suggestion = case vType of
        VHeredoc ->
          T.unlines
            [ "  Prefer nix-compile's generated emitter for structured config:",
              "    emit-config json   # or: yaml | toml",
              "",
              "  Or printf for simple strings:",
              "    printf 'Hello, %s\\n' \"$NAME\"",
              "",
              "  Or generate content in Nix, reference in bash:",
              "    cat ${pkgs.writeText \"msg\" ''...''}"
            ]
        VHereString ->
          T.unlines
            [ "  Use echo with pipe:",
              "    echo \"string\" | command",
              "",
              "  Or printf:",
              "    printf '%s' \"string\" | command"
            ]
        VEval ->
          T.unlines
            [ "  eval is forbidden. Refactor to avoid dynamic code execution.",
              "",
              "  If you need to set variables dynamically:",
              "    declare \"$name=$value\"",
              "",
              "  If you need to choose between commands:",
              "    case \"$mode\" in",
              "      a) /nix/store/...-tool/bin/tool ... ;;",
              "      b) /nix/store/...-other/bin/other ... ;;",
              "    esac"
            ]
        VBacktick ->
          T.unlines
            [ "  Use $() instead of backticks:",
              "    result=$(command)",
              "",
              "  Not:",
              "    result=`command`"
            ]
   in T.unlines
        [ "error[" <> errCode <> "]: " <> typeStr <> " not allowed",
          "  --> " <> src <> ":" <> T.pack (show line),
          "",
          suggestion
        ]

formatViolation :: Violation -> Text
formatViolation = formatViolationAt "<input>"

-- | Format all violations
formatViolationsAt :: Text -> [Violation] -> Text
formatViolationsAt _ [] = ""
formatViolationsAt src vs = T.intercalate "\n" (map (formatViolationAt src) vs)

formatViolations :: [Violation] -> Text
formatViolations = formatViolationsAt "<input>"
