{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- nix-compile - CLI for compile-time Nix type inference
--
-- Usage:
--   nix-compile parse <script>       Parse and show facts
--   nix-compile infer <script>       Infer types and show schema
--   nix-compile check <script>       Check for policy violations
--   nix-compile lint <script>        Check for forbidden constructs
--   nix-compile emit <script>       Generate emit-config bash function
--   nix-compile nix <file.nix>       Check embedded bash in Nix files
module Main (main) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import NixCompile hiding (Severity)
import NixCompile.Log
import NixCompile.Pretty (renderStdOut)
import NixCompile.Bash.Parse (parseBash)
import NixCompile.Bash.Facts (extractFacts)
import qualified NixCompile.LSP.Server as LSP
import qualified NixCompile.Docs.Extract as Docs
import qualified NixCompile.Docs.Search as Search
import qualified NixCompile.Docs.Types as Docs
import qualified NixCompile.Nix.Pretty as NixPretty
import NixCompile.Emit.Config (emitConfigFunction)
import NixCompile.Lint.Forbidden (findViolations, formatViolationsAt)
import NixCompile.Infer.Constraint (factsToConstraints)
import NixCompile.Infer.Unify (solve)
import NixCompile.Schema.Build (buildSchema)
import qualified NixCompile.Check as Check
import qualified NixCompile.Nix.Infer
import qualified NixCompile.Nix.Parse as Nix
import qualified NixCompile.Nix.Format as NixFmt
import qualified NixCompile.Nix.Flake as Flake
import qualified NixCompile.Nix.Module as Mod
import qualified NixCompile.Nix.Layout as Layout
import qualified NixCompile.Nix.Lint as Lint
import qualified NixCompile.Nix.Scope as Scope
import qualified NixCompile.Nix.Types
import qualified Data.Map.Strict as Map
import Control.Monad.IO.Class (MonadIO (..))
import GHC.IO.Encoding (setLocaleEncoding, utf8)

-- hnix imports for detectUnsupported function
import Data.Fix (Fix(..))
import Data.Functor.Compose (Compose(..))
import Data.List.NonEmpty (NonEmpty(..))
import Nix.Expr.Types
import Nix.Expr.Types.Annotated (AnnUnit(..), NExprLoc)
import Control.Applicative ((<|>))
import Control.Monad (forM, forM_, unless, void)
import Control.Concurrent.Async (mapConcurrently)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>), takeExtension, makeRelative, takeDirectory)
import Control.Exception (SomeException, try)

data TCResult = TCOk | TCFail | TCSkip
  deriving (Eq, Show)

main :: IO ()
main = do
  setLocaleEncoding utf8
  runLog InfoS $ do
    args <- liftIO getArgs
    case args of
      -- Legacy single-file commands
      ["lint", file] -> cmdLint file
      ["check", file] -> cmdCheck file
      ["infer", file] -> cmdInfer file
      ["parse", file] -> cmdParse file
      ["emit", file] -> cmdEmit file
      ["nix", file] -> cmdNix file
      ["fmt", file] -> cmdFmt file
      ["annotate", file] -> cmdAnnotate file
      ["lsp"] -> liftIO $ void LSP.run
      ["search", query, file] -> cmdSearch (T.pack query) file
      ["docs", file] -> cmdDocs file
      ["typecheck", path] -> cmdTypeCheck path
      ["flake"] -> cmdFlake "."
      ["flake", dir] -> cmdFlake dir
      ["graph"] -> cmdGraph "." False
      ["graph", dir] -> cmdGraph dir False
      ["graph", "--dot"] -> cmdGraph "." True
      ["graph", "--dot", dir] -> cmdGraph dir True
      ["graph", dir, "--dot"] -> cmdGraph dir True
      ["scope", file] -> cmdScope file
      ["scope", "--json", file] -> cmdScopeJSON file
      ["scope", "--dhall", file] -> cmdScopeDhall file
      ["--help"] -> liftIO usage
      ["-h"] -> liftIO usage

      -- Repository-wide check (default)
      _ -> do
        let (paths, cfg) = parseConfigArgs Check.defaultConfig args
        let paths' = if null paths then ["."] else paths
        cmdRepoCheck cfg paths'

parseConfigArgs :: Check.Config -> [String] -> ([FilePath], Check.Config)
parseConfigArgs cfg [] = ([], cfg)
parseConfigArgs cfg ("-p":p:rest) = parseConfigArgs (withProfile p cfg) rest
parseConfigArgs cfg ("--profile":p:rest) = parseConfigArgs (withProfile p cfg) rest
parseConfigArgs cfg ("-l":l:rest) = parseConfigArgs (withLayout l cfg) rest
parseConfigArgs cfg ("--layout":l:rest) = parseConfigArgs (withLayout l cfg) rest
parseConfigArgs cfg (x:xs) =
  let (paths, newCfg) = parseConfigArgs cfg xs
  in (x:paths, newCfg)

