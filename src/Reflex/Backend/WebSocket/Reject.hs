{-|
Copyright   : (c) 2018, Commonwealth Scientific and Industrial Research Organisation
License     : BSD3
Maintainer  : dave.laing.80@gmail.com
Stability   : experimental
Portability : non-portable
-}
{-# LANGUAGE FlexibleContexts #-}
module Reflex.Backend.WebSocket.Reject (
    reject
  ) where

import Control.Monad.Trans (MonadIO(..))

import qualified Data.ByteString as B

import Network.WebSockets

import Reflex

import Reflex.Backend.WebSocket.Internal

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

