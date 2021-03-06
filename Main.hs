{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PartialTypeSignatures      #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}

module Main where

import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Exception.Extensible          (bracket)
import           Control.Monad.IO.Class                (liftIO)
import           Control.Monad.Logger
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.Resource.Internal
import           Data.Aeson
import           Data.IORef
import           Data.List                             (null, sortOn)
import           Data.Map.Strict                       (fromListWith, toList)
import           Data.Proxy
import           Data.Text                             (Text)
import           Data.Text.Lazy                        (pack, toStrict)
import           Data.Time.Clock
import           Database.Esqueleto
import           Database.Persist                      (insert)
import           Database.Persist.Sqlite               (runMigration, runSqlite)
import           Database.Persist.TH                   (mkMigrate, mkPersist,
                                                        persistLowerCase, share,
                                                        sqlSettings)
import           GHC.Generics                          (Generic)
import qualified Graphics.UI.Gtk                       as Gtk
import           Graphics.UI.Gtk.Display.StatusIcon
import           Graphics.X11
import           Graphics.X11.Xlib.Extras
import qualified Network.Wai                           as Wai
import qualified Network.Wai.Handler.Warp              as Wai
import qualified Network.Wai.Middleware.Gzip           as Wai
import qualified Network.Wai.Middleware.RequestLogger  as Wai
import           Servant                               ((:<|>) (..), (:>), Get)
import qualified Servant
import           System.IO.Error                       (catchIOError)
import           Web.Browser                           (openBrowser)

share [mkPersist sqlSettings, mkMigrate "migrateTables"] [persistLowerCase|
LogItem
   title    Text
   begin    UTCTime
   end      UTCTime
   deriving Eq Show Generic
|]

main :: IO ()
main = do
  a <- asyncBound runTray
  b <- async runWarp
  c <- async runMain
  _ <- waitAnyCancel [a, b, c]
  return ()

runWarp :: IO ()
runWarp =
  Wai.run 3003 $ Wai.logStdout $ compress app

runMain :: IO ()
runMain =
  runDB $ do
    runMigration migrateTables
    liftIO loop

runTray :: IO ()
runTray = do
  _ <- Gtk.initGUI
  ref <- newIORef =<< statusIconNewFromStock Gtk.stockSave
  icon <- readIORef ref
  statusIconSetVisible icon True
  statusIconSetTooltipText icon $ Just ("Time Logger" :: String)
  menu <- mkmenu
  _ <- Gtk.on icon statusIconPopupMenu $ \b a -> do
         Gtk.widgetShowAll menu
         Gtk.menuPopup menu $ maybe Nothing (\b' -> Just (b',a)) b
  _ <- Gtk.on icon statusIconActivate $ do
      _ <- openBrowser "http://localhost:3003/static/index.html"
      return ()
  Gtk.mainGUI
  _ <- readIORef ref    -- Necessary.
  return ()

mkmenu :: IO Gtk.Menu
mkmenu = do
  m <- Gtk.menuNew
  mapM_ (mkitem m) [("Quit" :: String, Gtk.mainQuit)]
  return m
    where
        mkitem menu (labelName, act) =
            do i <- Gtk.menuItemNewWithLabel labelName
               Gtk.menuShellAppend menu i
               Gtk.on i Gtk.menuItemActivated act

runDB :: ReaderT SqlBackend (NoLoggingT (ResourceT IO)) a -> IO a
runDB = runSqlite "db.sqlite"

compress :: Wai.Middleware
compress = Wai.gzip Wai.def { Wai.gzipFiles = Wai.GzipCompress }

app :: Wai.Application
app = Servant.serve userAPI server

userAPI :: Proxy UserAPI
userAPI = Proxy

type UserAPI = "daily" :> Get '[Servant.JSON] [DailyDuration]
          :<|> "static" :> Servant.Raw

server :: Servant.Server UserAPI
server = daily
           :<|> static

static :: Servant.Server StaticAPI
static = Servant.serveDirectoryFileServer "static"

type StaticAPI = "static" :> Servant.Raw

data DailyDuration = DailyDuration
  { label :: Text
  , value :: NominalDiffTime
  } deriving (Eq, Show, Generic)

instance ToJSON DailyDuration

daily :: Servant.Handler [DailyDuration]
daily = do
  lis <- liftIO $ do
    timeNow <- getCurrentTime
    let oneDayAgo = addUTCTime (-nominalDay) timeNow
    runDB $ select $ from $ \li -> do
                     where_ (li ^. LogItemBegin >. val oneDayAgo)
                     orderBy [desc (li ^. LogItemId)]
                     return li
  let logItems = map entityVal lis
  let dailyDurations = fmap logItemToDailyDuration logItems
  let dd = fmap (\dailyDuration -> (label dailyDuration, value dailyDuration)) dailyDurations
  let dm = fromListWith (+) dd
  let ddr = uncurry DailyDuration <$> toList dm
  return $ take 20 $ reverse $ sortOn value ddr

logItemToDailyDuration :: LogItem -> DailyDuration
logItemToDailyDuration li = DailyDuration (logItemTitle li) time
  where time = diffUTCTime (logItemEnd li) (logItemBegin li)

loop :: IO ()
loop = do
  d <- openDisplay ""
  time <- getCurrentTime
  currentWindowTitle <- getFocusedWindowTitle d
  closeDisplay d
  runDB $ do
    previousLogItem <- select $ from $ \li -> do
            orderBy [desc (li ^. LogItemId)]
            limit 1
            return (li ^. LogItemId, li ^. LogItemTitle)
    liftIO $ print currentWindowTitle
    if not (null previousLogItem)
      && (toStrict (pack currentWindowTitle)
      == unValue (snd $ head previousLogItem))
      then do
        let logItemKey = unValue (fst $ head previousLogItem)
        update $ \li -> do
           set li [LogItemEnd =. val time]
           where_ (li ^. LogItemId ==. val logItemKey)
      else do
        _ <- insert $ LogItem (toStrict $ pack currentWindowTitle) time time -- dedup
        return ()
  threadDelay 1000000
  loop

getFocusedWindowTitle :: Display -> IO String
getFocusedWindowTitle d = do
  (w, _) <- getInputFocus d
  wt <- followTreeUntil d (hasCorrectTitle d) w
  getWindowTitle d wt

getWindowTitle :: Display -> Window -> IO String
getWindowTitle d w = do
  let getProp =
          (internAtom d "_NET_WM_NAME" False >>= getTextProperty d w)
          `catchIOError`
          (\_ -> getTextProperty d w wM_NAME)

      extract prop = do l <- wcTextPropertyToTextList d prop
                        return $ if null l then "" else head l

  bracket getProp (xFree . tp_value) extract
      `catchIOError` \_ -> return ""

getParent :: Display -> Window -> IO Window
getParent dpy w = do
  (_, parent, _) <- queryTree dpy w `catchIOError` const (return (0,0,[]))
  return parent

followTreeUntil :: Display -> (Window -> IO Bool) -> Window -> IO Window
followTreeUntil dpy cond = go
  where go w = do
          match <- cond w
          if match
            then return w
            else
              do p <- getParent dpy w
                 if p == 0 then return w
                           else go p

hasCorrectTitle :: Display -> Window -> IO Bool
hasCorrectTitle d w = do
  title <- getWindowTitle d w
  return $ title /= "" && title /= "FocusProxy"
