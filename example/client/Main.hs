{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Monad (void)
import Control.Monad.Trans (liftIO)

import Network.WebSockets

import Control.Concurrent.STM

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC

import Data.Map (Map)
import qualified Data.Map as Map

import Reflex
import Reflex.Basic.Host

import Reflex.Server.WebSocket
import Reflex.Server.WebSocket.ByteString

import List

guest ::
  WsManager Connection ->
  IO()
guest wsm = basicHost $ mdo
  eIn <- wsData wsm

  dCount <- count eIn

  dMap <- foldDyn ($) Map.empty .
          mergeWith (.) $ [
            Map.insert <$> current dCount <@> eIn
          , flip (foldr Map.delete) <$> eRemoves
          ]

  dmeRemove <- list dMap $ \dv -> mdo
    wsd <- sample . current $ dv

    let
      eTx = [BC.pack "Hi"] <$ _wsOpen ws
      eClose = (\(_, w, b) -> (w, b)) <$> _wsClosed ws
      wsc = WebSocketConfig eTx eClose

    ws <- connect wsd wsc

    performEvent_ $ (liftIO . putStrLn $ "Open") <$ _wsOpen ws
    performEvent_ $ (liftIO . putStrLn . ("Rx: " ++) . show) <$> _wsReceive ws
    performEvent_ $ (liftIO . putStrLn . ("Tx: " ++) . show) <$> eTx
    performEvent_ $ (liftIO . putStrLn $ "Close") <$ eClose

    pure $ _wsClosed ws

  let
    eRemoves = fmap Map.keys . switch . current . fmap mergeMap $ dmeRemove

  pure ()

main :: IO ()
main = do
  wsm <- atomically $ mkWsManager 10
  guest wsm
  runClient "127.0.0.1" 9000 "" (handleConnection wsm)
