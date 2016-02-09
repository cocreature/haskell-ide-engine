{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Main where

import           Control.Lens
import           Control.Monad.State
import           Data.Aeson
import qualified Data.Map as M
import qualified Data.Text as T
import           Haskell.Ide.Engine.Manager.Options
import           Haskell.Ide.Engine.PluginTypes
import           Haskell.Ide.Engine.Transport.Pipes
import           Haskell.Ide.Engine.Types
import           Options.Applicative
import           Pipes
import qualified Pipes.Aeson as PAe
import           Pipes.Concurrent
import           Pipes.Network.TCP.Safe hiding (send)
import qualified Pipes.Prelude as P

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
         do _ <- forkIO $ sendOutput socket input seal
            flip evalStateT (HieState (port opts + 1) M.empty) $
              parseInput socket output seal
  where optsParser =
          info (helper <*> managerOpts)
               (fullDesc <> progDesc "Manage multiple hie sessions" <>
                header "hie-manager - manager for hie sessions")

sendOutput :: (MonadIO m) => Socket -> Input Value -> STM () -> m ()
sendOutput socket input seal =
  runEffect $ fromInput input >-> serializePipe >-> toSocket socket

parseInput :: (MonadIO m,MonadState HieState m) => Socket -> Output Value -> STM () -> m ()
parseInput socket output seal =
  runEffect $
  parseFrames producer >-> filterErrors output >-> requestDispatcher output
  where producer = fromSocket socket 4096

filterErrors
  :: (MonadIO m)
  => Output Value
  -> Pipe (Either PAe.DecodingError WireRequest) WireRequest m ()
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

requestDispatcher :: (MonadIO m,MonadState HieState m) => Output Value -> Consumer WireRequest m ()
requestDispatcher = P.mapM_ . dispatchRequest

dispatchRequest :: (MonadIO m, MonadState HieState m) => Output Value -> WireRequest -> m ()
dispatchRequest out (WireReq cmd' params') =
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
             do (processOut,_seal) <- startProcess out
                stateProcessCache %=  (M.insert filePath (Process processOut))
                void . liftIO . atomically . (send processOut) $
                  WireReq cmd' params'
           Just x -> undefined

startProcess :: (MonadIO m) => Output Value -> m (Output WireRequest,STM ())
startProcess out =
  do (procOut,procIn,procSeal) <- liftIO (spawn' unbounded)
     liftIO $ forkIO (sessionProcess out procIn)
     pure (procOut,procSeal)

sessionProcess :: Output Value -> Input WireRequest -> IO ()
sessionProcess = undefined
