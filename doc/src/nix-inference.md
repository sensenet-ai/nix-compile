# Nix Type Inference

nix-compile implements Hindley-Milner type inference with row polymorphism for the Nix expression language. The engine lives in `lib/NixCompile/Nix/Infer.hs` (~1,000 lines) with support types in `lib/NixCompile/Nix/Types.hs`.

## 1. Type system

### Grammar

```
NixType ::=
    TVar TypeVar              -- unification variable (α, β, ...)
  | TInt                      -- integer
  | TFloat                    -- float
  | TBool                     -- boolean
  | TString                   -- string (interpolated or unknown content)
  | TStrLit "text"            -- known string literal
  | TPath                     -- filesystem path
  | TNull                     -- null
  | TDerivation               -- derivation (build recipe)
  | TAny                      -- top type (escapes the type system)
  | TList NixType             -- homogeneous list
  | TFun NixType NixType      -- function (curried)
  | TAttrs { name : (NixType, Bool) }     -- closed record (exact fields)
  | TAttrsOpen { name : (NixType, Bool) } -- open record (row polymorphism)
  | TUnion [NixType]          -- sum / union (least upper bound)
```

Each field in `TAttrs` / `TAttrsOpen` carries a `Bool` marking it optional (`?` in Nix patterns, e.g. `{ name, value ? 42 }:`). Non-optional fields trigger an error if missing or unmatched during unification.

### Type schemes

```
Scheme = Forall [TypeVar] NixType
```

Type schemes bind zero or more universally quantified type variables over a monotype. `Forall [] TInt` is a monomorphic scheme (no polymorphism). A scheme like `Forall [α, β] (α -> β -> α)` represents `∀α β. α → β → α`.

Schemes are instantiated at each use site by replacing quantified variables with fresh `TVar` values — this is the core of HM let-polymorphism.

### Substitution

```
type Subst = Map TypeVar NixType
```

A substitution maps type variables to types. Key operations:

- `singleSubst v t` — singleton mapping `{v ↦ t}`
- `composeSubst s1 s2` — composes two substitutions: `s1 ∘ s2`, applying `s1` to values in `s2` then unioning
- `applySubst s t` — applies a substitution to a type, following transitive chains (TVar resolution is recursive)
- `applySubstScheme s (Forall vars t)` — applies to a scheme, skipping the quantified variables

The inference state carries a global substitution (`inferSubst`) that grows monotonically: each binding pushes a `singleSubst` that gets composed onto the existing one.

## 2. Row polymorphism

### TAttrs (closed)

`TAttrs fields` represents a fully-determined record. All fields are known statically. This is the type of literal attribute sets:

```nix
{ x = 1; y = "hello"; }
-- type: TAttrs { x: Int, y: String }
```

Unifying two `TAttrs` requires the same keys. Any key present in one but not the other with `required=True` triggers a type error.

### TAttrsOpen (open)

`TAttrsOpen fields` represents a record with *at least* the given fields, possibly more. This models the "..." (variadic) pattern:

```nix
{ x, y, ... }: x + y
-- param type: TAttrsOpen { x: Int, y: Int }
-- full type:  TFun (TAttrsOpen { x: Int, y: Int }) Int
```

When a function parameter is declared as a set pattern with `Variadic`, the inference engine creates `TAttrsOpen` (`Infer.hs:672`). This way, if the function is called with `{ x = 1; y = 2; z = 3; }` the extra field `z` does not cause a type error — open records accept unknown fields.

### Unification rules for records

| lhs | rhs | rule |
|-----|-----|------|
| `TAttrs m1` | `TAttrs m2` | exact key match, unify shared field types |
| `TAttrsOpen m1` | `TAttrsOpen m2` | unify only common-key types; extras ok |
| `TAttrs closed` | `TAttrsOpen open` | closed must contain all open keys; unify common types |
| `TAttrsOpen open` | `TAttrs closed` | symmetric to above |

The bool flag (optional) propagates across unification: fields present in one record but absent in another are tolerated as long as they are marked optional.

