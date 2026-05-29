{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                   // nix // module
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--   "And the next. And ever was."
--
--                                                                 — Count Zero
--
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                     // module // graph
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

module NixCompile.Nix.Module (
    -- * Module graph
    ModuleGraph (..),
    Module (..),
    Import (..),
    ParseFailure (..),
    LintFailure (..),
    LayoutFailure (..),

    -- * Building
    buildModuleGraph,
    buildModuleGraphFromFlake,

    -- * Queries
    moduleImports,
    moduleDependents,
    topologicalOrder,
    hasViolations,
    totalViolationCount,
    moduleTypes,

    -- * Import extraction
    findImports,
)
where

import Control.Exception (IOException, try)
import Control.Monad (foldM)
import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.List (isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Expr.Types hiding (Binding)
import Nix.Expr.Types qualified as Nix
import Nix.Expr.Types.Annotated
import Nix.Parser (parseNixFileLoc)
import Nix.Utils qualified as NixPath
import NixCompile.Nix.Infer (builtinEnv, extendImport, inferExpr, inferExprWithEnv)
import NixCompile.Nix.Layout (LayoutViolation, findLayoutViolations)
import NixCompile.Nix.Lint (NixViolation, findNixViolations)
import NixCompile.Nix.Types
import NixCompile.Types (Loc (..), Span (..))
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (normalise, pathSeparator, takeDirectory, (</>))

-- ═════════════════════════════════════════════════════════════════════════════
-- types
-- ═════════════════════════════════════════════════════════════════════════════

data Module = Module
    { modPath :: !FilePath
    , modExpr :: !NExprLoc
    , modType :: !NixType
    , modImports :: ![Import]
    }
    deriving (Show)

data Import = Import
    { impPath :: !FilePath
    , impRawPath :: !Text
    , impArgs :: !(Maybe NExprLoc)
    , impSpan :: !Span
    }
    deriving (Show)

data ParseFailure = ParseFailure
    { pfPath :: !FilePath
    , pfError :: !Text
    }
    deriving (Show)

data LintFailure = LintFailure
    { lfPath :: !FilePath
    , lfViolations :: ![NixViolation]
    }
    deriving (Show)

data LayoutFailure = LayoutFailure
    { layPath :: !FilePath
    , layViolations :: ![LayoutViolation]
    }
    deriving (Show)

data ModuleGraph = ModuleGraph
    { mgModules :: !(Map FilePath Module)
    , mgRoot :: !FilePath
    , mgOrder :: ![FilePath]
    , mgFailures :: ![ParseFailure]
    , mgLintFailures :: ![LintFailure]
    , mgLayoutFailures :: ![LayoutFailure]
    , mgModuleTypes :: !(Map FilePath NixType)
    }
    deriving (Show)

-- ═════════════════════════════════════════════════════════════════════════════
-- building
-- ═════════════════════════════════════════════════════════════════════════════

data BuildState = BuildState
    { bsModules :: !(Map FilePath Module)
    , bsFailures :: ![ParseFailure]
    , bsLintFailures :: ![LintFailure]
    , bsLayoutFailures :: ![LayoutFailure]
    }

-- ── entry points ─────────────────────────────────────────────────

{- | build a complete module graph starting from a root nix file
resolves imports transitively, computes topological order, collects failures,
then infers types in topological order with cross-module type propagation
-}
buildModuleGraph :: FilePath -> IO (Either Text ModuleGraph)
buildModuleGraph rootPath = do
    canonRoot <- canonicalizePath rootPath
    let rootDir = takeDirectory canonRoot
    finalState <- buildModules rootDir canonRoot Set.empty (BuildState Map.empty [] [] [])
    let order = computeOrder canonRoot (bsModules finalState)
    let moduleGraph =
            ModuleGraph
                { mgModules = bsModules finalState
                , mgRoot = canonRoot
                , mgOrder = order
                , mgFailures = reverse (bsFailures finalState)
                , mgLintFailures = reverse (bsLintFailures finalState)
                , mgLayoutFailures = reverse (bsLayoutFailures finalState)
                , mgModuleTypes = Map.empty
                }
    -- run topological type inference to fill in mgModuleTypes
    finalGraph <- inferModuleTypes moduleGraph
    pure $ Right finalGraph

-- | build module graph starting from flake.nix in the given directory
buildModuleGraphFromFlake :: FilePath -> IO (Either Text ModuleGraph)
buildModuleGraphFromFlake dir = do
    let flakePath = dir </> "flake.nix"
    exists <- doesFileExist flakePath
    if exists
        then buildModuleGraph flakePath
        else pure $ Left $ "No flake.nix found in " <> T.pack dir

-- ── recursive module loading ─────────────────────────────────────

-- | build modules by recursively walking imports, guarding against cycles via visited set
buildModules :: FilePath -> FilePath -> Set FilePath -> BuildState -> IO BuildState
buildModules _rootDir path visited state
    | path `Set.member` visited = pure state
    | otherwise = processFile path visited state

-- | parse a single file and, on success, process its imports
processFile :: FilePath -> Set FilePath -> BuildState -> IO BuildState
processFile path visited state = do
    fileExists <- doesFileExist path
    if not fileExists
        then pure state
        else do
            parseResult <- try (parseNixFileLoc (NixPath.Path path))
            case parseResult of
                Left (exception :: IOException) ->
                    pure $ state{bsFailures = ParseFailure path (T.pack $ show exception) : bsFailures state}
                Right (Left parseError) ->
                    pure $ state{bsFailures = ParseFailure path (T.pack (show parseError)) : bsFailures state}
                Right (Right expr) ->
                    processParsedFile path visited state expr

-- ── process a successfully parsed file ───────────────────────────

-- | extract imports, run type inference / lint / layout checks, then recurse
processParsedFile :: FilePath -> Set FilePath -> BuildState -> NExprLoc -> IO BuildState
processParsedFile path visited state expr = do
    let imports = findImports (takeDirectory path) expr
    let moduleType = case inferExpr expr of
            Right (type_, _) -> type_
            Left _ -> TAny
    let lintViolations = findNixViolations expr
    let layoutViolations = findLayoutViolations path expr

    let moduleDefinition =
            Module
                { modPath = path
                , modExpr = expr
                , modType = moduleType
                , modImports = imports
                }

    let withModule = state{bsModules = Map.insert path moduleDefinition (bsModules state)}
    let withLint = recordLintFailures path lintViolations withModule
    let withLayout = recordLayoutFailures path layoutViolations withLint
    let updatedVisited = Set.insert path visited

    foldM (processImport (takeDirectory path) updatedVisited) withLayout imports

-- | record lint violations only if non-empty (avoids cluttering failure list)
recordLintFailures :: FilePath -> [NixViolation] -> BuildState -> BuildState
recordLintFailures path violations state
    | null violations = state
    | otherwise = state{bsLintFailures = LintFailure path violations : bsLintFailures state}

recordLayoutFailures :: FilePath -> [LayoutViolation] -> BuildState -> BuildState
recordLayoutFailures path violations state
    | null violations = state
    | otherwise = state{bsLayoutFailures = LayoutFailure path violations : bsLayoutFailures state}

-- ── import processing ────────────────────────────────────────────

{- | process a single import: check existence, enforce root-boundary, recurse
n.b. imports outside rootDir are silently skipped (vendored deps boundary)
-}
processImport :: FilePath -> Set FilePath -> BuildState -> Import -> IO BuildState
processImport rootDir visited state importBinding = do
    exists <- doesFileExist (impPath importBinding)
    if not exists
        then pure state
        else do
            canonPath <- canonicalizePath (impPath importBinding)
            let rootPrefix = rootDir ++ [pathSeparator]
            if rootPrefix `isPrefixOf` canonPath || canonPath == rootDir
                then buildModules rootDir canonPath visited state
                else pure state

-- ═════════════════════════════════════════════════════════════════════════════
-- import finding
-- ═════════════════════════════════════════════════════════════════════════════

-- ── import finding: walk AST for `import ./path` calls ───────────

-- | walk an entire expression tree looking for import calls
findImports :: FilePath -> NExprLoc -> [Import]
findImports baseDir = walkExpr
  where
    walkExpr :: NExprLoc -> [Import]
    walkExpr (Fix (Compose (AnnUnit srcSpan expr))) = case expr of
        NApp func arg -> processApplication baseDir srcSpan func arg walkExpr
        NLet bindings body -> concatMap walkBinding bindings ++ walkExpr body
        NSet _ bindings -> concatMap walkBinding bindings
        NIf cond thenBranch elseBranch -> walkExpr cond ++ walkExpr thenBranch ++ walkExpr elseBranch
        NWith scope body -> walkExpr scope ++ walkExpr body
        NAssert cond body -> walkExpr cond ++ walkExpr body
        NAbs _ body -> walkExpr body
        NList elements -> concatMap walkExpr elements
        NSelect _ base _ -> walkExpr base
        NBinary _ left right -> walkExpr left ++ walkExpr right
        NUnary _ operand -> walkExpr operand
        _ -> []

    walkBinding :: Nix.Binding NExprLoc -> [Import]
    walkBinding (Nix.NamedVar _ expr _) = walkExpr expr
    walkBinding (Nix.Inherit (Just scope) _ _) = walkExpr scope
    walkBinding (Nix.Inherit Nothing _ _) = []

-- ── import application analysis ──────────────────────────────────

{- | given an application node, determine if it's an import and extract its parts
handles: import ./path, builtins.import ./path, import ./path (arg)
-}
processApplication :: FilePath -> SrcSpan -> NExprLoc -> NExprLoc -> (NExprLoc -> [Import]) -> [Import]
processApplication baseDir srcSpan func arg continue
    | Just () <- checkImportBuiltin func = makeImport baseDir (extractImportPath arg) Nothing srcSpan
    | Just (rawPath, Nothing) <- unwrapImportExpression func = makeImport baseDir rawPath (Just arg) srcSpan ++ continue arg
    | Just (rawPath, Just inner) <- unwrapImportExpression func = makeImport baseDir rawPath (Just arg) srcSpan ++ continue inner ++ continue arg
    | otherwise = continue func ++ continue arg

-- | check if an expression is literally the `import` builtin (or builtins.import)
checkImportBuiltin :: NExprLoc -> Maybe ()
checkImportBuiltin (Fix (Compose (AnnUnit _ expr))) = case expr of
    NSym name | nixVarNameText name == "import" -> Just ()
    NSelect _ _ (attr :| rest)
        | nixVarNameText (nixKeyName (last (attr : rest))) == "import" -> Just ()
    _ -> Nothing

{- | try to unwrap a nested import expression: import (./path + args)
returns (path, maybe inner-arg-expr)
-}
unwrapImportExpression :: NExprLoc -> Maybe (Text, Maybe NExprLoc)
unwrapImportExpression (Fix (Compose (AnnUnit _ expr))) = case expr of
    NApp func pathExpr -> unwrapImportHelper func pathExpr
    _ -> Nothing

-- | helper to unwrap import at the head of a chain of applications
unwrapImportHelper :: NExprLoc -> NExprLoc -> Maybe (Text, Maybe NExprLoc)
unwrapImportHelper func pathExpr
    | Fix (Compose (AnnUnit _ (NSym name))) <- func
    , nixVarNameText name == "import" =
        Just (extractImportPath pathExpr, Nothing)
    | Just (path, Nothing) <- unwrapImportExpression func
    , not (T.null path) =
        Just (path, Just pathExpr)
    | Just () <- checkImportBuiltin func = Just (extractImportPath pathExpr, Nothing)
    | otherwise = Nothing

-- | extract the file path text from an import argument expression
extractImportPath :: NExprLoc -> Text
extractImportPath (Fix (Compose (AnnUnit _ expr))) = case expr of
    NLiteralPath (NixPath.Path p) -> T.pack p
    NStr (DoubleQuoted [Plain t]) -> t
    NStr (Indented _ [Plain t]) -> t
    _ -> ""

-- ── key & name helpers ───────────────────────────────────────────

nixKeyName :: NKeyName r -> VarName
nixKeyName (StaticKey key) = key
nixKeyName (DynamicKey _) = VarName ""

nixVarNameText :: VarName -> Text
nixVarNameText = coerce

-- | construct an Import record from a raw path string and source location
makeImport :: FilePath -> Text -> Maybe NExprLoc -> SrcSpan -> [Import]
makeImport baseDirectory rawPath arguments srcSpan
    | T.null rawPath = []
    | otherwise =
        let resolvedPath = resolveImportPath baseDirectory (T.unpack rawPath)
         in [ Import
                { impPath = resolvedPath
                , impRawPath = rawPath
                , impArgs = arguments
                , impSpan = nixSrcSpanToSpan srcSpan
                }
            ]

-- ── Nix SrcSpan → our Span type ──────────────────────────────────

nixSrcSpanToSpan :: SrcSpan -> Span
nixSrcSpanToSpan srcSpan =
    let begin = getSpanBegin srcSpan
        end = getSpanEnd srcSpan
        fileFromBegin = case begin of
            NSourcePos path _ _ -> Just (coerce path)
     in Span
            { spanStart = Loc (nixSourceLine begin) (nixSourceCol begin)
            , spanEnd = Loc (nixSourceLine end) (nixSourceCol end)
            , spanFile = fileFromBegin
            }

nixSourceLine :: NSourcePos -> Int
nixSourceLine (NSourcePos _ (NPos line) _) = unPos line

nixSourceCol :: NSourcePos -> Int
nixSourceCol (NSourcePos _ _ (NPos col)) = unPos col

-- | resolve a relative or absolute import path against the base directory
resolveImportPath :: FilePath -> FilePath -> FilePath
resolveImportPath baseDir path = case path of
    '.' : _ -> normalise (baseDir </> path)
    '/' : _ -> path
    _ -> path

-- ═════════════════════════════════════════════════════════════════════════════
-- queries
-- ═════════════════════════════════════════════════════════════════════════════

-- | look up the imports of a specific module by path
moduleImports :: ModuleGraph -> FilePath -> [Import]
moduleImports mg path = maybe [] modImports (Map.lookup path (mgModules mg))

-- | find all modules that directly import the given path
moduleDependents :: ModuleGraph -> FilePath -> [FilePath]
moduleDependents mg path =
    [ modPath m
    | m <- Map.elems (mgModules mg)
    , any (\i -> impPath i == path) (modImports m)
    ]

-- | expose the pre-computed topological order
topologicalOrder :: ModuleGraph -> [FilePath]
topologicalOrder = mgOrder

-- | look up the inferred type for a module
moduleTypes :: ModuleGraph -> Map FilePath NixType
moduleTypes = mgModuleTypes

-- | does this graph have any failures at all (parse, lint, or layout)?
hasViolations :: ModuleGraph -> Bool
hasViolations mg =
    not (null (mgFailures mg))
        || not (null (mgLintFailures mg))
        || not (null (mgLayoutFailures mg))

-- | total count of all violations across all categories
totalViolationCount :: ModuleGraph -> Int
totalViolationCount mg =
    length (mgFailures mg)
        + sum (map (length . lfViolations) (mgLintFailures mg))
        + sum (map (length . layViolations) (mgLayoutFailures mg))

-- ── topological type inference ───────────────────────────────────

{- | infer types for all modules in topological order, propagating types through imports
dependencies are inferred first, their types are fed into importers via TypeEnv
-}
inferModuleTypes :: ModuleGraph -> IO ModuleGraph
inferModuleTypes mg = do
    let order = mgOrder mg
    (finalTypes, _) <- foldM inferOneModule (Map.empty, Map.empty) order
    -- update each module's modType with the cross-module inferred type
    let updatedModules = Map.mapWithKey (\p m -> case Map.lookup p finalTypes of
                            Just t -> m{modType = t}
                            Nothing -> m
                        ) (mgModules mg)
    pure mg{mgModuleTypes = finalTypes, mgModules = updatedModules}
  where
    inferOneModule :: (Map FilePath NixType, Map FilePath [FilePath]) -> FilePath -> IO (Map FilePath NixType, Map FilePath [FilePath])
    inferOneModule (types, pendingDeps) path = do
        let imports = case Map.lookup path (mgModules mg) of
                Nothing -> []
                Just m -> modImports m
        -- insert types for both raw import paths (as written in the code) and resolved paths
        canonicImports <- mapM (\i -> canonicalizePath (impPath i)) imports
        let rawPaths = map (T.unpack . impRawPath) imports
        let resolvedPaths = map impPath imports
        -- n.b. look up in `types` by resolved path, then insert for both raw and resolved keys
        let env =
                foldr
                    (\p e -> case Map.lookup p types of
                        Just t -> extendImport p t e
                        Nothing -> e
                    )
                    builtinEnv
                    (resolvedPaths ++ canonicImports)
        let finalEnv =
                foldr
                    (\(raw, resolved) e -> case Map.lookup resolved types of
                        Just t -> extendImport raw t e
                        Nothing -> e
                    )
                    env
                    (zip rawPaths resolvedPaths)
        case Map.lookup path (mgModules mg) of
            Nothing -> pure (types, pendingDeps)
            Just m -> do
                let result = inferExprWithEnv finalEnv (modExpr m)
                case result of
                    Left _ -> pure (types, pendingDeps)
                    Right (t, _) -> pure (Map.insert path t types, pendingDeps)

{- | compute a DFS-based topological order starting from the root module
n.b. result is reversed so root appears first
-}
computeOrder :: FilePath -> Map FilePath Module -> [FilePath]
computeOrder root modules = reverse $ snd $ dfs Set.empty [] root
  where
    dfs :: Set FilePath -> [FilePath] -> FilePath -> (Set FilePath, [FilePath])
    dfs visited order path
        | path `Set.member` visited = (visited, order)
        | otherwise =
            case Map.lookup path modules of
                Nothing -> (visited, order)
                Just m ->
                    let visited' = Set.insert path visited
                        (visited'', order') = foldl go (visited', order) (map impPath (modImports m))
                     in (visited'', path : order')

    go (v, o) p = dfs v o p
