{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module NixCompile.CLI.Dispatch (
  cmdCheck,
  cmdFmt,
  cmdInfer,
  cmdInferInPlace,
  cmdEmit,
  cmdScope,
  cmdScopeJSON,
  cmdScopeDhall,
  cmdLSP,
)
where

import Control.Monad (forM_, unless)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesDirectoryExist, doesFileExist, renameFile)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (takeExtension)

import Nix.Expr.Types.Annotated (NExprLoc)

import NixCompile (parseScriptFile, scriptSchema)
import NixCompile.CLI.Bash
import NixCompile.CLI.CI
import NixCompile.Core.Config qualified as Config
import NixCompile.Core.Draw qualified as Draw
import NixCompile.Core.Log
import NixCompile.Core.Safety qualified as Safety
import NixCompile.Emit.Config (emitConfigFunction)
import NixCompile.Inference.Nix (builtinEnv)
import NixCompile.Inference.Nix.Annotate qualified as Annotate
import NixCompile.LSP.Handlers qualified as Handlers
import NixCompile.LSP.Server qualified as LSP
import NixCompile.Layout.Scope qualified as Scope
import NixCompile.Syntax.Format qualified as Formatter
import NixCompile.Syntax.Parse qualified as Nix

{- | @check <path>@: dispatch on the path — a directory runs the full CI sweep
('cmdCI'), a @.nix@ file is type-checked, any other file is checked as bash.
A missing path fails via 'failSafety'.
-}
cmdCheck :: Config.Config -> FilePath -> AppM ()
cmdCheck config path = do
  isDir <- liftIO $ doesDirectoryExist path
  if isDir
    then cmdCI config path
    else do
      exists <- liftIO $ doesFileExist path
      if not exists
        then failSafety (T.pack path <> ": no such file or directory")
        else
          if takeExtension path == ".nix"
            then checkNixFile config path
            else checkBashFile config path

{- | Run an analysis pass after enforcing the depth guard.
n.b. every command except `check` flowed through 'inferExpr'/'buildExpr' with no
depth guard; this helper funnels them all through 'Safety.analyzeDepth' first.
-}
withSafeNix :: FilePath -> (NExprLoc -> AppM ()) -> AppM ()
withSafeNix file act = do
  parseResult <- liftIO $ Nix.parseNixFile file
  either failSafety guardDepth parseResult
 where
  guardDepth expr = either depthFailed (const (act expr)) (Safety.analyzeDepth expr)
  depthFailed de = failSafety (Safety.renderSafetyError (Safety.SafetyDepthExceeded de))

{- | @fmt <file>@: format a Nix file and write the result to stdout (after the
depth guard). I/O failures go to stderr via 'failSafety'.
-}
cmdFmt :: FilePath -> AppM ()
cmdFmt file = withSafeNix file $ \expr -> do
  srcResult <- liftIO $ safeReadFile file
  either
    (\err -> failSafety ("I/O error: " <> err))
    (\src -> liftIO $ TIO.putStr $ Formatter.formatNixFile src file expr)
    srcResult

-- | @infer <file>@: print the Nix file annotated with inferred types to stdout.
cmdInfer :: FilePath -> AppM ()
cmdInfer = runInfer (liftIO . TIO.putStr)

{- | @infer -i\/--in-place@: rewrite the file with its annotations instead of
printing to stdout. Idempotent (prior annotations are stripped first) and written
atomically (temp + rename), so a re-run replaces cleanly and a failure never
clobbers the source — and on a parse/type error nothing is written at all.
-}
cmdInferInPlace :: FilePath -> AppM ()
cmdInferInPlace file = runInfer (liftIO . atomicWriteFile file) file

-- | Shared @infer@ core: enrich, annotate, and hand the result to a sink.
runInfer :: (Text -> AppM ()) -> FilePath -> AppM ()
runInfer sink file = withSafeNix file $ \expr -> do
  -- Enrich with real nixpkgs types (best-effort, time-boxed) so a `pkgs.<…>`
  -- reference annotates as its actual type rather than an opaque dynamic.
  env <- liftIO $ Handlers.enrichInferEnv file expr builtinEnv
  result <- liftIO $ Annotate.annotateFileWithEnv env file
  either failSafety sink result

-- | Write a file atomically: a sibling temp then 'renameFile' (atomic on POSIX).
atomicWriteFile :: FilePath -> Text -> IO ()
atomicWriteFile path txt = do
  let tmp = path <> ".nix-compile.tmp"
  TIO.writeFile tmp txt
  renameFile tmp path

