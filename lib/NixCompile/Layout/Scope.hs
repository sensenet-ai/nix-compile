-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // nix // compile // scope
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Machine dreams hold a special vertigo. Turner lay down on a
--    virgin slab of green temperfoam in the makeshift dorm and
--    jacked Mitchell's dossier."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The scope-graph façade. The work lives in four leaves: the type vocabulary
--   ('NixCompile.Layout.Scope.Types', also the JSON projection), construction
--   from a Nix AST ('…Scope.Build'), name resolution + queries
--   ('…Scope.Resolve'), and the Dhall projection ('…Scope.Dhall'). This module
--   re-exports their public surface unchanged, so callers import one name.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Layout.Scope (
  module NixCompile.Layout.Scope.Types,
  module NixCompile.Layout.Scope.Build,
  module NixCompile.Layout.Scope.Resolve,
  toJSON,
  toDhall,
)
where

import Data.Aeson (toJSON)
import NixCompile.Layout.Scope.Build
import NixCompile.Layout.Scope.Dhall (toDhall)
import NixCompile.Layout.Scope.Resolve
import NixCompile.Layout.Scope.Types