withProfile :: String -> Check.Config -> Check.Config
withProfile s cfg = cfg { Check.cProfile = readProfile s }

withLayout :: String -> Check.Config -> Check.Config
withLayout s cfg = cfg { Check.cLayout = readLayout s }

readProfile :: String -> Check.Profile
readProfile s = case map toLower s of
  "strict"   -> Check.Strict
  "standard" -> Check.Standard
  "minimal"  -> Check.Minimal
  "nixpkgs"  -> Check.Nixpkgs
  "security" -> Check.Security
  _          -> Check.Standard
  where
    toLower c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

readLayout :: String -> Check.LayoutMode
readLayout s = case map toLower s of
  "straylight"  -> Check.LayoutStraylight
  "flake-parts" -> Check.LayoutFlakeParts
  "nixpkgs"     -> Check.LayoutNixpkgs
  "nixos"       -> Check.LayoutNixOSConfig
  "none"        -> Check.LayoutNone
  _             -> Check.LayoutNone
  where
    toLower c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

cmdRepoCheck :: Check.Config -> [FilePath] -> AppM ()
cmdRepoCheck cfg paths = do
  result <- liftIO $ Check.checkWithConfig cfg paths
  if Check.isClean result
    then liftIO exitSuccess
    else liftIO exitFailure

usage :: IO ()
usage = do
  putStrLn "nix-compile — static analysis for Nix and bash"
  putStrLn ""
  putStrLn "USAGE"
  putStrLn "  nix-compile [OPTIONS] [PATHS...]    Analyze paths (default: current directory)"
  putStrLn ""
  putStrLn "OPTIONS"
  putStrLn "  -p, --profile <profile>   Analysis profile (default: standard)"
  putStrLn "  -l, --layout <layout>     Directory layout convention (default: none)"
  putStrLn "  -h, --help                Show this help"
  putStrLn ""
  putStrLn "PROFILES"
  putStrLn "  strict    Full aleph conventions (lisp-case, Dhall templating)"
  putStrLn "  standard  Sensible defaults for most projects"
  putStrLn "  minimal   Essential safety checks only"
  putStrLn "  nixpkgs   nixpkgs contribution guidelines"
  putStrLn "  security  Security-focused checks"
  putStrLn ""
  putStrLn "LAYOUTS"
  putStrLn "  straylight   nix/modules/{flake,nixos,home}/, nix/packages/"
  putStrLn "  flake-parts  modules/, packages/, overlays/"
  putStrLn "  nixpkgs      pkgs/by-name/XX/name/package.nix"
  putStrLn "  nixos        hosts/, modules/, users/"
  putStrLn "  none         No layout enforcement (default)"
  putStrLn ""
  putStrLn "EXIT CODES"
  putStrLn "  0  Clean — no issues"
  putStrLn "  1  Issues found (errors, warnings, info, or parse failures)"
  putStrLn ""
  putStrLn "EXAMPLES"
  putStrLn "  nix-compile                           # check current directory"
  putStrLn "  nix-compile nix/ lib/                 # check specific paths"
  putStrLn "  nix-compile -p strict                 # strict mode"
  putStrLn "  nix-compile -l straylight             # enforce straylight layout"
  putStrLn "  nix-compile -p strict -l straylight   # both"
  putStrLn ""
  putStrLn "LEGACY COMMANDS (single file)"
  putStrLn "  nix-compile lint <script.sh>    Forbidden constructs only"
  putStrLn "  nix-compile check <script.sh>   Full check (lint + policy + types)"
  putStrLn "  nix-compile infer <script.sh>   Infer types, emit JSON schema"
  putStrLn "  nix-compile parse <script.sh>   Parse and show facts"
  putStrLn "  nix-compile emit <script.sh>    Generate emit-config function"
  putStrLn "  nix-compile nix <file.nix>      Check embedded bash in Nix"
  putStrLn "  nix-compile fmt <file.nix>      Add type annotations"
  putStrLn "  nix-compile typecheck <path>    Recursive type inference"
  putStrLn "  nix-compile flake [dir]         Analyze a flake"
  putStrLn "  nix-compile graph [--dot] [dir] Module dependency graph"
  putStrLn "  nix-compile scope <file.nix>    Show scope graph"

-- ============================================================================
-- Pretty-printing for bash policy violations
-- ============================================================================

formatBareCommand :: T.Text -> (T.Text, Span) -> T.Text
formatBareCommand src (cmd, sp) =
  let tok = locLine (spanStart sp)
   in T.unlines
        [ "error[ALEPH-B005]: bare command not allowed: " <> cmd
        , "  --> " <> src <> ":" <> T.pack (show tok)
        , ""
        , "  Use an explicit store path for external commands:"
        , "    /nix/store/...-pkg/bin/" <> cmd
        ]