### The `//` operator (NUpdate)

The attrset update operator `a // b` is handled at `Infer.hs:640-650`. It merges two records (right overrides left):

```nix
{ x = 1; } // { y = 2; }
-- type: TAttrs { x: Int, y: Int }
```

If either operand is open, the result is open. The right-hand fields override left-hand fields of the same name.

## 3. Let-polymorphism via SCC-based generalization

### The problem

Naive let-inference without generalization would monomorphize every binding. Consider:

```nix
let id = x: x;
in { a = id 1; b = id true; }
```

Without generalization, `id` would be inferred as `Int → Int` at its first use and the second use would fail. HM let-polymorphism solves this by generalizing the let-binding's type, producing the scheme `∀α. α → α`.

### SCC grouping

Mutually recursive bindings must be inferred together. `inferLet` (`Infer.hs:881`) uses `Data.Graph.stronglyConnComp` to partition let-bindings into strongly connected components:

1. Each binding is parsed into `(name, expr, span)` triples via `parseBinding` (`Infer.hs:820`)
2. `collectFreeVars` walks the expression to find its free variable references
3. `buildEdge` connects each binding name to the bound names it references
4. `stronglyConnComp` returns SCCs sorted in dependency order
5. Each SCC is inferred stepwise via `inferLetGroup`

### Generalization algorithm

After inferring a group of bindings, `generalize` (`Infer.hs:935`) computes the type scheme:

1. Apply the current substitution to resolve all type variables
2. Collect free type variables in the binding's type: `freeTypeVars t'`
3. Collect free type variables in the *environment* (all previously-bound names): `freeInEnv`
4. Quantify over `freeInT \ freeInEnv` — only variables not mentioned by outer scopes
5. Package as `Forall quantifiedVars t'`

This follows the standard HM rule: generalise over variables not free in the environment. Acyclic SCCs (single bindings without self-reference) and cyclic SCCs (mutually recursive groups) are both generalised after inference, then added to the environment for use by downstream bindings and the body.

### Recursive bindings

Recursive (`rec { }`) and mutually-recursive `let` groups are handled identically: all names in the SCC are pre-allocated fresh type variables and inserted into scope, then each binding is inferred against that extended environment and unified with its pre-allocated variable. After unification, `checkInfinite` (`Infer.hs:725`) verifies that each variable resolved to something concrete — if it remains a bare `TVar`, the binding is self-referencing with no external constraint (e.g. `rec { x = x; }`), which is flagged as an infinite type error.

## 4. Unification algorithm

### Core unify (`Infer.hs:276-315`)

`unify t1 t2` applies the current substitution to both types, then dispatches to `unify'` for structural comparison:

| case | action |
|------|--------|
| `TVar v` with `t` | bind `v ↦ t` (with occurs check) |
| `TAny` with `_` | vacuously true — TAny is the top type |
| `TInt`/`TFloat`/`TBool`/`TString`/`TPath`/`TNull`/`TDerivation` | succeed when identical |
| `TString` with `TStrLit _` | string literals are subtypes of string (both directions ok) |
| `TStrLit` with `TStrLit` | succeed (lit-to-lit is allowed) |
| `TList a` with `TList b` | unify `a` with `b` |
| `TFun a1 b1` with `TFun a2 b2` | unify `a1` with `a2`, then `b1` with `b2` |
| `TAttrs`/`TAttrsOpen` combos | per the row polymorphism rules above |
| `TUnion ts` with `t` | check that `t` is a member of the union (or a TVar) |
| `TFun` with attrs | attempt `__functor` protocol resolution |
| anything else | type mismatch error |

### Occurs check (`Infer.hs:325-333`)

Prevents infinite types (e.g. `λx. x x`) by checking whether a type variable appears free inside the type it's being bound to. `occursCheck v t` traverses all compound types (TList, TFun, TAttrs, TUnion) and checks for `v`. If found, it signals `"infinite type"`.

### Type merging (join / LUB)

`mergeTypes` (`Infer.hs:394`) differs from `unify` — instead of asserting equality, it computes a common supertype:

