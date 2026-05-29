{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                        // nix // flake
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "The exceedingly rich were no longer even remotely human."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // flake // parsing
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Flake (
    -- * Flake types
    Flake (..),
    FlakeInput (..),
    FlakeOutputs (..),
    OutputEntry (..),

    -- * Parsing
    parseFlake,
    parseFlakeDir,

    -- * Type inference
    inferFlake,
    FlakeTypes (..),

    -- * Schema
    flakeOutputSchema,
)
where

import Control.Exception (IOException, try)
import Data.Fix (Fix (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types hiding (Binding)
import Nix.Expr.Types qualified as Nix
import Nix.Expr.Types.Annotated
import Nix.Parser (parseNixFileLoc)
import Nix.Utils qualified as Nix
import NixCompile.Nix.Infer (inferExpr)
import NixCompile.Nix.Types
import NixCompile.Nix.Utils (varNameText)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- ═════════════════════════════════════════════════════════════════════════════
-- flake types
-- ═════════════════════════════════════════════════════════════════════════════

data Flake = Flake
    { flakeDescription :: !(Maybe Text)
    , flakeInputs :: !(Map Text FlakeInput)
    , flakeOutputs :: !FlakeOutputs
    , flakePath :: !FilePath
    }
    deriving (Eq, Show)

data FlakeInput = FlakeInput
    { inputUrl :: !(Maybe Text)
    , inputFlake :: !Bool
    , inputFollows :: !(Maybe Text)
    }
    deriving (Eq, Show)

data FlakeOutputs = FlakeOutputs
    { outPackages :: !(Map Text (Map Text OutputEntry))
    , outDevShells :: !(Map Text (Map Text OutputEntry))
    , outChecks :: !(Map Text (Map Text OutputEntry))
    , outApps :: !(Map Text (Map Text OutputEntry))
    , outOverlays :: !(Map Text OutputEntry)
    , outNixosModules :: !(Map Text OutputEntry)
    , outNixosConfigurations :: !(Map Text OutputEntry)
    , outLib :: !(Maybe NExprLoc)
    , outOther :: !(Map Text NExprLoc)
    }
    deriving (Show)

instance Eq FlakeOutputs where
    a == b =
        outPackages a == outPackages b
            && outDevShells a == outDevShells b
            && outChecks a == outChecks b
            && outApps a == outApps b
            && outOverlays a == outOverlays b
            && outNixosModules a == outNixosModules b
            && outNixosConfigurations a == outNixosConfigurations b

data OutputEntry = OutputEntry
    { entryName :: !Text
    , entryExpr :: !NExprLoc
    , entryType :: !NixType
    }
    deriving (Show)

instance Eq OutputEntry where
    a == b = entryName a == entryName b && entryType a == entryType b

-- ═════════════════════════════════════════════════════════════════════════════
-- parsing
-- ═════════════════════════════════════════════════════════════════════════════

parseFlake :: FilePath -> IO (Either Text Flake)
parseFlake path = do
    result <- try (parseNixFileLoc (Nix.Path path))
    case result of
        Left (e :: IOException) -> pure $ Left (T.pack $ show e)
        Right (Left doc) -> pure $ Left (T.pack $ show doc)
        Right (Right expr) -> pure $ extractFlake path expr

parseFlakeDir :: FilePath -> IO (Either Text Flake)
parseFlakeDir dir = do
    let flakePath = dir </> "flake.nix"
    exists <- doesFileExist flakePath
    if exists
        then parseFlake flakePath
        else pure $ Left $ "No flake.nix found in " <> T.pack dir

extractFlake :: FilePath -> NExprLoc -> Either Text Flake
extractFlake path expr = do
    case unwrapExpr expr of
        NSet _ bindings -> do
            let desc = extractDescription bindings
            let inputs = extractInputs bindings
            let outputs = extractOutputs bindings
            Right $
                Flake
                    { flakeDescription = desc
                    , flakeInputs = inputs
                    , flakeOutputs = outputs
                    , flakePath = path
                    }
        _ -> Left "flake.nix must be an attribute set"

unwrapExpr :: NExprLoc -> NExprF NExprLoc
unwrapExpr (Fix (Compose (AnnUnit _ e))) = e

extractDescription :: [Nix.Binding NExprLoc] -> Maybe Text
extractDescription = foldr check Nothing
  where
    check (Nix.NamedVar (StaticKey name :| []) expr _) acc
        | varNameText name == "description" = extractStringLit expr
        | otherwise = acc
    check _ acc = acc

extractInputs :: [Nix.Binding NExprLoc] -> Map Text FlakeInput
extractInputs bindings = case findBinding "inputs" bindings of
    Just expr -> case unwrapExpr expr of
        NSet _ inputBindings -> Map.fromList $ mapMaybe parseInput inputBindings
        _ -> Map.empty
    Nothing -> Map.empty
  where
    parseInput :: Nix.Binding NExprLoc -> Maybe (Text, FlakeInput)
    parseInput (Nix.NamedVar (StaticKey name :| []) expr _) =
        Just (varNameText name, parseInputExpr expr)
    parseInput _ = Nothing

    parseInputExpr :: NExprLoc -> FlakeInput
    parseInputExpr expr = case unwrapExpr expr of
        NSet _ bs ->
            FlakeInput
                { inputUrl = findBinding "url" bs >>= extractStringLit
                , inputFlake = maybe True id (findBinding "flake" bs >>= extractBoolLit)
                , inputFollows = findBinding "follows" bs >>= extractStringLit
                }
        NStr _ ->
            FlakeInput
                { inputUrl = extractStringLit expr
                , inputFlake = True
                , inputFollows = Nothing
                }
        _ -> FlakeInput Nothing True Nothing

extractOutputs :: [Nix.Binding NExprLoc] -> FlakeOutputs
extractOutputs bindings = case findBinding "outputs" bindings of
    Just outputsExpr -> parseOutputsExpr outputsExpr
    Nothing -> emptyFlakeOutputs

parseOutputsExpr :: NExprLoc -> FlakeOutputs
parseOutputsExpr expr = case unwrapExpr expr of
    NAbs _ body -> parseOutputsBody body
    NSet _ bindings -> parseOutputsBindings bindings
    _ -> emptyFlakeOutputs

parseOutputsBody :: NExprLoc -> FlakeOutputs
parseOutputsBody expr = case unwrapExpr expr of
    NSet _ bindings -> parseOutputsBindings bindings
    NLet _ body -> parseOutputsBody body
    NWith _ body -> parseOutputsBody body
    _ -> emptyFlakeOutputs

emptyFlakeOutputs :: FlakeOutputs
emptyFlakeOutputs =
    FlakeOutputs
        Map.empty
        Map.empty
        Map.empty
        Map.empty
        Map.empty
        Map.empty
        Map.empty
        Nothing
        Map.empty

parseOutputsBindings :: [Nix.Binding NExprLoc] -> FlakeOutputs
parseOutputsBindings bindings =
    FlakeOutputs
        { outPackages = parseSystemMap "packages" bindings
        , outDevShells = parseSystemMap "devShells" bindings
        , outChecks = parseSystemMap "checks" bindings
        , outApps = parseSystemMap "apps" bindings
        , outOverlays = parseSimpleMap "overlays" bindings
        , outNixosModules = parseSimpleMap "nixosModules" bindings
        , outNixosConfigurations = parseSimpleMap "nixosConfigurations" bindings
        , outLib = findBinding "lib" bindings
        , outOther = parseUnknownBindings bindings
        }

knownOutputNames :: [Text]
knownOutputNames = ["packages", "devShells", "checks", "apps", "overlays", "nixosModules", "nixosConfigurations", "lib"]

parseSystemMap :: Text -> [Nix.Binding NExprLoc] -> Map Text (Map Text OutputEntry)
parseSystemMap categoryName bindings = case findBinding categoryName bindings of
    Just expr -> case unwrapExpr expr of
        NSet _ systemBindings ->
            Map.fromList $ mapMaybe (parseSystemBinding categoryName) systemBindings
        _ -> Map.empty
    Nothing -> Map.empty

parseSystemBinding :: Text -> Nix.Binding NExprLoc -> Maybe (Text, Map Text OutputEntry)
parseSystemBinding category (Nix.NamedVar (StaticKey system :| []) expr _)
    | NSet _ packageBindings <- unwrapExpr expr =
        Just (varNameText system, Map.fromList $ mapMaybe (parseEntry category) packageBindings)
parseSystemBinding _ _ = Nothing

parseSimpleMap :: Text -> [Nix.Binding NExprLoc] -> Map Text OutputEntry
parseSimpleMap mapName bindings = case findBinding mapName bindings of
    Just expr -> case unwrapExpr expr of
        NSet _ entryBindings ->
            Map.fromList $ mapMaybe (parseEntry mapName) entryBindings
        _ -> Map.empty
    Nothing -> Map.empty

parseUnknownBindings :: [Nix.Binding NExprLoc] -> Map Text NExprLoc
parseUnknownBindings bindings =
    Map.fromList
        [ (varNameText name, expression)
        | Nix.NamedVar (StaticKey name :| []) expression _ <- bindings
        , let fullName = varNameText name
        , fullName `notElem` knownOutputNames
        ]

parseEntry :: Text -> Nix.Binding NExprLoc -> Maybe (Text, OutputEntry)
parseEntry category (Nix.NamedVar (StaticKey name :| []) expr _) =
    let resultType = inferOutputType category
        entry = OutputEntry (varNameText name) expr resultType
     in Just (varNameText name, entry)
parseEntry _ _ = Nothing

inferOutputType :: Text -> NixType
inferOutputType = \case
    "packages" -> TDerivation
    "devShells" -> TDerivation
    "checks" -> TDerivation
    "apps" -> TAttrs $ Map.fromList [("type", (TString, False)), ("program", (TString, False))]
    "overlays" -> TFun (TAttrsOpen Map.empty) (TFun (TAttrsOpen Map.empty) (TAttrsOpen Map.empty))
    "nixosModules" -> TAttrsOpen Map.empty
    "nixosConfigurations" -> TAttrsOpen Map.empty
    "lib" -> TAttrsOpen Map.empty
    _ -> TAny

-- ═════════════════════════════════════════════════════════════════════════════
-- type inference
-- ═════════════════════════════════════════════════════════════════════════════

data FlakeTypes = FlakeTypes
    { ftOutputsType :: !NixType
    , ftPackageTypes :: !(Map Text (Map Text NixType))
    , ftLibTypes :: !(Maybe NixType)
    }
    deriving (Eq, Show)

inferFlake :: Flake -> FlakeTypes
inferFlake flake =
    FlakeTypes
        { ftOutputsType = TFun (inferFlakeInputs (flakeInputs flake)) (inferFlakeOutputs (flakeOutputs flake))
        , ftPackageTypes = Map.map (Map.map entryType) (outPackages outputs)
        , ftLibTypes = inferFlakeLibType (outLib outputs)
        }
  where
    outputs = flakeOutputs flake

inferFlakeInputs :: Map Text FlakeInput -> NixType
inferFlakeInputs inputs =
    TAttrs $
        Map.fromList [("self", (TAttrsOpen Map.empty, False))]
            `Map.union` Map.map (const $ (TAttrsOpen Map.empty, False)) inputs

inferFlakeOutputs :: FlakeOutputs -> NixType
inferFlakeOutputs outputs =
    TAttrs $
        Map.fromList $
            catMaybes
                [ present "packages" (outPackages outputs) (inferPerSystemOutputs TDerivation)
                , present "devShells" (outDevShells outputs) (inferPerSystemOutputs TDerivation)
                , present "checks" (outChecks outputs) (inferPerSystemOutputs TDerivation)
                , present "apps" (outApps outputs) (inferPerSystemOutputs flakeAppType)
                , present "overlays" (outOverlays outputs) (TAttrsOpen Map.empty)
                ]
  where
    present name field entryType
        | Map.null field = Nothing
        | otherwise = Just (name, (entryType, False))

inferFlakeLibType :: Maybe NExprLoc -> Maybe NixType
inferFlakeLibType Nothing = Nothing
inferFlakeLibType (Just libExpr) = case inferExpr libExpr of
    Right (type_, _) -> Just type_
    Left _ -> Nothing

inferPerSystemOutputs :: NixType -> NixType
inferPerSystemOutputs elementType =
    TAttrs $
        Map.fromList
            [ ("x86_64-linux", (TAttrsOpen (Map.singleton "_" (elementType, False)), False))
            , ("aarch64-linux", (TAttrsOpen (Map.singleton "_" (elementType, False)), False))
            , ("x86_64-darwin", (TAttrsOpen (Map.singleton "_" (elementType, False)), False))
            , ("aarch64-darwin", (TAttrsOpen (Map.singleton "_" (elementType, False)), False))
            ]

flakeAppType :: NixType
flakeAppType = TAttrs $ Map.fromList [("type", (TString, False)), ("program", (TString, False))]

-- ═════════════════════════════════════════════════════════════════════════════
-- schema
-- ═════════════════════════════════════════════════════════════════════════════

flakeOutputSchema :: NixType
flakeOutputSchema =
    TAttrs $
        Map.fromList
            [ ("packages", (systemMapType TDerivation, False))
            , ("devShells", (systemMapType TDerivation, False))
            , ("checks", (systemMapType TDerivation, False))
            , ("apps", (systemMapType flakeAppType, False))
            , ("overlays", (TAttrsOpen (Map.singleton "_" (flakeOverlayType, False)), False))
            , ("nixosModules", (TAttrsOpen Map.empty, False))
            , ("nixosConfigurations", (TAttrsOpen Map.empty, False))
            , ("lib", (TAttrsOpen Map.empty, False))
            , ("formatter", (systemMapType TDerivation, False))
            , ("templates", (TAttrsOpen (Map.singleton "_" (flakeTemplateType, False)), False))
            ]

systemMapType :: NixType -> NixType
systemMapType t = TAttrsOpen (Map.singleton "_" ((TAttrsOpen (Map.singleton "_" (t, False))), False))

flakeOverlayType :: NixType
flakeOverlayType = TFun (TAttrsOpen Map.empty) (TFun (TAttrsOpen Map.empty) (TAttrsOpen Map.empty))

flakeTemplateType :: NixType
flakeTemplateType = TAttrs $ Map.fromList [("description", (TString, False)), ("path", (TPath, False))]

-- ═════════════════════════════════════════════════════════════════════════════
-- helpers
-- ═════════════════════════════════════════════════════════════════════════════

findBinding :: Text -> [Nix.Binding NExprLoc] -> Maybe NExprLoc
findBinding name = foldr check Nothing
  where
    check (Nix.NamedVar (StaticKey k :| []) expr _) acc
        | varNameText k == name = Just expr
        | otherwise = acc
    check _ acc = acc

extractStringLit :: NExprLoc -> Maybe Text
extractStringLit expr = case unwrapExpr expr of
    NStr (DoubleQuoted [Plain t]) -> Just t
    NStr (Indented _ [Plain t]) -> Just t
    _ -> Nothing

extractBoolLit :: NExprLoc -> Maybe Bool
extractBoolLit expr = case unwrapExpr expr of
    NConstant (NBool b) -> Just b
    _ -> Nothing
