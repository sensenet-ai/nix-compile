# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                                      // review
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#     "Wintermute was a simple cube of white light, that very simplicity
#      suggesting extreme complexity."
#
#                                                                  — Neuromancer

# nix-compile Post-Patch Adversarial Review

**Scope:** All 13 advised edits applied against v2 tarball.
**Method:** Line-by-line spec trace, edge case enumeration, test vector replay.
**Verdict:** 2 bugs found in patch (both fixed below), 5 pre-existing spec deviations, several items to watch for Lean 4 port.


# ══════════════════════════════════════════════════════════════════════════════
#                                                      // bugs introduced by patch
# ══════════════════════════════════════════════════════════════════════════════


## // BUG-1 // extractSimpleVar breaks on ${VAR} input (CRITICAL)

**File:** `lib/NixCompile/Bash/Facts.hs:181-192`

The new guard ordering checks `$`-prefixed strings before `${`-prefixed:

```haskell
extractSimpleVar t
  | "$" `T.isPrefixOf` t
      && not ("$(" `T.isPrefixOf` t) =
      let v = T.drop 1 t
       in if isVar v then Just v else Nothing   -- ← swallows ${VAR}
  | "${" `T.isPrefixOf` t && "}" `T.isSuffixOf` t =
```

`"${VAR}"` starts with `$` and not `$(`, so the *first* guard fires. `T.drop 1 "${VAR}"` = `"{VAR}"`. `isVarChar '{'` = `False`. Returns `Nothing`. The second guard never executes.

**Impact:** Config assignments like `config.server.host=${HOST}` will fail to recognize `HOST` as a variable and instead parse it as a literal string `"${HOST}"`.

**Fix:** Reorder guards to check `${` before `$`. **APPLIED.**

### BUG-2: `parseExpansionBody` loses `Nothing` semantics for empty operator arguments (MINOR)

**File:** `lib/NixCompile/Bash/Patterns.hs:82-89`

The old code used `nonEmpty` to convert empty strings to `Nothing`. The new code uses `T.uncons` which produces `Just ""` for empty values:

```haskell
parseOpWithColon var rest = do
  ...
  Just ('?', msg) -> Just (ErrorIfUnset var (Just msg))
  -- When rest after operator is "", msg = ""
```

So `${VAR:?}` → `ErrorIfUnset "VAR" (Just "")` instead of spec-required `ErrorIfUnset "VAR" Nothing`.

**Impact:** Fails test vector `prop_expansion_test_vectors` line 484:
```
parseParamExpansion "${VAR:?}" === Just (ErrorIfUnset "VAR" Nothing)
```

Functionally benign since `envVarFacts` matches `Just (ErrorIfUnset _var _)` without inspecting the message. But test will fail.

**Fix:** Wrap `?` and `+` operator arguments with `nonEmpty`, but NOT `-` and `=` (where empty string is a meaningful default per spec §8.1). **APPLIED.**

---

## PRE-EXISTING SPEC DEVIATIONS (not introduced by patch)

### SPECDEV-1: Error codes / policy error formatting

RESOLVED: `lint` reports `ALEPH-B001` through `ALEPH-B004`, and the CLI reports
bare and dynamic commands using `ALEPH-B005` and `ALEPH-B006`.

### SPECDEV-2: Error reporting uses AST token IDs, not source locations

