{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
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
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Nix.Expr.Types
import Nix.Expr.Types.Annotated (NExprLoc)

import NixCompile.CLI.Report
import NixCompile.CLI.Types
import NixCompile.Core.Config qualified as Config
import NixCompile.Core.Diagnostic qualified as Diag
import NixCompile.Core.Log
import NixCompile.Core.Safety qualified as Safety
import NixCompile.Inference.Nix (TypeEnv (..), builtinEnv, inferExprWithEnv)
import NixCompile.Inference.Nix.Type qualified
import NixCompile.Layout.Closure qualified as Closure
import NixCompile.Layout.ModuleKind (ModuleKind (..), detectKind, detectedKind)
import NixCompile.Lint.Combined qualified as Combined
import NixCompile.Lint.Derivation qualified as Derivation
import NixCompile.Lint.Nix qualified as Lint
import NixCompile.Lint.Patterns qualified as Patterns
import NixCompile.Syntax.Annotation (pattern Layer)
import NixCompile.Syntax.Parse qualified as Nix

{- | Parse, depth-guard, and check one .nix file: emits lint and type
diagnostics and returns the overall 'TCResult' (a parse/depth failure is
'TCFail'; unsupported constructs skip the type check).
-}
checkFile :: Config.Config -> FilePath -> AppM TCResult
checkFile config file = do
  parseResult <- liftIO $ Nix.parseNixFile file
  either onParseError afterParse parseResult
 where
  onParseError parseError = do
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

  -- past parse: enforce the depth guard, then check (unless an unsupported
  -- construct means we skip the type-check phase)
  afterParse expression =
    either
      (onDepthExceeded expression)
      (const (afterDepth expression))
      (Safety.analyzeDepth expression)

  onDepthExceeded _ de = do
    $(logTM) ErrorS $
      logStr $
        crossMarker
          <> " "
          <> T.pack file
          <> " (depth limit exceeded: "
          <> Safety.renderSafetyError (Safety.SafetyDepthExceeded de)
          <> ")"
    return TCFail

  afterDepth expression =
    maybe
      (checkWithViolations config file expression False)
      (skipTypeCheck expression)
      (detectUnsupportedConstruct expression)

  skipTypeCheck expression reason = do
    $(logTM) DebugS $
      logStr $
        unsupMarker <> " " <> T.pack file <> " (skipping type check: " <> reason <> ")"
    checkWithViolations config file expression True

{- | Run the combined lint suite and (unless @skipTypeCheck@) the type check on
an already-parsed expression, emitting diagnostics and folding both into a
single 'TCResult'.
-}
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
  let allClean =
        null activeNixViolations
          && null activeDerivViolations
          && null activePatternViolations
      report TCFail = return TCFail
      report TCOk
        | skipTypeCheck = do
            $(logTM) DebugS $
              logStr $
                crossMarker <> " " <> T.pack file <> " (unsupported construct — type check skipped)"
            return TCFail
        | allClean = do
            $(logTM) DebugS $ logStr $ okMarker <> " " <> T.pack file
            return TCOk
      report _ = do
        $(logTM) DebugS $ logStr $ crossMarker <> " " <> T.pack file <> " (lint violations)"
        return TCFail
  report typeCheckResult

{- | Infer the expression's type (module-mode for flakes/modules, strict env
otherwise), emitting a TYPE diagnostic on error at the rule's configured
severity. Returns 'TCOk' when @skipTypeCheck@, clean, or the rule is off.
-}
performTypeCheck :: Config.Config -> FilePath -> NExprLoc -> Bool -> AppM TCResult
performTypeCheck config file expression skipTypeCheck
  | skipTypeCheck = return TCOk
  | otherwise = do
      -- Flakes and module-system files take their top-level parameters
      -- (self, inputs, config, pkgs, …) from the flake / module system, so we
      -- infer them in module mode (those params are dynamic). Everything else
      -- uses the strict builtin env. Either way, seed the cross-module
      -- import/callPackage closure (synchronous, eval-free — see
      -- 'NixCompile.Layout.Closure') so an `import ./dep.nix` /
      -- `callPackage ./pkg.nix` resolves to its real type instead of a dynamic.
      let kind = detectedKind (detectKind file expression)
          moduleMode = kind `elem` [Flake, FlakeModule, NixOSModule, HomeModule, DarwinModule]
      crossEnv <- liftIO (Closure.closureEnv builtinEnv file)
      let env = if moduleMode then crossEnv{envModuleParams = True} else crossEnv
      -- n.b. `either` forces inference to WHNF inside the `try`, so an exception
      -- from (pure but partial) inference is caught here; `prettyType` itself
      -- stays a thunk, exactly as the old `case` left it.
      result <-
        liftIO $
          try $
            either
              (pure . Left)
              (pure . Right . NixCompile.Inference.Nix.Type.prettyType . fst)
              (inferExprWithEnv env expression)
      handleResult result
 where
  handleResult (Left exception) = do
    emitDiagnostic $
      Diag.Diagnostic
        { Diag.diagSeverity = ErrorS
        , Diag.diagCode = Just "INTERNAL"
        , Diag.diagSpan = Nothing
        , Diag.diagSummary =
            "internal error (this is a bug in nix-compile): "
              <> T.pack (show (exception :: SomeException))
        , Diag.diagHelp = []
        , Diag.diagSnippet = Nothing
        }
    return TCFail
  handleResult (Right (Left typeError)) =
    bySeverity (Config.effectiveSeverity config Config.typeCheckRuleId)
   where
    bySeverity (Just Config.SevOff) = return TCOk
    bySeverity (Just Config.SevWarning) = emitType WarningS typeError >> return TCOk
    bySeverity _ = emitType ErrorS typeError >> return TCFail
  handleResult (Right (Right _)) = return TCOk

  -- build a TYPE diagnostic and attach the source line/caret from the file
  emitType sev typeError = do
    srcResult <- liftIO (Safety.safeReadFile file)
    let base = typeDiagnostic sev file typeError
    emitDiagnostic (either (const base) (`attachSnippet` base) srcResult)

