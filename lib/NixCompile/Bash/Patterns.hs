{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : NixCompile.Bash.Patterns
-- Description : Pattern recognition for bash constructs
--
-- Recognizes:
--   - ${VAR:-default}   parameter expansion with default
--   - ${VAR:?}          required parameter
--   - ${VAR:+alt}       alternative value
--   - config.x.y=$VAR   config assignment
--   - /nix/store/...    store paths
module NixCompile.Bash.Patterns
  ( -- * Parameter expansion
    ParamExpansion (..),
    parseParamExpansion,

    -- * Config assignment
    ConfigAssignment (..),
    parseConfigAssignment,
    parseConfigValue,
    validConfigPath,

    -- * Literals
    parseLiteral,
    isNumericLiteral,
    isBoolLiteral,
    isStorePathSafe,
    safeParseInt,
  )
where

import Control.Monad (guard)
import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)
import NixCompile.Types

-- ============================================================================
-- Parameter Expansion
-- ============================================================================

-- | Bash parameter expansion patterns
data ParamExpansion
  = -- | ${VAR:-default} or ${VAR-default}
    DefaultValue Text (Maybe Text)
  | -- | ${VAR:=default} - assign default
    AssignDefault Text (Maybe Text)
  | -- | ${VAR:?message} or ${VAR:?} - error if unset
    ErrorIfUnset Text (Maybe Text)
  | -- | ${VAR:+alt} - use alt if set
    UseAlternate Text (Maybe Text)
  | -- | $VAR or ${VAR} - simple reference
    SimpleRef Text
  deriving (Eq, Show)

-- | Parse a parameter expansion from text
-- Handles: $VAR, ${VAR}, ${VAR:-default}, ${VAR:?}, etc.
-- Rejects special parameters like $1, $?, $@, etc.
parseParamExpansion :: Text -> Maybe ParamExpansion
parseParamExpansion t
  | "${" `T.isPrefixOf` t && "}" `T.isSuffixOf` t =
      parseExpansionBody (T.dropEnd 1 (T.drop 2 t))
  | "$" `T.isPrefixOf` t =
      let varName = T.drop 1 t
       in if isValidVarName varName
            then Just (SimpleRef varName)
            else Nothing
  | otherwise = Nothing

-- | Check if a variable name is valid (matches SEC-1: ^[A-Za-z_][A-Za-z0-9_]*$)
-- Rejects special parameters like 1, 2, ?, #, @, *, etc.
isValidVarName :: Text -> Bool
isValidVarName t
  | T.null t = False
  | otherwise =
      case T.uncons t of
        Just (c, rest) ->
          (isAlpha c || c == '_') && T.all isVarChar rest
        Nothing -> False
  where
    isVarChar c = isAlphaNum c || c == '_'



parseExpansionBody :: Text -> Maybe ParamExpansion
parseExpansionBody body =
  -- Support:
  --   ${VAR} ${VAR:-default} ${VAR-default}
  --   ${VAR:=default} ${VAR=default}
  --   ${VAR:?} ${VAR?}
  case T.breakOn ":" body of
    -- Operators with ":" (bash semantics differ for unset vs null)
    (var, rest) | ":" `T.isPrefixOf` rest ->
      parseOpWithColon var (T.drop 1 rest)
    -- Operators without ":" (only test for unset)
    _ ->
      parseOpWithoutColon body
  where
    parseOpWithColon var rest = do
      guard (isVarName var)
      case T.uncons rest of
        -- For default/assign operators, empty IS meaningful (empty string default)
        Just ('-', def) -> Just (DefaultValue var (Just def))
        Just ('=', def) -> Just (AssignDefault var (Just def))
        -- For error/alternate, empty means "no message"/"no alternate"
        Just ('?', msg) -> Just (ErrorIfUnset var (nonEmpty msg))
        Just ('+', alt) -> Just (UseAlternate var (nonEmpty alt))
        _ -> Just (SimpleRef var)

    parseOpWithoutColon b = do
      let (var, rest) = T.break isOpChar b
      guard (isVarName var)
      case T.uncons rest of
        Just ('-', def) -> Just (DefaultValue var (Just def))
        Just ('=', def) -> Just (AssignDefault var (Just def))
        Just ('?', msg) -> Just (ErrorIfUnset var (nonEmpty msg))
        Just ('+', alt) -> Just (UseAlternate var (nonEmpty alt))
        Nothing -> Just (SimpleRef var)
        _ -> Nothing

    nonEmpty t = if T.null t then Nothing else Just t

    isOpChar c = c == '-' || c == '=' || c == '?' || c == '+'

    isVarName t =
      not (T.null t)
        && isValidStart t
        && T.all isVarChar t

    isValidStart t = case T.uncons t of
      Just (c, _) -> isAlpha c || c == '_'
      Nothing -> False

    isVarChar c = isAlphaNum c || c == '_'

-- ============================================================================
-- Config Assignment
-- ============================================================================

-- | config.* assignment pattern
data ConfigAssignment = ConfigAssignment
  { configPath :: [Text],
    configValue :: Either Text Literal, -- Left = var reference, Right = literal
    configQuoted :: Quoted
  }
  deriving (Eq, Show)

-- | Parse config assignment in either format:
--   - config[path.to.key]=$VAR   (associative array, ShellCheck-compliant)
--   - config.x.y.z=$VAR          (legacy dot syntax)
parseConfigAssignment :: Text -> Maybe ConfigAssignment
parseConfigAssignment line =
  parseConfigArraySyntax line <|> parseConfigDotSyntax line
  where
    (<|>) Nothing b = b
    (<|>) a _ = a

