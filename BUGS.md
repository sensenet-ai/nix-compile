# Bug Tracking

New findings from adversarial review (Apr 2026), layered on top of existing [FIXES.md](./FIXES.md) and [REVIEW.md](./REVIEW.md).

## Deprecated entries from prior docs

The following items from the prior review cycle have been subsumed or are stale:

| Doc | Entry | Status |
|-----|-------|--------|
| FIXES P1 | FIX-1 (lambda shadowing) | Fixed |
| FIXES P1 | FIX-2 (config path validation) | Fixed |
| FIXES P1 | FIX-3 (symlink cycles) | Fixed |
| FIXES P2 | FIX-4 (path traversal) | Fixed |
| FIXES P2 | FIX-5 (unsafePerformIO) | Open — still relevant |
| FIXES P3 | FIX-6 (applyDefaults dead code) | No action |
| FIXES P3 | FIX-7 (NPlus missing constraint) | Fixed |
| FIXES P3 | FIX-8 (unifyUnion multi-element) | Fixed |
| FIXES P3 | FIX-9 (mergeSchemas comment) | Fixed |
| FIXES P3 | FIX-10 (// in isStorePath) | Open — still relevant |
| FIXES P4 | FIX-11 (QC for Nix infer) | Fixed |
| FIXES P4 | FIX-12 (CI test exec) | Open |
| FIXES P4 | FIX-13 (emptySubst in test) | Open |
| FIXES P4 | FIX-14 (DynamicKey in NHasAttr) | Fixed |
| FIXES P5 | FIX-15 (srcSpanToSpan dedup) | Open |
| FIXES P5 | FIX-16 (eval in shellBuiltins) | Fixed |
| FIXES P5 | FIX-17 (token ID in span) | Fixed |
| REVIEW | BUG-1 (extractSimpleVar guard order) | Fixed |
| REVIEW | BUG-2 (parseExpansionBody Nothing) | Fixed |
| REVIEW | SPECDEV-2 (token IDs in spans) | Accepted |
| REVIEW | SPECDEV-4 (UseAlternate no facts) | Accepted |
| REVIEW | SPECDEV-5 (// in isStorePath) | Accepted |

---

## New bugs found (Apr 2026)

### CRIT-1: Bare-word config values misidentified as variables [FIXED]

**File:** `lib/NixCompile/Bash/Facts.hs:72-79`

`configArrayFacts` calls `extractSimpleVar`, which has a guard `| isVar t = Just t` that matches bare words as variable names.

```
config.server.host=localhost
# → ConfigAssign ["server","host"] "localhost" Unquoted
# → should be ConfigLit ["server","host"] (LitString "localhost")
```

`extractVarRef` was already defined in the same file for exactly this purpose but was not used here.

**Fix:** Use `extractVarRef` instead of `extractSimpleVar` in `configArrayFacts`.

### CRIT-2: Single-token literal values lost in config path extraction [FIXED]

**File:** `lib/NixCompile/Bash/Facts.hs:149-167`

`findValueTokens` looks for the token after the one ending with `=`. When ShellCheck produces a single Literal token `"config.x.y=value"`, `findValueTokens` detects `=` in the suffix, sets `seenEq=True`, then finds no remaining tokens and returns `([], Unquoted)`. `extractConfigValue [] _` returns `Nothing`. The assignment is silently dropped.

The text-based fallback in `configFacts` handles this correctly, but the AST-aware `configFactsFromParts` path missed it.

**Fix:** Fall back to text-based RHS parsing when `findValueTokens` returns empty.

### CRIT-3: Multi-token config values truncated to first token [FIXED]

**File:** `lib/NixCompile/Bash/Facts.hs:194-201`

`extractConfigValue` takes only the first token: `extractConfigValue (tok : _)`. For values like `config.x.y=$VAR/extra` or `config.x.y=$VAR$OTHER`, everything after the first token is dropped.

**Fix:** Use `T.concat (map tokenToText toks)` over all tokens.

### CRIT-4: `detectUnsupported` misses `rec` attrsets [FIXED]

**File:** `app/nix-compile.hs:461-489`

The CLI's `cmdTypeCheck` uses `detectUnsupported` to skip unanalyzable files before type inference. It checks `with` and dynamic attrs but not `NSet Recursive`. `rec { }` files proceed to type inference, which may produce incorrect results or confusing errors. Meanwhile `NixCompile.Nix.Lint.findNixViolations` correctly bans rec — creating a gap between lint and typecheck.

**Fix:** Add `NSet Recursive _ -> Just "rec attrset"` to `detectUnsupported`.

### BUG-1: `unifyUnion` checks membership against un-substituted types [FIXED]

**File:** `lib/NixCompile/Nix/Infer.hs:311-320`

`t' elem ts` checks the substituted type against original (possibly containing TVars) union members. If a union member was `TVar v` that later got substituted to `TInt`, the check fails because it compares `TInt` against `TVar v`.

**Fix:** Apply `applyCurrentSubst` to union members before the `elem` check.

### BUG-2: `shellBuiltins` includes empty string `""` [RETRACTED]

Original claim was that `shellBuiltins` contained `""` at line 319. Adversarial re-review confirms the list does **not** contain an empty string. The real risk is `innerToText`'s catch-all `_ -> ""` (see NEW-1 below).

### BUG-3: `findValueTokens` assumes `=` always at suffix of a Literal token [MITIGATED]

**File:** `lib/NixCompile/Bash/Facts.hs:173-186`

The check `"=" \`T.isSuffixOf\` (T.pack s)` assumes the `=` is at the end of a Literal token. If ShellCheck tokenizes `config.a.b=` as multiple parts (e.g., `Literal "config.a.b"`, `Literal "="`), the `=` is not at any suffix and `seenEq` stays False. The value is treated as part of the path.

Text-based fallback partially mitigates this, but quoting detection (`Quoted` vs `Unquoted`) is lost on the fallback path.

**Impact:** Depends on ShellCheck tokenization behavior, which may vary across versions.

### BUG-4: `cmdCheck` discards solved substitution [FIXED]

**File:** `app/nix-compile.hs:217-221`

`_subst <- solve constraints` — the substitution is bound to `_subst` (unused) and never inspected. Type errors are detected, but the solved types are never used or reported. The function then checks bare/dynamic commands using pre-solve raw facts.

**Impact:** Wasted computation. Unresolved types silently ignored.

### BUG-5: `mergeEnvSpec` picks first fact's type over second

**File:** `lib/NixCompile/Schema/Build.hs:62-69`

`Map.fromListWith mergeEnvSpec` via left-biased `Map.union` keeps the first fact's type. For `PORT=8080` followed by `PORT=hello`, the schema shows `PORT : TInt`. In bash, the second assignment wins at runtime. The solver would catch the type conflict (`TInt ~ TString`), so in practice duplicate assignments to the same var with different types produce a type error. But duplicate assignments with compatible types silently use the first.

**Impact:** Low — the solver guarantees type consistency across all assignments to a variable. The left-biased type is equivalent to the solved type.

### DESIGN-1: `sortEdges = id` in scope graph resolution [FIXED]

**File:** `lib/NixCompile/Nix/Scope.hs`

Edge priority (Parent > Import > With > Inherit > AttrAccess) was not implemented. `findPaths` now groups edges by label priority via `sortOn edgeLabel` and tries groups in order with `firstNonEmpty`, so higher-priority edges shadow lower-priority ones.

**Fix:** `sortEdges` replaced with `groupByLabel` + `firstNonEmpty` in `findPaths`. Property test `prop_scope_parent_before_with` confirms Parent edges resolve before With edges.

### DESIGN-2: `TVar -> TString` default masks inference failures [ACCEPTED]

**File:** `lib/NixCompile/Schema/Build.hs:123`

`applyDefaults` treats any unresolved TVar as `TString`. If the solver leaves a variable unresolved (cycle, incomplete constraints), the schema silently reports `TString` with no diagnostic.

### DESIGN-3: `emit-config` emits unguarded `$VAR` references [FIXED]

**File:** `lib/NixCompile/Emit/Config.hs:198-200`

For numeric/types values: `$VAR` is emitted directly. If `VAR` is unset at runtime, bash substitutes an empty string, producing invalid output like `{ "port": }`. The schema knows whether a var is required but this info isn't used to emit `${VAR:?}` guards.

Same pattern in `renderYamlValue` (line 243) and `renderTomlValue` (line 301). Additionally, the TOML emitter outputs `null` (line 303) which is not valid TOML.

---

## New bugs found (adversarial re-review, Apr 2026)

### NEW-1: `innerToText` catch-all produces phantom bare-command facts [FIXED]

**File:** `lib/NixCompile/Bash/Facts.hs:438`

`innerToText` returns `""` for unrecognized ShellCheck AST node types. If such a node appears as a command name, `cmdInvocationFacts` emits `BareCommand "" sp` — a false positive bare-command warning about a nonexistent command.

**Fix:** Guard against empty command text in `cmdInvocationFacts`.

### NEW-2: Type error not counted in `cmdNix` error tally [FIXED]

**File:** `app/nix-compile.hs:303-307, 324-328`

When `solve constraints` returns `Left err` in `checkScript`, the error is logged but the return value from that branch is bound to `_subst` and **discarded**. The final error count (`length violations + bareCount + dynCount`) does not include the type error. A script with a type error but no other violations reports 0 errors and passes the check.

**Impact:** High. Type errors are logged to stderr but do not affect the exit code.

**Fix:** Track the type error in the error count returned from `checkScript`.

### NEW-3: `error "impossible"` in production code [FIXED]

**File:** `lib/NixCompile/Nix/Infer.hs:352`

`mergeAttrs` contains `_ -> error "impossible"` which crashes the process with an unhandled exception rather than returning a proper error.

**Fix:** Replace with a proper error in the `Infer` monad.

### NEW-4: `NWith` scope edges both point to lexical parent [FIXED]

**File:** `lib/NixCompile/Nix/Scope.hs:381-383`

`NWith withExpr body` adds both a `Parent` edge and a `With` edge from the with-scope to the **same** lexical parent. The `With` edge should point to a scope derived from `withExpr` (the set being brought into scope), not the parent. This makes `with` effectively a no-op for scope resolution — names from the with-expression are never reachable.

**Fix:** Create a scope for `withExpr` and point the `With` edge there.

### NEW-5: `fromModuleGraph` drops all but first scope graph [FIXED]

**File:** `lib/NixCompile/Nix/Scope.hs:322-328`

```haskell
case Map.elems graphs of
  [] -> empty
  (g : _) -> g -- Return first for now
```

All file-level scope graphs except the first are discarded. Cross-file analysis is inert.

### NEW-6: `FlakeOutputs` `Eq` only compares `outPackages` [WONTFIX]

**File:** `lib/NixCompile/Nix/Flake.hs:86-88`

The `Eq` instance ignores devShells, checks, apps, overlays, and all other fields. Two structurally different `FlakeOutputs` compare as equal if their packages match.

### NEW-7: `mergeSchemas` uses `Map.union` — drops overlapping env specs [FIXED]

**File:** `lib/NixCompile/Types.hs:347`

`mergeSchemas` uses `Map.union` for `schemaEnv`, which silently drops the second schema's specs for overlapping variable names instead of merging them with `mergeEnvSpec`.

### NEW-8: `buildConfigSchema` last-writer-wins (no merge) [FIXED]

**File:** `lib/NixCompile/Schema/Build.hs:76`

Uses `Map.fromList` instead of `Map.fromListWith`. Duplicate config paths keep only the last entry, inconsistent with `buildEnvSchema` which merges.

### NEW-9: `mapConcurrently` unbounded parallelism [FIXED]

**File:** `app/nix-compile.hs:356`

`mapConcurrently` spawns one green thread per file with no upper bound. For large repositories, this can exhaust file descriptors or memory.

### NEW-10: `findAllNixFiles` has no path-escape guard [FIXED]

**File:** `app/nix-compile.hs:382-402`

Symlinks resolved by `canonicalizePath` can escape the project root. No `isPrefixOf canonRoot` check prevents traversal to arbitrary filesystem locations. The visited-set prevents infinite loops but not directory escape.

### NEW-11: `NConcat` doesn't verify list type [FIXED]

**File:** `lib/NixCompile/Nix/Infer.hs:492-494`

`++` in Nix is list concatenation only, but the type checker just unifies the two operands without constraining them to `TList`. `1 ++ 2` would pass type checking.

### NEW-12: `findReferences` matches by name only, not by resolution [FIXED]

**File:** `lib/NixCompile/Nix/Scope.hs:644-651`

Returns all references with matching name across all scopes, regardless of whether they actually resolve to the given declaration. Incorrect for codebases with shadowed names.
