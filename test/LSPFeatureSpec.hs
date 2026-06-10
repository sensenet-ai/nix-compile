{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                       // tests // lsp // features
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "He never saw the whole of it, only the traffic: requests arriving,
--    answers dispatched, the board never going dark."
--
--                                                                                      — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   Pure-compute contract tests for the LSP language features, derived from an
--   ad-hoc audit of the running server (STR-133 recon). Each feature has a
--   REGRESSION GUARD pinning behaviour that is correct today, plus — where the
--   audit found a gap — a TRIPWIRE encoding the behaviour we WANT. A tripwire
--   inverts its assertion: it is green while the bug lives and flips red the
--   instant the underlying code is fixed, which is the cue to delete the
--   'tripwire' wrapper and keep the bare assertion. Mirrors the long-standing
--   'expectFailure' idiom in "Props.hs".
--
--   Audited gaps (each a tripwire below):
--     * diagnostics never surface the type errors inference already finds
--     * document-symbol outline ignores `let` bindings (only attrsets)
--     * a single type error blanks ALL inlay hints for the file
--     * completion never offers in-scope local bindings (only builtins)
--     * go-to-def / references do nothing with the cursor ON a declaration
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module LSPFeatureSpec (lspFeatureTests) where

import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, listToMaybe)
import Data.Text (Text)
import Language.LSP.Protocol.Types (CompletionItem (..), Position (..), Range (..))
import Nix.Expr.Types.Annotated (NExprLoc)
import Nix.Parser (parseNixTextLoc)
import NixCompile.Inference.Nix (builtinEnv, inferExprWithEnv)
import NixCompile.LSP.Handlers.Diagnostics (diagnosticsForExpr)
import NixCompile.LSP.Handlers.Features (
  completionsForExpr,
  findRef,
  inlayHintsForExpr,
 )
import NixCompile.LSP.Handlers.Symbols (collectTopBindingSymbols)
import NixCompile.Layout.Scope qualified as Scope

-- ── harness ────────────────────────────────────────────────────────

{- | A correct-contract assertion that holds TODAY — a regression guard. Keep it
green: if it ever flips, the feature regressed.
-}
holds :: Bool -> IO Bool
holds = pure

{- | A tripwire over a KNOWN-BUT-UNFIXED gap. The argument is the CORRECT
contract (True once the bug is fixed); we invert it so the suite stays green
while the bug lives. When someone fixes the code the tripwire flips RED —
the signal to promote it to a bare 'holds' and drop the wrapper.
-}
tripwire :: Bool -> IO Bool
tripwire = pure . not

-- | Parse test Nix source; a parse failure is a test bug, so bottom out loudly.
parse :: Text -> NExprLoc
parse src = either (\e -> error ("LSPFeatureSpec parse: " <> show e)) id (parseNixTextLoc src)

-- | A range spanning any reasonable test buffer (inlay hints are range-filtered).
wholeBuffer :: Range
wholeBuffer = Range (Position 0 0) (Position 1000 0)

-- | The label of a completion item (record pattern disambiguates the field).
completionLabel :: CompletionItem -> Text
completionLabel CompletionItem{_label = l} = l

-- ── diagnostics ────────────────────────────────────────────────────

{- | GUARD: a lint violation (`with`) does surface as a diagnostic — the
diagnostics layer works for the rules it covers.
-}
testDiagReportsLint :: IO Bool
testDiagReportsLint =
  holds (not (null (diagnosticsForExpr "<buffer>" (parse "with { a = 1; }; a"))))

{- | GUARD: the inference engine DOES detect `1 + "s"` as a type error (returns
Left). The information exists; the tripwire below is that it never reaches the
editor as a diagnostic.
-}
testEngineDetectsTypeError :: IO Bool
testEngineDetectsTypeError =
  holds (isLeft (inferExprWithEnv builtinEnv (parse "let y = \"s\"; in 1 + y")))

{- | TRIPWIRE: a type error should be published as a diagnostic. Today
'diagnosticsForExpr' runs only the lint rules — never inference — so a genuine
type error produces zero squiggles even though the engine found it.
-}
testDiagSurfacesTypeError :: IO Bool
testDiagSurfacesTypeError =
  tripwire (not (null (diagnosticsForExpr "<buffer>" (parse "let y = \"s\"; in 1 + y"))))

-- ── document symbols ───────────────────────────────────────────────

-- | GUARD: a top-level attrset yields one document symbol per binding.
testSymbolsAttrset :: IO Bool
testSymbolsAttrset =
  holds (length (collectTopBindingSymbols (parse "{ foo = 1; bar = 2; }")) == 2)

{- | TRIPWIRE: a `let … in` file should outline its let bindings. Today
'collectTopBindingSymbols' descends to the `in` body and only reads attrsets,
so a let-heavy file (the common case) has an empty outline.
-}
testSymbolsLetIn :: IO Bool
testSymbolsLetIn =
  tripwire (not (null (collectTopBindingSymbols (parse "let x = 1; y = 2; in x + y"))))

-- ── inlay hints ────────────────────────────────────────────────────

