-- | Most basic functions and definitions exported by the library
module HtmlT.Base where

import Control.Exception as Ex
import Control.Lens hiding ((#))
import Control.Monad.Reader
import Data.Coerce
import Data.Foldable
import Data.IORef
import Data.JSString.Text as JSS
import Data.List as L
import Data.Text as T hiding (index)
import GHCJS.Marshal
import JavaScript.Object as Object
import JavaScript.Object.Internal

import HtmlT.DOM
import HtmlT.Event
import HtmlT.Internal
import HtmlT.Types

-- | Create a DOM element with a given tag name and attach it to the
-- current root. Second argument contains attributes, properties and
-- children nodes for the new element
--
-- > el "div" do
-- >   prop "className" "container"
-- >   el "span" $ text "Lorem Ipsum"
el :: MonadIO m => Text -> HtmlT m x -> HtmlT m x
el tag child = do
  newRootEl <- liftIO (createElement tag)
  appendHtmlT newRootEl child

-- | Same as 'el' but also returns the reference to the new element
el' :: MonadIO m => Text -> HtmlT m x -> HtmlT m (x, Node)
el' tag child = do
  newRootEl <- liftIO (createElement tag)
  (,newRootEl) <$> appendHtmlT newRootEl child

-- | Same as 'el' but allows to specify element's namespace, see more
-- https://developer.mozilla.org/en-US/docs/Web/API/Document/createElementNS
--
-- > elns "http://www.w3.org/2000/svg" "svg" do
-- >   prop "height" "210"
-- >   prop "width" "400"
-- >   elns "http://www.w3.org/2000/svg" "path" do
-- >     prop "d" "M150 0 L75 200 L225 200 Z"
elns :: MonadIO m => Text -> Text -> HtmlT m x -> HtmlT m x
elns ns tag child = do
  newRootEl <- liftIO (createElementNS ns tag)
  appendHtmlT newRootEl child

-- | Create a TextNode and attach it to the root
text :: MonadIO m => Text -> HtmlT m ()
text txt = do
  rootEl <- asks he_current_root
  textNode <- liftIO (createTextNode txt)
  liftIO $ appendChild rootEl textNode

-- | Create a TextNode with dynamic content
dynText :: MonadIO m => Dynamic Text -> HtmlT m ()
dynText d = do
  txt <- readDyn d
  rootEl <- asks he_current_root
  textNode <- liftIO (createTextNode txt)
  forEvent_ (updates d) \new -> void $ liftIO do
    setTextValue textNode new
  liftIO $ appendChild rootEl textNode

-- | Assign a property to the root element. Don't confuse attributes
-- and properties see
-- https://stackoverflow.com/questions/6003819/what-is-the-difference-between-properties-and-attributes-in-html
prop :: (ToJSVal v, MonadIO m) => Text -> v -> HtmlT m ()
prop (JSS.textToJSString -> key) val = do
  rootEl <- asks he_current_root
  v <- liftIO $ toJSVal val
  liftIO $ Object.setProp key v (coerce rootEl)

-- | Assign a property with dynamic content to the root element
dynProp
  :: (ToJSVal v, FromJSVal v, Eq v, MonadIO m)
  => Text
  -> Dynamic v
  -> HtmlT m ()
dynProp textKey dyn = do
  rootEl <- asks he_current_root
  void $ forDyn dyn (liftIO . setup rootEl)
  where
    setup el t = toJSVal t
      >>= flip (unsafeSetProp jsKey) (coerce el)
    jsKey = JSS.textToJSString textKey

-- | Assign an attribute to the root element. Don't confuse attributes
-- and properties see
-- https://stackoverflow.com/questions/6003819/what-is-the-difference-between-properties-and-attributes-in-html
attr :: MonadIO m => Text -> Text -> HtmlT m ()
attr k v = asks he_current_root
  >>= \e -> liftIO (setAttribute e k v)

-- | Assign an attribute with dynamic content to the root element
dynAttr :: MonadIO m => Text -> Dynamic Text -> HtmlT m ()
dynAttr k d = do
  rootEl <- asks he_current_root
  void $ forDyn d $ liftIO . setAttribute rootEl k

-- | Attach a listener to the root element. First agument is the name
-- of the DOM event to listen. Second is the callback that accepts the fired
-- DOM event object
--
-- > el "button" do
-- >   on "click" \_event -> do
-- >     liftIO $ putStrLn "Clicked!"
-- >   text "Click here"
on :: Text -> (DOMEvent -> HtmlT IO ()) -> HtmlT IO ()
on name f = ask >>= listen where
  listen HtmlEnv{..} =
    onGlobalEvent defaultListenerOpts he_current_root name f

-- | Same as 'on' but ignores 'DOMEvent' inside the callback
on_ :: Text -> HtmlT IO () -> HtmlT IO ()
on_ name = on name . const

onOpts :: Text -> ListenerOpts -> (DOMEvent -> HtmlT IO ()) -> HtmlT IO ()
onOpts name opts f = ask >>= listen where
  listen HtmlEnv{..} =
    onGlobalEvent opts he_current_root name f

onOpts_ :: Text -> ListenerOpts -> HtmlT IO () -> HtmlT IO ()
onOpts_ name opts = onOpts name opts . const

-- | Attach a listener to arbitrary target, not just the current root
-- element (usually that would be @window@, @document@ or @body@
-- objects)
onGlobalEvent
  :: ListenerOpts
  -- ^ Specified whether to call @event.stopPropagation()@ and
  -- @event.preventDefault()@ on the fired event
  -> Node
  -- ^ Event target
  -> Text
  -- ^ Event name
  -> (DOMEvent -> HtmlT IO ())
  -- ^ Callback that accepts reference to the DOM event
  -> HtmlT IO ()
onGlobalEvent opts target name f = ask >>= run where
  mkEvent e = Event \k -> liftIO do
    unlisten <- addEventListener opts target name \event -> do
      void . liftIO . catc e . sync . k . f $ coerce event
    pure $ liftIO unlisten
  run e@HtmlEnv{..} = void $
    subscribe (mkEvent e) (liftIO . runHtmlT e)
  catc e = flip Ex.catch (he_catch_interactive e)

-- | Assign CSS classes to the current root element. Compare to @prop
-- "className"@ can be used multiple times for the same root
--
-- > el "div" do
-- >   classes "container row"
-- >   classes "mt-1 mb-2"
classes :: MonadIO m => Text -> HtmlT m ()
classes cs = do
  rootEl <- asks he_current_root
  for_ (T.splitOn " " cs) $
    liftIO . classListAdd rootEl

-- | Assign a single CSS classe dynamically based on the value held by
-- the given Dynamic
--
-- > showRef <- newRef False
-- > el "div" do
-- >   toggleClass "show" $ fromRef showRef
-- > el "button" do
-- >   on_ "click" $ modifyRef showRef not
-- >   text "Toggle visibility"
toggleClass :: MonadIO m => Text -> Dynamic Bool -> HtmlT m ()
toggleClass cs dyn = do
  rootEl <- asks he_current_root
  void $ forDyn dyn (liftIO . setup rootEl cs)
  where
    setup rootEl cs enable = case enable of
      True  -> classListAdd rootEl cs
      False -> classListRemove rootEl cs

-- | Assign a boolean attribute dynamically based on the value held by
-- the given Dynamic
--
-- > hiddenRef <- newRef True
-- > el "div" do
-- >   toggleAttr "hidden" $ fromRef hiddenRef
-- > el "button" do
-- >   on_ "click" $ modifyRef hiddenRef not
-- >   text "Toggle visibility"
toggleAttr :: MonadIO m => Text -> Dynamic Bool -> HtmlT m ()
toggleAttr att dyn = do
  rootEl <- asks he_current_root
  void $ forDyn dyn (liftIO . setup rootEl att)
  where
    setup rootEl name enable = case enable of
      True -> setAttribute rootEl name "on"
      False -> removeAttribute rootEl name

-- | Assign a CSS property to the root dynamically based on the value
-- held by the given Dynamic
--
-- > colorRef <- newRef True
-- > el "button" do
-- >   dynStyle "background" $ bool "initial" "red" <$> fromRef colorRef
-- >   on_ "click" $ modifyRef colorRef not
-- >   text "Toggle background color"
dynStyle :: MonadIO m => Text -> Dynamic Text -> HtmlT m ()
dynStyle cssProp dyn = do
  rootEl <- asks he_current_root
  void $ forDyn dyn (liftIO . setup rootEl)
  where
    setup el t = do
      styleVal <- Object.getProp "style" (coerce el)
      cssVal <- toJSVal t
      unsafeSetProp jsCssProp cssVal (coerce styleVal)
    jsCssProp = JSS.textToJSString cssProp

-- | Alias for @pure ()@, useful when some HtmlIO action is expected.
blank :: Applicative m => m ()
blank = pure ()

-- | Attach a dynamic list to the root. Convenient for displaying
-- small dynamic collections (<100 elements). Currently has a
-- limitation — the children widgets have to has exactly one element
-- in their root level otherwise it is possible you get runtime error
-- after list modifications
--
-- > listRef <- newRef ["One", "Two", "Three"]
-- > el "ul" do
-- >   simpleList listRef traversed \_idx elemRef -> do
-- >     el "li" $ dynText $ fromRef elemRef
-- > el "button" do
-- >   on_ "click" $ modifyRef listRef ("New Item":)
-- >   text "Append new item"
simpleList
  :: forall s a
  . DynRef s
  -- ^ Some dynamic data from the above scope
  -> IndexedTraversal' Int s a
  -- ^ Point to some traversable collection inside @s@
  -> (Int -> DynRef a -> HtmlT IO ())
  -- ^ Function to build children widget. Accepts the index inside the
  -- collection and dynamic data for that particular element
  -> HtmlT IO ()
simpleList dynRef l h = do
  hte <- ask
  rootEl <- asks he_current_root
  s <- readRef dynRef
  itemRefs <- liftIO (newIORef [])
  let
    -- FIXME: 'setup' should return new contents for 'itemRefs'
    setup :: s -> Int -> [ElemEnv a] -> [a] -> [a] -> IO ()
    setup s idx refs old new = case (refs, old, new) of
      (_, [], [])    -> pure ()
      ([], [], x:xs) -> do
        -- New list is longer, append new elements
        fins <- Finalizers <$> newIORef []
        elemRef <- runSubscribeT (he_subscriptions hte) $ newRef x
        postRef <- liftIO (newIORef [])
        let
          elemRef' = elemRef {dr_modifier=mkModifier idx (fromRef elemRef)}
          newEnv = hte
            { he_finalizers = fins
            , he_post_hooks = postRef }
          itemRef = ElemEnv newEnv elemRef' (dr_modifier elemRef)
        runHtmlT newEnv $ h idx elemRef'
        liftIO (modifyIORef' itemRefs (<> [itemRef]))
        setup s (idx + 1) [] [] xs
      (_, x:xs, []) -> do
        -- New list is shorter, delete the elements that no longer
        -- present in the new list
        itemRefsValue <- liftIO (readIORef itemRefs)
        let (newRefs, tailRefs) = L.splitAt idx itemRefsValue
        unsub tailRefs
        childEl <- getChildNode rootEl idx
        removeChild rootEl childEl
        liftIO (writeIORef itemRefs newRefs)
      (r:rs, x:xs, y:ys) -> do
        -- Update child elemens along the way
        liftIO $ sync $ ee_modifier r \_ -> y
        setup s (idx + 1) rs xs ys
      (_, _, _) -> do
        error "simpleList: Incoherent internal state"

    unsub = traverse_ \ElemEnv{..} -> do
      let fins = he_finalizers ee_html_env
      liftIO $ readIORef (unFinalizers fins) >>= sequence_

    mkModifier :: Int -> Dynamic a -> (a -> a) -> Reactive ()
    mkModifier idx dyn f = do
      oldA <- readDyn dyn
      dr_modifier dynRef \oldS ->
        oldS & iover l \i x -> if i == idx then f oldA else x
  liftIO $ setup s 0 [] [] (toListOf l s)
  addFinalizer $ readIORef itemRefs >>= unsub
  let eUpdates = withOld s (dynamic_updates $ fromRef dynRef)
  forEvent_ eUpdates \(old, new) -> do
    refs <- liftIO (readIORef itemRefs)
    liftIO $ setup new 0 refs (toListOf l old) (toListOf l new)
  pure ()

-- | First build a DOM with the widget that is currently held by the
-- given Dynamic, then rebuild it every time Dynamic's value
-- changes. Useful for SPA routing, tabbed components etc. Currently
-- has a limitation — 'dyn_' can only be used as a sole descendant of
-- its parent element (i.e. should have no siblings)
--
-- > routeRef <- newRef Home
-- > el "div"
-- >   dyn_ $ routeRef <&> \case
-- >     Home -> homeWidget
-- >     Blog -> blogWidget
-- >     Resume -> resumeWidget
-- > el "button" do
-- >   on_ "click" $ writeRef routeRef Blog
-- >   text "Show my blog page"
dyn_ :: Dynamic (HtmlT IO ()) -> HtmlT IO ()
dyn_ dyn = do
  env <- ask
  childRef <- liftIO (newIORef Nothing)
  let
    rootEl = he_current_root env
    unsub newEnv = do
      readIORef childRef >>= \case
        Just HtmlEnv{..} -> do
          subs <- readIORef $ unFinalizers he_finalizers
          sequence_ subs
          writeIORef (unFinalizers he_finalizers) []
        Nothing -> return ()
      writeIORef childRef newEnv
    setup rootEl html = liftIO do
      postHooks <- newIORef []
      fins <- Finalizers <$> newIORef []
      let
        newEnv = env
          { he_finalizers = fins
          , he_post_hooks = postHooks }
        commit =
          unsub (Just newEnv)
          <* removeAllChilds rootEl
          <* (readIORef postHooks >>= sequence_)
      commit *> runHtmlT newEnv html
  addFinalizer (unsub Nothing)
  void $ forDyn dyn (liftIO . setup rootEl)

catchInteractive
  :: HtmlT IO ()
  -> (SomeException -> HtmlT IO ())
  -> HtmlT IO ()
catchInteractive html handle = ask >>= run where
  run e = local (f e) html
  f e he = he {he_catch_interactive = runHtmlT e . handle}

addFinalizer :: MonadIO m => IO () -> HtmlT m ()
addFinalizer fin = do
  fins <- askFinalizers
  finRef <- liftIO $ newIORef fin
  liftIO $ modifyIORef (unFinalizers fins) (fin:)

portal :: MonadIO m => Node -> HtmlT m x -> HtmlT m x
portal rootEl = local (\e -> e {he_current_root = rootEl})
