{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module GTD.Server where

import Control.Lens (over, use, (%=))
import Control.Monad (forM_, mapAndUnzipM, when, (<=<), (>=>))
import Control.Monad.Except (ExceptT, MonadError (..), MonadIO (..), liftEither, runExceptT)
import Control.Monad.Logger (MonadLoggerIO)
import Control.Monad.RWS (MonadReader (..), MonadState (..))
import Control.Monad.State (evalStateT, execStateT, modify)
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Trans.Except (throwE)
import Control.Monad.Trans.Reader (ReaderT (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Bifunctor (Bifunctor (..))
import qualified Data.Cache.LRU as LRU
import qualified Data.Map as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import GHC.Generics (Generic)
import GHC.Stats (getRTSStats, getRTSStatsEnabled)
import GTD.Cabal (ModuleNameS)
import qualified GTD.Cabal as Cabal
import GTD.Configuration (GTDConfiguration (..))
import GTD.Haskell.Declaration (ClassOrData (..), Declaration (..), Declarations (..), Identifier, SourceSpan, asDeclsMap, hasNonEmptyOrig)
import GTD.Haskell.Module (HsModule (..), HsModuleP (..), emptyHsModule, parseModule)
import qualified GTD.Haskell.Module as HsModule
import GTD.Resolution.Module (figureOutExports, figureOutExports0, figureOutExports1, module'Dependencies, moduleR)
import qualified GTD.Resolution.Module as Module
import GTD.Resolution.State (Context (..), Package (Package, _cabalPackage, _modules), cExports, ccGet)
import qualified GTD.Resolution.State as Package
import GTD.Resolution.State.Caching.Cabal (cabalCacheStore, cabalFindAtCached, cabalFull)
import GTD.Resolution.State.Caching.Package (packageCachedAdaptSizeTo, packageCachedGet, packageCachedGet', packageCachedPut, packageCachedRemove, packagePersistenceGet, persistenceExists, persistenceGet)
import GTD.Resolution.Utils (ParallelizedState (..), SchemeState (..), parallelized, scheme)
import GTD.Utils (logDebugNSS, ultraZoom)
import Text.Printf (printf)
import qualified Data.Graph as Graph

data DefinitionRequest = DefinitionRequest
  { workDir :: FilePath,
    file :: FilePath,
    word :: String
  }
  deriving (Show, Generic)

data DefinitionResponse = DefinitionResponse
  { srcSpan :: Maybe SourceSpan,
    err :: Maybe String
  }
  deriving (Show, Generic, Eq)

instance ToJSON DefinitionRequest

instance FromJSON DefinitionRequest

instance ToJSON DefinitionResponse

instance FromJSON DefinitionResponse

noDefintionFoundError :: Monad m => ExceptT String m a
noDefintionFoundError = throwE "No definition found"

noDefintionFoundErrorME :: MonadError String m => m a
noDefintionFoundErrorME = liftEither $ noDefintionFoundErrorE "No definition found"

noDefintionFoundErrorE :: (Monad m) => m (Either String a)
noDefintionFoundErrorE = runExceptT noDefintionFoundError

---

modules :: Package -> (MonadBaseControl IO m, MonadLoggerIO m) => m Package
modules pkg@Package {_cabalPackage = c} = do
  mods <- modules1 pkg c
  return pkg {Package._exports = Map.restrictKeys mods (Cabal._exports . Cabal._modules $ c), Package._modules = mods}

-- for a given Cabal package, it returns a list of modules in the order they should be processed
modulesOrdered :: Cabal.PackageFull -> (MonadBaseControl IO m, MonadLoggerIO m) => m [HsModule]
modulesOrdered c = do
  flip runReaderT c $ flip evalStateT (SchemeState Map.empty Map.empty) $ do
    scheme moduleR HsModule._name id (return . module'Dependencies) (Set.toList . Cabal._exports . Cabal._modules $ c)

-- for a given Cabal package and list of its modules in the 'right' order, concurrently parses all the modules
modules1 ::
  Package ->
  Cabal.PackageFull ->
  (MonadBaseControl IO m, MonadLoggerIO m) => m (Map.Map ModuleNameS HsModuleP)
modules1 pkg c = do
  modsO <- modulesOrdered c
  let st = ParallelizedState modsO Map.empty Map.empty (_modules pkg)
  parallelized st (Cabal.nameVersionF c) figureOutExports1 (const "tbd") HsModule._name (return . module'Dependencies)

---

packageK ::
  Context ->
  Cabal.PackageFull ->
  (MonadBaseControl IO m, MonadLoggerIO m, MonadReader GTDConfiguration m) => m (Maybe Package, Context -> Context)
packageK c cPkg = do
  let logTag = "packageK " ++ show (Cabal.nameVersionF cPkg)
  (pkgM, f) <- packageCachedGet' c cPkg
  case pkgM of
    Just x -> return (Just x, f)
    Nothing -> do
      (depsC, m) <- bimap catMaybes (foldr (.) id) <$> mapAndUnzipM (packageCachedGet' c <=< flip evalStateT c . cabalFull) (Cabal._dependencies cPkg)
      let deps = foldr (<>) Map.empty $ Package._exports <$> depsC
      pkgWORE <- modules $ Package {_cabalPackage = cPkg, Package._modules = deps, Package._exports = Map.empty}
      let reexports = Map.restrictKeys deps $ Cabal._reExports . Cabal._modules $ cPkg
      let pkg = pkgWORE {Package._exports = Package._exports pkgWORE <> reexports}
      packageCachedPut cPkg pkg
      logDebugNSS logTag $
        printf
          "given\ndeps=%s\ndepsF=%s\ndepsM=%s\nexports=%s\nreexports=%s\nPRODUCING\nexports=%s\nreexports=%s\n"
          (show $ Cabal.nameVersionP <$> Cabal._dependencies cPkg)
          (show $ Cabal.nameVersionF . _cabalPackage <$> depsC)
          (show $ Map.keys deps)
          (show $ Cabal._exports . Cabal._modules $ cPkg)
          (show $ Cabal._reExports . Cabal._modules $ cPkg)
          (show $ Map.keys $ Package._exports pkgWORE)
          (show $ Map.keys reexports)
      return (Just pkg, over cExports (LRU.insert (Cabal.nameVersionF cPkg) (Package._exports pkg)) . m . f)

package0 ::
  Cabal.PackageFull ->
  (MonadBaseControl IO m, MonadLoggerIO m, MonadState Context m, MonadReader GTDConfiguration m) => m (Maybe Package)
package0 cPkg = do
  c <- get
  (a, b) <- packageK c cPkg
  modify b
  return a

simpleShowContext :: Context -> String
simpleShowContext c =
  printf
    "ccFindAt: %s, ccFull: %s, ccGet: %s, cExports: %s\nccFindAt = %s\nccFull = %s\nccGet = %s\ncExports = %s"
    (show $ Map.size $ _ccFindAt c)
    (show $ Map.size $ _ccFull c)
    (show $ Map.size $ Cabal._vs . _ccGet $ c)
    (show $ LRU.size $ _cExports c)
    (show $ Map.keys $ _ccFindAt c)
    (show $ Map.keys $ _ccFull c)
    (show $ Map.keys $ Cabal._vs . _ccGet $ c)
    (show $ fst <$> LRU.toList (_cExports c))

packageOrderedF1 :: (Monad m, MonadLoggerIO m, MonadState Context m, MonadReader GTDConfiguration m, MonadBaseControl IO m) => Cabal.Package -> m (Maybe Cabal.PackageFull)
packageOrderedF1 cPkg = do b <- persistenceExists cPkg; if b then return Nothing else ((Just <$>) . cabalFull) cPkg

packageOrderedF2 :: (Monad m, MonadLoggerIO m, MonadState Context m, MonadReader GTDConfiguration m, MonadBaseControl IO m) => Cabal.Package -> m (Maybe Cabal.PackageFull)
packageOrderedF2 = (Just <$>) . cabalFull

packagesOrdered ::
  Cabal.PackageFull ->
  (MonadBaseControl IO m, MonadLoggerIO m, MonadState Context m, MonadReader GTDConfiguration m) =>
  (Cabal.Package -> m (Maybe Cabal.PackageFull)) ->
  m [Cabal.PackageFull]
packagesOrdered cPkg0 f = do
  flip evalStateT (SchemeState Map.empty Map.empty) $ do
    scheme f Cabal.nameVersionF Cabal.nameVersionP (return . Cabal._dependencies) [Cabal._fpackage cPkg0]

package ::
  Cabal.PackageFull ->
  (MonadBaseControl IO m, MonadLoggerIO m, MonadState Context m, MonadReader GTDConfiguration m) => m (Maybe Package)
package cPkg0 = do
  m <- packagePersistenceGet cPkg0
  case m of
    Just p -> return $ Just p
    Nothing -> do
      pkgsO <- packagesOrdered cPkg0 packageOrderedF1

      stC0 <- get
      let st = ParallelizedState pkgsO Map.empty Map.empty stC0
      stC1 <- parallelized st ("packages", Cabal.nameVersionF cPkg0) packageK simpleShowContext Cabal.nameVersionF (return . fmap Cabal.nameVersionP . Cabal._dependencies)
      put stC1

      package0 cPkg0
      packagePersistenceGet cPkg0

---

resolution :: Declarations -> Map.Map Identifier Declaration
resolution Declarations {_decls = ds, _dataTypes = dts} =
  let ds' = Map.elems ds
      dts' = concatMap (\cd -> [_cdtName cd] <> Map.elems (_cdtFields cd)) (Map.elems dts)
   in asDeclsMap $ ds' <> dts'

definition ::
  DefinitionRequest ->
  (MonadBaseControl IO m, MonadLoggerIO m, MonadReader GTDConfiguration m, MonadState Context m, MonadError String m) => m DefinitionResponse
definition (DefinitionRequest {workDir = wd, file = rf, word = w}) = do
  cPkg <- cabalFindAtCached wd
  pkgM <- package cPkg
  pkg <- maybe (throwError "no package found?") return pkgM

  m <- parseModule emptyHsModule {_path = rf, HsModule._package = Cabal.nameF cPkg}
  m' <- Module.resolution (_modules pkg) m

  ccGC <- use $ ccGet . Cabal.changed
  when ccGC cabalCacheStore

  statsE <- liftIO getRTSStatsEnabled
  when statsE $ do
    stats <- liftIO getRTSStats
    liftIO $ putStrLn $ "GCs: " ++ show stats

  ultraZoom cExports $ packageCachedAdaptSizeTo (toInteger $ 10 + length (Cabal._dependencies cPkg))

  case "" `Map.lookup` m' of
    Nothing -> noDefintionFoundErrorME
    Just m'' ->
      case w `Map.lookup` resolution m'' of
        Nothing -> noDefintionFoundErrorME
        Just d ->
          if hasNonEmptyOrig d
            then return $ DefinitionResponse {srcSpan = Just $ _declSrcOrig d, err = Nothing}
            else noDefintionFoundErrorME

---

newtype DropCacheRequest = DropCacheRequest {dir :: FilePath}
  deriving (Show, Generic)

instance FromJSON DropCacheRequest

instance ToJSON DropCacheRequest

resetCache ::
  DropCacheRequest ->
  (MonadBaseControl IO m, MonadLoggerIO m, MonadReader GTDConfiguration m, MonadState Context m, MonadError String m) => m String
resetCache (DropCacheRequest {dir = d}) = do
  cPkg <- cabalFindAtCached d
  packageCachedRemove cPkg
  cExports %= fst . LRU.delete (Cabal.nameVersionF cPkg)
  return "OK"