{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                      // nix // parsing
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Back into the living room, and amazed, somehow, that he hadn't moved;
--    expecting him to jump up, hello, waving a few centimeters of trick wire.
--    She removed his shoes, looked inside, felt the lining. Nothing. 'Don't
--    do this to me.' And back into the bedroom. The narrow closet. Brushing
--    aside a clatter of cheap white plastic hangers, a limp shroud of
--    drycleaner's plastic. Dragging the stained bedslab over and standing on
--    it, her heels sinking into the foam, to slide her hands the length of a
--    pressboard shelf, and find, in the far corner, a hard little fold of
--    paper, rectangular and blue."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                // nix // parse // extract
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Parse (
    -- * Parsing
    parseNixFile,
    parseNixExpr,
    parseNix,

    -- * Extraction
    extractBashScripts,
    BashScript (..),
    Interpolation (..),

    -- * Low-level
    findShellScriptCalls,
    ShellScriptCall (..),
)
where

import Control.Exception (IOException, try)
import Data.Fix (Fix (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import Nix.Parser (parseNixFileLoc, parseNixTextLoc)
import Nix.Utils (Path (..))
import NixCompile.Nix.Utils (toSpan, varNameText)
import NixCompile.Types (Span (..))

-- | A bash script extracted from a Nix file
data BashScript = BashScript
    { bsName :: !Text
    , bsContent :: !Text
    , bsInterpolations :: ![Interpolation]
    , bsSpan :: !Span
    }
    deriving (Eq, Show)

-- | An interpolation site in a bash string
data Interpolation = Interpolation
    { intExpr :: !Text
    , intIsStorePath :: !Bool
    , intSpan :: !Span
    }
    deriving (Eq, Show)

-- | A writeShellScript* call found in Nix
data ShellScriptCall = ShellScriptCall
    { sscFunction :: !Text
    , sscName :: !Text
    , sscBody :: !NExprLoc
    , sscSpan :: !Span
    }
    deriving (Show)

-- | Parse a Nix file and return the annotated AST
parseNixFile :: FilePath -> IO (Either Text NExprLoc)
parseNixFile path = do
    result <- try (parseNixFileLoc (Path path))
    pure $ case result of
        Left (e :: IOException) -> Left (T.pack $ show e)
        Right (Left doc) -> Left (T.pack $ show doc)
        Right (Right expr) -> Right expr

-- | Parse a Nix expression from text
parseNixExpr :: Text -> Either Text NExprLoc
parseNixExpr src = case parseNixTextLoc src of
    Left doc -> Left (T.pack $ show doc)
    Right expr -> Right expr

-- | Parse a Nix expression from text with filepath for error context
parseNix :: FilePath -> Text -> Either Text NExprLoc
parseNix _path src = parseNixExpr src

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
            { bsName = sscName ssc
            , bsContent = content
            , bsInterpolations = interps
            , bsSpan = span'
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

-- | Generate a placeholder string for an interpolation site
injectPlaceholders :: Bool -> Int -> Text
injectPlaceholders isStore n
    | isStore = "/nix/store/__nix_compile_interp_" <> T.pack (show n) <> "__"
    | otherwise = "@__nix_compile_interp_" <> T.pack (show n) <> "__@"

-- | Extract interpolation data from an antiquoted expression
extractInterpolations :: Int -> NExprLoc -> (Text, Interpolation)
extractInterpolations n expr =
    let isStore = isStorePathExpr expr
     in ( injectPlaceholders isStore n
        , Interpolation
            { intExpr = prettyExpr expr
            , intIsStorePath = isStore
            , intSpan = exprSpan expr
            }
        )

{- | Extract text and interpolations from string parts.

We replace interpolations with stable placeholders so downstream bash analysis can:
  * treat "known store-path" interpolations as store paths (by prefixing /nix/store/)
  * treat "unknown" interpolations as explicit placeholders (by prefixing @...@)
-}
extractPartsWithInterps :: [Antiquoted Text NExprLoc] -> (Text, [Interpolation])
extractPartsWithInterps = go 0
  where
    go _ [] = ("", [])
    go n (part : rest) =
        let (restText, restInterps) = go n' rest
         in case part of
                Plain txt -> (txt <> restText, restInterps)
                EscapedNewline -> ("\n" <> restText, restInterps)
                Antiquoted expr ->
                    let (placeholder, interp) = extractInterpolations n expr
                     in (placeholder <> restText, interp : restInterps)
      where
        n' = case part of
            Antiquoted _ -> n + 1
            _ -> n

{- | Check if an expression looks like a store path access
e.g., ${pkgs.curl} or ${lib.getExe pkgs.ripgrep}
-}
isStorePathExpr :: NExprLoc -> Bool
isStorePathExpr (Fix (Compose (AnnUnit _ expr))) = case expr of
    NSelect _ base (k :| _) -> isPackageBase base || keyTextIs "pkgs" k || keyTextIs "lib" k
    NApp func arg -> isStorePathExpr func || isStorePathExpr arg
    NSym name -> isLikelyPackageVar (varNameText name)
    NLiteralPath p -> "/nix/store" `T.isPrefixOf` T.pack (show p)
    _ -> False
  where
    isPackageBase (Fix (Compose (AnnUnit _ (NSym n)))) = varNameText n `elem` ["pkgs", "lib"]
    isPackageBase (Fix (Compose (AnnUnit _ (NSelect _ b _)))) = isPackageBase b
    isPackageBase _ = False

    keyTextIs name (StaticKey k) = varNameText k == name
    keyTextIs _ (DynamicKey _) = False

    isLikelyPackageVar name =
        T.isPrefixOf "pkgs" name
            || T.isPrefixOf "lib" name
            || T.isSuffixOf "Pkg" name
            || T.isSuffixOf "Package" name

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

-- | Get the source span of an expression
exprSpan :: NExprLoc -> Span
exprSpan (Fix (Compose (AnnUnit srcSpan _))) = toSpan srcSpan Nothing

-- | Find all writeShellScript* calls in an expression
findShellScriptCalls :: NExprLoc -> [ShellScriptCall]
findShellScriptCalls = walkExpression

-- | Walk the Nix AST, collecting shell script calls
walkExpression :: NExprLoc -> [ShellScriptCall]
walkExpression expr =
    case extractScriptCall expr of
        Just call -> [call]
        Nothing -> walkSubExprs expr

-- | Walk sub-expressions of a node
walkSubExprs :: NExprLoc -> [ShellScriptCall]
walkSubExprs (Fix (Compose (AnnUnit _ e))) = case e of
    NConstant _ -> []
    NStr _ -> []
    NSym _ -> []
    NList xs -> concatMap walkExpression xs
    NSet _ bindings -> concatMap walkBinding bindings
    NLiteralPath _ -> []
    NEnvPath _ -> []
    NLet bindings body -> concatMap walkBinding bindings ++ walkExpression body
    NIf cond t f -> walkExpression cond ++ walkExpression t ++ walkExpression f
    NWith scope body -> walkExpression scope ++ walkExpression body
    NAssert cond body -> walkExpression cond ++ walkExpression body
    NAbs _ body -> walkExpression body
    NApp f x -> walkExpression f ++ walkExpression x
    NSelect alt base _ -> walkExpression base ++ maybe [] walkExpression alt
    NHasAttr base _ -> walkExpression base
    NUnary _ x -> walkExpression x
    NBinary _ x y -> walkExpression x ++ walkExpression y
    NSynHole _ -> []

-- | Process a binding node
walkBinding :: Binding NExprLoc -> [ShellScriptCall]
walkBinding = \case
    NamedVar _ expr _ -> walkExpression expr
    Inherit _ _ _ -> []

-- | Check if a function name is a writeShellScript variant
isShellScriptFunction :: Text -> Bool
isShellScriptFunction name =
    name == "writeShellScript"
        || name == "writeShellScriptBin"
        || name == "writeScript"
        || name == "writeScriptBin"
        || name == "writeShellApplication"

-- | Unwrap nested applications to find the function name and all arguments
unwrapApp :: NExprLoc -> [NExprLoc] -> Maybe (Text, [NExprLoc])
unwrapApp (Fix (Compose (AnnUnit _ e))) args = case e of
    NApp func arg -> unwrapApp func (arg : args)
    NSym name -> Just (varNameText name, args)
    NSelect _ _ (attr :| rest) ->
        Just (keyText (last (attr : rest)), args)
    _ -> Nothing

-- | Extract key name text from a key node
keyText :: NKeyName NExprLoc -> Text
keyText (StaticKey k) = varNameText k
keyText (DynamicKey _) = ""

-- | Extract name and text from a record: { name = "foo"; text = ''body''; }
extractFromRecord :: NExprLoc -> Maybe (Text, NExprLoc)
extractFromRecord (Fix (Compose (AnnUnit _ e))) = case e of
    NSet _ bindings ->
        let nameVal = findBinding "name" bindings >>= extractStringLit
            textVal = findBinding "text" bindings
         in case (nameVal, textVal) of
                (Just n, Just t) -> Just (n, t)
                _ -> Nothing
    _ -> Nothing

-- | Find a binding by name in a binding list
findBinding :: Text -> [Binding NExprLoc] -> Maybe NExprLoc
findBinding name = foldr check Nothing
  where
    check (NamedVar (StaticKey k :| []) expr _) acc
        | varNameText k == name = Just expr
        | otherwise = acc
    check _ acc = acc

-- | Extract a string literal from an expression
extractStringLit :: NExprLoc -> Maybe Text
extractStringLit (Fix (Compose (AnnUnit _ e))) = case e of
    NStr (DoubleQuoted [Plain t]) -> Just t
    NStr (Indented _ [Plain t]) -> Just t
    _ -> Nothing

-- | Extract a ShellScriptCall from an expression node if it matches
extractScriptCall :: NExprLoc -> Maybe ShellScriptCall
extractScriptCall expr@(Fix (Compose (AnnUnit srcSpan e))) = case e of
    NApp _ _ -> processApp (unwrapApp expr [])
    _ -> Nothing
  where
    processApp (Just (name, args))
        | not (isShellScriptFunction name) = Nothing
        | otherwise = case args of
            [nameArg, bodyArg]
                | name `elem` positionalFuncs ->
                    fmap
                        (\n -> ShellScriptCall name n bodyArg (toSpan srcSpan Nothing))
                        (extractStringLit nameArg)
            [recordArg] | name == "writeShellApplication" ->
                case extractFromRecord recordArg of
                    Just (n, body) ->
                        Just
                            ShellScriptCall
                                { sscFunction = name
                                , sscName = n
                                , sscBody = body
                                , sscSpan = toSpan srcSpan Nothing
                                }
                    Nothing -> Nothing
            _ -> Nothing
    processApp Nothing = Nothing

    positionalFuncs =
        [ "writeShellScript"
        , "writeShellScriptBin"
        , "writeScript"
        , "writeScriptBin"
        ]
