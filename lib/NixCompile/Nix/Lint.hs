{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : NixCompile.Nix.Lint
-- Description : Detect banned Nix constructs
--
-- Bans:
--   - `with expr;` - obscures scope, breaks tooling
--   - `rec { }` - enables infinite loops, complicates analysis
--
-- These are banned without escape hatch.
module NixCompile.Nix.Lint
  ( -- * Violations
    NixViolation (..),
    ViolationType (..),

    -- * Detection
    findNixViolations,

    -- * Formatting
    formatNixViolations,
  )
where

import Data.Coerce (coerce)
import Data.Fix (Fix (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Nix.Expr.Types
import Nix.Expr.Types.Annotated
import Nix.Utils (Path (..))
import NixCompile.Types (Loc (..), Span (..))

-- | Type of violation
data ViolationType
  = -- | `with expr;`
    VWith
  | -- | `rec { }`
    VRec
  | -- | `substituteAll` call (use substituteAllFiles or similar)
    VSubstituteAll
  | -- | raw `mkDerivation` call (use wrapper)
    VRawMkDerivation
  | -- | raw `runCommand` call
    VRawRunCommand
  | -- | raw `writeShellApplication` call
    VRawWriteShellApplication
  | -- | `writeShellScript` (prefer writeShellApplication)
    VWriteShellScript
  | -- | inline string exceeds length threshold
    VLongInlineString !Int
  deriving (Eq, Show)

-- | A violation found in Nix source
data NixViolation = NixViolation
  { nvType :: !ViolationType,
    nvSpan :: !Span,
    -- | Brief context (e.g., "with lib;")
    nvContext :: !Text
  }
  deriving (Eq, Show)

-- | Maximum inline string length before violation
maxInlineStringLength :: Int
maxInlineStringLength = 120

-- | Find all violations in a parsed Nix expression
findNixViolations :: NExprLoc -> [NixViolation]
findNixViolations = go
  where
    go :: NExprLoc -> [NixViolation]
    go (Fix (Compose (AnnUnit srcSpan e))) = case e of
      -- with expr; body
      NWith scope body ->
        NixViolation
          { nvType = VWith,
            nvSpan = toSpan srcSpan,
            nvContext = "with " <> prettyExpr scope <> ";"
          }
          : go scope
          ++ go body
      -- rec { ... }
      NSet Recursive bindings ->
        NixViolation
          { nvType = VRec,
            nvSpan = toSpan srcSpan,
            nvContext = "rec { ... }"
          }
          : concatMap goBinding bindings
      -- Check function calls for banned functions
      NApp f _arg ->
        let callViolation = checkBannedCall srcSpan f
         in callViolation ++ go f ++ go _arg
      NStr (DoubleQuoted parts) ->
        let len = sum (map partLen parts)
            strViolation =
              if len > maxInlineStringLength
                then
                  [ NixViolation
                      { nvType = VLongInlineString len,
                        nvSpan = toSpan srcSpan,
                        nvContext = "inline string of length " <> T.pack (show len)
                      }
                  ]
                else []
         in strViolation ++ concatMap partExprs parts
      NStr (Indented _ parts) ->
        let len = sum (map partLen parts)
            strViolation =
              if len > maxInlineStringLength
                then
                  [ NixViolation
                      { nvType = VLongInlineString len,
                        nvSpan = toSpan srcSpan,
                        nvContext = "inline string of length " <> T.pack (show len)
                      }
                  ]
                else []
         in strViolation ++ concatMap partExprs parts
      -- Recurse into all other expressions
      NSet NonRecursive bindings -> concatMap goBinding bindings
      NList xs -> concatMap go xs
      NLet bindings body -> concatMap goBinding bindings ++ go body
      NIf c t f -> go c ++ go t ++ go f
      NAssert c b -> go c ++ go b
      NAbs _ b -> go b
      NSelect alt b _ -> go b ++ maybe [] go alt
      NHasAttr b _ -> go b
      NUnary _ x -> go x
      NBinary _ x y -> go x ++ go y
      _ -> []

    checkBannedCall :: SrcSpan -> NExprLoc -> [NixViolation]
    checkBannedCall srcSpan f = case leafSym f of
      Just name
        | name == "substituteAll" ->
            [ NixViolation
                { nvType = VSubstituteAll,
                  nvSpan = toSpan srcSpan,
                  nvContext = "substituteAll ..."
                }
            ]
        | name == "mkDerivation" ->
            [ NixViolation
                { nvType = VRawMkDerivation,
                  nvSpan = toSpan srcSpan,
                  nvContext = "mkDerivation { ... }"
                }
            ]
        | name == "runCommand" ->
            [ NixViolation
                { nvType = VRawRunCommand,
                  nvSpan = toSpan srcSpan,
                  nvContext = "runCommand ..."
                }
            ]
        | name == "writeShellApplication" ->
            [ NixViolation
                { nvType = VRawWriteShellApplication,
                  nvSpan = toSpan srcSpan,
                  nvContext = "writeShellApplication { ... }"
                }
            ]
        | name == "writeShellScript" || name == "writeShellScriptBin" ->
            [ NixViolation
                { nvType = VWriteShellScript,
                  nvSpan = toSpan srcSpan,
                  nvContext = name <> " ..."
                }
            ]
        | otherwise -> []
      Nothing -> []

    -- Extract the leaf symbol from a function expression path
    -- e.g. stdenv.mkDerivation -> Just "mkDerivation"
    --      someScope.substituteAll -> Just "substituteAll"
    leafSym :: NExprLoc -> Maybe Text
    leafSym (Fix (Compose (AnnUnit _ expr))) = case expr of
      NSym name -> Just (coerce name)
      NSelect _ _base (StaticKey name :| _) -> Just (coerce name)
      _ -> Nothing

    partLen (Plain t) = T.length t
    partLen _ = 0

    partExprs (Antiquoted ex) = go ex
    partExprs _ = []

    goBinding :: Binding NExprLoc -> [NixViolation]
    goBinding = \case
      NamedVar _ expr _ -> go expr
      Inherit (Just scope) _ _ -> go scope
      Inherit Nothing _ _ -> []

    toSpan :: SrcSpan -> Span
    toSpan srcSpan =
      let begin = getSpanBegin srcSpan
          end = getSpanEnd srcSpan
          fileFromBegin = case begin of
            NSourcePos path _ _ -> Just (coerce path)
       in Span
            { spanStart = Loc (sourceLine begin) (sourceCol begin),
              spanEnd = Loc (sourceLine end) (sourceCol end),
              spanFile = fileFromBegin
            }

    sourceLine (NSourcePos _ (NPos l) _) = fromIntegral (unPos l)
    sourceCol (NSourcePos _ _ (NPos c)) = fromIntegral (unPos c)

    -- Simple expression pretty printer for context
    prettyExpr :: NExprLoc -> Text
    prettyExpr (Fix (Compose (AnnUnit _ expr))) = case expr of
      NSym name -> coerce name
      NSelect _ base _ -> prettyExpr base <> ".‥"
      _ -> "‥"

-- | Format violations for display
formatNixViolations :: [NixViolation] -> Text
formatNixViolations = T.unlines . map formatOne
  where
    formatOne v =
      T.unlines
        [ formatLoc (nvSpan v) <> ": " <> errorCode (nvType v),
          "  " <> nvContext v,
          "",
          note (nvType v)
        ]

    formatLoc span' =
      let line = T.pack (show (locLine (spanStart span')))
          col = T.pack (show (locCol (spanStart span')))
       in case spanFile span' of
            Just f -> T.pack f <> ":" <> line <> ":" <> col
            Nothing -> line <> ":" <> col

    errorCode VWith = "ALEPH-N001: `with` expression"
    errorCode VRec = "ALEPH-N002: `rec` attrset"
    errorCode VSubstituteAll = "ALEPH-N005: `substituteAll`"
    errorCode VRawMkDerivation = "ALEPH-N006: raw `mkDerivation`"
    errorCode VRawRunCommand = "ALEPH-N007: raw `runCommand`"
    errorCode VRawWriteShellApplication = "ALEPH-N008: raw `writeShellApplication`"
    errorCode VWriteShellScript = "ALEPH-N011: `writeShellScript`"
    errorCode (VLongInlineString n) = "ALEPH-N012: long inline string (" <> T.pack (show n) <> " chars)"

    note VWith =
      T.unlines
        [ "  `with` is banned because it:",
          "    - Obscures where names come from",
          "    - Breaks tooling (go-to-definition, autocomplete)",
          "    - Creates shadowing hazards",
          "    - Makes type inference unsound",
          "",
          "  Use `inherit (expr) name1 name2;` instead."
        ]
    note VRec =
      T.unlines
        [ "  `rec` is banned because it:",
          "    - Enables infinite loops (non-termination)",
          "    - Complicates static analysis",
          "    - Makes evaluation order-dependent",
          "    - Breaks referential transparency",
          "",
          "  Use `let` bindings or explicit function arguments instead."
        ]
    note VSubstituteAll =
      T.unlines
        [ "  `substituteAll` is banned because it:",
          "    - Copies all derivation dependencies into the store",
          "    - Is needlessly expensive for single-variable substitution",
          "    - Should be replaced with the simpler `substitute` approach",
          "",
          "  Use `substituteInPlace` or `substitute` with explicit values instead."
        ]
    note VRawMkDerivation =
      T.unlines
        [ "  Raw `mkDerivation` is banned because it:",
          "    - Bypasses language-specific wrappers",
          "    - Misses important build phases and hooks",
          "",
          "  Use a language-specific wrapper (stdenv.mkDerivation, buildPythonPackage, etc.)."
        ]
    note VRawRunCommand =
      T.unlines
        [ "  Raw `runCommand` is banned because it:",
          "    - Creates derivations without proper package metadata",
          "    - Bypasses build system conventions",
          "",
          "  Use `runCommandWith` or a proper derivation wrapper instead."
        ]
    note VRawWriteShellApplication =
      T.unlines
        [ "  Raw `writeShellApplication` is banned because it:",
          "    - Should be declared via the module system",
          "    - Bypasses shell script linting and type checking",
          "",
          "  Use `aleph.shell.writeShellApplication` or the nix-compile wrapper instead."
        ]
    note VWriteShellScript =
      T.unlines
        [ "  `writeShellScript` is banned because it:",
          "    - Lacks runtime metadata (name, runtime inputs, description)",
          "    - Bypasses the module system for shell applications",
          "",
          "  Use `writeShellApplication` which requires explicit metadata."
        ]
    note (VLongInlineString n) =
      T.unlines
        [ "  Inline strings longer than " <> T.pack (show maxInlineStringLength) <> " characters are banned",
          "    because they:",
          "    - Clutter source files",
          "    - Are hard to review and maintain",
          "    - Should be extracted to separate files",
          "",
          "  Current string length: " <> T.pack (show n) <> " characters.",
          "",
          "  Use a file reference (e.g., `builtins.readFile ./data.txt`) instead."
        ]
