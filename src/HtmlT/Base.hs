module HtmlT.Base where

import Control.Exception
import Control.Lens hiding ((#))
import Control.Monad.Reader
import Data.Coerce
import Data.Default
import Data.Foldable
import Data.IORef
import Data.JSString.Text as JSS
import Data.List as L
import Data.Text as T hiding (index)
import GHC.Generics
import Language.Javascript.JSaddle as JS

import HtmlT.DOM
import HtmlT.Decode
import HtmlT.Event
import HtmlT.Internal
import HtmlT.Types

el :: Text -> HtmlT x -> HtmlT x
el tag child = do
  newRootEl <- liftJSM (createElement tag)
  withRootNode newRootEl child

el' :: Text -> HtmlT x -> HtmlT Node
el' tag child = do
  newRootEl <- liftJSM (createElement tag)
  newRootEl <$ withRootNode newRootEl child

elns :: Text -> Text -> HtmlT x -> HtmlT x
elns ns tag child = do
  newRootEl <- liftJSM (createElementNS ns tag)
  withRootNode newRootEl child

text :: Text -> HtmlT ()
text txt = do
  textNode <- liftJSM (createTextNode txt)
  mutateRoot (flip appendChild textNode)

dynText :: Dynamic Text -> HtmlT ()
dynText d = do
  txt <- readDyn d
  js <- askJSM
  textNode <- liftJSM (createTextNode txt)
  forUpdates d \new -> void $ liftIO do
    flip runJSM js $ setTextValue textNode new
  mutateRoot (flip appendChild textNode)

prop :: ToJSVal v => Text -> v -> HtmlT ()
prop (JSS.textToJSString -> key) val = mutateRoot \rootEl -> do
  v <- toJSVal val
  unsafeSetProp key v (coerce rootEl)

dynProp :: (ToJSVal v, FromJSVal v, Eq v) => Text -> Dynamic v -> HtmlT ()
dynProp (JSS.textToJSString -> key) dyn = do
  mutate <- askMutateRoot
  let
    setup txt rootEl = toJSVal txt
      >>= flip (unsafeSetProp key) (coerce rootEl)
  void $ forDyn dyn (liftIO . mutate . setup)

attr :: Text -> Text -> HtmlT ()
attr k v = mutateRoot \e -> setAttribute e k v

dynAttr :: Text -> Dynamic Text -> HtmlT ()
dynAttr k d = do
  mutate <- askMutateRoot
  let setup v e = setAttribute e k v
  void $ forDyn d (liftIO . mutate . setup)

on :: Text -> Decoder (HtmlT x) -> HtmlT ()
on name decoder = do
  env <- ask
  mutateRoot \rootEl ->
    liftIO $ runHtmlT env $ domEvent rootEl name decoder

on_ :: Text -> HtmlT x -> HtmlT ()
on_ name w = on name (pure w)

domEventOpts :: ListenerOpts -> Node -> Text -> Decoder (HtmlT x) -> HtmlT ()
domEventOpts opts elm name decoder = do
  env <- ask
  js <- askJSM
  let
    event :: Event (HtmlT ())
    event = Event \s k -> liftIO $ flip runJSM js do
      unlisten <- addListener opts elm name \event -> do
        e <- runDecoder decoder event
        maybe blank (void . liftIO . sync . k . void) e
      pure $ liftIO $ runJSM unlisten js
  void $ subscribeHtmlT event (liftIO . runHtmlT env)

domEvent :: Node -> Text -> Decoder (HtmlT x) -> HtmlT ()
domEvent = domEventOpts def

domEvent_ :: Node -> Text -> HtmlT x -> HtmlT ()
domEvent_ e n act = domEvent e n (pure act)

classes :: Text -> HtmlT ()
classes cs = mutateRoot \rootEl -> do
  for_ (T.splitOn (T.pack " ") cs) $
    classListAdd rootEl

toggleClass :: Text -> Dynamic Bool -> HtmlT ()
toggleClass cs dyn = do
  mutate <- askMutateRoot
  let
    setup cs enable rootEl = case enable of
      True  -> classListAdd rootEl cs
      False -> classListRemove rootEl cs
  void $ forDyn dyn (liftIO . mutate . setup cs)

toggleAttr :: Text -> Dynamic Bool -> HtmlT ()
toggleAttr att dyn = do
  mutate <- askMutateRoot
  let
    setup name enable rootEl = case enable of
      True -> setAttribute rootEl name (T.pack "on")
      False -> removeAttribute rootEl name
  void $ forDyn dyn (liftIO . mutate . setup att)

blank :: Applicative m => m ()
blank = pure ()

data ElemEnv a = ElemEnv
  { ee_htmlEnv :: HtmlEnv
  , ee_Ref :: DynRef a
  , ee_modifier :: Modifier a
  }
  deriving stock Generic

itraverseHtml
  :: forall s a
  . IndexedTraversal' Int s a
  -> DynRef s
  -> (Int -> DynRef a -> HtmlT ())
  -> HtmlT ()
itraverseHtml l dynRef h = do
  hte <- ask
  js <- askJSM
  rootEl <- askRootNode
  s <- readRef dynRef
  itemRefs <- liftIO (newIORef [])
  let
    -- FIXME: 'setup' should return new contents for 'itemRefs'
    setup :: s -> Int -> [ElemEnv a] -> [a] -> [a] -> IO ()
    setup s idx refs old new = case (refs, old, new) of
      (_, [], [])    -> pure ()
      ([], [], x:xs) -> mdo
        -- New list is longer, append new elements
        subscriptions <- newIORef []
        elemRef <- newRef x
        postRef <- liftIO (newIORef [])
        let
          elemRef' = elemRef {dr_modifier=mkModifier idx (fromRef elemRef)}
          newEnv = hte
            { he_finalizers = subscriptions
            , he_post_hooks = postRef }
          itemRef = ElemEnv newEnv elemRef' (dr_modifier elemRef)
        runHtmlT newEnv $ h idx elemRef'
        liftIO (modifyIORef itemRefs (<> [itemRef]))
        setup s (idx + 1) [] [] xs
      (_, x:xs, []) -> do
        -- New list is shorter, delete the elements that no longer
        -- present in the new list
        itemRefsValue <- liftIO (readIORef itemRefs)
        let (newRefs, tailRefs) = L.splitAt idx itemRefsValue
        unsub tailRefs
        childEl <- flip runJSM js $ getChildNode rootEl idx
        flip runJSM js (removeChild rootEl childEl)
        liftIO (writeIORef itemRefs newRefs)
      (r:rs, x:xs, y:ys) -> do
        -- Update child elemens along the way
        liftIO $ sync $ ee_modifier r \_ -> y
        setup s (idx + 1) rs xs ys
      (_, _, _) -> do
        error "itraverseHtml: Incoherent internal state"

    unsub = traverse_ \ElemEnv{..} -> do
      subscriptions <- liftIO . readIORef . he_finalizers $ ee_htmlEnv
      liftIO $ for_ subscriptions (readIORef >=> id)

    mkModifier :: Int -> Dynamic a -> (a -> a) -> Reactive ()
    mkModifier idx dyn f = do
      oldA <- readDyn dyn
      dr_modifier dynRef \oldS ->
        oldS & iover l \i x -> if i == idx then f oldA else x
  liftIO $ setup s 0 [] [] (toListOf l s)
  addFinalizer $ readIORef itemRefs >>= unsub
  let eUpdates = withOld s (dynamic_updates $ fromRef dynRef)
  subscribeHtmlT eUpdates \(old, new) -> do
    refs <- liftIO (readIORef itemRefs)
    liftIO $ setup new 0 refs (toListOf l old) (toListOf l new)
  pure ()

dyn_ :: Dynamic (HtmlT ()) -> HtmlT ()
dyn_ dyn = do
  env <- ask
  js <- askJSM
  childRef <- liftIO (newIORef Nothing)
  mutate <- askMutateRoot
  let
    unsub newEnv = do
      oldEnv <- readIORef childRef
      for_ oldEnv \HtmlEnv{..} -> do
        subs <- readIORef he_finalizers
        for_ subs (readIORef >=> id)
        writeIORef he_finalizers []
      writeIORef childRef newEnv
    setup html rootEl = liftIO do
      postHooks <- newIORef []
      subscriptions <- newIORef []
      (elmRef, flush) <- deferMutations (he_current_root env)
      let
        newEnv = env
          { he_finalizers = subscriptions
          , he_post_hooks = postHooks
          , he_current_root = elmRef }
        triggerPost = runHtmlT newEnv . sequence_
          =<< readIORef postHooks
        commit = do
          unsub (Just newEnv)
            <* removeAllChilds env
            <* flush
            <* triggerPost
      runHtmlT newEnv html <* commit
    removeAllChilds env = mutate \rootEl -> do
      length <- childLength rootEl
      for_ [0..length - 1] \idx -> do
        childEl <- getChildNode rootEl (length - idx - 1)
        removeChild rootEl childEl
  addFinalizer (unsub Nothing)
  void $ forDyn dyn (liftIO . mutate . (void .) . setup)

catchInteractive :: HtmlT () -> (SomeException -> HtmlT ()) -> HtmlT ()
catchInteractive html handle = ask >>= run where
  run e = local (f e) html
  f e he = he {he_catch_interactive = runHtmlT e . handle}
