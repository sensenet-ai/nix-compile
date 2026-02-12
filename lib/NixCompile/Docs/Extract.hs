{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module NixCompile.Docs.Extract
  ( extractDocs,
  )
where

import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import NixCompile.Docs.Types
import qualified NixCompile.Nix.Scope as Scope
import NixCompile.Nix.Scope (ScopeGraph(..), Scope(..), Declaration(..), SourceSpan(..), SourcePos(..))
import NixCompile.Types (Span(..), Loc(..))

-- | Extract documentation from a scope graph and source code
extractDocs :: ScopeGraph -> Text -> [DocItem]
extractDocs sg src =
  let decls = concatMap scopeDeclarations (Map.elems (sgScopes sg))
      sortedDecls = sortOn (posLine . Scope.spanStart . declSpan) decls
      lines_ = T.lines src
  in map (makeDocItem lines_) sortedDecls

makeDocItem :: [Text] -> Declaration -> DocItem
makeDocItem srcLines decl =
  DocItem
    { docName = declName decl
    , docDescription = extractComment srcLines (declSpan decl)
    , docType = declType decl
    , docSpan = toSpan (declSpan decl)
    , docKind = Variable -- TODO: infer kind
    }

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
     else if "#" `T.isPrefixOf` trimmed
          then T.drop 1 trimmed
          else t

takeWhileEnd :: (a -> Bool) -> [a] -> [a]
takeWhileEnd p = reverse . takeWhile p . reverse

toSpan :: SourceSpan -> Span
toSpan (SourceSpan (SourcePos l1 c1) (SourcePos l2 c2) f) =
  Span (Loc l1 c1) (Loc l2 c2) (f >>= \_ -> Nothing) -- TODO: file
