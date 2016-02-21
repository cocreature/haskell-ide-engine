{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Main where

import           Control.Concurrent hiding (yield)
import           Control.Exception.Base hiding (catch)
import           Control.Lens
import           Control.Monad.Catch
import           Control.Monad.Random
import           Control.Monad.State
import qualified Control.Monad.State.Strict as SS
import           Data.Aeson
import qualified Data.Map as M
import           Data.Maybe
import qualified Data.Text as T
import           Data.Time.Clock
import           Haskell.Ide.Engine.Manager.Options
import           Haskell.Ide.Engine.PluginTypes
import           Haskell.Ide.Engine.Transport.Pipes
import           Haskell.Ide.Engine.Types
import qualified Language.Haskell.GhcMod.PathsAndFiles as GMod
import           Options.Applicative
import           Pipes
import qualified Pipes.Aeson as PAe
import qualified Pipes.ByteString as PB
import           Pipes.Concurrent
import           Pipes.Network.TCP.Safe hiding (send)
import qualified Pipes.Prelude as P
import           System.FilePath
import           System.IO (Handle)
import           System.Process

data Process =
  Process {processIn :: Output WireRequest}

type CabalFile = FilePath

data HieState =
  HieState {_stateTCP :: Int
           ,_stateCabalProcessCache :: M.Map CabalFile Process -- map projects to the corresponding processes
           ,_stateFileProcessCache :: M.Map FilePath Process -- map files to the corresponding process for efficiency reasons
           }

makeLenses ''HieState

main :: IO ()
main =
  do opts <- execParser optsParser
     (output,input,seal) <- spawn' unbounded
     runSafeT $
       serve "localhost" (show (port opts)) $
       \(socket,_addr) ->
         do putStrLn "serving"
            _ <- forkIO $ sendOutput socket input seal
            gen <- newStdGen
            flip evalRandT gen $ flip evalStateT (HieState (port opts + 1) M.empty M.empty) $
              parseInput socket output seal
  where optsParser =
          info (helper <*> managerOpts)
               (fullDesc <> progDesc "Manage multiple hie sessions" <>
                header "hie-manager - manager for hie sessions")

sendOutput :: (MonadIO m) => Socket -> Input Value -> STM () -> m ()
sendOutput socket input _seal =
  runEffect $ fromInput input >-> serializePipe >-> toSocket socket

parseInput :: (MonadIO m,MonadState HieState m, MonadRandom m) => Socket -> Output Value -> STM () -> m ()
parseInput socket output _seal =
  runEffect $
  parseFrames producer >-> filterErrors output >-> requestDispatcher output
  where producer = fromSocket socket 4096

filterErrors
  :: (MonadIO m, FromJSON a)
  => Output Value
  -> Pipe (Either PAe.DecodingError a) a m ()
filterErrors out =
  P.chain (\case
             Right _ -> pure ()
             Left err ->
               void . liftIO . atomically . (send out) . toJSON . channelToWire $
               (CResp "" 0 $
                IdeResponseError (IdeError ParseError (T.pack $ show err) Null))) >->
  rights

rights :: (Monad m) => Pipe (Either a b) b m ()
rights =
  do x <- await
     case x of
       Left _ -> pure ()
       Right x' -> yield x'
     rights

requestDispatcher :: (MonadIO m,MonadState HieState m,MonadRandom m) => Output Value -> Consumer WireRequest m ()
requestDispatcher = P.mapM_ . dispatchRequest

type Port = Int

dispatchRequest :: (MonadIO m, MonadState HieState m,MonadRandom m) => Output Value -> WireRequest -> m ()
dispatchRequest out (WireReq cmd' params') =
  do liftIO $ putStrLn $ "dispatching request " <> show params'
     case M.lookup "file" params' of
       Nothing ->
         void . liftIO . atomically . (send out) . toJSON . channelToWire $
         (CResp "" 0 $
          IdeResponseError (IdeError MissingParameter "Need a file parameter" Null))
       Just (ParamFileP file) ->
         do let filePath = T.unpack file
            cache <- gets _stateFileProcessCache
            case M.lookup filePath cache of
              Nothing ->
                do cabalFile <-
                     liftIO $
                     fmap (fromMaybe "") $ -- empty string means no cabal project
                     GMod.findCabalFile (takeDirectory filePath)
                   cabalCache <- gets _stateCabalProcessCache
                   case M.lookup cabalFile cabalCache of
                     Nothing ->
                       do liftIO $ putStrLn "starting new process"
                          (processOut,_seal) <- startProcess out filePath
                          stateFileProcessCache %=
                            M.insert filePath (Process processOut)
                          stateCabalProcessCache %=
                            M.insert cabalFile (Process processOut)
                          void . liftIO . atomically . (send processOut) $
                            WireReq cmd' params'
                     Just process@(Process processOut) ->
                       do stateCabalProcessCache %= M.insert filePath process
                          void . liftIO . atomically . (send processOut) $
                            WireReq cmd' params'
              Just (Process processOut) ->
                void . liftIO . atomically . (send processOut) $
                WireReq cmd' params'
       Just _ -> error "TODO: wrong parametertype"

startProcess :: (MonadIO m,MonadRandom m) => Output Value -> FilePath -> m (Output WireRequest,STM ())
startProcess out file =
  do (procOut,procIn,procSeal) <- liftIO (spawn' unbounded)
     initialPort <- getRandomR (1024,65535)
     _ <- liftIO $ forkIO (sessionProcess initialPort out file procIn)
     pure (procOut,procSeal)

sessionProcess :: Port -> Output Value -> FilePath -> Input WireRequest -> IO ()
sessionProcess initialPort valOut file wireIn =
  do (_stdin,Just stdout,Just stderr,_processHandle) <-
       createProcess
         ((proc "hie" ["--tcp","--tcp-port",show initialPort,"-r",root]) {std_in =
                                                                            Inherit
                                                                         ,std_out =
                                                                            CreatePipe
                                                                         ,std_err =
                                                                            CreatePipe})
     do tcpParse <-
          SS.evalStateT PAe.decode
                        (PB.fromHandle stdout)
        case tcpParse of
          Nothing -> error "no input"
          Just (Left err) -> error $ "couldn’t parse tcp error" ++ show err
          Just (Right (TCP parsedPort)) ->
            do
               -- TODO: debug output, nothing should ever be sent here
               _ <-
                 forkIO $
                 runEffect $
                 PB.fromHandle stdout >-> P.map ("stdout: " <>) >-> PB.stdout
               _ <-
                 forkIO $
                 runEffect $
                 PB.fromHandle stderr >-> P.map ("stderr: " <>) >-> PB.stdout
               runSafeT $
                 retryFor (secondsToDiffTime 5)
                          100000
                          (connect "127.0.0.1" parsedPort $
                           \(socket,_addr) ->
                             do let producer = fromSocket socket 4096
                                    consumer = toSocket socket
                                let filterResponses
                                      :: (MonadIO m)
                                      => Pipe (Either PAe.DecodingError WireResponse) WireResponse m ()
                                    filterResponses = filterErrors valOut
                                _ <-
                                  liftIO $
                                  forkIO $
                                  runEffect $
                                  parseFrames (producer) >-> filterResponses >->
                                  P.map toJSON >->
                                  toOutput valOut
                                runEffect $
                                  fromInput wireIn >-> P.map toJSON >->
                                  serializePipe >->
                                  consumer)
  where root = takeDirectory file

dumpHandle :: PB.ByteString -> Handle -> IO ()
dumpHandle prefix h = runEffect $ PB.fromHandle h >-> P.map (prefix <>) >-> PB.stdout

data TCP = TCP {tcpPort :: String} deriving (Show)

instance FromJSON TCP where
  parseJSON =
    withObject "TCP"
               (\o -> TCP <$> (o .: "tcp" >>= (.: "port")))

-- | for how long, interval
retryFor :: (MonadIO m, MonadCatch m) => DiffTime -> Int -> m r -> m r
retryFor sleep interval act =
  do start <- liftIO getCurrentTime
     go start
  where go t =
          act `catch`
          (\(e :: IOException) ->
             do now <- liftIO getCurrentTime
                liftIO (putStrLn "catched an exception")
                if realToFrac (now `diffUTCTime` t) >= sleep
                   then throwM e
                   else liftIO (putStrLn "retrying") >>
                        liftIO (threadDelay interval) >> go t)
