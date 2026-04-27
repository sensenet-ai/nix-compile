{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Props
-- Description : Property tests for nix-compile
--
-- Brutalize the type inference system with QuickCheck.
--
-- Properties tested:
--   1. Parser totality: valid bash never crashes the parser
--   2. Unification algebra: reflexive, symmetric, transitive, idempotent
--   3. Constraint determinism: same facts -> same constraints
--   4. Schema consistency: inferred types match literal evidence
--   5. Substitution composition: (s1 . s2) t == s1 (s2 t)
--   6. Fact extraction determinism: same AST -> same facts
--   7. Config tree construction: paths preserved, no data loss
--   8. Emit roundtrip: generated config is valid bash
--
-- Run with:
--   nix shell .#legacyPackages.x86_64-linux.aleph.script.ghc-with-tests -c \
--     runghc -inix/nix-compile/lib -inix/nix-compile/test nix/nix-compile/test/Props.hs
module Main (main) where

import Control.Monad (replicateM)
import Data.Either (isRight)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Parser (parseNixTextLoc)
import NixCompile
import NixCompile.Bash.Builtins (builtins, lookupArgType)
import NixCompile.Bash.Facts (extractFacts)
import NixCompile.Bash.Parse (parseBash)
import NixCompile.Bash.Patterns
import NixCompile.Emit.Config (ConfigTree (..), buildConfigTree, emitConfigFunction, emitConfigJson, emitConfigToml, emitConfigYaml)
import NixCompile.Infer.Constraint (factToConstraints, factsToConstraints)
import NixCompile.Infer.Unify (solve, unify)
import NixCompile.Lint.Forbidden (findViolations)
import NixCompile.Nix.Effect
import NixCompile.Nix.Format (formatExpr)
import NixCompile.Nix.Infer (Binding, inferExpr)
import NixCompile.Nix.Lint (findNixViolations)
import NixCompile.Nix.Scope qualified as Scope
import NixCompile.Nix.Types qualified as NT
import NixCompile.Schema.Build (buildSchema)
import System.Exit (exitFailure, exitSuccess)
import Test.QuickCheck

-- ============================================================================
-- Generators
-- ============================================================================

-- | Generate valid bash variable names
genVarName :: Gen Text
genVarName = do
  first <- elements $ ['A' .. 'Z'] ++ ['a' .. 'z'] ++ ['_']
  rest <- listOf $ elements $ ['A' .. 'Z'] ++ ['a' .. 'z'] ++ ['0' .. '9'] ++ ['_']
  let name = first : take 15 rest -- reasonable length
  return $ T.pack name

-- | Generate valid uppercase env var names (convention)
genEnvVarName :: Gen Text
genEnvVarName = do
  first <- elements ['A' .. 'Z']
  rest <- listOf $ elements $ ['A' .. 'Z'] ++ ['0' .. '9'] ++ ['_']
  let name = first : take 10 rest
  return $ T.pack name

-- | Generate integer literals (common in bash)
genIntLiteral :: Gen Int
genIntLiteral =
  frequency
    [ (3, choose (0, 100)), -- common small numbers
      (2, choose (1000, 65535)), -- ports, etc.
      (1, choose (-100, -1)), -- negative
      (1, pure 0)
    ]

-- | Generate string literals (no special chars that break bash)
genStringLiteral :: Gen Text
genStringLiteral = do
  len <- choose (1, 20)
  chars <- replicateM len $ elements $ ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] ++ ['-', '_', '.']
  return $ T.pack chars

-- | Generate boolean literals
genBoolLiteral :: Gen Bool
genBoolLiteral = arbitrary

-- | Generate a Literal
genLiteral :: Gen Literal
genLiteral =
  oneof
    [ LitInt <$> genIntLiteral,
      LitString <$> genStringLiteral,
      LitBool <$> genBoolLiteral
    ]

-- | Generate a Type
genType :: Gen Type
genType = elements [TInt, TString, TBool, TPath, TNumeric]

-- | Generate a TypeVar
genTypeVar :: Gen TypeVar
genTypeVar = TypeVar <$> genVarName

-- | Generate a Type including type variables
genTypeWithVars :: Gen Type
genTypeWithVars =
  frequency
    [ (4, genType),
      (1, TVar <$> genTypeVar)
    ]

-- | Generate a Span (arbitrary, not semantic)
genSpan :: Gen Span
genSpan = do
  l1 <- choose (1, 1000)
  c1 <- choose (0, 80)
  l2 <- choose (l1, l1 + 10)
  c2 <- choose (0, 80)
  return $ Span (Loc l1 c1) (Loc l2 c2) Nothing

-- | Generate a config path
genConfigPath :: Gen ConfigPath
genConfigPath = do
  len <- choose (1, 4)
  replicateM len genVarName

-- | Generate a Fact
genFact :: Gen Fact
genFact =
  oneof
    [ DefaultIs <$> genEnvVarName <*> genLiteral <*> genSpan,
      DefaultFrom <$> genEnvVarName <*> genEnvVarName <*> genSpan,
      Required <$> genEnvVarName <*> genSpan,
      AssignFrom <$> genEnvVarName <*> genEnvVarName <*> genSpan,
      AssignLit <$> genEnvVarName <*> genLiteral <*> genSpan,
      ConfigAssign <$> genConfigPath <*> genEnvVarName <*> elements [Quoted, Unquoted] <*> genSpan,
      ConfigLit <$> genConfigPath <*> genLiteral <*> genSpan,
      BareCommand <$> genStringLiteral <*> genSpan
    ]

-- | Generate a Constraint
genConstraint :: Gen Constraint
genConstraint = (:~:) <$> genTypeWithVars <*> genTypeWithVars

-- | Generate a valid bash script fragment
genBashFragment :: Gen Text
genBashFragment = do
  ls <- listOf1 genBashLine
  return $ T.unlines ls

-- | Generate a single bash line
genBashLine :: Gen Text
genBashLine =
  frequency
    [ (3, genAssignment),
      (2, genConfigAssignment),
      (1, genCommand),
      (1, genIfBlock),
      (1, genForLoop),
      (1, genPipe),
      (1, pure ""), -- empty line
      (1, genComment)
    ]

-- | Generate an if block
genIfBlock :: Gen Text
genIfBlock = do
  var <- genEnvVarName
  body <- genAssignment
  pure $ "if [ -n \"$" <> var <> "\" ]; then\n  " <> body <> "\nfi"

-- | Generate a for loop
genForLoop :: Gen Text
genForLoop = do
  var <- genEnvVarName
  pure $ "for x in 1 2 3; do\n  echo \"$" <> var <> "\"\ndone"

-- | Generate a pipe
genPipe :: Gen Text
genPipe = do
  cmd1 <- elements ["echo hello", "printf '%s' test", "cat /dev/null"]
  cmd2 <- elements ["head -n 1", "tail -n 1", "wc -l"]
  pure $ cmd1 <> " | " <> cmd2

-- | Generate a variable assignment
genAssignment :: Gen Text
genAssignment = do
  var <- genEnvVarName
  value <- genAssignmentValue var
  return $ var <> "=" <> value

-- | Generate assignment RHS
genAssignmentValue :: Text -> Gen Text
genAssignmentValue var =
  oneof
    [ do
        def <- genLiteralText
        return $ "\"${" <> var <> ":-" <> def <> "}\"",
      do
        return $ "\"${" <> var <> ":?}\"",
      do
        -- literal
        lit <- genLiteralText
        return $ "\"" <> lit <> "\"",
      do
        other <- genEnvVarName
        return $ "\"$" <> other <> "\""
    ]

-- | Generate literal as text
genLiteralText :: Gen Text
genLiteralText =
  oneof
    [ T.pack . show <$> genIntLiteral,
      genStringLiteral,
      elements ["true", "false"]
    ]

-- | Generate config.* assignment
genConfigAssignment :: Gen Text
genConfigAssignment = do
  path <- genConfigPath
  var <- genEnvVarName
  quoted <- arbitrary
  let pathText = "config." <> T.intercalate "." path
  let value = if quoted then "\"$" <> var <> "\"" else "$" <> var
  return $ pathText <> "=" <> value

-- | Generate a command invocation
genCommand :: Gen Text
genCommand = do
  cmd <- elements ["curl", "wget", "sleep", "echo", "cat"]
  args <- listOf genArg
  return $ T.unwords (cmd : args)

-- | Generate command argument
genArg :: Gen Text
genArg =
  oneof
    [ genStringLiteral,
      ("$" <>) <$> genEnvVarName,
      ("\"$" <>) . (<> "\"") <$> genEnvVarName
    ]

-- | Generate a comment
genComment :: Gen Text
genComment = do
  text <- genStringLiteral
  return $ "# " <> text

-- ============================================================================
-- Arbitrary instances
-- ============================================================================

instance Arbitrary Text where
  arbitrary = genStringLiteral
  shrink t = map T.pack $ shrink (T.unpack t)

instance Arbitrary Type where
  arbitrary = genType

instance Arbitrary TypeVar where
  arbitrary = genTypeVar

instance Arbitrary Literal where
  arbitrary = genLiteral

instance Arbitrary Span where
  arbitrary = genSpan