formatDynamicCommand :: T.Text -> (T.Text, Span) -> T.Text
formatDynamicCommand src (var, sp) =
  let tok = locLine (spanStart sp)
   in T.unlines
        [ "error[ALEPH-B006]: dynamic command not allowed: $" <> var
        , "  --> " <> src <> ":" <> T.pack (show tok)
        , ""
        , "  Dynamic command selection is not statically analyzable."
        , "  Use a known store path or a case statement over a small allowlist."
        ]

-- | Indent every line of a multi-line block.
indentBlock :: T.Text -> T.Text -> T.Text
indentBlock prefix block =
  T.unlines [prefix <> line | line <- T.lines block]

cmdParse :: FilePath -> AppM ()
cmdParse file = do
  result <- liftIO $ parseScriptFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right script -> do
      liftIO $ putStrLn "Facts:"
      liftIO $ mapM_ print (scriptFacts script)

cmdInfer :: FilePath -> AppM ()
cmdInfer file = do
  result <- liftIO $ parseScriptFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right script -> do
      liftIO $ BL.putStrLn (encode (scriptSchema script))

-- | Lint for forbidden constructs only (heredocs, eval, backticks)
cmdLint :: FilePath -> AppM ()
cmdLint file = do
  src <- liftIO $ TIO.readFile file
  case parseBash src of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right ast -> do
      let violations = findViolations ast
      if null violations
        then do
          $(logTM) InfoS $ logStr $ T.pack $ file ++ ": OK (no forbidden constructs)"
          liftIO exitSuccess
        else do
          $(logTM) ErrorS $ logStr $ formatViolationsAt (T.pack file) violations
          $(logTM) ErrorS $ logStr $ T.pack $ "\n" ++ show (length violations) ++ " error(s) in " ++ file
          liftIO exitFailure

-- | Full check: lint + bare commands + type inference
cmdCheck :: FilePath -> AppM ()
cmdCheck file = do
  src <- liftIO $ TIO.readFile file
  -- First check for forbidden constructs
  case parseBash src of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right ast -> do
      let violations = findViolations ast
      unless (null violations) $ do
        $(logTM) ErrorS $ logStr $ formatViolationsAt (T.pack file) violations
        liftIO $ putStrLn ""
      
      -- Then do type inference and check policy violations
      let facts = extractFacts ast
      let constraints = factsToConstraints facts
      _subst <- case solve constraints of
        Left err -> do
          $(logTM) ErrorS $ logStr $ "Type error: " <> T.pack (show err)
          liftIO exitFailure
        Right s -> pure s

      let bareFacts = [(cmd, sp) | BareCommand cmd sp <- facts]
      let dynFacts = [(var, sp) | DynamicCommand var sp <- facts]
      let bareCount = length bareFacts
      let dynCount = length dynFacts
      let violationCount = length violations

      -- Report bare commands
      unless (null bareFacts) $ do
        liftIO $ TIO.putStrLn ""
        liftIO $ TIO.putStrLn "Bare commands (external commands must use store paths; shell builtins allowed):"
        liftIO $ mapM_ (TIO.putStr . formatBareCommand (T.pack file)) bareFacts

      -- Report dynamic commands
      unless (null dynFacts) $ do
        liftIO $ TIO.putStrLn ""
        liftIO $ TIO.putStrLn "Dynamic commands (cannot analyze):"
        liftIO $ mapM_ (TIO.putStr . formatDynamicCommand (T.pack file)) dynFacts

      let totalErrors = violationCount + bareCount + dynCount
      if totalErrors > 0
        then do
          $(logTM) ErrorS $ logStr $ T.pack $ "\n" ++ show totalErrors ++ " error(s) in " ++ file
          liftIO exitFailure
        else do
          $(logTM) InfoS $ logStr $ T.pack $ file ++ ": OK"
          liftIO exitSuccess

cmdEmit :: FilePath -> AppM ()
cmdEmit file = do
  result <- liftIO $ parseScriptFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right script -> do
      liftIO $ renderStdOut $ emitConfigFunction (scriptSchema script)

