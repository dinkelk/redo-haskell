{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Database(metaDir, initializeMetaDepsDir, isSourceFile, storeIfChangeDependencies, storeIfCreateDependencies, 
                storeAlwaysDependency, upToDate, noDoFileError, storePhonyTarget, lockFileName)  where

import Control.Applicative ((<$>),(<*>))
import Control.Monad (liftM, guard)
import Control.Exception (catch, catchJust, SomeException(..))
import qualified Data.ByteString.Char8 as BS
--import Data.Digest.Pure.MD5 (md5)
--import qualified Data.ByteString.Lazy as BL
import Crypto.Hash.MD5 (hash) 
import Data.Hex (hex)
import Data.Bool (bool)
import Data.Maybe (fromJust)
import GHC.IO.Exception (IOErrorType(..))
import System.Directory (getAppUserDataDirectory, makeAbsolute, getModificationTime, doesFileExist, getDirectoryContents, removeDirectoryRecursive, createDirectoryIfMissing, getCurrentDirectory, doesDirectoryExist)
import System.Exit (exitFailure)
import System.FilePath (normalise, dropTrailingPathSeparator, makeRelative, splitFileName, (</>), takeDirectory, isPathSeparator, pathSeparator)
import System.IO (withFile, hGetLine, IOMode(..))
import System.IO.Error (ioeGetErrorType, isDoesNotExistError)
import System.Environment (lookupEnv)

import PrettyPrint
import Helpers

-- Directory for storing and fetching data on dependencies of redo targets.
metaDir :: IO (String)
metaDir = getAppUserDataDirectory "redo"

-- Form the hash directory where a target's dependency hashes will be stored given the target
depFileDir :: FilePath -> IO (FilePath)
depFileDir target = do
  metaRoot <- metaDir 
  absPath <- makeAbsolute target
  return $ metaRoot </> (hex $ BS.unpack $ hash $ BS.pack absPath)

-- Create meta data folder for storing md5 hashes:
-- Note: this function also blows out the old directory, which is good news because we don't want old
-- dependencies hanging around if we are rebuilding a file.
initializeMetaDepsDir :: FilePath -> FilePath -> IO ()
initializeMetaDepsDir target doFile = f =<< depFileDir target
  where f metaDepsDir = do
          catchJust (guard . isDoesNotExistError)
                    (removeDirectoryRecursive metaDepsDir)
                    (\_ -> return())
          createDirectoryIfMissing True metaDepsDir 
          -- Write out .do script as dependency:
          storeIfChangeDep target doFile
          
-- Return the lock file name for a target:
lockFileName :: FilePath -> IO (FilePath)
lockFileName target = do dir <- depFileDir target
                         return $ dir ++ ".lck"

-- Does a phony target file exist in the meta directory for a target?
doesPhonyTargetExist :: FilePath -> IO Bool
doesPhonyTargetExist target = doesFileExist =<< phonyFile target

-- Does a target file or phony file exist?
hasTargetBeenBuilt :: FilePath -> IO Bool
hasTargetBeenBuilt target = (||) <$> doesTargetExist target <*> doesPhonyTargetExist target

-- Returns the path to the target, if it exists, otherwise it returns the path to the
-- phony target.
getBuiltTargetPath :: FilePath -> IO(FilePath)
getBuiltTargetPath target = bool (phonyFile target) (return target) =<< doesTargetExist target

-- Checks if a target file is a buildable target, or if it is a source file
isSourceFile :: FilePath -> IO Bool
isSourceFile target = bool (return False) (not <$> hasDependencies target) =<< doesTargetExist target
  where
    -- Check's if a target has dependencies stored already
    hasDependencies :: FilePath -> IO Bool
    hasDependencies t = doesDirectoryExist =<< depFileDir t
  
-- Some #defines used for creating escaped dependency filenames. We want to avoid /'s.
#define seperator_replacement '^'
#define seperator_replacement_escape '@'
-- We use different file prepends to denote different kinds of dependencies:
-- ~ redo-always
-- % redo-ifcreate
-- @ redo-ifchange
-- # phony target (.do file that doesn't write to stdout or $3)
#define ifchange_dependency_prepend '@'
#define ifcreate_dependency_prepend '%'
#define always_dependency_prepend '~'
#define phony_target_prepend '#'

-- Returns true if all dependencies are up-to-date, or target is a source file, false otherwise.
upToDate :: FilePath -> IO Bool
upToDate target =
  -- If the target has not been built, then it is obviously not up-to-date, otherwise check it's dependencies
  hasTargetBeenBuilt target >>= bool (return False) 
    -- If the target exists, but has no do file to build it, then it is a source file, and is up to date, so return true
    (maybe (return True) depsUpToDate =<< findDoFile target)
  where 
    -- Does a target have tracked dependencies, or is it a source file? If so, are they up to date?
    depsUpToDate :: FilePath -> IO Bool
    depsUpToDate doFile = do
      -- If target has no dependencies, then it is a source file, and can't be built, so it's up-to-date
      -- otherwise check the target's dependencies to see if they are up to date.
      -- Note: A target has dependencies if it has a metaDepsDir.
      -- Note: A target is a source file if the metaDepsDir doesn't exist
      metaDepsDir <- depFileDir target
      doesDirectoryExist metaDepsDir >>= bool (return True) (do
        doFileDir <- getAbsoluteDirectory doFile
        depsUpToDate' doFileDir =<< getDirectoryContents metaDepsDir) 
    -- Are a target's redo-create or redo-always or redo-ifchange dependencies up to date?
    depsUpToDate' :: FilePath -> [FilePath] -> IO Bool
    depsUpToDate' doFileDir depHashFiles =
      if anyAlwaysDeps depHashFiles then return False
      else do 
        -- redo-ifcreate - if one of those files was created, we need to return False immediately
        depCreated' <- or `liftM` mapM (depCreated .  unEscapeIfCreatePath) (ifCreateDeps depHashFiles)
        if depCreated' then return False
        -- redo-ifchange - check these files hashes against those stored to determine if they are up to date
        --                 then recursively check their dependencies to see if they are up to date
        else and `liftM` mapM (ifChangeDepsUpToDate doFileDir . unEscapeIfChangePath) (ifChangeDeps depHashFiles)
    -- Returns true if there are any "-always" dependencies present:
    anyAlwaysDeps = any (fileHasPrepend always_dependency_prepend) 
    -- Functions which filter a set of dependencies for only those made with "-ifchange" or "-ifcreate"
    ifChangeDeps = filter (fileHasPrepend ifchange_dependency_prepend)
    ifCreateDeps = filter (fileHasPrepend ifcreate_dependency_prepend)
    -- Check if dep file begins with certain prepend string
    fileHasPrepend depPrepend xs = take 2 xs == ['.'] ++ [depPrepend]
    -- Has a dependency been created
    depCreated :: FilePath -> IO Bool
    depCreated dep = id <$> doesTargetExist dep 
    -- Are a target's redo-ifchange dependencies up to date? This function provides recursion:
    ifChangeDepsUpToDate :: FilePath -> FilePath -> IO Bool
    ifChangeDepsUpToDate doFileDir dep = catch
      (do hashFile <- ifChangeDepFile target dep
          oldHash <- withFile hashFile ReadMode hGetLine
          -- Get the dependency to hash (phony or real). It it exists, calculate and 
          -- store the hash. Otherwise, we know we are not up to date because the dep 
          -- is missing.
          depToHash <- getBuiltTargetPath $ doFileDir </> dep
          newHash <- computeHash depToHash
          -- If the dependency is not up-to-date, then return false
          -- If the dependency is up-to-date then recurse to see if it's dependencies are up-to-date
          if oldHash /= newHash then return False
          else upToDate $ doFileDir </> dep)
      -- Ignore "." and ".." directories, and return true, return false if file dep doesn't exist
      (\e -> return (ioeGetErrorType e == InappropriateType))

-- Missing do error function:
noDoFileError :: FilePath -> IO()
noDoFileError target = do putErrorStrLn $ "Error: No .do file found for target '" ++ target ++ "'"
                          exitFailure

-- Functions to escape and unescape dependencies of different types:
escapeIfChangePath :: FilePath -> FilePath 
escapeIfChangePath = escapeDependencyPath ifchange_dependency_prepend
unEscapeIfChangePath :: FilePath -> FilePath 
unEscapeIfChangePath = unEscapeDependencyPath ifchange_dependency_prepend

escapeIfCreatePath :: FilePath -> FilePath 
escapeIfCreatePath = escapeDependencyPath ifcreate_dependency_prepend
unEscapeIfCreatePath :: FilePath -> FilePath 
unEscapeIfCreatePath = unEscapeDependencyPath ifcreate_dependency_prepend

escapeAlwaysPath :: FilePath
escapeAlwaysPath = escapeDependencyPath always_dependency_prepend "redo-always"

escapePhonyPath :: FilePath
escapePhonyPath = escapeDependencyPath phony_target_prepend "phony-target"

-- This is the same as running normalise, but it always removes the trailing path
-- separator, and it always keeps a "./" in front of things in the current directory
-- and always removes "./" in front of things not in the current directory.
-- we use this to ensure consistancy of naming convention
sanitizeFilePath :: FilePath -> FilePath
sanitizeFilePath filePath = normalise $ dir </> file
  where (dir, file) = splitFileName . dropTrailingPathSeparator . normalise $ filePath

-- Takes a file path and replaces all </> with @
escapeDependencyPath :: Char -> FilePath -> FilePath
escapeDependencyPath dependency_prepend path = (['.'] ++ [dependency_prepend]) ++ concatMap repl path' ++ ([dependency_prepend] ++ ['.'])
  where path' = sanitizeFilePath path
        repl seperator_replacement = [seperator_replacement] ++ [seperator_replacement_escape]
        repl c   = if isPathSeparator c then [seperator_replacement] else [c]

-- Reverses escapeFilePath
unEscapeDependencyPath :: Char -> FilePath -> FilePath
unEscapeDependencyPath dependency_prepend name = sanitizeFilePath path
  where 
    path = if take 2 name == (['.'] ++ [dependency_prepend]) then unEscape $ (dropEnd 2 . drop 2) name else name
    dropEnd n list = take (length list - n) list
    unEscape [] = []
    unEscape string = first : unEscape rest
      where
        (first, rest) = repl string
        repl [] = ('\0',"")
        repl (x:xs) = if x == seperator_replacement
                      then if head xs == seperator_replacement_escape
                           then (seperator_replacement, tail xs)
                           else (pathSeparator, xs)
                      else (x, xs)

-- Store dependencies for redo-ifchange:
storeIfChangeDependencies :: [FilePath] -> IO ()
storeIfChangeDependencies = storeDependencies storeIfChangeDep

-- Store dependencies for redo-ifcreate:
storeIfCreateDependencies :: [FilePath] -> IO ()
storeIfCreateDependencies = storeDependencies storeIfCreateDep

-- Store dependency for redo-always:
storeAlwaysDependency :: IO ()
storeAlwaysDependency = do 
  parentRedoPath <- lookupEnv "REDO_PATH" -- directory where .do file was run from
  parentRedoTarget <- lookupEnv "REDO_TARGET"
  performActionInDir (fromJust parentRedoPath) storeAlwaysDep $ fromJust parentRedoTarget

-- Store dependencies given a store action and a list of dependencies to store:
storeDependencies :: (FilePath -> FilePath -> IO ()) -> [FilePath] -> IO ()  
storeDependencies storeAction dependencies = do 
  parentRedoPath <- lookupEnv "REDO_PATH" -- directory where .do file was run from
  parentRedoTarget <- lookupEnv "REDO_TARGET"
  dependenciesRel2Parent <- makeRelativeToParent (fromJust parentRedoPath) dependencies 
  mapM_ (performActionInDir (fromJust parentRedoPath) (storeAction $ fromJust parentRedoTarget) ) dependenciesRel2Parent
  where
    makeRelativeToParent :: FilePath -> [FilePath] -> IO ([FilePath])
    makeRelativeToParent parent targets = do
      currentDir <- getCurrentDirectory
      -- All dependencies for the parent target should be stored in a .redo file in the
      -- parent target .do file invocation location.
      -- Note: All target listed here are relative to the current directory in the .do script. This could
      -- be different than the REDO_PATH variable, which represents the directory where the .do was invoked 
      -- if 'cd' was used in the .do script.
      -- So, let's get a list of targets relative to the parent .do file invocation location, REDO_PATH
      return $ map (makeRelative parent . (currentDir </>)) targets

-- If the dependency exists then store:
storeIfChangeDep :: FilePath -> FilePath -> IO ()
storeIfChangeDep target dep = do
  depToHash <- getBuiltTargetPath dep
  theDepFile <- ifChangeDepFile target dep
  h <- computeHash $ depToHash
  writeDepFile (theDepFile) h

storeIfCreateDep :: FilePath -> FilePath -> IO ()
storeIfCreateDep target dep = createEmptyDepFile =<< ifCreateDepFile target dep

storeAlwaysDep :: FilePath -> IO ()
storeAlwaysDep target = createEmptyDepFile =<< alwaysDepFile target 

storePhonyTarget :: FilePath -> IO ()
storePhonyTarget target = createEmptyDepFile =<< phonyFile target 

-- Calculate the hash of a file. If the file is a directory,
-- then return the timestamp instead.
-- TODO: implement timestamps, also make hash stored as binary
computeHash :: FilePath -> IO String
computeHash file = do 
  isDir <- doesDirectoryExist file
  if isDir then do
    timestamp <- getModificationTime file
    return (show timestamp)
  else (show . hash) `liftM` BS.readFile file

-- Calculate the hash of a target's dependency and write it to the proper meta data location
-- If the dependency doesn't exist, do not store a hash
writeDepFile :: FilePath -> FilePath -> IO ()
writeDepFile file contents = catch
  ( writeFile file contents )
  (\(_ :: SomeException) -> do cd <- getCurrentDirectory 
                               putErrorStrLn $ "Error: Encountered problem writing '" ++ contents ++ "' to '" ++ cd </> file ++ "'."
                               exitFailure)

-- Creation of an empty dep file for redo-always and redo-ifcreate
-- note may need to make specific one for redoifcreate and redoalways
createEmptyDepFile :: FilePath -> IO ()
createEmptyDepFile file = writeDepFile file "." 

-- Returns the absolute directory of a file path relative to the current dir:
getAbsoluteDirectory :: FilePath -> IO FilePath
getAbsoluteDirectory file = takeDirectory <$> makeAbsolute file 

-- Form the hash file path for a target's dependency given the current target and its dependency
depFile :: (FilePath -> FilePath) -> FilePath -> FilePath -> IO (FilePath)
depFile escapeFunc target dep = f =<< depFileDir target
  where f depDir = return $ depDir </> escapeFunc dep

-- Functions to get the dependency path for each file type
ifChangeDepFile :: FilePath -> FilePath -> IO (FilePath)
ifChangeDepFile = depFile escapeIfChangePath
ifCreateDepFile :: FilePath -> FilePath -> IO (FilePath)
ifCreateDepFile = depFile escapeIfCreatePath
alwaysDepFile :: FilePath -> IO (FilePath)
alwaysDepFile target = f =<< depFileDir target 
  where f depDir = return $ depDir </> escapeAlwaysPath
phonyFile :: FilePath -> IO (FilePath)
phonyFile target = f =<< depFileDir target 
  where f depDir = return $ depDir </> escapePhonyPath 
