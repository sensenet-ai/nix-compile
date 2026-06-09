{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NondecreasingIndentation #-}
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
        then do $(logTM) ErrorS $ logStr $ T.pack path <> ": no such file or directory"; liftIO exitFailure
        else case takeExtension path of
          ".nix" -> checkNixFile config path
          _ -> checkBashFile config path

{- | Run an analysis pass after enforcing the depth guard.
n.b. every command except `check` flowed through 'inferExpr'/'buildExpr' with no
depth guard; this helper funnels them all through 'Safety.analyzeDepth' first.
-}
withSafeNix :: FilePath -> (NExprLoc -> AppM ()) -> AppM ()
withSafeNix file act = do
  parseResult <- liftIO $ Nix.parseNixFile file
  case parseResult of
    Left err -> failSafety err
    Right expr -> case Safety.analyzeDepth expr of
      Left de -> failSafety (Safety.renderSafetyError (Safety.SafetyDepthExceeded de))
      Right () -> act expr

cmdFmt :: FilePath -> AppM ()
cmdFmt file = withSafeNix file $ \expr -> do
  srcResult <- liftIO $ safeReadFile file
  case srcResult of
    Left err -> do $(logTM) ErrorS $ logStr $ "I/O error: " <> err; liftIO exitFailure
    Right src -> liftIO $ TIO.putStr $ Formatter.formatNixFile src file expr

cmdInfer :: FilePath -> AppM ()
cmdInfer file = withSafeNix file $ \_expr -> do
  result <- liftIO $ Annotate.annotateFile file
  case result of
    Left err -> do $(logTM) ErrorS $ logStr err; liftIO exitFailure
    Right formatted -> liftIO $ TIO.putStr formatted

cmdEmit :: FilePath -> AppM ()
cmdEmit file = do
  result <- liftIO $ parseScriptFile file
  case result of
    Left err -> do $(logTM) ErrorS $ logStr err; liftIO exitFailure
    Right script -> do
      liftIO $ TIO.putStr $ emitConfigFunction (scriptSchema script)

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

{- | Report a failure from the safe-parse/depth gate and exit. The message is
already categorized by 'Safety.renderSafetyError' (e.g. "parse error: …",
"I/O error: …", "depth limit exceeded …"), so we emit it as-is — prefixing it
with "Parse error:" mislabeled I/O and depth failures and double-printed
"parse error:" for real parse failures.
-}
failSafety :: Text -> AppM a
failSafety err = do $(logTM) ErrorS $ logStr err; liftIO exitFailure

printScopeGraph :: Scope.ScopeGraph -> IO ()
printScopeGraph scopeGraph = do
  putStrLn "=== Scope Graph ==="
  putStrLn $ "File: " ++ maybe "(none)" id (Scope.sgFile scopeGraph)
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
            <> maybe "" (\typeLabel -> " : " <> typeLabel) (Scope.declType declaration)

    let refs = Scope.scopeReferences scope
    unless (null refs) $ do
      putStrLn "  References:"
      forM_ refs $ \reference -> do
        TIO.putStrLn $ "    " <> Scope.refName reference <> " (" <> T.pack (show (Scope.refKind reference)) <> ")"

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

  case Scope.resolveAll scopeGraph of
    Left errors -> do
      putStrLn $ "=== Unresolved References (" ++ show (length errors) ++ ") ==="
      forM_ errors $ \case
        Scope.Unresolved ref -> TIO.putStrLn $ "  " <> Scope.refName ref
        Scope.Ambiguous ref _ -> TIO.putStrLn $ "  " <> Scope.refName ref <> " (ambiguous)"
    Right resolved -> do
      putStrLn $ "=== All " ++ show (length resolved) ++ " references resolved ==="