-- | Check embedded bash scripts in Nix files
cmdNix :: FilePath -> AppM ()
cmdNix file = do
  result <- liftIO $ Nix.extractBashScripts file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right scripts -> do
      $(logTM) InfoS $ logStr $ T.pack $ "Found " ++ show (length scripts) ++ " shell scripts in " ++ file
      totalErrors <- sum <$> mapM checkScript scripts
      if totalErrors > 0
        then do
          $(logTM) ErrorS $ logStr $ T.pack $ "\n" ++ show totalErrors ++ " total error(s)"
          liftIO exitFailure
        else do
          $(logTM) InfoS $ logStr $ T.pack $ file ++ ": OK"
          liftIO exitSuccess
  where
    checkScript :: Nix.BashScript -> AppM Int
    checkScript bs = do
      $(logTM) InfoS $ logStr $ "\n=== " <> Nix.bsName bs <> " ==="
      -- Parse and check the bash content
      case parseBash (Nix.bsContent bs) of
        Left err -> do
          $(logTM) ErrorS $ logStr $ "  Parse error: " <> err
          return 1
        Right ast -> do
          -- Check for forbidden constructs
          let violations = findViolations ast
          unless (null violations) $ do
            let srcLabel = T.pack file <> ":" <> Nix.bsName bs
            $(logTM) ErrorS $ logStr $ formatViolationsAt srcLabel violations
          
          -- Check for non-store-path interpolations
          let badInterps = filter (not . Nix.intIsStorePath) (Nix.bsInterpolations bs)
          unless (null badInterps) $ do
            $(logTM) WarningS $ logStr "  Non-store-path interpolations (may need verification):"
            liftIO $ mapM_ (\i -> putStrLn $ "    ${" ++ T.unpack (Nix.intExpr i) ++ "}") badInterps
          
          -- Type inference and policy checks
          let facts = extractFacts ast
          let constraints = factsToConstraints facts
          schema <- case solve constraints of
            Left err -> do
              $(logTM) ErrorS $ logStr $ "  Type error: " <> T.pack (show err)
              return emptySchema
            Right subst -> pure (buildSchema facts subst)

          -- Cross-language type inference: find types for Nix interpolations
          let interps = Nix.bsInterpolations bs
          let interpTypes = mapInterpTypesToNix schema interps
          unless (null interpTypes) $ do
            $(logTM) InfoS $ logStr "  Nix interpolation types inferred from bash context:"
            liftIO $ mapM_ (\(expr, ty) -> 
              putStrLn $ "    ${" ++ T.unpack expr ++ "} :: " ++ show ty
              ) interpTypes

          let bareFacts = [(cmd, sp) | BareCommand cmd sp <- facts]
          let dynFacts = [(var, sp) | DynamicCommand var sp <- facts]
          let bareCount = length bareFacts
          let dynCount = length dynFacts

          unless (null bareFacts) $ do
            $(logTM) ErrorS $ logStr "  Bare commands (external commands must use store paths; shell builtins allowed):"
            let srcLabel = T.pack file <> ":" <> Nix.bsName bs
            liftIO $ mapM_ (TIO.putStr . indentBlock "  " . formatBareCommand srcLabel) bareFacts

          unless (null dynFacts) $ do
            $(logTM) ErrorS $ logStr "  Dynamic commands (cannot analyze):"
            let srcLabel = T.pack file <> ":" <> Nix.bsName bs
            liftIO $ mapM_ (TIO.putStr . indentBlock "  " . formatDynamicCommand srcLabel) dynFacts

          let errorCount = length violations + bareCount + dynCount
          if errorCount == 0
            then $(logTM) InfoS "  OK"
            else $(logTM) ErrorS $ logStr $ T.pack $ "  " ++ show errorCount ++ " error(s)"
          return errorCount