| case | result |
|------|--------|
| `TVar` with `t` | bind var → t, return t |
| `TAny` with `_` | return `TAny` |
| `TList a` with `TList b` | merge elements, produce `TList (merge a b)` |
| `TFun a1 b1` with `TFun a2 b2` | unify domains, merge codomains |
| `TAttrs m1` with `TAttrs m2` | field-by-field merge via `mergeAttrs` |
| identical types | return as-is |
| otherwise | produce `TUnion [a, b]` |

`mergeAttrs` (`Infer.hs:418`) unions the keysets: shared keys get their types merged; keys present in only one record are marked optional.

This is used for `if-then-else` branches, list elements, and the `//` operator — anywhere two types must coexist rather than be proven equal.

## 5. Special handling

### Import resolution (`Infer.hs:525-534`)

`inferAppWithImport` intercepts function applications where the argument is a path literal. Before falling through to standard application inference, it checks `envImportTypes` — a cache of previously-imported modules' types (populated by `extendImport`). If the import path is known, the cached type is returned directly (after substitution). This enables cross-module type inference without re-parsing and re-inferring imported files.

Path extraction via `extractImportPathLiteral` handles `./path`, string literals containing paths, and double-quoted strings.

### With-scope resolution (`Infer.hs:506-514, 587-604`)

`inferWith` evaluates the scope expression, stashes its type in `envWith` on the environment, then infers the body. The fresh memo cache (`inferWithMemo`) is reset for each `with` block.

When `inferSymbol` encounters an unknown name that isn't in the explicit environment, it falls back to `envWith`:

1. Check the memo cache — if the field was already constrained, reuse the cached type
2. Otherwise: allocate a fresh `TVar`, constrain the scope type to contain that field via `fieldConstraint`, apply substitution to resolve, and cache the result

`fieldConstraint` (`Infer.hs:436`) handles three cases:
- **Scope is `TAttrs`/`TAttrsOpen`**: look up the field; if found, unify the value type with the expected type
- **Scope is `TVar`**: unify the scope variable against `TAttrsOpen { name: valueT, ... }` — this constrains the scope type to be a record containing at least that field
- **Otherwise**: no-op (if scope type is, say, `TInt`, the `with` resolved to nothing meaningful)

The memo cache prevents repeated unification of the same field name, making `with` resolution practical for large scopes.

### Functor protocol (`Infer.hs:264-273`)

Nix supports callable attribute sets through the `__functor` convention: if an attrset contains a field `__functor` whose type is a function, that attrset is callable. `unifyFunctor` checks the attrset for `__functor :: TFun _ innerT` and unifies `innerT` with the expected function type.

This is triggered when `unify'` encounters a `TFun` ↔ attrset mismatch:

```nix
let mkSetter = {
  __functor = self: x: x + 1;
};
in mkSetter 5          -- resolves via functor protocol
```

If `__functor` is present but not a `TFun`, an explicit error is raised. If absent, the standard type mismatch error fires.

## 6. Builtin type signatures

The inference environment starts from `builtinEnv` (`Infer.hs:102-177`), which provides monomorphic type signatures for 42+ Nix builtins. Each is stored both as a top-level `"builtins"` key (an attrset containing all builtin entries) and individually for direct reference.

### String / path conversions

| builtin | signature |
|---------|-----------|
| `toString` | `Int \| Float \| Bool \| Path \| String → String` |
| `baseNameOf` | `Path → String` |
| `dirOf` | `Path → Path` |
| `stringLength` | `String → Int` |
| `substring` | `Int → Int → String → String` |
| `replaceStrings` | `[String] → [String] → String → String` |

### List operations

| builtin | signature |
|---------|-----------|
| `head` | `[a] → a` |
| `tail` | `[a] → [a]` |
| `length` | `[a] → Int` |
| `elemAt` | `[a] → Int → a` |
| `filter` | `(a → Bool) → [a] → [a]` |
| `map` | `(a → b) → [a] → [b]` |
| `foldl'` | `(a → b → a) → a → [b] → a` |
| `concatLists` | `[[a]] → [a]` |
| `concatMap` | `(a → [b]) → [a] → [b]` |

