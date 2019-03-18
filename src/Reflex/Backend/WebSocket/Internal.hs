{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Reflex.Backend.WebSocket.Internal (
    WsManager(..)
  , mkWsManager
  , WsData(..)
  , wsData
  , handleConnection
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (forever, void)

import Control.Monad.Trans (MonadIO(..))

import Data.Hashable (Hashable(..))

import Control.Monad.STM
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TBQueue

import qualified Control.Concurrent.STM.Map as SM

import Reflex

-- deal with handshake exceptions in mkAccept and mkConnect

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
