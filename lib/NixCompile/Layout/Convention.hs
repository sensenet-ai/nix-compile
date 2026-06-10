-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                       // layout convention
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--     "Wintermute was hive mind, decision maker, effecting change in
--      the world outside."
--
--                                                                 — Neuromancer
--

{- | Directory layout, file naming, and attribute naming convention enforcement.

Conventions define:
  * Where files live (directory structure)
  * What files are called (file naming)
  * What attributes are called (export naming)
  * What identifiers are called (code naming)

The key insight: if everything is a flake module, we get uniform structure.
Parse once, analyze everything.

This is the façade. The work lives in four leaves: the vocabulary
('NixCompile.Layout.Convention.Types'), the shipped convention catalog
('…Convention.Presets'), the naming policy ('…Convention.Naming'), and the
validation engine + universal checks ('…Convention.Validate'). The public
surface here is exactly what it always was.
-}
module NixCompile.Layout.Convention (
  -- * Conventions
  Convention (..),
  ConventionRule (..),
  straylight,
  nixpkgsByName,
  flakeParts,
  nixosConfig,
  allFlakeModule,

  -- * Validation
  validateLayout,
  validateFile,
  validateFileExpr,
  validateFileFromExpr,
  validateAttrName,
  validateIdentifier,

  -- * Convention lookup
  layoutFromName,

  -- * Universal checks
  isIndexFile,
  isMainFile,
  checkBannedFiles,
  checkClassAttr,

  -- * Results
  LayoutError (..),
  ErrorCode (..),

  -- * Naming
  NamingConvention (..),
  isValidName,
  toKebabCase,
  toSnakeCase,
  dropNixExtension,
)
where

import NixCompile.Layout.Convention.Naming (
  NamingConvention (..),
  dropNixExtension,
  isValidName,
  toKebabCase,
  toSnakeCase,
  validateAttrName,
  validateIdentifier,
 )
import NixCompile.Layout.Convention.Presets (
  allFlakeModule,
  flakeParts,
  layoutFromName,
  nixosConfig,
  nixpkgsByName,
  straylight,
 )
import NixCompile.Layout.Convention.Types (
  Convention (..),
  ConventionRule (..),
  ErrorCode (..),
  LayoutError (..),
 )
import NixCompile.Layout.Convention.Validate (
  checkBannedFiles,
  checkClassAttr,
  isIndexFile,
  isMainFile,
  validateFile,
  validateFileExpr,
  validateFileFromExpr,
  validateLayout,
 )
