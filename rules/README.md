# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                                       // rules
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#     "Wintermute could build a kind of personality into a shell. How subtle
#      a form could manipulation take?"
#
#                                                                  — Neuromancer

AST-based lint rules for tree-sitter powered linters.

These rules complement `nix-compile`'s built-in analysis with pattern-based
detection for common antipatterns and policy violations.


# ══════════════════════════════════════════════════════════════════════════════
#                                                                    // profiles
# ══════════════════════════════════════════════════════════════════════════════

Rules are organized into profiles. Use the one that fits your project:

| Profile | Description | `non-lisp-case` |
|---------|-------------|-----------------|
| `strict` | Full aleph conventions | **error** |
| `standard` | Sensible defaults (recommended) | off |
| `minimal` | Essential safety only | off |
| `nixpkgs` | nixpkgs contribution guidelines | off |
| `security` | Security-focused checks | off |

```bash
# use a profile
nix-compile-lint --profile standard nix/

# strict mode for straylight projects
nix-compile-lint --profile strict nix/
```


# ══════════════════════════════════════════════════════════════════════════════
#                                                             // configuration
# ══════════════════════════════════════════════════════════════════════════════

Create `.nix-compile.dhall` in your project root:

```dhall
let NixCompile = ./config/package.dhall

let Severity = NixCompile.Severity

in  NixCompile.Config::{
    , profile = "standard"
    , extra-ignores = [ "vendor/**", "third-party/**" ]
    , overrides = [
        -- downgrade rec-anywhere to info
        NixCompile.override "rec-anywhere" Severity.Info
        -- enable lisp-case for this project (optional)
        -- , NixCompile.override "non-lisp-case" Severity.Warning
      ]
    }
```


# ══════════════════════════════════════════════════════════════════════════════
#                                                                   // nix rules


## // policy // enforcement

| Rule | Severity | Description |
|------|----------|-------------|
| `rec-anywhere` | error | Recursive attrsets obscure dependency flow |
| `with-lib` | error | `with lib;` breaks tooling and creates shadowing hazards |
| `no-substitute-all` | error | Text templating must use Dhall |
| `no-raw-mkderivation` | error | Use prelude wrappers |
| `no-raw-runcommand` | error | Use prelude wrappers |
| `no-raw-writeshellapplication` | error | Use prelude wrappers |
| `no-translate-attrs-outside-prelude` | error | Translation happens in prelude only |


## // best // practices

| Rule | Severity | Description |
|------|----------|-------------|
| `prefer-write-shell-application` | error | Use `writeShellApplication` over `writeShellScript` |
| `no-heredoc-in-inline-bash` | error | Heredocs in Nix strings are fragile |
| `or-null-fallback` | warning | Prefer explicit null handling |
| `long-inline-string` | warning | Long strings should be external files |


## // derivation // quality

| Rule | Severity | Description |
|------|----------|-------------|
| `missing-meta` | error | Derivations must have meta attributes |
| `missing-description` | error | Meta must include description |
| `missing-class` | error | Packages must declare their class |


## // naming // conventions

| Rule | Severity | Description |
|------|----------|-------------|
| `non-lisp-case` | error | All identifiers must use lisp-case (kebab-case) |
| `default-nix-in-packages` | error | Package directories must have default.nix |


# ══════════════════════════════════════════════════════════════════════════════
#                                                                  // cpp rules
# ══════════════════════════════════════════════════════════════════════════════


| Rule | Severity | Description |
|------|----------|-------------|
| `cpp-using-namespace-header` | error | No `using namespace` in headers |
| `cpp-ban-cuda-identifier` | error | CUDA identifiers must go through abstraction layer |
| `cpp-raw-new-delete` | error | Use smart pointers, not raw new/delete |
| `cpp-namespace-closing-comment` | warning | Closing braces should have namespace comment |


# ══════════════════════════════════════════════════════════════════════════════
#                                                                // rule format
# ══════════════════════════════════════════════════════════════════════════════


Rules use tree-sitter AST patterns in YAML:

```yaml
id: rule-name
language: nix
severity: error
ignores:
  - "path/to/ignore/**"
rule:
  kind: ast_node_type
  has:
    field: child_field_name
    kind: child_type
    regex: "pattern"
  any:
    - { kind: option1 }
    - { kind: option2 }
  all:
    - { kind: required1 }
    - { kind: required2 }
  not:
    kind: forbidden
  inside:
    kind: parent_type
message: "Short error message"
note: |
  ## What's wrong?
  Detailed explanation.

  ## What can I do to fix this?
  Suggested remediation with examples.
```


## // pattern // operators

| Operator | Meaning |
|----------|---------|
| `kind` | Match AST node type |
| `field` | Match specific child field |
| `regex` | Match node text against pattern |
| `has` | Node must have matching child |
| `any` | At least one pattern must match |
| `all` | All patterns must match |
| `not` | Pattern must not match |
| `inside` | Node must be inside matching ancestor |


## // tree-sitter // node // types

For Nix, common node types include:

```
source_expression
function_expression
apply_expression
select_expression
attrset_expression
rec_attrset_expression
with_expression
let_expression
if_expression
binding_set
binding
inherit
identifier
variable_expression
string_expression
indented_string_expression
interpolation
```

Use `tree-sitter parse` to explore the AST of specific code.


# ══════════════════════════════════════════════════════════════════════════════
#                                                                     // usage
# ══════════════════════════════════════════════════════════════════════════════


## // nix-compile-lint

The recommended way to run rules:

```bash
# lint with standard profile
./bin/nix-compile-lint nix/

# lint with strict profile (lisp-case enabled)
./bin/nix-compile-lint --profile strict nix/

# lint with custom config
./bin/nix-compile-lint --config my-config.dhall nix/

# verbose mode
./bin/nix-compile-lint -v nix/
```


## // with // ast-grep // directly

```bash
ast-grep scan --rule rules/rec-anywhere.yml path/to/nix/
```


## // with // custom // runner

These rules are designed for any tree-sitter-based linter that supports
YAML rule definitions. The pattern language is similar to:

- ast-grep
- semgrep (with adaptation)
- tree-sitter queries (structural similarity)


## // integration // with // nix-compile

`nix-compile` has built-in detection for some of these patterns:

| Rule | nix-compile equivalent |
|------|------------------------|
| `rec-anywhere` | `Nix.Lint.VRec` |
| `with-lib` | `Nix.Lint.VWith` |
| `no-heredoc-in-inline-bash` | `Lint.Forbidden.VHeredoc` |

For rules not covered by `nix-compile`, use these YAML rules with a
tree-sitter linter for comprehensive coverage.


# ══════════════════════════════════════════════════════════════════════════════
#                                                         // error // code // map
# ══════════════════════════════════════════════════════════════════════════════


| Code | Rule |
|------|------|
| ALEPH-E001 | `with-lib` |
| ALEPH-E003 | `non-lisp-case` |
| ALEPH-E006 | `no-heredoc-in-inline-bash` |
| ALEPH-E007 | `no-substitute-all` |
| ALEPH-W001 | `rec-anywhere` |
| ALEPH-W006 | `prefer-write-shell-application` |
| ALEPH-W007 | `missing-meta` |


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#     "Case was twenty-four. At twenty-two, he'd been a cowboy, a rustler,
#      one of the best in the Sprawl."
#
#                                                                  — Neuromancer

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                                 — b7r6 // 2026
