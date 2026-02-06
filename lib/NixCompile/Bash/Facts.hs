{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : NixCompile.Bash.Facts
-- Description : Extract facts from bash AST
--
-- Walks the ShellCheck AST and extracts facts about:
--   - Variable assignments and defaults
--   - Config.* assignments
--   - Command invocations
--   - Store path usage
module NixCompile.Bash.Facts
  ( extractFacts,
  )
where

import Control.Monad.Reader (Reader, runReader, ask)
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import NixCompile.Bash.Parse (BashAST(..))
import NixCompile.Bash.Patterns
import NixCompile.Types
import qualified ShellCheck.AST as SA
import ShellCheck.Interface (Position(..))

-- | Extract all facts from a bash AST
extractFacts :: BashAST -> [Fact]
extractFacts (BashAST root posMap) = runReader (go root) posMap

go :: SA.Token -> Reader (Map SA.Id (Position, Position)) [Fact]
go (SA.OuterToken scId inner) = do
  local <- localFacts scId inner
  rest <- mapM go (toList inner)
  pure (local ++ concat rest)

-- | Extract facts from a single token (non-recursive)
localFacts :: SA.Id -> SA.InnerToken SA.Token -> Reader (Map SA.Id (Position, Position)) [Fact]
localFacts scId inner = do
  sp <- mkSpan scId
  case inner of
    -- Assignment: VAR=value or VAR="${VAR:-default}"
    SA.Inner_T_Assignment _ name _ value ->
      pure $ assignmentFacts sp (T.pack name) value
    -- Simple command: check for config.* or commands
    SA.Inner_T_SimpleCommand _assigns wrds ->
      commandFacts sp wrds
    _ -> pure []

-- | Facts from an assignment
assignmentFacts :: Span -> Text -> SA.Token -> [Fact]
assignmentFacts sp name value =
  -- Check for config[path.to.key] associative array pattern
  case parseConfigArrayAssign name of
    Just configPath -> configArrayFacts sp configPath value
    Nothing -> envVarFacts sp name value

-- | Parse config[path.to.key] -> Just ["path", "to", "key"]
parseConfigArrayAssign :: Text -> Maybe ConfigPath
parseConfigArrayAssign name
  | "config[" `T.isPrefixOf` name && "]" `T.isSuffixOf` name =
      let pathText = T.dropEnd 1 (T.drop 7 name)  -- drop "config[" and "]"
          parts = T.splitOn "." pathText
       in if validConfigPath parts then Just parts else Nothing
  | otherwise = Nothing

-- | Facts from config[...] assignment
configArrayFacts :: Span -> ConfigPath -> SA.Token -> [Fact]
configArrayFacts sp configPath value =
  let valueText = tokenToText value
      -- Determine if quoted by checking the token structure
      quoted = isQuotedToken value
   in case extractSimpleVar valueText of
        Just var -> [ConfigAssign configPath var quoted sp]
        Nothing -> [ConfigLit configPath (parseLiteral valueText) sp]

-- | Check if a token is quoted (DoubleQuoted)
isQuotedToken :: SA.Token -> Quoted
isQuotedToken (SA.OuterToken _ inner) = case inner of
  SA.Inner_T_DoubleQuoted _ -> Quoted
  SA.Inner_T_NormalWord [SA.OuterToken _ (SA.Inner_T_DoubleQuoted _)] -> Quoted
  _ -> Unquoted

-- | Facts from regular env var assignment
envVarFacts :: Span -> Text -> SA.Token -> [Fact]
envVarFacts sp name value =
  case extractParamExpansion value of
    -- ${VAR:-default} / ${VAR-default}
    Just (DefaultValue _var (Just def)) ->
      defaultFacts def
    -- ${VAR:=default} / ${VAR=default}
    Just (AssignDefault _var (Just def)) ->
      defaultFacts def
    Just (AssignDefault _var Nothing) ->
      [DefaultIs name (LitString "") sp]
    -- ${VAR:-} (empty default) should behave like default = "" (not required)
    Just (DefaultValue _var Nothing) ->
      [DefaultIs name (LitString "") sp]
    -- ${VAR:?message} / ${VAR?message}
    Just (ErrorIfUnset _var _) ->
      [Required name sp]
    -- ${VAR} / $VAR
    Just (SimpleRef var) ->
      [AssignFrom name var sp]
    -- ${VAR:+alt} - use alternate value
    Just (UseAlternate _var _) ->
      []  -- Not tracking alternate values for now
    -- Plain assignment: VAR=value
    Nothing ->
      case extractLiteral value of
        Just lit -> [AssignLit name lit sp]
        Nothing -> []
  where
    defaultFacts def =
      case defaultFromVar def of
        Just other -> [DefaultFrom name other sp]
        Nothing -> [DefaultIs name (parseLiteral def) sp]

    defaultFromVar def =
      case parseParamExpansion def of
        Just (SimpleRef v) -> Just v
        _ -> Nothing

-- | Facts from a command
commandFacts :: Span -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Fact]
commandFacts sp toks = case toks of
  [] -> pure []
  (cmdTok : args) ->
    let cmdText = tokenToText cmdTok
     in if "config." `T.isPrefixOf` cmdText
          then pure $ configFactsFromToken sp cmdTok
          else cmdInvocationFacts sp cmdText args

