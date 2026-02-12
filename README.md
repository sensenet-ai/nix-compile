# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                                // nix-compile
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#     "people who were genuinely dangerous might not need to exhibit the fact 
#      at all, and that the ability to conceal a threat made them even more 
#      dangerous."
#
#                                                                  — Count Zero

Nix is dynamically typed. Bash is worse. Together they form the substrate of
modern infrastructure — and together they resist verification at every turn.

`nix-compile` brings Hindley-Milner type inference to both. The trick is
cross-language unification: bash command semantics constrain Nix expression
types, so when you interpolate `${config.timeout}` into `curl --connect-timeout`,
we know it's an integer without you telling us.

~5k lines of Haskell. No runtime dependencies beyond what's already in nixpkgs.


# ══════════════════════════════════════════════════════════════════════════════
#                                                          // what it actually does
# ══════════════════════════════════════════════════════════════════════════════


## type inference for nix

Hindley-Milner with row polymorphism. String literal types, not just `String`.

```nix
# before
{ lib }:
{
  yes = { tristate = "y"; optional = false; };
  no = { tristate = "n"; optional = false; };
  module = { tristate = "m"; optional = false; };
}
```

```nix
# after: nix-compile fmt kernel.nix
{ lib }:
{
  # :: { optional : Bool, tristate : "y" }
  yes = { tristate = "y"; optional = false; };
  # :: { optional : Bool, tristate : "n" }
  no = { tristate = "n"; optional = false; };
  # :: { optional : Bool, tristate : "m" }
  module = { tristate = "m"; optional = false; };
}
```

Those are literal types — `"y"`, `"n"`, `"m"` — which means if you pass a
`tristate = "yes"` somewhere expecting `"y"`, we catch it.


## bash schema extraction

Environment variables, config structure, command dependencies — pulled out
statically without running the script.

```bash
#!/usr/bin/env bash
PORT="${PORT:-8080}"
HOST="${HOST:?HOST is required}"
curl --connect-timeout "$TIMEOUT" "$URL"
```

We infer `TIMEOUT` is an integer because `curl --connect-timeout` takes one.
`HOST` is required (the `:?` syntax). `PORT` defaults to 8080. This becomes
a typed schema you can use for validation, documentation, or codegen.


## the distinctive thing: cross-language inference

When you write `writeShellApplication` in Nix with interpolated values, we
trace those interpolations into bash and figure out their types from context:

```nix
pkgs.writeShellApplication {
  name = "fetch-data";
  text = ''
    curl --connect-timeout "${config.timeout}" \
         --retry "${config.retries}" \
         -o "${config.output}" \
         "${config.url}"
  '';
}
```