-- | Recursively type check a directory or single file in parallel
cmdTypeCheck :: FilePath -> AppM ()
cmdTypeCheck path = do
  isDir <- liftIO $ doesDirectoryExist path
  files <- if isDir 
           then liftIO $ findAllNixFiles path
           else return [path]
  
  $(logTM) InfoS $ logStr $ T.unlines
    [ ""
    , "================================================================"
    , "  nix-compile typecheck"
    , "  " <> T.pack (show (length files) <> " files")
    , "================================================================"
    , ""
    ]
  
  -- We don't use MVar for logging anymore, we use Katip
  -- But we need to pass the logging environment to the threads
  env <- getLogEnv
  ctx <- getKatipContext
  ns <- getKatipNamespace
  
  results <- liftIO $ mapConcurrently (checkFileWrapper (env, ctx, ns)) files
  let okCount = length [() | r <- results, r == TCOk]
  let skipCount = length [() | r <- results, r == TCSkip]
  let failCount = length [() | r <- results, r == TCFail]
  
  $(logTM) InfoS $ logStr $ T.unlines
    [ ""
    , "================================================================"
    , "  Summary"
    , "  " <> T.pack (show okCount <> " passed")
    , "  " <> T.pack (show skipCount <> " skipped (unsupported constructs)")
    , "  " <> T.pack (show failCount <> " failed")
    , "================================================================"
    , ""
    ]
  
  if failCount == 0
    then liftIO exitSuccess
    else liftIO exitFailure
  where
    findAllNixFiles :: FilePath -> IO [FilePath]
    findAllNixFiles dir = do
      entries <- listDirectory dir
      paths <- forM entries $ \entry -> do
        let fullPath = dir </> entry
        -- Skip excluded directories
        if entry `elem` [".git", ".direnv", "node_modules", ".cache", ".lake", "result", "result-lib", "target"]
          then return []
          else do
            isD <- doesDirectoryExist fullPath
            if isD
              then findAllNixFiles fullPath
              else return [fullPath | takeExtension fullPath == ".nix"]
      return (concat paths)

    checkFileWrapper :: (LogEnv, LogContexts, Namespace) -> FilePath -> IO TCResult
    checkFileWrapper (le, ctx, ns) file = runKatipContextT le ctx ns (checkFile file)

    checkFile :: FilePath -> AppM TCResult
    checkFile file = do
      -- First check if file uses unsupported constructs
      parseRes <- liftIO $ Nix.parseNixFile file
      case parseRes of
        Left err -> do
          $(logTM) ErrorS $ logStr $ T.unlines
            [ ""
            , "━━━ " <> cross <> " " <> T.pack file <> " ━━━"
            , ""
            , "  PARSE ERROR: " <> err
            , ""
            ]
          return TCFail
        Right expr -> 
          case detectUnsupported expr of
            Just reason -> do
              -- Skip files with unsupported constructs
              $(logTM) InfoS $ logStr $ skip <> " " <> T.pack file <> " (unsupported: " <> reason <> ")"
              return TCSkip
            Nothing -> do
              -- Type check the file
              result <- liftIO $ try $ case NixCompile.Nix.Infer.inferExpr expr of
                Left err -> return $ Left err
                Right (t, _) -> return $ Right (NixCompile.Nix.Types.prettyType t)
                
              case result of
                Left (e :: SomeException) -> do
                  $(logTM) ErrorS $ logStr $ T.unlines
                    [ ""
                    , "━━━ " <> cross <> " " <> T.pack file <> " ━━━"
                    , ""
                    , "  INTERNAL ERROR (this is a bug in nix-compile):"
                    , ""
                    , T.unlines $ map ("     " <>) $ T.lines $ T.pack $ show e
                    ]
                  return TCFail
                Right (Left err) -> do
                  $(logTM) ErrorS $ logStr $ T.unlines
                    [ ""
                    , "━━━ " <> cross <> " " <> T.pack file <> " ━━━"
                    , ""
                    , formatError err
                    , ""
                    ]
                  return TCFail
                Right (Right _t) -> do
                  $(logTM) InfoS $ logStr $ check <> " " <> T.pack file
                  return TCOk
      where
        check = "[OK]"
        cross = "[XX]"
        skip = "[SKIP]"
        
        formatError :: T.Text -> T.Text
        formatError err = 
          let lines' = T.lines err
          in case lines' of
               (first:rest) -> T.unlines $ ("  ERROR: " <> first) : map ("         " <>) rest
               [] -> "  ERROR: unknown error"
        
        -- Detect unsupported constructs that are fundamentally incompatible with static analysis
        detectUnsupported :: NExprLoc -> Maybe T.Text
        detectUnsupported (Fix (Compose (AnnUnit _ expr))) = case expr of
          -- Dynamic attribute access
          NSelect _ _ (DynamicKey _ :| _) -> Just "dynamic attribute access"
          -- with expression
          NWith _ _ -> Just "with expression"
          -- Dynamic imports (NImport removed in hnix 0.17.0)
          -- NImport path -> case path of
          --   Fix (Compose (AnnUnit _ (NStr _))) -> Just "dynamic import"
          --   _ -> Nothing
          -- Recursively check sub-expressions
          NAbs _ body -> detectUnsupported body
          NLet bindings body -> 
            foldl (<|>) (detectUnsupported body) (map detectUnsupportedBinding bindings)
          NSet _ bindings ->
            foldl (<|>) Nothing (map detectUnsupportedBinding bindings)
          NList elems ->
            foldl (<|>) Nothing (map detectUnsupported elems)
          NBinary _ left right ->
            detectUnsupported left <|> detectUnsupported right
          NUnary _ arg -> detectUnsupported arg
          NSelect _ base _ -> detectUnsupported base
          NHasAttr base _ -> detectUnsupported base
          NApp fun arg -> detectUnsupported fun <|> detectUnsupported arg
          NIf cond t f -> detectUnsupported cond <|> detectUnsupported t <|> detectUnsupported f
          NAssert cond body -> detectUnsupported cond <|> detectUnsupported body
          _ -> Nothing
        
        detectUnsupportedBinding :: Binding NExprLoc -> Maybe T.Text
        detectUnsupportedBinding binding = case binding of
          NamedVar _ expr _ -> detectUnsupported expr
          Inherit _ _ _ -> Nothing

-- | Format a Nix file (pretty print AST)
cmdFmt :: FilePath -> AppM ()
cmdFmt file = do
  result <- liftIO $ Nix.parseNixFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right expr -> do
      let doc = NixPretty.prettyNix expr
      liftIO $ renderStdOut doc

