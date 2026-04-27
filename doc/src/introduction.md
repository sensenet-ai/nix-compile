# nix-compile

Compile-time static analysis for Nix expressions and embedded bash scripts.

nix-compile sits in the build pipeline and catches bugs *before* runtime:

- **Type inference** for bash environment variables -- infers types from `${VAR:-default}` patterns, config assignments, and command usage
- **Hindley-Milner type inference** for Nix expressions -- row polymorphism, type schemes, attrset typing
- **Policy enforcement** -- bans `with`, `rec`, heredocs, `eval`, backticks, and bare (non-store-path) commands
- **Config generation** -- replaces heredoc-templated config files with typed `emit-config json|yaml|toml` functions
- **Scope graphs** -- Visser-style scope graphs for IDE tooling (go-to-definition, find-references), exportable as JSON or Dhall

## Design principles

1. **Fail at build time, not runtime.** Every bash `${VAR}` reference is statically checked. Every command is verified against store paths or a known-builtins allowlist.

2. **No escape hatches.** Forbidden constructs (heredocs, eval, backticks) are banned unconditionally. There is no `# nix-compile: ignore` directive.

3. **Two type systems, one tool.** Bash gets simple first-order types (`TInt`, `TString`, `TBool`, `TPath`). Nix gets full Hindley-Milner with row polymorphism. They don't interact -- bash scripts extracted from Nix files go through the bash pipeline; the surrounding Nix goes through the Nix pipeline.

4. **Conservative by default.** Unknown commands produce no type constraints. Unsupported Nix constructs (`with`, `rec`, dynamic attrs) cause the file to be skipped rather than producing wrong results.

## Project status

The bash analysis pipeline is complete and battle-tested with QuickCheck property tests. The Nix type inference handles most of the language. The scope graph works for single files; cross-file analysis is in progress. See [Bug Tracker](./bugs.md) for the full status.
