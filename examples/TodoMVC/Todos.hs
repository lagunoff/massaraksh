{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE IncoherentInstances #-}
{-# LANGUAGE Unsafe #-}
{-# LANGUAGE OverloadedStrings, QuasiQuotes #-}
module TodoMVC.Todos where

import Control.Lens hiding ((#))
import Data.Aeson (FromJSON, ToJSON)
import Data.Generics.Product (field)
import Data.String (fromString)
import Data.Text (Text)
import GHC.Generics
import Language.Javascript.JSaddle (JSM)
import Massaraksh.Component
import Polysemy
import Polysemy.State
import Text.RawString.QQ (r)
import TodoMVC.Utils (readTodos, writeTodos, readHash, writeHash)
import qualified Data.Text as T
import qualified GHCJS.DOM.GlobalEventHandlers as E
import qualified Massaraksh.Html.Attrs.Dynamic as Dyn
import qualified TodoMVC.Item as Item

data Model = Model
  { title  :: Text
  , todos  :: [Item.Model]
  , filter :: Filter
  } deriving (Show, Eq, Generic, FromJSON, ToJSON)
  
data Msg a where
  Edit :: Text -> Msg ()
  SetFilter :: Filter -> Msg ()
  ToggleAll :: Bool -> Msg ()
  ClearCompleted :: Msg ()
  KeyPress :: Int -> Msg ()
  HashChange :: Text -> Msg ()
  BeforeUnload :: Msg ()
  EditingCommit :: Msg ()
  Blur :: Msg ()
  TodoMsg :: Item.Msg a -> Int -> Msg a

data Filter = All | Active | Completed
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

init :: Eff '[Embed JSM] Model
init = embed do
  hash <- readHash
  let filter = filterFromUrl hash & maybe All id
  todos <- readTodos
  pure $ Model "" todos filter
  
eval :: Msg a -> Eff '[State Model, Emit Msg, Embed JSM] a
eval = \case
  Edit x ->
    modify @Model $ field @"title" .~ x
  SetFilter x ->
    modify @Model $ field @"filter" .~ x
  ToggleAll check ->
    modify @Model $ field @"todos" %~ fmap (field @"completed" .~ check)
  ClearCompleted ->
    modify @Model $ field @"todos" %~ Prelude.filter (not . Item.completed)
  EditingCommit -> do
    model <- get
    case T.strip (title model) of
      "" -> pure ()
      trimmed -> do
        modify @Model $ field @"todos" %~ (<> [Item.init trimmed])
        modify @Model $ field @"title" .~ ""
  Blur ->
    emit EditingCommit
  KeyPress 13 ->
    emit EditingCommit
  KeyPress _ ->
    pure ()
  HashChange hash ->
    case filterFromUrl hash of
      Just x -> modify @Model $ field @"filter" .~ x
      Nothing -> do
        modify @Model $ field @"filter" .~ All
        embed $ writeHash (filterToUrl All)
  BeforeUnload -> do
    model <- get @Model
    embed $ writeTodos (todos model)
  TodoMsg Item.Destroy idx ->
    modify @Model $ field @"todos" %~ deleteNth idx
  TodoMsg msg idx ->
    Item.eval msg
      & liftMsg (flip TodoMsg idx)
      & runStateLens @Model (field @"todos" . element idx)
    
view :: Html1 Msg Model Model
view =
  div_ []
  [ section_ [ class_ "todoapp" ]
    [ viewHeader
    , viewMain
    , viewFooter
    ]
  , footerInfo
  , el "style" [ type_ "text/css" ] [ text css ]
  ]
  where
    viewHeader =
      header_ [ class_ "header" ]
      [ h1_ [] [ text "todos" ]
      , input_
        [ class_ "new-todo"
        , placeholder_ "What needs to be done?"
        , autofocus_ True
        , Dyn.value_ title
        , onInput \_ -> Left . Exists . Edit
        , onWithOptions1_ E.keyDown keycodeDecoder KeyPress
        , on1_ E.blur Blur
        ]
      ]
    
    viewMain =
      section_
      [ Dyn.classList_
        [ ("hidden", null . todos)
        , ("main", const True)
        ]
      ]
      [ input_ [ type_ "checkbox", id_ "toggle-all", class_ "toggle-all", onWithOptions1_ E.click checkedDecoder ToggleAll ]
      , label_ [ htmlFor_ "toggle-all" ] [ text "Mark all as completed" ]
      , list (field @"todos") "ul" [ class_ "todo-list" ]
        (mapUI (\(Exists msg) idx -> Exists $ TodoMsg msg idx) Item.view)
        \parent model -> Item.Props { hidden = isHidden parent model, .. }
      ]
  
    viewFilter x =
      li_ []
      [ a_
        [ Dyn.classList_ [("selected", (x ==) . TodoMVC.Todos.filter)], href_ (filterToUrl x) ]
        [ text (fromString . show $ x) ]
      ]
      
    viewFooter =
      footer_
      [ Dyn.classList_
        [ ("footer", const True)
        , ("hidden", null . todos)
        ]
      ]
      [ span_
        [ class_ "todo-count" ]
        [ strong_ [] [ Dyn.text (fromString . show . itemsLeft) ]
        , Dyn.text $ pluralize " item left" " items left" . itemsLeft
        ]
      , ul_ [ class_ "filters" ] $
        [ All, Active, Completed ] & fmap viewFilter
      , button_ [ class_ "clear-completed", on1_ E.click ClearCompleted ] [ text "Clear completed" ]
      ]
      
    footerInfo =
      footer_
      [ class_ "info" ]
      [ p_ [] [ text "Double-click to edit a todo" ]
      , p_ [] [ text "Created by ", a_ [ href_ "https://github.com/lagunoff" ] [ text "Vlad Lagunov" ] ]
      , p_ [] [ text "Part of ", a_ [ href_ "http://todomvc.com" ] [ text "TodoMVC" ] ]
      ]

    itemsLeft :: Model -> Int
    itemsLeft model =
      foldl (\acc (itemModel) -> if not (Item.completed itemModel) then acc + 1 else acc) 0 (todos model)      

    isHidden :: Model -> Item.Model -> Bool
    isHidden (Model {filter}) (Item.Model {completed}) =
      case (filter, completed) of
        (Active,    True)  -> True
        (Completed, False) -> True
        _                  -> False
  
    pluralize :: Text -> Text -> Int -> Text
    pluralize singular plural 0 = singular
    pluralize singular plural _ = plural  
      
filterFromUrl :: Text -> Maybe Filter
filterFromUrl = \case
  "#/"          -> Just All
  "#/active"    -> Just Active
  "#/completed" -> Just Completed
  _             -> Nothing

filterToUrl :: Filter -> Text
filterToUrl = \case
  All       -> "#/"
  Active    -> "#/active"
  Completed -> "#/completed"

deleteNth :: Int -> [a] -> [a]
deleteNth _ []     = []
deleteNth i (a:as)
  | i == 0    = as
  | otherwise = a : deleteNth (i-1) as

css = [r|
body {
	margin: 0;
	padding: 0;
}

button {
	margin: 0;
	padding: 0;
	border: 0;
	background: none;
	font-size: 100%;
	vertical-align: baseline;
	font-family: inherit;
	font-weight: inherit;
	color: inherit;
	-webkit-appearance: none;
	appearance: none;
	-webkit-font-smoothing: antialiased;
	-moz-osx-font-smoothing: grayscale;
}

body {
	font: 14px 'Helvetica Neue', Helvetica, Arial, sans-serif;
	line-height: 1.4em;
	background: #f5f5f5;
	color: #4d4d4d;
	min-width: 230px;
	max-width: 550px;
	margin: 0 auto;
	-webkit-font-smoothing: antialiased;
	-moz-osx-font-smoothing: grayscale;
	font-weight: 300;
}

:focus {
	outline: 0;
}

.hidden {
	display: none;
}

.todoapp {
	background: #fff;
	margin: 130px 0 40px 0;
	position: relative;
	box-shadow: 0 2px 4px 0 rgba(0, 0, 0, 0.2),
	            0 25px 50px 0 rgba(0, 0, 0, 0.1);
}

.todoapp input::-webkit-input-placeholder {
	font-style: italic;
	font-weight: 300;
	color: #e6e6e6;
}

.todoapp input::-moz-placeholder {
	font-style: italic;
	font-weight: 300;
	color: #e6e6e6;
}

.todoapp input::input-placeholder {
	font-style: italic;
	font-weight: 300;
	color: #e6e6e6;
}

.todoapp h1 {
	position: absolute;
	top: -155px;
	width: 100%;
	font-size: 100px;
	font-weight: 100;
	text-align: center;
	color: rgba(175, 47, 47, 0.15);
	-webkit-text-rendering: optimizeLegibility;
	-moz-text-rendering: optimizeLegibility;
	text-rendering: optimizeLegibility;
}

.new-todo,
.edit {
	position: relative;
	margin: 0;
	width: 100%;
	font-size: 24px;
	font-family: inherit;
	font-weight: inherit;
	line-height: 1.4em;
	border: 0;
	color: inherit;
	padding: 6px;
	border: 1px solid #999;
	box-shadow: inset 0 -1px 5px 0 rgba(0, 0, 0, 0.2);
	box-sizing: border-box;
	-webkit-font-smoothing: antialiased;
	-moz-osx-font-smoothing: grayscale;
}

.new-todo {
	padding: 16px 16px 16px 60px;
	border: none;
	background: rgba(0, 0, 0, 0.003);
	box-shadow: inset 0 -2px 1px rgba(0,0,0,0.03);
}

.main {
	position: relative;
	z-index: 2;
	border-top: 1px solid #e6e6e6;
}

.toggle-all {
	width: 1px;
	height: 1px;
	border: none; /* Mobile Safari */
	opacity: 0;
	position: absolute;
	right: 100%;
	bottom: 100%;
}

.toggle-all + label {
	width: 60px;
	height: 34px;
	font-size: 0;
	position: absolute;
	top: -52px;
	left: -13px;
	-webkit-transform: rotate(90deg);
	transform: rotate(90deg);
}

.toggle-all + label:before {
	content: '❯';
	font-size: 22px;
	color: #e6e6e6;
	padding: 10px 27px 10px 27px;
}

.toggle-all:checked + label:before {
	color: #737373;
}

.todo-list {
	margin: 0;
	padding: 0;
	list-style: none;
}

.todo-list li {
	position: relative;
	font-size: 24px;
	border-bottom: 1px solid #ededed;
}

.todo-list li:last-child {
	border-bottom: none;
}

.todo-list li.editing {
	border-bottom: none;
	padding: 0;
}

.todo-list li.editing .edit {
	display: block;
	width: calc(100% - 43px);
	padding: 12px 16px;
	margin: 0 0 0 43px;
}

.todo-list li.editing .view {
	display: none;
}

.todo-list li .toggle {
	text-align: center;
	width: 40px;
	/* auto, since non-WebKit browsers doesn't support input styling */
	height: auto;
	position: absolute;
	top: 0;
	bottom: 0;
	margin: auto 0;
	border: none; /* Mobile Safari */
	-webkit-appearance: none;
	appearance: none;
}

.todo-list li .toggle {
	opacity: 0;
}

.todo-list li .toggle + label {
	/*
		Firefox requires `#` to be escaped - https://bugzilla.mozilla.org/show_bug.cgi?id=922433
		IE and Edge requires *everything* to be escaped to render, so we do that instead of just the `#` - https://developer.microsoft.com/en-us/microsoft-edge/platform/issues/7157459/
	*/
	background-image: url('data:image/svg+xml;utf8,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20width%3D%2240%22%20height%3D%2240%22%20viewBox%3D%22-10%20-18%20100%20135%22%3E%3Ccircle%20cx%3D%2250%22%20cy%3D%2250%22%20r%3D%2250%22%20fill%3D%22none%22%20stroke%3D%22%23ededed%22%20stroke-width%3D%223%22/%3E%3C/svg%3E');
	background-repeat: no-repeat;
	background-position: center left;
}

.todo-list li .toggle:checked + label {
	background-image: url('data:image/svg+xml;utf8,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20width%3D%2240%22%20height%3D%2240%22%20viewBox%3D%22-10%20-18%20100%20135%22%3E%3Ccircle%20cx%3D%2250%22%20cy%3D%2250%22%20r%3D%2250%22%20fill%3D%22none%22%20stroke%3D%22%23bddad5%22%20stroke-width%3D%223%22/%3E%3Cpath%20fill%3D%22%235dc2af%22%20d%3D%22M72%2025L42%2071%2027%2056l-4%204%2020%2020%2034-52z%22/%3E%3C/svg%3E');
}

.todo-list li label {
	word-break: break-all;
	padding: 15px 15px 15px 60px;
	display: block;
	line-height: 1.2;
	transition: color 0.4s;
}

.todo-list li.completed label {
	color: #d9d9d9;
	text-decoration: line-through;
}

.todo-list li .destroy {
	display: none;
	position: absolute;
	top: 0;
	right: 10px;
	bottom: 0;
	width: 40px;
	height: 40px;
	margin: auto 0;
	font-size: 30px;
	color: #cc9a9a;
	margin-bottom: 11px;
	transition: color 0.2s ease-out;
}

.todo-list li .destroy:hover {
	color: #af5b5e;
}

.todo-list li .destroy:after {
	content: '×';
}

.todo-list li:hover .destroy {
	display: block;
}

.todo-list li .edit {
	display: none;
}

.todo-list li.editing:last-child {
	margin-bottom: -1px;
}

.footer {
	color: #777;
	padding: 10px 15px;
	height: 20px;
	text-align: center;
	border-top: 1px solid #e6e6e6;
}

.footer:before {
	content: '';
	position: absolute;
	right: 0;
	bottom: 0;
	left: 0;
	height: 50px;
	overflow: hidden;
	box-shadow: 0 1px 1px rgba(0, 0, 0, 0.2),
	            0 8px 0 -3px #f6f6f6,
	            0 9px 1px -3px rgba(0, 0, 0, 0.2),
	            0 16px 0 -6px #f6f6f6,
	            0 17px 2px -6px rgba(0, 0, 0, 0.2);
}

.todo-count {
	float: left;
	text-align: left;
}

.todo-count strong {
	font-weight: 300;
}

.filters {
	margin: 0;
	padding: 0;
	list-style: none;
	position: absolute;
	right: 0;
	left: 0;
}

.filters li {
	display: inline;
}

.filters li a {
	color: inherit;
	margin: 3px;
	padding: 3px 7px;
	text-decoration: none;
	border: 1px solid transparent;
	border-radius: 3px;
}

.filters li a:hover {
	border-color: rgba(175, 47, 47, 0.1);
}

.filters li a.selected {
	border-color: rgba(175, 47, 47, 0.2);
}

.clear-completed,
html .clear-completed:active {
	float: right;
	position: relative;
	line-height: 20px;
	text-decoration: none;
	cursor: pointer;
}

.clear-completed:hover {
	text-decoration: underline;
}

.info {
	margin: 65px auto 0;
	color: #bfbfbf;
	font-size: 10px;
	text-shadow: 0 1px 0 rgba(255, 255, 255, 0.5);
	text-align: center;
}

.info p {
	line-height: 1;
}

.info a {
	color: inherit;
	text-decoration: none;
	font-weight: 400;
}

.info a:hover {
	text-decoration: underline;
}

/*
	Hack to remove background from Mobile Safari.
	Can't use it globally since it destroys checkboxes in Firefox
*/
@media screen and (-webkit-min-device-pixel-ratio:0) {
	.toggle-all,
	.todo-list li .toggle {
		background: none;
	}

	.todo-list li .toggle {
		height: 40px;
	}
}

@media (max-width: 430px) {
	.footer {
		height: 50px;
	}

	.filters {
		bottom: 10px;
	}
}|]
