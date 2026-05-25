{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module NixCompile.Nix.LintPackages
  ( PackageViolationCode (..),
    PackageViolation (..),
    checkPackageDirs,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (filterM)
import Data.List (nub)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import NixCompile.Nix.ModuleKind (detectKindFromFile, isPackage)
import System.Directory (doesFileExist, listDirectory)
import System.FilePath (takeDirectory, takeExtension, (</>))

data PackageViolationCode
  = P001
  deriving (Show, Eq)

data PackageViolation = PackageViolation
  { pvCode :: !PackageViolationCode,
    pvPath :: !FilePath,
    pvMessage :: !Text
  }
  deriving (Show, Eq)

checkPackageDirs :: [FilePath] -> IO [PackageViolation]
checkPackageDirs nixFiles = do
  let dirs = nub (map takeDirectory nixFiles)
  packageDirs <- filterM isPackageDir dirs
  catMaybes <$> mapM checkDefaultNix packageDirs

isPackageDir :: FilePath -> IO Bool
isPackageDir dir = do
  result <- try (listDirectory dir)
  case result of
    Left (_ :: IOException) -> pure False
    Right entries -> do
      let nixFilesInDir = filter ((== ".nix") . takeExtension) entries
      anyM (\f -> isPackageModule (dir </> f)) nixFilesInDir

isPackageModule :: FilePath -> IO Bool
isPackageModule path = do
  det <- detectKindFromFile path
  pure (isPackage det)

checkDefaultNix :: FilePath -> IO (Maybe PackageViolation)
checkDefaultNix dir = do
  exists <- doesFileExist (dir </> "default.nix")
  pure $
    if exists
      then Nothing
      else
        Just $
          PackageViolation
            { pvCode = P001,
              pvPath = dir,
              pvMessage = "Package directory missing default.nix"
            }

anyM :: (Monad m) => (a -> m Bool) -> [a] -> m Bool
anyM _ [] = pure False
anyM f (x : xs) = do
  r <- f x
  if r then pure True else anyM f xs
