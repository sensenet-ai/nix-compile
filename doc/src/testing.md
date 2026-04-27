# Testing

nix-compile has four test suites with ~90 property tests and ~10 integration tests.

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

56 QuickCheck property tests covering:

**Algebraic properties:**
- Unification: reflexive, symmetric, valid substitution, self-trivial, concrete disjoint, TVar universal
- Substitution: composition associativity, empty identity, single application
- Constraint solving: empty, reflexive, satisfies, deterministic
- Fact/constraint: deterministic, default generates one constraint, required generates none

**Schema properties:**
- Deterministic, env-complete, preserves defaults, required marked

**Parser safety:**
- No crash on arbitrary input, deterministic, handles empty/comments

**Pattern matching:**
- Default expansion, required expansion, simple expansion, numeric/alpha discrimination

**Scope graph:**
- Parent edges resolve before With edges

**Overlay algebra:**
- Identity (left/right), associativity, satisfaction, propagation

**Stress tests:**
- Large scripts (50-200 lines), many variables (20-50), deep config paths (3-8 levels), chained references

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

1. **Generators produce hostile input** -- injection attempts, overflow integers, malformed expansions, path traversal, Unicode in variable names
2. **Properties assert invariants** -- algebraic laws, parser totality, security boundaries, specification conformance
3. **Test vectors pin known behavior** -- specific expansion parses, literal types, overflow handling

The `Adversarial.hs` module contains additional security-focused properties (injection blocking, store path traversal rejection, bounded resource tests) that run alongside the main property suite.
