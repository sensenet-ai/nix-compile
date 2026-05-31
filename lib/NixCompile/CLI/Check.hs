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
)
where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Fix (Fix (..))
import Data.Functor.Compose (Compose (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Nix.Expr.Types
import Nix.Expr.Types.Annotated (AnnUnit (..), NExprLoc)

import NixCompile.CLI.Report
import NixCompile.CLI.Types
import NixCompile.Config qualified as Config
import NixCompile.Log
import NixCompile.Nix.Infer qualified
import NixCompile.Nix.LintCombined qualified as Combined
import NixCompile.Nix.Parse qualified as Nix
import NixCompile.Nix.Types qualified

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
                        , "  PARSE ERROR: " <> parseError
                        , ""
                        ]
            return TCFail
        Right expression ->
            case detectUnsupportedConstruct expression of
                Just reason -> do
                    $(logTM) InfoS $ logStr $ unsupMarker <> " " <> T.pack file <> " (skipping type check: " <> reason <> ")"
                    checkWithViolations config file expression True
                Nothing -> checkWithViolations config file expression False

checkWithViolations :: Config.Config -> FilePath -> NExprLoc -> Bool -> AppM TCResult
checkWithViolations config file expression skipTypeCheck = do
    let bundle = Combined.combinedLint file expression
    let (_, activeNixViolations) = partitionNixViolations config (Combined.lbNix bundle)
    let (_, activeDerivViolations) = partitionDerivViolations config (Combined.lbDeriv bundle)
    let (_, activePatternViolations) = partitionPatternViolations config (Combined.lbPattern bundle)

    reportNixLintViolations file activeNixViolations
    reportDerivViolations file activeDerivViolations
    reportPatternViolations file activePatternViolations

    typeCheckResult <- performTypeCheck config expression skipTypeCheck
    case typeCheckResult of
        TCFail -> return TCFail
        TCOk
            | skipTypeCheck -> do
                $(logTM) InfoS $ logStr $ crossMarker <> " " <> T.pack file <> " (unsupported construct — type check skipped)"
                return TCFail
            | null activeNixViolations && null activeDerivViolations && null activePatternViolations -> do
                $(logTM) InfoS $ logStr $ okMarker <> " " <> T.pack file
                return TCOk
        _ -> do
            $(logTM) InfoS $ logStr $ crossMarker <> " " <> T.pack file <> " (lint violations)"
            return TCFail

performTypeCheck :: Config.Config -> NExprLoc -> Bool -> AppM TCResult
performTypeCheck config expression skipTypeCheck
    | skipTypeCheck = return TCOk
    | otherwise = do
    result <- liftIO $ try $ case NixCompile.Nix.Infer.inferExpr expression of
        Left typeError -> return $ Left typeError
        Right (type_, _) -> return $ Right (NixCompile.Nix.Types.prettyType type_)
    case result of
        Left (exception :: SomeException) -> do
            $(logTM) ErrorS $
                logStr $
                    T.unlines
                        [ ""
                        , "  INTERNAL ERROR (this is a bug in nix-compile):"
                        , ""
                        , T.unlines $ map ("     " <>) $ T.lines $ T.pack $ show exception
                        ]
            return TCFail
        Right (Left typeError) ->
            case Config.effectiveSeverity config Config.typeCheckRuleId of
                Just Config.SevOff -> return TCOk
                Just Config.SevWarning -> do
                    $(logTM) WarningS $
                        logStr $
                            T.unlines
                                [ ""
                                , formatTypeError typeError
                                , ""
                                ]
                    return TCOk
                _ -> do
                    $(logTM) ErrorS $
                        logStr $
                            T.unlines
                                [ ""
                                , formatTypeError typeError
                                , ""
                                ]
                    return TCFail
        Right (Right _) -> return TCOk

formatTypeError :: T.Text -> T.Text
formatTypeError errorText =
    case T.lines errorText of
        (firstLine : remainingLines) -> T.unlines $ ("  TYPE WARNING: " <> firstLine) : map ("         " <>) remainingLines
        [] -> "  TYPE WARNING: unknown error"

maxRecursionDepth :: Int
maxRecursionDepth = 200

detectUnsupportedConstruct :: NExprLoc -> Maybe T.Text
detectUnsupportedConstruct = go 0
  where
    go :: Int -> NExprLoc -> Maybe T.Text
    go d _
        | d > maxRecursionDepth = Just "deeply nested expression"
    go d (Fix (Compose (AnnUnit _ expression))) =
        let n = d + 1
         in case expression of
                NSelect _ _ (DynamicKey _ :| _) -> Just "dynamic attribute access"
                NSet Recursive _ -> Just "rec attrset"
                NAbs _ body -> go n body
                NLet bindings body ->
                    foldl (<|>) (go n body) (map (detectUnsupportedBindingDepth n) bindings)
                NSet _ bindings ->
                    foldl (<|>) Nothing (map (detectUnsupportedBindingDepth n) bindings)
                NList elements ->
                    foldl (<|>) Nothing (map (go n) elements)
                NBinary _ left right ->
                    go n left <|> go n right
                NUnary _ arg -> go n arg
                NSelect _ base _ -> go n base
                NHasAttr base attributePath
                    | any isDynamicKey attributePath -> Just "dynamic attribute test"
                    | otherwise -> go n base
                NApp function arg -> go n function <|> go n arg
                NIf cond thenBranch elseBranch ->
                    go n cond <|> go n thenBranch <|> go n elseBranch
                NAssert cond body -> go n cond <|> go n body
                _ -> Nothing

    isDynamicKey (DynamicKey _) = True
    isDynamicKey _ = False

detectUnsupportedBinding :: Binding NExprLoc -> Maybe T.Text
detectUnsupportedBinding = detectUnsupportedBindingDepth 0

detectUnsupportedBindingDepth :: Int -> Binding NExprLoc -> Maybe T.Text
detectUnsupportedBindingDepth d (NamedVar _ e _) = go d e
  where
    go depth _
        | depth > maxRecursionDepth = Just "deeply nested expression"
    go depth (Fix (Compose (AnnUnit _ expression))) =
        let n = depth + 1
         in case expression of
                NSelect _ _ (DynamicKey _ :| _) -> Just "dynamic attribute access"
                NSet Recursive _ -> Just "rec attrset"
                NAbs _ body -> go n body
                NLet bindings body ->
                    foldl (<|>) (go n body) (map (detectUnsupportedBindingDepth n) bindings)
                NSet _ bindings ->
                    foldl (<|>) Nothing (map (detectUnsupportedBindingDepth n) bindings)
                NList elements ->
                    foldl (<|>) Nothing (map (go n) elements)
                NBinary _ left right ->
                    go n left <|> go n right
                NUnary _ arg -> go n arg
                NSelect _ base _ -> go n base
                NHasAttr base attributePath
                    | any hasDynKey attributePath -> Just "dynamic attribute test"
                    | otherwise -> go n base
                NApp function arg -> go n function <|> go n arg
                NIf cond thenBranch elseBranch ->
                    go n cond <|> go n thenBranch <|> go n elseBranch
                NAssert cond body -> go n cond <|> go n body
                _ -> Nothing
    hasDynKey (DynamicKey _) = True
    hasDynKey _ = False
detectUnsupportedBindingDepth _ (Inherit _ _ _) = Nothing
