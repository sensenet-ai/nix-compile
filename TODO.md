# TODO

## spans

- ShellCheck positions are 1-based (confirmed in source); previous REVIEW claim of
  0-based was wrong. Adjustment code reverted. `emptySpan` sentinels still
  proliferate across 3 modules — `Loc 0 0` errors indistinguishable from
  no-location errors. Replace with `Maybe Span` when convenient.

## types

- `NixCompile.Types.TypeVar` (wrap Text) and `NixCompile.Nix.Types.TypeVar`
  (wrap Int) share the same name. Rename one.

## perf

- Recursive tree walks use lazy `concatMap`/`++` everywhere — builds deep thunk
  chains. Strict folds or difference lists.
- `mergeConfigSpec` silently drops data on duplicate paths — should warn.

## hardening

- No input size limit before parsing (1GB nix file = OOM vector).
- TOCTOU in `collectFiles`: canonicalize after listing, not before.
- `isStorePathExpr` prefix-matches `T.isPrefixOf "pkgs"` / `"lib"` — false
  positives on `pkgsXml`, `librettoPath`.

## cleanup

- `show` on internal types in user-facing errors (`Mismatch TInt TString ...`).
- Double AST walk in `checkFile` (detectUnsupported → combinedLint walk the same
  structure).

## style

- Drifted from style guide — file header ornaments, camelCase conventions,
  pragma placement. Audit and normalize.

## benchmarks

- `cabal run nix-compile-bench` exercises analyzeDepth, parser, inferExpr,
  combinedLint, emit-config escape, and the full safety pipeline. Establish a
  baseline file and gate regressions in CI.

## formatter

- Collapses too much whitespace — consecutive blank lines in indented strings
  flattened, binding spacing inconsistent. Needs a pass.

## tests

- Property tests for: mutual-rec fix, bare import path resolution,
  `isEvalInvocation`, multi-line semantic tokens.
- Psychotic adversarial suite (`test/Psychotic.hs`) covers review-2 findings;
  add coverage for the open items above.

## review-2 fixed

All Critical / Soundness / Significant / Correctness items from `REVIEW-2.md`
have landed:

- C1 default-value command injection — `escapeForParamExpansion`
- C2/C3 depth-guard bypass — `Safety.analyzeDepth` from every entry point
- C4 parser stack overflow — `Safety.safeParseNix*`
- C5 sibling-directory escape — path-separator boundary check
- C6 Dhall remote imports — pre-parse rejection
- S1 polymorphic list builtins — `head`/`tail`/`length`/`filter` etc. now schemes
- S2 closed-set missing key — errors instead of fresh var
- S3 unbound variables — errors unless `envLenient`
- S4 `hasAttr` antiquotation typing
- S5 nested-path bindings — `desugarNestedBindings`
- S6 NPlus type restriction
- Co1 `//` polymorphism preservation
- Co2 inherit-from-scope span propagation
- B1 `combinedLintSafe` distinguishes "no violations" from depth-exceeded
- B2/B3/B4/B5/B6 LSP cache invalidation, exception handling, position underflow,
  warm-cache stub, walk-up limit
- D1 single `maxRecursionDepth` constant
- D2 cross-module env for `cmdFmt`/`cmdInfer`
- P2 `Set.member` instead of `Set.toList .. elem`
