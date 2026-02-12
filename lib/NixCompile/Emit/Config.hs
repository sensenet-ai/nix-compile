{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : NixCompile.Emit.Config
-- Description : Generate emit-config bash function
--
-- The key innovation of nix-compile: generating bash functions that output
-- structured config (JSON/YAML/TOML) based on config.* assignments.
--
-- Instead of heredoc templating:
-- @
-- cat << EOF > config.json
-- {
--   "server": {
--     "port": ${PORT},
--     "host": "${HOST}"
--   }
-- }
-- EOF
-- @
--
-- You write:
-- @
-- config.server.port=$PORT
-- config.server.host="$HOST"
-- emit-config json > config.json
-- @
--
-- The emit-config function is generated at build time with the correct
-- structure based on static analysis. Type safety is enforced: unquoted
-- values become JSON numbers/booleans, quoted become strings.
module NixCompile.Emit.Config
  ( -- * Generation
    emitConfigFunction,
    emitConfigJson,
    emitConfigYaml,
    emitConfigToml,

    -- * Schema helpers
    ConfigTree (..),
    ConfigTreeError (..),
    buildConfigTree,
    buildConfigTreeSafe,
    detectCollisions,
    
    -- * Validation
    isValidConfigKey,
    validateConfigKeys,
  )
where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import NixCompile.Pretty
import NixCompile.Types

-- | Check if a config key is valid for all output formats (JSON/YAML/TOML)
-- Valid keys match: ^[A-Za-z_][A-Za-z0-9_-]*$
-- This is the intersection of:
--   - JSON: any string (but we want to avoid escaping)
--   - YAML: safe unquoted keys
--   - TOML: bare keys (A-Za-z0-9_-)
isValidConfigKey :: Text -> Bool
isValidConfigKey t
  | T.null t = False
  | otherwise = validFirst (T.head t) && T.all validRest (T.tail t)
  where
    validFirst c = c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
    validRest c = validFirst c || (c >= '0' && c <= '9') || c == '-'

-- | Validate all config keys in a schema, returning invalid paths
validateConfigKeys :: Map ConfigPath ConfigSpec -> [ConfigPath]
validateConfigKeys specs = 
  [ path | (path, _) <- Map.toList specs
         , not (all isValidConfigKey path)
  ]

-- | A segment of output: either a literal string or a variable reference
-- This allows us to generate bash that properly expands variables
-- while keeping literal parts safely escaped.
data OutputSegment
  = LitSegment !Text      -- ^ Literal text (will be escaped)
  | VarSegment !Text      -- ^ Variable name (will be expanded)
  | EscapedVarSegment !Text  -- ^ Variable that needs escaping (for strings)
  deriving (Eq, Show)

-- | Convert segments to a bash printf command that safely concatenates
-- literals and variable expansions.
-- 
-- Each segment becomes a separate printf argument:
-- - Literals: single-quoted and escaped
-- - Variables: double-quoted for expansion with $
--
-- Example: [LitSegment "{\"port\": ", VarSegment "PORT"]
-- becomes: printf '%s' '{"port": ' "$PORT"
segmentsToPrintf :: [OutputSegment] -> Text
segmentsToPrintf segs =
  "printf '%s'" <> T.concat (map segmentToArg segs) <> "; printf '\\n'"
  where
    segmentToArg (LitSegment t) = " " <> escapeSingleQuote t
    segmentToArg (VarSegment v) = " \"$" <> v <> "\""  -- Note: $v for expansion
    segmentToArg (EscapedVarSegment v) = " \"$(__nix_compile_escape_json \"$" <> v <> "\")\""

-- | Escape text for use in single-quoted bash strings
escapeSingleQuote :: Text -> Text
escapeSingleQuote t = "'" <> T.concatMap escapeChar t <> "'"
  where
    escapeChar '\'' = "'\''"  -- End quote, escaped quote, start quote
    escapeChar c = T.singleton c

-- | Minimal JSON-style escaping for double-quoted strings.
-- Used for emitting literal config values safely.
jsonEscape :: Text -> Text
jsonEscape = T.concatMap $ \c -> case c of
  '"' -> "\\\""
  '\\' -> "\\\\"
  '\n' -> "\\n"
  '\r' -> "\\r"
  '\t' -> "\\t"
  _ -> T.singleton c

-- | Render a literal as JSON segments
renderJsonLit :: Literal -> [OutputSegment]
renderJsonLit = \case
  LitInt n -> [LitSegment (T.pack (show n))]
  LitBool True -> [LitSegment "true"]
  LitBool False -> [LitSegment "false"]
  LitString s -> [LitSegment ("\"" <> jsonEscape s <> "\"")]
  LitPath sp -> [LitSegment ("\"" <> jsonEscape (unStorePath sp) <> "\"")]

-- | Render a literal as YAML segments
renderYamlLit :: Literal -> [OutputSegment]
renderYamlLit = \case
  LitInt n -> [LitSegment (T.pack (show n))]
  LitBool True -> [LitSegment "true"]
  LitBool False -> [LitSegment "false"]
  LitString s -> [LitSegment ("\"" <> jsonEscape s <> "\"")]
  LitPath sp -> [LitSegment ("\"" <> jsonEscape (unStorePath sp) <> "\"")]

-- | Render a literal as TOML segments
renderTomlLit :: Literal -> [OutputSegment]
renderTomlLit = \case
  LitInt n -> [LitSegment (T.pack (show n))]
  LitBool True -> [LitSegment "true"]
  LitBool False -> [LitSegment "false"]
  LitString s -> [LitSegment ("\"" <> jsonEscape s <> "\"")]
  LitPath sp -> [LitSegment ("\"" <> jsonEscape (unStorePath sp) <> "\"")]

-- | A tree representation of config structure
-- config.server.port -> ConfigLeaf "server" (ConfigLeaf "port" (ConfigValue ...))
data ConfigTree
  = ConfigBranch !(Map Text ConfigTree)
  | ConfigLeaf !ConfigSpec
  deriving (Eq, Show)

-- | Config tree building error
data ConfigTreeError
  = PathCollision !ConfigPath !ConfigPath  -- Two paths conflict (one is prefix of other)
  deriving (Eq, Show)

-- | Build a config tree from flat config specs, detecting collisions
-- Returns Left if there are path collisions (e.g., config.a and config.a.b)
buildConfigTreeSafe :: Map ConfigPath ConfigSpec -> Either ConfigTreeError ConfigTree
buildConfigTreeSafe specs = 
  let sorted = Map.toList specs
      collisions = detectCollisions (map fst sorted)
   in case collisions of
        Just (p1, p2) -> Left (PathCollision p1 p2)
        Nothing -> Right (buildConfigTree specs)

-- | Detect if any path is a prefix of another
detectCollisions :: [ConfigPath] -> Maybe (ConfigPath, ConfigPath)
detectCollisions paths = go paths
  where
    go [] = Nothing
    go (p:ps) = case filter (isPrefix p) ps of
      (q:_) -> Just (p, q)
      [] -> case filter (`isPrefix` p) ps of
        (q:_) -> Just (q, p)
        [] -> go ps
    
    isPrefix [] _ = True
    isPrefix _ [] = False
    isPrefix (x:xs) (y:ys) = x == y && isPrefix xs ys

-- | Build a config tree from flat config specs
-- [["server", "port"]] -> { server: { port: ... } }
-- NOTE: Use buildConfigTreeSafe to detect collisions first
buildConfigTree :: Map ConfigPath ConfigSpec -> ConfigTree
buildConfigTree specs = foldr insertPath (ConfigBranch Map.empty) (Map.toList specs)
  where
    insertPath ([], spec) _ = ConfigLeaf spec
    insertPath (k : ks, spec) (ConfigBranch m) =
      ConfigBranch $ Map.alter (Just . go ks spec) k m
    insertPath _ leaf = leaf -- collision case, shouldn't happen if validated

    go [] spec Nothing = ConfigLeaf spec
    go [] spec (Just _) = ConfigLeaf spec -- overwrite (collision)
    go (k : ks) spec Nothing =
      ConfigBranch $ Map.singleton k (go ks spec Nothing)
    go (k : ks) spec (Just (ConfigBranch m)) =
      ConfigBranch $ Map.alter (Just . go ks spec) k m
    go _ _spec (Just leaf) = leaf -- collision: can't descend into leaf

-- | Generate the emit-config bash function
-- This function will be injected into the script at build time
-- NOTE: Does NOT use heredocs (that would violate our own policy)
emitConfigFunction :: Schema -> Doc AnsiStyle
emitConfigFunction schema =
  vsep
    [ "# Generated by nix-compile - do not edit"
    , "emit-config() {"
    , indent 2 $ vsep
        [ "__nix_compile_escape_json() {"
        , indent 2 $ vsep
            [ "local s=\"$1\""
            , "s=${s//\\\\/\\\\\\\\}"      -- Replace \ with \\
            , "s=${s//\\\"/\\\\\\\"}"      -- Replace " with \" (backslash + quote)
            , "s=${s//$'\\n'/\\\\n}"
            , "s=${s//$'\\r'/\\\\r}"
            , "s=${s//$'\\t'/\\\\t}"
            , "printf '%s' \"$s\""
            ]
        , "}"
        , "local format=\"${1:-json}\""
        , "case \"$format\" in"
        , indent 2 $ vsep
            [ "json)"
            , indent 2 (pretty (emitConfigJson schema))
            , ";;"
            , "yaml)"
            , indent 2 (pretty (emitConfigYaml schema))
            , ";;"
            , "toml)"
            , indent 2 (pretty (emitConfigToml schema))
            , ";;"
            , "*)"
            , indent 2 $ vsep
                [ "echo \"Unknown format: $format\" >&2"
                , "return 1"
                ]
            , ";;"
            ]
        , "esac"
        ]
    , "}"
    ]

-- | Generate JSON output command using printf with proper variable expansion
emitConfigJson :: Schema -> Text
emitConfigJson schema =
  let tree = buildConfigTree (schemaConfig schema)
  in segmentsToPrintf (renderJsonTree 0 tree)

-- | NixCompile config tree as JSON, returning segments
renderJsonTree :: Int -> ConfigTree -> [OutputSegment]
renderJsonTree level = \case
  ConfigBranch m | Map.null m -> [LitSegment "{}"]
  ConfigBranch m ->
    let entries = Map.toList m
        rendered = map (renderEntry level) entries
        indentStr = T.replicate level "  "
        nextIndent = T.replicate (level + 1) "  "
        prefix = [LitSegment "{\n", LitSegment nextIndent]
        suffix = [LitSegment "\n", LitSegment indentStr, LitSegment "}"]
        joinSegments [] = []
        joinSegments [x] = x
        joinSegments (x:y:rest) = x ++ [LitSegment ",\n", LitSegment nextIndent] ++ y ++ joinSegments rest
     in prefix ++ joinSegments rendered ++ suffix
  ConfigLeaf spec -> renderJsonValue spec
  where
    renderEntry ind (key, subtree) =
      -- Escape the key for JSON safety (defensive - keys should be validated)
      [LitSegment ("\"" <> jsonEscapeKey key <> "\": ")] ++ renderJsonTree (ind + 1) subtree

-- | Escape a key for use in JSON (handles special characters)
jsonEscapeKey :: Text -> Text
jsonEscapeKey = T.concatMap $ \c -> case c of
  '"' -> "\\\""
  '\\' -> "\\\\"
  _ -> T.singleton c

-- | NixCompile a config value as JSON, returning segments
renderJsonValue :: ConfigSpec -> [OutputSegment]
renderJsonValue ConfigSpec {..} =
  case (cfgFrom, cfgLit) of
    (_, Just lit) ->
      renderJsonLit lit
    (Just var, _) ->
      let forceString = cfgQuoted == Just Quoted
          asString = forceString || case cfgType of
            TString -> True
            TPath -> True
            TVar _ -> True
            _ -> False
       in if asString
             -- String values need surrounding quotes in JSON
             then [LitSegment "\"", EscapedVarSegment var, LitSegment "\""]
             else [VarSegment var]
    _ ->
      [LitSegment "\"\""]  -- Empty string for missing values

-- | Generate YAML output command using printf with proper variable expansion
emitConfigYaml :: Schema -> Text
emitConfigYaml schema =
  let tree = buildConfigTree (schemaConfig schema)
  in segmentsToPrintf (renderYamlTree 0 tree)

-- | NixCompile config tree as YAML, returning segments
renderYamlTree :: Int -> ConfigTree -> [OutputSegment]
renderYamlTree level = \case
  ConfigBranch m | Map.null m -> [LitSegment "{}"]
  ConfigBranch m ->
    let entries = sortOn fst (Map.toList m)
        rendered = map (renderYamlEntry level) entries
     in joinSegments rendered
  ConfigLeaf spec -> renderYamlValue spec
  where
    joinSegments [] = []
    joinSegments [x] = x
    joinSegments (x:y:rest) = x ++ [LitSegment "\n"] ++ y ++ joinSegments rest
    
    renderYamlEntry ind (key, subtree) =
      let indentStr = T.replicate ind "  "
       in case subtree of
            ConfigBranch _ ->
              -- Newline after key, then nested content at next indent
              [LitSegment (indentStr <> key <> ":\n")] ++ renderYamlTree (ind + 1) subtree
            ConfigLeaf spec ->
              [LitSegment (indentStr <> key <> ": ")] ++ renderYamlValue spec

-- | NixCompile a config value as YAML, returning segments
renderYamlValue :: ConfigSpec -> [OutputSegment]
renderYamlValue ConfigSpec {..} =
  case (cfgFrom, cfgLit) of
    (_, Just lit) ->
      renderYamlLit lit
    (Just var, _) ->
      let forceString = cfgQuoted == Just Quoted
          asString = forceString || case cfgType of
            TString -> True
            TPath -> True
            TVar _ -> True
            _ -> False
       in if asString
             -- YAML strings should be quoted for safety (may contain special chars)
             then [LitSegment "\"", EscapedVarSegment var, LitSegment "\""]
             else [VarSegment var]
    _ ->
      [LitSegment "\"\""]  -- Empty string for missing values

-- | Generate TOML output command using printf with proper variable expansion
emitConfigToml :: Schema -> Text
emitConfigToml schema =
  let tree = buildConfigTree (schemaConfig schema)
  in segmentsToPrintf (renderTomlTree [] tree)

-- | NixCompile config tree as TOML, returning segments
renderTomlTree :: [Text] -> ConfigTree -> [OutputSegment]
renderTomlTree path = \case
  ConfigBranch m | Map.null m -> [LitSegment ""]
  ConfigBranch m ->
    let -- Separate leaves (direct values) from branches (sections)
        (leaves, branches) = Map.partitionWithKey isLeaf m
        isLeaf _ (ConfigLeaf _) = True
        isLeaf _ _ = False
        -- NixCompile section header if we have leaves and a path
        sectionHeader =
          if not (null path) && not (Map.null leaves)
            then [LitSegment ("[" <> T.intercalate "." (map tomlKey path) <> "]\n")]
            else []
        -- NixCompile leaf values
        leafLines =
          map renderTomlLeaf (sortOn fst (Map.toList leaves))
        -- NixCompile subsections
        branchLines =
          map (renderTomlBranch path) (sortOn fst (Map.toList branches))
        allLines = sectionHeader ++ concat leafLines ++ concat branchLines
     in allLines
  ConfigLeaf _ -> [LitSegment ""] -- shouldn't be called at top level
  where
    renderTomlLeaf (key, ConfigLeaf spec) =
      [LitSegment (tomlKey key <> " = ")] ++ renderTomlValue spec ++ [LitSegment "\n"]
    renderTomlLeaf _ = [LitSegment ""]

    renderTomlBranch parentPath (key, subtree) =
      renderTomlTree (parentPath ++ [key]) subtree

-- | Format a key for TOML - quote if not a valid bare key
tomlKey :: Text -> Text
tomlKey k
  | isValidConfigKey k = k
  | otherwise = "\"" <> T.concatMap escToml k <> "\""
  where
    escToml '"' = "\\\""
    escToml '\\' = "\\\\"
    escToml c = T.singleton c

-- | NixCompile a config value as TOML, returning segments
renderTomlValue :: ConfigSpec -> [OutputSegment]
renderTomlValue ConfigSpec {..} =
  case (cfgFrom, cfgLit) of
    (_, Just lit) ->
      renderTomlLit lit
    (Just var, _) ->
      let forceString = cfgQuoted == Just Quoted
          asString = forceString || case cfgType of
            TString -> True
            TPath -> True
            TVar _ -> True
            _ -> False
       in if asString
             -- TOML strings need surrounding quotes
             then [LitSegment "\"", EscapedVarSegment var, LitSegment "\""]
             else [VarSegment var]
    _ ->
      [LitSegment "\"\""]  -- Empty string for missing values
