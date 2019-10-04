{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE LambdaCase   #-}

-- | Poprted from Miso
-- https://github.com/dmjio/miso/blob/acae5300c8b74398ff5333d38c36ae5cf64d01d3/src/Miso/Event/Decoder.hs
module Massaraksh.Decoder
  ( -- * Decoder
    Decoder (..)
  , DecodeTarget (..)
  , at
  -- * Decoders
  , emptyDecoder
  , keycodeDecoder
  , checkedDecoder
  , valueDecoder
  , runDecoder
  )
  where

import Data.Aeson.Types (withText, Value, Parser, withObject, (.:), parseEither)
import qualified Data.JSString.Text as JSS
import Control.Applicative
import Control.Monad (foldM)
import GHCJS.Types (JSVal)
import Data.JSString (JSString)
import Language.Javascript.JSaddle (valIsUndefined, js, fromJSVal, JSM)
import Control.Lens ((^.))
import GHCJS.Marshal ()

-- | Data type for storing the target when parsing events
data DecodeTarget
  = DecodeTarget [JSString] -- ^ Decode a single object

-- | Decoder data type for parsing events
data Decoder a = Decoder {
  decoder :: Value -> Parser a -- ^ FromJSON-based Event decoder
, decodeAt :: DecodeTarget -- ^ Location in DOM of where to decode
}

-- | Smart constructor for building
at :: [JSString] -> (Value -> Parser a) -> Decoder a
at decodeAt decoder = Decoder {decodeAt = DecodeTarget decodeAt, ..}

-- | Empty decoder for use with events like "click" that do not
-- return any meaningful values
emptyDecoder :: Decoder ()
emptyDecoder = mempty `at` go
  where
    go = withObject "emptyDecoder" $ \_ -> pure ()

-- | Retrieves either "keyCode", "which" or "charCode" field in `Decoder`
keycodeDecoder :: Decoder Int
keycodeDecoder = Decoder {..}
  where
    decodeAt = DecodeTarget mempty
    decoder = withObject "event" $ \o ->
       (o .: "keyCode" <|> o .: "which" <|> o .: "charCode")

-- | Retrieves "value" field in `Decoder`
valueDecoder :: Decoder JSString
valueDecoder = Decoder {..}
  where
    decodeAt = DecodeTarget ["target", "value"]
    decoder = withText "target.value" $ pure . JSS.textToJSString

-- | Retrieves "checked" field in Decoder
checkedDecoder :: Decoder Bool
checkedDecoder = Decoder {..}
  where
    decodeAt = DecodeTarget ["target"]
    decoder = withObject "target" $ \o ->
       (o .: "checked")

-- | Check JS values against decoder
runDecoder :: forall a. Decoder a -> JSVal -> JSM (Either String a)
runDecoder (Decoder parse (DecodeTarget target)) val =
  foldM go (Right val) target >>= checkValue where
    go (Left err)    key = pure $ Left err
    go (Right jsval) key = do
      jsval' <- val ^. js key
      isUndefined <- valIsUndefined jsval'
      pure $ if isUndefined then (Left "Undefined property ") else Right jsval'

    checkValue :: Either String JSVal -> JSM (Either String a)
    checkValue (Left err)    = pure $ Left err
    checkValue (Right jsval) = fromJSVal jsval >>= \case
      Just value -> pure $ parseEither parse value
      Nothing    -> pure $ Left "runDecoder: Cannot coerce JSVal to Data.Aeson.Value"