From this we infer:
- `config.timeout` is `TInt` (curl's `--connect-timeout` takes integers)
- `config.retries` is `TInt` (curl's `--retry` takes integers)  
- `config.output` is `TPath` (curl's `-o` takes a file path)
- `config.url` is `TString` (default, nothing more specific)

These constraints flow back into the Nix type checker. If `config` comes from
somewhere that provides `timeout = "fast"`, we flag it.


## policy enforcement

The boring but important stuff. Banned constructs, store path requirements,
effect tracking.

```
$ nix-compile check deployment.sh

Forbidden constructs:
  deployment.sh:42: heredoc (use writeText instead)
  deployment.sh:67: eval (dynamic code execution)

Bare commands (must use store paths):
  deployment.sh:12: curl
  deployment.sh:23: jq

Policy violations: 4
```


# ══════════════════════════════════════════════════════════════════════════════
#                                                               // using it
# ══════════════════════════════════════════════════════════════════════════════

```bash
# check current directory
nix-compile

# check specific paths  
nix-compile nix/ lib/

# strict mode (lisp-case identifiers, full straylight conventions)
nix-compile -p strict

# nixpkgs contribution mode
nix-compile -p nixpkgs pkgs/
```

Exit 0 means clean. Exit 1 means issues (errors, warnings, or parse failures).
We don't skip files we can't parse — if analysis fails, that's a failure.


## profiles

**strict** — Full straylight conventions. Lisp-case identifiers, no `rec`, no
`with lib`. For new projects where you control everything.

**standard** — Sensible defaults. Most projects should use this.

**minimal** — Essential safety only. For legacy codebases you're gradually
improving.

**nixpkgs** — Matches nixpkgs contribution guidelines.

**security** — Paranoid mode for critical infrastructure.


## single-file commands

For when you want to do one specific thing:

```bash
nix-compile lint script.sh      # forbidden constructs only
nix-compile infer script.sh     # emit type schema as JSON
nix-compile fmt file.nix        # add type annotations
nix-compile scope file.nix      # dump scope graph
nix-compile flake .             # analyze flake structure
```


# ══════════════════════════════════════════════════════════════════════════════
#                                                            // type system
# ══════════════════════════════════════════════════════════════════════════════

Bash types are simple: `TInt`, `TString`, `TBool`, `TPath`, plus unification
variables. No subtyping — an int is not a string, even if bash doesn't care.

Nix types are richer:

```
NixType ::= TVar α                                unification variable
          | TInt | TFloat | TBool | TString       primitives
          | TPath | TNull
          | TStrLit "literal"                     string literal types
          | TList NixType                         homogeneous lists
          | TAttrs (Map Name (NixType, Bool))     closed attribute sets
          | TAttrsOpen (Map Name (NixType, Bool)) open rows (extensible)
          | TFun NixType NixType                  functions
          | TDerivation
          | TUnion [NixType]
          | TAny                                  escape hatch
```

Row polymorphism is why we distinguish `TAttrs` (closed, you can't add fields)
from `TAttrsOpen` (extensible, used for module options and similar patterns).

The invariants we maintain: determinism (same input → same output), soundness
(if we say it's type T, evaluation won't produce a type error), principality
(inferred types are most general), and substitution composition behaves correctly.


# ══════════════════════════════════════════════════════════════════════════════
#                                                             // architecture  
# ══════════════════════════════════════════════════════════════════════════════

```
                              nix-compile

  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
  │   Nix.Parse  │    │  Bash.Parse  │    │  Bash.Facts  │
  │   (hnix)     │    │ (shellcheck) │    │  extraction  │
  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘
         │                   │                   │
         └───────────────────┼───────────────────┘
                             ▼
              ┌──────────────────────────────┐
              │       Infer.Constraint       │
              │      facts → constraints     │
              └──────────────┬───────────────┘
                             ▼
              ┌──────────────────────────────┐
              │         Infer.Unify          │
              │   Hindley-Milner unification │
              └──────────────┬───────────────┘
                             ▼
              ┌──────────────────────────────┐
              │        Schema.Build          │
              │  facts + subst → typed schema│
              └──────────────┬───────────────┘
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
  ┌────────────┐      ┌────────────┐      ┌────────────┐
  │Emit.Config │      │ Nix.Format │      │ Nix.Scope  │
  │  bash gen  │      │ type annot │      │scope graph │
  └────────────┘      └────────────┘      └────────────┘
```

About 5k lines of Haskell across 35 modules. The heavy hitters are `Nix.Scope`
(830 LOC for scope graph construction), `Nix.Infer` (770 LOC for type inference),
and `Bash.Facts` (500 LOC for fact extraction). Everything else is plumbing.

Dependencies: `hnix` for Nix parsing, `ShellCheck` for bash parsing, `megaparsec`
for the fiddly bits, `katip` for logging. Nothing exotic.


# ══════════════════════════════════════════════════════════════════════════════
#                                                           // flake integration
# ══════════════════════════════════════════════════════════════════════════════

The point is to block commits that introduce issues. Here's the flake-parts way:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-compile.url = "github:straylight/nix-compile";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
    imports = [ inputs.nix-compile.flakeModules.default ];

    systems = [ "x86_64-linux" "aarch64-darwin" ];

    nix-compile = {
      enable = true;
      profile = "standard";
      paths = [ "nix" "lib" ];
      pre-commit.enable = true;
    };
  };
}
```

This gives you `checks.${system}.nix-compile` (runs on `nix flake check`) and
auto-installs a pre-commit hook in dev shells. The hook only checks staged files:

```
$ git commit -m "add feature"
nix-compile: checking staged files...
error: [with-lib] nix/lib.nix:12: with lib;
error: [no-heredoc] scripts/deploy.sh:45: heredoc (<<)

nix-compile: ✗ blocked
Use --no-verify to bypass.
```

Fix the issues or `--no-verify` if you know what you're doing.


# ══════════════════════════════════════════════════════════════════════════════
#                                                        // straylight conventions
# ══════════════════════════════════════════════════════════════════════════════

In strict mode, we enforce some opinions that won't suit everyone.

**Lisp-case identifiers.** `parseConfig` becomes `parse-config`. Why? It forces
use of the straylight prelude, which provides type-safe wrappers. The dash acts
as an escape hatch detector — if you're reaching for camelCase, you're probably
bypassing the prelude.

**Everything is a flake-parts module.** Packages, overlays, NixOS modules,
devShells — all wrapped in `{ config, lib, ... }: { ... }`. Parse once, analyze
everything. The `_class` attribute declares what kind:

```nix
# nix/packages/my-tool.nix
{ config, lib, pkgs, ... }:
{
  _class = "package";
  perSystem.packages.my-tool = pkgs.writeShellApplication { ... };
}
```

**Layout enforcement.** With `-l straylight`, we check that packages live in
`nix/packages/`, modules in `nix/modules/{flake,nixos,home}/`, and so on. Files
are parsed to detect what they *are*, then validated against where they *should be*.


# ══════════════════════════════════════════════════════════════════════════════
#                                                              // known holes
# ══════════════════════════════════════════════════════════════════════════════

This tool finds CVEs, but it has blind spots. Things we don't catch:

**No taint tracking for `builtins.import`.** We don't trace where dynamically
imported code comes from. Arbitrary code execution paths aren't followed.

**IFD not blocked.** Import-from-derivation means build-time code execution.
Use `nix flake check --no-allow-import-from-derivation` alongside us.

**Flake input URLs not validated.** Typosquatting attacks on inputs aren't
detected. `github:nixos/nixpkgs` vs `github:nix0s/nixpkgs`.

**No SRI verification.** We don't check that fetcher hashes are present or valid.

**`__functor` abuse.** Attribute sets with `__functor` can hide computation.
We don't trace this.

Cross-language inference catches type mismatches but doesn't track data flow
for security properties. It's static analysis, not a security scanner.


# ══════════════════════════════════════════════════════════════════════════════
#                                                                  // testing
# ══════════════════════════════════════════════════════════════════════════════

```bash
cabal test fixtures        # golden tests against expected outputs
cabal test props           # QuickCheck property tests (~1k LOC)
cabal test adversarial     # security: injection, overflow, malformed input
cabal test flake-parts     # real-world integration tests
```

To update golden files after intentional changes: `cabal run fixtures -- --bless`


# ══════════════════════════════════════════════════════════════════════════════
#                                                                   // license
# ══════════════════════════════════════════════════════════════════════════════

BSD-3-Clause.


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#     "They built the first computers to crack German ice, right? Codebreakers.
#      So there was ice before computers, you wanna look at it that way."
#
#                                                                  — Count Zero

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                                 — b7r6 // 2026
