# Bug Tracker

Current status of known issues. The authoritative round-3 review and its
verdicts live in [REVIEW-3.md](https://github.com/sensenet-ai/nix-compile/blob/main/REVIEW-3.md); the actionable work list is [TODO.md](https://github.com/sensenet-ai/nix-compile/blob/main/TODO.md). (The older `BUGS.md`/`FIXES.md`/`REVIEW*.md` artifacts were deleted in round 3 because their `file:line` citations had gone stale.) The test suite passes 446/446 with the differential oracle reporting 0 failures.

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
| NEW-6 | `FlakeOutputs` `Eq` only compares packages (was "won't fix"; later fixed in round 3 — see review3-#14) |
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
| review3-RC1 | Row polymorphism implemented — `TRec (Map Text (NixType,Bool)) RowTail` with `RowTail = RClosed \| ROpen TypeVar`; `unifyRec` accumulates fields on open∪open; selection emits row constraints and extends open records; list/row builtins are schemes instantiated at the use site |
| review3-RC2 | Bash subtyping order-dependence fixed — `NixCompile.Infer.Unify` solver rewritten as collect-then-join (union-find + LUB over the `{TInt,TBool} <: TNumeric` lattice), so `[TInt~α, α~TBool]` resolves `α=TNumeric` order-independently |
| review3-RC3 | Differential oracle added (`test/Oracle.hs` / `nix-compile-oracle`) comparing inferred type vs `nix-instantiate` `builtins.typeOf`; soundness gate at 0 failures |
| review3-RC4 | Inference quadratics fixed — triangular substitution (`addSubst` = insert, `applySubst` resolves on read), `desugarNestedBindings` mergeByKey made O(n log n), non-recursive bindings use `mapM` (no `++` append); wide-attrset inference 276ms→5.47ms at 5000 fields |
| review3-#1 | Nested attribute selection truncated to one level (`x.a.b.c` typed as `x.a`) — `inferSelect` now folds the full `NonEmpty` path and errors on selecting from a concrete non-attrset |
| review3-#2 | Select on a type variable emitted no row constraint (`(x: x.foo) 5` accepted) — selection now emits `α ~ { k : β \| ρ }` and open records accumulate fields across selections |
| review3-#3 | `==`/`!=` unified their operands → false positive on `x == null` — equality operators no longer unify; typed as `TBool` |
| review3-#4 | `map`/`foldl'`/`concatMap` were `TAny` — promoted to real polymorphic schemes (`getAttr`/`attrValues` remain `TAny` pending rows/IO; `import` is #5) |
| review3-#5 | Cross-module `import` type flow confirmed working for static paths — driver extends env with raw and canonical keys; test `review_import_cross_module` infers `TInt` end-to-end (non-static import args remain deferred) |
| review3-#7 | `NPlus` rejected legal `1 + 1.5`, `./a + "b"`, `"" + ./a` — `+` now modeled over the numeric/path/string lattice instead of unifying operands to an identical base |
| review3-#8 | Optional-field handling — `unifyRec`'s `closeAgainst` respects the optional flag, so an open row demanding an optional key a closed set lacks no longer errors |
| review3-#14 | `FlakeOutputs` `Eq` was lawless/lossy (compared only `outPackages`) — now a lawful `deriving (Eq)` (supersedes NEW-6) |
| review3-#16 | Reformatter rewritten on deep-vendored nixfmt 1.3.1 (RFC 166) under `vendor/nixfmt/` → byte-exact parity; reformatting is meaning-preserving (round-trip tests pass, incl. `''…''` interiors) |
| review3-#19 | Applying any polymorphic builtin hung inference — `instantiate` self-map plus chasing `applySubst` looped; `applySubst` self-map now treated as identity; test `review_poly_builtin_terminates` |
| review3-#21 | Config parser accepted `$\|` as a variable reference — `parseConfigValue` validates the var name after `$`/`"$` |
| review3-#22 | Config var-ref captured `;`/newline (injection-relevant) — a non-name is now a literal, not a captured var ref |
| review3-#23 | `eval` behind a prefix (`command eval …`, `builtin eval …`) not detected — `isEvalInvocation` skips command modifiers before checking for `eval` |
| review3-#24 | No `ConfigTemplate` fact for a multi-interpolation array config — array-subscript LHS reconstructed and `parseConfigTemplate` counts all var parts |
| review3-#25 | Union membership didn't flatten nested unions — `checkUnionMembership` flattens before the membership test |
| review3-#26 | Derivation linter missed `mkDerivation` reached through a deep select chain — `isMkDerivationCall` checks the last key of the select path |
| review3-modules | Module cleanup — deleted dead duplicate `NixCompile.Nix.Pretty`, folded `NixCompile.Nix.Format` into the `infer`-command module, renamed the inference engine `NixCompile.Nix.Infer` → `NixCompile.Nix.Inference` and the `infer`-command renderer to `NixCompile.Nix.Infer` |

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
| review3-#20 | Non-global builtins (`head`/`filter`/`foldl'`/`elemAt`/`length`/…) are in the checker's top-level scope, but Nix provides them only under `builtins.`; bare `head xs` is an undefined var at eval, yet the checker types it. Split builtin env into true-globals vs `builtins.*`-only. (Found by the oracle.) |

## Untested

| Target | Coverage Gap |
|--------|-------------|
| Config glob matching | No unit tests for `matchGlob` / `tokenise` / `charMatch` |
| Layout conventions | 6 of 7 validation paths untested (nixpkgsByName, nixosConfig, validateAttrName, validateIdentifier, validateForbidden, validateFlakeModReq) |
| Layout.hs | L001-L002 fixture gaps; CamelCase/PascalCase naming untested |
| Config rules | Rule IDs in Dhall config schema (non-lisp-case, missing-*, cpp-*) lack enforcement code mapping |