-- | Add type annotations to a Nix file (legacy fmt)
cmdAnnotate :: FilePath -> AppM ()
cmdAnnotate file = do
  result <- liftIO $ NixFmt.formatFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right formatted -> do
      liftIO $ TIO.putStr formatted

-- | Analyze a flake
cmdFlake :: FilePath -> AppM ()
cmdFlake dir = do
  result <- liftIO $ Flake.parseFlakeDir dir
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right flake -> do
      liftIO $ putStrLn "=== Flake ==="
      liftIO $ putStrLn $ "Path: " ++ Flake.flakePath flake
      liftIO $ TIO.putStrLn $ "Description: " <> maybe "(none)" id (Flake.flakeDescription flake)
      
      liftIO $ putStrLn "\n=== Inputs ==="
      liftIO $ mapM_ printInput (Map.toList $ Flake.flakeInputs flake)
      
      liftIO $ putStrLn "\n=== Inferred Type ==="
      let types = Flake.inferFlake flake
      liftIO $ TIO.putStrLn $ "outputs : " <> prettyType (Flake.ftOutputsType types)
  where
    printInput (name, input) = do
      TIO.putStr $ "  " <> name <> " : FlakeInput"
      case Flake.inputUrl input of
        Just url -> TIO.putStrLn $ " = \"" <> url <> "\""
        Nothing -> case Flake.inputFollows input of
          Just follows -> TIO.putStrLn $ " (follows " <> follows <> ")"
          Nothing -> putStrLn ""
    
    prettyType = NixCompile.Nix.Types.prettyType

