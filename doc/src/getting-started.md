# Getting Started

## Installation

nix-compile is built with Nix flakes:

```bash
# Run directly from the flake
nix run github:sensenet-ai/nix-compile -- check ./deploy.sh

# Build the binary
nix build github:sensenet-ai/nix-compile

# Enter the development shell
nix develop github:sensenet-ai/nix-compile
```

## Quick examples

### Check a bash script

```bash
nix-compile check ./deploy.sh
```

This runs the full pipeline: lint for forbidden constructs, type inference on environment variables, and policy checks (bare commands, dynamic commands).

### Infer types and emit schema

```bash
nix-compile infer ./deploy.sh
```

Outputs a JSON schema showing all environment variables with their inferred types, defaults, and required status.

### Check embedded bash in Nix files

```bash
nix-compile nix ./default.nix
```

Finds `writeShellScript`, `writeShellScriptBin`, and `writeShellApplication` calls in the Nix file, extracts the bash content, and checks each script.

### Add type annotations to a Nix file

```bash
nix-compile fmt ./default.nix
```

Runs Hindley-Milner type inference and inserts `# :: Type` comments on bindings.

### Recursively check a directory

```bash
nix-compile typecheck ./my-project
```

Walks all `.nix` files in the directory tree (skipping `.git`, `node_modules`, etc.), runs type inference on each, and reports a summary.

### Generate a typed config emitter

```bash
nix-compile emit ./configure.sh
```

Given a script with `config.server.port=$PORT` assignments, generates an `emit-config` bash function that outputs structured JSON, YAML, or TOML:

```bash
# In the generated script:
emit-config json > config.json
emit-config yaml > config.yaml
emit-config toml > config.toml
```

### Analyze a flake

```bash
nix-compile flake .
```

Parses the flake structure, lists inputs and typed outputs.

### Show module dependency graph

```bash
nix-compile graph .
nix-compile graph --dot . | dot -Tpng -o graph.png
```
