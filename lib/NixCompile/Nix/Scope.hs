{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // nix // compile // scope
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "Machine dreams hold a special vertigo. Turner lay down on a
--    virgin slab of green temperfoam in the makeshift dorm and
--    jacked Mitchell's dossier."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // core // types
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Scope (
  -- * Core Types
  ScopeGraph (..),
  Scope (..),
  ScopeId (..),
  ScopeKind (..),
  Declaration (..),
  Reference (..),
  RefKind (..),
  Edge (..),
  EdgeLabel (..),

  -- * Source Locations
  SourceSpan (..),
  SourcePos (..),

  -- * Construction
  empty,
  fromNixExpr,
  fromNixFile,
  fromModuleGraph,
  mergeGraphs,

  -- * Resolution
  resolve,
  resolveAll,
  ResolutionError (..),

  -- * Queries
  declarationsInScope,
  referencesInScope,
  findDeclaration,
  findReferences,

  -- * Export (for zeitschrift)
  toJSON,
  toDhall,
)
where

import Control.Monad (forM_)
import Control.Monad.State.Strict
import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

import Data.Aeson (ToJSON (..), ToJSONKey (..), (.=))
import Data.Aeson qualified as Aeson
import Dhall (ToDhall (..))
import Dhall qualified
import Dhall.Core qualified as Dhall
import Dhall.Marshal.Encode qualified as Encode
import Nix.Expr.Types hiding (Binding, SourcePos)
import Nix.Expr.Types qualified as Nix
import Nix.Expr.Types.Annotated
import Nix.Utils (Path (..))

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // core // types
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data ScopeGraph = ScopeGraph
  { sgScopes :: Map ScopeId Scope
  , sgRoot :: ScopeId
  , sgNextId :: Int
  , sgFile :: Maybe FilePath
  }
  deriving stock (Eq, Show, Generic)

data Scope = Scope
  { scopeId :: ScopeId
  , scopeDeclarations :: [Declaration]
  , scopeReferences :: [Reference]
  , scopeEdges :: [Edge]
  , scopeKind :: ScopeKind
  }
  deriving stock (Eq, Show, Generic)

data ScopeKind
  = FileScope
  | LetScope
  | AttrSetScope
  | RecAttrSetScope
  | FunctionScope
  | WithScope
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToDhall)

newtype ScopeId = ScopeId {unScopeId :: Int}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (Num, ToJSON, ToJSONKey)

data Declaration = Declaration
  { declName :: Text
  , declSpan :: SourceSpan
  , declScope :: ScopeId
  , declAssocScope :: Maybe ScopeId
  , declType :: Maybe Text
  , declDoc :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

data Reference = Reference
  { refName :: Text
  , refSpan :: SourceSpan
  , refScope :: ScopeId
  , refKind :: RefKind
  }
  deriving stock (Eq, Show, Generic)

data RefKind
  = VarRef
  | AttrRef
  | InheritRef
  | ImportRef
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToDhall)

data Edge = Edge
  { edgeSource :: ScopeId
  , edgeTarget :: ScopeId
  , edgeLabel :: EdgeLabel
  }
  deriving stock (Eq, Show, Generic)

data EdgeLabel
  = Parent
  | Import
  | With
  | Inherit
  | AttrAccess
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToDhall)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // source // locations
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data SourceSpan = SourceSpan
  { spanStart :: SourcePos
  , spanEnd :: SourcePos
  , spanFile :: Maybe FilePath
  }
  deriving stock (Eq, Show, Generic)

data SourcePos = SourcePos
  { posLine :: Int
  , posCol :: Int
  }
  deriving stock (Eq, Show, Generic)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // construction // state
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ── build state: graph under construction + current insertion point ─

data BuildState = BuildState
  { bsGraph :: ScopeGraph
  , bsCurrentScope :: ScopeId
  }

type Build a = State BuildState a

-- | allocate a new scope node with the given kind, insert into graph
freshScope :: ScopeKind -> Build ScopeId
freshScope kind = do
  st <- get
  let newId = ScopeId (sgNextId (bsGraph st))
  let scope = Scope newId [] [] [] kind
  put
    st
      { bsGraph =
          (bsGraph st)
            { sgScopes = Map.insert newId scope (sgScopes (bsGraph st))
            , sgNextId = sgNextId (bsGraph st) + 1
            }
      }
  pure newId

