{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module GTD.Cabal where

import Control.Applicative (Applicative (liftA2))
import Control.Lens (makeLenses)
import Control.Monad (forM)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Maybe (MaybeT (runMaybeT), hoistMaybe)
import Data.ByteString.UTF8 (fromString)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Distribution.Compat.Prelude (Generic)
import Distribution.ModuleName (ModuleName, toFilePath)
import Distribution.PackageDescription (BuildInfo (..), Dependency (Dependency), Executable (buildInfo, exeName), Library (..), PackageDescription (..), unPackageName)
import Distribution.PackageDescription.Configuration (flattenPackageDescription)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Pretty (prettyShow)
import Distribution.Simple (majorBoundVersion, mkVersion)
import Distribution.Utils.Path (PackageDir, SourceDir, SymbolicPath, getSymbolicPath)
import Distribution.Utils.ShortText (fromShortText)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), hClose, hGetBuf, hGetContents, openFile)
import System.Process (CreateProcess (..), StdStream (CreatePipe), createProcess, proc)
import Text.Printf (printf)
import Text.Regex.Posix ((=~))

cabalGet :: String -> String -> MaybeT IO String
cabalGet pkg pkgVerPredicate = do
  (_, Just hout, Just herr, _) <- lift $ createProcess (proc "cabal" ["get", pkg ++ pkgVerPredicate, "--destdir", "./repo"]) {std_out = CreatePipe, std_err = CreatePipe}
  stdout <- lift $ hGetContents hout
  stderr <- lift $ hGetContents herr
  let content = stdout ++ stderr
  let re = pkg ++ "-" ++ "[^\\/]*\\/"
  let packageVersion :: [String] = (=~ re) <$> lines content
  hoistMaybe $ find (not . null) packageVersion

cabalRead :: FilePath -> IO PackageDescription
cabalRead p = do
  handle <- openFile p ReadMode
  (warnings, epkg) <- runParseResult . parseGenericPackageDescription . fromString <$> hGetContents handle
  either (fail . show) (return . flattenPackageDescription) epkg

cabalFetchDependencies :: PackageDescription -> IO [(String, FilePath)]
cabalFetchDependencies pkg = do
  let dependencies = liftA2 (,) exeName (((\(Dependency n v _) -> (unPackageName n, prettyShow v)) <$>) . targetBuildDepends . buildInfo) <$> executables pkg
      fetchDependency n v = (,) n <$> cabalGet n v
      fetchDependencies :: [(String, String)] -> IO [(String, FilePath)]
      fetchDependencies deps = catMaybes <$> mapM runMaybeT (uncurry fetchDependency <$> deps)
  concat <$> mapM (\(component, deps) -> fetchDependencies deps) dependencies

type CabalLibSrcDir = SymbolicPath PackageDir SourceDir

cabalGetExportedModules :: PackageDescription -> IO ([SymbolicPath PackageDir SourceDir], [ModuleName])
cabalGetExportedModules pkg = do
  lib <- maybe (fail "no library") return (library pkg)
  let modules = exposedModules lib
  let srcDirs = (hsSourceDirs . libBuildInfo) lib
  return (srcDirs, modules)

haskellPath :: FilePath -> CabalLibSrcDir -> ModuleName -> FilePath
haskellPath dir src mod = dir </> getSymbolicPath src </> (toFilePath mod ++ ".hs")

type PackageNameS = String

type ModuleNameS = String

data CabalPackage = CabalPackage
  { _cabalPackageName :: PackageNameS,
    _cabalPackagePath :: FilePath,
    _cabalPackageDesc :: PackageDescription,
    _cabalPackageSrcDirs :: [CabalLibSrcDir],
    _cabalPackageExportedModules :: Map.Map ModuleNameS ModuleName
  }
  deriving (Show, Generic)

$(makeLenses ''CabalPackage)

cabalDeps :: PackageDescription -> IO [CabalPackage]
cabalDeps pkg = do
  deps <- cabalFetchDependencies pkg
  forM deps $ \(n, p') -> do
    let p = "repo" </> p'
    let path = p </> (n ++ ".cabal")
    desc <- cabalRead path
    (srcs, mods) <- cabalGetExportedModules desc
    return $ CabalPackage n p desc srcs (Map.fromList $ (\x -> (prettyShow x, x)) <$> mods)
