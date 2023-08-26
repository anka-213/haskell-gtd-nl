{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Lens (use, (^.))
import Control.Monad (forM_)
import Control.Monad.Except (runExceptT, when)
import Control.Monad.Logger (LogLevel (LevelInfo), filterLogger, runFileLoggingT)
import Control.Monad.Reader (ReaderT (runReaderT))
import Control.Monad.State (execStateT)
import qualified GTD.Cabal.Cache as Cabal ( load, store )
import qualified GTD.Cabal.FindAt as Cabal ( findAt )
import qualified GTD.Cabal.Get as Cabal ( changed )
import qualified GTD.Configuration as Conf (GTDConfiguration (..), defaultArgs, Args(..), prepareConstants)
import GTD.Resolution.State (ccGet, emptyContext)
import GTD.Server (package'resolution'withDependencies'concurrently)
import GTD.Utils (logErrorNSS, stats)
import Options.Applicative (Parser, ParserInfo, auto, execParser, fullDesc, help, helper, info, long, option, showDefault, strOption, value, (<**>))
import System.Directory (getCurrentDirectory, setCurrentDirectory)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)

data Args = Args
  { dir :: String,
    logLevel :: LogLevel
  }
  deriving (Show)

args :: Parser Args
args =
  Args
    <$> strOption (long "dir" <> help "how long to wait before dying when idle (in seconds)")
    <*> option auto (long "log-level" <> help "" <> showDefault <> value LevelInfo)

opts :: ParserInfo Args
opts =
  info
    (args <**> helper)
    fullDesc

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering

  a@Args {dir = d, logLevel = ll} <- execParser opts
  print a

  constants <- Conf.prepareConstants =<< Conf.defaultArgs
  let r = Conf._root . Conf._args $ constants
  setCurrentDirectory r
  getCurrentDirectory >>= print
  print constants

  runFileLoggingT (r </> "package.log") $ filterLogger (\_ l -> l >= ll) $ do
    e <- runExceptT $ flip runReaderT constants $ flip execStateT emptyContext $ do
      Cabal.load
      pkg <- Cabal.findAt d
      forM_ pkg $ \p -> package'resolution'withDependencies'concurrently p
      ccGC <- use $ ccGet . Cabal.changed
      when ccGC Cabal.store
    case e of
      Left err -> logErrorNSS d err
      Right _ -> pure ()

  stats