-- | append a declaration to the current scope's declaration list
addDecl :: Declaration -> Build ()
addDecl decl = do
  st <- get
  let sid = declScope decl
  let update s = s{scopeDeclarations = decl : scopeDeclarations s}
  put
    st
      { bsGraph =
          (bsGraph st)
            { sgScopes = Map.adjust update sid (sgScopes (bsGraph st))
            }
      }

-- | record a reference in the current scope
addRef :: Reference -> Build ()
addRef ref = do
  st <- get
  let sid = refScope ref
  let update s = s{scopeReferences = ref : scopeReferences s}
  put
    st
      { bsGraph =
          (bsGraph st)
            { sgScopes = Map.adjust update sid (sgScopes (bsGraph st))
            }
      }

-- | add an edge between two scopes (parent, import, with, inherit, attr-access)
addEdge :: Edge -> Build ()
addEdge edge = do
  st <- get
  let sid = edgeSource edge
  let update s = s{scopeEdges = edge : scopeEdges s}
  put
    st
      { bsGraph =
          (bsGraph st)
            { sgScopes = Map.adjust update sid (sgScopes (bsGraph st))
            }
      }

-- | read the current scope (insertion point)
currentScope :: Build ScopeId
currentScope = gets bsCurrentScope

-- | run an action under a given scope, restoring the previous one after
withScope :: ScopeId -> Build a -> Build a
withScope sid action = do
  old <- gets bsCurrentScope
  modify $ \st -> st{bsCurrentScope = sid}
  result <- action
  modify $ \st -> st{bsCurrentScope = old}
  pure result

-- | create a child scope, link it to parent via Parent edge, run action
withChildScope :: ScopeKind -> (ScopeId -> Build ()) -> Build ()
withChildScope kind action = do
  parent <- currentScope
  childScope <- freshScope kind
  addEdge (Edge childScope parent Parent)
  withScope childScope (action childScope)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // construction // from // nix
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ── graph construction ───────────────────────────────────────────

-- | empty scope graph: one root FileScope node
empty :: ScopeGraph
empty =
  ScopeGraph
    { sgScopes = Map.singleton (ScopeId 0) (Scope (ScopeId 0) [] [] [] FileScope)
    , sgRoot = ScopeId 0
    , sgNextId = 1
    , sgFile = Nothing
    }

-- | build a scope graph from a single Nix expression (may be file-backed)
fromNixExpr :: Maybe FilePath -> NExprLoc -> ScopeGraph
fromNixExpr maybeFilePath expr =
  let initState =
        BuildState
          { bsGraph = empty{sgFile = maybeFilePath}
          , bsCurrentScope = ScopeId 0
          }
      finalState = execState (buildExpr expr) initState
   in bsGraph finalState

-- | build scope graph, recording the file path
fromNixFile :: FilePath -> NExprLoc -> ScopeGraph
fromNixFile = fromNixExpr . Just

-- | build a combined scope graph from multiple files, linking imports
fromModuleGraph :: Map FilePath NExprLoc -> ScopeGraph
fromModuleGraph modules
  | Map.null modules = empty
  | otherwise =
      let fileGraphs = Map.mapWithKey fromNixFile modules
          (merged, fileRoots) = mergeGraphs (Map.elems fileGraphs)
          withImports = addImportEdges merged fileRoots
       in withImports

-- | merge multiple scope graphs into one by offsetting scope IDs
mergeGraphs :: [ScopeGraph] -> (ScopeGraph, [ScopeId])
mergeGraphs [] = (empty, [])
mergeGraphs graphs =
  let (finalGraph, _, roots) = foldl mergeOneGraph (empty, sgNextId empty, []) graphs
   in (finalGraph, reverse roots)

{- | merge a single graph into the accumulator, remapping all IDs by an offset
n.b. the offset ensures no ID collisions across files
-}
mergeOneGraph :: (ScopeGraph, Int, [ScopeId]) -> ScopeGraph -> (ScopeGraph, Int, [ScopeId])
mergeOneGraph (accumulator, nextId, roots) scopeGraph =
  let offset = nextId - unScopeId (sgRoot scopeGraph)
      remappedScopes =
        Map.fromList
          [ (remapScopeId offset scopeId, remapEntireScope offset scope)
          | (scopeId, scope) <- Map.toList (sgScopes scopeGraph)
          ]
      newRoot = remapScopeId offset (sgRoot scopeGraph)
      maxId =
        if Map.null remappedScopes
          then nextId
          else maximum (map (unScopeId . fst) (Map.toList remappedScopes)) + 1
      updatedAccumulator =
        accumulator
          { sgScopes = Map.union (sgScopes accumulator) remappedScopes
          , sgNextId = maxId
          , sgFile = chooseFile (sgFile accumulator) (sgFile scopeGraph)
          }
   in (updatedAccumulator, maxId, newRoot : roots)