-- | Show module dependency graph
cmdGraph :: FilePath -> Bool -> AppM ()
cmdGraph dir asDot = do
  result <- liftIO $ Mod.buildModuleGraphFromFlake dir
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right graph -> do
      let rootDir = takeDirectory (Mod.mgRoot graph)
      if asDot
        then liftIO $ printDot rootDir graph
        else do
          liftIO $ printGraph rootDir graph
          -- Exit with failure if there are any violations
          if Mod.hasViolations graph
            then liftIO exitFailure
            else liftIO exitSuccess
  where
    printGraph :: FilePath -> Mod.ModuleGraph -> IO ()
    printGraph rootDir graph = do
      putStrLn "=== Module Graph ==="
      putStrLn $ "Root: " ++ makeRelative rootDir (Mod.mgRoot graph)
      putStrLn $ "Modules: " ++ show (Map.size (Mod.mgModules graph))
      
      let parseFailures = Mod.mgFailures graph
      let lintFailures = Mod.mgLintFailures graph
      let layoutFailures = Mod.mgLayoutFailures graph
      let lintViolationCount = sum (map (length . Mod.lfViolations) lintFailures)
      let layoutViolationCount = sum (map (length . Mod.layViolations) layoutFailures)
      
      if null parseFailures && null lintFailures && null layoutFailures
        then putStrLn ""
        else do
          if not (null parseFailures)
            then do
              putStrLn $ "Parse failures: " ++ show (length parseFailures)
              putStrLn ""
              putStrLn "=== Parse Failures (banned syntax) ==="
              mapM_ (printParseFailure rootDir) parseFailures
              putStrLn ""
            else return ()
          
          if not (null lintFailures)
            then do
              putStrLn $ "Lint violations: " ++ show lintViolationCount ++ " in " ++ show (length lintFailures) ++ " files"
              putStrLn ""
              putStrLn "=== Lint Failures (with/rec banned) ==="
              mapM_ (printLintFailure rootDir) lintFailures
              putStrLn ""
            else return ()
          
          if not (null layoutFailures)
            then do
              putStrLn $ "Layout violations: " ++ show layoutViolationCount ++ " in " ++ show (length layoutFailures) ++ " files"
              putStrLn ""
              putStrLn "=== Layout Failures (directory structure) ==="
              mapM_ (printLayoutFailure rootDir) layoutFailures
              putStrLn ""
            else return ()
      
      putStrLn "=== Topological Order (dependencies first) ==="
      mapM_ (\p -> putStrLn $ "  " ++ makeRelative rootDir p) (Mod.mgOrder graph)
      putStrLn ""
      
      putStrLn "=== Import Graph ==="
      mapM_ (printModuleImports rootDir) (Map.elems (Mod.mgModules graph))
      
      putStrLn ""
      putStrLn "=== Module Types ==="
      mapM_ (printModuleType rootDir graph) (Mod.mgOrder graph)
    
    printParseFailure :: FilePath -> Mod.ParseFailure -> IO ()
    printParseFailure rootDir pf = do
      let path = makeRelative rootDir (Mod.pfPath pf)
      TIO.putStrLn $ "  " <> T.pack path <> ":"
      -- Extract just the first line of the error (location info)
      let errLines = T.lines (Mod.pfError pf)
      case errLines of
        (l:_) -> TIO.putStrLn $ "    " <> l
        [] -> return ()
    
    printLintFailure :: FilePath -> Mod.LintFailure -> IO ()
    printLintFailure rootDir lf = do
      let path = makeRelative rootDir (Mod.lfPath lf)
      TIO.putStrLn $ "  " <> T.pack path <> ":"
      mapM_ printViolation (Mod.lfViolations lf)
    
    printViolation :: Lint.NixViolation -> IO ()
    printViolation v = do
      let loc = Lint.nvSpan v
      let code = case Lint.nvType v of
            Lint.VWith -> "ALEPH-N001"
            Lint.VRec -> "ALEPH-N002"
      TIO.putStrLn $ "    " <> T.pack (show (locLine (spanStart loc))) <> ":" <>
                     T.pack (show (locCol (spanStart loc))) <> " " <> code <> ": " <>
                     Lint.nvContext v
    
    locLine (Loc l _) = l
    locCol (Loc _ c) = c
    spanStart (Span s _ _) = s
    
    printLayoutFailure :: FilePath -> Mod.LayoutFailure -> IO ()
    printLayoutFailure rootDir lf = do
      let path = makeRelative rootDir (Mod.layPath lf)
      TIO.putStrLn $ "  " <> T.pack path <> ":"
      mapM_ printLayoutViolation (Mod.layViolations lf)
    
    printLayoutViolation :: Layout.LayoutViolation -> IO ()
    printLayoutViolation v = do
      let code = case Layout.lvCode v of
            Layout.L001 -> "ALEPH-L001"
            Layout.L002 -> "ALEPH-L002"
            Layout.L003 -> "ALEPH-L003"
            Layout.L004 -> "ALEPH-L004"
            Layout.L005 -> "ALEPH-L005"
      case Layout.lvSpan v of
        Just loc -> 
          TIO.putStrLn $ "    " <> T.pack (show (locLine (spanStart loc))) <> ":" <>
                         T.pack (show (locCol (spanStart loc))) <> " " <> code <> ": " <>
                         Layout.lvMessage v
        Nothing ->
          TIO.putStrLn $ "    " <> code <> ": " <> Layout.lvMessage v
    
    printModuleImports :: FilePath -> Mod.Module -> IO ()
    printModuleImports rootDir m = do
      let path = makeRelative rootDir (Mod.modPath m)
      let imports = Mod.modImports m
      if null imports
        then return ()
        else do
          putStrLn $ path ++ ":"
          mapM_ (\imp -> putStrLn $ "  -> " ++ makeRelative rootDir (Mod.impPath imp)) imports
    
    printModuleType :: FilePath -> Mod.ModuleGraph -> FilePath -> IO ()
    printModuleType rootDir graph path =
      case Map.lookup path (Mod.mgModules graph) of
        Nothing -> return ()
        Just m -> do
          let relPath = makeRelative rootDir path
          TIO.putStrLn $ T.pack relPath <> " : " <> NixCompile.Nix.Types.prettyType (Mod.modType m)
    
    printDot :: FilePath -> Mod.ModuleGraph -> IO ()
    printDot rootDir graph = do
      putStrLn "digraph modules {"
      putStrLn "  rankdir=LR;"
      putStrLn "  node [shape=box];"
      putStrLn ""
      mapM_ (printDotEdges rootDir) (Map.elems (Mod.mgModules graph))
      putStrLn "}"
    
    printDotEdges :: FilePath -> Mod.Module -> IO ()
    printDotEdges rootDir m = do
      let path = makeRelative rootDir (Mod.modPath m)
      mapM_ (\imp -> do
        let impPath = makeRelative rootDir (Mod.impPath imp)
        putStrLn $ "  \"" ++ path ++ "\" -> \"" ++ impPath ++ "\";") (Mod.modImports m)

-- | Show scope graph for a Nix file
cmdScope :: FilePath -> AppM ()
cmdScope file = do
  result <- liftIO $ Nix.parseNixFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right expr -> do
      let sg = Scope.fromNixFile file expr
      liftIO $ printScopeGraph sg

-- | Emit scope graph as JSON (for zeitschrift)
cmdScopeJSON :: FilePath -> AppM ()
cmdScopeJSON file = do
  result <- liftIO $ Nix.parseNixFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right expr -> do
      let sg = Scope.fromNixFile file expr
      liftIO $ BL.putStrLn $ encode sg

-- | Emit scope graph as Dhall (for zeitschrift)
cmdScopeDhall :: FilePath -> AppM ()
cmdScopeDhall file = do
  result <- liftIO $ Nix.parseNixFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Parse error: " <> err
      liftIO exitFailure
    Right expr -> do
      let sg = Scope.fromNixFile file expr
      liftIO $ TIO.putStrLn $ Scope.toDhall sg

