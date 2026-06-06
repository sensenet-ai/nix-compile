# Adversarial Review — nix-compile (round 3, validated)

**Date:** 2026-06-06
**Commit:** `9cd33e2` (`// nix-compile // a number of fixes //`)
**Method:** Static review only. No GHC in this environment — nothing was compiled
or run. Every finding below was checked by reading the named `file:line` at HEAD.
**Provenance note:** This document supersedes and replaces `REVIEW.md`,
`REVIEW-2.md`, `BUGS.md`, `FIXES.md`, and the `session-*.md` logs, which were
deleted because their line citations were stale and their `FIXED`/`WONTFIX`
status tags were no longer verifiable against the source (see §M2).

This round began as a validation pass over an *external* adversarial review.
That review was written against a **different tree** than HEAD (its `Infer.hs:792`,
`Props.hs` at 4513 lines, `app/Main.hs`, `LSP/Handlers.hs` line up only after the
last pull). Each finding is re-anchored to HEAD and given a verdict. Where the
external review's specifics diverge from this tree, that is called out.

---

## Verdict table

| #  | Finding | Anchor (HEAD) | Verdict |
|----|---------|---------------|---------|
| 1  | Nested attribute select truncated to one level | `Infer.hs:792` | **CONFIRMED** |
| 2  | Select on a type variable emits no row constraint | `Infer.hs:605` | **CONFIRMED** |
| 3  | `==`/`!=` unify operands → false positive on `x == null` | `Infer.hs:667-668` | **CONFIRMED** |
| 4  | `TAny` is a universal escape hatch; `map`/`foldl'`/`concatMap`/`getAttr`/`attrValues`/`import` still `TAny` (comment claims otherwise) | `Infer.hs:313-314,162-165` | **CONFIRMED** |
| 5  | `import : TPath → TAny`; literal-path lookup keyed by raw source string | `Infer.hs:190,550-567` | **CONFIRMED** (structural) |
| 6  | Bash unifier: subtyping via empty-subst is order-dependent + incomplete | `Infer/Unify.hs:36-40,62-69` | **CONFIRMED** |
| 7  | `NPlus` rejects legal `1 + 1.5`, `./a + "b"` | `Infer.hs:681-692` | **CONFIRMED** (this tree) |
| 8  | Union never constrains a var; `TStrLit` text ignored; closed/open ignores optional | `Infer.hs:409,320,384-394` | **CONFIRMED** |
| 9  | No differential oracle (accept ⟹ evaluates / reject ⟹ fails) | `test/`, `cabal` | **CONFIRMED** |
| 10 | Property suite dominated by no-crash / determinism | `Props.hs:1242,1251,2900` | **CONFIRMED** |
| 11 | `genNixExpr` cannot produce selection nodes → #1 unreachable by generator | `Props.hs:1106-1240` | **CONFIRMED** |
| 12 | `lspSafeParse` `evaluate` is WHNF-only; deep thunk failures escape the `try` | `LSP/Handlers.hs:98-105` | **CONFIRMED** |
| 13 | Trackers cite a nonexistent `app/nix-compile.hs` (real: `app/Main.hs`) | `BUGS.md`, `FIXES.md` | **CONFIRMED** |
| 14 | `FlakeOutputs` `Eq` is lawless/lossy | `Flake.hs:89-91` | **PARTIAL** — see §14 |
| 15 | Checker fully models `with`/`rec`, which the linter bans | `Infer.hs:530-538,852` | **CONFIRMED** (by-design tension) |
| 16 | Formatter stamps (often unsound) annotations; no `parse∘format` property; whitespace collapse | `Props.hs:2879-2923`, `Formatter.hs` | **CONFIRMED** |
| 17 | Inference is naive-`Map` HM: eager `composeSubst` + chase + per-`unify` re-apply → quadratic on wide attrsets / long chains | `Nix/Types.hs:116-126`, `Infer.hs:270-304` | **CONFIRMED** |
| 18 | Benchmark forces only `Bool` (results stay thunks); dead `Whnf`; inputs too narrow to hit the cliff | `bench/Bench.hs:89-92,171-193` | **CONFIRMED** |
| 19 | **Applying ANY polymorphic builtin hangs inference** — `instantiate` self-map + chasing `applySubst` → ∞ loop | `Nix/Types.hs:122-126`, `Infer.hs:480-484` | **NEW — found while testing; FIXED** |
| 20 | Checker exposes `head`/`filter`/`foldl'`/`elemAt`/… as GLOBAL names; Nix only provides them under `builtins.` (bare `head` is an undefined var at eval) | `Infer.hs:128-137` (`polymorphicBuiltins`) | **NEW — found by the oracle; open** |

