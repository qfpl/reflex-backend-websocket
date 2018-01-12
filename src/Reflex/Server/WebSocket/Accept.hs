{-|
Copyright   : (c) 2018, Commonwealth Scientific and Industrial Research Organisation
License     : BSD3
Maintainer  : dave.laing.80@gmail.com
Stability   : experimental
Portability : non-portable
-}
{-# LANGUAGE FlexibleContexts #-}
module Reflex.Server.WebSocket.Accept (
    accept
  ) where

import Control.Exception (catch, displayException)

import Control.Monad.Fix (MonadFix)
import Control.Monad.Trans (MonadIO(..))

import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as BC

import Network.WebSockets

import Reflex

import Reflex.Binary

import Reflex.Server.WebSocket.Socket
import Reflex.Server.WebSocket.Internal

accept :: ( MonadHold t m
            , TriggerEvent t m
            , PerformEvent t m
            , PostBuild t m
            , MonadIO (Performable m)
            , MonadIO m
            , MonadFix m
            , CanEncode a
            , CanDecode b
            )
         => WsData PendingConnection
         -> WebSocketConfig t a
         -> Event t ()
         -> m (WebSocket t b)
accept (WsData done pending) wsc eDone = do
  let
    handleAcceptEx :: HandshakeException -> IO (Either String Connection)
    handleAcceptEx =
      pure . Left . displayException

    handleAccept :: IO (Either String Connection)
    handleAccept = do
      conn <- acceptRequest pending
      pure . Right $ conn

  eConn <- liftIO $ handleAccept `catch` handleAcceptEx
  case eConn of
    Left s -> do
      ePostBuild <- getPostBuild
      let ws = WebSocket never never ePostBuild ((False, 1001, BL.fromStrict . BC.pack $ s) <$ ePostBuild)
      liftIO done
      pure ws
    Right conn -> do
      ws <- webSocket conn wsc
      performEvent_ $ liftIO done <$ eDone
      pure ws
