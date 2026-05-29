{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                       // nix // layout
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "A wing of night swept Barcelona's sky."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // layout // validation
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Layout (
    -- * Violations
    LayoutViolation (..),
    LayoutCode (..),

    -- * Validation
    findLayoutViolations,
    findLayoutViolationsInDir,

    -- * Queries
    expectedModuleClass,
    isIndexFile,
    isMainFile,
)
where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.List (isPrefixOf, isSuffixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Nix.Expr.Types hiding (Binding)
import Nix.Expr.Types qualified as Nix
import Nix.Expr.Types.Annotated
import Nix.Parser (parseNixFileLoc)
import Nix.Utils qualified as NixPath
import NixCompile.Types (Loc (..), Span (..))
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (normalise, splitPath, takeFileName, (</>))

-- ═════════════════════════════════════════════════════════════════════════════
-- types
-- ═════════════════════════════════════════════════════════════════════════════

data LayoutCode
    = L001
    | L002
    | L003
    | L004
    | L005
    deriving (Show, Eq)

data LayoutViolation = LayoutViolation
    { lvCode :: !LayoutCode
    , lvPath :: !FilePath
    , lvMessage :: !Text
    , lvSpan :: !(Maybe Span)
    }
    deriving (Show, Eq)

-- ═════════════════════════════════════════════════════════════════════════════
-- file classification
-- ═════════════════════════════════════════════════════════════════════════════

isIndexFile :: FilePath -> Bool
isIndexFile path = takeFileName path == "_index.nix"

isMainFile :: FilePath -> Bool
isMainFile path = takeFileName path == "_main.nix"

expectedModuleClass :: FilePath -> Maybe Text
expectedModuleClass path = case getModuleKind (normalise path) of
    Just "flake" -> Just "flake"
    Just "nixos" -> Just "nixos"
    Just "home" -> Just "home"
    _ -> Nothing

getModuleKind :: FilePath -> Maybe String
getModuleKind path =
    let
        normPath = normalise path
        parts = splitPath normPath
        findKind [] = Nothing
        findKind [_] = Nothing
        findKind (x : y : rest)
            | "modules" `isPrefixOf` x || "modules/" `isSuffixOf` x =
                Just (dropTrailingSlash y)
            | otherwise = findKind (y : rest)
        dropTrailingSlash s = if "/" `isSuffixOf` s then init s else s
     in
        findKind parts

-- ═════════════════════════════════════════════════════════════════════════════
-- validation
-- ═════════════════════════════════════════════════════════════════════════════

findLayoutViolations :: FilePath -> NExprLoc -> [LayoutViolation]
findLayoutViolations path expr =
    concat
        [ checkIndexFile path
        , checkMainFile path
        , checkModuleClass path expr
        ]

checkIndexFile :: FilePath -> [LayoutViolation]
checkIndexFile path
    | isIndexFile path =
        [ LayoutViolation
            { lvCode = L001
            , lvPath = path
            , lvMessage = "_index.nix files are banned; module graph is derived from directory structure"
            , lvSpan = Nothing
            }
        ]
    | otherwise = []

checkMainFile :: FilePath -> [LayoutViolation]
checkMainFile path
    | isMainFile path =
        [ LayoutViolation
            { lvCode = L002
            , lvPath = path
            , lvMessage = "_main.nix files are banned; use explicit imports in flake.nix"
            , lvSpan = Nothing
            }
        ]
    | otherwise = []

checkModuleClass :: FilePath -> NExprLoc -> [LayoutViolation]
checkModuleClass path expr = case expectedModuleClass path of
    Nothing -> []
    Just expectedClass ->
        case findClassAttr expr of
            Nothing ->
                [ LayoutViolation
                    { lvCode = L003
                    , lvPath = path
                    , lvMessage = "Module missing _class attribute; expected _class = \"" <> expectedClass <> "\""
                    , lvSpan = Nothing
                    }
                ]
            Just (actualClass, sp)
                | actualClass /= expectedClass ->
                    [ LayoutViolation
                        { lvCode = L004
                        , lvPath = path
                        , lvMessage = "Wrong _class: got \"" <> actualClass <> "\", expected \"" <> expectedClass <> "\""
                        , lvSpan = Just sp
                        }
                    ]
                | otherwise -> []

findClassAttr :: NExprLoc -> Maybe (Text, Span)
findClassAttr = go
  where
    go (Fix (Compose (AnnUnit _ e))) = case e of
        NSet _ bindings -> findInBindings bindings
        NAbs _ body -> go body
        NLet _ body -> go body
        NWith _ body -> go body
        _ -> Nothing

    findInBindings bindings =
        let classes = mapMaybe extractClass bindings
         in case classes of
                ((cls, sp) : _) -> Just (cls, sp)
                [] -> Nothing

    extractClass :: Nix.Binding NExprLoc -> Maybe (Text, Span)
    extractClass = \case
        Nix.NamedVar (StaticKey name :| []) valExpr _
            | varNameText name == "_class" -> extractStringValue valExpr
        _ -> Nothing

    extractStringValue :: NExprLoc -> Maybe (Text, Span)
    extractStringValue (Fix (Compose (AnnUnit srcSpan e))) = case e of
        NStr (DoubleQuoted [Plain t]) -> Just (t, toSpan srcSpan)
        NStr (Indented _ [Plain t]) -> Just (t, toSpan srcSpan)
        _ -> Nothing

    varNameText :: VarName -> Text
    varNameText = coerce

    toSpan :: SrcSpan -> Span
    toSpan srcSpan =
        let begin = getSpanBegin srcSpan
            end = getSpanEnd srcSpan
            fileFromBegin = case begin of
                NSourcePos path _ _ -> Just (coerce path)
         in Span
                { spanStart = Loc (sourceLine begin) (sourceCol begin)
                , spanEnd = Loc (sourceLine end) (sourceCol end)
                , spanFile = fileFromBegin
                }

    sourceLine (NSourcePos _ (NPos l) _) = fromIntegral (unPos l)
    sourceCol (NSourcePos _ _ (NPos c)) = fromIntegral (unPos c)

-- ═════════════════════════════════════════════════════════════════════════════
-- directory scanning
-- ═════════════════════════════════════════════════════════════════════════════

findLayoutViolationsInDir :: FilePath -> IO [LayoutViolation]
findLayoutViolationsInDir rootDir = do
    files <- findNixFiles rootDir
    violations <- forM files $ \path -> do
        result <- try (parseNixFileLoc (NixPath.Path path))
        case result of
            Left (_ :: IOException) -> pure []
            Right (Left _) -> pure []
            Right (Right expr) -> pure $ findLayoutViolations path expr
    pure $ concat violations

findNixFiles :: FilePath -> IO [FilePath]
findNixFiles dir = do
    exists <- doesDirectoryExist dir
    if not exists
        then pure []
        else do
            entries <- listDirectory dir
            paths <- forM entries $ \entry -> do
                let path = dir </> entry
                isDir <- doesDirectoryExist path
                isFile <- doesFileExist path
                if isDir
                    then findNixFiles path
                    else
                        if isFile && ".nix" `isSuffixOf` entry
                            then pure [path]
                            else pure []
            pure $ concat paths
