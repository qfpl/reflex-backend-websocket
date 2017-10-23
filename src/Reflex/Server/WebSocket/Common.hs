{-# LANGUAGE TemplateHaskell #-}
module Reflex.Server.WebSocket.Common (
    WebSocketConfig(..)
  , wscSend
  , wscClose
  , WebSocket(..)
  , wsReceive
  , wsOpen
  , wsError
  , wsClosed
  ) where

import Control.Lens

import qualified Data.ByteString as B

import Reflex

data WebSocketConfig t a =
  WebSocketConfig {
    _wscSend       :: Event t [a]
  , _wscClose      :: Event t (Word, B.ByteString)
  }

makeLenses ''WebSocketConfig

data WebSocket t b =
  WebSocket {
    _wsReceive :: Event t b
  , _wsOpen    :: Event t ()
  , _wsError   :: Event t ()
  , _wsClosed  :: Event t (Bool, Word, B.ByteString)
  }

makeLenses ''WebSocket

