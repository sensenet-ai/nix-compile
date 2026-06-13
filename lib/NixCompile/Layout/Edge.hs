{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                                 // layout // edge
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Every wire that left the box went somewhere; he learned to read them
--    all the same way."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The single home for eval-free dependency-edge discovery — the three ways one
--   Nix file reaches another, recognized syntactically from the AST. A PURE leaf
--   (hnix + 'NixCompile.Layout.Import' only, no inference), so every consumer —
--   the type closure ('NixCompile.Layout.Closure'), the module system, the
--   nixpkgs index — depends DOWN on this one definition instead of each carrying
--   its own copy of the same scan.
--
--     * 'EImport'      — @import ./path@, via the canonical 'findImports' walker;
--     * 'EFlakeImport' — a flake-parts @imports = [ ./a.nix … ]@ list element
--       ('flakeImportPaths');
--     * 'ECallPackage' — a top-level @x = callPackage ./path { }@ binding
--       ('callPackageTargetOf' on the bound value).
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Layout.Edge (
  -- * Edges
  EdgeKind (..),
  Edge (..),
  discoverEdges,

  -- * The individual scans (for consumers that want one kind)
  flakeImportPaths,
  callPackageTargetOf,
  topBindings,
)
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import Nix.Utils qualified as NixPath
import NixCompile.Layout.Import (Import (..), findImports)
import NixCompile.Syntax.Annotation (varNameText, pattern Layer)
import System.FilePath (normalise, (</>))

-- ── edges ───────────────────────────────────────────────────────────

{- | Which kind of dependency an edge encodes — the three ways one Nix file
reaches another without evaluation.
-}
data EdgeKind
  = -- | @import ./path@ (also @import ./path args@, @builtins.import@)
    EImport
  | -- | a flake-parts @imports = [ ./a.nix … ]@ list element
    EFlakeImport
  | -- | a top-level @x = callPackage ./path { }@ binding
    ECallPackage
  deriving (Eq, Ord, Show)

{- | One discovered edge: its kind, the path it resolves to (against the source
file's directory, before any existence check), and the path text as written
(the key inference's 'lookupImport' looks an @import@ up under).
-}
data Edge = Edge
  { edgeKind :: !EdgeKind
  , edgePath :: !FilePath
  , edgeRaw :: !Text
  }
  deriving (Eq, Show)

{- | Every dependency edge of an expression, all three kinds, eval-free. The
@import@ case delegates to the canonical 'findImports' walker; the flake-parts and
@callPackage@ cases use the scans below.
-}
discoverEdges :: FilePath -> NExprLoc -> [Edge]
discoverEdges baseDir expr =
  [Edge EImport (impPath i) (impRawPath i) | i <- findImports baseDir expr]
    ++ [Edge EFlakeImport (resolveEdge baseDir p) (T.pack p) | p <- flakeImportPaths expr]
    ++ [Edge ECallPackage (resolveEdge baseDir (T.unpack raw)) raw | raw <- callPackagePaths expr]

-- ── the individual scans ─────────────────────────────────────────────

-- | flake-parts module imports: the literal paths of a top-level @imports = [ … ]@.
flakeImportPaths :: NExprLoc -> [FilePath]
flakeImportPaths expr = maybe [] extractPaths (findAttr "imports" (topBindings expr))
 where
  extractPaths (Layer (NList es)) = mapMaybe litPath es
  extractPaths (Layer (NApp f a)) = extractPaths f ++ extractPaths a
  extractPaths _ = []
  litPath (Layer (NLiteralPath (NixPath.Path p))) = Just p
  litPath (Layer (NStr (DoubleQuoted [Plain t]))) = Just (T.unpack t)
  litPath _ = Nothing

-- | The literal paths of every top-level @x = callPackage ./path { … }@ binding.
callPackagePaths :: NExprLoc -> [Text]
callPackagePaths = mapMaybe binding . topBindings
 where
  binding (NamedVar _ rhs _) = callPackageTargetOf rhs
  binding _ = Nothing

{- | The literal path of a @callPackage ./path@ / @callPackages ./path@ application,
if the expression is one (the package file an @x = callPackage ./p { }@ binding
pulls in). Bare @callPackage@ head only, by design (matching nixpkgs all-packages).
-}
callPackageTargetOf :: NExprLoc -> Maybe Text
callPackageTargetOf
  (Layer (NApp (Layer (NApp (Layer (NSym f)) (Layer (NLiteralPath (NixPath.Path p))))) _))
    | varNameText f `elem` (["callPackage", "callPackages"] :: [Text]) = Just (T.pack p)
callPackageTargetOf _ = Nothing

-- ── small AST helpers ───────────────────────────────────────────────

-- | Top-level bindings, unwrapping lambda / let / with wrappers.
topBindings :: NExprLoc -> [Binding NExprLoc]
topBindings (Layer (NSet _ bs)) = bs
topBindings (Layer (NAbs _ body)) = topBindings body
topBindings (Layer (NLet _ body)) = topBindings body
topBindings (Layer (NWith _ body)) = topBindings body
topBindings _ = []

-- | The value of a named static binding, if present.
findAttr :: Text -> [Binding NExprLoc] -> Maybe NExprLoc
findAttr name = foldr check Nothing
 where
  check (NamedVar (StaticKey k :| []) v _) acc
    | varNameText k == name = Just v
    | otherwise = acc
  check _ acc = acc

-- | Resolve a raw import path against a base directory (absolute paths pass through).
resolveEdge :: FilePath -> FilePath -> FilePath
resolveEdge _ path@('/' : _) = path
resolveEdge baseDir path = normalise (baseDir </> path)
