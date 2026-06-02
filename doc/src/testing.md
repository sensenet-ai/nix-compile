# Testing

nix-compile has four test suites with 339 property tests, 34 adversarial regression
tests (the "psychotic" suite for review-2 findings), and 10 integration tests.

## Running tests

```bash
# All suites
cabal test

# Property tests only
cabal test nix-compile-test

# Fixture tests
cabal test nix-compile-fixtures
cabal test nix-compile-more-fixtures
cabal test nix-compile-flake-parts
```

## Test suites

### `nix-compile-test` (Props.hs + Adversarial.hs)

114 QuickCheck property tests across 21 categories:

| Category          | Count | What it tests                                                                           |
| ----------------- | ----- | --------------------------------------------------------------------------------------- |
| Type algebra      | 9     | Reflexive, symmetric, valid subst, order-independent solving                            |
| Constraints       | 4     | Empty identity, reflexive, satisfaction, order-independence                             |
| Fact extraction   | 5     | DefaultIs, Required, AssignFrom, ConfigAssign, ConfigLit vectors                        |
| Schema building   | 8     | Complete, defaults, required, defaulted-vars diagnostic                                 |
| Merge correctness | 4     | Required preserved, default kept, duplicate merged, identity law                        |
| Parser            | 4     | Labeled success/failure, deterministic, empty, comments                                 |
| Pattern matching  | 5     | Default, required, simple, numeric, alpha rejection                                     |
| Builtins          | 6     | Database integrity, known flags, unknown handling                                       |
| Config tree       | 2     | Completeness (conflict-free), deterministic                                             |
| Scope graph       | 7     | Priority, let/attrset/func/with/var construction, cross-file merge                      |
| Nix inference     | 10    | Totality, determinism, all literal types, lists, attrsets, functions, let               |
| Nix lint          | 3     | `with` detected, `rec` detected, clean passes                                           |
| Bash lint         | 3     | Heredoc, backtick detected, clean passes                                                |
| Emit-config       | 8     | `${VAR:?}` guards, no null, literal, string quoted, balanced braces, no heredoc, nested |
| Format            | 4     | Simple annotation, preserves source, function annotation, no-crash                      |
| E2E integration   | 5     | Config extraction, required vars, type conflicts, empty, store paths                    |
| Edge cases        | 4     | Comments-only, long names, deep config, all fact types                                  |
| Bash AST          | 4     | Arithmetic, subshell, pipe, for-loop body extraction                                    |
| Overlay algebra   | 5     | Identity, associativity, satisfaction, propagation                                      |
| Stress            | 4     | Large scripts (structural), many vars (>0), deep config, chains                         |
| Literals          | 3     | Int/bool roundtrip, type consistency                                                    |

### `nix-compile-fixtures` (Fixtures.hs)

Integration tests against real-world scripts:

- **check-by-name.sh** -- nixpkgs script, verifies env var extraction and bare command detection
- **qemu-common.nix** -- verifies type inference and `rec`/`with` lint detection
- **kernel.nix** -- clean file, verifies zero violations
- **gpu-broker layout** -- verifies `_class` validation (valid and invalid cases)

### `nix-compile-more-fixtures` (MoreFixtures.hs)

- **nativelink integration** -- real integration test script, verifies heredoc detection and bare command flagging
- **isospin main** -- large Nix file, verifies `rec`/`with` lint, bash extraction (10+ scripts), specific bare command detection

### `nix-compile-flake-parts` (FlakePartsTest.hs)

- Flake-parts `flake.nix` parsing
- Bash script with `@shell@` substitution placeholders
- Module directory lint (observation mode)

## Property test design

The property tests follow an adversarial philosophy:

1. **No tautologies** -- every property asserts something structural about successful results, not just "no exception." Tests that previously followed `Left _ -> True; Right _ -> True` have been replaced with labeled assertions on output structure.

2. **Generators produce hostile input** -- injection attempts, overflow integers, malformed expansions, path traversal, Unicode in variable names. Bash generators include conditionals (`if/then/fi`), loops (`for/do/done`), pipes, and subshells. Nix generators include list concat (`++`), attrset merge (`//`), and nested let.

3. **Properties assert invariants** -- algebraic laws (unification reflexivity/symmetry, substitution composition, overlay monoid laws), structural properties (balanced JSON braces, non-empty facts), and correctness vectors (specific bash patterns produce specific facts).

4. **Test vectors pin known behavior** -- specific expansion parses, literal types, overflow handling, merge semantics.

5. **Order-independence** -- constraint solving is tested against reversed input to catch order-dependent bugs.

The `Adversarial.hs` module contains additional security-focused properties (injection blocking, store path traversal rejection, bounded resource tests) that run alongside the main property suite.

### `Psychotic.hs` — review-2 regression suite

`test/Psychotic.hs` holds the regression suite for the second-round adversarial
audit (`REVIEW-2.md`). Each finding gets at least one negative test (input that
previously crashed or accepted bad code) and at least one positive test (input
that still works correctly after the fix). The 34 tests are grouped by finding:

| Group | Tests | Subject |
|-------|-------|---------|
| C1    | 6     | `escapeForParamExpansion` defeats every payload, idempotent under double-escape, end-to-end through `parseScriptFile` → `emitConfigFunction` |
| C2/C3 | 6     | `analyzeDepth` rejects `NWith`/`NApp` bypass chains; shallow ASTs accepted; structured `DepthError` |
| C4    | 2     | `safeParseNixText` survives 5000-deep parens, 3000-deep lists |
| C5    | 1     | Sibling-directory `proj-evil` not considered inside `proj` |
| C6    | 2     | Dhall config containing `https://attacker.example/x.dhall` rejected; local config still loads |
| S1    | 1     | `builtins.head [1 2 3] + 1` type-checks with polymorphic builtins |
| S2    | 3     | Closed-set missing-key errors; missing-with-`or` works; present-key works |
| S3    | 3     | Unbound variable errors; let-bound works; `envLenient = True` retains old behavior |
| S5    | 1     | `let xs = { a.b = 1; }; in xs.a.b` type-checks |
| S6    | 4     | `null + null`, `true + false` fail; `Int + Int`, `String + String` work |
| B1    | 2     | `combinedLintSafe` returns `LintDepthExceeded` past depth; clean returns `LintOk` |
| Safety wrappers | 3 | `renderSafetyError` total; `safeIO` catches exceptions; `safeReadFile` returns Left for missing path |
