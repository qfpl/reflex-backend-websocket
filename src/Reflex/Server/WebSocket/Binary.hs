{-|
Copyright   : (c) Dave Laing, 2017
License     : BSD3
Maintainer  : dave.laing.80@gmail.com
Stability   : experimental
Portability : non-portable
-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
module Reflex.Server.WebSocket.Binary (
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
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as BC

import Data.Binary
import Data.Binary.Get

import Network.WebSockets

import Reflex

import Reflex.Server.WebSocket.Common
import Reflex.Server.WebSocket.Internal

binaryTx :: Binary a => MkTx a
binaryTx = MkTx (BL.toStrict . encode)

binaryRx :: forall b. Binary b => MkRx b
binaryRx =
  let
    initRx = runGetIncremental (get :: Get b)

    handleDecoding onError onClosed _ (Fail _ _ s) = do
      onError ()
      onClosed (False, 1001, BL.fromStrict . BC.pack $ s)
      pure Nothing
    handleDecoding _ _ _ (Partial f) =
      pure . Just $ Partial f
    handleDecoding onError onClosed onRx (Done bs _ a) = do
      onRx a
      let decoder = initRx
      if B.null bs
      then pure . Just $ decoder
      else stepRx onError onClosed onRx bs decoder

    stepRx onError onClosed onRx bs decoder =
      handleDecoding onError onClosed onRx $ pushChunk decoder bs
  in
    MkRx initRx stepRx

accept :: ( MonadHold t m
          , TriggerEvent t m
          , PerformEvent t m
          , PostBuild t m
          , MonadIO (Performable m)
          , MonadIO m
          , MonadFix m
           , Binary a
           , Binary b
          )
       => WsData PendingConnection
       -> WebSocketConfig t a
       -> Event t ()
       -> m (WebSocket t b)
accept =
  mkAccept binaryTx binaryRx

connect :: ( MonadHold t m
           , TriggerEvent t m
           , PerformEvent t m
           , PostBuild t m
           , MonadIO (Performable m)
           , MonadIO m
           , MonadFix m
           , Binary a
           , Binary b
           )
        => WsData Connection
        -> WebSocketConfig t a
        -> m (WebSocket t b)
connect =
  mkConnect binaryTx binaryRx

webSocket ::
  forall t m a b.
  ( Reflex t
  , PerformEvent t m
  , PostBuild t m
  , TriggerEvent t m
  , MonadIO (Performable m)
  , MonadIO m
  , Binary a
  , Binary b
  ) =>
  Connection ->
  WebSocketConfig t a ->
  m (WebSocket t b)
webSocket =
  mkWebSocket binaryTx binaryRx
