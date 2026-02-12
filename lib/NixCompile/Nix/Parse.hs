{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : NixCompile.Nix.Parse
-- Description : Parse Nix files to extract embedded bash scripts
--
-- Uses hnix to parse Nix expressions and find writeShellScript* calls.
-- Extracts the bash string content along with Nix interpolation sites.
--
-- Key patterns we look for:
--
--   pkgs.writeShellScript "name" ''
--     bash content with ${pkgs.foo}/bin/bar
--   ''
--
--   pkgs.writeShellScriptBin "name" ''...''
--
--   lib.writeScript "name" ''...''
--
--   Each interpolation ${...} is tracked with its source span and
--   the Nix expression it contains (for store path verification).
module NixCompile.Nix.Parse
  ( -- * Parsing
    parseNixFile,
    parseNixExpr,
    parseNix,

    -- * Extraction
    extractBashScripts,
    BashScript (..),
    Interpolation (..),
    
    -- * Interpolation utilities
    isInterpPlaceholder,
    interpPlaceholderIndex,

    -- * Low-level
    findShellScriptCalls,
    ShellScriptCall (..),
  )
where

import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import Nix.Parser (parseNixFileLoc, parseNixTextLoc)
import Nix.Utils (Path (..))
import NixCompile.Types (Loc (..), Span (..))

-- | A bash script extracted from a Nix file
data BashScript = BashScript
  { bsName :: !Text, -- Script name (from first argument)
    bsContent :: !Text, -- Raw bash content with interpolations as placeholders
    bsInterpolations :: ![Interpolation], -- All interpolation sites
    bsSpan :: !Span -- Source location of the bash string
  }
  deriving (Eq, Show)

-- | An interpolation site in a bash string
data Interpolation = Interpolation
  { intExpr :: !Text, -- The Nix expression text (e.g., "pkgs.curl")
    intIsStorePath :: !Bool, -- True if this looks like a store path access
    intSpan :: !Span, -- Source location within the bash string
    intIndex :: !Int -- Index in the bash string (for mapping back from __nix_interp_N__)
  }
  deriving (Eq, Show)

-- | A writeShellScript* call found in Nix
data ShellScriptCall = ShellScriptCall
  { sscFunction :: !Text, -- "writeShellScript", "writeShellScriptBin", etc.
    sscName :: !Text, -- Script name
    sscBody :: !NExprLoc, -- The body expression (usually a string)
    sscSpan :: !Span -- Source location of the call
  }
  deriving (Show)

-- | Check if a variable name is a Nix interpolation placeholder
-- Placeholders have the form: __nix_interp_N__
isInterpPlaceholder :: Text -> Bool
isInterpPlaceholder t = 
  "__nix_interp_" `T.isPrefixOf` t && "__" `T.isSuffixOf` t

-- | Extract the index from an interpolation placeholder
-- "__nix_interp_3__" -> Just 3
interpPlaceholderIndex :: Text -> Maybe Int
interpPlaceholderIndex t
  | not (isInterpPlaceholder t) = Nothing
  | otherwise = 
      let middle = T.drop 13 (T.dropEnd 2 t)  -- Drop "__nix_interp_" and "__"
      in case TR.decimal middle of
           Right (n, "") -> Just n
           _ -> Nothing

-- | Parse a Nix file and return the annotated AST
parseNixFile :: FilePath -> IO (Either Text NExprLoc)
parseNixFile path = do
  result <- parseNixFileLoc (Path path)
  pure $ case result of
    Left doc -> Left (T.pack $ show doc)
    Right expr -> Right expr

-- | Parse a Nix expression from text
parseNixExpr :: Text -> Either Text NExprLoc
parseNixExpr src = case parseNixTextLoc src of
  Left doc -> Left (T.pack $ show doc)
  Right expr -> Right expr

-- | Parse a Nix expression from text with a filepath for error context
-- This is the primary API for callers that have already read the file.
parseNix :: FilePath -> Text -> Either Text NExprLoc
parseNix _path src = case parseNixTextLoc src of
  Left doc -> Left (T.pack $ show doc)
  Right expr -> Right expr

-- | Extract all bash scripts from a Nix file
extractBashScripts :: FilePath -> IO (Either Text [BashScript])
extractBashScripts path = do
  result <- parseNixFile path
  case result of
    Left err -> pure $ Left err
    Right expr -> pure $ Right $ concatMap extractFromCall (findShellScriptCalls expr)

-- | Extract bash content from a shell script call
extractFromCall :: ShellScriptCall -> [BashScript]
extractFromCall ssc = case extractString (sscBody ssc) of
  Nothing -> []
  Just (content, interps, span') ->
    [ BashScript
        { bsName = sscName ssc,
          bsContent = content,
          bsInterpolations = interps,
          bsSpan = span'
        }
    ]

-- | Extract string content and interpolations from an expression
extractString :: NExprLoc -> Maybe (Text, [Interpolation], Span)
extractString (Fix (Compose (AnnUnit srcSpan expr))) = case expr of
  NStr (DoubleQuoted parts) ->
    let (content, interps) = extractPartsWithInterps parts
     in Just (content, interps, toSpan srcSpan Nothing)
  NStr (Indented _ parts) ->
    let (content, interps) = extractPartsWithInterps parts
     in Just (content, interps, toSpan srcSpan Nothing)
  _ -> Nothing

-- | Extract text and interpolations from string parts.
--
-- We replace interpolations with stable placeholders so downstream bash analysis can:
--   * treat "known store-path" interpolations as store paths (by prefixing /nix/store/)
--   * treat "unknown" interpolations as explicit placeholders (by prefixing @...@)
extractPartsWithInterps :: [Antiquoted Text NExprLoc] -> (Text, [Interpolation])
extractPartsWithInterps = go (0 :: Int)
  where
    go :: Int -> [Antiquoted Text NExprLoc] -> (Text, [Interpolation])
    go _ [] = ("", [])
    go n (part : rest) =
      let (restText, restInterps) = go n' rest
       in case part of
            Plain txt ->
              (txt <> restText, restInterps)
            EscapedNewline ->
              ("\n" <> restText, restInterps)
            Antiquoted expr ->
              let isStore = isStorePathExpr expr
                  -- Use bash variable syntax so CmdArg extraction picks it up!
                  -- Store paths: /nix/store/__nix_interp_N__ (looks like a path)
                  -- Other: ${__nix_interp_N__} (looks like a bash variable)
                  placeholder =
                    if isStore
                      then "/nix/store/__nix_interp_" <> T.pack (show n) <> "__"
                      else "${__nix_interp_" <> T.pack (show n) <> "__}"
                  interp =
                    Interpolation
                      { intExpr = prettyExpr expr,
                        intIsStorePath = isStore,
                        intSpan = exprSpan expr,
                        intIndex = n
                      }
               in (placeholder <> restText, interp : restInterps)
      where
        n' = case part of
          Antiquoted _ -> n + 1
          _ -> n

-- | Check if an expression looks like a store path access
-- e.g., ${pkgs.curl} or ${lib.getExe pkgs.ripgrep}
isStorePathExpr :: NExprLoc -> Bool
isStorePathExpr (Fix (Compose (AnnUnit _ expr))) = case expr of
  -- pkgs.foo or lib.foo
  NSelect _ base (k :| _) -> isPackageBase base || keyTextIs "pkgs" k || keyTextIs "lib" k
  -- lib.getExe pkgs.foo
  NApp func arg -> isStorePathExpr func || isStorePathExpr arg
  -- Direct reference like ${myPkg}
  NSym name -> isLikelyPackageVar (varNameText name)
  -- Literal path /nix/store/...
  NLiteralPath p -> "/nix/store" `T.isPrefixOf` T.pack (show p)
  _ -> False
  where
    isPackageBase (Fix (Compose (AnnUnit _ (NSym n)))) = varNameText n `elem` ["pkgs", "lib"]
    isPackageBase (Fix (Compose (AnnUnit _ (NSelect _ b _ )))) = isPackageBase b
    isPackageBase _ = False

    keyTextIs name (StaticKey k) = varNameText k == name
    keyTextIs _ (DynamicKey _) = False

    isLikelyPackageVar name =
      T.isPrefixOf "pkgs" name
        || T.isPrefixOf "lib" name
        || T.isSuffixOf "Pkg" name
        || T.isSuffixOf "Package" name

-- | Extract text from VarName newtype
varNameText :: VarName -> Text
varNameText = coerce

-- | Get a simple text representation of an expression
prettyExpr :: NExprLoc -> Text
prettyExpr (Fix (Compose (AnnUnit _ expr))) = case expr of
  NSym name -> varNameText name
  NSelect _ base (attr :| rest) ->
    prettyExpr base <> "." <> T.intercalate "." (map keyText (attr : rest))
  NApp func arg -> prettyExpr func <> " " <> prettyExpr arg
  NConstant (NInt n) -> T.pack (show n)
  NConstant (NFloat f) -> T.pack (show f)
  NConstant (NBool b) -> if b then "true" else "false"
  NConstant NNull -> "null"
  NStr _ -> "<string>"
  NList _ -> "<list>"
  NSet _ _ -> "<attrset>"
  NLiteralPath p -> T.pack (show p)
  NEnvPath p -> "<" <> T.pack (show p) <> ">"
  _ -> "<expr>"
  where
    keyText (StaticKey k) = varNameText k
    keyText (DynamicKey _) = "<dynamic>"

-- | Get the source span of an expression
exprSpan :: NExprLoc -> Span
exprSpan (Fix (Compose (AnnUnit srcSpan _))) = toSpan srcSpan Nothing

-- | Convert hnix source span to our Span type
toSpan :: SrcSpan -> Maybe FilePath -> Span
toSpan srcSpan mFile =
  let
    begin = getSpanBegin srcSpan
    end = getSpanEnd srcSpan
    fileFromBegin = case begin of
      NSourcePos path _ _ -> Just (coerce path)
    sp = Span
      { spanStart = Loc (sourceLine begin) (sourceCol begin)
      , spanEnd = Loc (sourceLine end) (sourceCol end)
      , spanFile = fileFromBegin
      }
  in
    case mFile of
      Just f -> sp { spanFile = Just f }
      Nothing -> sp
  where
    sourceLine (NSourcePos _ (NPos l) _) = fromIntegral (unPos l)
    sourceCol (NSourcePos _ _ (NPos c)) = fromIntegral (unPos c)

-- | Find all writeShellScript* calls in an expression
findShellScriptCalls :: NExprLoc -> [ShellScriptCall]
findShellScriptCalls = go
  where
    go :: NExprLoc -> [ShellScriptCall]
    go expr@(Fix (Compose (AnnUnit srcSpan e))) = case e of
      -- Function application: check if it's a shell script writer
      NApp _ _ -> case unwrapApp expr [] of
        Just (name, args) -> 
          let matches = checkCall name args srcSpan
          in if null matches then recurse e else matches
        Nothing -> recurse e
      _ -> recurse e

    -- Check if a function call is a shell script builder
    -- Strategy:
    -- 1. Check Function Name (Nominal Heuristic)
    -- 2. Check Content (Semantic Inspection - shebang or strict mode)
    checkCall :: Text -> [NExprLoc] -> SrcSpan -> [ShellScriptCall]
    checkCall name args srcSpan = case args of
      -- Pattern 1: func "name" ''body''
      [nameArg, bodyArg] ->
        let 
           isNameMatch = isPositionalShellFunc name
           maybeBody = extractStringLit bodyArg
           isContentMatch = maybe False isContentBash maybeBody
        in
        if isNameMatch || isContentMatch
        then [ ShellScriptCall
                { sscFunction = name
                , sscName = fromMaybe "script" (extractStringLit nameArg)
                , sscBody = bodyArg
                , sscSpan = toSpan srcSpan Nothing
                }
             ]
        else []
      
      -- Pattern 2 & 3: Single argument (either string body or record)
      [arg] ->
        case extractStringLit arg of
          Just body ->
            let 
               isNameMatch = isPositionalShellFunc name
               isContentMatch = isContentBash body
            in
            if isNameMatch || isContentMatch
            then [ ShellScriptCall
                    { sscFunction = name
                    , sscName = "script"
                    , sscBody = arg
                    , sscSpan = toSpan srcSpan Nothing
                    }
                 ]
            else []
          Nothing ->
            -- Try treating it as a record { name = ...; text = ...; }
            case extractFromRecord arg of
              Just (scriptName, bodyExpr, maybeBodyText) ->
                let 
                   isRecNameMatch = isRecordShellFunc name
                   isRecContentMatch = maybe False isContentBash maybeBodyText
                in
                if isRecNameMatch || isRecContentMatch
                then [ ShellScriptCall
                        { sscFunction = name
                        , sscName = scriptName
                        , sscBody = bodyExpr
                        , sscSpan = toSpan srcSpan Nothing
                        }
                     ]
                else []
              Nothing -> []
      
      _ -> []

    -- Unwrap nested applications to find the function name and all arguments
    unwrapApp :: NExprLoc -> [NExprLoc] -> Maybe (Text, [NExprLoc])
    unwrapApp (Fix (Compose (AnnUnit _ e))) args = case e of
      NApp func arg -> unwrapApp func (arg : args)
      NSym name -> Just (varNameText name, args)
      NSelect _ _ (attr :| rest) ->
        Just (keyText (last (attr : rest)), args)
      _ -> Nothing

    keyText (StaticKey k) = varNameText k
    keyText (DynamicKey _) = ""

    -- Check if a string looks like a bash script based on content
    isContentBash :: Text -> Bool
    isContentBash t =
      let 
         hasShebang = "#!" `T.isPrefixOf` t
         hasSet = "set -" `T.isInfixOf` t && ("e" `T.isInfixOf` t || "u" `T.isInfixOf` t || "o" `T.isInfixOf` t)
      in hasShebang || hasSet

    -- Check if a function takes positional args: writeShellScript "name" ''body''
    -- HEURISTIC: match function names that imply shell script generation or execution.
    -- This is "bulletproofed" to catch common wrapper patterns in large codebases.
    isPositionalShellFunc :: Text -> Bool
    isPositionalShellFunc name =
      let n = T.toLower name
      in 
         -- 1. Strong signal keywords (anywhere in name)
         "script" `T.isInfixOf` n 
         || "shell" `T.isInfixOf` n
         || "runcommand" `T.isInfixOf` n
         || "entrypoint" `T.isInfixOf` n
         || "wrapper" `T.isInfixOf` n
         || "hook" `T.isInfixOf` n
         || "phase" `T.isInfixOf` n
         -- 2. Builder patterns (prefix + component)
         -- Catches: mkBin, writeTool, buildService, createDaemon, etc.
         || (("mk" `T.isPrefixOf` n || "write" `T.isPrefixOf` n || "build" `T.isPrefixOf` n || "create" `T.isPrefixOf` n) &&
             ("app" `T.isInfixOf` n 
              || "bin" `T.isInfixOf` n 
              || "cli" `T.isInfixOf` n 
              || "tool" `T.isInfixOf` n
              || "service" `T.isInfixOf` n
              || "daemon" `T.isInfixOf` n
              || "image" `T.isInfixOf` n
              || "job" `T.isInfixOf` n
             ))

    -- Check if a function takes a record arg: writeShellApplication { ... }
    -- Same heuristic logic as above.
    isRecordShellFunc :: Text -> Bool
    isRecordShellFunc name = 
      isPositionalShellFunc name 
      && not ("apply" `T.isInfixOf` (T.toLower name)) -- avoid false positives like "apply"

    -- Extract name, body expr, and body text from a record
    extractFromRecord :: NExprLoc -> Maybe (Text, NExprLoc, Maybe Text)
    extractFromRecord (Fix (Compose (AnnUnit _ e))) = case e of
      NSet _ bindings ->
        let nameVal = findBinding "name" bindings >>= extractStringLit
            textExpr = findBinding "text" bindings
            textVal = textExpr >>= extractStringLit
        in case (nameVal, textExpr) of
          (Just n, Just expr) -> Just (n, expr, textVal)
          _ -> Nothing
      _ -> Nothing

    -- Find a binding by name in a binding list
    findBinding :: Text -> [Binding NExprLoc] -> Maybe NExprLoc
    findBinding name = foldr check Nothing
      where
        check (NamedVar (StaticKey k :| []) expr _) acc
          | varNameText k == name = Just expr
          | otherwise = acc
        check _ acc = acc

    -- Extract a string literal from an expression
    extractStringLit :: NExprLoc -> Maybe Text
    extractStringLit (Fix (Compose (AnnUnit _ e))) = case e of
      NStr (DoubleQuoted [Plain t]) -> Just t
      NStr (Indented _ [Plain t]) -> Just t
      _ -> Nothing

    -- Recurse into sub-expressions
    recurse :: NExprF NExprLoc -> [ShellScriptCall]
    recurse e = case e of
      NConstant _ -> []
      NStr _ -> []
      NSym _ -> []
      NList xs -> concatMap go xs
      NSet _ bindings -> concatMap goBinding bindings
      NLiteralPath _ -> []
      NEnvPath _ -> []
      NLet bindings body -> concatMap goBinding bindings ++ go body
      NIf cond t f -> go cond ++ go t ++ go f
      NWith scope body -> go scope ++ go body
      NAssert cond body -> go cond ++ go body
      NAbs _ body -> go body
      NApp f x -> go f ++ go x
      NSelect alt base _ -> go base ++ maybe [] go alt
      NHasAttr base _ -> go base
      NUnary _ x -> go x
      NBinary _ x y -> go x ++ go y
      NSynHole _ -> []

    goBinding :: Binding NExprLoc -> [ShellScriptCall]
    goBinding = \case
      NamedVar _ expr _ -> go expr
      Inherit _ _ _ -> []
