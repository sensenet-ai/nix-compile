{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // bash // facts
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "As she walked from the Louvre, she seemed to sense some articulated
--    structure shifting to accommodate her course through the city. The
--    waiter would be merely a part of the thing, one limb, a delicate probe
--    or palp. The whole would be larger, much larger. How could she have
--    imagined that it would be possible to live, to move, in the unnatural
--    field of Virek's wealth without suffering distortion?"
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // ast // walk // facts
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Bash.Facts (
  extractFacts,
)
where

import Control.Monad.Reader (Reader, ask, runReader)
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import NixCompile.Bash.Parse (BashAST (..))
import NixCompile.Bash.Patterns
import NixCompile.Bash.Types
import NixCompile.Core.Span (Loc (..), Span (..))
import ShellCheck.AST qualified as SA
import ShellCheck.Interface (Position (..))

-- ── entry point: walk entire AST collecting facts ─────────────────

-- | walk a bash AST bottom-up, extracting facts at every token
extractFacts :: BashAST -> [Fact]
extractFacts (BashAST root posMap) = runReader (traverseTokens root) posMap

-- | recurse into token children, collecting facts at each node
traverseTokens :: SA.Token -> Reader (Map SA.Id (Position, Position)) [Fact]
traverseTokens (SA.OuterToken shellCheckId innerToken) = do
  local <- factFromInnerToken shellCheckId innerToken
  rest <- mapM traverseTokens (toList innerToken)
  pure (local ++ concat rest)

-- ── inner-token dispatch ─────────────────────────────────────────

-- | dispatch based on ShellCheck inner token type
factFromInnerToken :: SA.Id -> SA.InnerToken SA.Token -> Reader (Map SA.Id (Position, Position)) [Fact]
factFromInnerToken shellCheckId innerToken = do
  sourceSpan <- mkSpan shellCheckId
  dispatch sourceSpan innerToken
 where
  dispatch sourceSpan (SA.Inner_T_Assignment _ name indices value) =
    pure $ factFromAssignment sourceSpan (assignmentLhs name indices) value
  dispatch sourceSpan (SA.Inner_T_SimpleCommand assigns commandWords) =
    factFromCommand sourceSpan assigns commandWords
  dispatch sourceSpan (SA.Inner_T_Pipeline _ _) = factFromPipeline sourceSpan
  dispatch sourceSpan (SA.Inner_T_Subshell _) = factFromSubshell sourceSpan
  dispatch sourceSpan (SA.Inner_T_Redirecting _ _) = factFromRedirect sourceSpan
  dispatch sourceSpan (SA.Inner_T_IoFile _ _) = factFromRedirect sourceSpan
  dispatch sourceSpan (SA.Inner_T_FdRedirect _ _) = factFromRedirect sourceSpan
  dispatch _ _ = pure []

-- ── assignment facts ─────────────────────────────────────────────

-- | facts from a single variable assignment (config.* or regular env var)

{- | Reconstruct the assignment LHS. ShellCheck keeps an array subscript in a
separate indices field, so @config[server]=…@ arrives as name=@config@,
indices=@[server]@. We rebuild @config[server]@ so it routes to the config-array
path (only for the @config@ namespace — ordinary bash arrays are left as the bare
name, preserving prior behavior). (REVIEW-3 #24)
-}
assignmentLhs :: String -> [SA.Token] -> Text
assignmentLhs name indices
  | name == "config"
  , not (null indices) =
      T.pack name <> "[" <> T.intercalate "." (map tokenToText indices) <> "]"
  | otherwise = T.pack name

factFromAssignment :: Span -> Text -> SA.Token -> [Fact]
factFromAssignment sourceSpan variableName valueToken =
  maybe
    (envVarFacts sourceSpan variableName valueToken)
    (\configPath -> configArrayFacts sourceSpan configPath valueToken)
    (parseConfigArrayAssign variableName)

-- ── command facts ────────────────────────────────────────────────

-- | facts from a simple command (pre-command assigns are ignored)
factFromCommand :: Span -> [SA.Token] -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Fact]
factFromCommand sourceSpan _assigns commandWords =
  commandFacts sourceSpan commandWords

-- | placeholder: pipeline facts (children are traversed separately)
factFromPipeline :: Span -> Reader (Map SA.Id (Position, Position)) [Fact]
factFromPipeline _ = pure []

-- | placeholder: subshell facts (children are traversed separately)
factFromSubshell :: Span -> Reader (Map SA.Id (Position, Position)) [Fact]
factFromSubshell _ = pure []

-- | placeholder: redirect facts (children are traversed separately)
factFromRedirect :: Span -> Reader (Map SA.Id (Position, Position)) [Fact]
factFromRedirect _ = pure []

-- ── command body dispatch ────────────────────────────────────────

-- | inspect command tokens: config.* commands vs regular command invocations
commandFacts :: Span -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Fact]
commandFacts _ [] = pure []
commandFacts sourceSpan (commandToken : arguments) =
  let commandText = tokenToText commandToken
   in if "config." `T.isPrefixOf` commandText
        then pure $ configFactsFromToken sourceSpan commandToken
        else commandInvocationFacts sourceSpan commandText arguments