printScopeGraph :: Scope.ScopeGraph -> IO ()
printScopeGraph sg = do
  putStrLn "=== Scope Graph ==="
  putStrLn $ "File: " ++ maybe "(none)" id (Scope.sgFile sg)
  putStrLn $ "Scopes: " ++ show (Map.size (Scope.sgScopes sg))
  putStrLn ""
  
  -- Print scopes with their contents
  forM_ (Map.elems (Scope.sgScopes sg)) $ \scope -> do
    putStrLn $ "Scope " ++ show (Scope.unScopeId (Scope.scopeId scope)) ++ 
               " (" ++ show (Scope.scopeKind scope) ++ "):"
    
    -- Declarations
    let decls = Scope.scopeDeclarations scope
    unless (null decls) $ do
      putStrLn "  Declarations:"
      forM_ decls $ \d -> do
        TIO.putStrLn $ "    " <> Scope.declName d <> 
                       maybe "" (\t -> " : " <> t) (Scope.declType d)
    
    -- References
    let refs = Scope.scopeReferences scope
    unless (null refs) $ do
      putStrLn "  References:"
      forM_ refs $ \r -> do
        TIO.putStrLn $ "    " <> Scope.refName r <> " (" <> T.pack (show (Scope.refKind r)) <> ")"
    
    -- Edges
    let edges = Scope.scopeEdges scope
    unless (null edges) $ do
      putStrLn "  Edges:"
      forM_ edges $ \e -> do
        putStrLn $ "    -> " ++ show (Scope.unScopeId (Scope.edgeTarget e)) ++
                   " (" ++ show (Scope.edgeLabel e) ++ ")"
    
    putStrLn ""
  
  -- Resolution summary
  case Scope.resolveAll sg of
    Left errors -> do
      putStrLn $ "=== Unresolved References (" ++ show (length errors) ++ ") ==="
      forM_ errors $ \case
        Scope.Unresolved ref -> TIO.putStrLn $ "  " <> Scope.refName ref
        Scope.Ambiguous ref _ -> TIO.putStrLn $ "  " <> Scope.refName ref <> " (ambiguous)"
    Right resolved -> do
      putStrLn $ "=== All " ++ show (length resolved) ++ " references resolved ==="

-- | Extract types for Nix interpolations based on inferred bash types
-- 
-- When bash analysis finds: curl --timeout "${__nix_interp_0__}"
-- And type inference resolves __nix_interp_0__ to TInt, we report: ${nix-expr} :: TInt
mapInterpTypesToNix :: Schema -> [Nix.Interpolation] -> [(T.Text, Type)]
mapInterpTypesToNix schema interps =
  let interpTypes = extractInterpTypesFromSchema schema
  in [ (Nix.intExpr interp, ty)
     | interp <- interps
     , Just ty <- [Map.lookup (Nix.intIndex interp) interpTypes]
     ]
  where
    -- Extract types for __nix_interp_N__ variables from the schema
    extractInterpTypesFromSchema :: Schema -> Map.Map Int Type
    extractInterpTypesFromSchema s = Map.fromList
      [ (idx, envType spec)
      | (var, spec) <- Map.toList (schemaEnv s)
      , "__nix_interp_" `T.isPrefixOf` var
      , "__" `T.isSuffixOf` var
      , Just idx <- [parseInterpIdx var]
      , envType spec /= TString  -- Only report if we inferred something specific
      ]
    
    parseInterpIdx :: T.Text -> Maybe Int
    parseInterpIdx t = 
      let middle = T.drop 13 (T.dropEnd 2 t)  -- Drop "__nix_interp_" and "__"
      in case reads (T.unpack middle) of
           [(n, "")] -> Just n
           _ -> Nothing

cmdSearch :: T.Text -> FilePath -> AppM ()
cmdSearch query file = do
  result <- liftIO $ Nix.parseNixFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right expr -> do
      src <- liftIO $ TIO.readFile file
      let sg = Scope.fromNixFile file expr
      let docs = Docs.extractDocs sg src
      let results = Search.search query docs
      liftIO $ mapM_ printResult results
  where
    printResult item = do
      TIO.putStrLn $ Docs.docName item
      unless (T.null (Docs.docDescription item)) $
        TIO.putStrLn $ "  " <> Docs.docDescription item

cmdDocs :: FilePath -> AppM ()
cmdDocs file = do
  result <- liftIO $ Nix.parseNixFile file
  case result of
    Left err -> do
      $(logTM) ErrorS $ logStr $ "Error: " <> err
      liftIO exitFailure
    Right expr -> do
      src <- liftIO $ TIO.readFile file
      let sg = Scope.fromNixFile file expr
      let docs = Docs.extractDocs sg src
      liftIO $ BL.putStrLn (encode docs)
