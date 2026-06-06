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
> - #14 `FlakeOutputs` `Eq` — **deferred**: `Flake` derives `Eq` and needs
>   `Eq FlakeOutputs`; the manual instance avoids the `NExprLoc` fields, implying
>   `Eq NExprLoc` may be absent. Deriving could break the build — verify with a
>   compiler first.
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

- [ ] **[RC1] Real row variables** — the architectural item the next three depend
      on. `TAttrsOpen` (`Nix/Types.hs:79`) has no tail var, so a second select
      can't accumulate fields and `unifyAttrsOpenOpen` forgets the union.
      Fork-B design: recursive `Row` + lacks-constraints (Gaster–Jones), Expresso
      (`willtim/Expresso` + `willtim/row-polymorphism`'s
      `AlgorithmW_ConstrainedRows.hs`) as the reference; **read those first**; do
      NOT use `unification-fd` (single-sorted, wrong shape); stand up the oracle in
      the same breath (silent `generalize`/`instantiate` bugs). (REVIEW-3 RC1, Fork B)
- [x] **[point] Nested attribute selection truncates to one level.** `Infer.hs:792`
      `(attr :| _)` drops the path tail; `x.a.b.c` is typed as `x.a`. Iterate the
      full `NonEmpty` path through `inferSelect`. (REVIEW-3 #1)
      ✅ DONE — `inferSelect` folds the path and errors on selecting from a concrete
      non-attrset. Tests: `review_nested_select_errors`, `review_nested_select_deep_ok`.
- [ ] **Select on a type variable emits no row constraint.** `Infer.hs:605`
      falls to `freshVar`; `(x: x.foo) 5` type-checks. Emit `α ~ { foo : β | ρ }`
      (open-row constraint) instead. (REVIEW-3 #2)
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
- [ ] **`unifyAttrsClosedOpen` ignores optionality.** `Infer.hs:384-394` errors
      on a missing *optional* open-row key. Skip optional keys in
      `missingInClosed`. (REVIEW-3 #8)
- [ ] **`import` cross-module inference is inert.** `Infer.hs:190,550-567`.
      `extractImportPathLiteral` returns the raw source string and only handles
      bare literals; likely misses canonicalized `envImportTypes` keys. Canonicalize
      the lookup key and handle non-literal import args. **First write the failing
      differential test** (two files, importer consumes an imported type error).
      (REVIEW-3 #5)

## P0 — soundness (bash type checker)

- [ ] **[RC2] Subtyping via empty-substitution is order-dependent + incomplete.**
      `Infer/Unify.hs:36-40,62-69`. `[TInt ~ α, α ~ TBool]` is rejected though
      `α = TNumeric` satisfies it; reordering changes the result. Needs a real
      constraint phase (collect, then compute meets/joins) — the same solver that
      RC2 buys for union-membership and `//`. Or, under Fork A, drop the `TNumeric`
      supertype. (REVIEW-3 #6, RC2)

## P1 — test infrastructure (highest leverage — do these first)

- [ ] **Differential oracle.** Generated/corpus Nix: `accept ⟹ nix-instantiate
      --eval has no type error; reject ⟹ it errors`. Bash: schema round-trip.
      Catches most P0s automatically. (REVIEW-3 #9) — `process` dep already
      present (used by `bench/`).
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
- [ ] **[RC4, conditional] Quadratic substitution.** Eager `composeSubst`
      (`Nix/Types.hs:116-118`) + per-`unify` whole-subst re-apply
      (`Infer.hs:300-304`) + chasing `applySubst` (`Nix/Types.hs:122-126`) →
      O(n²) on wide attrsets / long chains. **Measure first** (needs a real box +
      a forcing benchmark); only switch `Subst` to union-find if the curve
      confirms it. Orthogonal to RC1/RC2 — do it last. (REVIEW-3 #17)

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