Net: 16 confirmed as stated, 1 confirmed against the current tree where the
external review described older behavior (#7), 2 partial where the external
review's specific claim is factually wrong for this tree (#14 `Eq`, #8
union-meets-var — see below). Zero findings refuted in a way that made the code
correct. **One new bug (#19) surfaced the moment a test actually applied a
polymorphic builtin and forced the result — exactly the class the review predicted
the un-forcing test suite was hiding.**

> **#8 correction.** The review said a union meeting a *variable* adds no
> constraint, so `(x: toString x) { a = 1; }` would be wrongly accepted. It is in
> fact correctly **rejected**: `unify'` hits its `(t, TVar v) -> bindVar` arm
> *before* `unifyUnion`, so the variable is bound to the whole union and the later
> application catches the mismatch. The residual `checkUnionMembership`
> `TVar _ -> pure ()` ([Infer.hs:409](lib/NixCompile/Nix/Infer.hs#L409)) is a narrow
> edge case, not the broad hole described. Like #14, overstated against this tree.
> (The `TStrLit`-ignores-text and closed/open-ignores-optional sub-parts of #8 do
> stand.)

---

## Soundness — accepts programs that type-error at runtime

### 1. Nested attribute selection is truncated to one level — CONFIRMED

[`Infer.hs:792`](lib/NixCompile/Nix/Infer.hs#L792):

```haskell
NSelect mDef base (attr :| _) -> inferSelect environment base attr (isJust mDef)
```

hnix represents `x.a.b.c` as a single `NSelect` whose `NonEmpty` path holds
`a :| [b, c]`. `(attr :| _)` keeps `a` and discards `b, c`. So `x.a.b.c` is typed
as `x.a`; the remaining selections are never checked. If `x.a : TInt`, then
`x.a.b.c : TInt` and the genuine error ("cannot select `b` from an Int") is never
produced. Violates SPEC INV-2 and poisons LSP hover/go-to-def on every dotted
path.

### 2. Selection on a variable emits no row constraint — CONFIRMED

[`inferSelect`, `Infer.hs:592-605`](lib/NixCompile/Nix/Infer.hs#L592). When the
base resolves to `TVar`, the case falls to `_ -> freshVar` (line 605) with no
constraint recorded. So `x: x.foo` infers `α → β` with no requirement that `α`
be an attrset containing `foo`. `(x: x.foo) 5` type-checks. A real
HM-with-rows engine would emit `α ~ { foo : β | ρ }`. The inferred type is
strictly more permissive than principal → unsound and falsifies both the "row
polymorphism" and "principality" (INV-3) claims in one shot.

### 4. `TAny` remains a universal escape hatch; comment claims a fix that isn't there — CONFIRMED

[`Infer.hs:313-314`](lib/NixCompile/Nix/Infer.hs#L313): `(TAny, _) -> pure ()` /
`(_, TAny) -> pure ()`. The comment at
[`Infer.hs:122-125`](lib/NixCompile/Nix/Infer.hs#L122) states the polymorphic
builtins are "now real schemes, so misuse fails." Only **six** are
([`polymorphicBuiltins`, 128-137](lib/NixCompile/Nix/Infer.hs#L128)): `head`,
`tail`, `length`, `elemAt`, `filter`, `concatLists`. The comment explicitly names
`map` as fixed, but `map`, `foldl'`, `concatMap`
([162-165](lib/NixCompile/Nix/Infer.hs#L162)), `getAttr`, `attrValues`, `import`
remain `TAny`-typed. `builtins.map (x: x + 1) ["a" "b"]` type-checks. `map` is
the most-used higher-order builtin and is not fixed; the comment is misleading.

### 5. `import : TPath → TAny` makes cross-module inference largely inert — CONFIRMED (structural)

[`Infer.hs:190`](lib/NixCompile/Nix/Infer.hs#L190). The intercept
[`inferAppWithImport`, 550-559](lib/NixCompile/Nix/Infer.hs#L550) only recovers a
real type when (a) the argument is a bare literal path/string —
[`extractImportPathLiteral`, 562-567](lib/NixCompile/Nix/Infer.hs#L562) returns
the **raw source string** (`./foo.nix`) and fails on `import ./${x}.nix`,
`import (./. + "/f.nix")`, `let p = …; in import p` — **and** (b) `lookupImport`
hits. `envImportTypes` is a `Map FilePath NixType`; if the module graph keys it by
canonicalized absolute path while `extractImportPathLiteral` yields the raw
relative string, the lookup misses and inference falls back to the `TAny`
builtin. *Caveat:* the key-mismatch half needs a runtime test to confirm
end-to-end (no GHC here); the raw-string extraction and `TAny` fallback are
confirmed by reading. **Action item: differential test two files where the
importer consumes a type error from the imported file.**

### 8. Unions never constrain a variable; minor type-erasure cases — CONFIRMED

[`unifyUnion`, 399-411](lib/NixCompile/Nix/Infer.hs#L399):
`checkUnionMembership` has `| TVar _ <- t' = pure ()` (line 409). So `toString`
(`TUnion[TInt,TFloat,TBool,TPath,TString] → TString`) applied to a variable adds
no constraint. `toString {a = 1;}` type-checks. Unions only bite against
already-concrete types. Related:

- [`Infer.hs:320`](lib/NixCompile/Nix/Infer.hs#L320): `(TStrLit _, TStrLit _) ->
  pure ()` ignores the carried text — `TStrLit "a" ~ TStrLit "b"` succeeds.
  Decorative singleton type, not a literal type.
- [`unifyAttrsClosedOpen`, 384-394](lib/NixCompile/Nix/Infer.hs#L384):
  `missingInClosed` is computed without consulting the optional-field `Bool`, so
  an open row demanding an *optional* key the closed set lacks still errors.

---

## Incompleteness — rejects programs that evaluate fine (false positives)

### 3. `==` / `!=` unify their operands — CONFIRMED

[`Infer.hs:667-668`](lib/NixCompile/Nix/Infer.hs#L667):

```haskell
NEq  -> unify leftT rightT >> pure TBool
NNEq -> unify leftT rightT >> pure TBool
```

In Nix, `==` is total over all values and never type-errors. `unify'` has no
cross-`TNull` case (only `(TNull, TNull)` at
[`Infer.hs:324`](lib/NixCompile/Nix/Infer.hs#L324)), so `x == null` with
`x : TInt` falls to `_ -> typeMismatch`. That is the single most idiomatic guard
in nixpkgs, reported as an error. Large false-positive surface on real Nix.

### 7. `NPlus` rejects legal heterogeneous `+` — CONFIRMED (this tree)

[`Infer.hs:681-692`](lib/NixCompile/Nix/Infer.hs#L681) unifies both operands, then
inspects the resolved type. Nix permits `1 + 1.5` (→ Float), `./a + "b"`
(path+string), `"" + ./a`. Each needs `unify TInt TFloat` / `unify TPath TString`,
which fail (base types unify identical-only). So legal `+` across numeric/path/
string mixes is now rejected. (The external review framed this as a regression
from an older "accept any `(t, t)`" version; on this tree the over-strict
behavior is present as described.)

---

## Bash type layer

### 6. Subtyping-as-empty-substitution is order-dependent and incomplete — CONFIRMED

[`Infer/Unify.hs:36-40`](lib/NixCompile/Infer/Unify.hs#L36) handles `TNumeric`
against `TInt`/`TBool` by returning `emptySubst`, and
[`solve = foldM`](lib/NixCompile/Infer/Unify.hs#L62) folds left.

- `[TInt ~ α, α ~ TBool]`: first binds `α ↦ TInt`; second becomes `TInt ~ TBool`
  → `Mismatch`. But the set is satisfiable with `α = TNumeric`. → **incomplete**
  (rejects a well-typed program).
- Reorder to `[TNumeric ~ α, α ~ TInt]`: accepts with `α = TNumeric` even though
  `α` was also constrained `= TInt`. → **order-dependent, non-principal**.

This is the classic "subtyping does not fit syntactic unification" trap. SPEC
PROP-5 states its invariant "modulo TNumeric compatibility" — the carve-out is
exactly the shape of the bug, so the property proves nothing about the case that
breaks.

---

## Test methodology — why the above survived

### 9. No differential oracle — CONFIRMED

Nothing in `test/` (or `lib/`) shells out to `nix-instantiate --eval` or to bash
to check that accepted programs evaluate and rejected ones fail. The `process`
dependency exists in the cabal file but is used only by `bench/NixpkgsBench.hs`,
not for an oracle. For a type checker, `accept(p) ⟹ p does not type-error at
runtime` is *the* property, and it is the one absent. INV-2/INV-3 are asserted in
the spec and verified nowhere.

### 10. Property suite is dominated by no-crash / determinism — CONFIRMED

[`prop_nix_infer_no_crash`, 1242](test/Props.hs#L1242) asserts only that the
result is a `Left` or a forceable `Right`.
[`prop_nix_infer_deterministic`, 1251](test/Props.hs#L1251) asserts `f x == f x`.
No positive property asserts that an accepted program is well-typed.

### 11. The generator cannot reach the select bugs — CONFIRMED

[`genNixExpr`, 1106-1240](test/Props.hs#L1106) produces atoms, lists, attrsets,
let, lambda, if, app, binop, concat, merge, with, rec — but **no
attribute-selection node** (`NSelect`). Finding #1 (nested select) is structurally
unreachable by the generative suite. `test/Psychotic.hs` builds `a.x.x…` by hand
but asserts no-crash only.

---

## Robustness

### 12. `lspSafeParse`'s graceful guarantee is false for lazy failures — CONFIRMED

[`LSP/Handlers.hs:98-105`](lib/NixCompile/LSP/Handlers.hs#L98):

```haskell
lspSafeParse txt = unsafePerformIO $ do
    r <- try (Exc.evaluate (parseNixTextLoc txt))
    pure $ case r of
        ...
        Right (Right e) -> case Safety.analyzeDepth e of   -- forced OUTSIDE the try
            ...
```

`evaluate` forces only to WHNF — it gets the `Either`/`NExprLoc` constructor. Any
partial pattern or bottom buried in the lazy hnix interior escapes the `try` and
detonates when `analyzeDepth e` (line 103, outside the `try`) or a downstream
handler forces it. The docstring promises the server "responds gracefully instead
of crashing"; for deep/lazy failures it will not. Fix: `force`/`deepseq` (or a
`NFData` evaluate) *inside* the `try`.

---

## Performance

The build runs fine on the dev box (32 cores / 91 GiB / 419 GB free; the full
dependency closure is in the Nix store and the library compiles clean — the
point fixes below were verified to compile under `-Wall -Werror`). The earlier
"cannot build" wall was a *separate constrained review sandbox* (1 core / 3.9 GiB
/ ~10 GB overlay), not this repo's environment. What is still missing is
*runtime numbers* — no one has run a forcing benchmark on large inputs yet — but
the scaling shape is readable from source and is not reassuring.

### 17. Inference is naive-`Map` HM → super-linear — CONFIRMED

`type Subst = Map TypeVar NixType` with eager composition
([`Nix/Types.hs:116-118`](lib/NixCompile/Nix/Types.hs#L116)):

```haskell
composeSubst s1 s2 = Map.map (applySubst s1) s2 `Map.union` s1
```

and every bind composes a singleton over the whole accumulated substitution
([`Infer.hs:270-272`](lib/NixCompile/Nix/Infer.hs#L270)):

```haskell
addSubst v t = modify $ \s -> s{ inferSubst = composeSubst (singleSubst v t) (inferSubst s) }
```

So each bind re-walks the entire substitution (O(k·m) for k entries, range size
m → O(n²·m) over n binds). On top of that, `unify` re-applies the *whole*
substitution to *both* operands on entry
([`Infer.hs:300-304`](lib/NixCompile/Nix/Infer.hs#L300)) and recurses back through
`unify` structurally, and `applySubst`'s `TVar` case *chases*
(`Just t -> go t`, [`Nix/Types.hs:122-126`](lib/NixCompile/Nix/Types.hs#L122)).
This is the textbook HM scaling trap that union-find + path compression exists to
avoid. It bites on **wide flat attrsets and long binding chains** — exactly the
shape of nixpkgs modules. Small/narrow expressions are fine; the cliff is at
scale, which is where this tool is aimed.

*Conditional severity:* if real inputs never get wide enough, immutable-`Map` is
acceptable and this is ignorable. You can only know by measuring — which needs a
box that can build it (§Performance preamble) and a benchmark that actually
measures (#18).

### 18. The benchmark cannot see #17 — CONFIRMED

Two independent reasons the existing harness prints reassuring numbers that don't
mean what they look like:

- **It doesn't force results.** `parseStr`/`analyzeWHNF`/`inferWHNF`/`lintWHNF`/
  `safetyPipelineResult` all return `Bool`
  ([`bench/Bench.hs:171-193`](bench/Bench.hs#L171)). `nf` on a `Bool` forces the
  wrapped `Either` only to its outer constructor — for parse that's
  `Right <thunk>`, leaving the whole AST spine unevaluated; for infer it runs the
  solve control-flow but leaves the materialized `NixType` and `[Binding]` as
  thunks; for lint it leaves the violation list unforced. The comment at
  [`Bench.hs:80`](bench/Bench.hs#L80) claims the AST is forced; the
  `parseNixExpr` group does not. The tell: a `newtype Whnf` with
  `rnf (Whnf _) = ()` ([`Bench.hs:89-92`](bench/Bench.hs#L89)) is defined "because
  tasty-bench's `nf` requires it" and then **never used** — the no-op-`NFData`
  dodge, with the `Bool` wrappers doing the same job by another route.
- **Inputs are too small and narrow.** Largest infer fixture is `attrSet 100` /
  `mixed-50`, producing tiny result types. Nothing generates a 10k-field attrset
  or a 500-deep `let`, so even with proper forcing the quadratic term never
  dominates.

Fix before trusting any number: make the benches `nf` the real output (return the
`NixType` / violation list; delete the `Bool` wrappers and the dead `Whnf`); add
pathological inputs (`attrSet 5000`/`10000`, deep `let`, wide `//`); run
`NixpkgsBench` against genuinely large real `.nix` files.

## Found while writing the tests

### 19. Applying any polymorphic builtin hangs inference — NEW, FIXED

Writing a property that actually *applies* a `polymorphicBuiltins` entry and forces
the result (`head [ 1 ]`, `map (x: x + 1) [ 1 ]`, `filter`, `foldl'`, …)
immediately deadlocked inference in a CPU-bound infinite loop.

Root cause, two pieces:

1. `instantiate` ([Infer.hs:480-484](lib/NixCompile/Nix/Infer.hs#L480)) draws its
   fresh vars from the same `0,1,…` supply that the builtin schemes use for their
   quantified vars (`scheme1`/`scheme2` literally use `TypeVar 0`/`TypeVar 1`). At
   a top-level call the supply is still low, so a "fresh" var equals a quantified
   var and `instantiate` builds the self-referential substitution
   `{ TypeVar 0 ↦ TVar (TypeVar 0) }`.
2. `applySubst`'s `TVar` arm chased (`Just t -> go t`,
   [Nix/Types.hs:122-126](lib/NixCompile/Nix/Types.hs#L122)). On a self-map that
   recurses forever.

`map` *alone* didn't hang only because the type was returned lazily and never
forced; *applying* it forces unification → loop. **This is precisely the failure
class REVIEW-3 #18/#9 predicted**: the existing ~4,500-line suite never applied a
polymorphic builtin and never forced an inferred type, so a total-inference-hang
(a DoS on every `head`/`map`/`filter` use site) sat latent.

**Fix:** `applySubst` now treats a self-map as the identity (semantically correct;
can only convert a former hang into termination). Regression test
`review_poly_builtin_terminates` forces the result so any re-introduction fails
fast. The deeper smell — scheme-quantified vars and inference fresh vars sharing
one `Int` namespace — remains and should be closed in the RC1 rewrite (give rows /
schemes a disjoint var supply).

### 20. Non-global builtins exposed as global names — NEW (from the oracle), open

The differential oracle (below) flagged `head [ 1 2 ]` as *typed-but-doesn't-eval*:
the checker accepts it (the `polymorphicBuiltins` map and the `builtinsTypes` map are
folded into the top-level `builtinBindings`, so `head`/`tail`/`filter`/`foldl'`/
`elemAt`/`length`/`concatLists`/`concatMap`/`stringLength`/… are in scope as bare
names), but Nix's *global* scope contains only a small set (`map`, `toString`,
`import`, `throw`, `abort`, `removeAttrs`, `isNull`, `baseNameOf`, `dirOf`,
`derivation`, …). Bare `head xs` is `error: undefined variable 'head'` at eval.

So the checker over-accepts: it types programs that don't evaluate. Not a *type*
unsoundness (it's a scope error), but a real accept/reject divergence from Nix.
Fix: split the builtin env into the true globals vs. the `builtins.*`-only set, and
only put the globals in the top-level scope. (Found on the oracle's first run —
exactly what it's for.)

## The differential oracle (REVIEW-3 #9 — now built)

`test/Oracle.hs` (`cabal test nix-compile-oracle`) compares each inferred type
against `nix-instantiate --eval` via `builtins.typeOf`. MISMATCH (claimed kind ≠
runtime kind) and CHECKER-HANG are failures; conservative rejections and
runtime-error-but-typed are tallied, not failed. It SKIPS cleanly (exit 0) when
`nix-instantiate` is absent (the sandboxed flake check), and does real work in the
dev shell / nix-capable CI. First run: 35 agree, 2 agree-reject, **0 failures**,
and it surfaced #20. This is the harness the RC1 row rewrite will be validated
against (silent `generalize`/`instantiate` bugs only show up here).

## Found by wiring up the dead test modules

`test/Adversarial.hs` (26 props) and `test/NixAdversarial.hs` (32 props) were
compiled as test `other-modules` but **never imported or run** (only `Psychotic`
and `ProjectCacheSpec` were wired in). Wiring all 58 in: 50 pass, 8 fail — 6 real
bugs and 2 bad tests. The 6 bugs are now `expectFailure` tripwires in
`Props.hs` (flip red when fixed); the 2 bad tests were dropped.

- **#21** config parser accepts `$|` as a variable reference (counterexample `"|"`):
  `parseConfigAssignment` doesn't validate the var name after `$`.
- **#22** config var-ref captures `;`/newline (counterexample `"\n; id\n"`) —
  injection-relevant; same family as the C1 default-injection finding.
- **#23** `eval` behind a prefix (`command eval …`, `builtin eval …`) is not
  detected as the `eval` violation — the lint only checks the leading word.
- **#24** no `ConfigTemplate` fact for a multi-interpolation array config
  (`config[server]="${HOST:-localhost}:${PORT:-8080}"`).
- **#25** union membership doesn't flatten nested unions
  (`unify (TUnion [TUnion [TInt,TBool], TString]) TInt` is rejected though `TInt`
  is a member). One-line fix in `checkUnionMembership` (flatten before `elem`).
- **#26** the derivation linter misses `mkDerivation` reached through a deep
  select chain (`pkgs.llvmPackages.stdenv.mkDerivation { … }`).

**Two bad tests dropped** (asserted wrong behavior; current code is correct):
`nix_row_empty_open_any` wanted `unify (TAttrsOpen {}) TInt` to *succeed* (unsound
— a record is not an Int); `bash_lint_eval_store_path` wanted a store-path binary
literally named `eval` flagged as the `eval` builtin (a different command — false
positive).

## Process / trust

### 13. Tracker docs cited a nonexistent source file — CONFIRMED

The (now-deleted) `BUGS.md` had 5 references and `FIXES.md` 2 references to
`app/nix-compile.hs`, and zero to the file that actually exists, `app/Main.hs`.
Every line citation in those artifacts was therefore unverifiable. This is the
core reason for the wholesale deletion (§M2). For this tree the external
reviewer's claim "the file is `app/Main.hs`" is correct.

### 14. `FlakeOutputs` `Eq` is lawless/lossy — PARTIAL

[`Flake.hs:89-91`](lib/NixCompile/Nix/Flake.hs#L89):

```haskell
instance Eq FlakeOutputs where
    a == b = outPackages a == outPackages b
```

The latent-trap point is **valid**: a hand-rolled field-dropping `Eq` means any
future `nub`/dedup over flakes conflates structurally distinct outputs, and
`-Wall` will never flag it. **But the external review's specific claim is wrong
for this tree**: it says the code "now compares five fields" and that BUGS.md's
"only `outPackages`" description is stale. In fact this tree compares **only
`outPackages`** (one field), which *matches* what BUGS.md said. The reviewer was
looking at yet another version. Recommended fix is unchanged: derive a real
`Eq`, or rename to an explicit `samePackages` predicate so the partiality is
visible at call sites.

---

## Design coherence

### 15. The checker fully models constructs it bans — CONFIRMED (tension, not a bug)

[`inferWith`, 530-538](lib/NixCompile/Nix/Infer.hs#L530) (with a memoized field
resolver) and [`inferRecursiveBindings`, 852](lib/NixCompile/Nix/Infer.hs#L852)
implement `with` and `rec` semantics, both unconditionally forbidden per SPEC
§3.2 (ALEPH-N001/N002, enforced in `Nix/Lint.hs`). This is defensible — inference
and linting are separate passes, and modeling banned forms lets the checker stay
useful on not-yet-clean code — but it should be a stated decision, not silent.
Either document "infer models a superset of the accepted language," or gate the
`with`/`rec` inference paths behind `envLenient`.

### 16. The formatter stamps unsound annotations and is unprotected by any semantic property — CONFIRMED

Two formatters exist:
[`Format.formatFile`](lib/NixCompile/Nix/Format.hs) →
[`Pretty.annotateSource`](lib/NixCompile/Nix/Pretty.hs) injects `# ::` type
comments; [`Formatter.formatNixFile`](lib/NixCompile/Nix/Formatter.hs) is the
reformatter wired into `fmt` ([`CLI/Dispatch.hs:76`](lib/NixCompile/CLI/Dispatch.hs#L76)).

- The injected `# ::` annotations come from the inference engine audited above, so
  they will frequently be wrong (findings #1–#8).
- There is **no** `parse(format(x)) ≅ parse(x)` property. The format properties
  are [`Props.hs:2879-2923`](test/Props.hs#L2879):
  `prop_format_no_crash` asserts only `T.length output >= T.length src`
  ([2904](test/Props.hs#L2904)); `prop_format_preserves` asserts only
  `"42" isInfixOf output` ([2889](test/Props.hs#L2889)). Neither checks meaning.
- The reformatter "collapses too much whitespace" (self-admitted in the old
  TODO). In Nix, `''…''` indented-string interior whitespace is semantically
  significant, so a formatter that touches it changes program meaning. For a
  formatter that is the cardinal sin, and it is currently untested.

---

## What is actually fine (calibration)

- Occurs check is present and correct on both unifiers
  ([`Infer.hs:349`](lib/NixCompile/Nix/Infer.hs#L349),
  [`Unify.hs:56`](lib/NixCompile/Infer/Unify.hs#L56)).
- Let-generalization via SCC (`stronglyConnComp`,
  [`Infer.hs:1012`](lib/NixCompile/Nix/Infer.hs#L1012)) exists; `instantiate`
  freshens correctly.
- Depth guard (`Safety.analyzeDepth`, cap 200) and store-path traversal guards
  landed.
- `-Wall -Werror -Wincomplete-*` is on.
- Module structure is clean; the bash fact-extraction layer is more careful than
  the Nix type layer.

The engineering hygiene is good. The gap is that the central technical claims —
sound HM, row polymorphism, principality — are marketing relative to what the
code does, and the test suite is shaped so the gap cannot surface.

---

## Meta

### M1. The spec's INV-2 / INV-3 are aspirational, not enforced

SPECIFICATION asserts soundness (INV-2) and principality (INV-3). Findings #1,
#2, #4, #8 each construct an accepted program that is ill-typed (INV-2), and #2
exhibits a strictly-more-general-than-principal result (INV-3). Until a
differential oracle exists, these should be downgraded in the spec to "goals" or
annotated with their known exceptions.

### M2. Why the prior docs were deleted

`REVIEW.md`, `REVIEW-2.md`, `BUGS.md`, `FIXES.md`, and three `session-*.md` logs
were removed in the same change that added this file. Their `file:line` citations
no longer resolved (e.g. `app/nix-compile.hs`, §13) and their `FIXED`/`WONTFIX`
tags could not be trusted without re-reading source — which defeats a tracker.
Live, verified-at-HEAD findings now live here; actionable work lives in
[`TODO.md`](TODO.md).

---

## Root causes & the fork

Counting findings by symptom is the wrong denominator: the 18 above are
surfacings of **four roots**. Point-fixing symptoms without naming the root is
whack-a-mole that won't converge, because the type system cannot express what the
docs claim, so every refactor regrows the same family.

| Root | What's missing | Symptoms it produces | Point-fixable? |
|------|----------------|----------------------|----------------|
| **RC1** | **No row variables.** `TAttrsOpen` is `Map Name (Type, Bool)` with *no tail var* ([`Nix/Types.hs:79`](lib/NixCompile/Nix/Types.hs#L79)), so a second select can't accumulate "also has bar" — `unifyAttrsOpenOpen` checks the intersection and forgets the union. | #1, #2, #8; the README "row polymorphism" claim | **No** — this is building the advertised feature |
| **RC2** | **No constraint solver.** Inference is immediate unification folded over a list ([`Unify.hs:62-69`](lib/NixCompile/Infer/Unify.hs#L62)), so it can't defer/relate constraints. | #6 (order-dependent bash subtyping), #8 (union can't constrain a var), and the eventual `//`/union-membership cases | **No** — architectural |
| **RC3** | **No differential oracle.** Nothing generates well/ill-typed programs and checks accept⟹evaluates / reject⟹fails. | Why #1–#8 existed *and survived ~4,500 lines of tests* | **No** — net-new infra |
| **RC4** | **Quadratic substitution** (eager `composeSubst` + chase). | #17 | **Conditionally** — ignorable if real inputs never get wide; measure first |

The point-fixable set is real and worth doing: #3 (`==`→`TBool`, two lines),
#7 (`+` cross-type arms, ~ten lines), the rest of #4 (`map`/`foldl'`/`concatMap`
→ schemes), #12 (`force` in the `try`), #13 (path find/replace), #14 (`Eq`),
#16/#18 (force the bench), #1 (fold the whole `NSelect` path). That's ~half the
findings by count and none are hard. **But the load-bearing findings sit on RC1–RC3**,
and finishing the easy half yields a checker that passes its existing suite and is
still unsound, still non-principal, still has no row polymorphism, still goes
quadratic on wide attrsets.

### The decision is a fork (this is the repo owner's call, not a code change)

- **Fork A — match the claims to the code.** Drop "Hindley-Milner,"
  "principality," "row polymorphism" from the README; call it a best-effort type
  *lint*. Then the point fixes above are exactly the right scope and you ship a
  useful, modest, honest tool. Cheap.
- **Fork B — keep the claims.** Then you owe RC1 (real rows) + RC2 (constraint
  solver) + RC3 (oracle), and the point fixes are rounding error against that.

What is *not* legitimate is the current state, where the README describes Fork B
and the code is Fork A. The base-rate argument cuts toward deciding deliberately:
this many soundness holes were found by reading alone, single-threaded, unable to
compile — the visible bugs are a sample, not the population.

### If Fork B — design notes (external research; not independently verified here)

These came from the review discussion's web research, **not** from my reading the
references' source. Treat as "strong starting direction," confirm on open:

- **Rows are "a few `mgu` cases," but use lacks-constraints, not a presence
  flag.** Recursive `Row` (`REmpty | RVar | RExtend label τ rest`), closed vs open
  = whether the tail bottoms out in `REmpty` or a row var. No-duplicate-labels via
  **lacks constraints** on row vars (Gaster–Jones qualified types), which Nix's
  duplicate-key ban makes the right fit (you want lacks, *not* Leijen scoped
  labels). The blog "toy" `mgu` (and McHale's sketch) reproduce exactly the
  open/open *union-forgetting* bug at the merge step — don't crib the toy.
- **`//` is the one genuinely hard primitive** (record concatenation doesn't fit
  row unification — Wand/Rémy/Harper–Pierce). Ship the closed-fast-path +
  sound-degrade-to-open version and *document* that polymorphic `//` degrades.
- **Don't link a library.** `unification-fd` is single-sorted structural
  unification — wrong shape for rows + three var sorts
  (`TypeVar`/`RowVar`/`PresenceVar`). `row-types`/CTRex are Haskell type-level
  records, wrong tool. The closest *shipping* artifact is **Expresso**
  (`willtim/Expresso`, a row-typed config language) and
  `willtim/row-polymorphism`'s `AlgorithmW_ConstrainedRows.hs` — read those before
  writing.
- **Architecture: pure THIH-style `Subst` + row `mgu` cases + a lacks-constraint
  layer.** RC4 (union-find) is an *orthogonal* optimization — bolt on only if the
  oracle shows the `Map` substitution going quadratic on real files. Don't
  pre-optimize.
- **The `with`/`rec` bans are load-bearing in your favor:** they remove exactly
  the two constructs (dynamic scope rows, equirecursive records) that make rows a
  research project, leaving the static non-recursive fragment that's "implement a
  known algorithm."
- **Build the oracle in the same breath as the rows.** `generalize`/`instantiate`
  over three var sorts fails *silently* — a forgotten row-var quantification still
  runs, still passes the existing suite, and is subtly unsound/non-principal. The
  blast radius (every `unifyAttrs*`, `applySubst`, `occursCheck`, the schema
  emitter, the pretty-printer, the `# ::` annotations) is where the "just
  `freshVar` here" escape hatches regrow. Only the oracle tells you the rewrite is
  correct rather than plausible.

## Highest-leverage fix

Not any single bug — it is **two test harnesses**:

1. **Differential oracle.** For generated/corpus Nix: `accept ⟹ nix-instantiate
   --eval succeeds (no type error); reject ⟹ it fails`. For bash: round-trip the
   schema. This alone would have caught #1–#8 on the first run.
2. **`parse(format(x)) ≅ parse(x)`** for both formatters.

Both are absent today, and nothing in the ~4,500-line property suite can
substitute for them. Build these before chasing individual inference bugs — they
are how the individual bugs become visible and stay fixed.
