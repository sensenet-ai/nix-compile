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
import Control.Monad (foldM, forM, forM_, replicateM, when)
import Control.Monad.State.Strict (gets, modify)
import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.Functor.Compose (Compose (..))
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List.NonEmpty (NonEmpty (..))
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
import NixCompile.Core.Span (Loc (..), Span (..))
import NixCompile.Inference.Nix.Builtins
import NixCompile.Inference.Nix.Constraint
import NixCompile.Inference.Nix.Environment
import NixCompile.Inference.Nix.Scheme
import NixCompile.Inference.Nix.Type
import NixCompile.Inference.Nix.Unify
import NixCompile.Syntax.Annotation (srcSpanToSpan, varNameText, pattern Layer, pattern LayerAnn)

-- ═════════════════════════════════════════════════════════════════════════════
-- instantiation
-- ═════════════════════════════════════════════════════════════════════════════

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
