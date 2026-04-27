# Policy Rules

nix-compile enforces a strict policy with no escape hatches. Every rule has an error code prefixed `ALEPH-`.

## Bash rules

### ALEPH-B001: Heredocs

```
Forbidden: heredoc (<<, <<-)
```

Heredocs contain interpolations that can't be statically analyzed. The content is opaque to the parser.

**Use instead:** `emit-config` for structured output, `printf` for formatted strings, or generate content in Nix.

### ALEPH-B002: Here-strings

```
Forbidden: here-string (<<<)
```

Same problem as heredocs -- interpolation inside here-strings is not statically analyzable.

**Use instead:** `echo "string" | command` or `printf '%s' "string" | command`.

### ALEPH-B003: eval

```
Forbidden: eval (including builtin eval, command eval)
```

Dynamic code execution defeats static analysis entirely.

**Use instead:** `declare "$name=$value"` for dynamic variable assignment, or a `case` statement for dispatch.

### ALEPH-B004: Backticks

```
Forbidden: backtick command substitution (`cmd`)
```

Backticks are deprecated POSIX syntax with broken nesting semantics.

**Use instead:** `$(command)`.

### ALEPH-B005: Bare commands

```
Bare commands (external commands must use store paths; shell builtins allowed)
```

Commands that are neither store paths (`/nix/store/...`) nor shell builtins are rejected. This ensures reproducibility -- every external tool must come from a Nix derivation.

Shell builtins (e.g. `echo`, `printf`, `test`, `[`, `set`, `export`, `declare`, `local`, `read`, `cd`, `pwd`, `true`, `false`, `:`) are always allowed.

### ALEPH-B006: Dynamic commands

```
Dynamic commands (cannot analyze)
```

Commands invoked via a variable (`$CMD arg1 arg2`) cannot be statically verified.

## Nix rules

### ALEPH-N001: `with` expressions

```
Forbidden: with expr;
```

`with` obscures scope, breaks go-to-definition, creates shadowing hazards, and makes type inference unsound. It silently changes the meaning of every unbound variable in its body.

**Use instead:** `inherit (expr) name1 name2;` to explicitly bring names into scope.

### ALEPH-N002: `rec` attrsets

```
Forbidden: rec { }
```

`rec` enables infinite loops (non-termination), complicates static analysis, makes evaluation order-dependent, and breaks referential transparency.

**Use instead:** `let` bindings or explicit function arguments.

## Layout rules

These apply to projects using the flake-parts module convention.

| Code | Condition | Message |
|------|-----------|---------|
| ALEPH-L001 | `_index.nix` file found | Module graph is derived from directory structure |
| ALEPH-L002 | `_main.nix` file found | Use explicit imports in flake.nix |
| ALEPH-L003 | Module missing `_class` attribute | Expected `_class = "<kind>"` |
| ALEPH-L004 | Wrong `_class` for directory | Got `"<actual>"`, expected `"<expected>"` |
