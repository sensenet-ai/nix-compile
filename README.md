# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                                // nix-compile
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#     "Get just right, and I'll cut the ice; get it wrong, and it's the death
#      of ten thousand Turing cops."
#
#                                                                  — Neuromancer

Compile-time static analysis for Nix expressions and embedded bash scripts.

Nix is dynamically typed. Bash is worse. Together they form the substrate of
modern infrastructure — and together they resist verification at every turn.

`nix-compile` brings Hindley-Milner type inference to both, with cross-language
unification that lets bash command semantics constrain Nix expression types.


# ══════════════════════════════════════════════════════════════════════════════
#                                                                   // features
# ══════════════════════════════════════════════════════════════════════════════


## // type // inference

Hindley-Milner with row polymorphism for Nix. Constraint-based inference for
bash.

```nix
# input: kernel.nix
{ lib }:
{
  yes = { tristate = "y"; optional = false; };
  no = { tristate = "n"; optional = false; };
  module = { tristate = "m"; optional = false; };
}
```

```nix
# output: nix-compile fmt kernel.nix
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

n.b. string literal types — `"y"`, `"n"`, `"m"` — not merely `String`.


## // bash // schema // extraction

Environment variables, config structure, command dependencies — extracted
statically from bash scripts without execution.

```bash
#!/usr/bin/env bash
PORT="${PORT:-8080}"
HOST="${HOST:?HOST is required}"
config.server.port=$PORT
config.server.host="$HOST"
curl --connect-timeout "$TIMEOUT" "$URL"
```

```json
{
  "env": {
    "PORT": { "type": "TInt", "required": false, "default": 8080 },
    "HOST": { "type": "TString", "required": true },
    "TIMEOUT": { "type": "TInt", "required": false }
  },
  "config": {
    "server": {
      "port": { "type": "TInt", "source": "PORT" },
      "host": { "type": "TString", "source": "HOST", "quoted": true }
    }
  },
  "commands": ["curl"]
}
```

n.b. `TIMEOUT` inferred as `TInt` from `curl --connect-timeout` semantics.


## // cross-language // inference

The distinctive capability. Nix interpolations in `writeShellScript` bodies
have their types constrained by bash command argument positions.

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

Inferred constraints flow back to Nix:

```
${config.timeout} :: TInt      # from curl --connect-timeout
${config.retries} :: TInt      # from curl --retry
${config.output}  :: TPath     # from curl -o
${config.url}     :: TString   # default
```


## // policy // enforcement

Banned constructs. Store path requirements. Effect tracking.

```
$ nix-compile check deployment.sh

Forbidden constructs:
  deployment.sh:42: heredoc (use writeText instead)
  deployment.sh:67: eval (dynamic code execution)

Bare commands (must use store paths):
  deployment.sh:12: curl
  deployment.sh:23: jq
  deployment.sh:45: docker

Policy violations: 5
```


# ══════════════════════════════════════════════════════════════════════════════
#                                                                      // usage
# ══════════════════════════════════════════════════════════════════════════════


## // quick // start

```bash
# check current directory
nix-compile

# check specific paths
nix-compile nix/ lib/

# use strict profile (lisp-case, Dhall templating)
nix-compile -p strict

# use nixpkgs profile
nix-compile -p nixpkgs pkgs/
```


## // exit // codes

| Code | Meaning |
|------|---------|
| 0 | Clean — no issues |
| 1 | Issues found (errors, warnings, info, or parse failures) |

Parse failures are not skipped. If we can't analyze a file, that's a failure.


## // profiles

| Profile | Description | `non-lisp-case` | `rec` | `with lib` |
|---------|-------------|-----------------|-------|------------|
| `strict` | Full aleph conventions | error | error | error |
| `standard` | Sensible defaults | off | warning | error |
| `minimal` | Essential safety only | off | off | warning |
| `nixpkgs` | nixpkgs guidelines | off | off | warning |
| `security` | Security-focused | off | off | error |


## // legacy // commands

Single-file commands for specific tasks:

```
nix-compile lint <script.sh>       check for forbidden constructs
nix-compile check <script.sh>      full analysis (lint + policy + types)
nix-compile infer <script.sh>      infer types, emit schema as JSON
nix-compile parse <script.sh>      show extracted facts
nix-compile emit <script.sh>       generate emit-config bash function