-- | shift a ScopeId by a constant offset (to avoid collisions during merge)
remapScopeId :: Int -> ScopeId -> ScopeId
remapScopeId offset scopeId = ScopeId (unScopeId scopeId + offset)

-- | remap all IDs inside a scope (declarations, refs, edges)
remapEntireScope :: Int -> Scope -> Scope
remapEntireScope offset scope =
  scope
    { scopeId = remapScopeId offset (scopeId scope)
    , scopeDeclarations = map (remapDeclaration offset) (scopeDeclarations scope)
    , scopeReferences = map (remapReference offset) (scopeReferences scope)
    , scopeEdges = map (remapEdge' offset) (scopeEdges scope)
    }

remapDeclaration :: Int -> Declaration -> Declaration
remapDeclaration offset declaration =
  declaration{declScope = remapScopeId offset (declScope declaration), declAssocScope = fmap (remapScopeId offset) (declAssocScope declaration)}

remapReference :: Int -> Reference -> Reference
remapReference offset reference = reference{refScope = remapScopeId offset (refScope reference)}

remapEdge' :: Int -> Edge -> Edge
remapEdge' offset edge = edge{edgeSource = remapScopeId offset (edgeSource edge), edgeTarget = remapScopeId offset (edgeTarget edge)}

-- | prefer the first file path over the second
chooseFile :: Maybe FilePath -> Maybe FilePath -> Maybe FilePath
chooseFile (Just a) _ = Just a
chooseFile Nothing b = b

{- | add Import edges connecting file roots under a synthetic global root
single-file graphs just use that file as root; multi-file gets a virtual parent
-}
addImportEdges :: ScopeGraph -> [ScopeId] -> ScopeGraph
addImportEdges scopeGraph [] = scopeGraph
addImportEdges scopeGraph [single] = scopeGraph{sgRoot = single}
addImportEdges scopeGraph fileRoots =
  let globalRoot = ScopeId (sgNextId scopeGraph)
      globalScope = Scope globalRoot [] [] (map (\fr -> Edge globalRoot fr Import) fileRoots) FileScope
   in scopeGraph
        { sgScopes = Map.insert globalRoot globalScope (sgScopes scopeGraph)
        , sgRoot = globalRoot
        , sgNextId = sgNextId scopeGraph + 1
        }

-- ── expression traversal helpers ─────────────────────────────────

-- | register a symbol reference at the current scope
buildSymbolRef :: SrcSpan -> VarName -> Build ()
buildSymbolRef srcSpan name = do
  scope <- currentScope
  addRef $
    Reference
      { refName = coerce name
      , refSpan = toSourceSpan srcSpan
      , refScope = scope
      , refKind = VarRef
      }

-- | register an attribute reference (e.name) at a given scope
addAttrRef :: SrcSpan -> ScopeId -> NKeyName NExprLoc -> Build ()
addAttrRef srcSpan scope keyName =
  addRef $
    Reference
      { refName = keyToText keyName
      , refSpan = toSourceSpan srcSpan
      , refScope = scope
      , refKind = AttrRef
      }

{- | build scope sub-graph for `with expr; body`
creates two scopes: one for the with-expression, one for the body
body scope has a With-edge to the expr scope
-}
buildWithExpr :: SrcSpan -> NExprLoc -> NExprLoc -> Build ()
buildWithExpr _srcSpan withExpr body = do
  parent <- currentScope
  withExprScope <- freshScope WithScope
  addEdge (Edge withExprScope parent Parent)
  withScope withExprScope $ buildExpr withExpr
  bodyScopeId <- freshScope LetScope
  addEdge (Edge bodyScopeId parent Parent)
  addEdge (Edge bodyScopeId withExprScope With)
  withScope bodyScopeId $ buildExpr body

-- ── string part extraction ──────────────────────────────────────

-- | extract all Nix expressions embedded within string antiquotations
exprsFromString :: NString NExprLoc -> [NExprLoc]
exprsFromString (DoubleQuoted parts) = mapMaybe extractExpr parts
exprsFromString (Indented _ parts) = mapMaybe extractExpr parts

extractExpr :: Antiquoted Text NExprLoc -> Maybe NExprLoc
extractExpr (Antiquoted e) = Just e
extractExpr _ = Nothing

-- ── walk an expression, building scope graph nodes ─────────────────

{- | dispatch on AST node to create scopes, declarations, and references
each scope-creating AST form (let, set, lambda, with) opens a child scope
-}
buildExpr :: NExprLoc -> Build ()
buildExpr (Fix (Compose (AnnUnit srcSpan e))) = case e of
  -- ── let ... in ...: child scope, declare all bindings in it ──
  NLet bindings body ->
    withChildScope LetScope $ \letScope -> do
      mapM_ (addBindingDecl letScope) bindings
      mapM_ buildBinding bindings
      buildExpr body
  -- ── non-recursive set: child scope ──
  NSet NonRecursive bindings ->
    withChildScope AttrSetScope $ \attrScope -> do
      mapM_ (addBindingDecl attrScope) bindings
      mapM_ buildBinding bindings
  -- ── recursive set: separate scope kind so we can distinguish ──
  NSet Recursive bindings ->
    withChildScope RecAttrSetScope $ \attrScope -> do
      mapM_ (addBindingDecl attrScope) bindings
      mapM_ buildBinding bindings
  -- ── lambda: function scope with parameter declarations ──
  NAbs params body ->
    withChildScope FunctionScope $ \funScope -> do
      addParamDecls funScope params
      buildExpr body
  -- ── with expr; body: special With-scope linked to expr scope ──
  NWith withExpr body -> buildWithExpr srcSpan withExpr body
  -- ── symbol reference ──
  NSym name -> buildSymbolRef srcSpan name
  -- ── attribute select: base + attr references ──
  NSelect _ base (attr :| rest) -> do
    buildExpr base
    scope <- currentScope
    addAttrRef srcSpan scope attr
    mapM_ (addAttrRef srcSpan scope) rest
  -- ── application: both sides ──
  NApp func arg -> do
    buildExpr func
    buildExpr arg
  -- ── binary / unary: recurse ──
  NBinary _ left right -> do
    buildExpr left
    buildExpr right
  NUnary _ operand -> buildExpr operand
  -- ── conditional: all branches ──
  NIf cond thenBranch elseBranch -> do
    buildExpr cond
    buildExpr thenBranch
    buildExpr elseBranch
  -- ── assertion: cond + body ──
  NAssert cond body -> do
    buildExpr cond
    buildExpr body
  -- ── list: every element ──
  NList elements -> mapM_ buildExpr elements
  -- ── string: traverse antiquoted expressions (e.g. ${srv.host}) ──
  NStr strParts -> mapM_ buildExpr (exprsFromString strParts)
  -- ── path: walk any embedded expressions ──
  NLiteralPath _ -> pure ()
  NEnvPath _ -> pure ()
  -- ── has-attr: walk base expression ──
  NHasAttr base _pat -> buildExpr base
  -- ── synonym hole (editor placeholder) ──
  NSynHole _ -> pure ()
  _ -> pure ()

addBindingDecl :: ScopeId -> Nix.Binding NExprLoc -> Build ()
addBindingDecl scope = \case
  Nix.NamedVar (StaticKey name :| []) _ srcSpan -> do
    addDecl $
      Declaration
        { declName = coerce name
        , declSpan = toSourceSpan' srcSpan
        , declScope = scope
        , declAssocScope = Nothing
        , declType = Nothing
        , declDoc = Nothing
        }
  Nix.Inherit _ names srcSpan ->
    forM_ names $ \varName ->
      addDecl $
        Declaration
          { declName = coerce varName
          , declSpan = toSourceSpan' srcSpan
          , declScope = scope
          , declAssocScope = Nothing
          , declType = Nothing
          , declDoc = Nothing
          }
  _ -> pure ()

buildBinding :: Nix.Binding NExprLoc -> Build ()
buildBinding = \case
  Nix.NamedVar _ expr _ -> buildExpr expr
  Nix.Inherit (Just expr) _ _ -> buildExpr expr
  Nix.Inherit Nothing _ _ -> pure ()

-- ── register parameter declarations in the function's scope ─────────

-- | declare lambda parameters: simple name, or set-pattern (with optional @-bind)
addParamDecls :: ScopeId -> Params NExprLoc -> Build ()
addParamDecls scope = \case
  -- simple param: f = x: ...
  Param name ->
    addDecl $
      Declaration
        { declName = coerce name
        , declSpan = emptySpan
        , declScope = scope
        , declAssocScope = Nothing
        , declType = Nothing
        , declDoc = Nothing
        }
  -- set pattern: { name ? default, ... } @ self ->
  ParamSet mname _variadic pset -> do
    addParamSetAtName scope mname
    forM_ pset $ \(pname, mdefault) -> do
      addDecl $
        Declaration
          { declName = coerce pname
          , declSpan = emptySpan
          , declScope = scope
          , declAssocScope = Nothing
          , declType = Nothing
          , declDoc = Nothing
          }
      mapM_ buildExpr mdefault
 where
  addParamSetAtName sc (Just pname) =
    addDecl $
      Declaration
        { declName = coerce pname
        , declSpan = emptySpan
        , declScope = sc
        , declAssocScope = Nothing
        , declType = Nothing
        , declDoc = Nothing
        }
  addParamSetAtName _ Nothing = pure ()

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                // resolution
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ── name resolution: find which declaration a reference points to ──

data ResolutionError
  = Unresolved Reference
  | Ambiguous Reference [Declaration]
  deriving stock (Eq, Show, Generic)

-- | resolve a single reference to its declaration
resolve :: ScopeGraph -> Reference -> Either ResolutionError Declaration
resolve scopeGraph ref =
  case findPaths scopeGraph (refScope ref) (refName ref) of
    [] -> Left (Unresolved ref)
    [d] -> Right d
    ds -> Left (Ambiguous ref ds)

-- | resolve all references in a graph, collecting errors
resolveAll :: ScopeGraph -> Either [ResolutionError] [(Reference, Declaration)]
resolveAll scopeGraph =
  let refs = concatMap scopeReferences (Map.elems (sgScopes scopeGraph))
      results = map (\ref -> (ref, resolve scopeGraph ref)) refs
      errors = [err | (_, Left err) <- results]
      successes = [(ref, decl) | (ref, Right decl) <- results]
   in if null errors
        then Right successes
        else Left errors

{- | search for a declaration by name, walking up through edge chains
edges are grouped by label and tried in priority order (Parent, Import, With, ...)
-}
findPaths :: ScopeGraph -> ScopeId -> Text -> [Declaration]
findPaths scopeGraph startScope targetName = searchScope Set.empty startScope
 where
  searchScope :: Set ScopeId -> ScopeId -> [Declaration]
  searchScope visited scopeId
    | Set.member scopeId visited = [] -- cycle guard
    | otherwise =
        case Map.lookup scopeId (sgScopes scopeGraph) of
          Nothing -> []
          Just scope ->
            let updatedVisited = Set.insert scopeId visited
                localDeclarations = filter (\d -> declName d == targetName) (scopeDeclarations scope)
                -- try each edge label group in order; stop at the first group that yields results
                fromEdges =
                  firstNonEmptyGroup
                    [ concatMap (searchScope updatedVisited . edgeTarget) group
                    | group <- groupEdgesByLabel (scopeEdges scope)
                    ]
             in if not (null localDeclarations) then localDeclarations else fromEdges

-- | group edges by their label, maintaining priority order within each group
groupEdgesByLabel :: [Edge] -> [[Edge]]
groupEdgesByLabel = groupByEdgeLabel . sortOn edgeLabel

groupByEdgeLabel :: [Edge] -> [[Edge]]
groupByEdgeLabel [] = []
groupByEdgeLabel (edge : rest) =
  let (sameLabel, different) = Prelude.span (\e -> edgeLabel e == edgeLabel edge) rest
   in (edge : sameLabel) : groupByEdgeLabel different

-- | return the first non-empty group, or [] if all are empty
firstNonEmptyGroup :: [[a]] -> [a]
firstNonEmptyGroup [] = []
firstNonEmptyGroup (group : rest)
  | null group = firstNonEmptyGroup rest
  | otherwise = group

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                   // queries
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ── queries against the scope graph ──────────────────────────────

-- | all declarations reachable from a scope (walking edges transitively)
declarationsInScope :: ScopeGraph -> ScopeId -> [Declaration]
declarationsInScope scopeGraph outerScopeId = go Set.empty outerScopeId
 where
  go visited currentScopeId
    | Set.member currentScopeId visited = []
    | otherwise = case Map.lookup currentScopeId (sgScopes scopeGraph) of
        Nothing -> []
        Just scope ->
          let visited' = Set.insert currentScopeId visited
           in scopeDeclarations scope
                ++ concatMap (go visited' . edgeTarget) (scopeEdges scope)

-- | all references in a specific scope
referencesInScope :: ScopeGraph -> ScopeId -> [Reference]
referencesInScope scopeGraph scopeId = case Map.lookup scopeId (sgScopes scopeGraph) of
  Nothing -> []
  Just scope -> scopeReferences scope

-- | find all declarations with a given name across the whole graph
findDeclaration :: ScopeGraph -> Text -> [Declaration]
findDeclaration scopeGraph name =
  [ d
  | scope <- Map.elems (sgScopes scopeGraph)
  , d <- scopeDeclarations scope
  , declName d == name
  ]

-- | find all references that resolve to a specific declaration
findReferences :: ScopeGraph -> Declaration -> [Reference]
findReferences scopeGraph decl =
  [ ref
  | scope <- Map.elems (sgScopes scopeGraph)
  , ref <- scopeReferences scope
  , refName ref == declName decl
  , resolvesToDecl ref
  ]
 where
  resolvesToDecl ref = case resolve scopeGraph ref of
    Right d -> declScope d == declScope decl && declSpan d == declSpan decl
    Left _ -> False

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // json // export
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

instance ToJSON ScopeGraph where
  toJSON scopeGraph =
    Aeson.object
      [ "scopes" .= sgScopes scopeGraph
      , "root" .= sgRoot scopeGraph
      , "file" .= sgFile scopeGraph
      ]

instance ToJSON Scope where
  toJSON s =
    Aeson.object
      [ "id" .= scopeId s
      , "declarations" .= scopeDeclarations s
      , "references" .= scopeReferences s
      , "edges" .= scopeEdges s
      , "kind" .= show (scopeKind s)
      ]

instance ToJSON Declaration where
  toJSON d =
    Aeson.object
      [ "name" .= declName d
      , "span" .= declSpan d
      , "scope" .= declScope d
      , "assocScope" .= declAssocScope d
      , "type" .= declType d
      , "doc" .= declDoc d
      ]

instance ToJSON Reference where
  toJSON r =
    Aeson.object
      [ "name" .= refName r
      , "span" .= refSpan r
      , "scope" .= refScope r
      , "kind" .= show (refKind r)
      ]

instance ToJSON Edge where
  toJSON e =
    Aeson.object
      [ "source" .= edgeSource e
      , "target" .= edgeTarget e
      , "label" .= show (edgeLabel e)
      ]

instance ToJSON SourceSpan where
  toJSON s =
    Aeson.object
      [ "start" .= spanStart s
      , "end" .= spanEnd s
      , "file" .= spanFile s
      ]

instance ToJSON SourcePos where
  toJSON p =
    Aeson.object
      [ "line" .= posLine p
      , "col" .= posCol p
      ]

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                           // dhall // export
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data SourcePosExport = SourcePosExport
  { line :: Natural
  , col :: Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToDhall)

data SourceSpanExport = SourceSpanExport
  { start :: SourcePosExport
  , end :: SourcePosExport
  , file :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToDhall)

data DeclarationExport = DeclarationExport
  { name :: Text
  , span :: SourceSpanExport
  , scope :: Natural
  , assocScope :: Maybe Natural
  , type_ :: Maybe Text
  , doc :: Maybe Text
  , kind :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

instance ToDhall DeclarationExport where
  injectWith _normalizer =
    let opts =
          Encode.defaultInterpretOptions
            { Encode.fieldModifier = T.dropWhileEnd (== '_')
            }
     in Encode.genericToDhallWith opts

data ReferenceExport = ReferenceExport
  { name :: Text
  , span :: SourceSpanExport
  , scope :: Natural
  , kind :: RefKind
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToDhall)

data EdgeExport = EdgeExport
  { source :: Natural
  , target :: Natural
  , label :: EdgeLabel
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToDhall)

data ScopeExport = ScopeExport
  { id :: Natural
  , declarations :: [DeclarationExport]
  , references :: [ReferenceExport]
  , edges :: [EdgeExport]
  , kind :: ScopeKind
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToDhall)

data ScopeGraphExport = ScopeGraphExport
  { scopes :: [ScopeExport]
  , root :: Natural
  , file :: Maybe Text
  , files :: [Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToDhall)

toExport :: ScopeGraph -> ScopeGraphExport
toExport scopeGraph =
  ScopeGraphExport
    { scopes = map scopeToExport (Map.elems (sgScopes scopeGraph))
    , root = fromIntegral (unScopeId (sgRoot scopeGraph))
    , file = T.pack <$> sgFile scopeGraph
    , files = []
    }
 where
  scopeToExport :: Scope -> ScopeExport
  scopeToExport s =
    ScopeExport
      { id = fromIntegral (unScopeId (scopeId s))
      , declarations = map declToExport (scopeDeclarations s)
      , references = map refToExport (scopeReferences s)
      , edges = map edgeToExport (scopeEdges s)
      , kind = scopeKind s
      }

  declToExport :: Declaration -> DeclarationExport
  declToExport d =
    DeclarationExport
      { name = declName d
      , span = spanToExport (declSpan d)
      , scope = fromIntegral (unScopeId (declScope d))
      , assocScope = fromIntegral . unScopeId <$> declAssocScope d
      , type_ = declType d
      , doc = declDoc d
      , kind = Nothing
      }

  refToExport :: Reference -> ReferenceExport
  refToExport r =
    ReferenceExport
      { name = refName r
      , span = spanToExport (refSpan r)
      , scope = fromIntegral (unScopeId (refScope r))
      , kind = refKind r
      }

  edgeToExport :: Edge -> EdgeExport
  edgeToExport e =
    EdgeExport
      { source = fromIntegral (unScopeId (edgeSource e))
      , target = fromIntegral (unScopeId (edgeTarget e))
      , label = edgeLabel e
      }

  spanToExport :: SourceSpan -> SourceSpanExport
  spanToExport sourceSpan =
    SourceSpanExport
      { start = posToExport (spanStart sourceSpan)
      , end = posToExport (spanEnd sourceSpan)
      , file = T.pack <$> spanFile sourceSpan
      }

  posToExport :: SourcePos -> SourcePosExport
  posToExport p =
    SourcePosExport
      { line = fromIntegral (posLine p)
      , col = fromIntegral (posCol p)
      }

toDhall :: ScopeGraph -> Text
toDhall scopeGraph = Dhall.pretty (Dhall.embed Dhall.inject (toExport scopeGraph))

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                 // utilities
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ── Nix SrcSpan → our SourceSpan ─────────────────────────────────

-- | convert a ranged Nix SrcSpan (begin..end) to our SourceSpan
toSourceSpan :: SrcSpan -> SourceSpan
toSourceSpan srcSpan =
  let begin = getSpanBegin srcSpan
      end = getSpanEnd srcSpan
      fileFromBegin = case begin of
        NSourcePos path _ _ -> Just (coerce path)
   in SourceSpan
        { spanStart = SourcePos (sourceLine begin) (sourceCol begin)
        , spanEnd = SourcePos (sourceLine end) (sourceCol end)
        , spanFile = fileFromBegin
        }
 where
  sourceLine (NSourcePos _ (NPos l) _) = unPos l
  sourceCol (NSourcePos _ _ (NPos c)) = unPos c

-- | convert a point Nix NSourcePos to a zero-width SourceSpan
toSourceSpan' :: NSourcePos -> SourceSpan
toSourceSpan' (NSourcePos path (NPos l) (NPos c)) =
  SourceSpan
    { spanStart = SourcePos (unPos l) (unPos c)
    , spanEnd = SourcePos (unPos l) (unPos c)
    , spanFile = Just (coerce path)
    }

-- | sentinel span used for synthetic nodes (parameter declarations, etc.)
emptySpan :: SourceSpan
emptySpan = SourceSpan (SourcePos 0 0) (SourcePos 0 0) Nothing

-- ── key → text (dynamic keys get a placeholder) ──────────────────
keyToText :: NKeyName r -> Text
keyToText (StaticKey name) = coerce name
keyToText (DynamicKey _) = "<dynamic>"