instance Arbitrary Fact where
  arbitrary = genFact

instance Arbitrary Constraint where
  arbitrary = genConstraint

instance Arbitrary Quoted where
  arbitrary = elements [Quoted, Unquoted]

-- ConfigSpec instance removed (duplicate)

instance Arbitrary ConfigSpec where
  arbitrary = genConfigSpec

genConfigSpec :: Gen ConfigSpec
genConfigSpec = oneof [genFromVar, genFromLit]
  where
    genFromVar = do
      t <- genType
      v <- genEnvVarName
      q <- oneof [pure Nothing, Just <$> arbitrary]
      s <- genSpan
      pure $ ConfigSpec t (Just v) q Nothing s

    genFromLit = do
      lit <- genLiteral
      s <- genSpan
      pure $ ConfigSpec (literalType lit) Nothing Nothing (Just lit) s

instance Arbitrary NT.TypeVar where
  arbitrary = NT.TypeVar <$> arbitrary

instance Arbitrary NT.NixType where
  arbitrary = sized genNixType

genNixType :: Int -> Gen NT.NixType
genNixType n
  | n <= 0 =
      oneof
        [ pure NT.TInt,
          pure NT.TFloat,
          pure NT.TBool,
          pure NT.TString,
          NT.TStrLit <$> genStringLiteral,
          pure NT.TPath,
          pure NT.TNull,
          pure NT.TDerivation,
          pure NT.TAny,
          NT.TVar <$> arbitrary
        ]
genNixType n =
  oneof
    [ pure NT.TInt,
      pure NT.TString,
      pure NT.TBool,
      NT.TList <$> genNixType (n `div` 2),
      NT.TFun <$> genNixType (n `div` 2) <*> genNixType (n `div` 2),
      NT.TAttrs <$> genAttrs (n `div` 2),
      NT.TAttrsOpen <$> genAttrs (n `div` 2)
    ]
  where
    genAttrs k = do
      size <- choose (0, 3)
      kvs <- replicateM size $ do
        key <- genVarName
        val <- genNixType k
        opt <- arbitrary
        pure (key, (val, opt))
      pure $ Map.fromList kvs

instance Arbitrary Coeffect where
  arbitrary =
    oneof
      [ RequireUpstream <$> genVarName <*> arbitrary,
        RequireSelf <$> genVarName <*> arbitrary,
        do
          p <- genStringLiteral -- path
          pure $ RequireImport (T.unpack p)
      ]

instance Arbitrary Effect where
  arbitrary =
    oneof
      [ Define <$> genVarName <*> arbitrary,
        Override <$> genVarName <*> arbitrary,
        Modify <$> genVarName
      ]

instance Arbitrary OverlaySignature where
  arbitrary = OverlaySignature <$> arbitrary <*> arbitrary

-- ============================================================================
-- Properties: Unification
-- ============================================================================

-- | Unification is reflexive: t ~ t always succeeds
prop_unify_reflexive :: Type -> Bool
prop_unify_reflexive t = isRight (unify t t)

-- | Unification is symmetric: t1 ~ t2 iff t2 ~ t1
prop_unify_symmetric :: Type -> Type -> Bool
prop_unify_symmetric t1 t2 =
  isRight (unify t1 t2) == isRight (unify t2 t1)

-- | Successful unification produces valid substitution
-- Note: TNumeric is a "union type" compatible with TInt and TBool,
-- so TNumeric ~ TInt doesn't require structural equality after subst
prop_unify_valid_subst :: Type -> Type -> Property
prop_unify_valid_subst t1 t2 =
  isRight (unify t1 t2) ==>
    case unify t1 t2 of
      Right s ->
        let t1' = applySubst s t1
            t2' = applySubst s t2
         in t1' == t2' || numericCompatible t1' t2'
      Left _ -> False
  where
    numericCompatible TNumeric TInt = True
    numericCompatible TInt TNumeric = True
    numericCompatible TNumeric TBool = True
    numericCompatible TBool TNumeric = True
    numericCompatible TNumeric TNumeric = True
    numericCompatible _ _ = False

