{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import Control.Monad.Trans (liftIO)

import Network.WebSockets

import Control.Concurrent.STM

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC

import qualified Data.Map as Map

import Reflex
import Reflex.Host.Basic

import Reflex.Server.WebSocket

guest ::
  WsManager PendingConnection ->
  IO ()
guest wsm = basicHostForever $ mdo
  eIn <- wsData wsm
  dCount :: Dynamic t Int <- count eIn

  dMap <- foldDyn ($) Map.empty .
          mergeWith (.) $ [
            Map.insert <$> current dCount <@> eIn
          , flip (foldr Map.delete) <$> eRemoves
          ]

  dmeRemove <- list dMap $ \dv -> mdo
    wsd <- sample . current $ dv

    let
      eRx = _wsReceive ws
      f c r = B.append (BC.pack . show $ c) r
      eTx = (\c r -> pure $ f c r) <$> current dCount <@> eRx
      eClose = (\(_, w, b) -> (w, b)) <$> _wsClosed ws
      wsc = WebSocketConfig eTx eClose

    ws <- accept wsd wsc never

    performEvent_ $ (liftIO . putStrLn $ "Open") <$ _wsOpen ws
    performEvent_ $ (liftIO . putStrLn . ("Rx: " ++) . show) <$> _wsReceive ws
    performEvent_ $ (liftIO . putStrLn . ("Closed: " ++). show) <$> _wsClosed ws
    performEvent_ $ (liftIO . putStrLn . ("Tx: " ++) . show) <$> eTx
    performEvent_ $ (liftIO . putStrLn . ("Close: " ++). show) <$> eClose

    pure $ _wsClosed ws

  let
    eRemoves = fmap Map.keys . switch . current . fmap mergeMap $ dmeRemove

  pure ()

main :: IO ()
main = do
  wsm <- atomically $ mkWsManager 10
  guest wsm
  runServer "127.0.0.1" 9000 (handleConnection wsm)