nix-compile nix <file.nix>         analyze embedded bash in Nix files
nix-compile fmt <file.nix>         add type annotations to Nix
nix-compile typecheck <path>       recursive type check (parallel)
nix-compile flake [dir]            analyze flake structure
nix-compile scope <file.nix>       scope graph analysis
```


## // examples

### bash schema extraction

```bash
$ nix-compile infer scripts/deploy.sh | jq .env
{
  "DEPLOY_ENV": {
    "type": "TString",
    "required": true,
    "default": null
  },
  "REPLICAS": {
    "type": "TInt",
    "required": false,
    "default": 3
  }
}
```


### nix type annotation

```bash
$ nix-compile fmt lib/kernel.nix > lib/kernel.nix.typed
$ head -20 lib/kernel.nix.typed
# :: { lib : a } -> { ... }
{ lib }:
let
  # :: a -> a
  inherit (lib) mkIf versionAtLeast versionOlder;
in
{
  # :: { optional : Bool, tristate : "y" }
  yes = { tristate = "y"; optional = false; };
  ...
```


### embedded bash analysis

```bash
$ nix-compile nix nix/modules/scripts.nix

Found 12 shell scripts in nix/modules/scripts.nix

=== fetch-assets ===
  Nix interpolation types inferred from bash context:
    ${config.timeout} :: TInt
    ${config.retries} :: TInt
  OK

=== deploy ===
  Bare commands (must use store paths):
    deploy:5: rsync
    deploy:12: ssh
  2 error(s)
```


# ══════════════════════════════════════════════════════════════════════════════
#                                                              // type // system
# ══════════════════════════════════════════════════════════════════════════════


## // bash // types

```
BashType ::= TInt          integers: -42, 0, 8080
           | TString       string values
           | TBool         true | false
           | TPath         Nix store paths: /nix/store/...
           | TVar α        unification variable
```

No subtyping relations between concrete types.


## // nix // types

```
NixType ::= TVar α                                unification variable
          | TInt | TFloat | TBool | TString       primitives
          | TPath | TNull                         primitives cont.
          | TStrLit "literal"                     string literal types
          | TList NixType                         homogeneous lists
          | TAttrs (Map Name (NixType, Bool))     closed attribute sets
          | TAttrsOpen (Map Name (NixType, Bool)) open rows
          | TFun NixType NixType                  functions
          | TDerivation                           derivations
          | TUnion [NixType]                      union types
          | TAny                                  top type (escape hatch)
```

Row polymorphism distinguishes `TAttrs` (closed) from `TAttrsOpen` (extensible).


## // invariants

| ID | Property | Statement |
|----|----------|-----------|
| INV-1 | Determinism | Identical input → identical output. No randomness. |
| INV-2 | Soundness | If inference succeeds with type T, evaluation will not produce a type error. |
| INV-3 | Principality | Inferred types are principal (most general). |
| INV-4 | Composition | `apply (compose s1 s2) t = apply s1 (apply s2 t)` |
| INV-5 | Satisfaction | If `solve(C) = σ`, then `∀(T1 ~ T2) ∈ C: apply σ T1 = apply σ T2` |


# ══════════════════════════════════════════════════════════════════════════════
#                                                               // architecture
# ══════════════════════════════════════════════════════════════════════════════

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                 nix-compile                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                   │
│  │   Nix.Parse  │    │  Bash.Parse  │    │  Bash.Facts  │                   │
│  │   (hnix)     │    │ (shellcheck) │    │  extraction  │                   │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘                   │
│         │                   │                   │                           │
│         ▼                   ▼                   ▼                           │
│  ┌──────────────────────────────────────────────────────┐                   │
│  │                    Infer.Constraint                   │                   │
│  │              facts → type constraints                 │                   │
│  └──────────────────────────┬───────────────────────────┘                   │
│                             │                                               │
│                             ▼                                               │
│  ┌──────────────────────────────────────────────────────┐                   │
│  │                     Infer.Unify                       │                   │
│  │           Hindley-Milner unification                  │                   │
│  └──────────────────────────┬───────────────────────────┘                   │
│                             │                                               │
│                             ▼                                               │
│  ┌──────────────────────────────────────────────────────┐                   │
│  │                    Schema.Build                       │                   │
│  │        facts + substitution → typed schema            │                   │
│  └──────────────────────────┬───────────────────────────┘                   │
│                             │                                               │
│         ┌───────────────────┼───────────────────┐                           │
│         ▼                   ▼                   ▼                           │
│  ┌────────────┐      ┌────────────┐      ┌────────────┐                     │
│  │ Emit.Config│      │ Nix.Format │      │  Nix.Scope │                     │
│  │ bash codegen│     │ type annot │      │ scope graph│                     │
│  └────────────┘      └────────────┘      └────────────┘                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```


## // module // inventory

```
lib/NixCompile/
├── Bash/
│   ├── Builtins.hs      385 LOC   command argument type database
│   ├── Facts.hs         402 LOC   fact extraction from AST
│   ├── Parse.hs         142 LOC   shellcheck wrapper
│   └── Patterns.hs      302 LOC   parameter expansion parsing
├── Emit/
│   └── Config.hs        332 LOC   bash config function codegen
├── Infer/
│   ├── Constraint.hs     62 LOC   facts → constraints
│   └── Unify.hs         187 LOC   Hindley-Milner solver
├── Lint/
│   └── Forbidden.hs     198 LOC   banned construct detection
├── Nix/
│   ├── Effect.hs        156 LOC   coeffect tracking
│   ├── Flake.hs         363 LOC   flake structure analysis
│   ├── Format.hs        284 LOC   type annotation insertion
│   ├── Infer.hs         768 LOC   Nix type inference
│   ├── Layout.hs        167 LOC   directory/class validation
│   ├── Lint.hs          143 LOC   rec/with detection
│   ├── Module.hs        398 LOC   module system analysis
│   ├── Parse.hs         378 LOC   hnix wrapper, bash extraction
│   ├── Pretty.hs        112 LOC   type pretty-printing
│   ├── Scope.hs         831 LOC   scope graph construction
│   ├── Types.hs         245 LOC   Nix type definitions
│   └── Utils.hs          89 LOC   shared utilities
├── Schema/
│   └── Build.hs         145 LOC   schema construction
├── Log.hs                67 LOC   katip logging
└── Types.hs             419 LOC   core type definitions

                        ~6,923 LOC total
```


# ══════════════════════════════════════════════════════════════════════════════
#                                                                     // build
# ══════════════════════════════════════════════════════════════════════════════


## // dependencies

```cabal
build-depends:
    base >= 4.17
  , aeson
  , async
  , bytestring
  , containers
  , directory
  , filepath
  , hnix >= 0.17
  , katip
  , megaparsec
  , mtl
  , ShellCheck >= 0.9
  , text
```


## // nix // shell

```bash
nix develop
cabal build
cabal test
```


## // flake // usage

```nix
{
  inputs.nix-compile.url = "github:straylight/nix-compile";

  outputs = { nix-compile, ... }: {
    devShells.default = pkgs.mkShell {
      packages = [ nix-compile.packages.${system}.default ];
    };
  };
}
```


# ══════════════════════════════════════════════════════════════════════════════
#                                                                    // testing
# ══════════════════════════════════════════════════════════════════════════════


## // test // suites

| Suite | LOC | Coverage |
|-------|-----|----------|
| `Fixtures.hs` | 396 | golden tests against expected outputs |
| `MoreFixtures.hs` | 198 | cross-language inference, isospin corpus |
| `FlakePartsTest.hs` | 97 | real-world flake-parts parsing |
| `Props.hs` | 1026 | algebraic properties (QuickCheck) |
| `Adversarial.hs` | 786 | security: injection, overflow, malformed input |


## // run // tests

```bash
cabal test fixtures        # golden tests
cabal test props           # property tests
cabal test adversarial     # security tests
cabal test flake-parts     # integration tests
cabal test more-fixtures   # cross-language tests
```


## // bless // fixtures

```bash
cabal run fixtures -- --bless
```

Regenerates `.expected` files from current tool output.


# ══════════════════════════════════════════════════════════════════════════════
#                                                             // specification
# ══════════════════════════════════════════════════════════════════════════════

See `SPECIFICATION.md` for the formal specification:

- type system rules and subtyping
- parameter expansion recognition table
- literal parsing semantics
- config assignment syntax
- command allowlist policy
- error code format (ALEPH-B00N)

See `REVIEW.md` for:

- post-patch adversarial review
- bug fixes applied
- spec deviations documented
- Lean 4 port considerations
- cross-language inference documentation

See `rules/README.md` for:

- AST-based lint rules for tree-sitter linters
- Policy enforcement patterns
- Derivation quality checks
- Integration with nix-compile


# ══════════════════════════════════════════════════════════════════════════════
#                                                              // external rules
# ══════════════════════════════════════════════════════════════════════════════

The `rules/` directory contains tree-sitter AST pattern rules for use with
`ast-grep` or similar tools. These complement `nix-compile`'s built-in checks.


## // profiles

Rules are organized into profiles. `non-lisp-case` is **off by default** — 
it's only enabled in `strict` mode for straylight projects.

| Profile | Description | Recommended For |
|---------|-------------|-----------------|
| `strict` | Full aleph conventions (lisp-case) | New straylight projects |
| `standard` | Sensible defaults | Most projects |
| `minimal` | Essential safety only | Legacy codebases |
| `nixpkgs` | nixpkgs guidelines | nixpkgs contributions |
| `security` | Security-focused | Critical infrastructure |


## // usage

```bash
# check current directory
nix-compile

# check specific paths
nix-compile nix/ lib/

# use a profile
nix-compile -p strict
nix-compile -p nixpkgs pkgs/
```


## // configuration

Create `.nix-compile.dhall` in your project root:

```dhall
let NixCompile = ./config/package.dhall

in  NixCompile.Config::{
    , profile = "standard"
    , extra-ignores = [ "vendor/**" ]
    , overrides = [
        NixCompile.override "rec-anywhere" NixCompile.Severity.Info
      ]
    }
```

See `config/README.md` for full documentation.


# ══════════════════════════════════════════════════════════════════════════════
#                                                       // flake // integration
# ══════════════════════════════════════════════════════════════════════════════

Import correctness into your project. Checks run on `nix flake check` and
commits are blocked if issues are found.


## // with // flake-parts

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
      profile = "standard";  # or "strict", "minimal", "nixpkgs", "security"
      paths = [ "nix" "lib" ];
      pre-commit.enable = true;
    };
  };
}
```

This provides:

| Output | Description |
|--------|-------------|
| `checks.${system}.nix-compile` | Runs on `nix flake check` |
| `packages.${system}.nix-compile-hook` | Standalone pre-commit script |
| `devShells.${system}.nix-compile` | Shell with hook auto-installed |


## // without // flake-parts

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-compile.url = "github:straylight/nix-compile";
  };

  outputs = { self, nixpkgs, nix-compile, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      nc = nix-compile.lib;
    in {
      checks.${system}.nix-compile = nc.mkCheck {
        inherit pkgs;
        nix-compile = nix-compile.packages.${system}.default;
        src = ./.;
        profile = "standard";
        paths = [ "nix" ];
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ nix-compile.packages.${system}.default ];
        shellHook = nc.mkPreCommitHook {
          profile = "standard";
          paths = [ "nix" ];
        };
      };
    };
}
```