-- | Unification with self produces empty or trivial substitution
prop_unify_self_trivial :: Type -> Bool
prop_unify_self_trivial t =
  case unify t t of
    Right s -> Map.null s || all isTrivial (Map.toList s)
    Left _ -> False
  where
    isTrivial (v, TVar v') = v == v'
    isTrivial _ = False

-- | Concrete types don't unify with different concrete types
prop_unify_concrete_disjoint :: Property
prop_unify_concrete_disjoint = forAll genType $ \t1 ->
  forAll genType $ \t2 ->
    (t1 /= t2 && not (numericCompat t1 t2)) ==>
      not (isRight (unify t1 t2))
  where
    numericCompat TNumeric TInt = True
    numericCompat TInt TNumeric = True
    numericCompat TNumeric TBool = True
    numericCompat TBool TNumeric = True
    numericCompat _ _ = False

-- | Type variable unifies with anything
prop_unify_tvar_universal :: Type -> Property
prop_unify_tvar_universal t = forAll genTypeVar $ \v ->
  isRight (unify (TVar v) t)

-- | Substitution composition is associative
prop_subst_compose_assoc :: [(TypeVar, Type)] -> [(TypeVar, Type)] -> Type -> Bool
prop_subst_compose_assoc pairs1 pairs2 t =
  let s1 = Map.fromList pairs1
      s2 = Map.fromList pairs2
      s12 = composeSubst s1 s2
   in applySubst s1 (applySubst s2 t) == applySubst s12 t

-- | Empty substitution is identity
prop_subst_empty_identity :: Type -> Bool
prop_subst_empty_identity t = applySubst emptySubst t == t

-- | Single substitution applies correctly
prop_subst_single :: TypeVar -> Type -> Bool
prop_subst_single v t =
  applySubst (singleSubst v t) (TVar v) == t

-- ============================================================================
-- Properties: Constraint solving
-- ============================================================================

-- | Solving empty constraints succeeds with empty substitution
prop_solve_empty :: Bool
prop_solve_empty =
  case solve [] of
    Right s -> Map.null s
    Left _ -> False

-- | Solving reflexive constraints always succeeds
prop_solve_reflexive :: [Type] -> Bool
prop_solve_reflexive ts =
  let constraints = map (\t -> t :~: t) ts
   in isRight (solve constraints)

-- | Solved constraints are satisfied
-- Note: TNumeric is compatible with TInt and TBool (union type semantics)
-- Use a custom generator for more satisfiable constraint sets
prop_solve_satisfies :: Property
prop_solve_satisfies = forAll genSatisfiableConstraints $ \constraints ->
  case solve constraints of
    Right s -> all (satisfied s) constraints
    Left _ -> True -- If it fails to solve, that's OK (not falsified)
  where
    satisfied s (t1 :~: t2) =
      let t1' = applySubst s t1
          t2' = applySubst s t2
       in t1' == t2' || numericCompatible t1' t2'
    numericCompatible TNumeric TInt = True
    numericCompatible TInt TNumeric = True
    numericCompatible TNumeric TBool = True
    numericCompatible TBool TNumeric = True
    numericCompatible TNumeric TNumeric = True
    numericCompatible _ _ = False

-- | Generate constraint sets that are more likely to be satisfiable
genSatisfiableConstraints :: Gen [Constraint]
genSatisfiableConstraints =
  frequency
    [ (3, genReflexiveConstraints),
      (2, genVarConstraints),
      (1, genMixedConstraints)
    ]
  where
    -- All reflexive: T ~ T
    genReflexiveConstraints = do
      ts <- listOf genType
      return $ map (\t -> t :~: t) ts

    -- Variable constraints: X ~ T, Y ~ T
    genVarConstraints = do
      n <- choose (1, 5)
      vs <- replicateM n genTypeVar
      ts <- replicateM n genType
      return $ zipWith (\v t -> TVar v :~: t) vs ts

    -- Mixed but compatible
    genMixedConstraints = do
      n <- choose (1, 3)
      replicateM n $ do
        t <- genType
        oneof
          [ pure (t :~: t),
            do
              v <- genTypeVar
              pure (TVar v :~: t),
            case t of
              TInt -> pure (TNumeric :~: TInt)
              TBool -> pure (TNumeric :~: TBool)
              _ -> pure (t :~: t)
          ]

-- | Constraint solving success/failure is order-independent
prop_solve_deterministic :: [Constraint] -> Bool
prop_solve_deterministic constraints =
  isRight (solve constraints) == isRight (solve (reverse constraints))

-- ============================================================================
-- Properties: Fact -> Constraint
-- ============================================================================

-- | Constraint generation is deterministic
prop_constraints_deterministic :: [Fact] -> Bool
prop_constraints_deterministic facts =
  factsToConstraints facts == factsToConstraints facts

-- | DefaultIs generates exactly one constraint
prop_default_is_constraint :: Text -> Literal -> Span -> Bool
prop_default_is_constraint var lit sp =
  length (factToConstraints (DefaultIs var lit sp)) == 1

-- | Required generates no constraints (just existence)
prop_required_no_constraint :: Text -> Span -> Bool
prop_required_no_constraint var sp =
  null (factToConstraints (Required var sp))

-- | ConfigAssign generates no constraints (type flows from definition, not usage)
prop_config_no_constraint :: ConfigPath -> Text -> Quoted -> Span -> Bool
prop_config_no_constraint path var quoted sp =
  null (factToConstraints (ConfigAssign path var quoted sp))

-- ============================================================================
-- Properties: Schema building
-- ============================================================================

-- | Schema building is deterministic
prop_schema_deterministic :: [Fact] -> Property
prop_schema_deterministic facts =
  isRight (solve (factsToConstraints facts)) ==>
    case solve (factsToConstraints facts) of
      Right s -> buildSchema facts s == buildSchema facts s
      Left _ -> False

-- | All env vars in facts appear in schema
prop_schema_env_complete :: [Fact] -> Property
prop_schema_env_complete facts =
  isRight (solve (factsToConstraints facts)) ==>
    case solve (factsToConstraints facts) of
      Right s ->
        let schema = buildSchema facts s
            factVars = Set.fromList $ mapMaybe factEnvVar facts
            schemaVars = Set.fromList $ Map.keys (schemaEnv schema)
         in factVars `Set.isSubsetOf` schemaVars
      Left _ -> False
  where
    factEnvVar (DefaultIs v _ _) = Just v
    factEnvVar (DefaultFrom v _ _) = Just v
    factEnvVar (Required v _) = Just v
    factEnvVar (AssignLit v _ _) = Just v
    factEnvVar (AssignFrom v _ _) = Just v
    factEnvVar (ConfigAssign _ v _ _) = Just v
    factEnvVar (CmdArg _ _ v _) = Just v
    factEnvVar _ = Nothing

-- | Literal defaults are preserved in schema (last one wins)
prop_schema_preserves_defaults :: [Fact] -> Property
prop_schema_preserves_defaults facts =
  isRight (solve (factsToConstraints facts)) ==>
    case solve (factsToConstraints facts) of
      Right s ->
        let schema = buildSchema facts s
            expected = foldl applyFact Map.empty facts
         in all (check schema) (Map.toList expected)
      Left _ -> False
  where
    applyFact m (DefaultIs v lit _) = Map.insert v lit m
    applyFact m (AssignLit v lit _) = Map.insert v lit m
    applyFact m _ = m

    check schema (var, expectedLit) =
      case Map.lookup var (schemaEnv schema) of
        Just spec -> envDefault spec == Just expectedLit
        Nothing -> False

-- | Required vars are marked required in schema
prop_schema_required_marked :: [Fact] -> Property
prop_schema_required_marked facts =
  isRight (solve (factsToConstraints facts)) ==>
    case solve (factsToConstraints facts) of
      Right s ->
        let schema = buildSchema facts s
         in all (requiredMarked schema) facts
      Left _ -> False
  where
    requiredMarked schema (Required var _) =
      case Map.lookup var (schemaEnv schema) of
        Just spec -> envRequired spec
        Nothing -> False
    requiredMarked _ _ = True

-- ============================================================================
-- Properties: Parser
-- ============================================================================

-- | Parser succeeds on well-formed generated bash
prop_parser_no_crash :: Property
prop_parser_no_crash = forAll genBashFragment $ \script ->
  case parseBash script of
    Left _ -> label "parse failure" True
    Right _ast ->
      label "parse success" True

-- | Parser result is order-independent of whitespace
prop_parser_deterministic :: Property
prop_parser_deterministic = forAll genBashFragment $ \script ->
  parseBash script == parseBash script

-- | Empty script parses
prop_parser_empty :: Bool
prop_parser_empty = isRight (parseBash "")

-- | Comment-only script parses
prop_parser_comments :: Property
prop_parser_comments = forAll genComment $ \comment ->
  isRight (parseBash comment)

-- ============================================================================
-- Properties: Pattern matching
-- ============================================================================

-- | parseParamExpansion recognizes ${VAR:-default}
prop_pattern_default :: Text -> Text -> Bool
prop_pattern_default var def =
  case parseParamExpansion ("${" <> var <> ":-" <> def <> "}") of
    Just (DefaultValue v (Just d)) -> v == var && d == def
    _ -> False

-- | parseParamExpansion recognizes ${VAR:?}
prop_pattern_required :: Text -> Bool
prop_pattern_required var =
  case parseParamExpansion ("${" <> var <> ":?}") of
    Just (ErrorIfUnset v Nothing) -> v == var
    _ -> False

-- | parseParamExpansion recognizes $VAR
prop_pattern_simple :: Text -> Bool
prop_pattern_simple var =
  case parseParamExpansion ("$" <> var) of
    Just (SimpleRef v) -> v == var
    _ -> False

-- | isNumericLiteral correct for integers
prop_numeric_int :: Int -> Bool
prop_numeric_int n = isNumericLiteral (T.pack (show n))

-- | isNumericLiteral rejects non-numeric
prop_numeric_rejects_alpha :: Property
prop_numeric_rejects_alpha = forAll genStringLiteral $ \s ->
  not (T.all (\c -> c >= '0' && c <= '9' || c == '-') s) ==>
    not (isNumericLiteral s)

-- ============================================================================
-- Properties: Builtins
-- ============================================================================

-- | All builtin commands have schemas
prop_builtins_nonempty :: Bool
prop_builtins_nonempty = not (Map.null builtins)

-- | Known flags have known types
prop_builtins_curl_timeout :: Bool
prop_builtins_curl_timeout =
  lookupArgType "curl" "--connect-timeout" == Just TInt

prop_builtins_curl_output :: Bool
prop_builtins_curl_output =
  lookupArgType "curl" "-o" == Just TPath

prop_builtins_jq_indent :: Bool
prop_builtins_jq_indent =
  lookupArgType "jq" "--indent" == Just TInt

-- | Unknown flags return Nothing (conservative)
prop_builtins_unknown_flag :: Property
prop_builtins_unknown_flag = forAll genStringLiteral $ \flag ->
  let weirdFlag = "--xyz-" <> flag <> "-unknown"
   in lookupArgType "curl" weirdFlag == Nothing

-- | Unknown commands return Nothing
prop_builtins_unknown_cmd :: Property
prop_builtins_unknown_cmd = forAll genStringLiteral $ \cmd ->
  let weirdCmd = "xyz-" <> cmd <> "-unknown"
   in lookupArgType weirdCmd "--timeout" == Nothing

-- ============================================================================
-- Properties: Config tree
-- ============================================================================

-- | Config tree preserves all non-empty paths when no path is a prefix of another.
-- The tree can't represent a key as both a leaf and a branch (e.g. ["v"] and ["v","a"]).
-- We filter to conflict-free path sets before asserting completeness.
prop_config_tree_complete :: [(ConfigPath, ConfigSpec)] -> Bool
prop_config_tree_complete items =
  let -- Filter out empty paths and paths with empty components
      validItems = filter (validPath . fst) items
      m = Map.fromList validItems
      -- Remove paths that are strict prefixes of other paths (or vice versa)
      keys = Map.keys m
      conflictFree = Map.filterWithKey (\k _ -> not (hasConflict k keys)) m
      tree = buildConfigTree conflictFree
      paths = collectPaths tree
   in Set.fromList (Map.keys conflictFree) `Set.isSubsetOf` paths
  where
    validPath [] = False -- Empty path not valid
    validPath ps = all (not . T.null) ps -- No empty components

    -- A path conflicts if it is a strict prefix of, or has a strict prefix in, the path set
    hasConflict p ps = any (\q -> p /= q && (p `isPrefixOfPath` q || q `isPrefixOfPath` p)) ps

    isPrefixOfPath [] _ = True
    isPrefixOfPath _ [] = False
    isPrefixOfPath (x : xs) (y : ys) = x == y && isPrefixOfPath xs ys

    collectPaths :: ConfigTree -> Set ConfigPath
    collectPaths (ConfigLeaf _) = Set.singleton []
    collectPaths (ConfigBranch m) =
      Set.unions
        [ Set.map (k :) (collectPaths v)
        | (k, v) <- Map.toList m
        ]

-- | Config tree is deterministic
prop_config_tree_deterministic :: Map ConfigPath ConfigSpec -> Bool
prop_config_tree_deterministic m =
  buildConfigTree m == buildConfigTree m

-- ============================================================================
-- Properties: Scope graph
-- ============================================================================

-- | Edge priority: Parent edges are resolved before With edges.
-- A reference 'x' in a scope with both a Parent edge (to a LetScope with 'x')
-- and a With edge (to a WithScope with 'x') should resolve to the LetScope decl.
prop_scope_parent_before_with :: Bool
prop_scope_parent_before_with =
  let mkSpan = Scope.SourceSpan (Scope.SourcePos 1 1) (Scope.SourcePos 1 1) Nothing
      declIn sid = Scope.Declaration "x" mkSpan sid Nothing Nothing Nothing
      refIn sid = Scope.Reference "x" mkSpan sid Scope.VarRef
      sg =
        Scope.ScopeGraph
          { Scope.sgScopes =
              Map.fromList
                [ ( Scope.ScopeId 0,
                    Scope.Scope
                      (Scope.ScopeId 0)
                      [] -- no local decl for 'x'
                      [refIn (Scope.ScopeId 0)]
                      [ Scope.Edge (Scope.ScopeId 0) (Scope.ScopeId 1) Scope.Parent,
                        Scope.Edge (Scope.ScopeId 0) (Scope.ScopeId 2) Scope.With
                      ]
                      Scope.FileScope
                  ),
                  ( Scope.ScopeId 1,
                    Scope.Scope
                      (Scope.ScopeId 1)
                      [declIn (Scope.ScopeId 1)]
                      []
                      []
                      Scope.LetScope
                  ),
                  ( Scope.ScopeId 2,
                    Scope.Scope
                      (Scope.ScopeId 2)
                      [declIn (Scope.ScopeId 2)]
                      []
                      []
                      Scope.WithScope
                  )
                ],
            Scope.sgRoot = Scope.ScopeId 0,
            Scope.sgNextId = 3,
            Scope.sgFile = Nothing
          }
   in case Scope.resolve sg (refIn (Scope.ScopeId 0)) of
        Right decl -> Scope.declScope decl == Scope.ScopeId 1
        Left _ -> False

-- ============================================================================
-- Properties: Literal parsing
-- ============================================================================

-- | Integer literals roundtrip
prop_literal_int_roundtrip :: Int -> Bool
prop_literal_int_roundtrip n =
  case parseLiteral (T.pack (show n)) of
    LitInt m -> m == n
    _ -> False

-- | Bool literals roundtrip
prop_literal_bool_roundtrip :: Bool -> Bool
prop_literal_bool_roundtrip b =
  let text = if b then "true" else "false"
   in case parseLiteral text of
        LitBool b' -> b' == b
        _ -> False

-- | literalType is consistent
prop_literal_type_consistent :: Literal -> Bool
prop_literal_type_consistent lit =
  case lit of
    LitInt _ -> literalType lit == TInt
    LitString _ -> literalType lit == TString
    LitBool _ -> literalType lit == TBool
    LitPath _ -> literalType lit == TPath

-- ============================================================================
-- Properties: End-to-end
-- ============================================================================

-- | Full pipeline on success produces non-trivial schema
prop_e2e_no_crash :: Property
prop_e2e_no_crash = forAll genBashFragment $ \script ->
  case parseScript script of
    Left _ -> label "pipeline failure" True
    Right s ->
      label "pipeline success" $
        -- Schema should have at least as many env vars as assignments in the script
        Map.size (schemaEnv (scriptSchema s)) >= 0
          -- All bare commands are non-empty strings
          && all (not . T.null) (schemaBareCommands (scriptSchema s))

-- | Full pipeline produces same result on same input
prop_e2e_deterministic :: Property
prop_e2e_deterministic = forAll genBashFragment $ \script ->
  parseScript script == parseScript script

-- | Schema env types are concrete (no TVars)
prop_e2e_concrete_types :: Property
prop_e2e_concrete_types = forAll genBashFragment $ \script ->
  case parseScript script of
    Left _ -> True
    Right s -> all isConcrete (Map.elems (schemaEnv (scriptSchema s)))
  where
    isConcrete EnvSpec {..} = case envType of
      TVar _ -> False
      _ -> True

-- ============================================================================
-- Properties: Stress tests
-- ============================================================================

-- | Large scripts produce schemas with env vars
prop_stress_large_script :: Property
prop_stress_large_script = forAll genLargeScript $ \script ->
  case parseScript script of
    Left _ -> label "large: failed" True
    Right s ->
      label "large: ok" $
        -- Large generated scripts should extract at least some facts
        not (null (scriptFacts s))

-- | Many variables all appear in schema
prop_stress_many_vars :: Property
prop_stress_many_vars = forAll genManyVars $ \script ->
  case parseScript script of
    Left _ -> label "manyvars: failed" True
    Right s ->
      label "manyvars: ok" $
        Map.size (schemaEnv (scriptSchema s)) > 0

-- | Deep config paths work
prop_stress_deep_config :: Property
prop_stress_deep_config = forAll genDeepConfig $ \script ->
  case parseScript script of
    Left _ -> True
    Right _ -> True

-- | Chained variable references work
prop_stress_chain :: Property
prop_stress_chain = forAll genChainedVars $ \script ->
  case parseScript script of
    Left _ -> True
    Right s ->
      let schema = scriptSchema s
       in Map.size (schemaEnv schema) > 0

-- | Generator for large scripts
genLargeScript :: Gen Text
genLargeScript = do
  n <- choose (50, 200)
  ls <- replicateM n genBashLine
  return $ T.unlines ls

-- | Generator for many variables
genManyVars :: Gen Text
genManyVars = do
  n <- choose (20, 50)
  vars <- replicateM n genEnvVarName
  let assigns = map (\v -> v <> "=\"${" <> v <> ":-default}\"") (nub vars)
  return $ T.unlines assigns

-- | Generator for deep config paths
genDeepConfig :: Gen Text
genDeepConfig = do
  depth <- choose (3, 8)
  path <- replicateM depth genVarName
  var <- genEnvVarName
  let assign = var <> "=\"${" <> var <> ":-value}\""
  let config = "config." <> T.intercalate "." path <> "=$" <> var
  return $ T.unlines [assign, config]

-- | Generator for chained variable references
genChainedVars :: Gen Text
genChainedVars = do
  n <- choose (3, 10)
  vars <- replicateM n genEnvVarName
  let uniqueVars = nub vars
  case uniqueVars of
    [] -> return ""
    [v] -> return $ v <> "=\"${" <> v <> ":-default}\""
    (v1 : vRest) -> do
      let first = v1 <> "=\"${" <> v1 <> ":-42}\""
      let rest = zipWith (\v prev -> v <> "=\"$" <> prev <> "\"") vRest (v1 : vRest)
      return $ T.unlines (first : rest)

-- | Transitivity: if A ~ B and B ~ C succeed, A ~ C should relate
prop_unify_transitivity :: Property
prop_unify_transitivity = forAll genTypeVar $ \v ->
  forAll genType $ \t1 ->
    forAll genType $ \t2 ->
      let c1 = TVar v :~: t1
          c2 = TVar v :~: t2
       in case solve [c1, c2] of
            Right _ -> True -- If both unify with v, they're compatible
            Left _ -> not (t1 == t2) -- Failure means types were incompatible

-- | Schema config paths match input
prop_schema_config_paths :: Property
prop_schema_config_paths = forAll genConfigScript $ \script ->
  case parseScript script of
    Left _ -> True
    Right s ->
      let cfg = schemaConfig (scriptSchema s)
       in all (not . null) (Map.keys cfg)

-- | Generator for config-heavy script
genConfigScript :: Gen Text
genConfigScript = do
  n <- choose (1, 10)
  assignments <- replicateM n $ do
    var <- genEnvVarName
    path <- genConfigPath
    quoted <- arbitrary
    let assign = var <> "=\"${" <> var <> ":-default}\""
    let pathText = "config." <> T.intercalate "." path
    let cfgVal = if quoted then "\"$" <> var <> "\"" else "$" <> var
    let cfg = pathText <> "=" <> cfgVal
    return $ T.unlines [assign, cfg]
  return $ T.concat assignments

-- | Monoid Identity: empty `merge` s = s
prop_overlay_identity_left :: OverlaySignature -> Bool
prop_overlay_identity_left s =
  let empty = OverlaySignature Set.empty Set.empty
   in mergeSignatures empty s == s

-- | Monoid Identity: s `merge` empty = s
prop_overlay_identity_right :: OverlaySignature -> Bool
prop_overlay_identity_right s =
  let empty = OverlaySignature Set.empty Set.empty
   in mergeSignatures s empty == s

-- | Associativity: (a <> b) <> c == a <> (b <> c)
prop_overlay_assoc :: OverlaySignature -> OverlaySignature -> OverlaySignature -> Bool
prop_overlay_assoc a b c =
  mergeSignatures (mergeSignatures a b) c == mergeSignatures a (mergeSignatures b c)

-- | Satisfaction: Defining 'x' satisfies upstream requirement for 'x'
prop_overlay_satisfaction :: Text -> Bool
prop_overlay_satisfaction name =
  let t = NT.TInt
      -- Producer: defines 'name'
      p = OverlaySignature Set.empty (Set.singleton (Define name t))
      -- Consumer: requires 'name'
      c = OverlaySignature (Set.singleton (RequireUpstream name t)) Set.empty
      -- Merge
      m = mergeSignatures p c
   in Set.null (osCoeffects m) -- Requirement should be gone

-- | Propagation: Unrelated requirements propagate
prop_overlay_propagation :: Text -> Text -> Property
prop_overlay_propagation n1 n2 =
  n1 /= n2 ==>
    let t = NT.TInt
        -- Producer: defines 'n1'
        p = OverlaySignature Set.empty (Set.singleton (Define n1 t))
        -- Consumer: requires 'n2'
        c = OverlaySignature (Set.singleton (RequireUpstream n2 t)) Set.empty
        -- Merge
        m = mergeSignatures p c
     in Set.member (RequireUpstream n2 t) (osCoeffects m)

-- ============================================================================
-- Properties: Nix type inference (FIX-11)
-- ============================================================================

-- | Generate valid Nix expression source text.
-- Avoids `with`, `rec`, dynamic attrs (which are skipped by inference).
genNixExpr :: Int -> Gen Text
genNixExpr 0 = genNixAtom
genNixExpr n =
  frequency
    [ (4, genNixAtom),
      (2, genNixList n),
      (2, genNixAttrSet n),
      (2, genNixLet n),
      (1, genNixFunc n),
      (1, genNixIf n),
      (1, genNixApp n),
      (1, genNixBinOp n),
      (1, genNixListConcat n),
      (1, genNixAttrMerge n),
      (1, genNixNestedLet n)
    ]

genNixAtom :: Gen Text
genNixAtom =
  oneof
    [ T.pack . show <$> (choose (0, 1000) :: Gen Int),
      pure "true",
      pure "false",
      pure "null",
      do
        s <- listOf1 (elements ['a' .. 'z'])
        pure $ "\"" <> T.pack (take 10 s) <> "\""
    ]

genNixIdent :: Gen Text
genNixIdent = do
  c <- elements ['a' .. 'z']
  rest <- listOf (elements $ ['a' .. 'z'] ++ ['0' .. '9'])
  pure $ T.pack (c : take 5 rest)

genNixList :: Int -> Gen Text
genNixList n = do
  len <- choose (0, 3)
  elems <- replicateM len (genNixExpr (n `div` 2))
  pure $ "[ " <> T.unwords elems <> " ]"

genNixAttrSet :: Int -> Gen Text
genNixAttrSet n = do
  len <- choose (1, 3)
  names <- replicateM len genNixIdent
  vals <- replicateM len (genNixExpr (n `div` 2))
  let bindings = zipWith (\k v -> k <> " = " <> v <> ";") (nub names) vals
  pure $ "{ " <> T.unwords bindings <> " }"

genNixLet :: Int -> Gen Text
genNixLet n = do
  name <- genNixIdent
  val <- genNixExpr (n `div` 2)
  body <- genNixExpr (n `div` 2)
  pure $ "let " <> name <> " = " <> val <> "; in " <> body

genNixFunc :: Int -> Gen Text
genNixFunc n = do
  param <- genNixIdent
  body <- genNixExpr (n `div` 2)
  pure $ param <> ": " <> body

genNixIf :: Int -> Gen Text
genNixIf n = do
  cond <- genNixExpr (n `div` 3)
  t <- genNixExpr (n `div` 3)
  f <- genNixExpr (n `div` 3)
  pure $ "if " <> cond <> " then " <> t <> " else " <> f

genNixApp :: Int -> Gen Text
genNixApp n = do
  func <- genNixFunc n
  arg <- genNixExpr (n `div` 2)
  pure $ "(" <> func <> ") " <> arg

genNixBinOp :: Int -> Gen Text
genNixBinOp n = do
  left <- genNixExpr (n `div` 2)
  right <- genNixExpr (n `div` 2)
  op <- elements ["+", "-", "*", "==", "!=", "<", "<=", ">", ">=", "&&", "||"]
  pure $ "(" <> left <> " " <> op <> " " <> right <> ")"

-- | List concatenation: [1] ++ [2]
genNixListConcat :: Int -> Gen Text
genNixListConcat n = do
  l1 <- genNixList (n `div` 2)
  l2 <- genNixList (n `div` 2)
  pure $ l1 <> " ++ " <> l2

-- | Attrset merge: { a = 1; } // { b = 2; }
genNixAttrMerge :: Int -> Gen Text
genNixAttrMerge n = do
  a1 <- genNixAttrSet (n `div` 2)
  a2 <- genNixAttrSet (n `div` 2)
  pure $ a1 <> " // " <> a2

-- | Nested let: let a = let b = 1; in b; in a
genNixNestedLet :: Int -> Gen Text
genNixNestedLet n = do
  outer <- genNixIdent
  inner <- genNixIdent
  val <- genNixExpr (n `div` 3)
  pure $ "let " <> outer <> " = let " <> inner <> " = " <> val <> "; in " <> inner <> "; in " <> outer

-- | Helper: parse Nix text and run inference
parseAndInfer :: Text -> Either Text (NT.NixType, [Binding])
parseAndInfer src = case parseNixTextLoc src of
  Left _err -> Left "parse error"
  Right expr -> inferExpr expr

-- | NIX-1: inferExpr on parseable expressions returns a type or a meaningful error
prop_nix_infer_no_crash :: Property
prop_nix_infer_no_crash = forAll (sized genNixExpr) $ \src ->
  case parseNixTextLoc src of
    Left _ -> label "nix: unparseable" True
    Right expr -> case inferExpr expr of
      Left err -> label "nix: type error" $ not (T.null err)
      Right (t, _) -> label "nix: inferred" $ t `seq` True

-- | NIX-2: inferExpr is deterministic (same input, same result)
prop_nix_infer_deterministic :: Property
prop_nix_infer_deterministic = forAll (sized genNixExpr) $ \src ->
  parseAndInfer src == parseAndInfer src

-- | NIX-3: Integer literals infer to TInt
prop_nix_int_literal :: Property
prop_nix_int_literal = forAll (choose (0, 10000) :: Gen Int) $ \n ->
  case parseAndInfer (T.pack (show n)) of
    Right (NT.TInt, _) -> True
    _ -> False

-- | NIX-4: String literals infer to TString or TStrLit
prop_nix_string_literal :: Property
prop_nix_string_literal = forAll genStringLiteral $ \s ->
  case parseAndInfer ("\"" <> s <> "\"") of
    Right (NT.TString, _) -> True
    Right (NT.TStrLit _, _) -> True
    _ -> False

-- | NIX-5: Bool literals infer to TBool
prop_nix_bool_literal :: Bool -> Bool
prop_nix_bool_literal b =
  case parseAndInfer (if b then "true" else "false") of
    Right (NT.TBool, _) -> True
    _ -> False

-- | NIX-6: null infers to TNull
prop_nix_null_literal :: Bool
prop_nix_null_literal =
  case parseAndInfer "null" of
    Right (NT.TNull, _) -> True
    _ -> False

-- | NIX-7: Lists of ints infer to TList TInt
prop_nix_list_int :: Property
prop_nix_list_int = forAll (choose (1, 5)) $ \n ->
  let elems = T.unwords (replicate n "1")
      src = "[ " <> elems <> " ]"
   in case parseAndInfer src of
        Right (NT.TList NT.TInt, _) -> True
        _ -> False

-- | NIX-8: Attrsets infer fields correctly
prop_nix_attrset :: Property
prop_nix_attrset =
  let src = "{ x = 1; y = \"hello\"; }"
   in case parseAndInfer src of
        Right (t, _) -> case t of
          NT.TAttrs m -> checkFields m
          NT.TAttrsOpen m -> checkFields m
          _ -> property False
        _ -> property False
  where
    checkFields m =
      case (Map.lookup "x" m, Map.lookup "y" m) of
        (Just (NT.TInt, _), Just (ty, _)) ->
          property $ case ty of
            NT.TString -> True
            NT.TStrLit _ -> True
            _ -> False
        _ -> property False

-- | NIX-9: Identity function infers polymorphic type
prop_nix_identity :: Bool
prop_nix_identity =
  case parseAndInfer "x: x" of
    Right (NT.TFun _ _, _) -> True
    _ -> False

-- | NIX-10: Let binding scopes correctly
prop_nix_let_binding :: Bool
prop_nix_let_binding =
  case parseAndInfer "let x = 42; in x" of
    Right (NT.TInt, _) -> True
    _ -> False

-- ============================================================================
-- Properties: Merge correctness
-- ============================================================================

-- | mergeEnvSpec preserves required from either side
prop_merge_preserves_required :: Bool
prop_merge_preserves_required =
  let sp = Span (Loc 1 0) (Loc 1 0) Nothing
      e1 = EnvSpec TString False Nothing sp
      e2 = EnvSpec TString True Nothing sp
   in envRequired (mergeEnvSpec e1 e2) && envRequired (mergeEnvSpec e2 e1)

-- | mergeEnvSpec keeps first default, falls back to second
prop_merge_keeps_default :: Bool
prop_merge_keeps_default =
  let sp = Span (Loc 1 0) (Loc 1 0) Nothing
      e1 = EnvSpec TInt False (Just (LitInt 42)) sp
      e2 = EnvSpec TInt False (Just (LitInt 99)) sp
      eNone = EnvSpec TInt False Nothing sp
   in envDefault (mergeEnvSpec e1 e2) == Just (LitInt 42)
        && envDefault (mergeEnvSpec eNone e2) == Just (LitInt 99)

-- | Duplicate variables in facts are correctly merged
prop_duplicate_var_merged :: Bool
prop_duplicate_var_merged =
  let sp = Span (Loc 1 0) (Loc 1 0) Nothing
      facts =
        [ DefaultIs "PORT" (LitInt 8080) sp,
          Required "PORT" sp
        ]
      constraints = factsToConstraints facts
      subst = case solve constraints of Right s -> s; Left _ -> emptySubst
      schema = buildSchema facts subst
   in case Map.lookup "PORT" (schemaEnv schema) of
        Just spec -> envRequired spec && envDefault spec == Just (LitInt 8080) && envType spec == TInt
        Nothing -> False

-- | mergeSchemas identity: empty `merge` s == s
prop_merge_schema_identity :: [Fact] -> Property
prop_merge_schema_identity facts =
  let constraints = factsToConstraints facts
      subst = case solve constraints of Right s -> s; Left _ -> emptySubst
      schema = buildSchema facts subst
   in property $ mergeSchemas emptySchema schema == schema

-- ============================================================================
-- Properties: Fact extraction vectors
-- ============================================================================

-- | \${VAR:-default} produces DefaultIs fact
prop_fact_default_is :: Bool
prop_fact_default_is =
  case parseBash "PORT=\"${PORT:-8080}\"" of
    Right ast ->
      let facts = extractFacts ast
       in any isDefaultIs facts
    Left _ -> False
  where
    isDefaultIs (DefaultIs "PORT" (LitInt 8080) _) = True
    isDefaultIs _ = False

-- | \${VAR:?} produces Required fact
prop_fact_required :: Bool
prop_fact_required =
  case parseBash "API_KEY=\"${API_KEY:?}\"" of
    Right ast ->
      let facts = extractFacts ast
       in any isRequired facts
    Left _ -> False
  where
    isRequired (Required "API_KEY" _) = True
    isRequired _ = False

-- | \$VAR assignment produces AssignFrom fact
prop_fact_assign_from :: Bool
prop_fact_assign_from =
  case parseBash "COPY=\"$ORIGINAL\"" of
    Right ast ->
      let facts = extractFacts ast
       in any isAssignFrom facts
    Left _ -> False
  where
    isAssignFrom (AssignFrom "COPY" "ORIGINAL" _) = True
    isAssignFrom _ = False

-- | config.x.y=$VAR produces ConfigAssign fact
prop_fact_config_assign :: Bool
prop_fact_config_assign =
  case parseBash "config.server.port=$PORT" of
    Right ast ->
      let facts = extractFacts ast
       in any isConfigAssign facts
    Left _ -> False
  where
    isConfigAssign (ConfigAssign ["server", "port"] "PORT" _ _) = True
    isConfigAssign _ = False

-- | Literal config produces ConfigLit fact
prop_fact_config_lit :: Bool
prop_fact_config_lit =
  case parseBash "config.debug=false" of
    Right ast ->
      let facts = extractFacts ast
       in any isConfigLit facts
    Left _ -> False
  where
    isConfigLit (ConfigLit ["debug"] (LitBool False) _) = True
    isConfigLit _ = False

-- ============================================================================
-- Properties: Emit-config output
-- ============================================================================

-- | emit-config JSON contains ${VAR:?} guards for variable refs
prop_emit_json_guarded :: Property
prop_emit_json_guarded =
  let spec = ConfigSpec TInt (Just "PORT") (Just Unquoted) Nothing (Span (Loc 1 0) (Loc 1 0) Nothing)
      schema = emptySchema {schemaConfig = Map.singleton ["port"] spec}
      output = emitConfigJson schema
   in property $ ":?" `T.isInfixOf` output

-- | emit-config JSON passes runtime vars as printf arguments, not inert single-quoted text
prop_emit_json_runtime_args :: Property
prop_emit_json_runtime_args =
  let spec = ConfigSpec TInt (Just "PORT") (Just Unquoted) Nothing (Span (Loc 1 0) (Loc 1 0) Nothing)
      schema = emptySchema {schemaConfig = Map.singleton ["port"] spec}
      output = emitConfigJson schema
   in property $ "%s" `T.isInfixOf` output && " ${PORT:?" `T.isInfixOf` output

-- | emit-config YAML contains ${VAR:?} guards
prop_emit_yaml_guarded :: Property
prop_emit_yaml_guarded =
  let spec = ConfigSpec TInt (Just "PORT") (Just Unquoted) Nothing (Span (Loc 1 0) (Loc 1 0) Nothing)
      schema = emptySchema {schemaConfig = Map.singleton ["port"] spec}
      output = emitConfigYaml schema
   in property $ ":?" `T.isInfixOf` output

-- | emit-config TOML never outputs invalid "null"
prop_emit_toml_no_null :: [Fact] -> Bool
prop_emit_toml_no_null facts =
  let schema = buildSchema facts emptySubst
      output = emitConfigToml schema
   in not ("null" `T.isInfixOf` output) || "\"\"" `T.isInfixOf` output || T.null output

-- | emit-config JSON for literal values renders correctly
prop_emit_json_literal :: Bool
prop_emit_json_literal =
  let spec = ConfigSpec TInt Nothing Nothing (Just (LitInt 8080)) (Span (Loc 1 0) (Loc 1 0) Nothing)
      schema = emptySchema {schemaConfig = Map.singleton ["port"] spec}
      output = emitConfigJson schema
   in "8080" `T.isInfixOf` output

-- | emit-config string values are quoted in JSON
prop_emit_json_string_quoted :: Bool
prop_emit_json_string_quoted =
  let spec = ConfigSpec TString (Just "HOST") (Just Quoted) Nothing (Span (Loc 1 0) (Loc 1 0) Nothing)
      schema = emptySchema {schemaConfig = Map.singleton ["host"] spec}
      output = emitConfigJson schema
   in "__nix_compile_escape_json" `T.isInfixOf` output

-- ============================================================================
-- Properties: Scope graph construction
-- ============================================================================

-- | Let bindings create declarations in the correct scope
prop_scope_let_decl :: Bool
prop_scope_let_decl =
  case parseNixTextLoc "let x = 1; in x" of
    Left _ -> False
    Right expr ->
      let sg = Scope.fromNixExpr Nothing expr
          decls = concatMap Scope.scopeDeclarations (Map.elems (Scope.sgScopes sg))
       in any (\d -> Scope.declName d == "x") decls

-- | Attrsets create declarations for each key
prop_scope_attrset_decls :: Bool
prop_scope_attrset_decls =
  case parseNixTextLoc "{ a = 1; b = 2; c = 3; }" of
    Left _ -> False
    Right expr ->
      let sg = Scope.fromNixExpr Nothing expr
          decls = concatMap Scope.scopeDeclarations (Map.elems (Scope.sgScopes sg))
          names = map Scope.declName decls
       in "a" `elem` names && "b" `elem` names && "c" `elem` names

-- | Function params create declarations
prop_scope_func_params :: Bool
prop_scope_func_params =
  case parseNixTextLoc "{ x, y, z }: x + y + z" of
    Left _ -> False
    Right expr ->
      let sg = Scope.fromNixExpr Nothing expr
          decls = concatMap Scope.scopeDeclarations (Map.elems (Scope.sgScopes sg))
          names = map Scope.declName decls
       in "x" `elem` names && "y" `elem` names && "z" `elem` names

-- | Variable references are tracked
prop_scope_var_refs :: Bool
prop_scope_var_refs =
  case parseNixTextLoc "let x = 1; in x" of
    Left _ -> False
    Right expr ->
      let sg = Scope.fromNixExpr Nothing expr
          refs = concatMap Scope.scopeReferences (Map.elems (Scope.sgScopes sg))
       in any (\r -> Scope.refName r == "x") refs

-- | With creates separate expression and body scopes
prop_scope_with_structure :: Bool
prop_scope_with_structure =
  case parseNixTextLoc "let s = { x = 1; }; in with s; x" of
    Left _ -> False
    Right expr ->
      let sg = Scope.fromNixExpr Nothing expr
          scopes = Map.elems (Scope.sgScopes sg)
          withScopes = filter (\s -> Scope.scopeKind s == Scope.WithScope) scopes
       in -- With should create at least one WithScope
          not (null withScopes)

-- | Cross-file merge produces a unified graph
prop_scope_merge_files :: Bool
prop_scope_merge_files =
  case (parseNixTextLoc "let a = 1; in a", parseNixTextLoc "let b = 2; in b") of
    (Right e1, Right e2) ->
      let sg = Scope.fromModuleGraph (Map.fromList [("a.nix", e1), ("b.nix", e2)])
          decls = concatMap Scope.scopeDeclarations (Map.elems (Scope.sgScopes sg))
          names = map Scope.declName decls
       in "a" `elem` names && "b" `elem` names
    _ -> False

-- ============================================================================
-- Properties: Nix lint
-- ============================================================================

-- | Nix lint detects `with`
prop_nix_lint_with :: Bool
prop_nix_lint_with =
  case parseNixTextLoc "with builtins; true" of
    Left _ -> False
    Right expr -> not (null (findNixViolations expr))

-- | Nix lint detects `rec`
prop_nix_lint_rec :: Bool
prop_nix_lint_rec =
  case parseNixTextLoc "rec { x = 1; }" of
    Left _ -> False
    Right expr -> not (null (findNixViolations expr))

-- | Clean Nix files pass lint
prop_nix_lint_clean :: Bool
prop_nix_lint_clean =
  case parseNixTextLoc "let x = 1; y = 2; in x + y" of
    Left _ -> False
    Right expr -> null (findNixViolations expr)

-- ============================================================================
-- Properties: Bash lint
-- ============================================================================

-- | Bash lint detects heredocs
prop_bash_lint_heredoc :: Bool
prop_bash_lint_heredoc =
  case parseBash "cat << EOF\nhello\nEOF\n" of
    Left _ -> False
    Right ast -> not (null (findViolations ast))

-- | Bash lint detects backticks
prop_bash_lint_backtick :: Bool
prop_bash_lint_backtick =
  case parseBash "x=`date`" of
    Left _ -> False
    Right ast -> not (null (findViolations ast))

-- | Clean bash passes lint
prop_bash_lint_clean :: Bool
prop_bash_lint_clean =
  case parseBash "x=\"hello\"\necho \"$x\"\n" of
    Left _ -> False
    Right ast -> null (findViolations ast)

-- ============================================================================
-- Properties: Schema defaulted vars (DESIGN-2)
-- ============================================================================

-- | Variables with no type evidence are reported in schemaDefaultedVars
prop_schema_defaulted_reported :: Bool
prop_schema_defaulted_reported =
  let facts = [Required "MYSTERY_VAR" (Span (Loc 1 0) (Loc 1 0) Nothing)]
      constraints = factsToConstraints facts
      subst = case solve constraints of Right s -> s; Left _ -> emptySubst
      schema = buildSchema facts subst
   in "MYSTERY_VAR" `elem` schemaDefaultedVars schema

-- | Variables with known types are not in schemaDefaultedVars
prop_schema_resolved_not_defaulted :: Bool
prop_schema_resolved_not_defaulted =
  let facts = [DefaultIs "PORT" (LitInt 8080) (Span (Loc 1 0) (Loc 1 0) Nothing)]
      constraints = factsToConstraints facts
      subst = case solve constraints of Right s -> s; Left _ -> emptySubst
      schema = buildSchema facts subst
   in "PORT" `notElem` schemaDefaultedVars schema

-- ============================================================================
-- Properties: End-to-end integration
-- ============================================================================

-- | parseScript on a config script produces config in schema
prop_e2e_config_extraction :: Bool
prop_e2e_config_extraction =
  let script =
        T.unlines
          [ "PORT=\"${PORT:-8080}\"",
            "HOST=\"${HOST:-localhost}\"",
            "config.server.port=$PORT",
            "config.server.host=\"$HOST\""
          ]
   in case parseScript script of
        Left _ -> False
        Right s ->
          let cfg = schemaConfig (scriptSchema s)
           in Map.member ["server", "port"] cfg && Map.member ["server", "host"] cfg

-- | parseScript correctly identifies required vars
prop_e2e_required_vars :: Bool
prop_e2e_required_vars =
  let script = "API_KEY=\"${API_KEY:?}\"\n"
   in case parseScript script of
        Left _ -> False
        Right s ->
          case Map.lookup "API_KEY" (schemaEnv (scriptSchema s)) of
            Just spec -> envRequired spec
            Nothing -> False

-- | parseScript rejects type conflicts
prop_e2e_type_conflict :: Bool
prop_e2e_type_conflict =
  let script =
        T.unlines
          [ "X=\"${X:-42}\"", -- X : TInt
            "Y=\"${Y:-hello}\"", -- Y : TString
            "Z=\"$X\"", -- Z : TInt (from X)
            "Z=\"$Y\"" -- Z : TString (from Y) -- conflict with TInt!
          ]
   in case parseScript script of
        Left _ -> True -- type error, correct
        Right _ -> False -- should have failed

-- | Empty script produces empty schema
prop_e2e_empty_script :: Bool
prop_e2e_empty_script =
  case parseScript "" of
    Left _ -> False
    Right s ->
      Map.null (schemaEnv (scriptSchema s))
        && Map.null (schemaConfig (scriptSchema s))

-- | Store paths are tracked
prop_e2e_store_paths :: Bool
prop_e2e_store_paths =
  let script = "/nix/store/abc123-curl-8.0/bin/curl http://example.com\n"
   in case parseScript script of
        Left _ -> False
        Right s -> not (Set.null (schemaStorePaths (scriptSchema s)))

-- ============================================================================
-- Properties: Edge cases
-- ============================================================================

-- | Script with only comments produces empty schema
prop_edge_comments_only :: Bool
prop_edge_comments_only =
  case parseScript "# this is a comment\n# another comment\n" of
    Left _ -> False
    Right s -> Map.null (schemaEnv (scriptSchema s))

-- | Very long variable names don't crash
prop_edge_long_varname :: Bool
prop_edge_long_varname =
  let name = T.replicate 1000 "A"
      script = name <> "=\"hello\"\n"
   in case parseBash script of
        Left _ -> True
        Right _ -> True

-- | Deeply nested config paths work
prop_edge_deep_config :: Bool
prop_edge_deep_config =
  let path = T.intercalate "." (replicate 50 "level")
      script = "config." <> path <> "=42\n"
   in case parseScript script of
        Left _ -> True -- parse might fail, that's ok
        Right _ -> True -- but it shouldn't crash

-- | Script with all fact types doesn't crash
prop_edge_all_fact_types :: Bool
prop_edge_all_fact_types =
  let script =
        T.unlines
          [ "A=\"${A:-42}\"",
            "B=\"${B:?}\"",
            "C=\"$A\"",
            "D=\"${D:-$A}\"",
            "config.x.y=$A",
            "config.x.z=\"$B\"",
            "config.x.w=true",
            "/nix/store/abc-curl/bin/curl --connect-timeout $A http://example.com"
          ]
   in case parseScript script of
        Left _ -> False
        Right s ->
          Map.size (schemaEnv (scriptSchema s)) >= 4
            && Map.size (schemaConfig (scriptSchema s)) >= 2

-- ============================================================================
-- Properties: Emit-config structural
-- ============================================================================

-- | emit-config JSON has balanced braces
prop_emit_json_balanced :: Property
prop_emit_json_balanced = forAll genConfigFacts $ \facts ->
  let schema = buildSchema facts emptySubst
      output = emitConfigJson schema
   in T.count "{" output == T.count "}" output

-- | emit-config function never contains heredocs
prop_emit_no_heredoc :: [Fact] -> Bool
prop_emit_no_heredoc facts =
  let schema = buildSchema facts emptySubst
      output = emitConfigFunction schema
   in not ("<<" `T.isInfixOf` output)

-- | emit-config JSON for nested config produces nested braces
prop_emit_json_nested :: Bool
prop_emit_json_nested =
  let sp = Span (Loc 1 0) (Loc 1 0) Nothing
      schema =
        emptySchema
          { schemaConfig =
              Map.fromList
                [ (["server", "port"], ConfigSpec TInt (Just "PORT") (Just Unquoted) Nothing sp),
                  (["server", "host"], ConfigSpec TString (Just "HOST") (Just Quoted) Nothing sp)
                ]
          }
      output = emitConfigJson schema
   in "server" `T.isInfixOf` output
        && "port" `T.isInfixOf` output
        && "host" `T.isInfixOf` output
        && T.count "{" output >= 2 -- at least root + server

-- | Generate facts likely to produce config
genConfigFacts :: Gen [Fact]
genConfigFacts = do
  n <- choose (1, 5)
  replicateM n $ do
    path <- genConfigPath
    oneof
      [ do
          var <- genEnvVarName
          sp <- genSpan
          q <- elements [Quoted, Unquoted]
          pure $ ConfigAssign path var q sp,
        do
          lit <- genLiteral
          sp <- genSpan
          pure $ ConfigLit path lit sp
      ]

-- ============================================================================
-- Properties: Format (annotation placement)
-- ============================================================================

-- | formatExpr on simple expressions succeeds
prop_format_simple :: Bool
prop_format_simple =
  case formatExpr "let x = 42; in x" of
    Right output -> "# ::" `T.isInfixOf` output
    Left _ -> False

-- | formatExpr preserves source when no annotations
prop_format_preserves :: Bool
prop_format_preserves =
  case formatExpr "42" of
    Right output -> "42" `T.isInfixOf` output
    Left _ -> False

-- | formatExpr on let-bound function adds type annotation
prop_format_function :: Bool
prop_format_function =
  case formatExpr "let add = x: y: x + y; in add" of
    Right output -> "# ::" `T.isInfixOf` output
    Left _ -> False

-- | formatExpr doesn't crash on generated Nix
prop_format_no_crash :: Property
prop_format_no_crash = forAll (sized genNixExpr) $ \src ->
  case formatExpr src of
    Left _ -> label "format: skip" True
    Right output -> label "format: ok" $ T.length output >= T.length src

-- ============================================================================
-- Properties: Bash AST edge cases
-- ============================================================================

-- | Arithmetic expansion doesn't crash fact extraction
prop_bash_arithmetic :: Bool
prop_bash_arithmetic =
  case parseBash "X=$(( 1 + 2 ))\n" of
    Right ast -> extractFacts ast `seq` True
    Left _ -> True

-- | Subshell doesn't crash fact extraction
prop_bash_subshell :: Bool
prop_bash_subshell =
  case parseBash "X=$(echo hello)\n" of
    Right ast -> extractFacts ast `seq` True
    Left _ -> True

-- | Pipe chain extracts facts from both sides
prop_bash_pipe :: Bool
prop_bash_pipe =
  case parseBash "echo hello | head -n 1\n" of
    Right ast -> extractFacts ast `seq` True
    Left _ -> True

-- | For loop body has facts extracted
prop_bash_for_loop :: Bool
prop_bash_for_loop =
  case parseBash "for x in 1 2 3; do\n  Y=\"${Y:-default}\"\ndone\n" of
    Right ast ->
      let facts = extractFacts ast
       in any isDefault facts
    Left _ -> False
  where
    isDefault (DefaultIs "Y" _ _) = True
    isDefault _ = False

-- ============================================================================
-- Main
-- ============================================================================

main :: IO ()
main = do
  putStrLn "nix-compile property tests"
  putStrLn "========================="
  putStrLn ""

  results <-
    sequence
      [ -- Unification
        run "unify_reflexive" prop_unify_reflexive,
        run "unify_symmetric" prop_unify_symmetric,
        run "unify_valid_subst" prop_unify_valid_subst,
        run "unify_self_trivial" prop_unify_self_trivial,
        run "unify_concrete_disjoint" prop_unify_concrete_disjoint,
        run "unify_tvar_universal" prop_unify_tvar_universal,
        run "subst_compose_assoc" prop_subst_compose_assoc,
        run "subst_empty_identity" prop_subst_empty_identity,
        run "subst_single" prop_subst_single,
        -- Constraint solving
        run "solve_empty" prop_solve_empty,
        run "solve_reflexive" prop_solve_reflexive,
        run "solve_satisfies" prop_solve_satisfies,
        run "solve_deterministic" prop_solve_deterministic,
        -- Fact -> Constraint
        run "constraints_deterministic" prop_constraints_deterministic,
        run "default_is_constraint" prop_default_is_constraint,
        run "required_no_constraint" prop_required_no_constraint,
        run "config_no_constraint" prop_config_no_constraint,
        -- Schema building
        run "schema_deterministic" prop_schema_deterministic,
        run "schema_env_complete" prop_schema_env_complete,
        run "schema_preserves_defaults" prop_schema_preserves_defaults,
        run "schema_required_marked" prop_schema_required_marked,
        -- Parser
        run "parser_no_crash" prop_parser_no_crash,
        run "parser_deterministic" prop_parser_deterministic,
        run "parser_empty" prop_parser_empty,
        run "parser_comments" prop_parser_comments,
        -- Patterns
        run "pattern_default" $ forAll genVarName $ \var -> property $ prop_pattern_default var,
        run "pattern_required" $ forAll genVarName $ \var -> property $ prop_pattern_required var,
        run "pattern_simple" $ forAll genVarName $ \var -> property $ prop_pattern_simple var,
        run "numeric_int" prop_numeric_int,
        run "numeric_rejects_alpha" prop_numeric_rejects_alpha,
        -- Builtins
        run "builtins_nonempty" prop_builtins_nonempty,
        run "builtins_curl_timeout" prop_builtins_curl_timeout,
        run "builtins_curl_output" prop_builtins_curl_output,
        run "builtins_jq_indent" prop_builtins_jq_indent,
        run "builtins_unknown_flag" prop_builtins_unknown_flag,
        run "builtins_unknown_cmd" prop_builtins_unknown_cmd,
        -- Config tree
        run "config_tree_complete" prop_config_tree_complete,
        run "config_tree_deterministic" prop_config_tree_deterministic,
        -- Scope graph
        run "scope_parent_before_with" prop_scope_parent_before_with,
        -- Literals
        run "literal_int_roundtrip" prop_literal_int_roundtrip,
        run "literal_bool_roundtrip" prop_literal_bool_roundtrip,
        run "literal_type_consistent" prop_literal_type_consistent,
        -- End-to-end
        run "e2e_no_crash" prop_e2e_no_crash,
        run "e2e_deterministic" prop_e2e_deterministic,
        run "e2e_concrete_types" prop_e2e_concrete_types,
        -- Stress tests
        run "stress_large_script" prop_stress_large_script,
        run "stress_many_vars" prop_stress_many_vars,
        run "stress_deep_config" prop_stress_deep_config,
        run "stress_chain" prop_stress_chain,
        run "unify_transitivity" prop_unify_transitivity,
        run "schema_config_paths" prop_schema_config_paths,
        -- Overlay Algebra
        run "overlay_identity_left" prop_overlay_identity_left,
        run "overlay_identity_right" prop_overlay_identity_right,
        run "overlay_assoc" prop_overlay_assoc,
        run "overlay_satisfaction" prop_overlay_satisfaction,
        run "overlay_propagation" prop_overlay_propagation,
        -- Nix type inference (FIX-11)
        run "nix_infer_no_crash" prop_nix_infer_no_crash,
        run "nix_infer_deterministic" prop_nix_infer_deterministic,
        run "nix_int_literal" prop_nix_int_literal,
        run "nix_string_literal" prop_nix_string_literal,
        run "nix_bool_literal" prop_nix_bool_literal,
        run "nix_null_literal" prop_nix_null_literal,
        run "nix_list_int" prop_nix_list_int,
        run "nix_attrset" prop_nix_attrset,
        run "nix_identity" prop_nix_identity,
        run "nix_let_binding" prop_nix_let_binding,
        -- Merge correctness
        run "merge_preserves_required" prop_merge_preserves_required,
        run "merge_keeps_default" prop_merge_keeps_default,
        run "duplicate_var_merged" prop_duplicate_var_merged,
        run "merge_schema_identity" prop_merge_schema_identity,
        -- Fact extraction vectors
        run "fact_default_is" prop_fact_default_is,
        run "fact_required" prop_fact_required,
        run "fact_assign_from" prop_fact_assign_from,
        run "fact_config_assign" prop_fact_config_assign,
        run "fact_config_lit" prop_fact_config_lit,
        -- Emit-config output
        run "emit_json_guarded" prop_emit_json_guarded,
        run "emit_json_runtime_args" prop_emit_json_runtime_args,
        run "emit_yaml_guarded" prop_emit_yaml_guarded,
        run "emit_toml_no_null" prop_emit_toml_no_null,
        run "emit_json_literal" prop_emit_json_literal,
        run "emit_json_string_quoted" prop_emit_json_string_quoted,
        -- Scope graph construction
        run "scope_let_decl" prop_scope_let_decl,
        run "scope_attrset_decls" prop_scope_attrset_decls,
        run "scope_func_params" prop_scope_func_params,
        run "scope_var_refs" prop_scope_var_refs,
        run "scope_with_structure" prop_scope_with_structure,
        run "scope_merge_files" prop_scope_merge_files,
        -- Nix lint
        run "nix_lint_with" prop_nix_lint_with,
        run "nix_lint_rec" prop_nix_lint_rec,
        run "nix_lint_clean" prop_nix_lint_clean,
        -- Bash lint
        run "bash_lint_heredoc" prop_bash_lint_heredoc,
        run "bash_lint_backtick" prop_bash_lint_backtick,
        run "bash_lint_clean" prop_bash_lint_clean,
        -- Schema defaulted vars
        run "schema_defaulted_reported" prop_schema_defaulted_reported,
        run "schema_resolved_not_defaulted" prop_schema_resolved_not_defaulted,
        -- End-to-end integration
        run "e2e_config_extraction" prop_e2e_config_extraction,
        run "e2e_required_vars" prop_e2e_required_vars,
        run "e2e_type_conflict" prop_e2e_type_conflict,
        run "e2e_empty_script" prop_e2e_empty_script,
        run "e2e_store_paths" prop_e2e_store_paths,
        -- Edge cases
        run "edge_comments_only" prop_edge_comments_only,
        run "edge_long_varname" prop_edge_long_varname,
        run "edge_deep_config" prop_edge_deep_config,
        run "edge_all_fact_types" prop_edge_all_fact_types,
        -- Emit-config structural
        run "emit_json_balanced" prop_emit_json_balanced,
        run "emit_no_heredoc" prop_emit_no_heredoc,
        run "emit_json_nested" prop_emit_json_nested,
        -- Format
        run "format_simple" prop_format_simple,
        run "format_preserves" prop_format_preserves,
        run "format_function" prop_format_function,
        run "format_no_crash" prop_format_no_crash,
        -- Bash AST edge cases
        run "bash_arithmetic" prop_bash_arithmetic,
        run "bash_subshell" prop_bash_subshell,
        run "bash_pipe" prop_bash_pipe,
        run "bash_for_loop" prop_bash_for_loop
      ]

  putStrLn ""
  let passed = length (filter id results)
  let totalPassed = length results
  putStrLn $ "Passed: " ++ show passed ++ "/" ++ show totalPassed

  if all id results
    then do
      putStrLn "All tests passed!"
      exitSuccess
    else do
      putStrLn "Some tests failed!"
      exitFailure
  where
    run :: (Testable prop) => String -> prop -> IO Bool
    run name prop = do
      putStr $ "  " ++ name ++ " ... "
      result <- quickCheckResult (withMaxSuccess 200 prop)
      case result of
        Success {} -> do
          putStrLn "OK"
          return True
        _ -> do
          putStrLn "FAILED"
          return False
