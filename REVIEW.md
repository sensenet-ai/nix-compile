# Adversarial Review — nix-compile

**Scope:** Full source audit of all Haskell modules, spec compliance trace, edge-case enumeration.  
**Date:** 2026-05-31

---

## CRITICAL

### CRITICAL-1: `checkInfinite` false-positive on mutual recursion
**File:** `lib/NixCompile/Nix/Infer.hs:726-735`

`rec { x = y; y = x; }` is incorrectly rejected as "infinite type". Both bindings get fresh vars α, β. After unifying α~β (subst [β→α]), then α~α (trivial — no new subst), `checkInfinite` sees α is still exactly α and throws. The types are merely underconstrained — not infinite. Only `x = x` (occurs check) or `x = x x` should be rejected.

**Fix:** `checkInfinite` should check whether the type variable remains unconstrained *after all other bindings in the same SCC have been processed*, not check each binding in isolation. For mutually-recursive groups, if *any* binding introduces a concrete constraint, the group is well-typed.

---

### CRITICAL-2: `resolveImportPath` drops bare relative paths
**File:** `lib/NixCompile/Nix/Module.hs:367-371`

```haskell
resolveImportPath baseDir path = case path of
    '.' : _ -> normalise (baseDir </> path)
    '/' : _ -> path
    _ -> path          -- BUG
```

`import default.nix` (without `./`) is treated as-is rather than resolved against the base directory. Every bare relative import is silently misrouted.

**Fix:** Treat all paths that do not start with `/` as relative to the base directory.

---

### CRITICAL-3: `processApplication` silently drops the second argument of `import ./path arg`
**File:** `lib/NixCompile/Nix/Module.hs:280-285`

When `import ./path arg` is encountered, `checkImportBuiltin` matches `import` as a bare NSym, then `makeImport baseDir (extractImportPath arg) Nothing srcSpan` captures only the first argument `./path`. The second argument `arg` (which Nix applies to the imported function) is silently discarded.

**Fix:** When `checkImportBuiltin` matches and the match is a bare `import`, the arg structure should be analyzed to separate the path from the additional argument.

---

### CRITICAL-4: `collectTokens` produces zero-length for multi-line semantic tokens
**File:** `lib/LSP/Handlers.hs:514-516`

```haskell
let len = if l == el then ec - c else 0
```

Tokens spanning multiple lines get `rtLen = 0`, corrupting the delta-encoded semantic tokens stream. LSP clients mis-highlight or crash on multi-line expressions.

**Fix:** Compute proper length from `spanEnd` position or use source text when available.

---

## SIGNIFICANT

### BUG-5: LSP rebuilds entire module graph on every request
**File:** `lib/LSP/Handlers.hs:783-793`

`buildCrossEnv` and `buildCrossScopeGraphWith` call `Mod.buildModuleGraph` which parses and typechecks every file in the project — on every hover, go-to-definition, completion, and signature-help request. No caching across LSP requests. A 100-module project has multi-second latency on every hover.

**Fix:** Add an `MVar` or `IORef` cache keyed on `flake.nix` mtime. Invalidate when `didSave` fires on `flake.nix`.

---

### BUG-6: `isEvalInvocation` matches any token containing "eval", not just the command word
**File:** `lib/Lint/Forbidden.hs:89-95`

```haskell
isEvalInvocation tokens = any isEvalToken (map tokenToText tokens)
isEvalToken text = text == "eval" || "/eval" `T.isSuffixOf` text
```

`echo "eval"` or `/nix/store/...-eval/bin/tool` are flagged as eval violations because every token is checked, not just the command word. The `/eval` suffix check is also overly broad.

**Fix:** Check only the first token (the command word). Remove the `/eval` suffix check or restrict it to store-prefixed paths.

---

### BUG-7: `Forbidden.hs` `tokenToText` is incomplete vs `Facts.hs` version
**File:** `lib/Lint/Forbidden.hs:97-101`

Returns `""` for `DoubleQuoted`, `SingleQuoted`, multi-part `NormalWord` tokens. Misses eval calls when the command token is structured differently by ShellCheck.

**Fix:** Reuse or replicate the full `tokenToText` dispatch from `Facts.hs`.

---

### BUG-8: `processParsedFile` writes to stdout unconditionally — spams LSP terminal
**File:** `lib/NixCompile/Nix/Module.hs:200`

```haskell
putStrLn $ "  " ++ path ++ " [" ++ show (length imports) ++ " imports, ...]"
```

Direct `putStrLn` bypasses the katip logging system. When the LSP server calls `buildModuleGraph` to build cross-module env, per-file status lines are written to the terminal the LSP server was launched from.

**Fix:** Remove the `putStrLn` or gate it behind a verbosity flag. LSP paths should emit nothing.

---

### BUG-9: ShellCheck span positions are zero-based but `mkSpan` doesn't adjust
**File:** `lib/NixCompile/Bash/Facts.hs:662-674`

ShellCheck's `Position` uses zero-based line and column indices (`posLine`, `posColumn`), but nix-compile's `Loc` treats these as-is. Nix spans from hnix use megaparsec's `Pos` which is 1-based. Bash diagnostics show line numbers off by one compared to Nix diagnostics in the same file.

**Fix:** Add +1 when converting ShellCheck `posLine`/`posColumn` to `Loc`.

---

## DESIGN ISSUES

### DESIGN-1: Double AST walk on every check
**File:** `lib/NixCompile/CLI/Check.hs:50-54`

