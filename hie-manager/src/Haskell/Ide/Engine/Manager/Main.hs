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
import qualified Data.Text as T
import           Data.Time.Clock
import           Haskell.Ide.Engine.Manager.Options
import           Haskell.Ide.Engine.PluginTypes
import           Haskell.Ide.Engine.Transport.Pipes
import           Haskell.Ide.Engine.Types
import           Options.Applicative
import           Pipes
import qualified Pipes.Aeson as PAe
import qualified Pipes.ByteString as PB
import           Pipes.Concurrent
import           Pipes.Network.TCP.Safe hiding (send)
import qualified Pipes.Prelude as P
import           System.FilePath
import           System.Process

data Process =
  Process {processIn :: Output WireRequest}

data HieState =
  HieState {_stateTCP :: Int
           ,_stateProcessCache :: M.Map FilePath Process}

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
            flip evalRandT gen $ flip evalStateT (HieState (port opts + 1) M.empty) $
              parseInput socket output seal
  where optsParser =
          info (helper <*> managerOpts)
               (fullDesc <> progDesc "Manage multiple hie sessions" <>
                header "hie-manager - manager for hie sessions")

sendOutput :: (MonadIO m) => Socket -> Input Value -> STM () -> m ()
sendOutput socket input seal =
  runEffect $ fromInput input >-> serializePipe >-> toSocket socket

parseInput :: (MonadIO m,MonadState HieState m, MonadRandom m) => Socket -> Output Value -> STM () -> m ()
parseInput socket output seal =
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
            cache <- gets _stateProcessCache
            case M.lookup filePath cache of
              Nothing ->
                do liftIO $ putStrLn "starting new process"
                   (processOut,_seal) <- startProcess out filePath
                   stateProcessCache %=
                     (M.insert filePath (Process processOut))
                   void . liftIO . atomically . (send processOut) $
                     WireReq cmd' params'
              Just (Process processOut) ->
                void . liftIO . atomically . (send processOut) $
                WireReq cmd' params'

startProcess :: (MonadIO m,MonadRandom m) => Output Value -> FilePath -> m (Output WireRequest,STM ())
startProcess out file =
  do (procOut,procIn,procSeal) <- liftIO (spawn' unbounded)
     port <- getRandomR (1024,65535)
     liftIO $ forkIO (sessionProcess port out file procIn)
     pure (procOut,procSeal)

sessionProcess :: Port -> Output Value -> FilePath -> Input WireRequest -> IO ()
sessionProcess port valOut file wireIn =
  do (_stdin,Just stdout,Just stderr,_processHandle) <-
       createProcess
         ((proc "hie" ["--tcp","--tcp-port",show port,"-r",root]) {std_in = Inherit
                                                                 ,std_out =
                                                                    CreatePipe
                                                                 ,std_err =
                                                                    CreatePipe})
     do tcpParse <-
          SS.evalStateT PAe.decode
                        (PB.fromHandle stdout)
        case tcpParse of
          Nothing -> error "no input"
          Just (Left err) -> error "couldn’t parse tcp error"
          Just (Right (TCP port)) ->
            do
               -- debug output, nothing should ever be sent here
               forkIO $
                 runEffect $
                 PB.fromHandle stdout >-> P.map ("stdout: " <>) >->
                 PB.stdout
               forkIO $
                 runEffect $
                 PB.fromHandle stderr >-> P.map ("stderr: " <>) >->
                 PB.stdout
               runSafeT $
                 retryFor (secondsToDiffTime 5)
                          100000
                          (connect "127.0.0.1" (show port) $
                           \(socket,addr) ->
                             do let producer = fromSocket socket 4096
                                    consumer = toSocket socket
                                let filterResponses
                                      :: (MonadIO m)
                                      => Pipe (Either PAe.DecodingError WireResponse) WireResponse m ()
                                    filterResponses = filterErrors valOut
                                liftIO $
                                  forkIO $
                                  runEffect $
                                  parseFrames (producer) >->
                                  filterResponses >->
                                  P.map toJSON >->
                                  toOutput valOut
                                runEffect $
                                  fromInput wireIn >-> P.map toJSON >->
                                  serializePipe >->
                                  consumer)
  where root = takeDirectory file

data TCP = TCP {tcpPort :: Int} deriving (Show)

instance FromJSON TCP where
  parseJSON =
    withObject "TCP"
               (\o -> TCP <$> (o .: "tcp" >>= (.: "port")))

-- | for how long, interval
retryFor :: (MonadIO m, MonadCatch m) => DiffTime -> Int -> m r -> m r
retryFor for interval act =
  do start <- liftIO getCurrentTime
     go start
  where go t =
          act `catch`
          (\(e :: IOException) ->
             do now <- liftIO getCurrentTime
                liftIO (putStrLn "catched an exception")
                if realToFrac (now `diffUTCTime` t) >= for
                   then throwM e
                   else liftIO (putStrLn "retrying") >>
                        liftIO (threadDelay interval) >> go t)