-- | Format a multi-line type-error string as an indented @TYPE WARNING:@ block.
formatTypeError :: T.Text -> T.Text
formatTypeError errorText = format (T.lines errorText)
 where
  format (firstLine : remainingLines) =
    T.unlines $
      ("  TYPE WARNING: " <> firstLine) : map ("         " <>) remainingLines
  format [] = "  TYPE WARNING: unknown error"

{- | Detect AST shapes that are syntactically valid but semantically unsupported.
n.b. depth checking now lives in 'NixCompile.Core.Safety.analyzeDepth' and runs BEFORE
this; we only flag rec/dynamic-key here, never depth.
-}
detectUnsupportedConstruct :: NExprLoc -> Maybe T.Text
detectUnsupportedConstruct = go
 where
  -- n.b. the dynamic-key NSelect must precede the general NSelect, as in the
  -- original case order
  go (Layer (NSelect _ _ (DynamicKey _ :| _))) = Just "dynamic attribute access"
  go (Layer (NSet Recursive _)) = Just "rec attrset"
  go (Layer (NAbs _ body)) = go body
  go (Layer (NLet bindings body)) = foldl (<|>) (go body) (map detectUnsupportedBinding bindings)
  go (Layer (NSet _ bindings)) = foldl (<|>) Nothing (map detectUnsupportedBinding bindings)
  go (Layer (NList elements)) = foldl (<|>) Nothing (map go elements)
  go (Layer (NBinary _ left right)) = go left <|> go right
  go (Layer (NUnary _ arg)) = go arg
  go (Layer (NSelect _ base _)) = go base
  go (Layer (NHasAttr base attributePath))
    | any isDynamicKey attributePath = Just "dynamic attribute test"
    | otherwise = go base
  go (Layer (NApp function arg)) = go function <|> go arg
  go (Layer (NIf cond thenBranch elseBranch)) = go cond <|> go thenBranch <|> go elseBranch
  go (Layer (NAssert cond body)) = go cond <|> go body
  go (Layer (NWith scope body)) = go scope <|> go body
  go (Layer (NStr (DoubleQuoted parts))) = foldl (<|>) Nothing (map goAnti parts)
  go (Layer (NStr (Indented _ parts))) = foldl (<|>) Nothing (map goAnti parts)
  go _ = Nothing

  goAnti (Antiquoted e) = go e
  goAnti _ = Nothing

  isDynamicKey (DynamicKey _) = True
  isDynamicKey _ = False

{- | Detect an unsupported construct inside a single let/attrset binding,
recursing into its value (and into the source of an @inherit (e) …@).
-}
detectUnsupportedBinding :: Binding NExprLoc -> Maybe T.Text
detectUnsupportedBinding (NamedVar _ e _) = detectUnsupportedConstruct e
detectUnsupportedBinding (Inherit (Just s) _ _) = detectUnsupportedConstruct s
detectUnsupportedBinding (Inherit Nothing _ _) = Nothing
