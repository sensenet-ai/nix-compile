{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                     // check
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--     "Get just right and I'll cut the ice; get it wrong and it's
--      the death of ten thousand Turing cops."
--
--                                                                 — Neuromancer
--
-- | Unified repository-wide analysis.
--
-- One command. One exit code.
--
--   * Exit 0 = clean
--   * Exit 1 = issues found OR files couldn't be parsed
--
-- There is no "skip". If we can't analyze it, that's a failure.
--
module NixCompile.Check
  ( -- * Running checks
    check
  , checkWithConfig

    -- * Configuration
  , Config (..)
  , Profile (..)
  , LayoutMode (..)
  , defaultConfig

    -- * Results
  , Result (..)
  , Issue (..)
  , Severity (..)
  , isClean
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (forM)
import Data.List (nub, sort)
import Data.Maybe (mapMaybe, maybeToList)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, doesDirectoryExist, listDirectory, getCurrentDirectory)
import System.FilePath ((</>), takeExtension, takeFileName, splitDirectories, normalise)
import System.IO (hPutStrLn, stderr)

import Shelly hiding (FilePath, (</>))
import qualified Shelly as Sh

import qualified NixCompile.Bash.Parse as Bash
import qualified NixCompile.Lint.Forbidden as Forbidden
import qualified NixCompile.Nix.Parse as Nix
import qualified NixCompile.Nix.Lint as NixLint
import qualified NixCompile.Nix.ModuleKind as MK
import qualified NixCompile.Nix.LayoutConvention as LC
import qualified NixCompile.Nix.Naming as Naming
import Nix.Expr.Types.Annotated (NExprLoc)
import NixCompile.Types (Span(..), Loc(..))

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                     // types
-- ══════════════════════════════════════════════════════════════════════════════

-- | Issue severity. No "skip" — if we can't parse, it's an error.
data Severity = Error | Warning | Info
  deriving (Eq, Ord, Show)

-- | A single issue found during analysis.
data Issue = Issue
  { iFile     :: !FilePath
  , iLine     :: !(Maybe Int)
  , iRule     :: !Text
  , iSeverity :: !Severity
  , iMessage  :: !Text
  } deriving (Eq, Show)

-- | Analysis result.
data Result = Result
  { rIssues   :: ![Issue]
  , rErrors   :: !Int
  , rWarnings :: !Int
  , rInfos    :: !Int
  , rFiles    :: !Int
  } deriving (Eq, Show)

-- | Clean means zero issues of any kind.
isClean :: Result -> Bool
isClean Result{..} = rErrors == 0 && rWarnings == 0 && rInfos == 0

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                  // profiles
-- ══════════════════════════════════════════════════════════════════════════════

-- | Analysis profile.
data Profile
  = Strict    -- ^ Full aleph conventions (lisp-case, dhall templating)
  | Standard  -- ^ Sensible defaults for most projects
  | Minimal   -- ^ Essential safety only
  | Nixpkgs   -- ^ nixpkgs contribution guidelines
  | Security  -- ^ Security focused
  deriving (Eq, Show, Read)

-- | Layout convention to enforce.
data LayoutMode
  = LayoutStraylight   -- ^ nix/modules/{flake,nixos,home}/, nix/packages/
  | LayoutFlakeParts   -- ^ modules/, packages/, overlays/
  | LayoutNixpkgs      -- ^ pkgs/by-name/XX/name/package.nix
  | LayoutNixOSConfig  -- ^ hosts/, modules/, users/
  | LayoutNone         -- ^ No layout enforcement
  deriving (Eq, Show, Read)

-- | Configuration for analysis.
data Config = Config
  { cProfile   :: !Profile
  , cLayout    :: !LayoutMode        -- ^ Layout convention to enforce
  , cRulesDir  :: !(Maybe FilePath)  -- ^ Path to ast-grep rule files
  , cVerbose   :: !Bool
  , cQuiet     :: !Bool
  } deriving (Eq, Show)

-- | Default config: standard profile, no layout enforcement.
defaultConfig :: Config
defaultConfig = Config
  { cProfile = Standard
  , cLayout = LayoutNone
  , cRulesDir = Nothing
  , cVerbose = False
  , cQuiet = False
  }

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                     // rules
-- ══════════════════════════════════════════════════════════════════════════════

data RuleSev = RError | RWarning | RInfo | ROff
  deriving (Eq, Show)

-- | Rule severity by profile.
ruleSev :: Profile -> Text -> RuleSev
ruleSev Strict = \case
  "parse-error"                  -> RError  -- always error
  "with-lib"                     -> RError
  "rec-anywhere"                 -> RError
  "no-heredoc"                   -> RError
  "no-eval"                      -> RError
  "no-backticks"                 -> RWarning
  "non-lisp-case"                -> RError
  "no-substitute-all"            -> RError
  "missing-meta"                 -> RError
  "missing-description"          -> RError
  "missing-class"                -> RError
  "cpp-using-namespace-header"   -> RError
  "cpp-raw-new-delete"           -> RError
  _                              -> RWarning

ruleSev Standard = \case
  "parse-error"                  -> RError
  "with-lib"                     -> RError
  "rec-anywhere"                 -> RWarning
  "no-heredoc"                   -> RError
  "no-eval"                      -> RError
  "no-backticks"                 -> RWarning
  "non-lisp-case"                -> ROff
  "no-substitute-all"            -> ROff
  "missing-meta"                 -> RWarning
  "missing-description"          -> RInfo
  "missing-class"                -> RError
  "cpp-using-namespace-header"   -> RError
  "cpp-raw-new-delete"           -> RWarning
  _                              -> ROff

ruleSev Minimal = \case
  "parse-error"                  -> RError
  "with-lib"                     -> RWarning
  "no-heredoc"                   -> RError
  "no-eval"                      -> RError
  "missing-class"                -> RWarning
  "cpp-using-namespace-header"   -> RError
  _                              -> ROff

ruleSev Nixpkgs = \case
  "parse-error"                  -> RError
  "with-lib"                     -> RWarning
  "no-heredoc"                   -> RWarning
  "missing-meta"                 -> RError
  "missing-description"          -> RError
  "missing-class"                -> RError
  _                              -> ROff

ruleSev Security = \case
  "parse-error"                  -> RError
  "no-heredoc"                   -> RError
  "no-eval"                      -> RError
  "no-substitute-all"            -> RWarning
  "with-lib"                     -> RError
  "missing-class"                -> RError
  "cpp-raw-new-delete"           -> RError
  _                              -> ROff

toSeverity :: RuleSev -> Maybe Severity
toSeverity = \case
  RError   -> Just Error
  RWarning -> Just Warning
  RInfo    -> Just Info
  ROff     -> Nothing

-- ══════════════════════════════════════════════════════════════════════════════
--                                                           // file discovery
-- ══════════════════════════════════════════════════════════════════════════════

discoverFiles :: [FilePath] -> IO [FilePath]
discoverFiles paths = nub . sort . concat <$> mapM findRec paths

findRec :: FilePath -> IO [FilePath]
findRec filePath = do
  isFile <- doesFileExist filePath
  isDir <- doesDirectoryExist filePath
  if isFile
    then pure [filePath | analyzable filePath]
    else if isDir && not (ignored $ takeFileName filePath)
      then listDirectory filePath >>= fmap concat . mapM (findRec . (filePath </>))
      else pure []

analyzable :: FilePath -> Bool
analyzable p = takeExtension p `elem` [".nix", ".sh", ".bash"]

ignored :: String -> Bool
ignored n = n `elem` [".git", "dist-newstyle", "result", "node_modules", ".direnv", "fixtures", ".stack-work", "target", "build", "dist", ".cabal-sandbox", "_build", ".bloop", ".metals", ".idea", ".vscode"]

-- ══════════════════════════════════════════════════════════════════════════════
--                                                          // native analysis
-- ══════════════════════════════════════════════════════════════════════════════

analyzeFile :: Config -> FilePath -> IO [Issue]
analyzeFile cfg filePath = do
  result <- try (TIO.readFile filePath) :: IO (Either SomeException Text)
  case result of
    Left err -> pure [mkIssue cfg filePath "parse-error" $ "read: " <> T.pack (show err)]
    Right content ->
      case takeExtension filePath of
        ".nix"  -> analyzeNix cfg filePath content
        ".sh"   -> analyzeBash cfg filePath content
        ".bash" -> analyzeBash cfg filePath content
        _       -> pure []

mkIssue :: Config -> FilePath -> Text -> Text -> Issue
mkIssue cfg filePath rule msg =
  let sev = maybe Error id $ toSeverity $ ruleSev (cProfile cfg) rule
  in Issue filePath Nothing rule sev msg

analyzeNix :: Config -> FilePath -> Text -> IO [Issue]
analyzeNix cfg filePath content =
  case Nix.parseNix filePath content of
    Left err -> pure [mkIssue cfg filePath "parse-error" $ T.pack (show err)]
    Right expr ->
      let -- Lint violations (with, rec)
          lintViolations = NixLint.findNixViolations expr
          lintIssues = mapMaybe (nixToIssue cfg filePath) lintViolations
          -- Naming violations (only in Strict mode)
          namingConv = case cProfile cfg of
            Strict -> Naming.LispCase
            _      -> Naming.NoConvention
          namingViolations = Naming.findNamingViolations namingConv expr
          namingIssues = map (namingToIssue cfg filePath) namingViolations
          classIssues = maybeToList (missingClassIssue cfg filePath expr)
      in pure $ lintIssues ++ namingIssues ++ classIssues

nixToIssue :: Config -> FilePath -> NixLint.NixViolation -> Maybe Issue
nixToIssue cfg filePath v =
  let rule = case NixLint.nvType v of
        NixLint.VWith -> "with-lib"
        NixLint.VRec  -> "rec-anywhere"
      Span { spanStart = Loc line _ } = NixLint.nvSpan v
  in case toSeverity $ ruleSev (cProfile cfg) rule of
    Nothing -> Nothing  -- Rule is Off, don't emit
    Just sev -> Just $ Issue filePath (Just line) rule sev (NixLint.nvContext v)

namingToIssue :: Config -> FilePath -> Naming.NamingViolation -> Issue
namingToIssue _cfg filePath v =
  let Span { spanStart = Loc line _ } = Naming.nvSpan v
      msg = Naming.nvContext v <> " '" <> Naming.nvIdentifier v
          <> "' should be '" <> Naming.nvSuggestion v <> "'"
  in Issue filePath (Just line) "naming" Warning msg

missingClassIssue :: Config -> FilePath -> NExprLoc -> Maybe Issue
missingClassIssue cfg filePath expr =
  case toSeverity $ ruleSev (cProfile cfg) "missing-class" of
    Nothing -> Nothing
    Just sev ->
      if shouldCheckClass filePath
        then case MK.detectClassValue expr of
          Nothing -> Just $ Issue filePath Nothing "missing-class" sev (missingClassMessage filePath)
          Just _ -> Nothing
        else Nothing

missingClassMessage :: FilePath -> Text
missingClassMessage filePath =
  case expectedClassForPath filePath of
    Nothing -> "Module missing `_class` attribute"
    Just expected -> "Module missing `_class` attribute; expected _class = \"" <> expected <> "\""

expectedClassForPath :: FilePath -> Maybe Text
expectedClassForPath filePath = do
  comps <- modulePathComponents filePath
  case comps of
    ("flake":_) -> Just "flake"
    ("nixos":_) -> Just "nixos"
    ("home":_) -> Just "home"
    ("home-manager":_) -> Just "homeManager"
    ("darwin":_) -> Just "darwin"
    _ -> Nothing

shouldCheckClass :: FilePath -> Bool
shouldCheckClass filePath =
  case modulePathComponents filePath of
    Nothing -> False
    Just comps -> not (isIgnoredModuleFile comps)

modulePathComponents :: FilePath -> Maybe [String]
modulePathComponents filePath =
  case dropWhile (/= "nix") (splitDirectories (normalise filePath)) of
    ("nix":"modules":rest) -> Just rest
    _ -> Nothing

isIgnoredModuleFile :: [String] -> Bool
isIgnoredModuleFile comps =
  let fileName = case reverse comps of
        (name:_) -> name
        [] -> ""
      ignoredNames =
        [ "_index.nix"
        , "options.nix"
        , "toolchains.nix"
        , "buckconfig.nix"
        , "shell-hook.nix"
        , "nimi-init.nix"
        ]
      isOptionsSchema = comps == ["flake", "options-schema.nix"]
      isScriptsHelper = "scripts" `elem` comps
  in fileName `elem` ignoredNames || isOptionsSchema || isScriptsHelper

analyzeBash :: Config -> FilePath -> Text -> IO [Issue]
analyzeBash cfg filePath content =
  case Bash.parseScript content of
    Left err -> pure [mkIssue cfg filePath "parse-error" err]
    Right ast ->
      let violations = Forbidden.findViolations ast
      in pure $ mapMaybe (bashToIssue cfg filePath) violations

bashToIssue :: Config -> FilePath -> Forbidden.Violation -> Maybe Issue
bashToIssue cfg filePath v =
  let rule = case Forbidden.vType v of
        Forbidden.VHeredoc    -> "no-heredoc"
        Forbidden.VHereString -> "no-heredoc"
        Forbidden.VEval       -> "no-eval"
        Forbidden.VBacktick   -> "no-backticks"
      Span { spanStart = Loc line _ } = Forbidden.vSpan v
  in case toSeverity $ ruleSev (cProfile cfg) rule of
    Nothing -> Nothing  -- Rule is Off, don't emit
    Just sev -> Just $ Issue filePath (Just line) rule sev (Forbidden.vContext v)

-- ══════════════════════════════════════════════════════════════════════════════
--                                                              // ast-grep
-- ══════════════════════════════════════════════════════════════════════════════

-- | AST-grep rules we can run.
astGrepRules :: [Text]
astGrepRules =
  [ "rec-anywhere", "with-lib", "no-heredoc-in-inline-bash"
  , "no-substitute-all", "prefer-write-shell-application"
  , "missing-meta", "missing-description", "non-lisp-case"
  , "cpp-using-namespace-header", "cpp-raw-new-delete"
  ]

hasAstGrep :: IO Bool
hasAstGrep = shelly $ silently $ errExit False $ do
  _ <- Sh.run "ast-grep" ["--version"]
  (== 0) <$> lastExitCode

runAstGrep :: Config -> [FilePath] -> IO [Issue]
runAstGrep cfg paths = do
  case cRulesDir cfg of
    Nothing -> pure []
    Just rulesDir -> do
      ok <- hasAstGrep
      if not ok
        then do
          unless (cQuiet cfg) $ hPutStrLn stderr "error: ast-grep not found"
          pure [Issue "<tool>" Nothing "ast-grep-missing" Error "ast-grep not installed"]
        else concat <$> forM astGrepRules (runRule cfg rulesDir paths)

runRule :: Config -> FilePath -> [FilePath] -> Text -> IO [Issue]
runRule cfg rulesDir paths rule = do
  let ruleFile = rulesDir </> T.unpack rule <> ".yml"
  exists <- doesFileExist ruleFile
  if not exists
    then pure []
    else case toSeverity (ruleSev (cProfile cfg) rule) of
      Nothing -> pure []  -- rule is off
      Just sev -> shelly $ silently $ errExit False $ do
        out <- Sh.run "ast-grep" $ ["scan", "--rule", T.pack ruleFile] ++ map T.pack paths
        if T.null (T.strip out)
          then pure []
          else pure $ parseOutput rule sev out

parseOutput :: Text -> Severity -> Text -> [Issue]
parseOutput rule sev out =
  [ Issue (T.unpack $ T.takeWhile (/= ':') ln) Nothing rule sev (T.strip ln)
  | ln <- T.lines out
  , not $ T.null $ T.strip ln
  ]

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                      // run
-- ══════════════════════════════════════════════════════════════════════════════

-- | Check paths with default config.
check :: [FilePath] -> IO Result
check = checkWithConfig defaultConfig

-- | Check paths with custom config.
checkWithConfig :: Config -> [FilePath] -> IO Result
checkWithConfig cfg paths = do
  unless (cQuiet cfg) $ do
    hPutStrLn stderr $ "nix-compile (profile: " ++ show (cProfile cfg) ++ ")"
    when (cLayout cfg /= LayoutNone) $
      hPutStrLn stderr $ "layout: " ++ show (cLayout cfg)
    hPutStrLn stderr $ "paths: " ++ unwords paths

  root <- getCurrentDirectory
  files <- discoverFiles paths
  when (cVerbose cfg) $ hPutStrLn stderr $ "files: " ++ show (length files)

  -- Native analysis (lint, parse errors)
  native <- concat <$> mapM (analyzeFile cfg) files

  -- AST-grep rules
  ast <- runAstGrep cfg paths

  -- Layout validation (requires parsing + kind detection)
  layout <- runLayoutValidation cfg root files

  let issues = native ++ ast ++ layout
      errors   = length [i | i <- issues, iSeverity i == Error]
      warnings = length [i | i <- issues, iSeverity i == Warning]
      infos    = length [i | i <- issues, iSeverity i == Info]
      result = Result issues errors warnings infos (length files)

  unless (cQuiet cfg) $ do
    mapM_ printIssue issues
    printSummary result

  pure result

-- ══════════════════════════════════════════════════════════════════════════════
--                                                       // layout validation
-- ══════════════════════════════════════════════════════════════════════════════

runLayoutValidation :: Config -> FilePath -> [FilePath] -> IO [Issue]
runLayoutValidation cfg root files = do
  case getConvention (cLayout cfg) of
    Nothing -> pure []  -- No layout enforcement
    Just conv -> do
      -- Only validate .nix files for layout
      let nixFiles = filter (\f -> takeExtension f == ".nix") files
      -- Detect kind for each file
      detections <- forM nixFiles $ \filePath -> do
        det <- MK.detectKindFromFile filePath
        pure (filePath, det)
      -- Validate against convention
      let errors = LC.validateLayout conv root detections
      pure $ map (layoutToIssue cfg) errors

getConvention :: LayoutMode -> Maybe LC.Convention
getConvention = \case
  LayoutStraylight  -> Just LC.straylight
  LayoutFlakeParts  -> Just LC.flakeParts
  LayoutNixpkgs     -> Just LC.nixpkgsByName
  LayoutNixOSConfig -> Just LC.nixosConfig
  LayoutNone        -> Nothing

layoutToIssue :: Config -> LC.LayoutError -> Issue
layoutToIssue _cfg err = Issue
  { iFile = LC.errPath err
  , iLine = Nothing
  , iRule = "layout-" <> T.pack (show $ LC.errCode err)
  , iSeverity = Error  -- Layout violations are always errors
  , iMessage = LC.errMessage err <> maybe "" (\e -> " (expected: " <> e <> ")") (LC.errExpected err)
  }

-- ══════════════════════════════════════════════════════════════════════════════
--                                                                   // output
-- ══════════════════════════════════════════════════════════════════════════════

printIssue :: Issue -> IO ()
printIssue Issue{..} = hPutStrLn stderr $ unwords
  [ sevStr iSeverity
  , "[" ++ T.unpack iRule ++ "]"
  , iFile ++ maybe "" ((":" ++) . show) iLine ++ ":"
  , T.unpack iMessage
  ]
  where
    sevStr Error   = "error:"
    sevStr Warning = "warn: "
    sevStr Info    = "info: "

printSummary :: Result -> IO ()
printSummary Result{..} = do
  hPutStrLn stderr ""
  if rErrors + rWarnings + rInfos == 0
    then hPutStrLn stderr "✓ clean"
    else do
      hPutStrLn stderr $ "✗ " ++ show (rErrors + rWarnings + rInfos) ++ " issue(s)"
      when (rErrors > 0)   $ hPutStrLn stderr $ "  " ++ show rErrors ++ " error(s)"
      when (rWarnings > 0) $ hPutStrLn stderr $ "  " ++ show rWarnings ++ " warning(s)"
      when (rInfos > 0)    $ hPutStrLn stderr $ "  " ++ show rInfos ++ " info(s)"
