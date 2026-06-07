{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module NixCompile.CLI.Report (
    partitionViolations,
    partitionNixViolations,
    partitionDerivViolations,
    partitionPackageViolations,
    partitionPatternViolations,
    formatBareCommand,
    formatDynamicCommand,
    indentBlock,
    formatPackageViolations,
    reportBareCommands,
    reportDynamicCommands,
    printCheckResult,
    reportNixLintViolations,
    reportDerivViolations,
    reportPatternViolations,
)
where

import Control.Monad.IO.Class (MonadIO (..))
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (exitFailure, exitSuccess)

import NixCompile.CLI.Types
import NixCompile.Config qualified as Config
import NixCompile.Lint.Forbidden (Violation (..))
import NixCompile.Log
import NixCompile.Nix.Lint qualified as Lint
import NixCompile.Nix.LintDerivation qualified as Derivation
import NixCompile.Nix.LintPackages qualified as LintPackages
import NixCompile.Nix.LintPatterns qualified as LintPatterns
import NixCompile.Types (Loc (..), Span (..))

partitionViolations :: Config.Config -> [Violation] -> ([Violation], [Violation])
partitionViolations config = foldr go ([], [])
  where
    go v (suppressed, active)
        | Config.isSuppressed config (Config.bashRuleId (vType v)) = (v : suppressed, active)
        | otherwise = (suppressed, v : active)

partitionNixViolations :: Config.Config -> [Lint.NixViolation] -> ([Lint.NixViolation], [Lint.NixViolation])
partitionNixViolations config = foldr go ([], [])
  where
    go v (suppressed, active)
        | Config.isSuppressed config (Config.nixRuleId (Lint.nvType v)) = (v : suppressed, active)
        | otherwise = (suppressed, v : active)

partitionDerivViolations :: Config.Config -> [Derivation.DerivViolation] -> ([Derivation.DerivViolation], [Derivation.DerivViolation])
partitionDerivViolations config = foldr go ([], [])
  where
    go v (suppressed, active)
        | Config.isSuppressed config (Config.derivRuleId (Derivation.dvType v)) = (v : suppressed, active)
        | otherwise = (suppressed, v : active)

partitionPackageViolations :: Config.Config -> [LintPackages.PackageViolation] -> ([LintPackages.PackageViolation], [LintPackages.PackageViolation])
partitionPackageViolations config = foldr go ([], [])
  where
    go v (suppressed, active)
        | Config.isSuppressed config (Config.packageRuleId (LintPackages.pvCode v)) = (v : suppressed, active)
        | otherwise = (suppressed, v : active)

partitionPatternViolations :: Config.Config -> [LintPatterns.PatternViolation] -> ([LintPatterns.PatternViolation], [LintPatterns.PatternViolation])
partitionPatternViolations config = foldr go ([], [])
  where
    go v (suppressed, active)
        | Config.isSuppressed config (Config.patternRuleId (LintPatterns.pvType v)) = (v : suppressed, active)
        | otherwise = (suppressed, v : active)

formatBareCommand :: Text -> (Text, Span) -> Text
formatBareCommand src (cmd, sourceSpan) =
    let tok = locLine (spanStart sourceSpan)
     in T.unlines
            [ "error[ALEPH-B005]: bare command not allowed: " <> cmd
            , "  --> " <> src <> ":" <> T.pack (show tok)
            , ""
            , "  Use an explicit store path for external commands:"
            , "    /nix/store/...-pkg/bin/" <> cmd
            ]

formatDynamicCommand :: Text -> (Text, Span) -> Text
formatDynamicCommand src (var, sourceSpan) =
    let tok = locLine (spanStart sourceSpan)
     in T.unlines
            [ "error[ALEPH-B006]: dynamic command not allowed: $" <> var
            , "  --> " <> src <> ":" <> T.pack (show tok)
            , ""
            , "  Dynamic command selection is not statically analyzable."
            , "  Use a known store path or a case statement over a small allowlist."
            ]

indentBlock :: Text -> Text -> Text
indentBlock prefix block =
    T.unlines [prefix <> line | line <- T.lines block]

formatPackageViolations :: [LintPackages.PackageViolation] -> Text
formatPackageViolations [] = ""
formatPackageViolations violations =
    T.unlines
        [ "ALEPH-P001: Package directories must contain a `default.nix` file:"
        , ""
        ]
        <> T.unlines (map (\violation -> "  " <> T.pack (LintPackages.pvPath violation)) violations)

-- n.b. diagnostics go to stderr via katip (the stdout/stderr contract); only a
-- command's product (formatted source, scope JSON, …) is allowed on stdout.
reportBareCommands :: FilePath -> [(Text, Span)] -> AppM ()
reportBareCommands file bareFacts
    | null bareFacts = pure ()
    | otherwise =
        $(logTM) ErrorS $
            logStr $
                "\nBare commands (external commands must use store paths; shell builtins allowed):\n"
                    <> T.concat (map (formatBareCommand (T.pack file)) bareFacts)

reportDynamicCommands :: FilePath -> [(Text, Span)] -> AppM ()
reportDynamicCommands file dynFacts
    | null dynFacts = pure ()
    | otherwise =
        $(logTM) ErrorS $
            logStr $
                "\nDynamic commands (cannot analyze):\n"
                    <> T.concat (map (formatDynamicCommand (T.pack file)) dynFacts)

printCheckResult :: FilePath -> Int -> AppM ()
printCheckResult file totalErrors
    | totalErrors > 0 = do
        $(logTM) ErrorS $ logStr $ T.pack $ "\n" ++ show totalErrors ++ " error(s) in " ++ file
        liftIO exitFailure
    | otherwise = do
        $(logTM) InfoS $ logStr $ T.pack $ file ++ ": OK"
        liftIO exitSuccess

reportNixLintViolations :: FilePath -> [Lint.NixViolation] -> AppM ()
reportNixLintViolations file violations
    | null violations = pure ()
    | otherwise = do
        $(logTM) ErrorS $
            logStr $
                T.unlines
                    [ ""
                    , "━━━ " <> crossMarker <> " " <> T.pack file <> " ━━━"
                    , ""
                    , "  NIX LINT VIOLATIONS:"
                    , ""
                    ]
        $(logTM) ErrorS $ logStr $ Lint.formatNixViolations violations

reportDerivViolations :: FilePath -> [Derivation.DerivViolation] -> AppM ()
reportDerivViolations file violations
    | null violations = pure ()
    | otherwise = do
        $(logTM) WarningS $
            logStr $
                T.unlines
                    [ ""
                    , "━━━ " <> crossMarker <> " " <> T.pack file <> " ━━━"
                    , ""
                    , "  DERIVATION QUALITY VIOLATIONS:"
                    , ""
                    ]
        $(logTM) WarningS $ logStr $ Derivation.formatDerivViolations violations

reportPatternViolations :: FilePath -> [LintPatterns.PatternViolation] -> AppM ()
reportPatternViolations file violations
    | null violations = pure ()
    | otherwise = do
        $(logTM) WarningS $
            logStr $
                T.unlines
                    [ ""
                    , "━━━ " <> crossMarker <> " " <> T.pack file <> " ━━━"
                    , ""
                    , "  PATTERN VIOLATIONS:"
                    , ""
                    ]
        $(logTM) WarningS $ logStr $ LintPatterns.formatPatternViolations violations