-- | GUARD: a clean file gets a type inlay hint per let binding.
testInlayClean :: IO Bool
testInlayClean =
  holds (not (null (inlayHintsForExpr builtinEnv (parse "let x = 1; y = 2; in x") wholeBuffer)))

{- | TRIPWIRE: one type error should not erase the hints for the well-typed
bindings around it. Today 'inlayHintsForExpr' runs whole-file inference and a
single error takes the Left branch, blanking EVERY hint in the file.
-}
testInlaySurvivesTypeError :: IO Bool
testInlaySurvivesTypeError =
  tripwire
    ( not
        ( null
            ( inlayHintsForExpr
                builtinEnv
                (parse "let good = 1; bad = 1 + \"s\"; in good")
                wholeBuffer
            )
        )
    )

-- ── completion ─────────────────────────────────────────────────────

-- | GUARD: completion offers builtins.
testCompletionBuiltins :: IO Bool
testCompletionBuiltins =
  holds (any ((== "map") . completionLabel) (completionsForExpr builtinEnv letExpr 0 25))
 where
  letExpr = parse "let myLocal = 1; in myLocal"

{- | TRIPWIRE: completion should offer in-scope local bindings. Today
'completionsForExpr' only emits builtins and options — its scope-completion
path is a stub returning [] — so `myLocal` never appears.
-}
testCompletionIncludesLocal :: IO Bool
testCompletionIncludesLocal =
  tripwire (any ((== "myLocal") . completionLabel) (completionsForExpr builtinEnv letExpr 0 25))
 where
  letExpr = parse "let myLocal = 1; in myLocal"

-- ── navigation (definition / references) ───────────────────────────

-- | Scope graph + first declaration / first reference of `let x = 1; in x + x`.
navFixture :: (Scope.ScopeGraph, Maybe Scope.Declaration, Maybe Scope.Reference)
navFixture = (sg, listToMaybe decls, listToMaybe refs)
 where
  sg = Scope.fromNixExpr Nothing (parse "let x = 1; in x + x")
  decls = concatMap Scope.scopeDeclarations (Map.elems (Scope.sgScopes sg))
  refs = concatMap Scope.scopeReferences (Map.elems (Scope.sgScopes sg))

declPos :: Scope.Declaration -> (Int, Int)
declPos d =
  ( Scope.posLine (Scope.spanStart (Scope.declSpan d))
  , Scope.posCol (Scope.spanStart (Scope.declSpan d))
  )

refPos :: Scope.Reference -> (Int, Int)
refPos r =
  ( Scope.posLine (Scope.spanStart (Scope.refSpan r))
  , Scope.posCol (Scope.spanStart (Scope.refSpan r))
  )

-- | GUARD: the cursor on a USE of `x` resolves to a reference (nav works there).
testFindRefAtUse :: IO Bool
testFindRefAtUse =
  case navFixture of
    (sg, _, Just r) -> holds (isJust (findRef (refPos r) sg))
    _ -> holds False

{- | GUARD: given the declaration, the graph enumerates both references — the
data backing references/rename is correct; only the cursor-on-declaration entry
point is missing (the tripwire below).
-}
testFindReferencesEnumerates :: IO Bool
testFindReferencesEnumerates =
  case navFixture of
    (sg, Just d, _) -> holds (length (Scope.findReferences sg d) == 2)
    _ -> holds False

{- | TRIPWIRE: the cursor ON a declaration should be navigable (go-to-def /
references / rename). Today 'findRef' only scans references, so placing the
cursor on the binding site `x = 1` finds nothing — the most common invocation
of references/rename returns null.
-}
testFindRefAtDecl :: IO Bool
testFindRefAtDecl =
  case navFixture of
    (sg, Just d, _) -> tripwire (isJust (findRef (declPos d) sg))
    _ -> tripwire False

-- ── runner ─────────────────────────────────────────────────────────

{- | All LSP feature contract tests. Names tagged @[tripwire]@ are inverted
known-broken markers: a RED tripwire means the bug was fixed — promote it.
-}
lspFeatureTests :: [(String, IO Bool)]
lspFeatureTests =
  [ ("lsp_diag_reports_lint", testDiagReportsLint)
  , ("lsp_diag_engine_detects_type_error", testEngineDetectsTypeError)
  , ("lsp_diag_surfaces_type_error [tripwire]", testDiagSurfacesTypeError)
  , ("lsp_symbols_attrset", testSymbolsAttrset)
  , ("lsp_symbols_letin [tripwire]", testSymbolsLetIn)
  , ("lsp_inlay_clean", testInlayClean)
  , ("lsp_inlay_survives_type_error [tripwire]", testInlaySurvivesTypeError)
  , ("lsp_completion_builtins", testCompletionBuiltins)
  , ("lsp_completion_includes_local [tripwire]", testCompletionIncludesLocal)
  , ("lsp_nav_findref_at_use", testFindRefAtUse)
  , ("lsp_nav_findreferences_enumerates", testFindReferencesEnumerates)
  , ("lsp_nav_findref_at_decl [tripwire]", testFindRefAtDecl)
  ]
