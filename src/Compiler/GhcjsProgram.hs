{-# LANGUAGE CPP, ScopedTypeVariables, MultiWayIf, TupleSections #-}
{-
  The GHCJS-specific parts of the frontend (ghcjs program)

  Our main frontend is copied from GHC, Compiler.Program
 -}

module Compiler.GhcjsProgram where

import           GHC hiding (setSessionDynFlags)
import           GhcMonad
import           DynFlags
import           PackageConfig
import           UniqFM
import           PrimOp
import           PrelInfo
import           IfaceEnv
import           HscTypes
import           DsMeta
import           LoadIface
import           ErrUtils (fatalErrorMsg'')
import           Panic (handleGhcException)
import           Exception

import           Control.Applicative
import           Control.Monad
import           Control.Monad.IO.Class

import qualified Data.ByteString as B
import           Data.IORef
import           Data.List (isSuffixOf, isPrefixOf, partition,)
import qualified Data.List as L
import qualified Data.Map as M
import           Data.Maybe
import           Data.Monoid
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Lazy.IO as TL
import           Data.Time.Clock

import           Distribution.System (buildOS, OS(..))
import           Distribution.Verbosity (deafening, intToVerbosity)
import           Distribution.Package (PackageName(..))
import           Distribution.Simple.BuildPaths (exeExtension)
import           Distribution.Simple.Utils (installExecutableFile, installDirectoryContents)
import           Distribution.Simple.Program (runProgramInvocation, simpleProgramInvocation)

import           Options.Applicative

import           System.Directory (doesFileExist, doesDirectoryExist, createDirectoryIfMissing)
import           System.Environment (getArgs)
import           System.Exit
import           System.FilePath
import           System.IO
import           System.Process

import           Compiler.GhcjsPlatform
import           Compiler.Info
import           Compiler.Settings
import           Compiler.Utils

-- fixme, make frontend independent of backend
import qualified Gen2.Object      as Object
import qualified Gen2.ClosureInfo as Gen2
import qualified Gen2.PrimIface   as Gen2
import qualified Gen2.Shim        as Gen2
import qualified Gen2.Rts         as Gen2
import qualified Gen2.RtsTypes    as Gen2

-- workaround for platform dependence bugs
import           Rules (mkRuleBase)
import qualified Gen2.GHC.PrelRules

import           Gen2.GHC.Packages

getGhcjsSettings :: [Located String] -> IO ([Located String], GhcjsSettings)
getGhcjsSettings args =
  case p of
    Failure failure -> do
      let (msg, code) = execFailure failure "ghcjs"
      hPutStrLn stderr msg
      exitWith code
    Success gs1 -> do
      gs2 <- envSettings
      return (args', gs1 <> gs2)
    CompletionInvoked _ -> exitWith (ExitFailure 1)
  where
    (ga,args') = partition (\a -> any (`isPrefixOf` unLoc a) as) args
    p = execParserPure (prefs mempty) optParser' (map unLoc ga)
    as = [ "--native-executables"
         , "--native-too"
         , "--building-cabal-setup"
         , "--no-js-executables"
         , "--strip-program="
         , "--log-commandline="
         , "--with-ghc="
         , "--only-out"
         , "--no-rts"
         , "--no-stats"
         , "--generate-base="
         , "--use-base="
         ]
    envSettings = GhcjsSettings <$> getEnvOpt "GHCJS_NATIVE_EXECUTABLES"
                                <*> getEnvOpt "GHCJS_NATIVE_TOO"
                                <*> pure False
                                <*> pure False
                                <*> pure Nothing
                                <*> getEnvMay "GHCJS_LOG_COMMANDLINE_NAME"
                                <*> getEnvMay "GHCJS_WITH_GHC"
                                <*> pure False
                                <*> pure False
                                <*> pure False
                                <*> pure Nothing
                                <*> pure NoBase

optParser' :: ParserInfo GhcjsSettings
optParser' = info (helper <*> optParser) fullDesc

optParser :: Parser GhcjsSettings
optParser = GhcjsSettings
            <$> switch ( long "native-executables" )
            <*> switch ( long "native-too" )
            <*> switch ( long "building-cabal-setup" )
            <*> switch ( long "no-js-executables" )
            <*> optStr ( long "strip-program" )
            <*> optStr ( long "log-commandline" )
            <*> optStr ( long "with-ghc" )
            <*> switch ( long "only-out" )
            <*> switch ( long "no-rts" )
            <*> switch ( long "no-stats" )
            <*> optStr ( long "generate-base" )
            <*> (maybe NoBase BaseFile <$> optStr ( long "use-base" ))

optStr :: Mod OptionFields (Maybe String) -> Parser (Maybe String)
optStr m = nullOption $ value Nothing <> reader (pure . str)  <> m

printVersion :: IO ()
printVersion = putStrLn $
  "The Glorious Glasgow Haskell Compilation System for JavaScript, version " ++
     getCompilerVersion ++ " (GHC " ++ getGhcCompilerVersion ++ ")"

printNumericVersion :: IO ()
printNumericVersion = putStrLn getCompilerVersion

printRts :: DynFlags -> IO ()
printRts dflags = TL.putStrLn (Gen2.rtsText dflags $ Gen2.dfCgSettings dflags) >> exitSuccess

printDeps :: FilePath -> IO ()
printDeps = Object.readDepsFile >=> TL.putStrLn . Object.showDeps

printObj :: FilePath -> IO ()
printObj = Object.readObjectFile >=> TL.putStrLn . Object.showObject

-- replace primops in the name cache so that we get our correctly typed primops
fixNameCache :: GhcMonad m => m ()
fixNameCache = do
  sess <- getSession
  liftIO $ modifyIORef (hsc_NC sess) $ \(NameCache u _) ->
    (initNameCache u knownNames)
  liftIO $ modifyIORef (hsc_EPS sess) $ \eps ->
    eps { eps_rule_base = mkRuleBase Gen2.GHC.PrelRules.builtinRules }
    where
      knownNames = map getName (filter (not.isPrimOp) wiredInThings) ++
                      basicKnownKeyNames ++
                      templateHaskellNames ++
                      map (getName . AnId . Gen2.mkGhcjsPrimOpId) allThePrimOps
      isPrimOp (AnId i) = isPrimOpId i
      isPrimOp _        = False


checkIsBooted :: Maybe String -> IO ()
checkIsBooted mbMinusB = do
  base <- mkLibDir mbMinusB
  let bootFile = base </> "ghcjs_boot.completed"
  e <- doesFileExist bootFile
  when (not e) $ do
    hPutStrLn stderr $ "cannot find `" ++ bootFile ++ "'\n\n" ++
#ifdef WINDOWS
                       "please install the GHCJS boot libraries or edit the `.options' file to point to the correct library location\n" ++
#else
                       "please install the GHCJS boot libraries or edit the `ghcjs' wrapper script to point to the correct library location\n" ++
#endif
                       "See README for details\n" ++
                       "(running `ghcjs-boot' might fix this)\n"
    exitWith (ExitFailure 87)


runJsProgram :: Maybe String -> [String] -> IO ()
runJsProgram Nothing _ = error noTopDirErrorMsg
runJsProgram (Just topDir) args
  | (_:script:scriptArgs) <- dropWhile (/="--run") args = do
      hSetBuffering stdin NoBuffering
      hSetBuffering stdout NoBuffering
      hSetBuffering stderr NoBuffering
      node <- T.strip <$> T.readFile (topDir </> "node")
      ph <- runProcess (T.unpack node) (script:scriptArgs) Nothing Nothing Nothing Nothing Nothing
      exitWith =<< waitForProcess ph
  | otherwise = error "usage: ghcjs --run [script] [arguments]"

-- | when booting GHCJS, we pretend to have the Cabal lib installed
--   call GHC to compile our Setup.hs
bootstrapFallback :: IO ()
bootstrapFallback = do
    ghc <- fmap (fromMaybe "ghc") $ getEnvMay "GHCJS_WITH_GHC"
    as  <- ghcArgs <$> getFullArguments
    e   <- rawSystem ghc $ as -- run without GHCJS library prefix arg
    case (e, getOutput as) of
      (ExitSuccess, Just o) ->
        createDirectoryIfMissing False (o <.> "jsexe")
      _ -> return ()
    exitWith e
    where
      ignoreArg a  = "-B" `isPrefixOf` a || a == "--building-cabal-setup"
      ghcArgs args = filter (not . ignoreArg) args ++ ["-threaded"]
      getOutput []         = Nothing
      getOutput ("-o":x:_) = Just x
      getOutput (x:xs)     = getOutput xs

installExecutable :: DynFlags -> GhcjsSettings -> [String] -> IO ()
installExecutable dflags settings srcs = do
    case (srcs, outputFile dflags) of
        ([from], Just to) -> do
          let v = fromMaybe deafening . intToVerbosity $ verbosity dflags
          nativeExists <- doesFileExist $ from <.> exeExtension
          when nativeExists $ do
            installExecutableFile v (from <.> exeExtension) (to <.> exeExtension)
            let stripFlags = if buildOS == OSX then ["-x"] else []
            case gsStripProgram settings of
                Just strip -> runProgramInvocation v . simpleProgramInvocation strip $
                                stripFlags ++ [to <.> exeExtension]
                Nothing -> return ()
          jsExists <- doesDirectoryExist $ from <.> jsexeExtension
          when jsExists $ installDirectoryContents v (from <.> jsexeExtension) (to <.> jsexeExtension)
          unless (nativeExists || jsExists) $ do
            hPutStrLn stderr $ "No executable found to install at " ++ from
            exitFailure
        _ -> do
            hPutStrLn stderr "Usage: ghcjs --install-executable <from> -o <to>"
            exitFailure

{-
  Generate lib.js and lib1.js for the latest version of all installed
  packages

  fixme: make this variant-aware?
 -}

generateLib :: GhcjsSettings -> Ghc ()
generateLib settings = do
  dflags1 <- getSessionDynFlags
  liftIO $ do
    (dflags2, _) <- initPackages dflags1
    let pkgs =  map sourcePackageId . eltsUFM . pkgIdMap . pkgState $ dflags2
        base = getDataDir (getLibDir dflags2) </> "shims"
        convertPkg p = let PackageName n = pkgName p
                           v = map fromIntegral (versionBranch $ pkgVersion p)
                       in (T.pack n, v)
        pkgs' = M.toList $ M.fromListWith max (map convertPkg pkgs)
    (beforeFiles, afterFiles) <- Gen2.collectShims base pkgs'
    B.writeFile "lib.js"  . mconcat =<< mapM B.readFile beforeFiles
    B.writeFile "lib1.js" . mconcat =<< mapM B.readFile afterFiles
    putStrLn "generated lib.js and lib1.js for:"
    mapM_ (\(p,v) -> putStrLn $ "    " ++ T.unpack p ++
      if null v then "" else ("-" ++ L.intercalate "." (map show v))) pkgs'

setGhcjsSuffixes :: Bool     -- oneshot option, -c
                 -> DynFlags
                 -> DynFlags
setGhcjsSuffixes oneshot df = df
    { objectSuf     = mkGhcjsSuf (objectSuf df)
    , dynObjectSuf  = mkGhcjsSuf (dynObjectSuf df)
    , hiSuf         = mkGhcjsSuf (hiSuf df)
    , dynHiSuf      = mkGhcjsSuf (dynHiSuf df)
    , outputFile    = fmap mkGhcjsOutput (outputFile df)
    , dynOutputFile = fmap mkGhcjsOutput (dynOutputFile df)
    , outputHi      = fmap mkGhcjsOutput (outputHi df)
    , ghcLink       = if oneshot then NoLink else ghcLink df
    }


-- | make sure we don't show panic messages with the "report GHC bug" text, since
--   those are probably our fault.
ghcjsErrorHandler :: (ExceptionMonad m, MonadIO m)
                    => FatalMessager -> FlushOut -> m a -> m a
ghcjsErrorHandler fm (FlushOut flushOut) inner =
  -- top-level exception handler: any unrecognised exception is a compiler bug.
  ghandle (\exception -> liftIO $ do
           flushOut
           case fromException exception of
                -- an IO exception probably isn't our fault, so don't panic
                Just (ioe :: IOException) ->
                  fatalErrorMsg'' fm (show ioe)
                _ -> case fromException exception of
                     Just UserInterrupt ->
                         -- Important to let this one propagate out so our
                         -- calling process knows we were interrupted by ^C
                         liftIO $ throwIO UserInterrupt
                     Just StackOverflow ->
                         fatalErrorMsg'' fm "stack overflow: use +RTS -K<size> to increase it"
                     _ -> case fromException exception of
                          Just (ex :: ExitCode) -> liftIO $ throwIO ex
                          _ -> case fromException exception of
                               -- don't panic!
                               Just (Panic str) -> fatalErrorMsg'' fm str
                               _                -> fatalErrorMsg'' fm (show exception)
           exitWith (ExitFailure 1)
         ) $

  -- error messages propagated as exceptions
  handleGhcException
            (\ge -> liftIO $ do
                flushOut
                case ge of
                     PhaseFailed _ code -> exitWith code
                     Signal _ -> exitWith (ExitFailure 1)
                     _ -> do fatalErrorMsg'' fm (show ge)
                             exitWith (ExitFailure 1)
            ) $
  inner

sourceErrorHandler :: GhcMonad m => m a -> m a
sourceErrorHandler m = handleSourceError (\e -> do
  GHC.printException e
  liftIO $ exitWith (ExitFailure 1)) m

runGhcjsSession :: Maybe FilePath  -- ^ Directory with library files,
                   -- like GHC's -B argument
                -> GhcjsSettings
                -> Ghc b           -- ^ Action to perform
                -> IO b
runGhcjsSession mbMinusB settings m = runGhc mbMinusB $ do
    dflags <- getSessionDynFlags
    let base = getLibDir dflags
    jsEnv <- liftIO newGhcjsEnv
    _ <- setSessionDynFlags
         $ setGhcjsPlatform settings jsEnv [] base
         $ updateWays $ addWay' (WayCustom "js")
         $ setGhcjsSuffixes False dflags
    fixNameCache
    m


setSessionDynFlags :: GhcMonad m => DynFlags -> m [PackageId]
setSessionDynFlags dflags = do
  (dflags', preload) <- liftIO $ initPackages dflags -- this is Gen2.GHC.Packages.initPackages
  modifySession $ \h -> h{ hsc_dflags = dflags'
                         , hsc_IC = (hsc_IC h){ ic_dflags = dflags' } }
  invalidateModSummaryCache
  return preload

invalidateModSummaryCache :: GhcMonad m => m ()
invalidateModSummaryCache =
  modifySession $ \h -> h { hsc_mod_graph = map inval (hsc_mod_graph h) }
 where
  inval ms = ms { ms_hs_date = addUTCTime (-1) (ms_hs_date ms) }

{-|
  get the command line arguments for GHCJS by adding the ones specified in the
  ghcjs.exe.options file on Windows, since we cannot run wrapper scripts there

  also handles some location information queries for Setup.hs and ghcjs-boot,
  that would otherwise fail due to missing boot libraries or a wrapper interfering
 -}
getWrappedArgs :: IO ([String], Bool, Bool)
getWrappedArgs = do
  booting  <- getEnvOpt "GHCJS_BOOTING"        -- do not check that we're booted
  booting1 <- getEnvOpt "GHCJS_BOOTING_STAGE1" -- enable GHC fallback
  as <- getArgs
  if | "--ghcjs-setup-print"   `elem` as -> printBootInfo as >> exitSuccess
     | "--ghcjs-booting-print" `elem` as -> getFullArguments >>= printBootInfo >> exitSuccess
     | otherwise                         -> do
        fas <- getFullArguments
        when (isNothing  $ getArgsTopDir fas) (error noTopDirErrorMsg)
        return (fas, booting, booting1)

printBootInfo :: [String] -> IO ()
printBootInfo v
  | "--print-topdir"         `elem` v = putStrLn t
  | "--print-libdir"         `elem` v = putStrLn t
  | "--print-global-db"      `elem` v = putStrLn (getGlobalPackageDB t)
  | "--print-user-db-dir"    `elem` v = putStrLn . fromMaybe "<none>" =<< getUserPackageDir
  | "--print-default-libdir" `elem` v = putStrLn =<< getDefaultLibDir
  | "--print-default-topdir" `elem` v = putStrLn =<< getDefaultTopDir
  | "--print-native-too"     `elem` v = print ("--native-too" `elem` v)
  | "--numeric-ghc-version"  `elem` v = putStrLn getGhcCompilerVersion
  | "--print-rts-profiled"   `elem` v = print rtsIsProfiled
  | otherwise                         = error "no --ghcjs-setup-print or --ghcjs-booting-print options found"
  where
    t = fromMaybe (error noTopDirErrorMsg) (getArgsTopDir v)

noTopDirErrorMsg :: String
noTopDirErrorMsg = "Cannot determine library directory.\n\nGHCJS requires a -B argument to specify the library directory. " ++
#ifdef WINDOWS
                   "On Windows, GHCJS reads the `ghcjs.exe.options' and `ghcjs-[version].exe.options' files from the " ++
                   "program directory for extra command line arguments."
#else
                   "Usually this argument is provided added by a shell script wrapper. Verify that you are not accidentally " ++
                   "invoking the executable directly."
#endif

getArgsTopDir :: [String] -> Maybe String
getArgsTopDir xs
  | null minusB_args = Nothing
  | otherwise        = Just (drop 2 $ last minusB_args)
  where
    minusB_args = filter ("-B" `isPrefixOf`) xs

