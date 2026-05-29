{-# LANGUAGE LambdaCase #-}
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
import NixCompile.Types
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
    case innerToken of
        SA.Inner_T_Assignment _ name _ value ->
            pure $ factFromAssignment sourceSpan (T.pack name) value
        SA.Inner_T_SimpleCommand assigns commandWords ->
            factFromCommand sourceSpan assigns commandWords
        SA.Inner_T_Pipeline _ _ -> factFromPipeline sourceSpan
        SA.Inner_T_Subshell _ -> factFromSubshell sourceSpan
        SA.Inner_T_Redirecting _ _ -> factFromRedirect sourceSpan
        SA.Inner_T_IoFile _ _ -> factFromRedirect sourceSpan
        SA.Inner_T_FdRedirect _ _ -> factFromRedirect sourceSpan
        _ -> pure []

-- ── assignment facts ─────────────────────────────────────────────

-- | facts from a single variable assignment (config.* or regular env var)
factFromAssignment :: Span -> Text -> SA.Token -> [Fact]
factFromAssignment sourceSpan variableName valueToken =
    case parseConfigArrayAssign variableName of
        Just configPath -> configArrayFacts sourceSpan configPath valueToken
        Nothing -> envVarFacts sourceSpan variableName valueToken

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
commandFacts sourceSpan tokens = case tokens of
    [] -> pure []
    (commandToken : arguments) ->
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
    | isStorePath path = case reverse (T.splitOn "/" path) of
        (name : _) | not (T.null name) -> name
        _ -> path
    | otherwise = path

-- ── argument flag extraction (--flag=$VAR, --flag $VAR) ───────────

{- | scan command arguments for variable references in flags
handles both --flag=$VAR (same token) and --flag $VAR (adjacent tokens)
-}
extractArgFacts :: Text -> [SA.Token] -> Reader (Map SA.Id (Position, Position)) [Fact]
extractArgFacts command tokens = loop tokens
  where
    loop [] = pure []
    loop (token : remainingTokens) =
        case factFromFlagArgument command token of
            Just getFact -> do
                sourceSpan <- mkSpan (tokenId token)
                restFacts <- loop remainingTokens
                pure (getFact sourceSpan : restFacts)
            Nothing ->
                case remainingTokens of
                    (valueToken : restAfterValue) ->
                        case factFromFlagValuePair command token valueToken of
                            Just getFact -> do
                                sourceSpan <- mkSpan (tokenId token)
                                restFacts <- loop restAfterValue
                                pure (getFact sourceSpan : restFacts)
                            Nothing -> loop remainingTokens
                    [] -> pure []

    tokenId (SA.OuterToken tokenId' _) = tokenId'

{- | detect --flag=$VAR within a single token
returns a (Span -> Fact) thunk since the caller owns the span
-}
factFromFlagArgument :: Text -> SA.Token -> Maybe (Span -> Fact)
factFromFlagArgument command token =
    let text = tokenToText token
        (flag, eqRest) = T.breakOn "=" text
     in if isFlag flag && not (T.null eqRest)
            then case extractVarRef (T.drop 1 eqRest) of
                Just variableName -> Just (\sourceSpan -> CmdArg command flag variableName sourceSpan)
                Nothing -> Nothing
            else Nothing
  where
    isFlag f = "-" `T.isPrefixOf` f

-- | detect --flag $VAR across two adjacent tokens
factFromFlagValuePair :: Text -> SA.Token -> SA.Token -> Maybe (Span -> Fact)
factFromFlagValuePair command flagToken valueToken =
    let flagText = tokenToText flagToken
        valueText = tokenToText valueToken
     in case extractVarRef valueText of
            Just variableName
                | isFlag flagText -> Just (\sourceSpan -> CmdArg command flagText variableName sourceSpan)
            _ -> Nothing
  where
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
    let valueText = tokenToText valueToken
        quoted = isQuotedToken valueToken
     in case extractVarRef valueText of
            Just variable -> [ConfigAssign configPath variable quoted sourceSpan]
            Nothing -> [ConfigLit configPath (parseLiteral valueText) sourceSpan]

-- ── quoting detection ────────────────────────────────────────────

-- | determine if a token is quoted or unquoted (for config value semantics)
isQuotedToken :: SA.Token -> Quoted
isQuotedToken (SA.OuterToken _ inner) = case inner of
    SA.Inner_T_DoubleQuoted _ -> Quoted
    SA.Inner_T_NormalWord [SA.OuterToken _ (SA.Inner_T_DoubleQuoted _)] -> Quoted
    _ -> Unquoted

-- ── env var facts: ${var:-default}, ${var:=default}, ${var:?err} ──

-- | extract facts from a regular (non-config) shell variable assignment
envVarFacts :: Span -> Text -> SA.Token -> [Fact]
envVarFacts sourceSpan variableName valueToken =
    case extractParamExpansion valueToken of
        Just (DefaultValue _var (Just defaultValue)) ->
            defaultFacts defaultValue
        Just (AssignDefault _var (Just defaultValue)) ->
            defaultFacts defaultValue
        Just (AssignDefault _var Nothing) ->
            [DefaultIs variableName (LitString "") sourceSpan]
        Just (DefaultValue _var Nothing) ->
            [DefaultIs variableName (LitString "") sourceSpan]
        Just (ErrorIfUnset _var _) ->
            [Required variableName sourceSpan]
        Just (SimpleRef variable) ->
            [AssignFrom variableName variable sourceSpan]
        Just (UseAlternate _var _) ->
            []
        Nothing ->
            case extractLiteral valueToken of
                Just lit -> [AssignLit variableName lit sourceSpan]
                Nothing -> []
  where
    defaultFacts defaultValue =
        case defaultFromVar defaultValue of
            Just other -> [DefaultFrom variableName other sourceSpan]
            Nothing -> [DefaultIs variableName (parseLiteral defaultValue) sourceSpan]

    -- if the default value is itself a variable reference, emit DefaultFrom
    defaultFromVar defaultValue =
        case parseParamExpansion defaultValue of
            Just (SimpleRef variable) -> Just variable
            _ -> Nothing

-- ── config.* command facts ───────────────────────────────────────

-- | extract config assignment facts from a config.* command token
configFactsFromToken :: Span -> SA.Token -> [Fact]
configFactsFromToken sourceSpan token@(SA.OuterToken _ innerToken) =
    case innerToken of
        SA.Inner_T_NormalWord parts -> configFactsFromParts sourceSpan parts
        _ -> configFacts sourceSpan (tokenToText token)

-- ── token-part-level config analysis ─────────────────────────────

{- | extract config assignment facts from NormalWord token parts
splits on =, validates path, then parses the value side
-}
configFactsFromParts :: Span -> [SA.Token] -> [Fact]
configFactsFromParts sourceSpan tokenParts =
    case matchedPrefix of
        Nothing -> []
        Just pathText
            | T.null rightHandSide -> []
            | not (validConfigPath pathParts) -> []
            | otherwise -> buildConfigFacts pathParts
          where
            pathParts = T.splitOn "." pathText
  where
    combinedText = T.concat (map tokenToText tokenParts)
    (leftHandSide, rightHandSide) = T.breakOn "=" combinedText
    matchedPrefix = T.stripPrefix "config." leftHandSide

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
selectValueParser tokens _ quoted =
    case parseConfigTemplateTokens tokens of
        Just [ConfigVar variable] -> Just (CVDVar variable)
        Just templateParts -> Just (CVDTemplate templateParts)
        Nothing -> parseConfigValueDynamic (T.concat (map tokenToText tokens)) quoted

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
configValueFact configPath quoted sourceSpan = \case
    CVDVar variable -> ConfigAssign configPath variable quoted sourceSpan
    CVDLit literal -> ConfigLit configPath literal sourceSpan
    CVDTemplate templateParts -> ConfigTemplate configPath templateParts quoted sourceSpan

-- ── value token extraction ───────────────────────────────────────

{- | scan token parts for the portion after = and determine quoting
n.b. we need to find = within literal tokens, then grab the next token
-}
findValueTokens :: [SA.Token] -> ([SA.Token], Quoted)
findValueTokens parts = loop parts False
  where
    loop [] _ = ([], Unquoted)
    loop (token@(SA.OuterToken _ innerToken) : remainingTokens) seenEquals = case innerToken of
        SA.Inner_T_Literal content
            | not seenEquals && "=" `T.isInfixOf` (T.pack content) ->
                loop remainingTokens True
        SA.Inner_T_DoubleQuoted _
            | seenEquals ->
                ([token], Quoted)
        _
            | seenEquals ->
                ([token], Unquoted)
        _ ->
            loop remainingTokens seenEquals

-- ── dynamic text-level parser ────────────────────────────────────

-- | parse a config value from raw text (fallback when token parser fails)
parseConfigValueDynamic :: Text -> Quoted -> Maybe ConfigValueDynamic
parseConfigValueDynamic rawText _quoted
    | T.null strippedText = Nothing
    | otherwise =
        case parseConfigTemplate strippedText of
            Just [ConfigVar variable] -> Just (CVDVar variable)
            Just templateParts -> Just (CVDTemplate templateParts)
            Nothing -> Just (CVDLit (parseLiteral strippedText))
  where
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
    innerParts = \case
        SA.Inner_T_Literal content -> [ConfigText (T.pack content)]
        SA.Inner_T_SingleQuoted content -> [ConfigText (T.pack content)]
        SA.Inner_T_Glob content -> [ConfigText (T.pack content)]
        SA.Inner_T_NormalWord subParts -> concatMap tokenParts subParts
        SA.Inner_T_DoubleQuoted subParts -> concatMap tokenParts subParts
        SA.Inner_T_DollarBraced _ body ->
            expansionPart ("${" <> tokenToText body <> "}")
        _ -> []

    -- ── ${...} → ConfigVar / ConfigVarDefault / ConfigVarRequired ──
    expansionPart text = case parseParamExpansion text of
        Just (SimpleRef variable) -> [ConfigVar variable]
        Just (DefaultValue variable defaultValue) -> [ConfigVarDefault variable (maybe "" id defaultValue)]
        Just (AssignDefault variable defaultValue) -> [ConfigVarDefault variable (maybe "" id defaultValue)]
        Just (ErrorIfUnset variable _) -> [ConfigVarRequired variable]
        Just (UseAlternate variable alternate) -> [ConfigVarAlternate variable (maybe "" id alternate)]
        Nothing -> [ConfigText text]

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
    isVarPart (ConfigVar _) = True
    isVarPart _ = False

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
         in if "}" `T.isPrefixOf` textAfterName
                then case parseParamExpansion ("${" <> name <> "}") of
                    Just (SimpleRef variable) -> ConfigVar variable : parseParts (T.drop 1 textAfterName)
                    Just (DefaultValue variable defaultValue) -> ConfigVarDefault variable (maybe "" id defaultValue) : parseParts (T.drop 1 textAfterName)
                    Just (AssignDefault variable defaultValue) -> ConfigVarDefault variable (maybe "" id defaultValue) : parseParts (T.drop 1 textAfterName)
                    Just (ErrorIfUnset variable _) -> ConfigVarRequired variable : parseParts (T.drop 1 textAfterName)
                    Just (UseAlternate variable alternate) -> ConfigVarAlternate variable (maybe "" id alternate) : parseParts (T.drop 1 textAfterName)
                    Nothing -> splitText text
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
configFacts sourceSpan text =
    let dynamicFallback =
            let (leftHandSide, rightHandSide0) = T.breakOn "=" text
             in case (T.stripPrefix "config." leftHandSide, T.stripPrefix "=" rightHandSide0) of
                    (Just pathText, Just rightHandSide)
                        | "$" `T.isInfixOf` rightHandSide
                        , let pathParts = T.splitOn "." pathText
                        , validConfigPath pathParts
                        , Just parsed <- parseConfigValueDynamic rightHandSide Unquoted ->
                            [configValueFact pathParts Unquoted sourceSpan parsed]
                    _ -> []
     in case dynamicFallback of
            facts@(_ : _) -> facts
            [] -> case parseConfigAssignment text of
                Just ConfigAssignment{..} ->
                    case configValue of
                        Left variable -> [ConfigAssign configPath variable configQuoted sourceSpan]
                        Right literal -> [ConfigLit configPath literal sourceSpan]
                Nothing -> []

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
innerToText = \case
    SA.Inner_T_Literal content -> T.pack content
    SA.Inner_T_SingleQuoted content -> T.pack content
    SA.Inner_T_Glob content -> T.pack content
    SA.Inner_T_NormalWord parts -> T.concat (map tokenToText parts)
    SA.Inner_T_DoubleQuoted parts -> T.concat (map tokenToText parts)
    SA.Inner_T_DollarBraced _ token -> "${" <> tokenToText token <> "}"
    SA.Inner_T_DollarSingleQuoted content -> T.pack content
    SA.Inner_T_BraceExpansion parts -> T.concat (map tokenToText parts)
    _ -> ""

-- ── span construction ────────────────────────────────────────────

-- | look up a ShellCheck node's position in the position map and produce a Span
mkSpan :: SA.Id -> Reader (Map SA.Id (Position, Position)) Span
mkSpan shellCheckId = do
    posMap <- ask
    case Map.lookup shellCheckId posMap of
        Just (start, end) ->
            pure $
                Span
                    (Loc (fromIntegral $ posLine start) (fromIntegral $ posColumn start))
                    (Loc (fromIntegral $ posLine end) (fromIntegral $ posColumn end))
                    (Just (posFile start))
        Nothing ->
            pure $ Span (Loc 0 0) (Loc 0 0) Nothing
