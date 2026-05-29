{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // nix // module system
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "The sky above the port was the color of television, tuned to a dead
--    channel."
--
--                                                                 — Neuromancer
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                // module // option // system
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.ModuleSystem (
    -- * Types
    OptionInfo (..),
    ModuleOptions (..),

    -- * Extraction
    extractOptions,
    collectModuleOptions,

    -- * Queries
    optionAtPath,
    allOptionPaths,
)
where

import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import Nix.Utils (Path (..))
import NixCompile.Nix.Types
import NixCompile.Types (Loc (..), Span (..))

-- ═════════════════════════════════════════════════════════════════════════════
-- types
-- ═════════════════════════════════════════════════════════════════════════════

data OptionInfo = OptionInfo
    { optPath :: !Text
    , optType :: !NixType
    , optDefault :: !(Maybe NExprLoc)
    , optDescription :: !(Maybe Text)
    , optSpan :: !Span
    }
    deriving (Eq, Show)

data ModuleOptions = ModuleOptions
    { moOptions :: !(Map Text OptionInfo)
    , moConfig :: !(Maybe NExprLoc)
    , moImports :: ![FilePath]
    }
    deriving (Eq, Show)

-- ═════════════════════════════════════════════════════════════════════════════
-- extraction
-- ═════════════════════════════════════════════════════════════════════════════

-- | extract all declared options from a NixOS-style module
extractOptions :: NExprLoc -> Map Text OptionInfo
extractOptions expr = goOptions [] expr Map.empty
  where
    goOptions pathPrefix e acc = case unwrap e of
        NSet _ bindings ->
            foldr (collectOption pathPrefix) acc bindings
        NAbs _ body -> goOptions pathPrefix body acc
        NLet _ body -> goOptions pathPrefix body acc
        NWith _ body -> goOptions pathPrefix body acc
        _ -> acc

    collectOption pathPrefix binding acc = case binding of
        NamedVar (StaticKey name :| []) val _ ->
            let fullPath = buildPath pathPrefix (coerceVarName name)
             in if "options" `T.isPrefixOf` fullPath
                    then case collectOneOption fullPath val of
                        Just oi -> Map.insert (optPath oi) oi acc
                        Nothing -> goOptions (coerceVarName name : pathPrefix) val acc
                    else acc
        _ -> acc

    buildPath prefix name =
        T.intercalate "." (reverse (name : prefix))

-- | collect a single option from a mkOption/mkEnableOption call
collectOneOption :: Text -> NExprLoc -> Maybe OptionInfo
collectOneOption path expr = case unwrap expr of
    NApp func _ -> case funcName func of
        Just "mkOption" -> parseMkOption path expr
        Just "mkEnableOption" -> parseMkEnableOption path expr
        _ -> Nothing
    _ -> Nothing

-- | parse mkOption { type = ..., default = ..., description = ... }
parseMkOption :: Text -> NExprLoc -> Maybe OptionInfo
parseMkOption path expr = case unwrap expr of
    NApp _ arg -> case unwrap arg of
        NSet _ bindings -> do
            let optType = case findAttr "type" bindings of
                    Just t -> inferTypeExpr t
                    Nothing -> TAny
            let optDefault = findAttr "default" bindings
            let optDescription = findAttr "description" bindings >>= extractStringLit
            let optSpan = spanFromExpr arg
            pure $ OptionInfo path optType optDefault optDescription optSpan
        _ -> Nothing
    _ -> Nothing

-- | parse mkEnableOption "description" → Bool option
parseMkEnableOption :: Text -> NExprLoc -> Maybe OptionInfo
parseMkEnableOption path expr = case unwrap expr of
    NApp _ arg -> do
        let description = extractStringLit arg
        let optSpan = spanFromExpr expr
        pure $ OptionInfo path TBool Nothing description optSpan
    _ -> Nothing

-- ═════════════════════════════════════════════════════════════════════════════
-- type inference for option types
-- ═════════════════════════════════════════════════════════════════════════════

-- | infer NixType from a lib.types.* expression
inferTypeExpr :: NExprLoc -> NixType
inferTypeExpr e = case unwrap e of
    -- lib.types.bool → Bool
    NSelect _ base (StaticKey name :| [])
        | Just "types" <- attrLastName base -> inferTypeFromName (coerceVarName name)
    -- lib.types.str → String
    NApp func arg -> case funcName func of
        Just "types.listOf" -> TList (inferTypeExpr arg)
        Just "types.attrsOf" -> TAttrsOpen (Map.singleton "_" (inferTypeExpr arg, False))
        Just "types.nullOr" -> TUnion [TNull, inferTypeExpr arg]
        Just "types.either" -> TUnion (collectEitherTypes arg)
        Just "types.enum" -> inferEnumType arg
        Just "types.submodule" -> inferSubmoduleType arg
        _ -> TAny
    -- lib.types.listOf lib.types.str → [String]
    _ -> TAny

-- | find the last StaticKey name in a NSelect chain
attrLastName :: NExprLoc -> Maybe Text
attrLastName (Fix (Compose (AnnUnit _ e))) = case e of
    NSelect _ _ (StaticKey name :| []) -> Just (coerceVarName name)
    _ -> Nothing

-- | get the function name from an expression (lib.types.listOf → "listOf")
funcName :: NExprLoc -> Maybe Text
funcName (Fix (Compose (AnnUnit _ e))) = case e of
    NSym name -> Just (coerceVarName name)
    NSelect _ _ (StaticKey name :| []) -> Just (coerceVarName name)
    _ -> Nothing

-- | map common NixOS type names to NixType
inferTypeFromName :: Text -> NixType
inferTypeFromName = \case
    "bool" -> TBool
    "str" -> TString
    "int" -> TInt
    "float" -> TFloat
    "path" -> TPath
    "string" -> TString
    "number" -> TUnion [TInt, TFloat]
    "anything" -> TAny
    "unspecified" -> TAny
    "derivation" -> TDerivation
    "package" -> TDerivation
    "lines" -> TString
    "commas" -> TString
    "envVar" -> TString
    _ -> TAny

-- | collect types from either a b → Union [typeOf a, typeOf b]
collectEitherTypes :: NExprLoc -> [NixType]
collectEitherTypes e = case unwrap e of
    NApp f a -> case funcName f of
        Just "lib.types.either" -> inferTypeExpr a : collectEitherTypes f
        _ -> map inferTypeExpr (nixListExprs e)
    _ -> []

-- | infer enum type from list of strings
inferEnumType :: NExprLoc -> NixType
inferEnumType e = case unwrap e of
    NList literals ->
        let values = mapMaybe extractStringLit literals
         in if not (null values)
                then TUnion (map TStrLit values)
                else TString
    _ -> TString

-- | infer submodule type from import or options set
inferSubmoduleType :: NExprLoc -> NixType
inferSubmoduleType e = case unwrap e of
    NSet _ bindings ->
        let opts = mapMaybe (\(k, v) -> case k of
                    StaticKey name -> Just (coerceVarName name, inferTypeExpr v)
                    _ -> Nothing
                ) (mapMaybe bindingToPair bindings)
         in TAttrs (Map.map (\(t) -> (t, True)) (Map.fromList opts))
    _ -> TAttrsOpen Map.empty

-- ═════════════════════════════════════════════════════════════════════════════
-- module-level collection
-- ═════════════════════════════════════════════════════════════════════════════

-- | collect all options and module metadata from a NixOS module
collectModuleOptions :: NExprLoc -> ModuleOptions
collectModuleOptions expr =
    let opts = extractOptions expr
        cfg = findAttr "config" (topBindings expr)
        imports = findImports' expr
     in ModuleOptions opts cfg imports

-- | get top-level bindings, unwrapping lambdas and lets
topBindings :: NExprLoc -> [Binding NExprLoc]
topBindings (Fix (Compose (AnnUnit _ e))) = case e of
    NSet _ bs -> bs
    NAbs _ body -> topBindings body
    NLet _ body -> topBindings body
    NWith _ body -> topBindings body
    _ -> []

-- | find imports from the top-level `imports` binding
findImports' :: NExprLoc -> [FilePath]
findImports' expr = case findAttr "imports" (topBindings expr) of
    Just importExpr -> extractImportPaths importExpr
    Nothing -> []

extractImportPaths :: NExprLoc -> [FilePath]
extractImportPaths (Fix (Compose (AnnUnit _ e))) = case e of
    NList exprs -> mapMaybe extractLiteralPath exprs
    NApp func arg -> extractImportPaths func ++ extractImportPaths arg
    _ -> []

extractLiteralPath :: NExprLoc -> Maybe FilePath
extractLiteralPath (Fix (Compose (AnnUnit _ e))) = case e of
    NLiteralPath (Path p) -> Just p
    NStr (DoubleQuoted [Plain t]) -> Just (T.unpack t)
    _ -> Nothing

-- ═════════════════════════════════════════════════════════════════════════════
-- queries
-- ═════════════════════════════════════════════════════════════════════════════

optionAtPath :: ModuleOptions -> Text -> Maybe OptionInfo
optionAtPath mos path = Map.lookup path (moOptions mos)

allOptionPaths :: ModuleOptions -> [Text]
allOptionPaths mos = Map.keys (moOptions mos)

-- ═════════════════════════════════════════════════════════════════════════════
-- helpers
-- ═════════════════════════════════════════════════════════════════════════════

unwrap :: NExprLoc -> NExprF NExprLoc
unwrap (Fix (Compose (AnnUnit _ e))) = e

coerceVarName :: VarName -> Text
coerceVarName = coerce

-- | find a named binding in a list
findAttr :: Text -> [Binding NExprLoc] -> Maybe NExprLoc
findAttr name = foldr check Nothing
  where
    check (NamedVar (StaticKey k :| []) v _) acc
        | coerceVarName k == name = Just v
        | otherwise = acc
    check _ acc = acc

-- | extract a string literal from an expression
extractStringLit :: NExprLoc -> Maybe Text
extractStringLit e = case unwrap e of
    NStr (DoubleQuoted [Plain t]) -> Just t
    NStr (Indented _ [Plain t]) -> Just t
    NConstant _ -> Nothing
    _ -> Nothing

-- | extract binding as (key, value) pair if it has a static key
bindingToPair :: Binding NExprLoc -> Maybe (NKeyName NExprLoc, NExprLoc)
bindingToPair = \case
    NamedVar (StaticKey _ :| []) val _ -> Just (StaticKey "" , val) -- placeholder
    _ -> Nothing

-- | extract all expressions from a list literal
nixListExprs :: NExprLoc -> [NExprLoc]
nixListExprs (Fix (Compose (AnnUnit _ e))) = case e of
    NList es -> es
    _ -> []

-- | crude span extraction from an expression
spanFromExpr :: NExprLoc -> Span
spanFromExpr _ = Span (Loc 0 0) (Loc 0 0) Nothing
    -- n.b. real spans require SrcSpan conversion; placeholder for now