{- | @emit <file>@: from a script's inferred schema, emit the generated
@emit-config@ bash function to stdout.
-}
cmdEmit :: FilePath -> AppM ()
cmdEmit file = do
  result <- liftIO $ parseScriptFile file
  either failSafety (liftIO . TIO.putStr . emitConfigFunction . scriptSchema) result

{- | @lsp@: run the language server over stdio until the client disconnects,
then exit cleanly.
-}
cmdLSP :: AppM ()
cmdLSP = liftIO LSP.run >> liftIO exitSuccess

{- | @scope <file>@: build the scope graph and print it as a human-readable
framed report (scopes, declarations, references, edges, resolution) to stdout.
-}
cmdScope :: FilePath -> AppM ()
cmdScope file = withSafeNix file $ \expr -> do
  let scopeGraph = Scope.fromNixFile file expr
  liftIO $ printScopeGraph scopeGraph

-- | @scope --json <file>@: build the scope graph and print it as JSON to stdout.
cmdScopeJSON :: FilePath -> AppM ()
cmdScopeJSON file = withSafeNix file $ \expr -> do
  let scopeGraph = Scope.fromNixFile file expr
  liftIO $ BL.putStrLn $ encode scopeGraph

-- | @scope --dhall <file>@: build the scope graph and print it as Dhall to stdout.
cmdScopeDhall :: FilePath -> AppM ()
cmdScopeDhall file = withSafeNix file $ \expr -> do
  let scopeGraph = Scope.fromNixFile file expr
  liftIO $ TIO.putStrLn $ Scope.toDhall scopeGraph

{- | The uniform CLI failure path: log a message at 'ErrorS' and exit non-zero.
Messages are emitted as-is — callers pass already-categorized text (e.g.
'Safety.renderSafetyError' yields "parse error: …" / "I/O error: …" / "depth
limit exceeded …"), so no prefix is added here (a blanket "Parse error:" would
mislabel I/O and depth failures and double-print for real parse failures).
-}
failSafety :: Text -> AppM a
failSafety err = do
  $(logTM) ErrorS $ logStr err
  liftIO exitFailure

printScopeGraph :: Scope.ScopeGraph -> IO ()
printScopeGraph scopeGraph = do
  TIO.putStrLn (Draw.framed Draw.Double "Scope Graph")
  putStrLn $ "File: " ++ fromMaybe "(none)" (Scope.sgFile scopeGraph)
  putStrLn $ "Scopes: " ++ show (Map.size (Scope.sgScopes scopeGraph))
  putStrLn ""

  forM_ (Map.elems (Scope.sgScopes scopeGraph)) $ \scope -> do
    putStrLn $
      "Scope "
        ++ show (Scope.unScopeId (Scope.scopeId scope))
        ++ " ("
        ++ show (Scope.scopeKind scope)
        ++ "):"

    let decls = Scope.scopeDeclarations scope
    unless (null decls) $ do
      putStrLn "  Declarations:"
      forM_ decls $ \declaration -> do
        TIO.putStrLn $
          "    "
            <> Scope.declName declaration
            <> maybe "" (" : " <>) (Scope.declType declaration)

    let refs = Scope.scopeReferences scope
    unless (null refs) $ do
      putStrLn "  References:"
      forM_ refs $ \reference -> do
        TIO.putStrLn $
          "    "
            <> Scope.refName reference
            <> " ("
            <> T.pack (show (Scope.refKind reference))
            <> ")"

    let edges = Scope.scopeEdges scope
    unless (null edges) $ do
      putStrLn "  Edges:"
      forM_ edges $ \edge -> do
        putStrLn $
          "    -> "
            ++ show (Scope.unScopeId (Scope.edgeTarget edge))
            ++ " ("
            ++ show (Scope.edgeLabel edge)
            ++ ")"

    putStrLn ""

  either reportUnresolved reportResolved (Scope.resolveAll scopeGraph)
 where
  reportUnresolved errors = do
    TIO.putStrLn $
      Draw.framed Draw.Double ("Unresolved References (" <> T.pack (show (length errors)) <> ")")
    forM_ errors printUnresolved
  reportResolved resolved =
    TIO.putStrLn $
      Draw.framed Draw.Double ("All " <> T.pack (show (length resolved)) <> " references resolved")
  printUnresolved (Scope.Unresolved ref) = TIO.putStrLn $ "  " <> Scope.refName ref
  printUnresolved (Scope.Ambiguous ref _) =
    TIO.putStrLn $ "  " <> Scope.refName ref <> " (ambiguous)"
