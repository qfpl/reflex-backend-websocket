{-|
Copyright   : (c) Dave Laing, 2017
License     : BSD3
Maintainer  : dave.laing.80@gmail.com
Stability   : experimental
Portability : non-portable
-}
{-# LANGUAGE FlexibleContexts #-}
module Reflex.Server.WebSocket.ByteString (
    WebSocketConfig(..)
  , WebSocket(..)
  , WsData
  , reject
  , accept
  , connect
  , webSocket
  ) where

import Control.Monad.Trans (MonadIO)
import Control.Monad.Fix (MonadFix)

import qualified Data.ByteString as B

import Network.WebSockets

import Reflex

import Reflex.Server.WebSocket.Common
import Reflex.Server.WebSocket.Internal

bytestringTx :: MkTx B.ByteString
bytestringTx = MkTx id

bytestringRx :: MkRx B.ByteString
bytestringRx =
  let
    stepRx onError onClosed onRx bs _ = do
      onRx bs
      pure (Just ())
  in
    MkRx () stepRx

accept :: ( MonadHold t m
          , TriggerEvent t m
          , PerformEvent t m
          , PostBuild t m
          , MonadIO (Performable m)
          , MonadIO m
          , MonadFix m
          )
       => WsData PendingConnection
       -> WebSocketConfig t B.ByteString
       -> Event t ()
       -> m (WebSocket t B.ByteString)
accept =
  mkAccept bytestringTx bytestringRx

connect :: ( MonadHold t m
           , TriggerEvent t m
           , PerformEvent t m
           , PostBuild t m
           , MonadIO (Performable m)
           , MonadIO m
           , MonadFix m
           )
        => WsData Connection
        -> WebSocketConfig t B.ByteString
        -> m (WebSocket t B.ByteString)
connect =
  mkConnect bytestringTx bytestringRx

webSocket ::
  ( Reflex t
  , PerformEvent t m
  , PostBuild t m
  , TriggerEvent t m
  , MonadIO (Performable m)
  , MonadIO m
  ) =>
  Connection ->
  WebSocketConfig t B.ByteString ->
  m (WebSocket t B.ByteString)
webSocket =
  mkWebSocket bytestringTx bytestringRx
