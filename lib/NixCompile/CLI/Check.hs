{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module NixCompile.CLI.Check (
    checkFile,
    checkWithViolations,
    performTypeCheck,
    formatTypeError,
    detectUnsupportedConstruct,
    detectUnsupportedBinding,

    -- * Re-exports
    Safety.maxRecursionDepth,
)
where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Either (fromRight)
import Data.Fix (Fix (..))
import Data.Functor.Compose (Compose (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Nix.Expr.Types
import Nix.Expr.Types.Annotated (AnnUnit (..), NExprLoc)

import NixCompile.CLI.Report
import NixCompile.CLI.Types
import NixCompile.Config qualified as Config
import NixCompile.Diagnostic qualified as Diag
import NixCompile.Log
import NixCompile.Nix.Inference qualified
import NixCompile.Nix.Lint qualified as Lint
import NixCompile.Nix.LintCombined qualified as Combined
import NixCompile.Nix.LintDerivation qualified as Derivation
import NixCompile.Nix.LintPatterns qualified as Patterns
import NixCompile.Nix.Parse qualified as Nix
import NixCompile.Nix.Types qualified
import NixCompile.Safety qualified as Safety

checkFile :: Config.Config -> FilePath -> AppM TCResult
checkFile config file = do
    parseResult <- liftIO $ Nix.parseNixFile file
    case parseResult of
        Left parseError -> do
            $(logTM) ErrorS $
                logStr $
                    T.unlines
                        [ ""
                        , "━━━ " <> crossMarker <> " " <> T.pack file <> " ━━━"
                        , ""
                        , "  " <> parseError
                        , ""
                        ]
            return TCFail
        Right expression -> case Safety.analyzeDepth expression of
            Left de -> do
                $(logTM) ErrorS $
                    logStr $
                        crossMarker
                            <> " "
                            <> T.pack file
                            <> " (depth limit exceeded: "
                            <> Safety.renderSafetyError (Safety.SafetyDepthExceeded de)
                            <> ")"
                return TCFail
            Right () ->
                case detectUnsupportedConstruct expression of
                    Just reason -> do
                        $(logTM) DebugS $ logStr $ unsupMarker <> " " <> T.pack file <> " (skipping type check: " <> reason <> ")"
                        checkWithViolations config file expression True
                    Nothing -> checkWithViolations config file expression False

checkWithViolations :: Config.Config -> FilePath -> NExprLoc -> Bool -> AppM TCResult
checkWithViolations config file expression skipTypeCheck = do
    let bundle = Combined.combinedLint file expression
    let (_, activeNixViolations) = partitionNixViolations config (Combined.lbNix bundle)
    let (_, activeDerivViolations) = partitionDerivViolations config (Combined.lbDeriv bundle)
    let (_, activePatternViolations) = partitionPatternViolations config (Combined.lbPattern bundle)

    -- read the source once so lint diagnostics can show the offending line + caret
    srcResult <- liftIO (Safety.safeReadFile file)
    let src = fromRight "" srcResult
        emitAll toDiag = mapM_ (emitDiagnostic . attachSnippet src . toDiag)
    emitAll Lint.nixViolationDiagnostic activeNixViolations
    emitAll Derivation.derivViolationDiagnostic activeDerivViolations
    emitAll Patterns.patternViolationDiagnostic activePatternViolations

    typeCheckResult <- performTypeCheck config file expression skipTypeCheck
    case typeCheckResult of
        TCFail -> return TCFail
        TCOk
            | skipTypeCheck -> do
                $(logTM) DebugS $ logStr $ crossMarker <> " " <> T.pack file <> " (unsupported construct — type check skipped)"
                return TCFail
            | null activeNixViolations && null activeDerivViolations && null activePatternViolations -> do
                $(logTM) DebugS $ logStr $ okMarker <> " " <> T.pack file
                return TCOk
        _ -> do
            $(logTM) DebugS $ logStr $ crossMarker <> " " <> T.pack file <> " (lint violations)"
            return TCFail

performTypeCheck :: Config.Config -> FilePath -> NExprLoc -> Bool -> AppM TCResult
performTypeCheck config file expression skipTypeCheck
    | skipTypeCheck = return TCOk
    | otherwise = do
        result <- liftIO $ try $ case NixCompile.Nix.Inference.inferExpr expression of
            Left typeError -> return $ Left typeError
            Right (type_, _) -> return $ Right (NixCompile.Nix.Types.prettyType type_)
        case result of
            Left (exception :: SomeException) -> do
                emitDiagnostic $
                    Diag.Diagnostic
                        { Diag.diagSeverity = ErrorS
                        , Diag.diagCode = Just "INTERNAL"
                        , Diag.diagSpan = Nothing
                        , Diag.diagSummary = "internal error (this is a bug in nix-compile): " <> T.pack (show exception)
                        , Diag.diagHelp = []
                        , Diag.diagSnippet = Nothing
                        }
                return TCFail
            Right (Left typeError) ->
                case Config.effectiveSeverity config Config.typeCheckRuleId of
                    Just Config.SevOff -> return TCOk
                    Just Config.SevWarning -> emitType WarningS typeError >> return TCOk
                    _ -> emitType ErrorS typeError >> return TCFail
            Right (Right _) -> return TCOk
  where
    -- build a TYPE diagnostic and attach the source line/caret from the file
    emitType sev typeError = do
        srcResult <- liftIO (Safety.safeReadFile file)
        let base = typeDiagnostic sev file typeError
        emitDiagnostic (either (const base) (`attachSnippet` base) srcResult)

formatTypeError :: T.Text -> T.Text
formatTypeError errorText =
    case T.lines errorText of
        (firstLine : remainingLines) -> T.unlines $ ("  TYPE WARNING: " <> firstLine) : map ("         " <>) remainingLines
        [] -> "  TYPE WARNING: unknown error"

{- | Detect AST shapes that are syntactically valid but semantically unsupported.
n.b. depth checking now lives in 'NixCompile.Safety.analyzeDepth' and runs BEFORE
this; we only flag rec/dynamic-key here, never depth.
-}
detectUnsupportedConstruct :: NExprLoc -> Maybe T.Text
detectUnsupportedConstruct = go
  where
    go (Fix (Compose (AnnUnit _ expression))) = case expression of
        NSelect _ _ (DynamicKey _ :| _) -> Just "dynamic attribute access"
        NSet Recursive _ -> Just "rec attrset"
        NAbs _ body -> go body
        NLet bindings body ->
            foldl (<|>) (go body) (map detectUnsupportedBinding bindings)
        NSet _ bindings ->
            foldl (<|>) Nothing (map detectUnsupportedBinding bindings)
        NList elements -> foldl (<|>) Nothing (map go elements)
        NBinary _ left right -> go left <|> go right
        NUnary _ arg -> go arg
        NSelect _ base _ -> go base
        NHasAttr base attributePath
            | any isDynamicKey attributePath -> Just "dynamic attribute test"
            | otherwise -> go base
        NApp function arg -> go function <|> go arg
        NIf cond thenBranch elseBranch -> go cond <|> go thenBranch <|> go elseBranch
        NAssert cond body -> go cond <|> go body
        NWith scope body -> go scope <|> go body
        NStr (DoubleQuoted parts) -> foldl (<|>) Nothing (map goAnti parts)
        NStr (Indented _ parts) -> foldl (<|>) Nothing (map goAnti parts)
        _ -> Nothing

    goAnti (Antiquoted e) = go e
    goAnti _ = Nothing

    isDynamicKey (DynamicKey _) = True
    isDynamicKey _ = False

detectUnsupportedBinding :: Binding NExprLoc -> Maybe T.Text
detectUnsupportedBinding (NamedVar _ e _) = detectUnsupportedConstruct e
detectUnsupportedBinding (Inherit (Just s) _ _) = detectUnsupportedConstruct s
detectUnsupportedBinding (Inherit Nothing _ _) = Nothing
