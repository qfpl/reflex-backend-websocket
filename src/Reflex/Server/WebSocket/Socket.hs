{-|
Copyright   : (c) 2018, Commonwealth Scientific and Industrial Research Organisation
License     : BSD3
Maintainer  : dave.laing.80@gmail.com
Stability   : experimental
Portability : non-portable
-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE FlexibleContexts #-}
module Reflex.Server.WebSocket.Socket (
    WebSocketConfig(..)
  , WebSocket(..)
  , webSocket
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (void, when, forM_)
import Data.Word (Word16)

import Control.Exception (IOException, catch, displayException)

import Control.Monad.Trans (MonadIO(..))

import Control.Monad.STM
import Control.Concurrent.STM.TMVar
import Control.Concurrent.STM.TQueue

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as BC

import Network.WebSockets

import Reflex

import Reflex.Binary

data WebSocketConfig t a =
  WebSocketConfig {
    _wscSend       :: Event t [a]
  , _wscClose      :: Event t (Word16, BL.ByteString)
  }

data WebSocket t b =
  WebSocket {
    _wsReceive :: Event t b
  , _wsOpen    :: Event t ()
  , _wsError   :: Event t ()
  , _wsClosed  :: Event t (Bool, Word16, BL.ByteString)
  }

webSocket ::
  forall t m a b.
  ( Reflex t
  , PerformEvent t m
  , PostBuild t m
  , TriggerEvent t m
  , MonadIO (Performable m)
  , MonadIO m
  , CanEncode a
  , CanDecode b
  ) =>
  Connection ->
  WebSocketConfig t a ->
  m (WebSocket t b)
webSocket initSock (WebSocketConfig eTx eClose) = mdo
  (eRx, onRx) <- newTriggerEvent
  (eOpen, onOpen) <- newTriggerEvent
  (eError, onError) <- newTriggerEvent
  (eClosed, onClosed) <- newTriggerEvent

  payloadQueue <- liftIO newTQueueIO
  isOpenRead <- liftIO . atomically $ newEmptyTMVar
  isOpenWrite <- liftIO . atomically $ newEmptyTMVar

  let
    start = liftIO $ do
      void . atomically . tryPutTMVar isOpenRead $ initSock
      void . atomically . tryPutTMVar isOpenWrite $ initSock
      onOpen ()
      pure ()

  ePostBuild <- getPostBuild
  performEvent_ $ start <$ ePostBuild

  let
    exHandlerTx :: ConnectionException -> IO Bool
    exHandlerTx (CloseRequest code reason) = do
      mSock <- atomically . tryReadTMVar $ isOpenWrite
      forM_ mSock $ \_ -> do
        void . atomically $ tryTakeTMVar isOpenWrite
        onClosed (True, code, reason)
      pure False
    exHandlerTx e = do
      mSock <- atomically . tryReadTMVar $ isOpenWrite
      forM_ mSock $ \_ -> do
        void . atomically $ tryTakeTMVar isOpenWrite
        onError ()
        onClosed (False, 1001, BL.fromStrict . BC.pack . displayException $ e)
      pure False

    exHandlerTxIO :: IOException -> IO Bool
    exHandlerTxIO e = do
      mSock <- atomically . tryReadTMVar $ isOpenWrite
      forM_ mSock $ \_ -> do
        void . atomically $ tryTakeTMVar isOpenWrite
        onError ()
        onClosed (False, 1001, BL.fromStrict . BC.pack . displayException $ e)
      pure False

    txLoop = do
      mSock <- atomically . tryReadTMVar $ isOpenWrite
      forM_ mSock $ \sock -> do
        bs <- atomically . readTQueue $ payloadQueue
        success <-
          (sendBinaryData sock (doEncode bs) >> pure True) `catch` exHandlerTx `catch` exHandlerTxIO
        when success txLoop

    startTxLoop = liftIO $ do
      mSock <- atomically $ tryReadTMVar isOpenWrite
      forM_ mSock $ \_ -> void . forkIO $ txLoop

  performEvent_ $ ffor eTx $ \payloads -> liftIO $ forM_ payloads $
    atomically . writeTQueue payloadQueue

  performEvent_ $ startTxLoop <$ ePostBuild

  let
    exHandlerRx :: ConnectionException -> IO (Maybe B.ByteString)
    exHandlerRx (CloseRequest code reason) = do
      mSock <- atomically . tryReadTMVar $ isOpenRead
      forM_ mSock $ \_ -> do
        void . atomically $ tryTakeTMVar isOpenRead
        onClosed (True, code, reason)
      pure Nothing
    exHandlerRx e = do
      mSock <- atomically . tryReadTMVar $ isOpenRead
      forM_ mSock $ \_ -> do
        void . atomically . tryTakeTMVar $ isOpenRead
        onError ()
        onClosed (False, 1001, BL.fromStrict . BC.pack . displayException $ e)
      pure Nothing

    exHandlerRxIO :: IOException -> IO (Maybe B.ByteString)
    exHandlerRxIO e = do
      mSock <- atomically . tryReadTMVar $ isOpenRead
      forM_ mSock $ \_ -> do
        void . atomically . tryTakeTMVar $ isOpenRead
        onError ()
        onClosed (False, 1001, BL.fromStrict . BC.pack . displayException $ e)
      pure Nothing

    handlerRx :: IO (Maybe B.ByteString)
    handlerRx = do
      mSock <- atomically $ tryReadTMVar isOpenRead
      case mSock of
        Nothing -> pure Nothing
        Just sock -> do
          bs <- receiveData sock
          pure (Just bs)

    onDecodeError s = do
      onError ()
      onClosed (False, 1001, BL.fromStrict . BC.pack $ s)

    shutdownRx =
      void . atomically $ tryTakeTMVar isOpenRead

    rxLoop decoder = do
      mSock <- atomically $ tryReadTMVar isOpenRead
      forM_ mSock $ \_ -> do
        mbs <- handlerRx `catch` exHandlerRx `catch` exHandlerRxIO
        forM_ mbs $
          runIncrementalDecoder onDecodeError onRx (const shutdownRx) rxLoop decoder

    startRxLoop = liftIO $ do
      mSock <- atomically $ tryReadTMVar isOpenRead
      forM_ mSock $ const . void . forkIO . rxLoop $ getDecoder

  performEvent_ $ startRxLoop <$ ePostBuild

  let
    exHandlerClose :: ConnectionException -> IO ()
    exHandlerClose (CloseRequest code reason) = do
      onClosed (True, code, reason)
    exHandlerClose e = do
      onError ()
      onClosed (False, 1001, BL.fromStrict . BC.pack . displayException $ e)

    exHandlerCloseIO :: IOException -> IO ()
    exHandlerCloseIO e = do
      onError ()
      onClosed (False, 1001, BL.fromStrict . BC.pack . displayException $ e)

    handlerClose :: Word16 -> BL.ByteString -> IO ()
    handlerClose _ reason = do
      mSock <- atomically . tryReadTMVar $ isOpenWrite
      forM_ mSock $ \sock -> do
        sendClose sock reason

    closeFn (code, reason) = liftIO $ do
      void . atomically . tryTakeTMVar $ isOpenWrite
      void . atomically . tryTakeTMVar $ isOpenRead
      handlerClose code reason `catch` exHandlerClose `catch` exHandlerCloseIO

  performEvent_ $ closeFn <$> eClose

  pure $ WebSocket eRx eOpen eError eClosed
