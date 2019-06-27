{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import           Control.Concurrent (forkIO)
import           Control.Concurrent.STM
import           Control.Monad.Trans (liftIO)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import           Data.Functor (void)
import qualified Data.Map as Map
import           Network.WebSockets
import           Reflex
import           Reflex.Backend.WebSocket
import           Reflex.Host.Basic

guest ::
  WsManager Connection ->
  IO()
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
      eTx = [(BC.pack "Hi") :: B.ByteString] <$ _wsOpen ws
      eClose = (\(_, w, b) -> (w, b)) <$> _wsClosed ws
      wsc = WebSocketConfig eTx eClose

    ws <- connect wsd wsc

    performEvent_ $ (liftIO . putStrLn $ "Open") <$ _wsOpen ws
    performEvent_ $ (liftIO . putStrLn . ("Rx: " ++) . BC.unpack) <$> _wsReceive ws
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
  void . forkIO $ guest wsm
  runClient "127.0.0.1" 9000 "" (handleConnection wsm)