-- | collect invocation facts: store path usage + argument flag facts
commandInvocationFacts :: Span -> Text -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Fact]
commandInvocationFacts sourceSpan command arguments = do
  let pathFact = factFromStorePath sourceSpan command
  let commandName = resolveCommandName command
  argumentFacts <- extractArgFacts commandName arguments
  pure (pathFact ++ argumentFacts)

-- ── store path vs bare command classification ────────────────────

-- | classify a command text: store path, dynamic var, bare command, or ignored
factFromStorePath :: Span -> Text -> [Fact]
factFromStorePath sourceSpan command
  | T.null command = []
  | isStorePath command = [UsesStorePath (StorePath command) sourceSpan]
  | Just variable <- extractVarRef command = [DynamicCommand variable sourceSpan]
  | "@__nix_compile_interp_" `T.isPrefixOf` command = [BareCommand command sourceSpan]
  | "@" `T.isPrefixOf` command = []
  | isIgnoredCommand command = []
  | otherwise = [BareCommand command sourceSpan]

-- | extract short command name from a store path (e.g. /nix/store/xxx-curl/bin/curl -> curl)
resolveCommandName :: Text -> Text
resolveCommandName path
  | isStorePath path = lastSegment (reverse (T.splitOn "/" path))
  | otherwise = path
 where
  lastSegment (name : _) | not (T.null name) = name
  lastSegment _ = path

-- ── argument flag extraction (--flag=$VAR, --flag $VAR) ───────────

