{-# LANGUAGE OverloadedStrings #-}
module Haskell.Ide.Engine.Transport.JsonTcp where

import           Control.Concurrent
import           Control.Concurrent.STM.TChan
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.STM
import           Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as BS
import           Haskell.Ide.Engine.Transport.Pipes
import           Haskell.Ide.Engine.Types
import qualified Pipes as P
import           Pipes.Network.TCP.Safe

jsonTcpTransport :: Bool -> TChan ChannelRequest -> HostPreference -> ServiceName -> IO ()
jsonTcpTransport oneShot cin host service =
  do cout <- atomically $ newTChan :: IO (TChan ChannelResponse)
     runSafeT $
       listen host service $
       \(lsock,_addr) ->
         do -- TODO: Find a clean way to output this
            liftIO $ BS.putStrLn $ encode $ object ["tcp" .= object ["port" .= service]]
            forever $ acceptFork lsock $ \(socket,_addr) ->
              do let producer = fromSocket socket 4096
                     consumer = toSocket socket
                 _ <-
                   forkIO $
                   P.runEffect
                     (parseFrames producer P.>->
                      parseToJsonPipe oneShot cin cout 1)
                 P.runEffect
                   (tchanProducer oneShot cout P.>-> encodePipe P.>->
                    serializePipe P.>->
                    consumer)