## // pre-commit // behavior

The hook checks only staged `.nix`, `.sh`, and `.bash` files:

```
$ git commit -m "add feature"
nix-compile: checking staged files...
error: [with-lib] nix/lib.nix:12: with lib;
error: [no-heredoc] scripts/deploy.sh:45: heredoc (<<)

nix-compile: ✗ blocked
Use --no-verify to bypass.
```

Fix the issues or bypass with `git commit --no-verify`.


# ══════════════════════════════════════════════════════════════════════════════
#                                                       // layout // enforcement
# ══════════════════════════════════════════════════════════════════════════════

Enforce ironclad directory structure and file naming by detecting what each
file IS (via parsing) and validating it's in the RIGHT PLACE.

```bash
nix-compile -l straylight       # enforce straylight layout
nix-compile -p strict -l straylight  # strict + layout
```


## // layout // conventions

| Convention | Structure |
|------------|-----------|
| `straylight` | `nix/modules/{flake,nixos,home}/`, `nix/packages/`, `nix/overlays/` |
| `flake-parts` | `modules/`, `packages/`, `overlays/` |
| `nixpkgs` | `pkgs/by-name/XX/name/package.nix` |
| `nixos` | `hosts/`, `modules/`, `users/` |
| `none` | No enforcement (default) |


