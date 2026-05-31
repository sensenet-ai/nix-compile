-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                            // app // nix-compile // Main
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Control.Monad.IO.Class (liftIO)
import Data.Text qualified as T
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.Directory (doesFileExist)

import NixCompile.CLI.Dispatch
import NixCompile.Config qualified as Config
import NixCompile.Log

main :: IO ()
main = runLog InfoS $ do
    commandArguments <- liftIO getArgs
    let (maybeConfigPath, commandAndArgs) = parseConfigArg commandArguments
    loadedConfig <- loadConfiguration maybeConfigPath
    dispatchCommand loadedConfig commandAndArgs

loadConfiguration :: Maybe FilePath -> AppM Config.Config
loadConfiguration (Just configPath) = do
    result <- liftIO $ Config.loadConfig configPath
    case result of
        Left errorMessage -> do
            $(logTM) WarningS $ logStr $ "Failed to load config: " <> errorMessage
            pure Config.defaultConfig
        Right configuration -> pure configuration
loadConfiguration Nothing = do
    configFileExists <- liftIO $ doesFileExist ".nix-compile.dhall"
    if configFileExists
        then do
            result <- liftIO $ Config.loadConfig ".nix-compile.dhall"
            case result of
                Left errorMessage -> do
                    $(logTM) WarningS $ logStr $ "Failed to load .nix-compile.dhall: " <> errorMessage
                    pure Config.defaultConfig
                Right configuration -> pure configuration
        else pure Config.defaultConfig

dispatchCommand :: Config.Config -> [String] -> AppM ()
dispatchCommand config ["check", path] = cmdCheck config path
dispatchCommand _ ["fmt", file] = cmdFmt file
dispatchCommand _ ["infer", file] = cmdInfer file
dispatchCommand _ ["emit", file] = cmdEmit file
dispatchCommand _ ["lsp"] = cmdLSP
dispatchCommand _ ["scope", file] = cmdScope file
dispatchCommand _ ["scope", "--json", file] = cmdScopeJSON file
dispatchCommand _ ["scope", "--dhall", file] = cmdScopeDhall file
dispatchCommand _ ["--help"] = liftIO usage
dispatchCommand _ ["-h"] = liftIO usage
dispatchCommand _ [] = liftIO usage
dispatchCommand _ unknownArgs = do
    $(logTM) ErrorS $ logStr $ T.pack $ "Unknown command: " ++ unwords unknownArgs
    liftIO usage
    liftIO exitFailure

parseConfigArg :: [String] -> (Maybe FilePath, [String])
parseConfigArg ("--config" : path : rest) = (Just path, rest)
parseConfigArg args = (Nothing, args)

usage :: IO ()
usage = do
    putStrLn "nix-compile - compile-time type checker for Nix expressions"
    putStrLn ""
    putStrLn "Usage:"
    putStrLn "  nix-compile check <path>      Run all checks (auto-detects .sh, .nix, or directory)"
    putStrLn "  nix-compile infer <file.nix>  Infer types and add annotation comments"
    putStrLn "  nix-compile fmt <file.nix>    Format Nix source (nixfmt)"
    putStrLn "  nix-compile emit <script.sh>  Generate emit-config bash function"
    putStrLn "  nix-compile scope <file.nix>  Show scope graph (--json, --dhall)"
    putStrLn "  nix-compile lsp               Start LSP server"
    putStrLn ""
    putStrLn "Options:"
    putStrLn "  --config <file.dhall>         Path to Dhall config (default: .nix-compile.dhall)"
    putStrLn ""
    putStrLn "Examples:"
    putStrLn "  nix-compile check ."
    putStrLn "  nix-compile check ./default.nix"
    putStrLn "  nix-compile check ./deploy.sh"
    putStrLn "  nix-compile infer ./default.nix"
    putStrLn "  nix-compile emit ./configure.sh > emitter.sh"
