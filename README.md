# // nix-compile //

Compile-time static analysis for Nix expressions and embedded bash scripts.

- **Type inference** for bash environment variables -- infers types from `${VAR:-default}` patterns, config assignments, and command usage
- **Hindley-Milner type inference** for Nix expressions -- row polymorphism, type schemes, attrset typing
- **Policy enforcement** -- bans `with`, `rec`, heredocs, `eval`, backticks, and bare (non-store-path) commands
- **Config generation** -- replaces heredoc-templated config with typed `emit-config json|yaml|toml`
- **Scope graphs** -- Visser-style scope graphs for IDE tooling, exportable as JSON or Dhall

## // documentation //

Full docs are in [`doc/`](./doc/) (built with [mdBook](https://rust-lang.github.io/mdBook/)):

```bash
mdbook serve doc/    # local preview at http://localhost:3000
mdbook build doc/    # build to doc/book/
```

Or read the source markdown directly:

- [Introduction](./doc/src/introduction.md)
- [Getting Started](./doc/src/getting-started.md)
- [CLI Reference](./doc/src/cli.md)
- [Architecture](./doc/src/architecture.md)
- [Policy Rules](./doc/src/policy.md)
- [Bug Tracker](./doc/src/bugs.md)

## // quick start //

```bash
# Run all checks on a project (auto-detects .sh, .nix, or directory)
nix run github:sensenet-ai/nix-compile -- check ./

# Check a single file
nix run github:sensenet-ai/nix-compile -- check ./default.nix

# Infer types and add annotation comments
nix run github:sensenet-ai/nix-compile -- infer ./default.nix

# Generate typed config emitter
nix run github:sensenet-ai/nix-compile -- emit ./configure.sh

# Show scope graph
nix run github:sensenet-ai/nix-compile -- scope ./default.nix

# Start LSP server
nix run github:sensenet-ai/nix-compile -- lsp
```