## // module // kind // detection

Files are parsed to determine their kind:

| Kind | Detection |
|------|-----------|
| `NixOSModule` | Has `options` and `config` attrs, params include `config`, `lib` |
| `Package` | Calls `mkDerivation`, has `pname`/`version`, params include `stdenv` |
| `Overlay` | Two-argument function (`final: prev:` or `self: super:`) |
| `FlakeModule` | flake-parts style module structure |
| `Library` | Exports functions like `mkOption`, `mapAttrs` |
| `Flake` | File is `flake.nix` |

Then validated against convention:

```
$ nix-compile -l straylight
error: [layout-E001] packages/foo.nix: File in wrong location for Package
  (expected: nix/packages/...)

error: [layout-E004] nix/lib/utils.nix: File name must be kebab-case
  (expected: kebab-case: utils)
```


## // with // flake-parts

```nix
nix-compile = {
  enable = true;
  profile = "strict";
  layout = "straylight";  # enforce directory structure
  paths = [ "nix" ];
  pre-commit.enable = true;
};
```


# ══════════════════════════════════════════════════════════════════════════════
#                                                        // naming // enforcement
# ══════════════════════════════════════════════════════════════════════════════

In `strict` profile, all Nix identifiers must be kebab-case (lisp-case).

```
$ nix-compile -p strict
warn: [naming] nix/lib/utils.nix:12: let binding 'parseConfig' should be 'parse-config'
warn: [naming] nix/lib/utils.nix:15: attribute 'extraOptions' should be 'extra-options'
```

