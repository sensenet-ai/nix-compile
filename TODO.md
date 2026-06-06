# TODO

Rebuilt from scratch on 2026-06-06 against commit `9cd33e2`. Every item below was
re-confirmed by reading the cited `file:line` at HEAD. Findings detail and
evidence live in [REVIEW-3.md](REVIEW-3.md); this file is the actionable work
list. No `FIXED`/`WONTFIX` archaeology — if it's here, it's open.

Severity: **P0** soundness/false-positive (the tool's core promise) · **P1**
test infrastructure that lets P0s hide · **P2** robustness/correctness · **P3**
hygiene/process.

> **Decide the fork first — it sets the scope of everything below.** The 18
> findings reduce to 4 roots (REVIEW-3 §"Root causes & the fork"): RC1 no row
> variables, RC2 no constraint solver, RC3 no differential oracle, RC4 quadratic
> substitution. Either **(A)** downgrade the README claims to "best-effort type
> lint" and do only the point fixes (the P0 items marked *[point]* + most of P2/P3),
> **or (B)** keep the "HM / row-polymorphic / principal" claims and do the
> architectural work (the items marked *[RC1]/[RC2]/[RC3]*). The point fixes are
> rounding error against B. Today the README says B and the code is A.

> **Point fixes applied 2026-06-06 — compile clean AND behavior-verified.** Built
> and run in `nix develop`; the full `nix-compile-test` suite is green, including
> new `review_*` properties for each finding (fixed ones assert correct behavior;
> #2/#6 are `expectFailure` tripwires that flip red when their root cause is fixed).
> Writing the tests surfaced **#19** (below), a latent inference hang. Fixes:
> - #1 nested select — `Infer.hs` `inferSelect` folds the full `NonEmpty` path AND
>   errors on selecting from a concrete non-attrset (was only truncation)
> - #3 `==`/`!=` — no longer unify operands (`Infer.hs` `inferBinary`)
> - #4 `map`/`foldl'`/`concatMap` — added as 2-var schemes (`Infer.hs`
>   `polymorphicBuiltins`); `builtins.*` path still TAny (RC1)
> - #7 `NPlus` — heterogeneous `+`-lattice; keeps var-propagation
> - #12 `lspSafeParse` — `analyzeDepth` walk moved inside the `try`
> - #13 stale `app/nix-compile.hs` doc paths — corrected in `HACKING.md`,
>   `design/pretty-printing.md`
> - #14 `FlakeOutputs` `Eq` — ✅ FIXED: `Eq NExprLoc` exists, so the instance is
>   now a lawful `deriving (Eq)` (the hand-rolled one dropped the NExprLoc fields).
> - #19 **(NEW, found while testing — FIXED)** applying any polymorphic builtin
>   (`head`/`map`/`filter`/…) hung inference: `instantiate` made a self-map
>   `{v ↦ TVar v}` and the chasing `applySubst` looped. Fixed in
>   `Nix/Types.hs applySubst` (self-map = identity). Deeper smell — scheme vars and
>   fresh vars share one `Int` namespace — to be closed in the RC1 rewrite.
> - #8 union-meets-var **does not reproduce** (corrected like #14): `unify` binds
>   the var to the union, so misuse is rejected. Test asserts the correct behavior.

---

## P0 — soundness & false positives (Nix type checker)

*[point]* = standalone fix, correct under either fork. *[RC1]* = only truly fixed
by real row variables (Fork B); under Fork A, document the limitation instead.

- [~] **[RC1] Real row variables** — landed on `main` (see `design/rows.md`):
      `TRec (Map Text (NixType,Bool)) RowTail`, `RowTail = RClosed | ROpen TypeVar`;
      `unifyRec` with open∪open **union accumulation**; selection emits row
      constraints + extends open records. Validated against the oracle.
      **Stages 1–4 DONE**: ADT, row-var plumbing, open∪open accumulation, select
      constraints, and `builtins.<name>` row-polymorphic via a scheme table
      instantiated at the selection site (`attrNames`/`attrValues`/`hasAttr`/
      `getAttr`/`removeAttrs` + precise list builtins). `//` already degrades to
      open (closed-merge stays precise). ☐ Remaining: `import` returns a record
      (#5, cross-module), and an explicit lacks-constraint store (deferred — current
      accumulation stays sound via disjoint field-difference; needed only for
      first-class record extension). (REVIEW-3 RC1, Fork B)
- [x] **[point] Nested attribute selection truncates to one level.** `Infer.hs:792`
      `(attr :| _)` drops the path tail; `x.a.b.c` is typed as `x.a`. Iterate the
      full `NonEmpty` path through `inferSelect`. (REVIEW-3 #1)
      ✅ DONE — `inferSelect` folds the path and errors on selecting from a concrete
      non-attrset. Tests: `review_nested_select_errors`, `review_nested_select_deep_ok`.
- [x] **[RC1] Select on a type variable emits no row constraint.** ✅ DONE (rows
      stage 3). `inferSelect` now emits `α ~ { k : β | ρ }`, and open records
      accumulate fields across selections via the tail var. `(x: x.foo) 5` now
      errors. Tests: `review_select_on_var_constrains`, `review_select_accumulates`,
      `review_select_present_ok`, `review_select_missing_fails`. (REVIEW-3 #2)
- [x] **`x == null` is a false positive.** `Infer.hs:667-668` unify operands;
      `unify'` has no cross-`TNull` case. `==`/`!=` are total in Nix — they must
      not unify. Type both as `_ -> TBool` (optionally still infer operands for
      effect). (REVIEW-3 #3) ✅ DONE — test `review_eq_null_ok`, `review_eq_heterogeneous_ok`.
- [x] **`map`/`foldl'`/`concatMap` were `TAny` (also `getAttr`/`attrValues`/`import`
      — those need rows/IO, still open).** Promoted the three higher-order list
      builtins to real schemes and fixed the false `map`-is-done comment.
      (REVIEW-3 #4) ✅ DONE — tests `review_map_ok`, `review_map_misuse_fails`.
      `getAttr`/`attrValues` remain `TAny` (RC1); `import` is #5 below.
- [x] **`NPlus` rejects legal `1 + 1.5`, `./a + "b"`, `"" + ./a`.**
      `Infer.hs:681-692`. Model `+` over the numeric/path/string lattice instead
      of unifying operands to an identical base. (REVIEW-3 #7) ✅ DONE — tests
      `review_plus_int_float`, `review_plus_path_string`, `review_plus_nonaddable_fails`.
- [x] **#19 (NEW) polymorphic-builtin application hung inference.** Self-map from
      `instantiate` + chasing `applySubst` → ∞ loop on `head`/`map`/`filter`/…
      ✅ DONE — `Nix/Types.hs applySubst` self-map guard; test
      `review_poly_builtin_terminates`. (REVIEW-3 #19)
- [~] **Unions meeting a variable.** REVIEW-3 #8's "never constrains" claim does
      NOT reproduce — `unify` binds the var to the union (test
      `review_union_var_constrains`). Residual: `checkUnionMembership`
      `TVar _ -> pure ()` edge case + `TStrLit` text ignored. Low priority.
- [x] **#8 optionality** ✅ fixed by the rows rewrite — `unifyRec`'s `closeAgainst`
      respects the optional flag. Test `review_optional_open_field_ok`.
- [ ] **`import` cross-module inference is inert.** `Infer.hs:190,550-567`.
      `extractImportPathLiteral` returns the raw source string and only handles
      bare literals; likely misses canonicalized `envImportTypes` keys. Canonicalize
      the lookup key and handle non-literal import args. **First write the failing
      differential test** (two files, importer consumes an imported type error).
      (REVIEW-3 #5)

## P0 — soundness (bash type checker)

- [x] **[RC2] Subtyping order-dependence** ✅ FIXED. `solve` rewritten as
      collect-then-join: union-find over vars, each var resolved to the LUB of its
      concrete constraints in the `{TInt,TBool} <: TNumeric` lattice. `[TInt~a,
      a~TBool]` now resolves `a=TNumeric` order-independently; bare concrete~concrete
      stays strict (TInt/TBool disjoint). Test `review_bash_subtype_resolves`.
      (REVIEW-3 #6, RC2)

## P1 — test infrastructure (highest leverage — do these first)

- [~] **Differential oracle.** ✅ v1 DONE — `test/Oracle.hs`
      (`cabal test nix-compile-oracle`) compares inferred type vs
      `nix-instantiate`'s `builtins.typeOf` over a closed-expression corpus;
      MISMATCH/CHECKER-HANG = failure; skips cleanly without nix. First run: 35
      agree, 0 failures; surfaced #20. ☐ NEXT: generated closed terms (not just a
      corpus), and a bash schema round-trip. (REVIEW-3 #9)
- [ ] **#20 Non-global builtins exposed as global names.** `head`/`filter`/
      `foldl'`/`elemAt`/`length`/… are in the checker's top-level scope but Nix
      provides them only under `builtins.`; bare `head xs` is an undefined var at
      eval, yet the checker types it. Split builtinEnv into true-globals vs
      `builtins.*`-only. (REVIEW-3 #20; found by the oracle)
- [~] **`parse(format(x)) ≅ parse(x)`** property. ✅ DONE for
      `Format`/`annotateSource` (test `review_format_roundtrip` — meaning-preserving,
      green). ☐ STILL OPEN for the reformatter `Formatter.formatNixFile` (the one
      the review faults for collapsing significant whitespace). (REVIEW-3 #16)
- [ ] **Make the benchmark force real output.** `bench/Bench.hs:171-193` wrappers
      return `Bool`, so `nf` leaves the AST/`NixType`/`[Binding]`/violation-list as
      thunks; the dead `Whnf` newtype (89-92) is the tell. Return the real values,
      delete the `Bool` wrappers and `Whnf`, add pathological inputs
      (`attrSet 5000`/`10000`, deep `let`, wide `//`). (REVIEW-3 #18)
- [ ] **Generator can't produce `NSelect`.** `genNixExpr` (`Props.hs:1106-1240`)
      emits no attribute-selection nodes, so #1/#2 are unreachable by QuickCheck.
      Add select/nested-select generation. (REVIEW-3 #11)
- [ ] **Add positive well-typedness properties.** Current Nix-infer props assert
      only no-crash + determinism (`Props.hs:1242,1251`). Add properties that an
      accepted program has the expected type on a curated vector set. (REVIEW-3 #10)

## P1.5 — bugs found by wiring up the dead adversarial suites (now expectFailure tripwires)

`Adversarial.hs`/`NixAdversarial.hs` (58 props) were compiled but never run; wiring
them in surfaced these. Each is an `expectFailure` in Props now — fix flips it green.

- [x] **#21** ✅ `parseConfigValue` validates the var name after `$`/`"$`.
- [x] **#22** ✅ a non-name (`$|`, `$\n; id`) is a literal, not a captured var ref.
- [x] **#23** ✅ `isEvalInvocation` skips command modifiers (command/builtin/…) before checking for `eval`.
- [x] **#24** ✅ array-subscript LHS reconstructed + arith subscript tokens rendered + `parseConfigTemplate` counts all var parts.
- [x] **#25** union membership now flattens nested unions (`checkUnionMembership`).
      Test `nixadv_nix_nested_union` (was an expectFailure tripwire). ✅ DONE
- [x] **#26** ✅ `isMkDerivationCall` checks the last key of the select path.

## P2 — robustness & correctness

- [ ] **`lspSafeParse` only catches WHNF failures.** `LSP/Handlers.hs:98-105`
      `evaluate` returns at the `Either` constructor; lazy hnix bottoms escape the
      `try` and `analyzeDepth e` forces them outside it. `force`/`deepseq` inside
      the `try`. (REVIEW-3 #12)
- [ ] **`mergeConfigSpec _ s2 = s2` silently drops data.** `Types.hs:288` (via
      `Schema/Build.hs:111`). Duplicate config paths lose the first spec with no
      warning. Warn or merge meaningfully.
- [ ] **`isStorePathExpr` prefix-matches `"pkgs"`/`"lib"`.** `Parse.hs:201-202`.
      False positives on `pkgsXml`, `libfoo`, etc. Match whole identifiers.
- [ ] **No input size limit before parse.** `Safety` has `maxRecursionDepth=200`
      (a depth guard) but no byte cap — a multi-GB `.nix` is an OOM vector. Add a
      size check at every parse entry point (SPEC PROP-10).
- [ ] **TOCTOU in file collection.** Canonicalize after listing, not before
      (carried from prior TODO — re-verify in `Module`/`ModuleSystem` before
      acting).
- [ ] **[RC4] Quadratic substitution — MEASURED, confirmed.** Eager `composeSubst`
      (`Nix/Types.hs`) + per-`unify` whole-subst re-apply + chasing `applySubst`.
      The forcing benchmark (`nix-compile-bench -p inferExprWithEnv`, #18) now shows
      the cliff on wide attrsets: 10f=3µs, 100f=96µs, 1000f=8.6ms, **5000f=291ms**
      → 1000→5000 is 5× fields / 34× time ≈ **n^2.2** (super-quadratic). `let`-chains
      are milder (~n^1.3). The fix (still TODO): switch `Subst` to union-find /
      apply-on-read so a bind is O(1) and you don't re-walk the whole substitution.
      Last remaining root cause; perf-only (no correctness impact). (REVIEW-3 #17/#18)

## P3 — hygiene & process

- [ ] **`FlakeOutputs` `Eq` is lawless.** `Flake.hs:89-91` compares only
      `outPackages`, dropping 8 fields. Derive a real `Eq` or rename to an
      explicit `samePackages` predicate. (REVIEW-3 #14)
- [ ] **Two `TypeVar` newtypes share a name.** `Types.hs:92` (wraps `Text`) vs
      `Nix/Types.hs:61` (wraps `Int`). Rename one (e.g. `BashTypeVar`).
- [ ] **`Loc 0 0` sentinels are indistinguishable from real origins.** In
      `Infer/Unify.hs`, `Nix/ModuleSystem.hs`, `Lint/Forbidden.hs`,
      `Bash/Facts.hs`. Move to `Maybe Span`.
- [ ] **`with`/`rec` are inferred but linter-banned — decide and document.**
      `Infer.hs:530-538,852` vs `Nix/Lint.hs`. State "infer models a superset," or
      gate those paths behind `envLenient`. (REVIEW-3 #15)
- [ ] **`show` on internal types leaks into user-facing errors** (e.g.
      `Mismatch TInt TString …`). Use the pretty-printers.
- [ ] **Double AST walk in `checkFile`** (`detectUnsupported` + combined lint
      traverse the same tree). Merge into one pass.
- [ ] **Spec INV-2/INV-3 are aspirational.** Downgrade to goals or annotate known
      exceptions until the differential oracle backs them. (REVIEW-3 M1)
- [ ] **Benchmark baseline.** `bench/NixpkgsBench.hs` exists; establish a
      committed baseline and gate regressions in CI.
- [ ] **Formatter whitespace.** Reformatter collapses consecutive blanks and
      touches `''…''` interiors (semantically significant). Blocked-on / verified
      by the `parse∘format` property above.
- [ ] **Style audit.** File-header ornaments, camelCase, pragma placement drifted
      from the style guide.
