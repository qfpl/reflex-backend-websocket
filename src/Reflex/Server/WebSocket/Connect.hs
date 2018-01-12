{-|
Copyright   : (c) 2018, Commonwealth Scientific and Industrial Research Organisation
License     : BSD3
Maintainer  : dave.laing.80@gmail.com
Stability   : experimental
Portability : non-portable
-}
{-# LANGUAGE FlexibleContexts #-}
module Reflex.Server.WebSocket.Connect (
    connect
  ) where

import Control.Monad.Fix (MonadFix)
import Control.Monad.Trans (MonadIO(..))

import Network.WebSockets

import Reflex

import Reflex.Binary

import Reflex.Server.WebSocket.Socket
import Reflex.Server.WebSocket.Internal

connect :: ( MonadHold t m
             , TriggerEvent t m
             , PerformEvent t m
             , PostBuild t m
             , MonadIO (Performable m)
             , MonadIO m
             , MonadFix m
             , CanEncode a
             , CanDecode b
             )
          => WsData Connection
          -> WebSocketConfig t a
          -> m (WebSocket t b)
connect (WsData done conn) wsc = do
  ws <- webSocket conn wsc
  performEvent_ $ liftIO done <$ _wsClosed ws
  return ws