### Attribute set introspectors

| builtin | signature |
|---------|-----------|
| `attrNames` | `{ ... } → [String]` |
| `attrValues` | `{ ... } → [a]` |
| `hasAttr` | `String → { ... } → Bool` |
| `getAttr` | `String → { ... } → a` |
| `removeAttrs` | `{ ... } → [String] → { ... }` |
| `listToAttrs` | `[{ name: String, value: a }] → { ... }` |

### Type predicates

| builtin | signature |
|---------|-----------|
| `isNull` | `a → Bool` |
| `isInt` | `a → Bool` |
| `isFloat` | `a → Bool` |
| `isBool` | `a → Bool` |
| `isString` | `a → Bool` |
| `isList` | `a → Bool` |
| `isAttrs` | `a → Bool` |
| `isFunction` | `a → Bool` |
| `isPath` | `a → Bool` |

### Arithmetic, I/O, and control flow

| builtin | signature |
|---------|-----------|
| `add`, `sub`, `mul`, `div` | `Int → Int → Int` |
| `lessThan` | `Int → Int → Bool` |
| `import` | `Path → a` |
| `readFile` | `Path → String` |
| `toPath` | `String → Path` |
| `derivation` | `{ ... } → Derivation` |
| `throw`, `abort` | `String → a` |
| `trace` | `String → a → a` |
| `seq`, `deepSeq` | `a → b → b` |
| `tryEval` | `a → { success: Bool, value: a }` |

### How signatures interact with inference

Builtin types are stored as monomorphic `Scheme`s (`Forall [] type`). At lookup time, `inferSymbol` calls `instantiate`, which allocates fresh `TVar`s for any quantified variables. This means polymorphic builtins like `map : (a → b) → [a] → [b]` get fresh type variables `α`, `β` at each use site, enabling independent instantiation.

The `builtinsTypes` list also carries a `Bool` flag (currently unused at runtime) that historically marked functions as being "pure" for potential optimization.

## 7. Example inference walkthroughs

### Example 1: simple function

```nix
x: x + 1
```

1. **Lambda**: allocate fresh `α` for `x`, extend env with `x : α`
2. **Body** (`x + 1` via `NPlus`): infer `x` → `α`, infer `1` → `Int`. Unify `α = Int`. Return `Int`.
3. Result: `α → Int` with `α = Int` → `Int → Int`

### Example 2: set pattern with default

```nix
{ name, value ? 42 }: "${name}: ${toString value}"
```

1. **ParamSet**: `name` gets fresh `α`, `value` gets `Int` (from the default `42`)
2. Variadic → `TAttrsOpen { name: α, value: Int }`
3. **Body**: string interpolation → `TString`, context constrains `name : String` so `α = String`
4. Result: `TFun (TAttrsOpen { name: String, value: Int }) String`

### Example 3: let-polymorphism

```nix
let id = x: x; in { a = id 1; b = id true; }
```

1. **SCC**: single acyclic component `[id]`
2. **Infer `id`**: param gets fresh `α`, body returns `α` → type `α → α`
3. **Generalize**: `freeInT = {α}`, `freeInEnv = {}` → `Forall [α] (α → α)`
4. **Body `id 1`**: instantiate → `β → β`, unify `β = Int` → result `Int`
5. **Body `id true`**: instantiate → `γ → γ`, unify `γ = Bool` → result `Bool`
6. **Merge**: `mergeTypes Int Bool` → `TUnion [Int, Bool]`
7. Result: `TAttrs { a: Int, b: Bool }`

### Example 4: with scope

```nix
with lib;
let sum = foldl' add 0;
in sum [1 2 3]
```

