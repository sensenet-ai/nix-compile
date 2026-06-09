{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                        // nix // infer
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "They set a slamhound on Turner's trail."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // type // inference
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Inference.Nix (
  -- * Inference
  inferExpr,
  inferModuleExpr,
  inferExprWithEnv,
  inferFile,
  runInfer,
  unify,

  -- * Environment
  TypeEnv (..),
  emptyEnv,
  builtinEnv,
  extendEnv,
  extendImport,
  extendImports,
  lookupEnv,
  lookupImport,

  -- * Results
  InferResult (..),
  Binding (..),
)
where

import Control.Exception (IOException, try)
import Control.Monad (foldM, forM, forM_, replicateM, unless, when)
import Control.Monad.Except
import Control.Monad.State.Strict
import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.Functor.Compose (Compose (..))
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Atoms (NAtom (..))
import Nix.Expr.Types hiding (Binding)
import Nix.Expr.Types qualified as Nix
import Nix.Expr.Types.Annotated (AnnUnit (..), NExprLoc, nullSpan)
import Nix.Parser (parseNixFileLoc)
import Nix.Utils qualified as Nix
import NixCompile.Inference.Nix.Type
import NixCompile.Syntax.Annotation (srcSpanToSpan, varNameText, pattern Layer, pattern LayerAnn)
import NixCompile.Types (Loc (..), Span (..))

-- ═════════════════════════════════════════════════════════════════════════════
-- environment
-- ═════════════════════════════════════════════════════════════════════════════

data TypeEnv = TypeEnv
  { envBindings :: Map Text Scheme
  , envWith :: Maybe NixType
  , envImportTypes :: Map FilePath NixType
  , envLenient :: Bool
  {- ^ when True, treat unbound names as fresh polymorphic vars instead of
    errors. Used for backwards compatibility with libraries that mention
    builtins we don't yet model. Default: False (strict).
  -}
  , envModuleParams :: Bool
  {- ^ when True, lambda parameters whose names are well-known external module
    / flake inputs (self, inputs, config, pkgs, the @-bound input set, …) are
    typed as dynamic ('TAny') rather than fresh inference vars. These values are
    supplied by the flake / module system, not by the file under analysis, so
    inferring precise types for them only produces false positives (e.g. the
    self-referential @inputs in `mkFlake { inherit inputs; }`). Matched by name
    so ordinary inner lambdas (`x: x + 1`) keep precise inference. Default: False.
  -}
  }
  deriving (Eq, Show)

emptyEnv :: TypeEnv
emptyEnv = TypeEnv Map.empty Nothing Map.empty False False

{- | extend the env with one name → scheme binding
n.b. this shadows — if a name already exists the new scheme wins
-}
extendEnv :: Text -> Scheme -> TypeEnv -> TypeEnv
extendEnv name scheme environment = environment{envBindings = Map.insert name scheme (envBindings environment)}

-- | look up a name; returns Nothing if absent (type defaults to fresh var downstream)
lookupEnv :: Text -> TypeEnv -> Maybe Scheme
lookupEnv name environment = Map.lookup name (envBindings environment)

-- | register the exported type of an imported file
extendImport :: FilePath -> NixType -> TypeEnv -> TypeEnv
extendImport path t env = env{envImportTypes = Map.insert path t (envImportTypes env)}

-- | extend env with multiple imported modules at once
extendImports :: Map FilePath NixType -> TypeEnv -> TypeEnv
extendImports imports env = env{envImportTypes = Map.union imports (envImportTypes env)}

-- | look up a previously imported module's type
lookupImport :: FilePath -> TypeEnv -> Maybe NixType
lookupImport path env = Map.lookup path (envImportTypes env)

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

{- | Polymorphic schemes for the nixpkgs `lib` namespace, the library record
threaded through every flake-parts module and NixOS module as the `lib`
parameter. Like the builtins table these are SCHEMES (instantiated fresh per
use), so a single `lib.mkIf` may be applied at many result types — the whole
point: `{ lib }: { a = lib.mkIf c { x = 1; }; b = lib.mkIf c 2; }` must check.

Modeled structurally where the shape is stable (mkIf/mkMerge/mkDefault/… are
`a -> a`-shaped) and left permissive (TAny) where the real type is an
options-DSL value we don't model. There is no oracle coverage for module code
(it isn't a closed term), so permissive entries can't introduce soundness
mismatches — they only avoid false positives.
-}
libSchemeTable :: Map Text Scheme
libSchemeTable =
  Map.fromList
    [ -- module-system combinators: thread a value through unchanged
      ("mkIf", scheme1 (\a -> TFun TBool (TFun a a)))
    , ("mkMerge", scheme1 (\a -> TFun (TList a) a))
    , ("mkDefault", scheme1 (\a -> TFun a a))
    , ("mkForce", scheme1 (\a -> TFun a a))
    , ("mkOverride", scheme1 (\a -> TFun TInt (TFun a a)))
    , ("mkBefore", scheme1 (\a -> TFun a a))
    , ("mkAfter", scheme1 (\a -> TFun a a))
    , ("mkOptionDefault", scheme1 (\a -> TFun a a))
    , -- conditional attrset / list helpers
      ("optionalAttrs", scheme1 (\a -> TFun TBool (TFun a a)))
    , ("optional", scheme1 (\a -> TFun TBool (TFun a (TList a))))
    , ("optionals", scheme1 (\a -> TFun TBool (TFun (TList a) (TList a))))
    , ("optionalString", Forall [] (TFun TBool (TFun TString TString)))
    , -- string helpers
      ("concatStringsSep", Forall [] (TFun TString (TFun (TList TString) TString)))
    , ("makeBinPath", scheme1 (\a -> TFun (TList a) TString))
    , ("getExe", Forall [] (TFun TDerivation TString))
    , ("getExe'", Forall [] (TFun TDerivation (TFun TString TString)))
    , -- list/attr utilities whose precise row type we don't model: permissive
      ("mkOption", Forall [] (TFun TAny TAny))
    , ("mkEnableOption", Forall [] (TFun TString TAny))
    , ("mkPackageOption", Forall [] (TFun TAny TAny))
    , ("mapAttrs", Forall [] (TFun (TFun TString (TFun TAny TAny)) (TFun TAny TAny)))
    , ("filterAttrs", Forall [] (TFun (TFun TString (TFun TAny TBool)) (TFun TAny TAny)))
    , ("recursiveUpdate", Forall [] (TFun TAny (TFun TAny TAny)))
    , ("genAttrs", Forall [] (TFun (TList TString) (TFun TAny TAny)))
    , ("nameValuePair", Forall [] (TFun TString (TFun TAny TAny)))
    ]
 where
  scheme1 builder = let a = TypeVar 0 in Forall [a] (builder (TVar a))

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
  builtinBindings = Map.union builtinsAttr (Map.union builtinSchemeTable (Map.map (mono . fst) builtinsTypes))

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
        , ("listToAttrs", TFun (TList (TAttrs (Map.fromList [("name", (TString, False)), ("value", (TAny, False))]))) TAny)
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
        , ("tryEval", TFun TAny (TAttrs (Map.fromList [("success", (TBool, False)), ("value", (TAny, False))])))
        ]

-- ═════════════════════════════════════════════════════════════════════════════
-- inference state
-- ═════════════════════════════════════════════════════════════════════════════

{- | inference monad state
supply = fresh type-var counter; subst = current unifier substitution
binds = accumulated (name, type, span) triples for the output
span = current source location (for error messages)
withMemo = cache for `with` scope field lookups (avoids re-unification)
-}
data InferState = InferState
  { inferSupply :: !Int
  , inferSubst :: !Subst
  , inferBinds :: ![Binding]
  , inferSpan :: !(Maybe Span)
  , inferWithMemo :: !(Map Text NixType)
  }

-- | inference runs in EitherT over State: errors abort, state persists
type Infer a = ExceptT Text (State InferState) a

{- | run the inference monad, extracting final bindings
starts with empty substitution / fresh-var counter at 0
-}
runInfer :: Infer a -> Either Text (a, [Binding])
runInfer inference =
  let (eitherResult, inferState) = runState (runExceptT inference) (InferState 0 emptySubst [] Nothing Map.empty)
   in (\res -> (res, inferBinds inferState)) <$> eitherResult

-- ── emit a binding into the result list (prepended, reversed later) ──
emitBinding :: Text -> NixType -> Span -> Infer ()
emitBinding name t sp = modify $ \s ->
  s{inferBinds = Binding name t sp : inferBinds s}

-- ── run an action with a specific source span for error reporting ──
withSpan :: Span -> Infer a -> Infer a
withSpan sp action = do
  old <- gets inferSpan
  modify $ \s -> s{inferSpan = Just sp}
  res <- action
  modify $ \s -> s{inferSpan = old}
  pure res

-- ── abort inference with a type error annotated by source location ──
throwTypeError :: Text -> Infer a
throwTypeError msg = do
  mSpan <- gets inferSpan
  maybe (throwError msg) located mSpan
 where
  located (Span (Loc l c) _ _) = throwError $ T.pack (show l) <> ":" <> T.pack (show c) <> ": " <> msg

-- ── allocate a fresh type variable (monotonically increasing id) ──
freshVar :: Infer NixType
freshVar = TVar <$> freshTypeVar

-- | allocate a fresh type/row variable (the raw 'TypeVar', for row tails)
freshTypeVar :: Infer TypeVar
freshTypeVar = do
  s <- get
  put s{inferSupply = inferSupply s + 1}
  pure $ TypeVar (inferSupply s)

-- | build an open record with the given known fields and a FRESH row tail var
mkOpenRec :: Map Text (NixType, Bool) -> Infer NixType
mkOpenRec m = do
  r <- freshTypeVar
  pure (TRec m (ROpen r))

-- ── apply the current substitution to a type (idempotent with current subst) ──
applyCurrentSubst :: NixType -> Infer NixType
applyCurrentSubst t = do
  s <- gets inferSubst
  pure $ applySubst s t

{- | Extend the current substitution with @v ↦ t@.

We keep a TRIANGULAR substitution (a plain insert) rather than eagerly
composing. The old @composeSubst@ form re-walked and rewrote the entire
accumulated substitution on every bind — O(n) per bind, O(n²) over a program
with n unifications (RC4). 'applySubst' already chases transitively (the @TVar@
case recurses through bound vars), so resolution still fully normalises on read.

Soundness invariant: every caller binds @v@ to a @t@ that has already been
resolved against the current substitution ('applyCurrentSubst' in 'unify' /
'mergeTypes' / 'unifyRec'), and 'bindVar'/'bindRowVar' run the occurs check on
that resolved @t@. So @v@ is unbound and @t@ is ground w.r.t. current bindings at
insert time — the substitution stays acyclic and the on-read chase terminates.
-}
addSubst :: TypeVar -> NixType -> Infer ()
addSubst v t = modify $ \s ->
  s{inferSubst = Map.insert v t (inferSubst s)}

-- ═════════════════════════════════════════════════════════════════════════════
-- unification
-- ═════════════════════════════════════════════════════════════════════════════

-- ── unify: the core constraint solver ────────────────────────────

-- | report a mismatch between expected and actual types
typeMismatch :: NixType -> NixType -> Infer a
typeMismatch type1 type2 =
  throwTypeError $ "type mismatch: expected " <> prettyType type1 <> ", got " <> prettyType type2

{- | handle __functor protocol: if attrs has __functor, unify against its return type
n.b. this is how nix makes callable attribute sets
-}
unifyFunctor :: NixType -> NixType -> Infer ()
unifyFunctor funT attrsT
  | TAttrs m <- attrsT = lookupFunctor funT m
  | TAttrsOpen m <- attrsT = lookupFunctor funT m
  | otherwise = typeMismatch funT attrsT
 where
  lookupFunctor ft m = dispatch (Map.lookup "__functor" m)
   where
    dispatch (Just (TFun _ innerT, _)) = unify innerT ft
    dispatch (Just (ftFunctor, _)) = throwTypeError $ "__functor must be a function, got " <> prettyType ftFunctor
    dispatch Nothing = typeMismatch ft attrsT

-- | apply current subst, then unify the normalised forms
unify :: NixType -> NixType -> Infer ()
unify type1 type2 = do
  t1' <- applyCurrentSubst type1
  t2' <- applyCurrentSubst type2
  unify' t1' t2'

{- | structural unification — must be applied AFTER current substitution.
n.b. clause order is load-bearing: the patterns overlap (TFun/TFun before
the functor-protocol TFun/attrs, TUnion before that), exactly as the old
top-to-bottom `case (type1, type2)` required.
-}
unify' :: NixType -> NixType -> Infer ()
-- variable cases: bind one to the other (with occurs check)
unify' (TVar v) t = bindVar v t
unify' t (TVar v) = bindVar v t
-- TAny unifies with everything (dynamic / unknown)
unify' TAny _ = pure ()
unify' _ TAny = pure ()
-- base types: identical only
unify' TInt TInt = pure ()
unify' TFloat TFloat = pure ()
unify' TBool TBool = pure ()
unify' TString TString = pure ()
unify' (TStrLit _) (TStrLit _) = pure ()
unify' TString (TStrLit _) = pure ()
unify' (TStrLit _) TString = pure ()
unify' TPath TPath = pure ()
unify' TNull TNull = pure ()
unify' TDerivation TDerivation = pure ()
-- compound types: recurse structurally
unify' (TList a) (TList b) = unify a b
unify' (TFun a1 b1) (TFun a2 b2) = unify a1 a2 >> unify b1 b2
unify' (TRec m1 tl1) (TRec m2 tl2) = unifyRec m1 tl1 m2 tl2
-- union: check membership
unify' (TUnion ts) t = unifyUnion ts t
unify' t (TUnion ts) = unifyUnion ts t
-- function vs attrset: try functor protocol
unify' (TFun argT retT) attrsT = unifyFunctor (TFun argT retT) attrsT
unify' attrsT (TFun argT retT) = unifyFunctor (TFun argT retT) attrsT
unify' type1 type2 = typeMismatch type1 type2

-- | bind a type variable to a concrete type (with occurs check)
bindVar :: TypeVar -> NixType -> Infer ()
bindVar v t
  | t == TVar v = pure ()
  | occursCheck v t = throwTypeError $ "infinite type: " <> prettyType (TVar v) <> " occurs in " <> prettyType t
  | otherwise = addSubst v t

-- | occurs check: does v appear free inside t? (prevents infinite types)
occursCheck :: TypeVar -> NixType -> Bool
occursCheck v (TVar typeVariable') = v == typeVariable'
occursCheck v (TList t) = occursCheck v t
occursCheck v (TFun a b) = occursCheck v a || occursCheck v b
occursCheck v (TRec m tail_) =
  any (occursCheck v . fst) (Map.elems m) || rowHas tail_
 where
  rowHas (ROpen r) = v == r
  rowHas RClosed = False
occursCheck v (TUnion ts) = any (occursCheck v) ts
occursCheck _ _ = False

-- | unify two closed attr sets: all keys must match, required fields must exist
unifyAttrs :: Map Text (NixType, Bool) -> Map Text (NixType, Bool) -> Infer ()
unifyAttrs m1 m2 = forM_ (Set.toList allKeys) reconcile
 where
  allKeys = Set.union (Map.keysSet m1) (Map.keysSet m2)
  reconcile k = step (Map.lookup k m1) (Map.lookup k m2)
   where
    step (Just (t1, _)) (Just (t2, _)) = unify t1 t2
    step (Just (_, False)) Nothing = throwTypeError $ "missing required field: " <> k
    step Nothing (Just (_, False)) = throwTypeError $ "unexpected field (required in other): " <> k
    step _ _ = pure ()

{- | Unify two records, row-variable aware (RC1 core).

  * closed/closed: exact — delegated to 'unifyAttrs'.
  * open/closed: the open side's own required fields must exist in the closed
    side; the open tail var then absorbs the closed side's extra fields and is
    bound CLOSED.
  * open/open: common fields unified, and the two tail vars are bound to a
    SHARED fresh tail carrying each side's extra fields — so the field UNION is
    preserved across the unification (the old 'unifyAttrsOpenOpen' discarded it).

  The anonymous sentinel row var ('isAnonRowVar') is never bound, so pure
  flake/module display types keep their old open-world behavior.
-}
unifyRec :: Map Text (NixType, Bool) -> RowTail -> Map Text (NixType, Bool) -> RowTail -> Infer ()
unifyRec m1 tl1 m2 tl2 = dispatch tl1 tl2
 where
  dispatch RClosed RClosed = unifyAttrs m1 m2
  dispatch (ROpen r1) RClosed = unifyCommon >> closeAgainst r1 only1 only2
  dispatch RClosed (ROpen r2) = unifyCommon >> closeAgainst r2 only2 only1
  dispatch (ROpen r1) (ROpen r2)
    | isAnonRowVar r1 || isAnonRowVar r2 = unifyCommon
    | otherwise = do
        unifyCommon
        r3 <- freshTypeVar
        bindRowVar r1 (TRec only2 (ROpen r3))
        bindRowVar r2 (TRec only1 (ROpen r3))
  only1 = Map.difference m1 m2 -- fields known only on the left
  only2 = Map.difference m2 m1 -- fields known only on the right
  unifyCommon =
    mapM_ (\((t1, _), (t2, _)) -> unify t1 t2) (Map.elems (Map.intersectionWith (,) m1 m2))
  -- an open record (tail var r, own-only fields `openOnly`) meeting a closed
  -- side whose extras are `closedExtra`
  closeAgainst r openOnly closedExtra = do
    forM_ (Map.toList openOnly) $ \(k, (_, optional)) ->
      unless optional $
        throwTypeError ("closed record missing field required by open record: " <> k)
    unless (isAnonRowVar r) $ bindRowVar r (TRec closedExtra RClosed)

-- | bind a row variable (with row-occurs check; never binds the anon sentinel)
bindRowVar :: TypeVar -> NixType -> Infer ()
bindRowVar r t
  | isAnonRowVar r = pure ()
  | occursCheck r t = throwTypeError $ "recursive row type: " <> prettyType (TVar r) <> " occurs in " <> prettyType t
  | otherwise = addSubst r t

{- | unify a union (sum) type against a concrete type
single-element unions delegate; multi-element checks membership
-}
unifyUnion :: [NixType] -> NixType -> Infer ()
unifyUnion [] _ = pure ()
unifyUnion [t'] t = unify t' t
unifyUnion ts t = do
  t' <- applyCurrentSubst t
  ts' <- mapM applyCurrentSubst ts
  checkUnionMembership t' ts'
 where
  -- flatten nested unions so membership sees the leaves (REVIEW-3 #25)
  flatten (TUnion us) = concatMap flatten us
  flatten x = [x]
  checkUnionMembership t' ts'
    | TVar _ <- t' = pure ()
    | t' `elem` concatMap flatten ts' = pure ()
    | otherwise = throwTypeError $ "type mismatch: expected one of " <> T.intercalate " | " (map prettyType ts) <> ", got " <> prettyType t'

-- ── type merging (for branches / polymorphic result combination) ──

{- | merge two types into their least upper bound (join)
differs from unify in that it produces a result rather than asserting equality
-}
mergeTypes :: NixType -> NixType -> Infer NixType
mergeTypes type1 type2 = do
  t1' <- applyCurrentSubst type1
  t2' <- applyCurrentSubst type2
  merge t1' t2'
 where
  -- variable on either side: bind and return
  merge (TVar v) t = bindVar v t >> pure t
  merge t (TVar v) = bindVar v t >> pure t
  -- TAny absorbs anything
  merge TAny _ = pure TAny
  merge _ TAny = pure TAny
  -- attrs: merge field-by-field
  merge (TAttrs m1) (TAttrs m2) = mergeAttrs m1 m2
  merge (TList e1) (TList e2) = TList <$> mergeTypes e1 e2
  merge (TFun a1 b1) (TFun a2 b2) = do
    unify a1 a2
    res <- mergeTypes b1 b2
    pure $ TFun a1 res
  -- identical base types: return as-is
  merge a b | a == b = pure a
  -- otherwise: produce a union
  merge a b = pure $ TUnion [a, b]

-- | merge two attr types field-by-field, marking optional any field present in only one
mergeAttrs :: Map Text (NixType, Bool) -> Map Text (NixType, Bool) -> Infer NixType
mergeAttrs m1 m2 = do
  fields <- forM (Set.toList keys) field
  pure $ TAttrs (Map.fromList fields)
 where
  keys = Set.union (Map.keysSet m1) (Map.keysSet m2)
  field k = combine (Map.lookup k m1) (Map.lookup k m2)
   where
    combine (Just (t1, o1)) (Just (t2, o2)) = do
      t <- mergeTypes t1 t2
      pure (k, (t, o1 || o2))
    combine (Just (t1, _)) Nothing = pure (k, (t1, True))
    combine Nothing (Just (t2, _)) = pure (k, (t2, True))
    combine Nothing Nothing = throwTypeError $ "internal error: key " <> k <> " missing from both attr sets"

{- | constrain a field in a scope type to a specific type
used by `with` scope resolution
-}
fieldConstraint :: Text -> NixType -> NixType -> Infer ()
fieldConstraint name scopeT valueT
  | TAttrs m <- scopeT = lookupAndUnify name valueT m
  | TAttrsOpen m <- scopeT = lookupAndUnify name valueT m
  | TVar _ <- scopeT = do
      r <- freshTypeVar
      let fieldType = TRec (Map.singleton name (valueT, False)) (ROpen r)
      unify scopeT fieldType
  | otherwise = pure ()
 where
  lookupAndUnify k v m = maybe (pure ()) (\(ft, _) -> unify v ft) (Map.lookup k m)

-- ═════════════════════════════════════════════════════════════════════════════
-- instantiation
-- ═════════════════════════════════════════════════════════════════════════════

{- | instantiate a polymorphic scheme by replacing each quantified var with a fresh type var
this is HM-style let-polymorphism: each use-site gets its own copy
-}
instantiate :: Scheme -> Infer NixType
instantiate (Forall vars t) = do
  freshVars <- mapM (const freshVar) vars
  let subst = Map.fromList (zip vars freshVars)
  pure $ applySubst subst t

-- ═════════════════════════════════════════════════════════════════════════════
-- inference: expression-level helpers
-- ═════════════════════════════════════════════════════════════════════════════

-- | atom → type mapping (NAtom → NixType)
inferAtom :: NAtom -> Infer NixType
inferAtom = pure . atomType

-- | string: literal strings get TStrLit, interpolated strings get TString
inferStr :: NString NExprLoc -> Infer NixType
inferStr (DoubleQuoted [Plain t]) = pure $ TStrLit t
inferStr _ = pure TString

{- | list: infer element type from first element, merge remaining against it
empty list gets a fresh (unconstrained) element type variable
-}
inferList :: TypeEnv -> [NExprLoc] -> Infer NixType
inferList _environment [] = do
  elemType <- freshVar
  pure $ TList elemType
inferList environment (x : xs) = do
  elemType <- infer environment x
  finalElemType <- foldM (\acc e -> infer environment e >>= mergeTypes acc) elemType xs
  pure $ TList finalElemType

-- | attrset: infer all bindings, wrap as closed TAttrs
inferAttrSet :: Recursivity -> TypeEnv -> [Nix.Binding NExprLoc] -> Infer NixType
inferAttrSet recursive environment bindings = do
  fields <- inferBindings (recursive == Recursive) environment bindings
  let fieldMap = Map.fromList $ map (\(k, t) -> (k, (t, False))) fields
  pure $ TAttrs fieldMap

-- | if-then-else: condition must be bool, branches merged
inferIf :: TypeEnv -> NExprLoc -> NExprLoc -> NExprLoc -> Infer NixType
inferIf environment cond thenE elseE = do
  condT <- infer environment cond
  unify condT TBool
  thenT <- infer environment thenE
  elseT <- infer environment elseE
  mergeTypes thenT elseT

{- | with: scope expr provides attr type, body sees fields via dynamic lookup
n.b. the memo cache prevents repeated unification for the same field
-}
inferWith :: TypeEnv -> NExprLoc -> NExprLoc -> Infer NixType
inferWith environment scope body = do
  scopeT <- infer environment scope
  let environment' = environment{envWith = Just scopeT}
  oldMemo <- gets inferWithMemo
  modify $ \s -> s{inferWithMemo = Map.empty}
  resultT <- infer environment' body
  modify $ \s -> s{inferWithMemo = oldMemo}
  pure resultT

-- | assert: condition must be bool, then infer body
inferAssert :: TypeEnv -> NExprLoc -> NExprLoc -> Infer NixType
inferAssert environment cond body = do
  condT <- infer environment cond
  unify condT TBool
  infer environment body

{- | function application: unify func type as TFun arg result, return result
n.b. intercepts import ./path to use cross-module type info
-}
inferAppWithImport :: TypeEnv -> NExprLoc -> NExprLoc -> Infer NixType
inferAppWithImport environment func arg =
  maybe (inferApp environment func arg) viaImport (extractImportPathLiteral arg)
 where
  viaImport importPath =
    maybe (inferApp environment func arg) useImported (lookupImport importPath environment)
  useImported importedType = do
    _ <- infer environment func
    _ <- infer environment arg
    applyCurrentSubst importedType

-- | extract a literal file path from an expression (for import resolution)
extractImportPathLiteral :: NExprLoc -> Maybe FilePath
extractImportPathLiteral (Layer (NLiteralPath (Nix.Path p))) = Just p
extractImportPathLiteral (Layer (NStr (DoubleQuoted [Plain t]))) = Just (T.unpack t)
extractImportPathLiteral (Layer (NStr (Indented _ [Plain t]))) = Just (T.unpack t)
extractImportPathLiteral _ = Nothing

-- | function application: unify func type as TFun arg result, return result
inferApp :: TypeEnv -> NExprLoc -> NExprLoc -> Infer NixType
inferApp environment func arg = do
  funcT <- infer environment func
  argT <- infer environment arg
  resultT <- freshVar
  unify funcT (TFun argT resultT)
  applyCurrentSubst resultT

{- | attribute select @e.name@: look up name in e's attr type.
n.b. fixes S2 from review-2: a missing key on a *closed* attrset is a type
error. Open attrsets may legitimately have more fields, so a miss there is
just a fresh polymorphic var.
The 'hasDefault' parameter (from @attrs.x or default@) suppresses the error,
because the source has explicitly declared "ok if missing".
-}
inferSelect :: TypeEnv -> NExprLoc -> NonEmpty (NKeyName NExprLoc) -> Bool -> Infer NixType
inferSelect environment base path hasDefault = do
  baseT <- infer environment base
  -- Fold the WHOLE dotted path, not just the first key. The dispatch used to
  -- match `(attr :| _)`, silently dropping `b.c` from `x.a.b.c` (so the genuine
  -- "cannot select b from an Int" error was never produced). `expr or default`
  -- suppresses the missing-key error at every level, matching Nix semantics.
  foldM selectStep baseT path
 where
  selectStep baseTy attr = do
    t' <- applyCurrentSubst baseTy
    resolve t' (keyOf attr)
  keyOf (StaticKey k) = Just (varNameText k)
  keyOf (DynamicKey _) = Nothing

  -- closed record: key must be present (unless `or default`)
  resolve (TRec fields RClosed) (Just k) = maybe closedMiss (pure . fst) (Map.lookup k fields)
   where
    closedMiss
      | hasDefault = freshVar
      | otherwise =
          throwTypeError $
            "attribute '"
              <> k
              <> "' missing on closed attribute set (keys: "
              <> T.intercalate ", " (Map.keys fields)
              <> ")"
  -- open record: a missing key EXTENDS the row through its tail var, so
  -- repeated selections accumulate (`x.a` then `x.b` ⟹ `{a,b|ρ}`).
  resolve (TRec fields (ROpen r)) (Just k) = maybe openMiss (pure . fst) (Map.lookup k fields)
   where
    openMiss
      | hasDefault || isAnonRowVar r = freshVar
      | otherwise = do
          fieldTy <- freshVar
          r' <- freshTypeVar
          bindRowVar r (TRec (Map.singleton k (fieldTy, False)) (ROpen r'))
          pure fieldTy
  -- selection on a VARIABLE emits a row constraint α ~ { k : β | ρ }
  -- (RC1 #2 — was a silent freshVar, so `(x: x.foo) 5` wrongly passed).
  resolve t'@(TVar _) (Just k)
    | hasDefault = freshVar
    | otherwise = do
        fieldTy <- freshVar
        r <- freshTypeVar
        unify t' (TRec (Map.singleton k (fieldTy, False)) (ROpen r))
        pure fieldTy
  resolve TAny (Just _) = freshVar
  -- selecting a static key from a concrete non-attrset is a type error
  -- (e.g. `x.a.b` where `x.a : Int`)
  resolve t' (Just k)
    | hasDefault = freshVar
    | otherwise =
        throwTypeError $
          "cannot select attribute '" <> k <> "' from non-attrset type " <> prettyType t'
  -- dynamic key (`x.${e}`): not statically resolvable
  resolve _ _ = freshVar

{- | @e ? attr@: returns Bool. We additionally check that any dynamic-key
antiquotations type-check correctly (S4 from review-2 — previously the path
was ignored entirely).
-}
inferHasAttr :: TypeEnv -> NExprLoc -> NAttrPath NExprLoc -> Infer NixType
inferHasAttr environment base attrPath = do
  _ <- infer environment base
  mapM_ checkKey attrPath
  pure TBool
 where
  checkKey (StaticKey _) = pure ()
  checkKey (DynamicKey (Plain _)) = pure ()
  checkKey (DynamicKey EscapedNewline) = pure ()
  checkKey (DynamicKey (Antiquoted e)) = do
    t <- infer environment e
    -- The antiquoted expression must be a string (Nix coerces here)
    unify t TString

-- | unary ops: negation requires int, not requires bool
inferUnary :: TypeEnv -> NUnaryOp -> NExprLoc -> Infer NixType
inferUnary environment op e = do
  t <- infer environment e
  apply op t
 where
  apply NNeg t = unify t TInt >> pure TInt
  apply NNot t = unify t TBool >> pure TBool

{- | symbol resolution: lookup in env, or fall through to `with` scope, or error.
n.b. fixes S3 from review-2: previously fell through to 'freshVar' for any unbound
name. Now we error unless the name is in env or under an enclosing 'with' scope.
'envWithBypass' lets call paths opt into the old behavior — used at the top
level where some legitimate imports/builtins arrive un-modeled.
-}
inferSymbol :: TypeEnv -> Text -> Infer NixType
inferSymbol environment symbolName
  | Just scheme <- lookupEnv symbolName environment = instantiate scheme
  | Just scopeType <- envWith environment = resolveWithScope symbolName scopeType
  | envLenient environment = freshVar
  | otherwise = throwTypeError $ "unbound variable: " <> symbolName
 where
  -- resolve via `with <scope>`: constrain field in scope type, memoize result
  resolveWithScope name scopeType = do
    memo <- gets inferWithMemo
    maybe (compute memo) pure (Map.lookup name memo)
   where
    compute memo = do
      typeVar <- freshVar
      resolvedScope <- applyCurrentSubst scopeType
      fieldConstraint name resolvedScope typeVar
      resolvedType <- applyCurrentSubst typeVar
      modify $ \inferState -> inferState{inferWithMemo = Map.insert name resolvedType memo}
      pure resolvedType

-- | binary ops: each operator has specific type constraints
inferBinary :: TypeEnv -> NBinaryOp -> NExprLoc -> NExprLoc -> Infer NixType
inferBinary environment op left right = do
  leftT <- infer environment left
  rightT <- infer environment right
  apply op leftT rightT
 where
  -- comparison: `==`/`!=` are TOTAL in Nix and never type-error, so we must
  -- NOT unify the operands — `x == null` with `x : Int` is legal and idiomatic.
  -- Operands are still inferred above (for their own checking); we just don't
  -- relate them. (Previously `unify leftT rightT` false-positived on `x == null`.)
  apply NEq _ _ = pure TBool
  apply NNEq _ _ = pure TBool
  -- numeric comparison
  apply NLt l r = unify l TInt >> unify r TInt >> pure TBool
  apply NLte l r = unify l TInt >> unify r TInt >> pure TBool
  apply NGt l r = unify l TInt >> unify r TInt >> pure TBool
  apply NGte l r = unify l TInt >> unify r TInt >> pure TBool
  -- boolean logic
  apply NAnd l r = unify l TBool >> unify r TBool >> pure TBool
  apply NOr l r = unify l TBool >> unify r TBool >> pure TBool
  apply NImpl l r = unify l TBool >> unify r TBool >> pure TBool
  -- nix `+` is heterogeneous: Int/Float numeric add (Int+Float = Float),
  -- String concat, and Path concat (Path+String = Path, String+Path = String).
  -- When one side is still a variable we unify to PROPAGATE (`x + 1 ⟹ x:Int`);
  -- when both are concrete we use the +-lattice instead of demanding equality.
  -- The old `unify leftT rightT` wrongly rejected `1 + 1.5` and `./a + "b"`.
  apply NPlus leftT rightT = do
    l <- applyCurrentSubst leftT
    r <- applyCurrentSubst rightT
    plus l r
   where
    plus TAny _ = pure TAny
    plus _ TAny = pure TAny
    plus (TVar _) _ = unifyPlus
    plus _ (TVar _) = unifyPlus
    plus l r =
      maybe
        (throwTypeError $ "operator `+` cannot combine " <> prettyType l <> " and " <> prettyType r)
        pure
        (plusConcrete l r)
    -- at least one operand is a variable: unify to propagate the known side
    unifyPlus = do
      unify leftT rightT
      resolved <- applyCurrentSubst leftT
      plusResult resolved
    plusResult TInt = pure TInt
    plusResult TFloat = pure TFloat
    plusResult TString = pure TString
    plusResult (TStrLit _) = pure TString
    plusResult TPath = pure TPath
    plusResult resolved@(TVar _) = pure resolved
    plusResult TAny = pure TAny
    plusResult resolved = throwTypeError $ "operator `+` expects Int, Float, String, or Path; got " <> prettyType resolved
    -- both operands concrete: the legal +-combinations (TStrLit ≈ TString)
    plusConcrete a b = combine (norm a) (norm b)
    combine TInt TInt = Just TInt
    combine TInt TFloat = Just TFloat
    combine TFloat TInt = Just TFloat
    combine TFloat TFloat = Just TFloat
    combine TString TString = Just TString
    combine TString TPath = Just TString
    combine TPath TString = Just TPath
    combine TPath TPath = Just TPath
    combine _ _ = Nothing
    norm (TStrLit _) = TString
    norm t = t
  -- arithmetic (int-only in our model)
  apply NMinus l r = unify l TInt >> unify r TInt >> pure TInt
  apply NMult l r = unify l TInt >> unify r TInt >> pure TInt
  apply NDiv l r = unify l TInt >> unify r TInt >> pure TInt
  -- list concatenation
  apply NConcat leftT rightT = do
    elemVar <- freshVar
    let listT = TList elemVar
    unify leftT listT
    unify rightT listT
    applyCurrentSubst listT
  -- attrset update // operator. Co1 from review-2: the TVar fallback
  -- previously unified leftT against rightT, collapsing a polymorphic
  -- parameter to the right operand's exact shape. We now route TVar
  -- through TAttrsOpen instead so `\x. x // {a=1;}` stays polymorphic.
  apply NUpdate leftT rightT = do
    leftT' <- applyCurrentSubst leftT
    rightT' <- applyCurrentSubst rightT
    update leftT' rightT'
   where
    update (TAttrs l) (TAttrs r) = pure $ TAttrs (r `Map.union` l)
    update (TAttrsOpen l) (TAttrsOpen r) = mkOpenRec (r `Map.union` l)
    update (TAttrs l) (TAttrsOpen r) = mkOpenRec (r `Map.union` l)
    update (TAttrsOpen l) (TAttrs r) = mkOpenRec (r `Map.union` l)
    update (TVar _) (TAttrs r) = do
      -- Constrain x to be an attrset (open) and produce an open row
      -- containing at least the right side's keys.
      mkOpenRec Map.empty >>= unify leftT
      mkOpenRec r
    update (TVar _) (TAttrsOpen r) = do
      mkOpenRec Map.empty >>= unify leftT
      mkOpenRec r
    update (TAttrs l) (TVar _) = do
      mkOpenRec Map.empty >>= unify rightT
      mkOpenRec l
    update (TAttrsOpen l) (TVar _) = do
      mkOpenRec Map.empty >>= unify rightT
      mkOpenRec l
    update (TVar _) (TVar _) = do
      mkOpenRec Map.empty >>= unify leftT
      mkOpenRec Map.empty >>= unify rightT
      mkOpenRec Map.empty
    update _ _ = do
      unify leftT rightT
      applyCurrentSubst leftT

-- | lambda: fresh var for each param, infer body, produce TFun
inferLambda :: TypeEnv -> Params NExprLoc -> NExprLoc -> Infer NixType
-- simple param: just one binder
inferLambda environment (Param name) body = do
  paramT <- moduleParamVar environment (varNameText name)
  let environment' = extendEnv (varNameText name) (Forall [] paramT) environment
  resultT <- infer environment' body
  paramT' <- applyCurrentSubst paramT
  pure $ TFun paramT' resultT
-- set pattern: { name ? default, ... } @ name ->
inferLambda environment (ParamSet mName variadic paramList) body = do
  paramTypes <- forM paramList $ \(name, mDefault) -> do
    t <- maybe (moduleParamVar environment (varNameText name)) (infer environment) mDefault
    pure (varNameText name, (t, isJust mDefault))

  attrsT <-
    if variadic == Variadic
      then mkOpenRec (Map.fromList paramTypes)
      else pure (TAttrs (Map.fromList paramTypes))

  -- all param names are in scope in the body
  let environment' = foldr (\(n, (t, _)) e -> extendEnv n (Forall [] t) e) environment paramTypes

  -- @-binding: the whole attrset is in scope. In module mode it's the
  -- externally-supplied input set (e.g. flake @inputs) — type it dynamic so
  -- self-references like `mkFlake { inherit inputs; }` don't form a cyclic
  -- (occurs-check-failing) row.
  let boundType
        | envModuleParams environment = TAny
        | otherwise = attrsT
  let environment'' = maybe environment' (\name -> extendEnv (varNameText name) (Forall [] boundType) environment') mName

  resultT <- infer environment'' body
  pure $ TFun attrsT resultT

{- | Type for a lambda parameter. Normally a fresh inference var, but in module
mode ('envModuleParams') a parameter whose name is a well-known external module /
flake input is typed dynamically — those values come from the flake / module
system, so inferring them precisely only yields false positives. Matched by name
so ordinary inner lambdas keep precise inference.
-}
moduleParamVar :: TypeEnv -> Text -> Infer NixType
moduleParamVar environment name
  | envModuleParams environment && isExternalParam name = pure TAny
  | otherwise = freshVar

-- | Well-known parameter names supplied by the flake / module system.
isExternalParam :: Text -> Bool
isExternalParam name =
  name
    `elem` [ "self"
           , "inputs"
           , "self'"
           , "inputs'"
           , "config"
           , "options"
           , "lib"
           , "pkgs"
           , "pkgs'"
           , "final"
           , "prev"
           , "super"
           , "specialArgs"
           , "modulesPath"
           , "system"
           , "withSystem"
           , "moduleWithSystem"
           , "getSystem"
           , "flake-parts-lib"
           ]

-- ═════════════════════════════════════════════════════════════════════════════
-- inference: main dispatch
-- ═════════════════════════════════════════════════════════════════════════════

-- | top-level inference: destructure AST node and dispatch to handler
infer :: TypeEnv -> NExprLoc -> Infer NixType
infer environment (LayerAnn sp expr) = withSpan (srcSpanToSpan sp) (go expr)
 where
  go (NConstant atom) = inferAtom atom
  go (NStr str) = inferStr str
  go (NLiteralPath _) = pure TPath
  go (NEnvPath _) = pure TPath
  go (NSym name) = inferSymbol environment (varNameText name)
  go (NList list) = inferList environment list
  go (NSet recursive bindings) = inferAttrSet recursive environment bindings
  go (NLet bindings body) = inferLet environment bindings body
  go (NIf cond thenE elseE) = inferIf environment cond thenE elseE
  go (NWith scope body) = inferWith environment scope body
  go (NAssert cond body) = inferAssert environment cond body
  go (NAbs params body) = inferLambda environment params body
  go (NApp func arg) = inferAppWithImport environment func arg
  -- `builtins.<name>`: a modeled namespace field gets a fresh polymorphic instance
  go (NSelect mDef base path) =
    maybe (inferSelect environment base path (isJust mDef)) instantiate (builtinsFieldScheme base path)
  go (NHasAttr base attr) = inferHasAttr environment base attr
  go (NUnary op e) = inferUnary environment op e
  go (NBinary op left right) = inferBinary environment op left right
  go (NSynHole _) = freshVar

-- ═════════════════════════════════════════════════════════════════════════════
-- inference: bindings
-- ═════════════════════════════════════════════════════════════════════════════

-- | extract declared names from a Nix binding (NamedVar or Inherit)
bindingNames :: Nix.Binding NExprLoc -> [Text]
bindingNames (Nix.NamedVar (StaticKey name :| []) _ _) = [varNameText name]
bindingNames (Nix.Inherit _ keys _) = map varNameText keys
bindingNames _ = []

{- | partition fresh type vars per binding by name count
each binding may introduce multiple names (e.g. inherit a b c)
-}
assignChunks :: [NixType] -> [Nix.Binding NExprLoc] -> [[NixType]]
assignChunks [] _ = []
assignChunks typeVars (heading : rest) =
  let nameCount = length (bindingNames heading)
      (chunk, remainder) = splitAt nameCount typeVars
   in chunk : assignChunks remainder rest
assignChunks _ [] = []

-- | infer a single binding in recursive context (all names pre-scoped)
inferRecBinding :: TypeEnv -> Nix.Binding NExprLoc -> [NixType] -> Infer [(Text, NixType)]
inferRecBinding extendedEnv (Nix.NamedVar (StaticKey name :| []) expr pos) (typeVar : _) = do
  let bindingName = varNameText name
  t <- infer extendedEnv expr
  unify typeVar t
  t' <- applyCurrentSubst t
  emitBinding bindingName t' (posToSpan pos)
  pure [(bindingName, t)]
inferRecBinding _ (Nix.NamedVar (StaticKey _ :| []) _ _) [] = pure []
inferRecBinding extendedEnv (Nix.Inherit maybeScope keys _) typeVarList = do
  sequence
    [ do
        t <- resolveInheritType extendedEnv maybeScope k
        unify typeVar t
        pure (keyName, t)
    | (k, typeVar) <- zip keys typeVarList
    , let keyName = varNameText k
    ]
 where
  -- Use the scope's own span (Co2 from review-2) so error messages from
  -- `inherit (foo) bar` point at the inherit clause, not at (0,0).
  resolveInheritType env (Just scope) k =
    let LayerAnn scopeSp _ = scope
     in infer env (Fix (Compose (AnnUnit scopeSp (NSelect Nothing scope (StaticKey k :| [])))))
  resolveInheritType env Nothing k = maybe freshVar instantiate (lookupEnv (varNameText k) env)
inferRecBinding _ _ _ = pure []

{- | a pre-allocated rec/let var that resolved back to *itself* picked up no
concrete constraint — the signal for the "infinite type" guard. (The original
'freshVar' is always a 'TVar', so equality alone suffices, but we keep the
explicit 'TVar' match to mirror the old per-site test exactly.)
-}
resolvedToSelf :: (NixType, NixType) -> Bool
resolvedToSelf (TVar vid, original) = TVar vid == original
resolvedToSelf _ = False

{- | infer all bindings in a recursive set: pre-allocate vars, then unify each.
n.b. desugars nested-path bindings (S5 from review-2) so @{ a.b = 1; }@ is
treated as @{ a = { b = 1; }; }@ before inference begins.
-}
inferRecursiveBindings :: TypeEnv -> [Nix.Binding NExprLoc] -> Infer [(Text, NixType)]
inferRecursiveBindings environment bindings'' = do
  let bindings' = desugarNestedBindings bindings''
  let names = concatMap bindingNames bindings'
  freshTypeVars <- replicateM (length names) freshVar
  let extendedEnv = foldr (\(n, t) e -> extendEnv n (Forall [] t) e) environment (zip names freshTypeVars)
  let varChunks = assignChunks freshTypeVars bindings'
  inferredBindings <- sequence [inferRecBinding extendedEnv binding typeVars | (binding, typeVars) <- zip bindings' varChunks]
  resolvedVars <- forM freshTypeVars applyCurrentSubst
  when
    (all resolvedToSelf (zip resolvedVars freshTypeVars))
    $ throwTypeError
    $ "infinite type: rec bindings " <> T.intercalate ", " names <> " have no concrete constraint"
  pure $ concat inferredBindings

{- | infer a single non-recursive binding and accumulate results
n.b. bindings in a non-recursive set are independent (each sees only
@environment@), so this is a plain per-binding map — the caller concats the
results. The old accumulator-with-@++@ form was O(n²) on wide attrsets.
-}
inferNonRecursiveBinding :: TypeEnv -> Nix.Binding NExprLoc -> Infer [(Text, NixType)]
inferNonRecursiveBinding environment (Nix.NamedVar (StaticKey name :| []) expr pos) = do
  let bindingName = varNameText name
  t <- infer environment expr
  t' <- applyCurrentSubst t
  emitBinding bindingName t' (posToSpan pos)
  pure [(bindingName, t)]
inferNonRecursiveBinding environment (Nix.Inherit maybeScope keys _) =
  forM keys $ \key -> do
    let keyName = varNameText key
    t <- maybe (fromEnv keyName) (fromScope key) maybeScope
    pure (keyName, t)
 where
  fromScope key scope =
    let LayerAnn scopeSp _ = scope
     in infer environment (Fix (Compose (AnnUnit scopeSp (NSelect Nothing scope (StaticKey key :| [])))))
  fromEnv keyName = maybe freshVar instantiate (lookupEnv keyName environment)
inferNonRecursiveBinding _ _ = pure []

-- | dispatch to recursive or non-recursive binding inference
inferBindings :: Bool -> TypeEnv -> [Nix.Binding NExprLoc] -> Infer [(Text, NixType)]
inferBindings recursive environment bindings
  | recursive = inferRecursiveBindings environment bindings
  | otherwise = concat <$> mapM (inferNonRecursiveBinding environment) (desugarNestedBindings bindings)

{- | Desugar nested-path bindings into top-level bindings whose value is a
synthesised attrset. Closes S5 from review-2: previously @{ a.b = 1; }@ was
silently dropped because the inference engine only matched singleton paths.
We also merge bindings that share a top-level key, so @{ a.b = 1; a.c = 2; }@
becomes @{ a = { b = 1; c = 2; }; }@.
-}
desugarNestedBindings :: [Nix.Binding NExprLoc] -> [Nix.Binding NExprLoc]
desugarNestedBindings = mergeByKey . map desugar1
 where
  desugar1 (Nix.NamedVar (StaticKey k :| (k2 : ks)) e pos) =
    let inner = Fix (Compose (AnnUnit nullSpan (NSet NonRecursive [Nix.NamedVar (k2 :| ks) e pos])))
     in Nix.NamedVar (StaticKey k :| []) inner pos
  desugar1 b = b

  -- Merge bindings sharing a top-level static key (e.g. desugared @a.b@/@a.c@)
  -- into one. Two O(n log n) passes: collect each key's later values, then
  -- emit each key's first occurrence merged with them (later occurrences are
  -- dropped, non-static bindings pass through in place). The old per-key
  -- partition scan was O(n²) on wide attrsets.
  mergeByKey bs =
    let (_, outRev) = foldl' emit (Set.empty, []) bs
     in reverse outRev
   where
    collectExtra acc (Nix.NamedVar (StaticKey k :| []) v _)
      | Map.member (varNameText k) acc = Map.insertWith (flip (++)) (varNameText k) [v] acc
      | otherwise = Map.insert (varNameText k) [] acc
    collectExtra acc _ = acc
    extras = foldl' collectExtra Map.empty bs
    emit (seen, out) (Nix.NamedVar kp@(StaticKey k :| []) val pos) =
      let kt = varNameText k
       in if kt `Set.member` seen
            then (seen, out)
            else
              let merged = foldr addAttrs val (Map.findWithDefault [] kt extras)
               in (Set.insert kt seen, Nix.NamedVar kp merged pos : out)
    emit (seen, out) b = (seen, b : out)

  addAttrs (Fix (Compose (AnnUnit s (NSet r bs1)))) (Fix (Compose (AnnUnit _ (NSet _ bs2)))) =
    Fix (Compose (AnnUnit s (NSet r (bs2 ++ bs1))))
  addAttrs additional original = original `mergeOrKeep` additional
  mergeOrKeep a _ = a

-- ═════════════════════════════════════════════════════════════════════════════
-- inference: let expressions
-- ═════════════════════════════════════════════════════════════════════════════

{- | convert a Nix binding to (name, expr, span) tuples (1 per declared name)
inherit from scope desugars to a select expression
-}
parseBinding :: Nix.Binding NExprLoc -> [(Text, NExprLoc, Span)]
parseBinding (Nix.NamedVar (StaticKey name :| []) expr pos) =
  [(varNameText name, expr, posToSpan pos)]
parseBinding (Nix.Inherit mScope keys pos) = map synth keys
 where
  synth key = (varNameText key, expr, posToSpan pos)
   where
    spForSynth = maybe nullSpan scopeSpan mScope
    scopeSpan scope = let LayerAnn s _ = scope in s
    expr =
      maybe
        (Fix (Compose (AnnUnit spForSynth (NSym key))))
        (\scope -> Fix (Compose (AnnUnit spForSynth (NSelect Nothing scope (StaticKey key :| [])))))
        mScope
parseBinding _ = []

-- | build a graph edge: the name → [dependency names] for SCC analysis
buildEdge :: [(Text, NExprLoc, Span)] -> (Text, NExprLoc, Span) -> ((Text, NExprLoc, Span), Text, [Text])
buildEdge allBindings (name, expr, sp) =
  let free = collectFreeVars expr
      deps = [n | (n, _, _) <- allBindings, n `elem` free]
   in ((name, expr, sp), name, deps)

{- | infer one SCC (strongly connected component) group of let bindings
acyclic groups have 1 binding; cyclic groups share scope immediately
-}

-- | the members of an SCC as a plain list (acyclic = singleton, cyclic = group)
sccBindings :: SCC a -> [a]
sccBindings (AcyclicSCC x) = [x]
sccBindings (CyclicSCC list) = list

inferLetGroup :: TypeEnv -> TypeEnv -> SCC (Text, NExprLoc, Span) -> Infer TypeEnv
inferLetGroup _baseEnv currentEnv scc = do
  let groupBindings = sccBindings scc

  let names = map (\(n, _, _) -> n) groupBindings
  freshVars <- replicateM (length names) freshVar

  let envRecursive = foldr (\(n, t) e -> extendEnv n (Forall [] t) e) currentEnv (zip names freshVars)

  forM_ (zip groupBindings freshVars) $ \((name, expr, sp), typeVar) -> do
    t <- infer envRecursive expr
    unify typeVar t
    t' <- applyCurrentSubst t
    emitBinding name t' sp

  resolvedVars <- forM freshVars applyCurrentSubst
  when
    (all resolvedToSelf (zip resolvedVars freshVars))
    $ throwTypeError
    $ "infinite type: rec bindings " <> T.intercalate ", " names <> " have no concrete constraint"

  -- generalize each binding for let-polymorphism
  schemes <- mapM (generalize currentEnv) freshVars

  pure $ foldr (\(n, s) e -> extendEnv n s e) currentEnv (zip names schemes)

{- | infer let ... in ... using SCC-based dependency analysis
bindings are grouped by mutual recursion, then each group is inferred in order
-}
inferLet :: TypeEnv -> [Nix.Binding NExprLoc] -> NExprLoc -> Infer NixType
inferLet environment bindings body = do
  let namedBindings = concatMap parseBinding bindings
  let edges = map (buildEdge namedBindings) namedBindings
  let sccs = stronglyConnComp edges
  environmentBody <- foldM (inferLetGroup environment) environment sccs
  infer environmentBody body

-- | collect free variable names from an expression (for dependency analysis)
collectFreeVars :: NExprLoc -> [Text]
collectFreeVars (Layer (NSym name)) = [varNameText name]
collectFreeVars (Layer (NList elems)) = concatMap collectFreeVars elems
collectFreeVars (Layer (NSet _ bindings)) = concatMap collectFreeVarsBinding bindings
collectFreeVars (Layer (NLet bindings body)) = concatMap collectFreeVarsBinding bindings ++ collectFreeVars body
collectFreeVars (Layer (NIf c t f)) = collectFreeVars c ++ collectFreeVars t ++ collectFreeVars f
collectFreeVars (Layer (NWith s b)) = collectFreeVars s ++ collectFreeVars b
collectFreeVars (Layer (NAssert c b)) = collectFreeVars c ++ collectFreeVars b
collectFreeVars (Layer (NAbs params b)) =
  let bound = paramNames params
      paramFreeVars = paramDefaults params
   in paramFreeVars ++ filter (`notElem` bound) (collectFreeVars b)
collectFreeVars (Layer (NApp f a)) = collectFreeVars f ++ collectFreeVars a
collectFreeVars (Layer (NSelect _ b _)) = collectFreeVars b
collectFreeVars (Layer (NHasAttr b _)) = collectFreeVars b
collectFreeVars (Layer (NUnary _ e)) = collectFreeVars e
collectFreeVars (Layer (NBinary _ l r)) = collectFreeVars l ++ collectFreeVars r
collectFreeVars _ = []

-- | collect free vars from a binding (recurse into the value expression)
collectFreeVarsBinding :: Nix.Binding NExprLoc -> [Text]
collectFreeVarsBinding (Nix.NamedVar _ expr _) = collectFreeVars expr
collectFreeVarsBinding _ = []

{- | extract the names bound by a function parameter pattern
n.b. this is used by collectFreeVars to scope variables (not type inference)
-}
paramNames :: Params NExprLoc -> [Text]
paramNames (Param name) = [varNameText name]
paramNames (ParamSet mName _ formals) =
  let formalNames = map (varNameText . fst) formals
   in formalNames ++ maybe [] (pure . varNameText) mName

{- | collect free vars from default expressions in a parameter pattern
the actual value of defaults may reference outer variables
-}
paramDefaults :: Params NExprLoc -> [Text]
paramDefaults (Param _) = []
paramDefaults (ParamSet _ _ formals) =
  concat [collectFreeVars e | (_, Just e) <- formals]

{- | generalize (close over) free type vars not free in the environment
this implements HM let-polymorphism: only quantify vars the env doesn't mention
-}
generalize :: TypeEnv -> NixType -> Infer Scheme
generalize environment t = do
  t' <- applyCurrentSubst t
  envSchemes <- mapM applyCurrentSubstScheme (Map.elems (envBindings environment))
  let freeInEnv = Set.unions (map freeTypeVarsScheme envSchemes)
  let freeInT = freeTypeVars t'
  let vars = Set.toList (freeInT `Set.difference` freeInEnv)
  pure $ Forall vars t'

-- | apply current subst to all type variables in a scheme
applyCurrentSubstScheme :: Scheme -> Infer Scheme
applyCurrentSubstScheme s = do
  subst <- gets inferSubst
  pure $ applySubstScheme subst s

-- | map NAton to the corresponding NixType
atomType :: NAtom -> NixType
atomType (NInt _) = TInt
atomType (NFloat _) = TFloat
atomType (NBool _) = TBool
atomType NNull = TNull
atomType (NURI _) = TString

-- ═════════════════════════════════════════════════════════════════════════════
-- results
-- ═════════════════════════════════════════════════════════════════════════════

-- ═════════════════════════════════════════════════════════════════════════════
-- results
-- ═════════════════════════════════════════════════════════════════════════════

-- | a single typed binding (name, resolved type, source location)
data Binding = Binding
  { bindName :: !Text
  , bindType :: !NixType
  , bindSpan :: !Span
  }
  deriving (Eq, Show)

-- | top-level inference result: all bindings + per-file function signatures
data InferResult = InferResult
  { irBindings :: ![Binding]
  , irFunctions :: ![(Text, NixType)]
  }
  deriving (Eq, Show)

-- | infer a single expression in the builtin environment
inferExpr :: NExprLoc -> Either Text (NixType, [Binding])
inferExpr expr = inferExprWithEnv builtinEnv expr

{- | Infer a module / flake expression: like 'inferExpr' but well-known external
parameter names (self, inputs, config, pkgs, the @-bound input set, …) are typed
as dynamic rather than inferred precisely. Used for files detected as a flake or
a module, whose top-level parameters are supplied by the flake / module system
(see 'envModuleParams').
-}
inferModuleExpr :: NExprLoc -> Either Text (NixType, [Binding])
inferModuleExpr = inferExprWithEnv builtinEnv{envModuleParams = True}

-- | infer an expression with a specific type environment (for cross-module inference)
inferExprWithEnv :: TypeEnv -> NExprLoc -> Either Text (NixType, [Binding])
inferExprWithEnv env expr =
  runInfer $ do
    t <- infer env expr
    applyCurrentSubst t

-- | convert Nix source position to our Span type
posToSpan :: Nix.NSourcePos -> Span
posToSpan (Nix.NSourcePos path l c) =
  Span
    (Loc (unPos (coerce l)) (unPos (coerce c)))
    (Loc (unPos (coerce l)) (unPos (coerce c)))
    (Just (coerce path))

-- | parse and infer a file, returning bindings and overall type
inferFile :: FilePath -> IO (Either Text InferResult)
inferFile path = do
  result <- try (parseNixFileLoc (Nix.Path path))
  either onIOError onParsed result
 where
  onIOError (e :: IOException) = pure $ Left (T.pack $ show e)
  onParsed = either onDoc onExpr
  onDoc doc = pure $ Left (T.pack $ show doc)
  onExpr expr = either (pure . Left) onInferred (inferExpr expr)
  onInferred (t, bindings) = pure $ Right $ InferResult bindings [(T.pack path, t)]
