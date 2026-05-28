# Architecture

nix-compile has two analysis pipelines that operate on different languages with different type systems, unified at the point of use.

## Pipeline A: Bash Analysis

```
Bash source text
    |
    v
parseBash (ShellCheck)          -- lib/NixCompile/Bash/Parse.hs
    |
    v  BashAST (ShellCheck Token tree + position map)
    |
extractFacts                    -- lib/NixCompile/Bash/Facts.hs
    |
    v  [Fact]
    |  - DefaultIs "PORT" (LitInt 8080)
    |  - Required "HOST"
    |  - ConfigAssign ["server","port"] "PORT" Unquoted
    |  - UsesStorePath "/nix/store/...-curl/bin/curl"
    |  - BareCommand "wget"
    |
factsToConstraints              -- lib/NixCompile/Infer/Constraint.hs
    |
    v  [Constraint]
    |  - TVar "PORT" :~: TInt
    |  - TVar "HOST" :~: TString
    |
solve                           -- lib/NixCompile/Infer/Unify.hs
    |
    v  Subst (Map TypeVar Type)
    |  - "PORT" -> TInt
    |  - "HOST" -> TString
    |
buildSchema                     -- lib/NixCompile/Schema/Build.hs
    |
    v  Schema
       - schemaEnv: PORT : TInt (default 8080), HOST : TString (required)
       - schemaConfig: server.port -> TInt from PORT
       - schemaCommands: curl (store path)
       - schemaBareCommands: wget (violation)
```

## Pipeline B: Nix Type Inference

```
Nix source text
    |
    v
parseNixFile (hnix)             -- external dependency
    |
    v  NExprLoc (annotated AST)
    |
inferExpr                       -- lib/NixCompile/Nix/Infer.hs
    |  Full Hindley-Milner:
    |  - Type schemes (forall a. ...)
    |  - Row polymorphism (TAttrs closed / TAttrsOpen open)
    |  - SCC-based let generalization
    |  - __functor support
    |  - ~40 builtin signatures
    |
    v  (NixType, [Binding])
```

## Cross-cutting features

- **`Nix.Parse.extractBashScripts`** -- finds `writeShellScript` / `writeShellScriptBin` / `writeShellApplication` calls in Nix files, extracts bash content with interpolation tracking, feeds it through Pipeline A.

- **`Nix.Module.buildModuleGraph`** -- follows `import` statements from a flake root, builds a dependency graph with topological ordering, runs type inference and lint on each file.

- **`Nix.Scope`** -- builds Visser-style scope graphs from Nix ASTs for IDE tooling. Single-file and cross-file analysis both functional; `fromModuleGraph` merges graphs with ID remapping for multi-file projects.

- **`Nix.Effect`** -- models Nix overlays as a Coeffect calculus (requirements vs productions). The algebra is complete and tested; integration with actual overlay analysis is in progress.

## Module map

```
NixCompile                      -- top-level API (parseScript, parseScriptFile)
  Bash
    Parse                       -- ShellCheck wrapper
    Facts                       -- AST -> [Fact] extraction
    Patterns                    -- ${VAR:-default}, config.x.y=$VAR recognition
    Builtins                    -- 21-command typed flag database
  Infer
    Constraint                  -- Fact -> [Constraint]
    Unify                       -- first-order unification
  Schema
    Build                       -- Facts + Subst -> Schema
  Emit
    Config                      -- Schema -> emit-config bash function
  Lint
    Forbidden                   -- heredoc/eval/backtick detection
  Nix
    Infer                       -- HM type inference for Nix
    Types                       -- NixType, Scheme, row types
    Parse                       -- extract bash from Nix files
    Lint                        -- with/rec detection
    Scope                       -- scope graph construction + resolution
    Module                      -- multi-file module graph
    Flake                       -- flake.nix analysis
    Layout                      -- directory convention validation
    Effect                      -- overlay coeffect algebra
    Format                      -- inject type annotations
    Pretty                      -- type pretty-printing
    Utils                       -- shared utilities
  Types                         -- bash type system (TInt/TString/TBool/TPath)
  Log                           -- Katip logging setup
```
