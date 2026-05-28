{-# LANGUAGE ScopedTypeVariables #-}

module NixCompile.Bash.Parse (
    parseBash,
    parseBashWithFilename,
    parseBashFile,
    BashAST (..),
)
where

import Control.Exception (IOException, try)
import Control.Monad.Identity (Identity, runIdentity)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import ShellCheck.AST qualified as SA
import ShellCheck.Interface (
    ParseResult (..),
    ParseSpec (..),
    Position (..),
    SystemInterface (..),
    newParseSpec,
    newSystemInterface,
 )
import ShellCheck.Parser (parseScript)

-- | The AST from ShellCheck with source positions
data BashAST = BashAST
    { astRoot :: SA.Token
    , astPositions :: Map.Map SA.Id (Position, Position)
    }
    deriving (Show, Eq)

-- | Parse bash source text
parseBash :: Text -> Either Text BashAST
parseBash = parseBashWithFilename "<input>"

{- | Parse bash source text with an associated filename.

ShellCheck includes the filename in diagnostics; we also propagate it into
'Span's at higher layers.
-}
parseBashWithFilename :: FilePath -> Text -> Either Text BashAST
parseBashWithFilename filename src =
    let spec =
            newParseSpec
                { psFilename = filename
                , psScript = T.unpack src
                }
        result = runIdentity $ parseScript sysInterface spec
     in case prRoot result of
            Just ast -> Right $ BashAST ast (prTokenPositions result)
            Nothing -> Left $ T.pack $ "Parse errors: " ++ show (length (prComments result))
  where
    sysInterface :: SystemInterface Identity
    sysInterface =
        newSystemInterface
            { siReadFile = \_ _ -> return (Left "no file access")
            }

-- | Parse a bash file
parseBashFile :: FilePath -> IO (Either Text BashAST)
parseBashFile path = do
    result <- try (TIO.readFile path)
    case result of
        Left (e :: IOException) -> return $ Left $ T.pack $ show e
        Right content -> return $ parseBashWithFilename path content
