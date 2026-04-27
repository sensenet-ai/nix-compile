# Nix Type Inference

nix-compile implements Hindley-Milner type inference with row polymorphism for the Nix expression language.

## Type system

```
NixType ::= TInt | TFloat | TBool | TString | TStrLit "text"
          | TPath | TNull | TDerivation | TAny
          | TVar a
          | TList NixType
          | TFun NixType NixType
          | TAttrs { name : (NixType, optional?) }      -- closed
          | TAttrsOpen { name : (NixType, optional?) }   -- open (row variable)
          | TUnion [NixType]
```

### Key features

- **Type schemes** (`forall a b. a -> b -> a`) -- let-bound values are generalized.
- **Row polymorphism** -- `TAttrs` is a closed set (exact fields), `TAttrsOpen` is an open set (at least these fields, maybe more). Function arguments `{ x, y, ... }: ...` produce open sets.
- **SCC-based let generalization** -- mutually recursive let bindings are grouped by strongly connected component and generalized together.
- **`__functor` support** -- attrsets with a `__functor` attribute are callable.
- **Union types** -- `TUnion [TInt, TString]` for branches with different types.

## What it handles

| Nix construct | Typing rule |
|---|---|
| `42` | `TInt` |
| `"hello"` | `TString` |
| `true` / `false` | `TBool` |
| `./path` | `TPath` |
| `null` | `TNull` |
| `[1 2 3]` | `TList TInt` |
| `{ x = 1; y = "a"; }` | `TAttrs { x: TInt, y: TString }` |
| `x: x + 1` | `TFun TInt TInt` |
| `{ x, y }: x + y` | `TFun (TAttrsOpen { x: TInt, y: TInt }) TInt` |
| `let x = 1; in x` | `TInt` (generalized in let) |
| `if c then 1 else "a"` | `TUnion [TInt, TString]` |
| `a // b` | Attrset merge (right overrides left) |
| `a ++ b` | `TList elem` (both must be lists of same type) |
| `import ./file.nix` | Type of the imported expression |

## What it skips

Files using these constructs are **skipped** rather than producing wrong results:

- `with expr;` -- makes scope analysis unsound
- `rec { }` -- enables non-termination, complicates analysis
- Dynamic attribute names (`${expr}` as attrset key) -- can't determine field names statically

The `detectUnsupported` function in the CLI identifies these before inference runs.

## Builtins

~40 Nix builtins have typed signatures, including:

```
builtins.map     : (a -> b) -> [a] -> [b]
builtins.filter  : (a -> Bool) -> [a] -> [a]
builtins.length  : [a] -> Int
builtins.attrNames : { ... } -> [String]
builtins.hasAttr : String -> { ... } -> Bool
builtins.elem    : a -> [a] -> Bool
builtins.toString : a -> String
builtins.import  : Path -> a
```

## Output

`nix-compile fmt` inserts type annotations as comments:

```nix
# :: Int -> Int -> Int
add = x: y: x + y;

# :: { name : String, value : Int } -> String
format = { name, value }: "${name}: ${toString value}";
```