**Why lisp-case?** Forces use of the straylight prelude, which provides type-safe
wrappers. `extraOptions` becomes `prelude.extra-options cfg`. The dash acts as
an escape hatch detector.


## // exempt // identifiers

Standard Nix/NixOS/flake-parts names are exempt:

```
config, lib, pkgs, options, imports, stdenv, pname, version, src, meta,
buildInputs, nativeBuildInputs, configurePhase, buildPhase, installPhase,
perSystem, flake, enable, package, ...
```

Identifiers starting with `_` (like `_class`, `_module`) are also exempt.


# ══════════════════════════════════════════════════════════════════════════════
#                                                // everything // is // a // module
# ══════════════════════════════════════════════════════════════════════════════

In the straylight convention, **everything is a flake-parts module**.

| Traditional | Flake-parts module |
|-------------|-------------------|
| NixOS module | `flake.nixosModules.foo` |
| Package | `perSystem.packages.foo` |
| Overlay | `flake.overlays.foo` |
| DevShell | `perSystem.devShells.foo` |
| Library | `flake.lib.foo` |
| home-manager | `flake.homeModules.foo` |

This gives uniform structure: every file is `{ config, lib, ... }: { ... }`.
Parse once, analyze everything.

The `_class` attribute declares what kind of module it is:

```nix
# nix/packages/my-tool.nix
{ config, lib, pkgs, ... }:
{
  _class = "package";

  perSystem.packages.my-tool = pkgs.writeShellApplication {
    name = "my-tool";
    text = ''
      echo "hello"
    '';
  };
}
```

If `-l straylight` is set, modules without `_class` are flagged.


# ══════════════════════════════════════════════════════════════════════════════
#                                                                    // license
# ══════════════════════════════════════════════════════════════════════════════

BSD-3-Clause. See `LICENSE`.


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#     "The matrix has its roots in primitive arcade games, in early graphics
#      programs and military experimentation with cranial jacks."
#
#                                                                  — Neuromancer

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                                 — b7r6 // 2026
