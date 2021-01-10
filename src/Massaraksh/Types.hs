{-# LANGUAGE NoOverloadedStrings #-}
{-# LANGUAGE CPP #-}
module Massaraksh.Types where

import Control.Applicative
import Control.Monad.Catch
import Control.Monad.Reader
import Data.IORef
import Data.String
import Data.Text as T
import GHC.Generics
import Language.Javascript.JSaddle
import Massaraksh.DOM
import Massaraksh.Event

newtype Html a = Html {unHtml :: ReaderT HtmlEnv IO a}
  deriving newtype
    ( Functor, Applicative, Monad, MonadIO, MonadReader HtmlEnv
    , MonadFix, MonadCatch, MonadThrow, MonadMask )

data HtmlEnv = HtmlEnv
  { htenvElement :: ElementRef
  , htenvSubscriber :: Subscriber
  , htenvPostBuild :: IORef [Html ()]
  , htenvJsContext :: JSContextRef
  , htenvCatchInteractive :: SomeException -> IO ()
  }
  deriving stock (Generic)

data ElementRef = ElementRef
  { elrfRead          :: IO Node
  , elrfQueueMutation :: (Node -> JSM ()) -> IO ()
  }

newtype Subscriber = Subscriber
  { unSubscriber :: forall a. Event a -> Callback a -> Reactive Canceller
  }

type Subscriptions = IORef [IORef (IO ())]

data Exist (f :: * -> *) = forall x. Exist (f x)

runHtml :: HtmlEnv -> Html x -> IO x
runHtml e = flip runReaderT e . unHtml
{-# INLINE runHtml #-}

instance Semigroup a => Semigroup (Html a) where
  (<>) = liftA2 (<>)

instance Monoid a => Monoid (Html a) where
  mempty = Html $ ReaderT \_ -> pure mempty

instance (x ~ ()) => IsString (Html x) where
  fromString = text . T.pack where
    text t = do
      elm <- liftIO =<< asks (elrfRead . htenvElement)
      textNode <- liftJSM (createTextNode t)
      liftJSM (appendChild elm textNode)

#ifndef ghcjs_HOST_OS
instance MonadJSM Html where
  liftJSM' jsm = Html $ ReaderT (runReaderT (unJSM jsm) . htenvJsContext)
#endif
