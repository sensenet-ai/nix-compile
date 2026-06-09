{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
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
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types hiding (Binding)
import Nix.Expr.Types qualified as Nix
import Nix.Expr.Types.Annotated
import Nix.Parser (parseNixFileLoc)
import Nix.Utils qualified as Nix
import NixCompile.Nix.Inference (inferExpr)
import NixCompile.Nix.Types
import NixCompile.Syntax.Annotation (varNameText, pattern Layer)
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
  -- lawful structural Eq (REVIEW-3 #14): the old hand-rolled instance compared
  -- only outPackages, silently treating structurally distinct flakes as equal.
  deriving (Eq, Show)

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
  pure (interpret result)
 where
  interpret (Left e) = Left (T.pack (show (e :: IOException)))
  interpret (Right (Left doc)) = Left (T.pack (show doc))
  interpret (Right (Right expr)) = extractFlake path expr

parseFlakeDir :: FilePath -> IO (Either Text Flake)
parseFlakeDir dir = do
  let flakePath = dir </> "flake.nix"
  exists <- doesFileExist flakePath
  if exists
    then parseFlake flakePath
    else pure $ Left $ "No flake.nix found in " <> T.pack dir

extractFlake :: FilePath -> NExprLoc -> Either Text Flake
extractFlake path (Layer (NSet _ bindings)) =
  Right
    Flake
      { flakeDescription = extractDescription bindings
      , flakeInputs = extractInputs bindings
      , flakeOutputs = extractOutputs bindings
      , flakePath = path
      }
extractFlake _ _ = Left "flake.nix must be an attribute set"

extractDescription :: [Nix.Binding NExprLoc] -> Maybe Text
extractDescription = foldr check Nothing
 where
  check (Nix.NamedVar (StaticKey name :| []) expr _) acc
    | varNameText name == "description" = extractStringLit expr
    | otherwise = acc
  check _ acc = acc

extractInputs :: [Nix.Binding NExprLoc] -> Map Text FlakeInput
extractInputs bindings
  | Just (Layer (NSet _ inputBindings)) <- findBinding "inputs" bindings =
      Map.fromList (mapMaybe parseInput inputBindings)
  | otherwise = Map.empty
 where
  parseInput :: Nix.Binding NExprLoc -> Maybe (Text, FlakeInput)
  parseInput (Nix.NamedVar (StaticKey name :| []) expr _) = Just (varNameText name, parseInputExpr expr)
  parseInput _ = Nothing

  parseInputExpr :: NExprLoc -> FlakeInput
  parseInputExpr (Layer (NSet _ bs)) =
    FlakeInput
      { inputUrl = findBinding "url" bs >>= extractStringLit
      , inputFlake = fromMaybe True (findBinding "flake" bs >>= extractBoolLit)
      , inputFollows = findBinding "follows" bs >>= extractStringLit
      }
  parseInputExpr expr@(Layer (NStr _)) =
    FlakeInput
      { inputUrl = extractStringLit expr
      , inputFlake = True
      , inputFollows = Nothing
      }
  parseInputExpr _ = FlakeInput Nothing True Nothing

extractOutputs :: [Nix.Binding NExprLoc] -> FlakeOutputs
extractOutputs bindings = maybe emptyFlakeOutputs parseOutputsExpr (findBinding "outputs" bindings)

parseOutputsExpr :: NExprLoc -> FlakeOutputs
parseOutputsExpr (Layer (NAbs _ body)) = parseOutputsBody body
parseOutputsExpr (Layer (NSet _ bindings)) = parseOutputsBindings bindings
parseOutputsExpr _ = emptyFlakeOutputs

parseOutputsBody :: NExprLoc -> FlakeOutputs
parseOutputsBody (Layer (NSet _ bindings)) = parseOutputsBindings bindings
parseOutputsBody (Layer (NLet _ body)) = parseOutputsBody body
parseOutputsBody (Layer (NWith _ body)) = parseOutputsBody body
parseOutputsBody _ = emptyFlakeOutputs

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
parseSystemMap categoryName bindings
  | Just (Layer (NSet _ systemBindings)) <- findBinding categoryName bindings =
      Map.fromList (mapMaybe (parseSystemBinding categoryName) systemBindings)
  | otherwise = Map.empty

parseSystemBinding :: Text -> Nix.Binding NExprLoc -> Maybe (Text, Map Text OutputEntry)
parseSystemBinding category (Nix.NamedVar (StaticKey system :| []) (Layer (NSet _ packageBindings)) _) =
  Just (varNameText system, Map.fromList (mapMaybe (parseEntry category) packageBindings))
parseSystemBinding _ _ = Nothing

parseSimpleMap :: Text -> [Nix.Binding NExprLoc] -> Map Text OutputEntry
parseSimpleMap mapName bindings
  | Just (Layer (NSet _ entryBindings)) <- findBinding mapName bindings =
      Map.fromList (mapMaybe (parseEntry mapName) entryBindings)
  | otherwise = Map.empty

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
inferOutputType "packages" = TDerivation
inferOutputType "devShells" = TDerivation
inferOutputType "checks" = TDerivation
inferOutputType "apps" = TAttrs $ Map.fromList [("type", (TString, False)), ("program", (TString, False))]
inferOutputType "overlays" = TFun (tRecOpenAnon Map.empty) (TFun (tRecOpenAnon Map.empty) (tRecOpenAnon Map.empty))
inferOutputType "nixosModules" = tRecOpenAnon Map.empty
inferOutputType "nixosConfigurations" = tRecOpenAnon Map.empty
inferOutputType "lib" = tRecOpenAnon Map.empty
inferOutputType _ = TAny

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
    Map.fromList [("self", (tRecOpenAnon Map.empty, False))]
      `Map.union` Map.map (const (tRecOpenAnon Map.empty, False)) inputs

inferFlakeOutputs :: FlakeOutputs -> NixType
inferFlakeOutputs outputs =
  TAttrs $
    Map.fromList $
      catMaybes
        [ present "packages" (outPackages outputs) (inferPerSystemOutputs TDerivation)
        , present "devShells" (outDevShells outputs) (inferPerSystemOutputs TDerivation)
        , present "checks" (outChecks outputs) (inferPerSystemOutputs TDerivation)
        , present "apps" (outApps outputs) (inferPerSystemOutputs flakeAppType)
        , present "overlays" (outOverlays outputs) (tRecOpenAnon Map.empty)
        ]
 where
  present name field entryType
    | Map.null field = Nothing
    | otherwise = Just (name, (entryType, False))

inferFlakeLibType :: Maybe NExprLoc -> Maybe NixType
inferFlakeLibType Nothing = Nothing
inferFlakeLibType (Just libExpr) = either (const Nothing) (Just . fst) (inferExpr libExpr)

inferPerSystemOutputs :: NixType -> NixType
inferPerSystemOutputs elementType =
  TAttrs $
    Map.fromList
      [ ("x86_64-linux", (tRecOpenAnon (Map.singleton "_" (elementType, False)), False))
      , ("aarch64-linux", (tRecOpenAnon (Map.singleton "_" (elementType, False)), False))
      , ("x86_64-darwin", (tRecOpenAnon (Map.singleton "_" (elementType, False)), False))
      , ("aarch64-darwin", (tRecOpenAnon (Map.singleton "_" (elementType, False)), False))
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
      , ("overlays", (tRecOpenAnon (Map.singleton "_" (flakeOverlayType, False)), False))
      , ("nixosModules", (tRecOpenAnon Map.empty, False))
      , ("nixosConfigurations", (tRecOpenAnon Map.empty, False))
      , ("lib", (tRecOpenAnon Map.empty, False))
      , ("formatter", (systemMapType TDerivation, False))
      , ("templates", (tRecOpenAnon (Map.singleton "_" (flakeTemplateType, False)), False))
      ]

systemMapType :: NixType -> NixType
systemMapType t = tRecOpenAnon (Map.singleton "_" (tRecOpenAnon (Map.singleton "_" (t, False)), False))

flakeOverlayType :: NixType
flakeOverlayType = TFun (tRecOpenAnon Map.empty) (TFun (tRecOpenAnon Map.empty) (tRecOpenAnon Map.empty))

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
extractStringLit (Layer (NStr (DoubleQuoted [Plain t]))) = Just t
extractStringLit (Layer (NStr (Indented _ [Plain t]))) = Just t
extractStringLit _ = Nothing

extractBoolLit :: NExprLoc -> Maybe Bool
extractBoolLit (Layer (NConstant (NBool b))) = Just b
extractBoolLit _ = Nothing
