module NixCompile.Bash.Parse
  ( parseBash,
    parseBashWithFilename,
    parseBashFile,
    parseScript,  -- alias for parseBash
    BashAST(..),
  )
where

import Control.Monad.Identity (Identity, runIdentity)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import qualified ShellCheck.AST as SA
import ShellCheck.Interface
  ( ParseResult (..),
    ParseSpec (..),
    SystemInterface (..),
    newParseSpec,
    newSystemInterface,
    Position(..),
  )
import qualified ShellCheck.Parser as SC

-- | The AST from ShellCheck with source positions
data BashAST = BashAST
  { astRoot :: SA.Token
  , astPositions :: Map.Map SA.Id (Position, Position)
  }
  deriving (Show, Eq)

-- | Parse bash source text
parseBash :: Text -> Either Text BashAST
parseBash = parseBashWithFilename "<input>"

-- | Parse bash source text with an associated filename.
--
-- ShellCheck includes the filename in diagnostics; we also propagate it into
-- 'Span's at higher layers.
parseBashWithFilename :: FilePath -> Text -> Either Text BashAST
parseBashWithFilename filename src =
  let spec =
        newParseSpec
          { psFilename = filename,
            psScript = T.unpack src
          }
      result = runIdentity $ SC.parseScript sysInterface spec
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
  content <- TIO.readFile path
  return $ parseBashWithFilename path content

-- | Alias for parseBash for API compatibility
parseScript :: Text -> Either Text BashAST
parseScript = parseBash
