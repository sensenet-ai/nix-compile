# Bug Tracker

Current status of known issues. See [BUGS.md](https://github.com/sensenet-ai/nix-compile/blob/main/BUGS.md) in the repository for the full detail.

## Fixed (this cycle)

| ID | Description |
|----|-------------|
| CRIT-1 | Bare-word config values misidentified as variables |
| CRIT-2 | Single-token literal values lost in config path extraction |
| CRIT-3 | Multi-token config values truncated to first token |
| CRIT-4 | `detectUnsupported` misses `rec` attrsets |
| BUG-1 | `unifyUnion` checks membership against un-substituted types |
| DESIGN-1 | Scope graph edge priority not implemented |
| NEW-1 | `innerToText` catch-all produces phantom bare-command facts |
| NEW-2 | Type error not counted in `cmdNix` error tally |
| NEW-3 | `error "impossible"` in production code |
| NEW-4 | `NWith` scope edges both point to lexical parent |
| NEW-6 | `FlakeOutputs` `Eq` only compares packages |
| NEW-7 | `mergeSchemas` drops overlapping env specs |
| NEW-8 | `buildConfigSchema` last-writer-wins (no merge) |
| NEW-9 | `mapConcurrently` unbounded parallelism |
| NEW-10 | `findAllNixFiles` has no path-escape guard |
| NEW-11 | `NConcat` doesn't verify list type |
| NEW-12 | `findReferences` matches by name only |
| DESIGN-3 | `emit-config` emits unguarded `$VAR` references |
| BUG-4 | `cmdCheck` discards solved substitution |

## Open

| ID | Severity | Description |
|----|----------|-------------|
| BUG-3 | Medium | `findValueTokens` assumes `=` at suffix of Literal token |
| BUG-5 | Low | `mergeEnvSpec` left-biased type selection |
| DESIGN-2 | Medium | `TVar -> TString` default masks inference failures |
| FIX-5 | Low | `unsafePerformIO` in test suite |
| FIX-10 | Low | `//` check in `isStorePath` |
| FIX-11 | Medium | No QuickCheck properties for Nix type inference |
| FIX-12 | Medium | CI check only runs `--help` |
| FIX-13 | Low | `emptySubst` in test |
| FIX-15 | Low | `srcSpanToSpan` duplicated across 7 modules |
| NEW-5 | High | `fromModuleGraph` drops all but first scope graph |