-- | Facts from config.* assignment (AST-aware)
-- We need to check the AST structure to determine if the value was quoted
configFactsFromToken :: Span -> SA.Token -> [Fact]
configFactsFromToken sp tok@(SA.OuterToken _ inner) =
  case inner of
    -- NormalWord contains the config assignment parts
    SA.Inner_T_NormalWord parts -> configFactsFromParts sp parts
    _ -> configFacts sp (tokenToText tok)

-- | Extract config facts from NormalWord parts
-- The structure is: "config.x.y=" followed by the value part(s)
configFactsFromParts :: Span -> [SA.Token] -> [Fact]
configFactsFromParts sp parts =
  let text = T.concat (map tokenToText parts)
      (lhs, rest) = T.breakOn "=" text
   in case T.stripPrefix "config." lhs of
        Just pathText | not (T.null rest) ->
          let pathParts = T.splitOn "." pathText
           in if not (validConfigPath pathParts)
                then []
                else
                  let -- Find the value token(s) after the "=" in the literal
                      (valueToks, quoted) = findValueTokens parts
                      varOrLit = extractConfigValue valueToks quoted
                   in case varOrLit of
                        Just (Left var) -> [ConfigAssign pathParts var quoted sp]
                        Just (Right lit) -> [ConfigLit pathParts lit sp]
                        Nothing -> []
        _ -> []

-- | Find value tokens and determine if quoted
-- Returns the tokens representing the value and whether it was quoted
findValueTokens :: [SA.Token] -> ([SA.Token], Quoted)
findValueTokens parts = loop parts False
  where
    loop [] _ = ([], Unquoted)
    loop (t@(SA.OuterToken _ inner) : rest) seenEq = case inner of
      SA.Inner_T_Literal s | "=" `T.isSuffixOf` (T.pack s) ->
        -- We've hit the "=" in "config.x.y=", value starts next
        loop rest True
      SA.Inner_T_DoubleQuoted _ | seenEq ->
        -- Double-quoted value
        ([t], Quoted)
      _ | seenEq ->
        -- Unquoted value (could be literal or variable)
        ([t], Unquoted)
      _ ->
        -- Still in the path part
        loop rest seenEq

-- | Extract variable name or literal from value tokens
extractConfigValue :: [SA.Token] -> Quoted -> Maybe (Either Text Literal)
extractConfigValue [] _ = Nothing
extractConfigValue (tok:_) _quoted =
  let text = tokenToText tok
   in case extractSimpleVar text of
        Just var -> Just (Left var)
        Nothing -> Just (Right (parseLiteral text))

