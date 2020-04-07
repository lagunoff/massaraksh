{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module Main where

import Massaraksh
import Control.Monad.Reader
import Text.RawString.QQ (r)
import qualified Data.Text as T

type Model = Int

widget :: HtmlBase m => HtmlT m ()
widget = do
  DynRef dyn modify <- liftIO (newDynRef 0)
  div_ do
    "className" =: "root"
    h1_ do
      "style" ~: headerStyle <$> dyn
      on_ "mouseenter" do liftIO $ modify (+ 1)
      text "Hello, World!"
    el "style" do "type" =: "text/css"; text css

headerStyle n =
 ("color: " :: T.Text) <> colors !! (n `mod` length colors)

colors =
  [ "rgb(173,192,84)", "rgb(22,153,190)", "rgb(22,93,24)", "rgb(199,232,42)"
  , "rgb(235,206,57)", "rgb(225,57,149)", "rgb(255,134,157)", "rgb(231,251,35)"
  , "rgb(148,122,45)", "rgb(227,10,30)", "rgb(97,22,125)", "rgb(239,243,10)"
  , "rgb(155,247,3)", "rgb(199,31,74)", "rgb(109,198,34)", "rgb(170,52,228)"
  , "rgb(61,44,247)", "rgb(118,45,39)", "rgb(248,116,17)", "rgb(27,184,238)"
  , "rgb(117,23,222)" ]

css = [r|
  html, body {
    margin: 0;
    height: 100%;
  }

 .root {
   width: 100%;
   height: 100%;
   display: flex;
   align-items: center;
   justify-content: center;
 }

 .root > h1 {
   font-size: 48px;
   margin: 0;
   font-family: "Helvetica", Arial, sans-serif;
   font-weight: 600;
   border: dashed 4px rgba(0,0,0,0.12);
   cursor: default;
   padding: 8px 16px;
 } |]

main = withJSM $ attachToBodySimple widget
