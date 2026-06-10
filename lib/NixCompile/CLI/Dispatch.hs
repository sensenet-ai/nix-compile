{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module NixCompile.CLI.Dispatch (
  cmdCheck,
  cmdFmt,
  cmdInfer,
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
import System.Directory (doesDirectoryExist, doesFileExist)
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
import NixCompile.Inference.Nix.Annotate qualified as Annotate
import NixCompile.LSP.Server qualified as LSP
import NixCompile.Layout.Scope qualified as Scope
import NixCompile.Syntax.Format qualified as Formatter
import NixCompile.Syntax.Parse qualified as Nix

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

cmdFmt :: FilePath -> AppM ()
cmdFmt file = withSafeNix file $ \expr -> do
  srcResult <- liftIO $ safeReadFile file
  either
    (\err -> failSafety ("I/O error: " <> err))
    (\src -> liftIO $ TIO.putStr $ Formatter.formatNixFile src file expr)
    srcResult

cmdInfer :: FilePath -> AppM ()
cmdInfer file = withSafeNix file $ \_expr -> do
  result <- liftIO $ Annotate.annotateFile file
  either failSafety (liftIO . TIO.putStr) result

cmdEmit :: FilePath -> AppM ()
cmdEmit file = do
  result <- liftIO $ parseScriptFile file
  either failSafety (liftIO . TIO.putStr . emitConfigFunction . scriptSchema) result

cmdLSP :: AppM ()
cmdLSP = liftIO LSP.run >> liftIO exitSuccess

cmdScope :: FilePath -> AppM ()
cmdScope file = withSafeNix file $ \expr -> do
  let scopeGraph = Scope.fromNixFile file expr
  liftIO $ printScopeGraph scopeGraph

cmdScopeJSON :: FilePath -> AppM ()
cmdScopeJSON file = withSafeNix file $ \expr -> do
  let scopeGraph = Scope.fromNixFile file expr
  liftIO $ BL.putStrLn $ encode scopeGraph

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