-- | Extract simple variable reference: ${VAR} or HOST -> Just "VAR"/"HOST"
extractSimpleVar :: Text -> Maybe Text
extractSimpleVar t
  | "${" `T.isPrefixOf` t && "}" `T.isSuffixOf` t =
      let v = T.dropEnd 1 (T.drop 2 t)
       in if isVar v then Just v else Nothing
  | "$" `T.isPrefixOf` t
      && not ("$(" `T.isPrefixOf` t)
      && not ("${" `T.isPrefixOf` t) =
      let v = T.drop 1 t
       in if isVar v then Just v else Nothing
  | isVar t =
      Just t
  | otherwise =
      Nothing
  where
    isVar v =
      not (T.null v)
        && T.all isVarChar v
        && not (isNumericLiteral v)
        && not (isBoolLiteral v)
    isVarChar c = c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')

-- | Extract only "$..." and "${...}" variable references.
--
-- This is intentionally stricter than 'extractSimpleVar': it will *not* treat
-- bare words like "curl" or "HOST" as variables.
extractVarRef :: Text -> Maybe Text
extractVarRef t
  | "${" `T.isPrefixOf` t && "}" `T.isSuffixOf` t = extractSimpleVar t
  | "$" `T.isPrefixOf` t = extractSimpleVar t
  | otherwise = Nothing

-- | Facts from config.* assignment (text-based fallback)
configFacts :: Span -> Text -> [Fact]
configFacts sp text =
  case parseConfigAssignment text of
    Just ConfigAssignment {..} ->
      case configValue of
        Left var -> [ConfigAssign configPath var configQuoted sp]
        Right lit -> [ConfigLit configPath lit sp]
    Nothing -> []

-- | Shell builtins that are allowed without store paths
-- These are part of bash itself, not external commands
-- This is a STRICT list per SPECIFICATION.md - only true shell builtins
isIgnoredCommand :: Text -> Bool
isIgnoredCommand cmd = cmd `elem` shellBuiltins

-- | TRUE shell builtins only (per POSIX + bash)
-- NOTE: This is intentionally restrictive. External tools like curl, grep, etc.
-- MUST use store paths. See SPECIFICATION.md §2.4
shellBuiltins :: [Text]
shellBuiltins =
  [ -- Flow control
    "if", "then", "else", "elif", "fi"
  , "case", "esac"
  , "for", "while", "until", "do", "done"
  , "function", "return"
  , "break", "continue"
    -- Variable/environment
  , "set", "unset", "export", "declare", "local", "readonly", "typeset"
  , "let"
    -- Shell operation  
  , "source", "."
  , "cd", "pwd", "pushd", "popd", "dirs"
  , "echo", "printf", "read"
  , "exit", "exec"
  , "trap", "wait", "kill"
  , "true", "false", ":"
  , "test", "["
    -- Job control
  , "bg", "fg", "jobs", "disown"
    -- Misc builtins
  , ""  -- Empty string placeholder
  , "builtin", "command", "type", "hash"
  , "help", "enable"
  , "shopt", "bind", "complete", "compgen"
  , "getopts", "shift"
  , "times", "ulimit", "umask"
  , "history", "fc"
  , "eval"  -- Builtin (but also forbidden construct - caught by lint)
  ]

-- NOTE: The previous commonUtilities list has been REMOVED.
-- External tools like cat, grep, curl, etc. MUST use store paths.
-- This requires reproducibility and makes dependencies explicit.

-- | Facts from command invocation
cmdInvocationFacts :: Span -> Text -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Fact]
cmdInvocationFacts sp cmd args = do
  -- What kind of command is this?
  let pathFact
        | isStorePath cmd = [UsesStorePath (StorePath cmd) sp]
        | Just var <- extractVarRef cmd = [DynamicCommand var sp]
        | "@__nix_compile_interp_" `T.isPrefixOf` cmd = [BareCommand cmd sp]
        | "@" `T.isPrefixOf` cmd = [] -- Ignore other substitution placeholders like @foo@
        | isIgnoredCommand cmd = []  -- builtins are OK
        | otherwise = [BareCommand cmd sp]

  -- Extract the command name (strip store path prefix if present)
  let cmdName = extractCmdName cmd

  -- Parse arguments looking for flag-value pairs with variables
  argFacts <- extractArgFacts cmdName args
  pure (pathFact ++ argFacts)

