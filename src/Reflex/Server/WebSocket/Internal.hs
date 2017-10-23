{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Reflex.Server.WebSocket.Internal (
    MkTx(..)
  , MkRx(..)
  , reject
  , mkAccept
  , mkConnect
  , mkWebSocket
  , WsManager
  , mkWsManager
  , WsData
  , wsData
  , handleConnection
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (unless, when, forever, void)
import Data.Foldable (forM_, traverse_)

import Control.Exception (IOException, catch, displayException)

import Control.Monad.Trans (MonadIO(..))
import Control.Monad.Fix (MonadFix)

import Data.Hashable (Hashable(..))

import Control.Monad.STM
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TMVar
import Control.Concurrent.STM.TQueue
import Control.Concurrent.STM.TBQueue

import qualified Control.Concurrent.STM.Map as SM

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC

import Network.WebSockets

import Reflex

import Reflex.Server.WebSocket.Common

data MkTx a where
  MkTx :: (a -> B.ByteString) -> MkTx a

data MkRx b where
  MkRx :: c -> ((() -> IO ()) -> ((Bool, Word, B.ByteString) -> IO ()) -> (b -> IO ()) -> B.ByteString -> c -> IO (Maybe c)) -> MkRx b

reject :: ( PerformEvent t m
          , MonadIO (Performable m)
          )
       => Behavior t B.ByteString
       -> Event t (WsData PendingConnection)
       -> m ()
reject b e =
  let
    go r w = liftIO $ do
      rejectRequest (wsConnection w) r
      wsDone w
  in
    performEvent_ $ go <$> b <@> e

mkAccept :: ( MonadHold t m
            , TriggerEvent t m
            , PerformEvent t m
            , PostBuild t m
            , MonadIO (Performable m)
            , MonadIO m
            , MonadFix m
            )
         => MkTx a
         -> MkRx b
         -> WsData PendingConnection
         -> WebSocketConfig t a
         -> Event t ()
         -> m (WebSocket t b)
mkAccept mkTx mkRx (WsData done pending) wsc eDone = do
  conn <- liftIO $ acceptRequest pending
  ws <- mkWebSocket mkTx mkRx conn wsc
  performEvent_ $ liftIO done <$ eDone
  return ws

mkConnect :: ( MonadHold t m
             , TriggerEvent t m
             , PerformEvent t m
             , PostBuild t m
             , MonadIO (Performable m)
             , MonadIO m
             , MonadFix m
             )
          => MkTx a
          -> MkRx b
          -> WsData Connection
          -> WebSocketConfig t a
          -> m (WebSocket t b)
mkConnect mkTx mkRx (WsData done conn) wsc = do
  ws <- mkWebSocket mkTx mkRx conn wsc
  performEvent_ $ liftIO done <$ _wsClosed ws
  return ws

mkWebSocket ::
  forall t m a b.
  ( Reflex t
  , PerformEvent t m
  , PostBuild t m
  , TriggerEvent t m
  , MonadIO (Performable m)
  , MonadIO m
  ) =>
  MkTx a ->
  MkRx b ->
  Connection ->
  WebSocketConfig t a ->
  m (WebSocket t b)
mkWebSocket (MkTx encodeTx) (MkRx initRx stepRx) initSock (WebSocketConfig eTx eClose) = mdo
  (eRx, onRx) <- newTriggerEvent
  (eOpen, onOpen) <- newTriggerEvent
  (eError, onError) <- newTriggerEvent
  (eClosed, onClosed) <- newTriggerEvent

  payloadQueue <- liftIO newTQueueIO
  isOpen <- liftIO . atomically $ newEmptyTMVar

  let
    start = liftIO $ do
      atomically . tryPutTMVar isOpen $ initSock
      onOpen ()
      pure ()

  ePostBuild <- getPostBuild
  performEvent_ $ start <$ ePostBuild

  let
    exHandlerTx :: IOException -> IO Bool
    exHandlerTx e = do
      mSock <- atomically . tryReadTMVar $ isOpen
      forM_ mSock $ \_ -> do
        void . atomically $ tryTakeTMVar isOpen
        onError ()
        onClosed (False, 1001, BC.pack . displayException $ e)
      pure False

    txLoop = do
      mSock <- atomically . tryReadTMVar $ isOpen
      forM_ mSock $ \sock -> do
        bs <- atomically . readTQueue $ payloadQueue
        success <-
          (sendBinaryData sock (encodeTx bs) >> pure True) `catch` exHandlerTx
        when success txLoop

    startTxLoop = liftIO $ do
      mSock <- atomically $ tryReadTMVar isOpen
      forM_ mSock $ \_ -> void . forkIO $ txLoop

  performEvent_ $ ffor eTx $ \payloads -> liftIO $ forM_ payloads $
    atomically . writeTQueue payloadQueue

  performEvent_ $ startTxLoop <$ ePostBuild

  let
    exHandlerRx :: IOException -> IO (Maybe B.ByteString)
    exHandlerRx e = do
      mSock <- atomically . tryReadTMVar $ isOpen
      forM_ mSock $ \_ -> do
        onError ()
        onClosed (False, 1001, BC.pack . displayException $ e)
      pure Nothing

    handlerRx :: Connection -> IO (Maybe B.ByteString)
    handlerRx sock = do
      bs <- receiveData sock
      pure (Just bs)

    shutdownRx b code reason = do
      void . atomically $ tryTakeTMVar isOpen
      onClosed (b, code, reason)

    rxLoop decoder = do
      mSock <- atomically $ tryReadTMVar isOpen
      forM_ mSock $ \sock -> do
        mbs <- handlerRx sock `catch` exHandlerRx
        forM_ mbs $ \bs -> do
          mDecoder <- stepRx onError onClosed onRx bs decoder
          forM_ mDecoder $ rxLoop

    startRxLoop = liftIO $ do
      mSock <- atomically $ tryReadTMVar isOpen
      forM_ mSock $ \_ -> void . forkIO . rxLoop $ initRx

  performEvent_ $ startRxLoop <$ ePostBuild

  let
    exHandlerClose :: Word -> B.ByteString -> IOException -> IO ()
    exHandlerClose code reason e = do
      onError ()
      onClosed (False, 1001, BC.pack . displayException $ e)

    handlerClose :: Connection -> Word -> B.ByteString -> IO ()
    handlerClose sock code reason = do
      sendClose sock reason
      onClosed (True, code, reason)

    closeFn (code, reason) = liftIO $ do
      mSock <- atomically . tryReadTMVar $ isOpen
      forM_ mSock $ \sock -> do
        void . atomically . tryTakeTMVar $ isOpen
        handlerClose sock code reason `catch` exHandlerClose code reason

  performEvent_ $ closeFn <$> eClose

  pure $ WebSocket eRx eOpen eError eClosed

newtype Ticket = Ticket Int
  deriving (Eq, Ord, Show, Hashable)

data WsData a =
  WsData {
    wsDone :: IO ()
  , wsConnection :: a
  }

data WsManager a =
  WsManager (TVar Ticket) (TBQueue (WsData a)) (SM.Map Ticket ())

mkWsManager :: Int -> STM (WsManager a)
mkWsManager size =
  WsManager <$> newTVar (Ticket 0) <*> newTBQueue size <*> SM.empty

getTicket :: WsManager a -> STM Ticket
getTicket (WsManager tv _ _) = do
  Ticket t <- readTVar tv
  writeTVar tv $ Ticket (succ t)
  return $ Ticket t

sendData :: WsManager a -> WsData a -> STM ()
sendData (WsManager _ q _) =
  writeTBQueue q

waitForData :: WsManager a -> STM (WsData a)
waitForData (WsManager _ q _) =
  readTBQueue q

sendDone :: WsManager a -> Ticket -> STM ()
sendDone (WsManager _ _ m) t =
  SM.insert t () m

waitForDone :: WsManager a -> Ticket -> STM ()
waitForDone (WsManager _ _ m) t = do
  v <- SM.lookup t m
  case v of
    Just x -> do
      SM.delete t m
      return x
    Nothing ->
      retry

wsData ::
  ( TriggerEvent t m
  , MonadIO m
  ) =>
  WsManager a ->
  m (Event t (WsData a))
wsData wsm = do
  (eData, onData) <- newTriggerEvent

  void . liftIO . forkIO . forever $ do
    wsd <- atomically $ waitForData wsm
    onData wsd

  pure eData

handleConnection ::
  WsManager a ->
  a ->
  IO ()
handleConnection wsm a = do
  t <- atomically $ do
    t <- getTicket wsm
    sendData wsm $ WsData (atomically $ sendDone wsm t) a
    return t
  atomically $ waitForDone wsm t
