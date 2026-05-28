{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module NixCompile.Docs.Extract (
    extractDocs,
)
where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import NixCompile.Docs.Types
import NixCompile.Nix.Scope (Declaration (..), Scope (..), ScopeGraph (..), ScopeId, ScopeKind (..), SourcePos (..), SourceSpan (..))
import NixCompile.Nix.Scope qualified as Scope
import NixCompile.Types (Loc (..), Span (..))

-- | Extract documentation from a scope graph and source code
extractDocs :: ScopeGraph -> Text -> [DocItem]
extractDocs sg src =
    let decls = concatMap scopeDeclarations (Map.elems (sgScopes sg))
        sortedDecls = sortOn (posLine . Scope.spanStart . declSpan) decls
        lines_ = T.lines src
        scopeKinds =
            Map.fromList
                [ (scopeId s, scopeKind s)
                | s <- Map.elems (sgScopes sg)
                ]
     in map (makeDocItem lines_ scopeKinds) sortedDecls

makeDocItem :: [Text] -> Map ScopeId ScopeKind -> Declaration -> DocItem
makeDocItem srcLines scopeKinds decl =
    DocItem
        { docName = declName decl
        , docDescription = extractComment srcLines (declSpan decl)
        , docType = declType decl
        , docSpan = toSpan (declSpan decl)
        , docKind = inferDocKind scopeKinds decl
        }

inferDocKind :: Map ScopeId ScopeKind -> Declaration -> DocKind
inferDocKind scopeKinds decl = case Map.lookup (declScope decl) scopeKinds of
    Just FunctionScope -> Function
    Just AttrSetScope -> Attribute
    Just RecAttrSetScope -> Attribute
    _ -> Variable

-- | Extract comments preceding annotations
extractComment :: [Text] -> SourceSpan -> Text
extractComment lines_ span' =
    let lineIdx = posLine (Scope.spanStart span') - 1 -- 0-based index
        preceding = take lineIdx lines_
        comments = takeWhileEnd isComment preceding
     in T.unlines (map cleanComment comments)

isComment :: Text -> Bool
isComment t = "#" `T.isPrefixOf` T.stripStart t

cleanComment :: Text -> Text
cleanComment t =
    let trimmed = T.stripStart t
     in if "# " `T.isPrefixOf` trimmed
            then T.drop 2 trimmed
            else
                if "#" `T.isPrefixOf` trimmed
                    then T.drop 1 trimmed
                    else t

takeWhileEnd :: (a -> Bool) -> [a] -> [a]
takeWhileEnd p = reverse . takeWhile p . reverse

toSpan :: SourceSpan -> Span
toSpan (SourceSpan (SourcePos l1 c1) (SourcePos l2 c2) f) =
    Span (Loc l1 c1) (Loc l2 c2) f
