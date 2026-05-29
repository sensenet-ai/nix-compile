{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                               // lint // forbidden
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "They set a slamhound on Turner's trail in New Delhi, slotted it to
--    his pheromones and the color of his hair."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // lint // detection
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Lint.Forbidden (
    -- * Types
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

import Control.Monad.Reader (Reader, ask, runReader)
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import NixCompile.Bash.Parse (BashAST (..))
import NixCompile.Types (Loc (..), Span (..))
import ShellCheck.AST qualified as SA
import ShellCheck.Interface (Position (..))

data ViolationType
    = VHeredoc
    | VHereString
    | VEval
    | VBacktick
    deriving (Eq, Show)

data Violation = Violation
    { vType :: !ViolationType
    , vSpan :: !Span
    , vContext :: !Text
    }
    deriving (Eq, Show)

findViolations :: BashAST -> [Violation]
findViolations (BashAST root posMap) = runReader (go root) posMap

go :: SA.Token -> Reader (Map SA.Id (Position, Position)) [Violation]
go (SA.OuterToken shellCheckId inner) = do
    local <- localViolations shellCheckId inner
    nested <- mapM go (toList inner)
    pure (local ++ concat nested)

localViolations :: SA.Id -> SA.InnerToken SA.Token -> Reader (Map SA.Id (Position, Position)) [Violation]
localViolations shellCheckId inner = do
    violationSpan <- mkSpan shellCheckId
    case inner of
        SA.Inner_T_HereDoc{} ->
            pure [Violation VHeredoc violationSpan "heredoc (<<)"]
        SA.Inner_T_HereString{} ->
            pure [Violation VHereString violationSpan "here-string (<<<)"]
        SA.Inner_T_Backticked{} ->
            pure [Violation VBacktick violationSpan "backticks (`...`)"]
        SA.Inner_T_SimpleCommand _ commandWords ->
            checkForEval shellCheckId commandWords
        _ -> pure []

checkForEval :: SA.Id -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Violation]
checkForEval tokenId commandWords
    | isEvalInvocation commandWords = do
        violationSpan <- mkSpan tokenId
        pure [Violation VEval violationSpan "eval"]
    | otherwise = pure []

isEvalInvocation :: [SA.Token] -> Bool
isEvalInvocation tokens =
    any isEvalToken (map tokenToText tokens)

isEvalToken :: Text -> Bool
isEvalToken text =
    text == "eval" || "/eval" `T.isSuffixOf` text

tokenToText :: SA.Token -> Text
tokenToText (SA.OuterToken _ inner) = case inner of
    SA.Inner_T_NormalWord [SA.OuterToken _ (SA.Inner_T_Literal literal)] -> T.pack literal
    SA.Inner_T_Literal literal -> T.pack literal
    _ -> ""

mkSpan :: SA.Id -> Reader (Map SA.Id (Position, Position)) Span
mkSpan tokenId = do
    positionMap <- ask
    pure $ lookupPosition tokenId positionMap

lookupPosition :: SA.Id -> Map SA.Id (Position, Position) -> Span
lookupPosition tokenId positionMap
    | Just (startPosition, endPosition) <- Map.lookup tokenId positionMap =
        Span
            (Loc (fromIntegral $ posLine startPosition) (fromIntegral $ posColumn startPosition))
            (Loc (fromIntegral $ posLine endPosition) (fromIntegral $ posColumn endPosition))
            (Just (posFile startPosition))
    | otherwise =
        Span (Loc 0 0) (Loc 0 0) Nothing

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                           // output formatting
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

formatViolationAt :: Text -> Violation -> Text
formatViolationAt src Violation{..} =
    T.unlines
        [ "error[" <> forbiddenErrorCode vType <> "]: " <> forbiddenTypeLabel vType <> " not allowed"
        , "  --> " <> src <> ":" <> T.pack (show line)
        , ""
        , forbiddenSuggestion vType
        ]
  where
    line = locLine (spanStart vSpan)

-- ── violation type labels ──────────────────────────────────────────
-- Short, human-readable classification strings for each violation type.

forbiddenTypeLabel :: ViolationType -> Text
forbiddenTypeLabel = \case
    VHeredoc -> "heredoc"
    VHereString -> "here-string"
    VEval -> "eval"
    VBacktick -> "backtick"

-- ── error codes ────────────────────────────────────────────────────
-- Stable ALEPH-Bxxx codes. B-prefix denotes bash/shell violations.

forbiddenErrorCode :: ViolationType -> Text
forbiddenErrorCode = \case
    VHeredoc -> "ALEPH-B001"
    VHereString -> "ALEPH-B002"
    VEval -> "ALEPH-B003"
    VBacktick -> "ALEPH-B004"

-- ── remediation suggestions ────────────────────────────────────────
-- Each forbidden bash construct has a suggested replacement. The text
-- includes concrete code examples because the target audience is
-- developers who may not know the idiomatic nix-compile alternatives.
-- n.b. heredoc replacements reference pkgs.writeText, which requires
-- a Nix context — the user must plumb the path through their build.

forbiddenSuggestion :: ViolationType -> Text
forbiddenSuggestion = \case
    VHeredoc ->
        T.unlines
            [ "  Prefer nix-compile's generated emitter for structured config:"
            , "    emit-config json   # or: yaml | toml"
            , ""
            , "  Or printf for simple strings:"
            , "    printf 'Hello, %s\\n' \"$NAME\""
            , ""
            , "  Or generate content in Nix, reference in bash:"
            , "    cat ${pkgs.writeText \"msg\" ''...''}"
            ]
    VHereString ->
        T.unlines
            [ "  Use echo with pipe:"
            , "    echo \"string\" | command"
            , ""
            , "  Or printf:"
            , "    printf '%s' \"string\" | command"
            ]
    VEval ->
        T.unlines
            [ "  eval is forbidden. Refactor to avoid dynamic code execution."
            , ""
            , "  If you need to set variables dynamically:"
            , "    declare \"$name=$value\""
            , ""
            , "  If you need to choose between commands:"
            , "    case \"$mode\" in"
            , "      a) /nix/store/...-tool/bin/tool ... ;;"
            , "      b) /nix/store/...-other/bin/other ... ;;"
            , "    esac"
            ]
    VBacktick ->
        T.unlines
            [ "  Use $() instead of backticks:"
            , "    result=$(command)"
            , ""
            , "  Not:"
            , "    result=`command`"
            ]

formatViolation :: Violation -> Text
formatViolation = formatViolationAt "<input>"

formatViolationsAt :: Text -> [Violation] -> Text
formatViolationsAt _ [] = ""
formatViolationsAt src violations = T.intercalate "\n" (map (formatViolationAt src) violations)

formatViolations :: [Violation] -> Text
formatViolations = formatViolationsAt "<input>"
