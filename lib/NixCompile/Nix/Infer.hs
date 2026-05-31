{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
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

module NixCompile.Nix.Infer (
    -- * Inference
    inferExpr,
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
import NixCompile.Nix.Types
import NixCompile.Nix.Utils (srcSpanToSpan, varNameText)
import NixCompile.Types (Loc (..), Span (..))

-- ═════════════════════════════════════════════════════════════════════════════
-- environment
-- ═════════════════════════════════════════════════════════════════════════════

data TypeEnv = TypeEnv
    { envBindings :: Map Text Scheme
    , envWith :: Maybe NixType
    , envImportTypes :: Map FilePath NixType
    }
    deriving (Eq, Show)

emptyEnv :: TypeEnv
emptyEnv = TypeEnv Map.empty Nothing Map.empty

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

builtinEnv :: TypeEnv
builtinEnv =
    TypeEnv
        { envBindings = builtinBindings
        , envWith = Nothing
        , envImportTypes = Map.empty
        }
  where
    -- ── core type scheme helpers ──────────────────────────────────
    mono type_ = Forall [] type_
    req type_ = (type_, False)

    -- ── builtins attrset ──────────────────────────────────────────
    -- 'builtins' itself is typed as attrset of all function entries
    builtinsAttr = Map.singleton "builtins" (mono $ TAttrs builtinsTypes)
    builtinBindings = Map.union builtinsAttr (Map.map (mono . fst) builtinsTypes)

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
                  ("attrNames", TFun (TAttrsOpen Map.empty) (TList TString))
                , ("attrValues", TFun (TAttrsOpen (Map.singleton "_" (TAny, False))) (TList TAny))
                , ("hasAttr", TFun TString (TFun (TAttrsOpen Map.empty) TBool))
                , ("getAttr", TFun TString (TFun (TAttrsOpen Map.empty) TAny))
                , ("removeAttrs", TFun (TAttrsOpen Map.empty) (TFun (TList TString) (TAttrsOpen Map.empty)))
                , ("listToAttrs", TFun (TList (TAttrs (Map.fromList [("name", (TString, False)), ("value", (TAny, False))]))) (TAttrsOpen Map.empty))
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
                , ("derivation", TFun (TAttrsOpen Map.empty) TDerivation)
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
     in case eitherResult of
            Left err -> Left err
            Right res -> Right (res, inferBinds inferState)

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
    case mSpan of
        Just (Span (Loc l c) _ _) -> throwError $ T.pack (show l) <> ":" <> T.pack (show c) <> ": " <> msg
        Nothing -> throwError msg

-- ── allocate a fresh type variable (monotonically increasing id) ──
freshVar :: Infer NixType
freshVar = do
    s <- get
    put s{inferSupply = inferSupply s + 1}
    pure $ TVar (TypeVar (inferSupply s))

-- ── apply the current substitution to a type (idempotent with current subst) ──
applyCurrentSubst :: NixType -> Infer NixType
applyCurrentSubst t = do
    s <- gets inferSubst
    pure $ applySubst s t

-- ── extend the current substitution (composes on top) ──
addSubst :: TypeVar -> NixType -> Infer ()
addSubst v t = modify $ \s ->
    s{inferSubst = composeSubst (singleSubst v t) (inferSubst s)}

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
unifyFunctor funT attrsT = case attrsT of
    TAttrs m -> lookupFunctor funT m
    TAttrsOpen m -> lookupFunctor funT m
    _ -> typeMismatch funT attrsT
  where
    lookupFunctor ft m = case Map.lookup "__functor" m of
        Just (TFun _ innerT, _) -> unify innerT ft
        Just (ftFunctor, _) -> throwTypeError $ "__functor must be a function, got " <> prettyType ftFunctor
        Nothing -> typeMismatch ft attrsT

-- | apply current subst, then unify the normalised forms
unify :: NixType -> NixType -> Infer ()
unify type1 type2 = do
    t1' <- applyCurrentSubst type1
    t2' <- applyCurrentSubst type2
    unify' t1' t2'

-- | structural unification — must be applied AFTER current substitution
unify' :: NixType -> NixType -> Infer ()
unify' type1 type2 = case (type1, type2) of
    -- variable cases: bind one to the other (with occurs check)
    (TVar v, t) -> bindVar v t
    (t, TVar v) -> bindVar v t
    -- TAny unifies with everything (dynamic / unknown)
    (TAny, _) -> pure ()
    (_, TAny) -> pure ()
    -- base types: identical only
    (TInt, TInt) -> pure ()
    (TFloat, TFloat) -> pure ()
    (TBool, TBool) -> pure ()
    (TString, TString) -> pure ()
    (TStrLit _, TStrLit _) -> pure ()
    (TString, TStrLit _) -> pure ()
    (TStrLit _, TString) -> pure ()
    (TPath, TPath) -> pure ()
    (TNull, TNull) -> pure ()
    (TDerivation, TDerivation) -> pure ()
    -- compound types: recurse structurally
    (TList a, TList b) -> unify a b
    (TFun a1 b1, TFun a2 b2) -> unify a1 a2 >> unify b1 b2
    (TAttrs m1, TAttrs m2) -> unifyAttrs m1 m2
    (TAttrsOpen m1, TAttrsOpen m2) -> unifyAttrsOpenOpen m1 m2
    (TAttrs m1, TAttrsOpen m2) -> unifyAttrsClosedOpen m1 m2
    (TAttrsOpen m1, TAttrs m2) -> unifyAttrsClosedOpen m2 m1
    -- union: check membership
    (TUnion ts, t) -> unifyUnion ts t
    (t, TUnion ts) -> unifyUnion ts t
    -- function vs attrset: try functor protocol
    (TFun argT retT, attrsT) -> unifyFunctor (TFun argT retT) attrsT
    (attrsT, TFun argT retT) -> unifyFunctor (TFun argT retT) attrsT
    _ -> typeMismatch type1 type2

-- | bind a type variable to a concrete type (with occurs check)
bindVar :: TypeVar -> NixType -> Infer ()
bindVar v t
    | t == TVar v = pure ()
    | occursCheck v t = throwTypeError $ "infinite type: " <> prettyType (TVar v) <> " occurs in " <> prettyType t
    | otherwise = addSubst v t

-- | occurs check: does v appear free inside t? (prevents infinite types)
occursCheck :: TypeVar -> NixType -> Bool
occursCheck v = \case
    TVar typeVariable' -> v == typeVariable'
    TList t -> occursCheck v t
    TFun a b -> occursCheck v a || occursCheck v b
    TAttrs m -> any (occursCheck v . fst) (Map.elems m)
    TAttrsOpen m -> any (occursCheck v . fst) (Map.elems m)
    TUnion ts -> any (occursCheck v) ts
    _ -> False

-- | unify two closed attr sets: all keys must match, required fields must exist
unifyAttrs :: Map Text (NixType, Bool) -> Map Text (NixType, Bool) -> Infer ()
unifyAttrs m1 m2 = do
    let keys1 = Map.keysSet m1
    let keys2 = Map.keysSet m2
    let allKeys = Set.union keys1 keys2

    forM_ (Set.toList allKeys) $ \k -> do
        let v1 = Map.lookup k m1
        let v2 = Map.lookup k m2
        case (v1, v2) of
            (Just (t1, _), Just (t2, _)) -> unify t1 t2
            (Just (_, False), Nothing) -> throwTypeError $ "missing required field: " <> k
            (Nothing, Just (_, False)) -> throwTypeError $ "unexpected field (required in other): " <> k
            _ -> pure ()

{- | unify two open attr sets: only common fields are checked
extra keys in either side are allowed (open-world assumption)
-}
unifyAttrsOpenOpen :: Map Text (NixType, Bool) -> Map Text (NixType, Bool) -> Infer ()
unifyAttrsOpenOpen m1 m2 = do
    let common = Map.intersectionWith (,) m1 m2
    mapM_ (\((t1, _), (t2, _)) -> unify t1 t2) (Map.elems common)

-- | unify closed set against open set: closed must have all open's keys
unifyAttrsClosedOpen :: Map Text (NixType, Bool) -> Map Text (NixType, Bool) -> Infer ()
unifyAttrsClosedOpen closed open = do
    let openKeys = Map.keysSet open
    let closedKeys = Map.keysSet closed
    let missingInClosed = Set.difference openKeys closedKeys

    if not (Set.null missingInClosed)
        then throwTypeError $ "closed set missing fields required by open set: " <> T.intercalate ", " (Set.toList missingInClosed)
        else do
            let common = Map.intersectionWith (,) closed open
            mapM_ (\((t1, _), (t2, _)) -> unify t1 t2) (Map.elems common)

{- | unify a union (sum) type against a concrete type
single-element unions delegate; multi-element checks membership
-}
unifyUnion :: [NixType] -> NixType -> Infer ()
unifyUnion ts t = case ts of
    [] -> pure ()
    [t'] -> unify t' t
    _ -> do
        t' <- applyCurrentSubst t
        ts' <- mapM applyCurrentSubst ts
        checkUnionMembership t' ts'
  where
    checkUnionMembership t' ts'
        | TVar _ <- t' = pure ()
        | t' `elem` ts' = pure ()
        | otherwise = throwTypeError $ "type mismatch: expected one of " <> T.intercalate " | " (map prettyType ts) <> ", got " <> prettyType t'

-- ── type merging (for branches / polymorphic result combination) ──

{- | merge two types into their least upper bound (join)
differs from unify in that it produces a result rather than asserting equality
-}
mergeTypes :: NixType -> NixType -> Infer NixType
mergeTypes type1 type2 = do
    t1' <- applyCurrentSubst type1
    t2' <- applyCurrentSubst type2
    case (t1', t2') of
        -- variable on either side: bind and return
        (TVar v, t) -> bindVar v t >> pure t
        (t, TVar v) -> bindVar v t >> pure t
        -- TAny absorbs anything
        (TAny, _) -> pure TAny
        (_, TAny) -> pure TAny
        -- attrs: merge field-by-field
        (TAttrs m1, TAttrs m2) -> mergeAttrs m1 m2
        (TList e1, TList e2) -> TList <$> mergeTypes e1 e2
        (TFun a1 b1, TFun a2 b2) -> do
            unify a1 a2
            res <- mergeTypes b1 b2
            pure $ TFun a1 res
        -- identical base types: return as-is
        (a, b) | a == b -> pure a
        -- otherwise: produce a union
        (a, b) -> pure $ TUnion [a, b]

-- | merge two attr types field-by-field, marking optional any field present in only one
mergeAttrs :: Map Text (NixType, Bool) -> Map Text (NixType, Bool) -> Infer NixType
mergeAttrs m1 m2 = do
    let keys = Set.union (Map.keysSet m1) (Map.keysSet m2)
    fields <- forM (Set.toList keys) $ \k -> do
        let v1 = Map.lookup k m1
        let v2 = Map.lookup k m2
        case (v1, v2) of
            (Just (t1, o1), Just (t2, o2)) -> do
                t <- mergeTypes t1 t2
                pure (k, (t, o1 || o2))
            (Just (t1, _), Nothing) -> pure (k, (t1, True))
            (Nothing, Just (t2, _)) -> pure (k, (t2, True))
            (Nothing, Nothing) -> throwTypeError $ "internal error: key " <> k <> " missing from both attr sets"
    pure $ TAttrs (Map.fromList fields)

{- | constrain a field in a scope type to a specific type
used by `with` scope resolution
-}
fieldConstraint :: Text -> NixType -> NixType -> Infer ()
fieldConstraint name scopeT valueT
    | TAttrs m <- scopeT = lookupAndUnify name valueT m
    | TAttrsOpen m <- scopeT = lookupAndUnify name valueT m
    | TVar _ <- scopeT = do
        let fieldType = TAttrsOpen (Map.singleton name (valueT, False))
        unify scopeT fieldType
    | otherwise = pure ()
  where
    lookupAndUnify k v m = case Map.lookup k m of
        Just (ft, _) -> unify v ft
        Nothing -> pure ()

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
    case extractImportPathLiteral arg of
        Just importPath -> case lookupImport importPath environment of
            Just importedType -> do
                _ <- infer environment func
                _ <- infer environment arg
                applyCurrentSubst importedType
            Nothing -> inferApp environment func arg
        Nothing -> inferApp environment func arg

-- | extract a literal file path from an expression (for import resolution)
extractImportPathLiteral :: NExprLoc -> Maybe FilePath
extractImportPathLiteral (Fix (Compose (AnnUnit _ e))) = case e of
    NLiteralPath (Nix.Path p) -> Just p
    NStr (DoubleQuoted [Plain t]) -> Just (T.unpack t)
    NStr (Indented _ [Plain t]) -> Just (T.unpack t)
    _ -> Nothing

-- | function application: unify func type as TFun arg result, return result
inferApp :: TypeEnv -> NExprLoc -> NExprLoc -> Infer NixType
inferApp environment func arg = do
    funcT <- infer environment func
    argT <- infer environment arg
    resultT <- freshVar
    unify funcT (TFun argT resultT)
    applyCurrentSubst resultT

{- | attribute select e.name: look up name in e's attr type
dynamic keys and unknown attrs get a fresh type variable
-}
inferSelect :: TypeEnv -> NExprLoc -> NKeyName NExprLoc -> Infer NixType
inferSelect environment base attr = do
    baseT <- infer environment base
    t' <- applyCurrentSubst baseT
    let key = case attr of
            StaticKey k -> Just (varNameText k)
            DynamicKey _ -> Nothing
    case (t', key) of
        (TAttrs fields, Just k) -> lookupField k fields
        (TAttrsOpen fields, Just k) -> lookupField k fields
        _ -> freshVar
  where
    lookupField k fields = case Map.lookup k fields of
        Just (t, _) -> pure t
        Nothing -> freshVar

-- | hasAttr: always returns Bool (we don't track presence at the type level)
inferHasAttr :: TypeEnv -> NExprLoc -> NAttrPath NExprLoc -> Infer NixType
inferHasAttr environment base _attr = do
    _ <- infer environment base
    pure TBool

-- | unary ops: negation requires int, not requires bool
inferUnary :: TypeEnv -> NUnaryOp -> NExprLoc -> Infer NixType
inferUnary environment op e = do
    t <- infer environment e
    case op of
        NNeg -> unify t TInt >> pure TInt
        NNot -> unify t TBool >> pure TBool

-- | symbol resolution: lookup in env, or fall through to `with` scope, or fresh var
inferSymbol :: TypeEnv -> Text -> Infer NixType
inferSymbol environment symbolName
    | Just scheme <- lookupEnv symbolName environment = instantiate scheme
    | Just scopeType <- envWith environment = resolveWithScope symbolName scopeType
    | otherwise = freshVar
  where
    -- resolve via `with <scope>`: constrain field in scope type, memoize result
    resolveWithScope name scopeType = do
        memo <- gets inferWithMemo
        case Map.lookup name memo of
            Just resolved -> pure resolved
            Nothing -> do
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
    case op of
        -- comparison: both sides same type, result is Bool
        NEq -> unify leftT rightT >> pure TBool
        NNEq -> unify leftT rightT >> pure TBool
        -- numeric comparison
        NLt -> unify leftT TInt >> unify rightT TInt >> pure TBool
        NLte -> unify leftT TInt >> unify rightT TInt >> pure TBool
        NGt -> unify leftT TInt >> unify rightT TInt >> pure TBool
        NGte -> unify leftT TInt >> unify rightT TInt >> pure TBool
        -- boolean logic
        NAnd -> unify leftT TBool >> unify rightT TBool >> pure TBool
        NOr -> unify leftT TBool >> unify rightT TBool >> pure TBool
        NImpl -> unify leftT TBool >> unify rightT TBool >> pure TBool
        -- n.b. nix + works on strings, ints, paths — we approximate
        NPlus -> do
            unify leftT rightT
            applyCurrentSubst leftT
        -- arithmetic (int-only in our model)
        NMinus -> unify leftT TInt >> unify rightT TInt >> pure TInt
        NMult -> unify leftT TInt >> unify rightT TInt >> pure TInt
        NDiv -> unify leftT TInt >> unify rightT TInt >> pure TInt
        -- list concatenation
        NConcat -> do
            elemVar <- freshVar
            let listT = TList elemVar
            unify leftT listT
            unify rightT listT
            applyCurrentSubst listT
        -- attrset update // operator
        NUpdate -> do
            leftT' <- applyCurrentSubst leftT
            rightT' <- applyCurrentSubst rightT
            case (leftT', rightT') of
                (TAttrs l, TAttrs r) -> pure $ TAttrs (r `Map.union` l)
                (TAttrsOpen l, TAttrsOpen r) -> pure $ TAttrsOpen (r `Map.union` l)
                (TAttrs l, TAttrsOpen r) -> pure $ TAttrsOpen (r `Map.union` l)
                (TAttrsOpen l, TAttrs r) -> pure $ TAttrsOpen (r `Map.union` l)
                _ -> do
                    unify leftT rightT
                    applyCurrentSubst leftT

-- | lambda: fresh var for each param, infer body, produce TFun
inferLambda :: TypeEnv -> Params NExprLoc -> NExprLoc -> Infer NixType
inferLambda environment params body = case params of
    -- simple param: just one binder
    Param name -> do
        paramT <- freshVar
        let environment' = extendEnv (varNameText name) (Forall [] paramT) environment
        resultT <- infer environment' body
        paramT' <- applyCurrentSubst paramT
        pure $ TFun paramT' resultT
    -- set pattern: { name ? default, ... } @ name ->
    ParamSet mName variadic paramList -> do
        paramTypes <- forM paramList $ \(name, mDefault) -> do
            t <- case mDefault of
                Just defaultExpr -> infer environment defaultExpr
                Nothing -> freshVar
            pure (varNameText name, (t, isJust mDefault))

        let attrsT =
                if variadic == Variadic
                    then TAttrsOpen (Map.fromList paramTypes)
                    else TAttrs (Map.fromList paramTypes)

        -- all param names are in scope in the body
        let environment' = foldr (\(n, (t, _)) e -> extendEnv n (Forall [] t) e) environment paramTypes

        -- @-binding: the whole attrset is also in scope
        let environment'' = case mName of
                Just name -> extendEnv (varNameText name) (Forall [] attrsT) environment'
                Nothing -> environment'

        resultT <- infer environment'' body
        pure $ TFun attrsT resultT

-- ═════════════════════════════════════════════════════════════════════════════
-- inference: main dispatch
-- ═════════════════════════════════════════════════════════════════════════════

-- | top-level inference: destructure AST node and dispatch to handler
infer :: TypeEnv -> NExprLoc -> Infer NixType
infer environment (Fix (Compose (AnnUnit sp expr))) = withSpan (srcSpanToSpan sp) $ case expr of
    NConstant atom -> inferAtom atom
    NStr str -> inferStr str
    NLiteralPath _ -> pure TPath
    NEnvPath _ -> pure TPath
    NSym name -> inferSymbol environment (varNameText name)
    NList list -> inferList environment list
    NSet recursive bindings -> inferAttrSet recursive environment bindings
    NLet bindings body -> inferLet environment bindings body
    NIf cond thenE elseE -> inferIf environment cond thenE elseE
    NWith scope body -> inferWith environment scope body
    NAssert cond body -> inferAssert environment cond body
    NAbs params body -> inferLambda environment params body
    NApp func arg -> inferAppWithImport environment func arg
    NSelect _ base (attr :| _) -> inferSelect environment base attr
    NHasAttr base attr -> inferHasAttr environment base attr
    NUnary op e -> inferUnary environment op e
    NBinary op left right -> inferBinary environment op left right
    NSynHole _ -> freshVar

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
    resolveInheritType env (Just scope) k =
        infer env (Fix (Compose (AnnUnit nullSpan (NSelect Nothing scope (StaticKey k :| [])))))
    resolveInheritType env Nothing k = case lookupEnv (varNameText k) env of
        Just scheme -> instantiate scheme
        Nothing -> freshVar
inferRecBinding _ _ _ = pure []

-- | infer all bindings in a recursive set: pre-allocate vars, then unify each
inferRecursiveBindings :: TypeEnv -> [Nix.Binding NExprLoc] -> Infer [(Text, NixType)]
inferRecursiveBindings environment bindings' = do
    let names = concatMap bindingNames bindings'
    freshTypeVars <- replicateM (length names) freshVar
    let extendedEnv = foldr (\(n, t) e -> extendEnv n (Forall [] t) e) environment (zip names freshTypeVars)
    let varChunks = assignChunks freshTypeVars bindings'
    inferredBindings <- sequence [inferRecBinding extendedEnv binding typeVars | (binding, typeVars) <- zip bindings' varChunks]
    resolvedVars <- forM freshTypeVars applyCurrentSubst
    when
        ( all
            ( \(resolved, original) -> case resolved of
                TVar vid -> TVar vid == original
                _ -> False
            )
            (zip resolvedVars freshTypeVars)
        )
        $ throwTypeError
        $ "infinite type: rec bindings " <> T.intercalate ", " names <> " have no concrete constraint"
    pure $ concat inferredBindings

-- | infer a single non-recursive binding and accumulate results
inferNonRecursiveBinding :: TypeEnv -> [(Text, NixType)] -> Nix.Binding NExprLoc -> Infer [(Text, NixType)]
inferNonRecursiveBinding environment accumulatedBindings (Nix.NamedVar (StaticKey name :| []) expr pos) = do
    let bindingName = varNameText name
    t <- infer environment expr
    t' <- applyCurrentSubst t
    emitBinding bindingName t' (posToSpan pos)
    pure $ accumulatedBindings ++ [(bindingName, t)]
inferNonRecursiveBinding environment accumulatedBindings (Nix.Inherit maybeScope keys _) = do
    additionalBindings <- forM keys $ \key -> do
        let keyName = varNameText key
        t <- case maybeScope of
            Just scope -> infer environment (Fix (Compose (AnnUnit nullSpan (NSelect Nothing scope (StaticKey key :| [])))))
            Nothing -> case lookupEnv keyName environment of
                Just scheme -> instantiate scheme
                Nothing -> freshVar
        pure (keyName, t)
    pure $ accumulatedBindings ++ additionalBindings
inferNonRecursiveBinding _ accumulatedBindings _ = pure accumulatedBindings

-- | dispatch to recursive or non-recursive binding inference
inferBindings :: Bool -> TypeEnv -> [Nix.Binding NExprLoc] -> Infer [(Text, NixType)]
inferBindings recursive environment bindings
    | recursive = inferRecursiveBindings environment bindings
    | otherwise = foldM (inferNonRecursiveBinding environment) [] bindings

-- ═════════════════════════════════════════════════════════════════════════════
-- inference: let expressions
-- ═════════════════════════════════════════════════════════════════════════════

{- | convert a Nix binding to (name, expr, span) tuples (1 per declared name)
inherit from scope desugars to a select expression
-}
parseBinding :: Nix.Binding NExprLoc -> [(Text, NExprLoc, Span)]
parseBinding (Nix.NamedVar (StaticKey name :| []) expr pos) =
    [(varNameText name, expr, posToSpan pos)]
parseBinding (Nix.Inherit mScope keys pos) =
    map
        ( \key ->
            let name = varNameText key
                expr = case mScope of
                    Just scope -> Fix (Compose (AnnUnit nullSpan (NSelect Nothing scope (StaticKey key :| []))))
                    Nothing -> Fix (Compose (AnnUnit nullSpan (NSym key)))
             in (name, expr, posToSpan pos)
        )
        keys
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
inferLetGroup :: TypeEnv -> TypeEnv -> SCC (Text, NExprLoc, Span) -> Infer TypeEnv
inferLetGroup _baseEnv currentEnv scc = do
    let groupBindings = case scc of
            AcyclicSCC x -> [x]
            CyclicSCC list -> list

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
        ( all
            ( \(resolved, original) -> case resolved of
                TVar vid -> TVar vid == original
                _ -> False
            )
            (zip resolvedVars freshVars)
        )
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
collectFreeVars (Fix (Compose (AnnUnit _ expr))) = case expr of
    NSym name -> [varNameText name]
    NList elems -> concatMap collectFreeVars elems
    NSet _ bindings -> concatMap collectFreeVarsBinding bindings
    NLet bindings body -> concatMap collectFreeVarsBinding bindings ++ collectFreeVars body
    NIf c t f -> collectFreeVars c ++ collectFreeVars t ++ collectFreeVars f
    NWith s b -> collectFreeVars s ++ collectFreeVars b
    NAssert c b -> collectFreeVars c ++ collectFreeVars b
    NAbs params b ->
        let bound = paramNames params
            paramFreeVars = paramDefaults params
         in paramFreeVars ++ filter (`notElem` bound) (collectFreeVars b)
    NApp f a -> collectFreeVars f ++ collectFreeVars a
    NSelect _ b _ -> collectFreeVars b
    NHasAttr b _ -> collectFreeVars b
    NUnary _ e -> collectFreeVars e
    NBinary _ l r -> collectFreeVars l ++ collectFreeVars r
    _ -> []

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
atomType = \case
    NInt _ -> TInt
    NFloat _ -> TFloat
    NBool _ -> TBool
    NNull -> TNull
    NURI _ -> TString

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
    case result of
        Left (e :: IOException) -> pure $ Left (T.pack $ show e)
        Right (Left doc) -> pure $ Left (T.pack $ show doc)
        Right (Right expr) ->
            case inferExpr expr of
                Left err -> pure $ Left err
                Right (t, bindings) -> pure $ Right $ InferResult bindings [(T.pack path, t)]