`checkFile` calls `detectUnsupportedConstruct` (full tree walk), then `checkWithViolations` calls `Combined.combinedLint` (another full walk of identical structure). The first walk exists only to decide whether to skip type-checking. Two identical traversals.

**Fix:** Integrate `detectUnsupportedConstruct` logic into the combined lint walk, returning a flag alongside violations.

---

### DESIGN-2: `mergeConfigSpec` silently loses data
**File:** `lib/NixCompile/Types.hs:287-288`

`mergeConfigSpec _ spec2 = spec2` — when two facts produce `ConfigSpec` for the same path, only the second survives with no warning. Used via `Map.fromListWith mergeConfigSpec`.

**Fix:** At minimum, emit a warning when a config path is reassigned. Ideally, merge the type information rather than discarding.

---

### DESIGN-3: Two different `TypeVar` types at same module scope level
**Files:** `NixCompile.Types` and `NixCompile.Nix.Types`

`NixCompile.Types.TypeVar` (wraps `Text`, for bash) and `NixCompile.Nix.Types.TypeVar` (wraps `Int`, for Nix) share the same constructor name. Every module importing both must qualify one.

**Fix:** Rename one or both, e.g. `BashTypeVar` and `NixTypeVar`.

---

### DESIGN-4: `emptySpan` sentinel proliferation — ambiguous (0,0) locations
**Files:** `Nix/Infer/Unify.hs:46`, `Nix/Scope.hs:942-943`

At least 3 different "empty span" sentinels cross the codebase. Errors with (0,0) locations are indistinguishable from "no location available". `bindVar`'s errors carry the sentinel span rather than the actual call-site span from `inferSpan`.

**Fix:** Use `inferSpan` state in `bindVar` error paths. Replace sentinel spans with `Maybe Span`.

---

### DESIGN-5: `show` leaked to user-facing error messages
**Files:** `CLI/Bash.hs:64`, `Infer/Unify.hs:102`

`Type error: Mismatch TInt TString (Span (Loc 0 0) (Loc 0 0) Nothing)` is printed directly to users. Data constructor names are Haskell internals.

**Fix:** Add a `prettyTypeError :: TypeError -> Text` function.

---

## PERFORMANCE

### PERF-1: `concatMap` accumulation everywhere without strictness
**Files:** Most lint and traversal modules.

Every recursive tree walk uses `concatMap` or `++` which builds O(n²) thunk chains for deep expressions. `deepseq` is only a test dependency.

**Fix:** Add `{-# LANGUAGE StrictData #-}` or use strict left folds.

---

### PERF-2: O(n) completion filtering per keystroke
**File:** `lib/NixCompile/LSP/Handlers.hs:293`

`Map.filterWithKey` scans all options linearly for prefix matching. No trie, no incremental matcher.

**Fix:** Build a prefix trie from the option set at document open time.

---

## SECURITY

### SEC-1: `isStorePathExpr` false-positives on variable name prefixes
**File:** `lib/NixCompile/Nix/Parse.hs:194-198`

```haskell
isLikelyPackageVar name =
    T.isPrefixOf "pkgs" name || T.isPrefixOf "lib" name || ...
```

Variables named `pkgsXml`, `libraryData`, `librettoPath` are misclassified as store-path interpolations and get `/nix/store/` placeholder prefixes. This corrupts the bash analysis — non-store-path variables are treated as store paths.

**Fix:** Match exact equality or use `elem` against a known set rather than prefix matching.

---

### SEC-2: No input size limits before parsing
**Files:** `Bash/Parse.hs`, `Nix/Parse.hs`

Both `parseBash` and `parseNixFile` load entire files into memory via `TIO.readFile` before parsing. No size check, no streaming. A 1GB Nix file is fully loaded into a single `Text` value.

**Fix:** Add a configurable maximum input size (e.g., 10 MB) checked before `readFile`.

---

### SEC-3: TOCTOU in `collectFiles` — symlink race between `canonicalizePath` and `listDirectory`
**File:** `lib/NixCompile/CLI/CI.hs:242-245`

```haskell
canonical <- canonicalizePath directory
if canonical `Set.member` visited || not (canonicalRoot `isPrefixOf` canonical)
    then ... else do entries <- listDirectory directory
```

A symlink created between `canonicalizePath` and `listDirectory` could point outside the project root. Each entry should be canonicalized individually after listing.

**Fix:** Canonicalize each entry after listing.

---

### SEC-4: Shell injection surface in `emitConfigFunction` — config paths become shell identifiers
**File:** `lib/NixCompile/Emit/Config.hs`

Config path segments become variable names in generated shell code. While `validConfigPath` constrains to `[a-zA-Z0-9_-]+`, a bug in that validation could produce injection-vulnerable output. The printf-based template approach is fragile.

**Fix:** Add an integration test that fuzzes `emitConfigFunction` with arbitrary schemas and verifies output safety.

---

## TEST GAPS

### TEST-1: No property test for `checkInfinite` mutual recursion false-positive
`Nix/Infer.hs`'s `inferRecBinding` rejection of `rec { x = y; y = x; }` is untested. The existing `prop_nix_rec_infinite` only tests `rec { x = x; }`.

### TEST-2: No test for `resolveImportPath` with bare relative paths
Only `./`-prefixed paths are tested implicitly.

### TEST-3: No test for `isEvalInvocation` false-positive
No test verifies that `echo "eval"` does NOT trigger ALEPH-B003.

### TEST-4: No test for multi-line semantic token encoding
`collectTokens` multi-line bug is untested.
