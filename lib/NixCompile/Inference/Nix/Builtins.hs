{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                // inference // nix // builtins
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Everything was built, nothing was born."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--   The builtin typing prelude: hand-maintained signatures for `builtins.*`,
--   the polymorphic-scheme table for the bare names, and the starting
--   'builtinEnv'. 'builtinsFieldScheme' is the selection interceptor that makes
--   `builtins.<name>` / `lib.<name>` instantiate fresh per use.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Inference.Nix.Builtins (
  builtinEnv,
  builtinSchemeTable,
  builtinsFieldScheme,
)
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nix.Expr.Types (NExprF (..), NKeyName (..))
import Nix.Expr.Types.Annotated (NExprLoc)
import NixCompile.Inference.Nix.Environment
import NixCompile.Inference.Nix.Lib (libSchemeTable)
import NixCompile.Inference.Nix.Type
import NixCompile.Syntax.Annotation (varNameText, pattern Layer)

{- | Polymorphic builtins as SCHEMES, instantiated fresh at each use site. They
cannot be stored in the 'builtins' record as monotypes — that would prematurely
monomorphize them (every use would share one set of vars). This table backs both
the bare names and `builtins.<name>` (via 'builtinsFieldScheme').
-}
builtinSchemeTable :: Map Text Scheme
builtinSchemeTable = Map.union polymorphicListBuiltins rowBuiltins
 where
  polymorphicListBuiltins =
    Map.fromList
      [ ("head", scheme1 (\a -> TFun (TList a) a))
      , ("tail", scheme1 (\a -> TFun (TList a) (TList a)))
      , ("length", scheme1 (\a -> TFun (TList a) TInt))
      , ("elemAt", scheme1 (\a -> TFun (TList a) (TFun TInt a)))
      , ("filter", scheme1 (\a -> TFun (TFun a TBool) (TFun (TList a) (TList a))))
      , ("concatLists", scheme1 (\a -> TFun (TList (TList a)) (TList a)))
      , ("map", scheme2 (\a b -> TFun (TFun a b) (TFun (TList a) (TList b))))
      , ("concatMap", scheme2 (\a b -> TFun (TFun a (TList b)) (TFun (TList a) (TList b))))
      , ("foldl'", scheme2 (\a b -> TFun (TFun b (TFun a b)) (TFun b (TFun (TList a) b))))
      ]
  -- row-polymorphic attribute-set builtins: reject non-records, return the
  -- right shape. `getAttr` is value-dependent so its result stays TAny.
  rowBuiltins =
    Map.fromList
      [ ("attrNames", schemeRow (\r -> TFun (openRec r) (TList TString)))
      , ("attrValues", schemeRow (\r -> TFun (openRec r) (TList TAny)))
      , ("hasAttr", schemeRow (\r -> TFun TString (TFun (openRec r) TBool)))
      , ("getAttr", schemeRow (\r -> TFun TString (TFun (openRec r) TAny)))
      , ("removeAttrs", schemeRow (\r -> TFun (openRec r) (TFun (TList TString) (openRec r))))
      ]
  openRec r = TRec Map.empty (ROpen r)
  scheme1 builder = let a = TypeVar 0 in Forall [a] (builder (TVar a))
  scheme2 builder = let a = TypeVar 0; b = TypeVar 1 in Forall [a, b] (builder (TVar a) (TVar b))
  schemeRow builder = let r = TypeVar 0 in Forall [r] (builder r)

{- | If a selection is `<ns>.<name>` for a modeled namespace (`builtins`, `lib`),
return the field's polymorphic scheme (to be instantiated fresh). This is what
makes `builtins.attrNames` row-polymorphic and `lib.mkIf` reusable at many
result types even though the namespace record itself holds monotypes. n.b. a
purely syntactic check on the namespace symbol; locally shadowing it
(pathological) is not handled.
-}
builtinsFieldScheme :: NExprLoc -> NonEmpty (NKeyName NExprLoc) -> Maybe Scheme
builtinsFieldScheme base (StaticKey k :| [])
  | isNamespaceVar "builtins" base = Map.lookup (varNameText k) builtinSchemeTable
  | isNamespaceVar "lib" base = Map.lookup (varNameText k) libSchemeTable
builtinsFieldScheme _ _ = Nothing

isNamespaceVar :: Text -> NExprLoc -> Bool
isNamespaceVar name (Layer (NSym n)) = varNameText n == name
isNamespaceVar _ _ = False

builtinEnv :: TypeEnv
builtinEnv =
  TypeEnv
    { envBindings = builtinBindings
    , envWith = Nothing
    , envImportTypes = Map.empty
    , envLenient = False
    , envModuleParams = False
    }
 where
  -- ── core type scheme helpers ──────────────────────────────────
  mono type_ = Forall [] type_
  req type_ = (type_, False)

  -- ── builtins attrset ──────────────────────────────────────────
  -- 'builtins' itself is typed as attrset of all function entries
  builtinsAttr = Map.singleton "builtins" (mono $ TAttrs builtinsTypes)
  -- n.b. polymorphic/row builtins live in the top-level 'builtinSchemeTable'
  -- as SCHEMES (instantiated fresh per use) — they cannot be baked into the
  -- 'builtins' record as monotypes without prematurely monomorphizing them.
  -- The same table backs `builtins.<name>` via selection interception (see
  -- 'builtinsFieldScheme').
  builtinBindings =
    Map.union builtinsAttr (Map.union builtinSchemeTable (Map.map (mono . fst) builtinsTypes))

  -- n.b. hand-maintained signatures — must stay in sync with nixpkgs
  builtinsTypes :: Map Text (NixType, Bool)
  builtinsTypes =
    Map.fromList $
      map
        (\(name, type_) -> (name, req type_))
        -- ── string / path conversions ──
        [ ("toString", TFun (TUnion [TInt, TFloat, TBool, TPath, TString]) TString)
        , ("baseNameOf", TFun TPath TString)
        , ("dirOf", TFun TPath TPath)
        , ("stringLength", TFun TString TInt)
        , ("substring", TFun TInt (TFun TInt (TFun TString TString)))
        , ("replaceStrings", TFun (TList TString) (TFun (TList TString) (TFun TString TString)))
        , -- ── list operations ──
          ("head", TFun (TList TAny) TAny)
        , ("tail", TFun (TList TAny) (TList TAny))
        , ("length", TFun (TList TAny) TInt)
        , ("elemAt", TFun (TList TAny) (TFun TInt TAny))
        , ("filter", TFun (TFun TAny TBool) (TFun (TList TAny) (TList TAny)))
        , ("map", TFun (TFun TAny TAny) (TFun (TList TAny) (TList TAny)))
        , ("foldl'", TFun (TFun TAny (TFun TAny TAny)) (TFun TAny (TFun (TList TAny) TAny)))
        , ("concatLists", TFun (TList (TList TAny)) (TList TAny))
        , ("concatMap", TFun (TFun TAny (TList TAny)) (TFun (TList TAny) (TList TAny)))
        , -- ── attribute set introspection ──
          -- n.b. record args are TAny here; real row-polymorphic signatures
          -- for these land in rows stage 4 (these feed the `builtins.X` path).
          ("attrNames", TFun TAny (TList TString))
        , ("attrValues", TFun TAny (TList TAny))
        , ("hasAttr", TFun TString (TFun TAny TBool))
        , ("getAttr", TFun TString (TFun TAny TAny))
        , ("removeAttrs", TFun TAny (TFun (TList TString) TAny))
        ,
          ( "listToAttrs"
          , TFun
              (TList (TAttrs (Map.fromList [("name", (TString, False)), ("value", (TAny, False))])))
              TAny
          )
        , -- ── type predicates ──
          ("isNull", TFun TAny TBool)
        , ("isInt", TFun TAny TBool)
        , ("isFloat", TFun TAny TBool)
        , ("isBool", TFun TAny TBool)
        , ("isString", TFun TAny TBool)
        , ("isList", TFun TAny TBool)
        , ("isAttrs", TFun TAny TBool)
        , ("isFunction", TFun TAny TBool)
        , ("isPath", TFun TAny TBool)
        , -- ── arithmetic ──
          ("add", TFun TInt (TFun TInt TInt))
        , ("sub", TFun TInt (TFun TInt TInt))
        , ("mul", TFun TInt (TFun TInt TInt))
        , ("div", TFun TInt (TFun TInt TInt))
        , ("lessThan", TFun TInt (TFun TInt TBool))
        , -- ── file / derivation I/O ──
          ("import", TFun TPath TAny)
        , ("readFile", TFun TPath TString)
        , ("toPath", TFun TString TPath)
        , ("derivation", TFun TAny TDerivation)
        , -- ── control flow / debugging ──
          ("throw", TFun TString TAny)
        , ("abort", TFun TString TAny)
        , ("trace", TFun TString (TFun TAny TAny))
        , ("seq", TFun TAny (TFun TAny TAny))
        , ("deepSeq", TFun TAny (TFun TAny TAny))
        ,
          ( "tryEval"
          , TFun
              TAny
              (TAttrs (Map.fromList [("success", (TBool, False)), ("value", (TAny, False))]))
          )
        ]
