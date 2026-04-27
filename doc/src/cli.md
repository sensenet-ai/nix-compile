# CLI Reference

```
nix-compile <command> [args]
```

## Commands

### `lint <script.sh>`

Check a bash script for forbidden constructs only. Does not run type inference or policy checks.

Detects: heredocs, here-strings, `eval`, backticks.

### `check <script.sh>`

Full check: lint + type inference + policy enforcement. Exits non-zero on any violation.

Detects everything `lint` detects, plus: bare commands (not store paths or builtins), dynamic commands (`$CMD`), type errors.

### `infer <script.sh>`

Run type inference and output the schema as JSON. Includes environment variables (with types, defaults, required status), config structure, commands, and store paths.

### `parse <script.sh>`

Parse and display extracted facts. Useful for debugging -- shows the raw observations before constraint generation.

### `emit <script.sh>`

Generate an `emit-config` bash function from config assignments in the script. The generated function supports `emit-config json`, `emit-config yaml`, and `emit-config toml`.

### `nix <file.nix>`

Check embedded bash scripts in a Nix file. Finds `writeShellScript`, `writeShellScriptBin`, and `writeShellApplication` calls, extracts bash content, and runs the full check pipeline on each.

### `fmt <file.nix>`

Run Hindley-Milner type inference on a Nix file and insert `# :: Type` annotations on bindings.

### `typecheck <path>`

Recursively type-check all `.nix` files in a directory (or a single file). Runs type inference on each file in parallel (bounded to 16 concurrent workers). Reports a summary with pass/skip/fail counts.

Skips files using unsupported constructs (`with`, `rec`, dynamic attrs) and directories: `.git`, `.direnv`, `node_modules`, `.cache`, `.lake`, `result`, `result-lib`, `target`.

### `flake [dir]`

Analyze a Nix flake. Defaults to the current directory. Reports inputs, typed outputs, and any issues.

### `graph [--dot] [dir]`

Show the module dependency graph for a Nix project. Follows `import` statements from `flake.nix`. Reports lint violations and layout issues. Exits non-zero if violations are found.

With `--dot`, outputs Graphviz DOT format for visualization.

### `scope <file.nix>`

Display the scope graph for a Nix file: declarations, references, and edges with their labels.

### `scope --json <file.nix>`

Emit the scope graph as JSON (for integration with zeitschrift or other tooling).

### `scope --dhall <file.nix>`

Emit the scope graph as a Dhall expression (for integration with zeitschrift).
