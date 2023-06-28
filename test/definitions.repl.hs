import Control.Applicative
import Control.Exception (evaluate)
import Control.Lens
import Control.Monad.Logger (runStderrLoggingT)
import Control.Monad.Logger.CallStack (runFileLoggingT)
import Control.Monad.State (MonadTrans (lift), StateT (..), evalStateT, forM)
import Control.Monad.Trans.Except (runExceptT)
import Control.Monad.Trans.Maybe (MaybeT (runMaybeT))
import Control.Monad.Trans.Reader
import Control.Monad.Trans.State
import Control.Monad.Writer (MonadIO (liftIO), execWriterT, forM_, join, runWriterT)
import Data.Aeson (decode, defaultOptions, encode, genericToJSON)
import Data.List
import Data.Maybe
import Data.Time.Clock (diffUTCTime)
import Data.Time.Clock.POSIX (getCurrentTime)
import Distribution.PackageDescription (emptyGenericPackageDescription, emptyPackageDescription)
import GHC.RTS.Flags (ProfFlags (descrSelector))
import GTD.Cabal
import GTD.Configuration (GTDConfiguration (_repos), prepareConstants)
import GTD.Haskell.AST
import GTD.Haskell.Cpphs
import GTD.Haskell.Declaration
import GTD.Haskell.Enrich
import GTD.Haskell.Package
import GTD.Haskell.Module
import GTD.Haskell.Utils
import GTD.Server
import GTD.Utils
import Language.Haskell.Exts
import System.Directory (getCurrentDirectory, setCurrentDirectory)
import System.FilePath ((</>))
import qualified Data.ByteString.Lazy as BS
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Distribution.ModuleName as Cabal
import qualified Distribution.ModuleName as ModuleName

:set -XRankNTypes
:set -XFlexibleContexts
:set -XTupleSections

let tWorkDir = "./test/integrationTestRepo/sc-ea-hs"
let mFile = tWorkDir </> "app/game/Main.hs"

consts <- prepareConstants

oS s f1 f2 = flip f1 s $ runFileLoggingT (tWorkDir </> "log1.txt") $ flip runReaderT consts $ runExceptT $ f2
rS s f = oS s runStateT f
eaS s f = oS s evalStateT f
esS s f = oS s execStateT f

(a, b) <- rS emptyServerState $ definition DefinitionRequest {workDir = tWorkDir, file = mFile, word = "playIO"}

let modules = _ccpmodules $ _context b
let cabalDeps = _dependencies $ _context b

(Right tM) <- eaS b $ parseModule emptyHsModule {_path = mFile}
(Right tM') <- eaS b $ ultraZoom context $ enrich tM
enrichedDeclsA = filter hasNonEmptyOrig $ Map.elems $ _decls tM'
enrichedDeclsI = filter (\d -> _declSrcUsage d /= emptySourceSpan) $ filter (\d -> _declSrcUsage d /= _declSrcOrig d) $ filter hasNonEmptyOrig $ Map.elems $ _decls tM'
forM_ enrichedDeclsI print

let modules = _ccpmodules $ _context b
let modulesGloss = fromJust $ "gloss" `Map.lookup` modules
let moduleGlossIoGame = fromJust $ "Graphics.Gloss.Interface.IO.Game" `Map.lookup` modulesGloss

let modulesRandom = fromJust $ "random" `Map.lookup` modules
let modulesRandomI = fromJust $ "System.Random.Internal" `Map.lookup` modulesRandom
let modulesRandomM = fromJust $ "System.Random" `Map.lookup` modulesRandom

Right (_, exportsRI) <- eaS b $ runWriterT $ haskellGetExportedIdentifiers (_ast modulesRandomI)
Right importsRI <- eaS b $ execWriterT $ haskellGetImportedIdentifiers (_ast modulesRandomI)
_declName <$> (Map.elems $ Map.intersection (asDeclsMap exportsRI) (_decls modulesRandomI <> asDeclsMap importsRI))

Right (_, exportsRM) <- eaS b $ runWriterT $ haskellGetExportedIdentifiers (_ast modulesRandomM)
Right importsRM <- eaS b $ execWriterT $ haskellGetImportedIdentifiers (_ast modulesRandomM)
_declName <$> (Map.elems $ Map.intersection (_decls modulesRandomM <> asDeclsMap importsRM) (asDeclsMap exportsRM))
Map.lookup (Identifier "mkStdGen") (Map.intersection (_decls modulesRandomM <> asDeclsMap importsRM) (asDeclsMap exportsRM))

(a, _) <- rS b $ definition DefinitionRequest {workDir = tWorkDir, file = mFile, word = "mkStdGen"}

let cabalPackageRandom = fromJust $ find (\v -> _cabalPackageName v == "random") cabalDeps
Right ppr <- eaS b $ parsePackage cabalPackageRandom
Map.lookup (Identifier "mkStdGen") (_exports $ fromJust $ Map.lookup "System.Random" ppr)
Map.lookup (Identifier "newStdGen") (_exports $ fromJust $ Map.lookup "System.Random" ppr)