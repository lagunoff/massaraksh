-- | Start and stop browser application
module HtmlT.Main where

import Control.Monad.Catch
import Control.Monad.Reader
import Data.IORef
import GHC.Generics
import HtmlT.DOM
import HtmlT.Event
import HtmlT.Types
import qualified HtmlT.HashMap as H

data StartOpts = StartOpts
  { startopts_finalizers :: Finalizers
  , startopts_subscriptions :: Subscriptions
  , startopts_root_element :: Node
  } deriving Generic

startWithOptions :: StartOpts -> Html a -> IO (a, HtmlEnv)
startWithOptions StartOpts{..} render = do
  postHooks <- liftIO (newIORef [])
  let
    htmlEnv = HtmlEnv
      { html_current_root = startopts_root_element
      , html_finalizers = startopts_finalizers
      , html_subscriptions = startopts_subscriptions
      , html_post_hooks = postHooks
      , html_catch_interactive = throwM
      }
  result <- runHtmlT htmlEnv render
  liftIO (readIORef postHooks >>= sequence_)
  onBeforeUnload do
    fins <- readIORef (unFinalizers startopts_finalizers)
    sequence_ fins
  pure (result, htmlEnv)

attachTo :: Node -> Html a -> IO (a, HtmlEnv)
attachTo rootEl render = do
  fins <- liftIO $ Finalizers <$> newIORef []
  subs <- liftIO $ Subscriptions <$> H.new
  startWithOptions (StartOpts fins subs rootEl) render

attachToBody :: Html a -> IO (a, HtmlEnv)
attachToBody h = getCurrentBody >>= (`attachTo` h)

detach :: HtmlEnv -> IO ()
detach HtmlEnv{..} = do
  fins <- readIORef (unFinalizers html_finalizers)
  sequence_ fins
  removeAllChilds html_current_root