{- | scan command arguments for variable references in flags
handles both --flag=$VAR (same token) and --flag $VAR (adjacent tokens)
-}
extractArgFacts :: Text -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Fact]
extractArgFacts command tokens = loop tokens
 where
  loop [] = pure []
  loop (token : remainingTokens) =
    maybe afterFlag (emitWith remainingTokens) (factFromFlagArgument command token)
   where
    -- both the same-token (--flag=$VAR) and adjacent-token (--flag $VAR) emits
    -- carry the FLAG token's span; only the tail to recurse on differs.
    emitWith rest getFact = do
      sourceSpan <- mkSpan (tokenId token)
      restFacts <- loop rest
      pure (getFact sourceSpan : restFacts)
    afterFlag = pairCase remainingTokens
    pairCase (valueToken : restAfterValue) =
      maybe (loop remainingTokens) (emitWith restAfterValue) (factFromFlagValuePair command token valueToken)
    pairCase [] = pure []

  tokenId (SA.OuterToken tokenId' _) = tokenId'

{- | detect --flag=$VAR within a single token
returns a (Span -> Fact) thunk since the caller owns the span
-}
factFromFlagArgument :: Text -> SA.Token -> Maybe (Span -> Fact)
factFromFlagArgument command token =
  let text = tokenToText token
      (flag, eqRest) = T.breakOn "=" text
   in if isFlag flag && not (T.null eqRest)
        then fmap (CmdArg command flag) (extractVarRef (T.drop 1 eqRest))
        else Nothing
 where
  isFlag f = "-" `T.isPrefixOf` f

-- | detect --flag $VAR across two adjacent tokens
factFromFlagValuePair :: Text -> SA.Token -> SA.Token -> Maybe (Span -> Fact)
factFromFlagValuePair command flagToken valueToken
  | isFlag flagText, Just variableName <- extractVarRef valueText = Just (CmdArg command flagText variableName)
  | otherwise = Nothing
 where
  flagText = tokenToText flagToken
  valueText = tokenToText valueToken
  isFlag f = "-" `T.isPrefixOf` f

-- ── config[path.to.key] syntax ───────────────────────────────────

-- | parse config[path.to.key] assignment name → ConfigPath
parseConfigArrayAssign :: Text -> Maybe ConfigPath
parseConfigArrayAssign name
  | "config[" `T.isPrefixOf` name && "]" `T.isSuffixOf` name =
      let pathText = T.dropEnd 1 (T.drop 7 name)
          parts = T.splitOn "." pathText
       in if validConfigPath parts then Just parts else Nothing
  | otherwise = Nothing

-- ── config[...] = value facts ────────────────────────────────────

-- | extract facts from a config[...]=value assignment
configArrayFacts :: Span -> ConfigPath -> SA.Token -> [Fact]
configArrayFacts sourceSpan configPath valueToken =
  maybe noVar withVar (extractVarRef valueText)
 where
  valueText = tokenToText valueToken
  quoted = isQuotedToken valueToken
  withVar variable = [ConfigAssign configPath variable quoted sourceSpan]
  litFact = [ConfigLit configPath (parseLiteral valueText) sourceSpan]
  noVar
    | "${" `T.isInfixOf` valueText =
        maybe litFact (\parts -> [ConfigTemplate configPath parts quoted sourceSpan]) (parseConfigTemplate valueText)
    | otherwise = litFact

-- ── quoting detection ────────────────────────────────────────────

-- | determine if a token is quoted or unquoted (for config value semantics)
isQuotedToken :: SA.Token -> Quoted
isQuotedToken (SA.OuterToken _ (SA.Inner_T_DoubleQuoted _)) = Quoted
isQuotedToken (SA.OuterToken _ (SA.Inner_T_NormalWord [SA.OuterToken _ (SA.Inner_T_DoubleQuoted _)])) = Quoted
isQuotedToken _ = Unquoted

-- ── env var facts: ${var:-default}, ${var:=default}, ${var:?err} ──

-- | extract facts from a regular (non-config) shell variable assignment
envVarFacts :: Span -> Text -> SA.Token -> [Fact]
envVarFacts sourceSpan variableName valueToken =
  maybe fromLiteral fromExpansion (extractParamExpansion valueToken)
 where
  fromExpansion (DefaultValue _var (Just defaultValue)) = defaultFacts defaultValue
  fromExpansion (AssignDefault _var (Just defaultValue)) = defaultFacts defaultValue
  fromExpansion (AssignDefault _var Nothing) = [DefaultIs variableName (LitString "") sourceSpan]
  fromExpansion (DefaultValue _var Nothing) = [DefaultIs variableName (LitString "") sourceSpan]
  fromExpansion (ErrorIfUnset _var _) = [Required variableName sourceSpan]
  fromExpansion (SimpleRef variable) = [AssignFrom variableName variable sourceSpan]
  fromExpansion (UseAlternate _var _) = []

  fromLiteral = maybe [] (\lit -> [AssignLit variableName lit sourceSpan]) (extractLiteral valueToken)

  defaultFacts defaultValue =
    maybe
      [DefaultIs variableName (parseLiteral defaultValue) sourceSpan]
      (\other -> [DefaultFrom variableName other sourceSpan])
      (defaultFromVar defaultValue)

  -- if the default value is itself a variable reference, emit DefaultFrom
  defaultFromVar defaultValue
    | Just (SimpleRef variable) <- parseParamExpansion defaultValue = Just variable
    | otherwise = Nothing

-- ── config.* command facts ───────────────────────────────────────

-- | extract config assignment facts from a config.* command token
configFactsFromToken :: Span -> SA.Token -> [Fact]
configFactsFromToken sourceSpan (SA.OuterToken _ (SA.Inner_T_NormalWord parts)) =
  configFactsFromParts sourceSpan parts
configFactsFromToken sourceSpan token = configFacts sourceSpan (tokenToText token)

-- ── token-part-level config analysis ─────────────────────────────

{- | extract config assignment facts from NormalWord token parts
splits on =, validates path, then parses the value side
-}
configFactsFromParts :: Span -> [SA.Token] -> [Fact]
configFactsFromParts sourceSpan tokenParts = maybe [] fromPrefix matchedPrefix
 where
  combinedText = T.concat (map tokenToText tokenParts)
  (leftHandSide, rightHandSide) = T.breakOn "=" combinedText
  matchedPrefix = T.stripPrefix "config." leftHandSide

  fromPrefix pathText
    | T.null rightHandSide = []
    | not (validConfigPath pathParts) = []
    | otherwise = buildConfigFacts pathParts
   where
    pathParts = T.splitOn "." pathText

  buildConfigFacts parts =
    map (configValueFact parts quoted sourceSpan) (maybeToList parsed)
   where
    (valueTokens, quoted) = findValueTokens tokenParts
    parsed = selectValueParser valueTokens (T.drop 1 rightHandSide) quoted

-- ── value parser selection ───────────────────────────────────────

{- | choose the appropriate value parser based on token structure
empty token list → text fallback; non-empty → try template / var / dynamic
-}
selectValueParser :: [SA.Token] -> Text -> Quoted -> Maybe ConfigValueDynamic
selectValueParser [] rhsText quoted =
  parseConfigValueDynamic rhsText quoted
selectValueParser tokens _ quoted = classify (parseConfigTemplateTokens tokens)
 where
  classify (Just [ConfigVar variable]) = Just (CVDVar variable)
  classify (Just templateParts) = Just (CVDTemplate templateParts)
  classify Nothing = parseConfigValueDynamic (T.concat (map tokenToText tokens)) quoted

-- ── config value dynamic representation ──────────────────────────

data ConfigValueDynamic
  = -- | single variable reference
    CVDVar Text
  | -- | plain literal
    CVDLit Literal
  | -- | template with mixed text/vars
    CVDTemplate [ConfigPart]

-- | convert a dynamic value to the corresponding Fact constructor
configValueFact :: ConfigPath -> Quoted -> Span -> ConfigValueDynamic -> Fact
configValueFact configPath quoted sourceSpan (CVDVar variable) = ConfigAssign configPath variable quoted sourceSpan
configValueFact configPath _quoted sourceSpan (CVDLit literal) = ConfigLit configPath literal sourceSpan
configValueFact configPath quoted sourceSpan (CVDTemplate templateParts) = ConfigTemplate configPath templateParts quoted sourceSpan

-- ── value token extraction ───────────────────────────────────────

{- | scan token parts for the portion after = and determine quoting
n.b. we need to find = within literal tokens, then grab the next token
-}
findValueTokens :: [SA.Token] -> ([SA.Token], Quoted)
findValueTokens parts = loop parts False
 where
  loop [] _ = ([], Unquoted)
  loop (token@(SA.OuterToken _ innerToken) : remainingTokens) seenEquals
    | SA.Inner_T_Literal content <- innerToken
    , not seenEquals
    , "=" `T.isInfixOf` T.pack content =
        loop remainingTokens True
    | SA.Inner_T_DoubleQuoted _ <- innerToken, seenEquals = ([token], Quoted)
    | seenEquals = ([token], Unquoted)
    | otherwise = loop remainingTokens seenEquals

-- ── dynamic text-level parser ────────────────────────────────────

-- | parse a config value from raw text (fallback when token parser fails)
parseConfigValueDynamic :: Text -> Quoted -> Maybe ConfigValueDynamic
parseConfigValueDynamic rawText _quoted
  | T.null strippedText = Nothing
  | otherwise = classify (parseConfigTemplate strippedText)
 where
  classify (Just [ConfigVar variable]) = Just (CVDVar variable)
  classify (Just templateParts) = Just (CVDTemplate templateParts)
  classify Nothing = Just (CVDLit (parseLiteral strippedText))
  strippedText
    | "\"" `T.isPrefixOf` rawText && "\"" `T.isSuffixOf` rawText = T.dropEnd 1 (T.drop 1 rawText)
    | otherwise = rawText

-- ═════════════════════════════════════════════════════════════════════════════
-- token → config template
-- ═════════════════════════════════════════════════════════════════════════════

-- -- token sequence → config parts -- --
-- ShellCheck tokenizes `"$A-$B"` as a sequence of literal+var tokens.
-- We reconstruct the template structure from that token stream.

parseConfigTemplateTokens :: [SA.Token] -> Maybe [ConfigPart]
parseConfigTemplateTokens tokens =
  let parts = mergeTextParts (concatMap tokenParts tokens)
   in if any isVarPart parts then Just parts else Nothing
 where
  -- ── classify: if any part is a variable, it's a template ──
  isVarPart (ConfigText _) = False
  isVarPart _ = True

  -- ── token → [ConfigPart] ──
  tokenParts (SA.OuterToken _ innerToken) = innerParts innerToken

  -- ── inner token → flat part list ──
  -- n.b. Literal, SingleQuoted, Glob all become ConfigText
  -- DollarBraced tries expansionPart first
  innerParts (SA.Inner_T_Literal content) = [ConfigText (T.pack content)]
  innerParts (SA.Inner_T_SingleQuoted content) = [ConfigText (T.pack content)]
  innerParts (SA.Inner_T_Glob content) = [ConfigText (T.pack content)]
  innerParts (SA.Inner_T_NormalWord subParts) = concatMap tokenParts subParts
  innerParts (SA.Inner_T_DoubleQuoted subParts) = concatMap tokenParts subParts
  innerParts (SA.Inner_T_DollarBraced _ body) = expansionPart ("${" <> tokenToText body <> "}")
  innerParts _ = []

  -- ── ${...} → ConfigVar / ConfigVarDefault / ConfigVarRequired ──
  expansionPart text = classify (parseParamExpansion text)
   where
    classify (Just (SimpleRef variable)) = [ConfigVar variable]
    classify (Just (DefaultValue variable defaultValue)) = [ConfigVarDefault variable (maybe "" id defaultValue)]
    classify (Just (AssignDefault variable defaultValue)) = [ConfigVarDefault variable (maybe "" id defaultValue)]
    classify (Just (ErrorIfUnset variable _)) = [ConfigVarRequired variable]
    classify (Just (UseAlternate variable alternate)) = [ConfigVarAlternate variable (maybe "" id alternate)]
    classify Nothing = [ConfigText text]

  -- ── merge adjacent ConfigText parts ──
  mergeTextParts = foldr step []
   where
    step (ConfigText a) (ConfigText b : xs) = ConfigText (a <> b) : xs
    step part xs = part : xs

-- -- text → config parts -- --
-- Parses raw text like "$A-${B:-default}" into [ConfigVar "A", ConfigText "-", ConfigVarDefault "B" "default"]
-- n.b. this is the text-level fallback when token-level parsing didn't apply

parseConfigTemplate :: Text -> Maybe [ConfigPart]
parseConfigTemplate sourceText =
  let parts = parseParts sourceText
   in if any isVarPart parts then Just (mergeTextParts parts) else Nothing
 where
  -- any part that carries a variable counts — not just bare $VAR. Without the
  -- default/required/alternate cases, a template built entirely of
  -- `${VAR:-default}` parts was misclassified as a plain literal. (REVIEW-3 #24)
  isVarPart (ConfigVar _) = True
  isVarPart (ConfigVarDefault _ _) = True
  isVarPart (ConfigVarRequired _) = True
  isVarPart (ConfigVarAlternate _ _) = True
  isVarPart (ConfigText _) = False

  -- ── main parser: dispatch on first character ──
  parseParts remainingText
    | T.null remainingText = []
    | "${" `T.isPrefixOf` remainingText =
        -- \${...} expansion: extract name, try param expansion, fallback to text
        parseDollarBrace remainingText
    | "$" `T.isPrefixOf` remainingText =
        -- \$VAR simple variable: grab identifier chars
        parseDollarVar remainingText
    | otherwise =
        -- plain text: scan forward to the next $
        splitText remainingText

  -- ── ${...} handler ──
  -- extract the name between ${ and }, then try each expansion form
  parseDollarBrace text =
    let textAfterDollarBrace = T.drop 2 text
        (name, textAfterName) = T.breakOn "}" textAfterDollarBrace
        rest = parseParts (T.drop 1 textAfterName)
        classify (Just (SimpleRef variable)) = ConfigVar variable : rest
        classify (Just (DefaultValue variable defaultValue)) = ConfigVarDefault variable (maybe "" id defaultValue) : rest
        classify (Just (AssignDefault variable defaultValue)) = ConfigVarDefault variable (maybe "" id defaultValue) : rest
        classify (Just (ErrorIfUnset variable _)) = ConfigVarRequired variable : rest
        classify (Just (UseAlternate variable alternate)) = ConfigVarAlternate variable (maybe "" id alternate) : rest
        classify Nothing = splitText text
     in if "}" `T.isPrefixOf` textAfterName
          then classify (parseParamExpansion ("${" <> name <> "}"))
          else splitText text

  -- ── $VAR handler ──
  parseDollarVar text =
    let textAfterDollar = T.drop 1 text
        (name, textAfterName) = T.span isVarChar textAfterDollar
     in if isVarName name
          then ConfigVar name : parseParts textAfterName
          else splitText text

  -- ── text chunk: find the next $, emit as ConfigText ──
  splitText text =
    let (textBefore, textAfter) = T.breakOn "$" text
     in if T.null textBefore
          then ConfigText (T.take 1 textAfter) : parseParts (T.drop 1 textAfter)
          else ConfigText textBefore : parseParts textAfter

  -- ── identifier validation ──
  isVarName name =
    not (T.null name)
      && not (isNumericLiteral name)
      && not (isBoolLiteral name)
      && T.all isVarChar name

  isVarChar character = character == '_' || (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9')

  -- ── merge adjacent ConfigText parts (post-processing) ──
  mergeTextParts = foldr step []
   where
    step (ConfigText a) (ConfigText b : xs) = ConfigText (a <> b) : xs
    step part xs = part : xs

-- ── variable reference extraction ────────────────────────────────

{- | extract a plain variable name from ${VAR}, $VAR, or just VAR
n.b. rejects $(...) command substitutions and empty strings
-}
extractSimpleVar :: Text -> Maybe Text
extractSimpleVar text
  | "${" `T.isPrefixOf` text && "}" `T.isSuffixOf` text =
      let name = T.dropEnd 1 (T.drop 2 text)
       in if isValidName name then Just name else Nothing
  | "$" `T.isPrefixOf` text
      && not ("$(" `T.isPrefixOf` text)
      && not ("${" `T.isPrefixOf` text) =
      let name = T.drop 1 text
       in if isValidName name then Just name else Nothing
  | isValidName text =
      Just text
  | otherwise =
      Nothing
 where
  isValidName name =
    not (T.null name)
      && T.all isVarChar name
      && not (isNumericLiteral name)
      && not (isBoolLiteral name)
  isVarChar character = character == '_' || (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9')

-- | extract a variable reference that starts with $ (either $VAR or ${VAR})
extractVarRef :: Text -> Maybe Text
extractVarRef text
  | "${" `T.isPrefixOf` text && "}" `T.isSuffixOf` text = extractSimpleVar text
  | "$" `T.isPrefixOf` text = extractSimpleVar text
  | otherwise = Nothing

-- ── config.* text fallback parser ────────────────────────────────

{- | extract config facts from raw text (used when token-level parsing fails)
tries dynamic (var-containing) parsing first, then falls back to parseConfigAssignment
-}
configFacts :: Span -> Text -> [Fact]
configFacts sourceSpan text
  | facts@(_ : _) <- dynamicFallback = facts
  | otherwise = fallbackConfigFacts sourceSpan text
 where
  dynamicFallback
    | Just pathText <- T.stripPrefix "config." leftHandSide
    , Just rightHandSide <- T.stripPrefix "=" rightHandSide0
    , "$" `T.isInfixOf` rightHandSide
    , let pathParts = T.splitOn "." pathText
    , validConfigPath pathParts
    , Just parsed <- parseConfigValueDynamic rightHandSide Unquoted =
        [configValueFact pathParts Unquoted sourceSpan parsed]
    | otherwise = []
   where
    (leftHandSide, rightHandSide0) = T.breakOn "=" text

  fallbackConfigFacts sp text_ = maybe [] fromAssignment (parseConfigAssignment text_)
   where
    fromAssignment ConfigAssignment{..} =
      either
        (\variable -> [ConfigAssign configPath variable configQuoted sp])
        (\literal -> [ConfigLit configPath literal sp])
        configValue

-- ── shell builtin classification ─────────────────────────────────

-- | is this command a shell builtin (no store path needed)?
isIgnoredCommand :: Text -> Bool
isIgnoredCommand command = command `elem` shellBuiltins

-- | exhaustive list of POSIX + bash builtins
shellBuiltins :: [Text]
shellBuiltins =
  [ "if"
  , "then"
  , "else"
  , "elif"
  , "fi"
  , "case"
  , "esac"
  , "for"
  , "while"
  , "until"
  , "do"
  , "done"
  , "function"
  , "return"
  , "break"
  , "continue"
  , "set"
  , "unset"
  , "export"
  , "declare"
  , "local"
  , "readonly"
  , "typeset"
  , "let"
  , "source"
  , "."
  , "cd"
  , "pwd"
  , "pushd"
  , "popd"
  , "dirs"
  , "echo"
  , "printf"
  , "read"
  , "exit"
  , "exec"
  , "trap"
  , "wait"
  , "kill"
  , "true"
  , "false"
  , ":"
  , "test"
  , "["
  , "bg"
  , "fg"
  , "jobs"
  , "disown"
  , "builtin"
  , "command"
  , "type"
  , "hash"
  , "help"
  , "enable"
  , "shopt"
  , "bind"
  , "complete"
  , "compgen"
  , "getopts"
  , "shift"
  , "times"
  , "ulimit"
  , "umask"
  , "history"
  , "fc"
  ]

-- ── token → parameter expansion / literal ────────────────────────

-- | try to parse a token's text as a parameter expansion expression
extractParamExpansion :: SA.Token -> Maybe ParamExpansion
extractParamExpansion token =
  parseParamExpansion (tokenToText token)

-- | try to extract a literal value from a token
extractLiteral :: SA.Token -> Maybe Literal
extractLiteral token =
  let text = tokenToText token
   in if T.null text then Nothing else Just (parseLiteral text)

-- ── token → text conversion ──────────────────────────────────────

-- | convert a ShellCheck token to its text representation
tokenToText :: SA.Token -> Text
tokenToText (SA.OuterToken _ inner) = innerToText inner

-- | convert a ShellCheck inner token to text, recursing into child tokens
innerToText :: SA.InnerToken SA.Token -> Text
innerToText (SA.Inner_T_Literal content) = T.pack content
innerToText (SA.Inner_T_SingleQuoted content) = T.pack content
innerToText (SA.Inner_T_Glob content) = T.pack content
innerToText (SA.Inner_T_NormalWord parts) = T.concat (map tokenToText parts)
innerToText (SA.Inner_T_DoubleQuoted parts) = T.concat (map tokenToText parts)
innerToText (SA.Inner_T_DollarBraced _ token) = "${" <> tokenToText token <> "}"
innerToText (SA.Inner_T_DollarSingleQuoted content) = T.pack content
innerToText (SA.Inner_T_BraceExpansion parts) = T.concat (map tokenToText parts)
-- arithmetic-context tokens — used for array subscripts like `config[server]`
-- (the key parses as a TA_Variable inside a TA_Sequence). (REVIEW-3 #24)
innerToText (SA.Inner_TA_Variable name _) = T.pack name
innerToText (SA.Inner_TA_Sequence parts) = T.concat (map tokenToText parts)
innerToText _ = ""

-- ── span construction ────────────────────────────────────────────

-- | look up a ShellCheck node's position in the position map and produce a Span
mkSpan :: SA.Id -> Reader (Map SA.Id (Position, Position)) Span
mkSpan shellCheckId = do
  posMap <- ask
  pure $ maybe noSpan toSpan (Map.lookup shellCheckId posMap)
 where
  noSpan = Span (Loc 0 0) (Loc 0 0) Nothing
  -- n.b. ShellCheck positions are 1-based (per the Interface module);
  -- this matches megaparsec's positions so no adjustment is needed.
  toSpan (start, end) =
    Span
      (Loc (fromIntegral $ posLine start) (fromIntegral $ posColumn start))
      (Loc (fromIntegral $ posLine end) (fromIntegral $ posColumn end))
      (Just (posFile start))
