# Bug Tracker

Current status of known issues. See [BUGS.md](https://github.com/sensenet-ai/nix-compile/blob/main/BUGS.md) in the repository for the full detail.

## Fixed

| ID | Description |
|----|-------------|
| CRIT-1 | Bare-word config values misidentified as variables |
| CRIT-2 | Single-token literal values lost in config path extraction |
| CRIT-3 | Multi-token config values truncated to first token |
| CRIT-4 | `detectUnsupported` misses `rec` attrsets |
| BUG-1 | `unifyUnion` checks membership against un-substituted types |
| BUG-3 | `findValueTokens` assumes `=` at suffix of Literal token |
| BUG-4 | `cmdCheck` discards solved substitution |
| DESIGN-1 | Scope graph edge priority not implemented |
| DESIGN-2 | `TVar -> TString` default masks inference failures (now tracked via `schemaDefaultedVars`) |
| DESIGN-3 | `emit-config` emits unguarded `$VAR` references (now uses `${VAR:?}`) |
| NEW-1 | `innerToText` catch-all produces phantom bare-command facts |
| NEW-2 | Type error not counted in `cmdNix` error tally |
| NEW-3 | `error "impossible"` in production code |
| NEW-4 | `NWith` scope edges both point to lexical parent |
| NEW-5 | `fromModuleGraph` drops all but first scope graph |
| NEW-6 | `FlakeOutputs` `Eq` only compares packages |
| NEW-7 | `mergeSchemas` drops overlapping env specs |
| NEW-8 | `buildConfigSchema` last-writer-wins semantics inverted |
| NEW-9 | `mapConcurrently` unbounded parallelism |
| NEW-10 | `findAllNixFiles` has no path-escape guard |
| NEW-11 | `NConcat` doesn't verify list type |
| NEW-12 | `findReferences` matches by name only |
| FIX-5 | `unsafePerformIO` in test suite |
| FIX-10 | `//` check in `isStorePath` |
| FIX-11 | No QuickCheck properties for Nix type inference (10 properties added) |
| FIX-12 | CI check only runs `--help` (now uses `haskell.lib.doCheck`) |
| FIX-13 | `emptySubst` in test (now uses real solved subst) |
| FIX-15 | `srcSpanToSpan` duplicated across 7 modules (deduplicated to Utils.hs) |
| 0x04-1 | All `TIO.readFile` calls wrapped in `try`/`IOException` |
| 0x04-2 | `jsonEscape` handles all control chars U+0000-U+001F per RFC 8259 |
| 0x04-3 | `findAllNixFiles` root visited-set initialization bug |

## Closed (confirmed not bugs)

| ID | Reason |
|----|--------|
| BUG-2 | `shellBuiltins` does not contain `""` (retracted) |
| BUG-5 | `mergeEnvSpec` left-biased type is safe in context (solver guarantees consistency) |

## Open

None.
