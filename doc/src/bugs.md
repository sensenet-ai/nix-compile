# Bug Tracker

Current status of known issues. See [BUGS.md](https://github.com/sensenet-ai/nix-compile/blob/main/BUGS.md) in the repository for the full detail.

## Fixed

| ID | Description |
|----|-------------|
| CRIT-1 | Bare-word config values misidentified as variables |
| CRIT-2 | Single-token literal values lost in config path extraction |
| CRIT-3 | Multi-token config values truncated to first token |
| CRIT-4 | `detectUnsupported` misses `rec` attrsets |
| BUG-1 | `unifyUnion` checks membership against un-substituted types |
| BUG-4 | `cmdCheck` discards solved substitution |
| DESIGN-1 | Scope graph edge priority not implemented |
| DESIGN-2 | `TVar -> TString` default masks inference failures (accepted trade-off; `schemaDefaultedVars` tracks unresolved vars) |
| DESIGN-3 | `emit-config` emits unguarded `$VAR` references (now uses `${VAR:?}`) |
| NEW-1 | `innerToText` catch-all produces phantom bare-command facts |
| NEW-2 | Type error not counted in `cmdNix` error tally |
| NEW-3 | `error "impossible"` in production code |
| NEW-4 | `NWith` scope edges both point to lexical parent |
| NEW-5 | `fromModuleGraph` drops all but first scope graph |
| NEW-6 | `FlakeOutputs` `Eq` only compares packages (won't fix — low impact) |
| NEW-7 | `mergeSchemas` drops overlapping env specs |
| NEW-8 | `buildConfigSchema` last-writer-wins semantics inverted |
| NEW-9 | `mapConcurrently` unbounded parallelism |
| NEW-10 | `findAllNixFiles` has no path-escape guard |
| NEW-11 | `NConcat` doesn't verify list type |
| NEW-12 | `findReferences` matches by name only |
| FIX-5 | `unsafePerformIO` in test suite |
| FIX-10 | `//` check in `isStorePath` |
| FIX-11 | No QuickCheck properties for Nix type inference (10 properties added) |
| FIX-12 | CI check only runs `--help` (now uses `haskell.lib.doCheck`) |
| FIX-13 | `emptySubst` in test (now uses real solved subst) |
| FIX-15 | `srcSpanToSpan` duplicated across 7 modules (deduplicated to Utils.hs) |
| SPECDEV-2 | ShellCheck token IDs in `locLine` — now uses ShellCheck `Position` with real line/column |
| 0x04-1 | All `TIO.readFile` calls wrapped in `try`/`IOException` |
| 0x04-2 | `jsonEscape` handles all control chars U+0000-U+001F per RFC 8259 |
| 0x04-3 | `findAllNixFiles` root visited-set initialization bug |
| review2-C1 | Shell injection via `${VAR:-…}` default-value passthrough — fixed by `escapeForParamExpansion` at the render boundary |
| review2-C2 | `inferExpr`/`Scope.buildExpr`/`Formatter.printNExprF` unguarded against deep input — fixed by `Safety.analyzeDepth` precondition in every CLI entry |
| review2-C3 | `detectUnsupportedConstruct` bypassable via `NWith`/`NStr`/`NSynHole` — replaced by single-source depth walker that descends every Fix unwrap |
| review2-C4 | hnix/megaparsec `StackOverflow` not caught — `Safety.safeParseNixFile`/`safeParseNixText` route through `try @SomeException` |
| review2-C5 | Sibling-directory escape via prefix-without-separator — `walkDirectory` now requires the boundary path separator |
| review2-C6 | Dhall config loader allowed remote imports — `Config.loadConfig` pre-parses and rejects any `Remote` import in the source AST |
| review2-S1 | `head`/`tail`/`length`/`filter` typed with `TAny` — replaced with single-parameter polymorphic schemes |
| review2-S2 | Closed-set missing-key returned `freshVar` — now throws unless the `or` default is provided |
| review2-S3 | Unbound variables returned `freshVar` — now error unless `envLenient = True` |
| review2-S4 | `inferHasAttr` ignored the attribute path — now type-checks dynamic-key antiquotations |
| review2-S5 | Nested-path bindings (`{ a.b = 1; }`) silently dropped — `desugarNestedBindings` synthesizes proper attrset structure |
| review2-S6 | `NPlus` accepted any `(t, t)` — now restricted to `Int|Float|String|Path` |
| review2-Co1 | `//` operator collapsed polymorphic operand — TVar fallback now routes through `TAttrsOpen` |
| review2-Co2 | Synthetic `NSelect` for `inherit (scope) name` used `nullSpan` — now carries the scope expression's actual span |
| review2-B1 | `combinedLint` silently returned `emptyBundle` past depth — new `combinedLintSafe` distinguishes `LintOk` from `LintDepthExceeded` |
| review2-B2 | LSP cache only invalidated on `flake.nix` save — now invalidates on every save in the project root |
| review2-B3 | LSP had no exception handling around `buildModuleGraph` — wrapped in `try @SomeException` with in-flight dedup |
| review2-B4 | `spToDiagnostic` could underflow to ~4 billion on 0-based bash spans — clamped to zero |
| review2-B5 | `voidProjectDiags` was a no-op stub — now actually populates the cache via `getOrBuildModuleGraph` |
| review2-B6 | `findProjectRoot` capped at 10 levels — raised to 64 (`projectRootWalkupLimit`) |
| review2-D1 | Three independent `200` constants — unified at `Safety.maxRecursionDepth` |
| review2-D2 | `cmdFmt`/`cmdInfer`/`cmdScope*` used empty environment — `formatFileWithEnv` accepts cross-module env |
| review2-P2 | `walkDirectory` rebuilt `Set.toList ignoredDirs` per entry — switched to `Set.member` |

## Closed (confirmed not bugs)

| ID | Reason |
|----|--------|
| BUG-2 | `shellBuiltins` does not contain `""` (retracted) |
| BUG-5 | `mergeEnvSpec` left-biased type is safe in context (solver guarantees consistency) |

## Open

| ID | Description |
|----|-------------|
| BUG-3 | `findValueTokens` loses `Quoted` metadata on text-based fallback path. Depends on ShellCheck tokenization behavior. |
| REVIEW-4 | `ALEPH-B00N` error code scheme not fully implemented (cf. HACKING.md). |
| REVIEW-7 | `ConfigSpec` record has mutually-exclusive fields (var vs literal); sum-type refactor deferred to Lean 4 port. |

## Untested

| Target | Coverage Gap |
|--------|-------------|
| Config glob matching | No unit tests for `matchGlob` / `tokenise` / `charMatch` |
| Layout conventions | 6 of 7 validation paths untested (nixpkgsByName, nixosConfig, validateAttrName, validateIdentifier, validateForbidden, validateFlakeModReq) |
| Layout.hs | L001-L002 fixture gaps; CamelCase/PascalCase naming untested |
| Config rules | Rule IDs in Dhall config schema (non-lisp-case, missing-*, cpp-*) lack enforcement code mapping |