-- | Extract command name from path
-- /nix/store/xxx-curl/bin/curl -> curl
extractCmdName :: Text -> Text
extractCmdName path
  | isStorePath path = case reverse (T.splitOn "/" path) of
      (name : _) | not (T.null name) -> name
      _ -> path
  | otherwise = path

-- | Extract CmdArg facts from argument list
-- Looks for patterns like: --timeout $VAR, --timeout "$VAR", or --timeout=$VAR
extractArgFacts :: Text -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Fact]
extractArgFacts cmd tokens = loop tokens
  where
    loop [] = pure []
    loop (tok : rest) =
      case parseFlagEqVar tok of
        Just getFact -> do
          sp <- mkSpan (tokId tok)
          restFacts <- loop rest
          pure (getFact sp : restFacts)
        Nothing ->
          case rest of
            (valueTok : rest') ->
              let flagText = tokenToText tok
                  valueText = tokenToText valueTok
               in case extractVarRef valueText of
                    Just varName
                      | isFlag flagText -> do
                          sp <- mkSpan (tokId tok)
                          restFacts <- loop rest'
                          pure (CmdArg cmd flagText varName sp : restFacts)
                    _ ->
                      loop rest
            [] ->
              pure []

    -- Handle the common pattern: --flag=$VAR or --flag="$VAR"
    -- Returns a function that needs a Span to create the Fact
    parseFlagEqVar tok =
      let t = tokenToText tok
          (flag, eqRest) = T.breakOn "=" t
       in if isFlag flag && not (T.null eqRest)
            then case extractVarRef (T.drop 1 eqRest) of
              Just varName -> Just (\sp -> CmdArg cmd flag varName sp)
              Nothing -> Nothing
            else Nothing

    isFlag t = "-" `T.isPrefixOf` t

    tokId (SA.OuterToken tokId' _) = tokId'

-- | Try to extract parameter expansion from a token
extractParamExpansion :: SA.Token -> Maybe ParamExpansion
extractParamExpansion tok =
  parseParamExpansion (tokenToText tok)

-- | Try to extract a literal from a token
extractLiteral :: SA.Token -> Maybe Literal
extractLiteral tok =
  let t = tokenToText tok
   in if T.null t then Nothing else Just (parseLiteral t)

-- | Convert token to text (simplified)
tokenToText :: SA.Token -> Text
tokenToText (SA.OuterToken _ inner) = innerToText inner

innerToText :: SA.InnerToken SA.Token -> Text
innerToText = \case
  SA.Inner_T_Literal s -> T.pack s
  SA.Inner_T_SingleQuoted s -> T.pack s
  SA.Inner_T_Glob s -> T.pack s
  SA.Inner_T_NormalWord parts -> T.concat (map tokenToText parts)
  SA.Inner_T_DoubleQuoted parts -> T.concat (map tokenToText parts)
  SA.Inner_T_DollarBraced _ t -> "${" <> tokenToText t <> "}"
  SA.Inner_T_DollarSingleQuoted s -> T.pack s
  SA.Inner_T_BraceExpansion parts -> T.concat (map tokenToText parts)
  _ -> ""

-- | Make a span from a token ID using the position map
mkSpan :: SA.Id -> Reader (Map SA.Id (Position, Position)) Span
mkSpan scId = do
  posMap <- ask
  case Map.lookup scId posMap of
    Just (start, end) ->
      pure $ Span
        (Loc (fromIntegral $ posLine start) (fromIntegral $ posColumn start))
        (Loc (fromIntegral $ posLine end) (fromIntegral $ posColumn end))
        (Just (posFile start))
    Nothing ->
      let (SA.Id n) = scId
       in pure $ Span (Loc n 0) (Loc n 0) Nothing
