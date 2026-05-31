# TODO

## spans
- ShellCheck positions are zero-based, `Loc` treats them as 1-based. Bash diagnostic line numbers off by one from Nix.
- `emptySpan` sentinels proliferated across 3 modules — (0,0) errors indistinguishable from no-location errors.

## types
- `NixCompile.Types.TypeVar` (wrap Text) and `NixCompile.Nix.Types.TypeVar` (wrap Int) share the same name. Rename one.

## perf
- Recursive tree walks use lazy `concatMap`/`++` everywhere — builds deep thunk chains. Strict folds or difference lists.
- `mergeConfigSpec` silently drops data on duplicate paths — should warn.

## hardening
- No input size limit before parsing (1GB nix file = OOM vector).
- TOCTOU in `collectFiles`: canonicalize after listing, not before.
- `isStorePathExpr` prefix-matches `T.isPrefixOf "pkgs"` / `"lib"` — false positives on `pkgsXml`, `librettoPath`.
- `emitConfigFunction` constructs shell from config paths — fuzz it.

## cleanup
- `show` on internal types in user-facing errors (`Mismatch TInt TString ...`).
- Double AST walk in `checkFile` (detectUnsupported → combinedLint do the same traversal).

## style
- Drifted from style guide — file header ornaments, camelCase conventions, pragma placement. Audit and normalize.

## benchmarks
- LSP is interactive — hover/definition/completion latency must be measured under scale. Criterion benchmarks for `inferExpr`, `combinedLint`, `buildModuleGraph`.

## formatter
- Collapses too much whitespace — consecutive blank lines in indented strings flattened, binding spacing inconsistent. Needs a pass.

## tests
- Property tests for: mutual-rec fix, bare import path resolution, `isEvalInvocation`, multi-line semantic tokens.