-- | Parse config[path.to.key]=$VAR (associative array syntax)
parseConfigArraySyntax :: Text -> Maybe ConfigAssignment
parseConfigArraySyntax line = do
  -- Split on first =
  let (lhs, rest) = T.breakOn "=" line
  -- Check it starts with config[
  inner <- T.stripPrefix "config[" lhs
  -- Must end with ]
  guard ("]" `T.isSuffixOf` inner)
  let pathText = T.dropEnd 1 inner  -- drop the ]
  -- Must have = and something after
  guard (not (T.null rest))
  let rhs = T.drop 1 rest -- drop the =
  -- Parse the path (dots separate levels)
  let pathParts = T.splitOn "." pathText
  guard (validConfigPath pathParts)
  -- Parse the value
  (value, quoted) <- parseConfigValue rhs
  Just
    ConfigAssignment
      { configPath = pathParts,
        configValue = value,
        configQuoted = quoted
      }
-- | Parse config.x.y.z=$VAR (legacy dot syntax)
parseConfigDotSyntax :: Text -> Maybe ConfigAssignment
parseConfigDotSyntax line = do
  -- Split on first =
  let (lhs, rest) = T.breakOn "=" line
  -- Check it starts with config.
  path <- T.stripPrefix "config." lhs
  -- Must have = and something after
  guard (not (T.null rest))
  let rhs = T.drop 1 rest -- drop the =
  -- Parse the path
  let pathParts = T.splitOn "." path
  guard (validConfigPath pathParts)
  -- Parse the value
  (value, quoted) <- parseConfigValue rhs
  Just
    ConfigAssignment
      { configPath = pathParts,
        configValue = value,
        configQuoted = quoted
      }
-- | Config paths must be non-empty and contain no empty segments.
--
-- Examples (invalid):
--   config..a=...
--   config.=...
--   config[.a]=...
validConfigPath :: [Text] -> Bool
validConfigPath parts =
  not (null parts) && all (not . T.null) parts

parseConfigValue :: Text -> Maybe (Either Text Literal, Quoted)
parseConfigValue t
  -- Quoted brace variable: "${VAR}"
  | "\"${" `T.isPrefixOf` t && "}\"" `T.isSuffixOf` t =
      Just (Left (T.dropEnd 2 (T.drop 3 t)), Quoted)
  -- Quoted simple variable: "$VAR"
  | "\"$" `T.isPrefixOf` t && "\"" `T.isSuffixOf` t =
      Just (Left (T.dropEnd 1 (T.drop 2 t)), Quoted)
  -- Quoted literal string: "hello"
  | "\"" `T.isPrefixOf` t && "\"" `T.isSuffixOf` t =
      Just (Right (LitString (T.dropEnd 1 (T.drop 1 t))), Quoted)
  -- Unquoted brace variable: ${VAR}
  | "${" `T.isPrefixOf` t && "}" `T.isSuffixOf` t =
      Just (Left (T.dropEnd 1 (T.drop 2 t)), Unquoted)
  -- Unquoted simple variable: $VAR
  | "$" `T.isPrefixOf` t =
      Just (Left (T.drop 1 t), Unquoted)
  -- Unquoted literal
  | otherwise =
      Just (Right (parseLiteralValue t), Unquoted)

parseLiteralValue :: Text -> Literal
parseLiteralValue t
  | t == "true" = LitBool True
  | t == "false" = LitBool False
  | isNumericLiteral t = case safeParseInt t of
      Just n -> LitInt n
      Nothing -> LitString t
  | otherwise = LitString t

-- ============================================================================
-- Literals
-- ============================================================================

-- | Parse a literal value from text
parseLiteral :: Text -> Literal
parseLiteral t
  | t == "true" = LitBool True
  | t == "false" = LitBool False
  | isNumericLiteral t = case safeParseInt t of
      Just n -> LitInt n
      Nothing -> LitString t  -- Overflow, treat as string
  | isStorePathSafe t = LitPath (StorePath t)
  | otherwise = LitString t

-- | Check if text is a valid store path (no traversal)
isStorePathSafe :: Text -> Bool
isStorePathSafe t = "/nix/store/" `T.isPrefixOf` t
                 && not (".." `T.isInfixOf` t)
                 && not ("//" `T.isInfixOf` t)

-- | Check if text is a numeric literal
-- Must have at least one digit, optional leading minus
-- Must fit in Int64 range
isNumericLiteral :: Text -> Bool
isNumericLiteral t =
  not (T.null t)
    && T.all isDigitOrSign t
    && T.any isDigit t  -- Must have at least one digit
    && validMinus t
    && validLength t
    && fitsInt64 t
  where
    isDigitOrSign c = isDigit c || c == '-'
    -- Minus only valid at start, and only one
    validMinus s = case T.uncons s of
      Just ('-', rest) -> not (T.null rest) && not (T.any (== '-') rest)
      _ -> not (T.any (== '-') s)
    -- Quick length check before parsing (Int64 max is 19 digits)
    validLength s = T.length (T.dropWhile (== '-') s) <= 19
    -- Actually check if it fits
    fitsInt64 s = case readMaybe (T.unpack s) :: Maybe Integer of
      Nothing -> False
      Just n -> n >= -9223372036854775808 && n <= 9223372036854775807

-- | Safely parse an integer, returning Nothing on overflow
-- Returns Int64 to match spec requirements for 64-bit integer support
safeParseInt :: Text -> Maybe Int64
safeParseInt t = case readMaybe (T.unpack t) :: Maybe Integer of
  Nothing -> Nothing
  Just n | n >= fromIntegral (minBound :: Int64) && n <= fromIntegral (maxBound :: Int64) -> Just (fromIntegral n)
  _ -> Nothing

-- | Check if text is a boolean literal
isBoolLiteral :: Text -> Bool
isBoolLiteral t = t == "true" || t == "false"
