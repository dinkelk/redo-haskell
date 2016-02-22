-- adding StandAloneDeriving extension:
-- {-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Build(redo, redoIfChange, makeRelative') where

-- System imports:
import Control.Applicative ((<$>))
import Control.Monad (unless, when)
import Control.Exception (catch, SomeException(..))
import Data.Map.Lazy (adjust, insert, fromList, toList)
import Data.Maybe (isNothing, fromJust, fromMaybe)
import System.Directory (doesDirectoryExist, setCurrentDirectory, renameFile, renameDirectory, removeFile, doesFileExist, getCurrentDirectory)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode(..), exitFailure)
import System.FileLock (lockFile, tryLockFile, unlockFile, SharedExclusive(..), FileLock)
import System.FilePath ((</>), takeDirectory, dropExtension, takeExtensions, takeFileName, dropExtensions)
import System.IO (withFile, IOMode(..), hFileSize, hGetLine)
import System.Process (createProcess, waitForProcess, shell, CreateProcess(..))
import Data.Bool (bool)

-- Local imports:
import Database
import PrettyPrint
import Helpers

-- Just run the do file for a 'redo' command:
redo :: [Target] -> IO ExitCode
redo = buildTargets redo'
  where redo' target = maybe (noDoFileError target) (build target) =<< findDoFile target

-- Only run the do file if the target is not up to date for 'redo-ifchange' command:
redoIfChange :: [Target] -> IO ExitCode
redoIfChange = buildTargets redoIfChange'
  where 
    redoIfChange' target = do 
      --putStatusStrLn $ "redo-ifchange " ++ target
      -- TODO maybe get do file from this func
      upToDate' <- upToDate target
      -- Try to run redo if out of date, if it fails, print an error message:
      unless' upToDate' (maybe (missingDo target) (build target) =<< findDoFile target)
    -- If a do file is not found then return an error message, unless the file exists,
    -- in which case it is a source file and does not need to be rebuilt
    missingDo target = do exists <- doesTargetExist target
                          unless' exists (noDoFileError target)
    -- Custom unless which return ExitSuccess if the condition is met
    unless' condition action = if condition then return ExitSuccess else action

-- Lock a file and run a function that takes that file as input.
-- If the file is already locked, skip running the function on that
-- file initially, and continue to trying to run the function on the next
-- file in the list. In a second pass, wait as long as it takes to lock 
-- on the files that were initially skipped before running the function.
-- This function allows us to build all the targets that don't have any 
-- lock contention first, buying us a little time before we wait to build
-- the files under lock contention
buildTargets :: (Target -> IO ExitCode) -> [Target] -> IO ExitCode
buildTargets buildFunc targets = do
  keepGoing'' <- lookupEnv "REDO_KEEP_GOING" -- Variable to tell redo to keep going even on failure
  let keepGoing' = fromMaybe "" keepGoing''
  let keepGoing = not $ null keepGoing'
  -- Try to lock file and build it, accumulate list of unbuilt files
  remainingTargets <- mapM' keepGoing tryBuild targets 
  -- Wait to acquire the lock, and build the remaining unbuilt files
  mapM_' keepGoing waitBuild remainingTargets          
  where
    -- Try to build the target if the do file can be found and there is no lock contention:
    tryBuild :: Target -> IO (Target, LockFile, ExitCode)
    tryBuild target = do 
      absTarget <- Target <$> canonicalizePath' (unTarget target)
      tryBuild' absTarget
    tryBuild' :: Target -> IO (Target, LockFile, ExitCode)
    tryBuild' target = do lckFileName <- createLockFile target 
                          maybe (return (target, lckFileName, ExitSuccess)) (runBuild target) 
                            =<< tryLockFile (lockFileToFilePath lckFileName) Exclusive
    runBuild :: Target -> FileLock -> IO (Target, LockFile, ExitCode)
    runBuild target lock = do exitCode <- buildFunc target
                              unlockFile lock
                              return (Target "", LockFile "", exitCode)
    -- Wait to build the target if the do file is given, regardless of lock contention:
    waitBuild :: (Target, LockFile, ExitCode) -> IO ExitCode 
    waitBuild (Target "", LockFile "", exitCode) = return exitCode
    waitBuild (target, lckFileName, _) = do lock <- lockFile (lockFileToFilePath lckFileName) Exclusive 
                                            exitCode <- buildFunc target
                                            unlockFile lock
                                            return exitCode
    -- Special mapM which exits early if an operation fails
    mapM' :: Bool -> (Target -> IO (Target, LockFile, ExitCode)) -> [Target] -> IO [(Target, LockFile, ExitCode)]
    mapM' keepGoing f list = mapM'' ExitSuccess list
      where 
        mapM'' exitCode [] = return [(Target "", LockFile "", exitCode)]
        mapM'' exitCode (x:xs) = do 
          (a, b, newExitCode) <- f x 
          if newExitCode /= ExitSuccess then 
            if keepGoing then runNext newExitCode (a, b, newExitCode)
            else return [(a, b, newExitCode)]
          else runNext exitCode (a, b, newExitCode)
          where runNext code current = do next <- mapM'' code xs
                                          return $ current : next
    -- Special mapM_ which exits early if an operation fails
    mapM_' :: Bool -> ((Target, LockFile, ExitCode) -> IO ExitCode) -> [(Target, LockFile, ExitCode)] -> IO ExitCode
    mapM_' keepGoing f list = mapM_'' ExitSuccess list
      where 
        mapM_'' exitCode [] = return exitCode
        mapM_'' exitCode (x:xs) = do 
          newExitCode <- f x 
          if newExitCode /= ExitSuccess then 
            if keepGoing then mapM_'' newExitCode xs
            else return newExitCode
          else mapM_'' exitCode xs

-- Run a do file in the do file directory on the given target:
build :: Target -> DoFile -> IO ExitCode
build target doFile = performActionInDir' (takeDirectory $ unDoFile doFile) (runDoFile target) doFile

-- TODO cleanup
performActionInDir' :: FilePath -> (t -> IO ExitCode) -> t -> IO ExitCode
performActionInDir' dir action target = do
  topDir <- getCurrentDirectory
  catch (setCurrentDirectory dir) (\(_ :: SomeException) -> do 
    putErrorStrLn $ "Error: No such directory " ++ topDir </> dir
    exitFailure)
  exitCode <- action target
  setCurrentDirectory topDir
  return exitCode

-- Run do file if the target was not modified by the user first.
runDoFile :: Target -> DoFile -> IO ExitCode
runDoFile target doFile = do 
  metaDir <- metaFileDir target
  cachedTimeStamp <- getTargetBuiltTimeStamp metaDir
  currentTimeStamp <- safeGetTargetTimeStamp target
  whenTargetNotModified cachedTimeStamp currentTimeStamp targetModifiedError (runDoFile' target doFile currentTimeStamp metaDir)
  where
    targetModifiedError :: IO ExitCode
    targetModifiedError = do putWarningStrLn $ "Warning: '" ++ unTarget target ++ "' was modified outside of redo. Skipping...\n" ++
                                               "If you want to rebuild '" ++ unTarget target ++ "', remove it and try again."
                             return ExitSuccess

-- Run the do script. Note: this must be run in the do file's directory!:
-- and the absolute target must be passed.
runDoFile' :: Target -> DoFile -> Maybe Stamp -> MetaDir -> IO ExitCode
runDoFile' target doFile currentTimeStamp depDir = do 
  -- Get some environment variables:
  keepGoing' <- lookupEnv "REDO_KEEP_GOING"           -- Variable to tell redo to keep going even on failure
  shuffleDeps' <- lookupEnv "REDO_SHUFFLE"            -- Variable to tell redo to shuffle build order
  redoDepth' <- lookupEnv "REDO_DEPTH"                -- Depth of recursion for this call to redo
  shellArgs' <- lookupEnv "REDO_SHELL_ARGS"           -- Shell args passed to initial invokation of redo
  redoInitPath' <- lookupEnv "REDO_INIT_PATH"         -- Path where redo was initially invoked
  sessionNumber' <- lookupEnv "REDO_SESSION"          -- Unique number to define this session
  redoPath <- getCurrentDirectory                     -- Current redo path
  let redoInitPath = fromJust redoInitPath'           -- this should always be set from the first run of redo
  let redoDepth = show $ if isNothing redoDepth' then 0 else (read (fromJust redoDepth') :: Int) + 1
  let shellArgs = fromMaybe "" shellArgs'
  let keepGoing = fromMaybe "" keepGoing'
  let shuffleDeps = fromMaybe "" shuffleDeps'
  let sessionNumber = fromMaybe "" sessionNumber'
  let targetRel2Do = Target $ makeRelative' redoPath (unTarget target)
  cmd <- shellCmd shellArgs doFile targetRel2Do

  -- Print what we are currently "redoing"
  putRedoStatus (read redoDepth :: Int) (makeRelative' redoInitPath (unTarget target))
  unless(null shellArgs) (putUnformattedStrLn $ "* " ++ cmd)

  -- Create the meta deps dir:
  initializeMetaDepsDir' depDir doFile

  -- Add REDO_TARGET to environment, and make sure there is only one REDO_TARGET in the environment
  oldEnv <- getEnvironment
  let newEnv = toList $ adjust (++ ":.") "PATH" 
                      $ insert "REDO_PATH" redoPath
                      $ insert "REDO_SESSION" sessionNumber
                      $ insert "REDO_KEEP_GOING" keepGoing
                      $ insert "REDO_SHUFFLE" shuffleDeps
                      $ insert "REDO_DEPTH" redoDepth
                      $ insert "REDO_INIT_PATH" redoInitPath 
                      $ insert "REDO_TARGET" (unTarget target)
                      $ insert "REDO_SHELL_ARGS" shellArgs 
                      $ fromList oldEnv
  (_, _, _, processHandle) <- createProcess $ (shell cmd) {env = Just newEnv}
  exit <- waitForProcess processHandle
  case exit of  
    ExitSuccess -> do exitCode <- moveTempFiles 
                      markTargetClean depDir -- we just built this target, so we know it is clean now
                      -- If the target exists, then mark the target built with its timestamp
                      targetExists <- doesTargetExist target
                      when targetExists (markTargetBuilt target depDir)
                      removeTempFiles target
                      return exitCode
    ExitFailure code -> do markTargetDirty depDir -- we failed to build this target, so mark it dirty
                           removeTempFiles target
                           redoError code $ nonZeroExitStr code
  where
    nonZeroExitStr code = "Error: Redo script '" ++ unDoFile doFile ++ "' failed to build '" ++ 
                          unTarget target ++ "' with exit code: " ++ show code 
    -- Temporary file names:
    tmp3 = tmp3File target 
    tmpStdout = tmpStdoutFile target 
    moveTempFiles :: IO ExitCode
    moveTempFiles = do 
      tmp3Exists <- doesTargetExist $ Target tmp3
      stdoutExists <- doesTargetExist $ Target tmpStdout
      targetIsDirectory <- doesDirectoryExist $ unTarget target
      newTimeStamp <- safeGetTargetTimeStamp target
      if tmp3Exists then
        if currentTimeStamp /= newTimeStamp && not targetIsDirectory then dollarOneModifiedError 
        else do
          renameFileOrDir tmp3 target
          size <- fileSize tmpStdout
          if stdoutExists && size > 0 then wroteToStdoutError else return ExitSuccess
      else if stdoutExists then
        if currentTimeStamp /= newTimeStamp && not targetIsDirectory then dollarOneModifiedError 
        else do
          size <- fileSize tmpStdout
          -- The else statement is a bit confusing, and is used to be compatible with apenwarr's implementation
          -- Basically, if the stdout temp file has a size of zero, we should remove the target, because no
          -- target should be created. This is our way of denoting the file as correctly build! 
          -- Usually this target won't exist anyways, but it might exist in the case
          -- of a modified .do file that was generating something, and now is not! In this case we remove the 
          -- old target to denote that the new .do file is working as intended. See the unit test "silencetest.do"
          if size > 0 then renameFileOrDir tmpStdout target >> return ExitSuccess
                      -- a stdout file size of 0 was created. This is the default
                      -- behavior on some systems for ">"-ing a file that generatetes
                      -- no stdout. In this case, lets not clutter the directory, and
                      -- instead store a phony target in the meta directory
                      else do safeRemoveFile $ unTarget target
                              storePhonyTarget depDir
                              return ExitSuccess
      -- Neither temp file was created. This must be a phony target. Let's create it in the meta directory.
      else storePhonyTarget depDir >> return ExitSuccess
      where renameFileOrDir :: FilePath -> Target -> IO () 
            renameFileOrDir old new = catch(renameFile old (unTarget new)) 
              (\(_ :: SomeException) -> catch(renameDirectory old (unTarget new)) (\(_ :: SomeException) -> storePhonyTarget depDir))
    
    wroteToStdoutError :: IO ExitCode
    wroteToStdoutError = redoError 1 $ "Error: '" ++ unDoFile doFile ++ "' wrote to stdout and created $3.\n" ++
                                       "You should write status messages to stderr, not stdout." 
    dollarOneModifiedError :: IO ExitCode
    dollarOneModifiedError = redoError 1 $ "Error: '" ++ unDoFile doFile ++ "' modified '" ++ unTarget target ++ "' directly.\n" ++
                                           "You should update $3 (the temporary file) or stdout, not $1." 
    redoError :: Int -> String -> IO ExitCode
    redoError code message = do putErrorStrLn message
                                return $ ExitFailure code

-- Pass redo script 3 arguments:
-- $1 - the target name
-- $2 - the target basename
-- $3 - the temporary target name
shellCmd :: String -> DoFile -> Target -> IO String
shellCmd shellArgs doFile target = do
  shebang <- readShebang doFile
  return $ unwords [shebang, show $ unDoFile doFile, show $ unTarget target, show arg2, show $ tmp3File target, ">", show $ tmpStdoutFile target]
  where
    -- The second argument $2 is a tricky one. Traditionally, $2 is supposed to be the target name with the extension removed.
    -- What exactly constitutes the "extension" of a file can be debated. After much grudging... this implementation is now 
    -- compatible with the python implementation of redo. The value of arg2 depends on if the do file run is a default<.extensions>.do 
    -- file or a <targetName>.do file. For example the $2 for "redo file.x.y.z" run from different .do files is shown below:
    --
    --    .do file name |         $2  | description 
    --    file.x.y.z.do | file.x.y.z  | we do not know what part of the file is the extension... so we leave the entire thing 
    -- default.x.y.z.do |       file  | we know .x.y.z is the extension, so remove it
    --   default.y.z.do |     file.x  | we know .y.z is the extension, so remove it 
    --     default.z.do |   file.x.y  | we know .z is the extension, so remove it
    --       default.do | file.x.y.z  | we do not know what part of the file is the extension... so we leave the entire thing
    --
    arg2 = if (dropExtensions . takeFileName . unDoFile) doFile == "default" then createArg2 (unTarget target) doExtensions else unTarget target
    doExtensions = (takeExtensions . dropExtension . unDoFile) doFile -- remove .do, then grab the rest of the extensions
    createArg2 fname extension = if null extension then fname else createArg2 (dropExtension fname) (dropExtension extension)
    -- Read the shebang from a file and use that as the command. This allows us to run redo files that are in a language
    -- other than shell, ie. python or perl
    readShebang :: DoFile -> IO String
    readShebang file = readFirstLine >>= extractShebang
      where 
        readFirstLine = catch (withFile (unDoFile file) ReadMode hGetLine) (\(_ :: SomeException) -> return "")
        extractShebang shebang = if take 2 shebang == "#!" then return $ drop 2 shebang else return $ "sh -e" ++ shellArgs

-- Temporary files:
tmp3File :: Target -> FilePath
tmp3File target = unTarget target ++ ".redo1.temp" -- this temp file gets passed as $3 and is written to by programs that do not print to stdout
tmpStdoutFile :: Target -> FilePath
-- Stdout file name. Note we make this in the current directory, regardless of the target directory,
-- because we don't know if the target directory even exists yet. We can't redirect output to a non-existant
-- file.
tmpStdoutFile target = takeFileName (unTarget target) ++ ".redo2.temp" -- this temp file captures what gets written to stdout

-- Remove the temporary files created for a target:
removeTempFiles :: Target -> IO ()
removeTempFiles target = do safeRemoveFile $ tmp3File target
                            safeRemoveFile $ tmpStdoutFile target
                     
-- Function to check if file exists, and if it does, remove it:
safeRemoveFile :: FilePath -> IO ()
safeRemoveFile file = bool (return ()) (removeFile file) =<< doesFileExist file

-- Get the file size of a file
fileSize :: FilePath -> IO Integer
fileSize path = withFile path ReadMode hFileSize

-- Missing do error function:
noDoFileError :: Target -> IO ExitCode
noDoFileError target = do putErrorStrLn $ "Error: No .do file found to build target '" ++ unTarget target ++ "'"
                          return $ ExitFailure 1