1. **Infer `lib`**: suppose it has type `TAttrs { foldl': (a→b→a)→a→[b]→a, add: Int→Int→Int, ... }`
2. **`inferWith`**: store scope type in `envWith`, reset memo cache
3. **`foldl'` lookup**: not in explicit env, falls to `resolveWithScope` → fresh `α`, constrain `lib` field → resolved as `(a→b→a)→a→[b]→a`
4. **`add` lookup**: not in explicit env, memoized from step 3 → `Int→Int→Int`
5. Subsequent lookups in the same `with` block hit the memo cache, avoiding re-unification

### Example 5: functor protocol

```nix
let mkAdder = {
  __functor = self: x: y: x + y;
};
in mkAdder 2 3
```

1. **`mkAdder`**: `TAttrs { __functor: α → Int → Int → Int }`
2. **`mkAdder 2`**: `inferApp` expects `TFun arg result` for `mkAdder`, gets `TAttrs { ... }`
3. **`unify`** sees `TFun` / `TAttrs` mismatch → `unifyFunctor`
4. **`unifyFunctor`** finds `__functor : α → Int → Int → Int`, extracts inner `TFun Int (TFun Int Int)` → unifies app result with `Int → Int`
5. Result: `Int → Int` at `mkAdder 2`, `Int` at `mkAdder 2 3`

## 8. Inference environment

### TypeEnv structure

```
TypeEnv = TypeEnv
  { envBindings    :: Map Text Scheme    -- explicit name → scheme bindings
  , envWith        :: Maybe NixType      -- active `with` scope type
  , envImportTypes :: Map FilePath NixType -- cached imported module types
  }
```

### Name resolution priority (`inferSymbol`)

1. `lookupEnv` — explicit bindings (let, lambda params, builtins)
2. `envWith` — active `with` scope (with memo cache)
3. Fresh type variable — unconstrained fallback

### Cross-module inference

```haskell
extendImport :: FilePath -> NixType -> TypeEnv -> TypeEnv
extendImport path t env = env{envImportTypes = Map.insert path t (envImportTypes env)}
```

When a file is imported, its inferred type is registered. Subsequent import applications (`import ./other.nix`) short-circuit to the cached type, avoiding redundant inference. This is handled transparently in `inferAppWithImport`.

## 9. Error reporting

Errors are reported via `ExceptT Text` in the `Infer` monad. `throwTypeError` (`Infer.hs:225-230`) annotates the message with the current source span (file, line, column):

```haskell
throwTypeError :: Text -> Infer a
throwTypeError msg = do
    mSpan <- gets inferSpan
    case mSpan of
        Just (Span (Loc l c) _ _ _) ->
            throwError $ T.pack (show l) <> ":" <> T.pack (show c) <> ": " <> msg
        Nothing -> throwError msg
```

Error categories:

| error | trigger |
|-------|---------|
| `type mismatch: expected X, got Y` | unification of incompatible types |
| `infinite type: α occurs in β → α` | occurs check failure (self-application) |
| `infinite type: rec binding 'x' has no concrete constraint` | recursive binding that never resolves (e.g., `rec { x = x; }`) |
| `missing required field: name` | closed record lacks a non-optional field required by the other side |
| `unexpected field (required in other): name` | symmetric to above |
| `closed set missing fields required by open set: ...` | `TAttrs` unified with `TAttrsOpen` but missing keys |
| `__functor must be a function, got X` | attrset has `__functor` field but it's not a `TFun` |
| `type mismatch: expected one of A \| B, got C` | union membership check failed |

All spans originate from the Nix parser's source locations, propagated into `InferState` via `withSpan` (`Infer.hs:216-222`) as expressions are recursively traversed.

## 10. Limitations and skipped constructs

The following Nix constructs are **not** type-inferred. The CLI's `detectUnsupported` function identifies them before inference runs and skips the file to avoid producing incorrect results:

| construct | why skipped |
|-----------|-------------|
| `with expr;` | makes lexical scope dynamically dependent on a runtime value; scope graph unsound |
| `rec { }` at file top-level | enables non-termination through infinite recursion without a base case |
| dynamic attrset keys (`${expr}`) | field names cannot be determined statically |

These are pragmatic decisions: attempting to infer types for these cases would require either a radically different approach (symbolic execution) or would produce unsound results.