**Spec §3.3** says errors MUST include "Source location (file, line, column) — NOT AST node IDs". The patch (edit #10) intentionally changed the wording to say "token N (ShellCheck AST id)" and the README note acknowledges this. But this is a *documented* spec violation, not a resolution. ShellCheck's AST IDs are **not** line numbers.

The `mkSpan` function `Span (Loc n 0) (Loc n 0) Nothing` puts the token ID in the `locLine` field, which is semantically wrong — it's not a line number.

### SPECDEV-3: JSON schema output includes `quoted` field

RESOLVED: SPECIFICATION.md now documents the `quoted` field for config entries.

### SPECDEV-4: `UseAlternate` produces no facts

**Spec §2.1** says `${VAR:+alt}` and `${VAR+alt}` produce "(no type constraint)". The code doesn't generate *any* fact for these patterns — `envVarFacts` has no case for `UseAlternate`. This means the variable won't appear in the schema at all if its only usage is `${VAR:+...}`. This is technically correct per spec but may surprise users.

### SPECDEV-5: `isStorePath` blocks `//` but spec doesn't require it

**Types.hs:271:** `&& not ("//" `T.isInfixOf` t)`. The spec §2.2 only requires blocking `..`. The `//` check is extra-conservative, which is fine for security but not spec-required.

---

## CORRECTNESS AUDIT (PASSING)

### Unification (§1.1) ✓
- `Unify.hs` correctly implements all unification rules
- Occurs check present and correct
- `composeSubst` implements `apply s1 (apply s2 t)` correctly

### Literal Parsing (§2.2) ✓
- Integer bounds checked against Int64 range
- `-` alone correctly produces `LitString`
- Store path traversal blocked
- Empty string produces `LitString ""`

### Config Assignment (§2.3) ✓
- Both dot and array syntax supported
- Quoting semantics preserved in `Quoted`/`Unquoted`
- Path parsing via `T.splitOn "."` with explicit validation (empty segments rejected)

### Command Analysis (§2.4) ✓
- Store paths, dynamic commands, builtins, and bare commands correctly categorized
- Builtin list is comprehensive

### emit-config (§4.2) ✓
- No heredocs used
- `__nix_compile_escape_json` helper added for string escaping
- `cfgQuoted == Just Quoted` forces string treatment (preserves quoting semantics)
- Literal types preserved (ints as ints, bools as bools)

### Security (§5) ✓
- `isVarChar` restricts to `[A-Za-z0-9_]`
- `isNumericLiteral` has length bounds and Int64 range check
- `safeParseInt` uses `Integer` intermediary to avoid overflow
- Store path traversal blocked
- `jsonEscape` handles `"`, `\`, `\n`, `\r`, `\t`

### Nix Infer safe head removal (edit #9) ✓
- `head vars` → `case vars of (typeVar : _) -> ...; [] -> pure ()`
- Correct — avoids partial function crash

### Nix Parse interpolation placeholders (edit #8) ✓
- Store-path interpolations → `/nix/store/__nix_compile_interp_N__`
- Other interpolations → `@__nix_compile_interp_N__@`
- Counter `n` correctly incremented only for `Antiquoted` parts
- Prevents false bare-command detection from `${...}` → `$(INTERP)` confusion

### TCResult in typecheck summary (edit #12) ✓
- `TCOk | TCFail | TCSkip` correctly replaces `Bool`
- Skipped files no longer inflate pass count
- Exit code only fails on `TCFail`

---

## ITEMS FOR LEAN 4 PORT

### 1. Type System Representation
The Haskell types use `Generic`-derived `FromJSON`/`ToJSON`. In Lean 4, use `Decidable` equality and `Repr` for the type language. The `Type` ADT maps directly to an inductive type.

### 2. Substitution as Verified Map
`Subst = Map TypeVar Type` can become `Std.HashMap` or an `AList` with a well-formedness invariant. The `composeSubst` law (INV-4) should be a `theorem`, not just a QC property.

### 3. `parseExpansionBody` as a Verified Parser
The bash parameter expansion grammar (Appendix A ABNF) is regular. In Lean, express it as a decidable parser with totality proof. The `guard`+`Maybe` monad becomes `Option` with explicit pattern matching.

### 4. Occurs Check Proof
`occursIn` is trivial for the flat type language but becomes interesting if Lean 4 types get richer (functions, lists). Should carry a proof that `bindVar` only succeeds when the occurs check passes.

### 5. `ConfigSpec` Field Explosion
The `ConfigSpec` record now has 5 fields (`cfgType`, `cfgFrom`, `cfgQuoted`, `cfgLit`, `cfgSpan`). Some of these are mutually exclusive (var-sourced vs literal-sourced). In Lean, model as a sum type:
```lean
inductive ConfigSource where
  | fromVar (var : String) (quoted : Quoted) (ty : BashType)
  | fromLit (lit : Literal)
```
This makes invalid states unrepresentable.

### 6. Escape Function Correctness
`jsonEscape` should have a theorem that the output contains no unescaped `"` or `\` characters. Express as:
```lean
theorem jsonEscape_no_raw_quotes (s : String) :
  ¬ hasUnescapedQuote (jsonEscape s) := by ...
```

### 7. ShellCheck Dependency
ShellCheck is Haskell-only. For Lean 4, you'll need either:
- FFI to ShellCheck (complex, keeps Haskell dependency)
- A Lean bash parser (significant work, but then it's verifiable)
- An external tool that dumps ShellCheck AST as JSON (pragmatic)

### 8. Property Tests → Lean Proofs
The 14 spec properties (PROP-1 through PROP-14) should become:
- PROP-1,2,3,4: `theorem`s about `unify` and `applySubst`
- PROP-5: `theorem` about `solve`
- PROP-7,8: `theorem`s about roundtrip (literal parse ∘ render = id)
- PROP-9,10,11: totality and termination proofs
- PROP-12,13,14: security `theorem`s

### 9. No `unsafePerformIO`
The test suite imports `System.IO.Unsafe`. Lean 4 separates pure and IO cleanly. All pure functions should live in `def` without `IO`.

### 10. Error Reporting
The `Span` type conflates ShellCheck token IDs with line numbers. For Lean, define a proper `SourcePos` with a `Fin` for the line and column, and keep AST node references separate.

---

## RECOMMENDED FIXES BEFORE LEAN PORT

**Priority 1 (blockers):**
1. Fix `extractSimpleVar` guard ordering (BUG-1)
2. Add `nonEmpty` wrapper in `parseExpansionBody` (BUG-2)

**Priority 2 (spec compliance):**
3. Use `ALEPH-B00N` error codes per spec
4. Map ShellCheck token IDs to actual line numbers (or accept the deviation formally)

**Priority 3 (cleanup):**
5. Remove `.orig` files from tree
6. Remove extra blank lines added by patch hunk in `Facts.hs:336-337`
7. Model `ConfigSpec` as a sum type (var vs literal) to make invalid states unrepresentable

---

## FEATURE: CROSS-LANGUAGE TYPE INFERENCE (v0x02)

**Added:** Cross-language type inference from bash command arguments back to Nix interpolations.

### Motivation

When Nix embeds bash via `writeShellScript`, Nix expressions are interpolated:
```nix
pkgs.writeShellScript "fetch" ''
  curl --connect-timeout "${config.timeout}" "$url"
''
```

Previously, nix-compile treated `${config.timeout}` as an opaque placeholder. Now it infers:
- `config.timeout :: TInt` (from curl's `--connect-timeout` expecting integer)

### Implementation

1. **Placeholder format**: Non-store-path interpolations use `${__nix_interp_N__}` (bash variable syntax) instead of `@...@` (opaque literal). This lets bash fact extraction recognize them as variables.

2. **Index tracking**: `Interpolation` type has `intIndex :: Int` to map back from placeholder names to original expressions.

3. **Type flow**:
   ```
   Nix: ${config.timeout}
     → bash: ${__nix_interp_0__}
     → fact: CmdArg "curl" "--connect-timeout" "__nix_interp_0__" span
     → constraint: TVar "__nix_interp_0__" :~: TInt
     → schema.env["__nix_interp_0__"] :: TInt
     → output: ${config.timeout} :: TInt
   ```

4. **Files changed**:
   - `lib/NixCompile/Nix/Parse.hs`: Placeholder format, `intIndex` field, utilities
   - `lib/NixCompile/Schema/Build.hs`: `extractInterpTypes` function
   - `app/nix-compile.hs`: `mapInterpTypesToNix`, CLI reporting
   - `test/MoreFixtures.hs`: `testCrossLangInference`
   - `test/fixtures/nix/cross-lang-inference.nix`: Test fixture

### Test Coverage

`testCrossLangInference` validates:
- `config.timeout :: TInt` (from `curl --connect-timeout`)
- `config.retries :: TInt` (from `curl --retry`)
- `config.output :: TPath` (from `curl -o`)

### Limitations

1. Only works for commands in the builtins database (curl, wget, ssh, find, parallel, etc.)
2. Requires interpolation at argument position (not embedded in string)
3. Store-path interpolations (`${pkgs.curl}`) use `/nix/store/__nix_interp_N__` format and are typed as `TPath`


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#     "The sky above the port was the color of television, tuned to a dead
#      channel."
#
#                                                                  — Neuromancer

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                                 — b7r6 // 2026
