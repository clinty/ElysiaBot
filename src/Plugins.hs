{-# LANGUAGE DeriveDataTypeable, OverloadedStrings, StandaloneDeriving, PackageImports #-}
module Plugins 
  (PluginCommand(..)
  , writeCommand
  , runPlugins
  , pluginLoop
  , messagePlugin
  , findPlugin
  , unloadPlugin
  , loadPlugin
  , getPluginProperty
  , getPluginProperty_
  ) where
import System.IO
import System.IO.Error (try, catch, isEOFError)
import System.Process
import System.FilePath
import System.Directory
import System.FilePath ((</>))

import Control.Concurrent
import Control.Concurrent.MVar (MVar)
import Control.Monad
import Control.Applicative
import Control.Exception (IOException)
import "mtl" Control.Monad.Error

import Network.SimpleIRC

import Text.JSON
import Text.JSON.Generic
import Text.JSON.Types

import Data.Maybe
import Data.List (isPrefixOf, find, delete)
import Data.Ratio (numerator)
import Data.Char (toLower)
import Data.ConfigFile


import qualified Data.ByteString.Char8 as B

import Types

data RPC = 
    RPCRequest
      { reqMethod :: B.ByteString
      , reqParams :: JSValue
      , reqId     :: Maybe Rational
      } 
  | RPCResponse 
      { rspResult :: B.ByteString
      , rspError  :: Maybe B.ByteString
      , rspID     :: Rational
      }
  deriving (Typeable, Show)
  
data Message = 
   MsgSend
    { servAddr :: B.ByteString
    , rawMsg   :: B.ByteString
    , sId      :: Int
    }
  | MsgCmdAdd
    { command  :: B.ByteString, caId :: Int }
  | MsgIrcAdd
    { code     :: B.ByteString, iaId :: Int }
    
  | MsgPid
    { pid      :: Int }
  deriving Show
  
data PluginCommand = PluginCommand
  -- Requests
  | PCMessage IrcMessage MIrc
  | PCCmdMsg  IrcMessage MIrc B.ByteString B.ByteString B.ByteString 
            -- IrcMessage, Server, prefix, 
            -- (the command.), (msg without prefix and without command)
  | PCQuit
  -- Responses
  | PCSuccess B.ByteString Int -- result message, id
  | PCError   B.ByteString Int -- error message, id

validateFields :: JSValue -> [String] -> Bool
validateFields (JSObject obj) fields =
  let exist = map (get_field obj) fields
  in all (isJust) exist

validateArray :: [JSValue] -> Int -> Bool
validateArray arr num = length arr == num 

-- -.-
getJSString :: JSValue -> B.ByteString
getJSString (JSString (JSONString s)) = B.pack s

getJSMaybe :: JSValue -> Maybe JSValue
getJSMaybe (JSNull) = 
  Nothing
getJSMaybe jsvalue = 
  Just jsvalue

getJSRatio :: JSValue -> Rational
getJSRatio (JSRational _ r) = r
getJSRatio _ = error "Not a JSRational."

errorResult :: Result a -> a
errorResult (Ok a) = a
errorResult (Error s) = error s

-- Turns the parsed JSValue into a RPC(Either a RPCRequest or RPCResponse)
jsToRPC :: JSValue -> RPC
jsToRPC js@(JSObject obj) 
  | validateFields js ["method", "params", "id"] =
    let rID = getJSMaybe $ fromJust $ get_field obj "id" 
    in RPCRequest 
         { reqMethod = getJSString $ fromJust $ get_field obj "method"
         , reqParams = fromJust $ get_field obj "params" 
         , reqId     = if isJust $ rID 
                          then Just $ getJSRatio $ fromJust rID
                          else Nothing 
         }

  -- TODO: RPCResponse -- Currently there are no Responses from the plugin.

-- This function just checks the reqMethod of RPCRequest.
rpcToMsg :: RPC -> Either (Int, B.ByteString) Message
rpcToMsg req@(RPCRequest method _ _)
  | method == "send"    = rpcToSend   req
  | method == "cmdadd"  = rpcToCmdAdd req
  | method == "ircadd"  = rpcToIrcAdd req
  | method == "pid"     = rpcToPID    req 

-- Turns an RPC(Which must be a RPCRequest with a method of "send") into a MsgSend.
rpcToSend :: RPC -> Either (Int, B.ByteString) Message
rpcToSend (RPCRequest _ (JSArray params) (Just id))
  | validateArray params 2 = 
    let server    = getJSString $ params !! 0
        msg       = getJSString $ params !! 1
    in Right $ MsgSend server msg numId
  -- PRIVMSG, NOTICE, JOIN, PART, KICK, TOPIC
  | validateArray params 3 =
    -- JOIN, TOPIC, NICK, QUIT
    let server = getJSString $ params !! 0
        cmd    = B.map toLower (getJSString $ params !! 1)
        chan   = getJSString $ params !! 2
    in case cmd of 
         "join"    -> Right $ 
           MsgSend server (showCommand (MJoin chan Nothing)) numId
         "topic"   -> Right $ 
           MsgSend server (showCommand (MTopic chan Nothing)) numId
         "nick"    -> Right $ 
           MsgSend server (showCommand (MNick chan)) numId
         otherwise -> Left (numId, "Invalid command, got: " `B.append` cmd)
  | validateArray params 4 =
    -- PRIVMSG, PART, TOPIC, INVITE, NOTICE, ACTION
    let server = getJSString $ params !! 0
        cmd    = B.map toLower (getJSString $ params !! 1)
        chan   = getJSString $ params !! 2
        msg    = getJSString $ params !! 3
    in case cmd of 
         "privmsg" -> Right $
            MsgSend server (foldl 
                              (\a m -> a `B.append` "\n" `B.append`
                                         showCommand (MPrivmsg chan m)) "" 
                                                     (B.lines msg))
                           numId
         "part"    -> Right $
            MsgSend server (showCommand (MPart chan msg)) numId
         "topic"   -> Right $ 
            MsgSend server (showCommand (MTopic chan (Just msg))) numId
         "notice"  -> Right $
            MsgSend server (showCommand (MNotice chan msg)) numId
         "action"  -> Right $
            MsgSend server (showCommand (MAction chan msg)) numId
         otherwise -> Left (numId, "Invalid command, got: " `B.append` cmd)
  | validateArray params 5 =
    -- KICK
    let server = getJSString $ params !! 0
        cmd    = B.map toLower (getJSString $ params !! 1)
        chan   = getJSString $ params !! 2
        usr    = getJSString $ params !! 3
        msg    = getJSString $ params !! 4
    in case cmd of
         "kick"    -> Right $
            MsgSend server (showCommand (MKick chan usr msg)) numId
         otherwise -> Left (numId, "Invalid command, got: " `B.append` cmd)
    
  where numId = fromIntegral $ numerator id
  
rpcToSend (RPCRequest _ (JSArray params) Nothing) = 
  error "id is Nothing, expected something."

rpcToCmdAdd :: RPC -> Either (Int, B.ByteString) Message
rpcToCmdAdd (RPCRequest _ (JSArray params) (Just id)) = 
  Right $ MsgCmdAdd cmd (fromIntegral $ numerator id)
  where cmd = getJSString $ params !! 0

rpcToCmdAdd (RPCRequest _ (JSArray params) Nothing) = 
  error "id is Nothing, expected something."

rpcToIrcAdd :: RPC -> Either (Int, B.ByteString) Message
rpcToIrcAdd (RPCRequest _ (JSArray params) (Just id)) = 
  Right $ MsgIrcAdd code (fromIntegral $ numerator id)
  where code = getJSString $ params !! 0

rpcToIrcAdd (RPCRequest _ (JSArray params) Nothing) = 
  error "id is Nothing, expected something."

rpcToPID :: RPC -> Either (Int, B.ByteString) Message
rpcToPID (RPCRequest _ (JSArray params) _) =
  Right $ MsgPid (read pid) -- TODO: Check whether it's an int.
  where pid = B.unpack $ getJSString $ params !! 0

decodeMessage :: String -> Either (Int, B.ByteString) Message
decodeMessage xs = rpcToMsg $ jsToRPC parsed
  where parsed = errorResult $ decode xs 
  
-- Writing JSON ----------------------------------------------------------------

showJSONMaybe :: (JSON t) => Maybe t -> JSValue
showJSONMaybe (Just a)  = showJSON a
showJSONMaybe (Nothing) = JSNull

showJSONIrcMessage :: IrcMessage -> JSValue
showJSONIrcMessage msg =
  JSObject $ toJSObject $
    [("nick", showJSONMaybe (mNick msg))
    ,("user", showJSONMaybe (mUser msg))
    ,("host", showJSONMaybe (mHost msg))
    ,("server", showJSONMaybe (mServer msg))
    ,("code", showJSON (mCode msg))
    ,("msg", showJSON (mMsg msg))
    ,("chan", showJSONMaybe (mChan msg))
    ,("origin", showJSONMaybe (mOrigin msg))
    ,("other", showJSONMaybe (mOther msg))
    ,("raw", showJSON (mRaw msg))
    ]

showJSONMIrc :: MIrc -> IO JSValue
showJSONMIrc s = do
  addr <- getAddress s
  nick <- getNickname s
  user <- getUsername s
  chans <- getChannels s
  
  return $ JSObject $ toJSObject $
    [("address", showJSON $ addr)
    ,("nickname", showJSON $ nick)
    ,("username", showJSON $ user)
    ,("chans", showJSON $ chans)
    ]

showJSONCommand :: PluginCommand -> IO JSValue
showJSONCommand (PCMessage msg serv) = do
  servJSON <- showJSONMIrc serv
  return $ JSObject $ toJSObject $
    [("method", showJSON ("recv" :: String))
    ,("params", JSArray [showJSONIrcMessage msg, servJSON])
    ,("id", JSNull)
    ]

showJSONCommand (PCCmdMsg msg serv prefix cmd rest) = do
  servJSON <- showJSONMIrc serv
  return $ JSObject $ toJSObject $
    [("method", showJSON ("cmd" :: String))
    ,("params", JSArray [showJSONIrcMessage msg, 
                         servJSON, showJSON prefix, showJSON cmd, showJSON rest])
    ,("id", JSNull)
    ]

showJSONCommand (PCQuit) = do
  return $ JSObject $ toJSObject $
    [("method", showJSON ("quit" :: String))
    ,("params", JSArray [])
    ,("id", JSNull)
    ]

showJSONCommand (PCSuccess msg id) = do
  return $ JSObject $ toJSObject $
    [("result", showJSON msg)
    ,("error", JSNull)
    ,("id", showJSON id)
    ]

showJSONCommand (PCError err id) = do
  return $ JSObject $ toJSObject $
    [("result", showJSON ("error" :: String))
    ,("error", showJSON err)
    ,("id", showJSON id)
    ]

-- End of JSON -----------------------------------------------------------------

readConfig plugin filename = do
  readfile emptyCP filename >>= (getData plugin) . handleError

handleError :: Either (CPErrorData, [Char]) a -> a
handleError x =
  case x of
    Left (ParseError err, err') -> error $ "Parse error: \n"
                                   ++ err ++ "\n" ++ err'
    Left err                    -> error $ show err
    Right c                     -> c

getData plugin cp = do
  config <- runErrorT $ do
    name <- get cp "DEFAULT" "name"
    desc <- get cp "DEFAULT" "description"
    depends <- get cp "DEFAULT" "depends"
    language <- get cp "DEFAULT" "language"
    
    return $! plugin { pName = (B.pack name), pDescription = (B.pack desc),
                       pDepends = (readLst "depends" depends), 
                       pLanguage = (B.pack language) }

  return $ handleError config

readLst :: String -> String -> [B.ByteString]
readLst opt [] = []
readLst opt xs
  | "," `isPrefixOf` xs = error $ "Invalid list for \"" ++ opt ++ "\""
  | otherwise = 
    (noSpace first) : (readLst opt $ drop 1 $ dropWhile (/= ',') second)
    where (first, second) = break (== ',') xs
          noSpace f       = B.pack $ takeWhile (/= ' ') (dropWhile (== ' ') f)
  
-- End of config reading -------------------------------------------------------

isCorrectDir dir f = do
  r <- doesDirectoryExist (dir </> f)
  return $ r && f /= "." && f /= ".." && not ("." `isPrefixOf` f)

stopPlugin :: MVar Plugin -> IO ()
stopPlugin mPlugin = do
  writeCommand PCQuit mPlugin
  plugin <- readMVar mPlugin
  -- TODO: Add a small delay, to give the plugin time to shutdown.
  terminateProcess (pPHandle plugin)

runPlugins :: IO [MVar Plugin]
runPlugins = do
  contents  <- getDirectoryContents "Plugins/"
  fContents <- filterM (isCorrectDir "Plugins/") contents
  
  mapM (runPlugin) fContents
  
runPlugin :: String -> IO (MVar Plugin)
runPlugin plDir = do
  currWorkDir <- getCurrentDirectory
  let plWorkDir = currWorkDir </> "Plugins/" </> plDir
      shFile    = plWorkDir </> "run.sh"
      iniFile   = plWorkDir </> (plDir ++ ".ini") 
  putStrLn $ "-- " ++ plWorkDir
  (inpH, outH, errH, pid) <- runInteractiveProcess ("./run.sh") [] (Just plWorkDir) Nothing
  hSetBuffering outH LineBuffering
  hSetBuffering errH LineBuffering
  hSetBuffering inpH LineBuffering

  let plugin = Plugin (B.pack plDir) "" [] "" outH errH inpH pid Nothing [] [] False []
  configPlugin <- readConfig plugin iniFile
  newMVar $ configPlugin

getAllLines :: Handle -> IO [String]
getAllLines h = liftA2 (:) first rest `catch` (\_ -> return []) 
  where first = hGetLine h
        rest = getAllLines h

getErrs :: Plugin -> IO String
getErrs plugin = do
  -- hGetContents is lazy, getAllLines is a non-lazy hGetContents :D
  contents <- getAllLines (pStderr plugin)
  return $ unlines contents

-- NOTE: This function should only return True *once*; the first time it gets
--       the pid message.
eventsPlugin :: MVar MessageArgs -> MVar Plugin 
                -> String
                -> IO Bool -- whether to stop waiting for pid
eventsPlugin mArgs mPlugin line = do
  plugin <- readMVar mPlugin
  let decoded = decodeMessage line
  case decoded of
    Right (MsgSend addr msg id) -> do 
      ret <- sendRawToServer mArgs addr msg
      if ret
        then writeCommand (PCSuccess "Message sent." id) mPlugin
        else writeCommand (PCError "Server doesn't exist." id) mPlugin
      return False
    Right (MsgPid pid)          -> do
      _ <- swapMVar mPlugin (plugin {pPid = Just pid})
      -- NOTE: This checks whether the 'old' plugin had the pid.
      --       we don't want a new thread everytime the plugin
      --       sends the pid message.
      if isJust (pPid plugin)
        then return False
        else return True
    Right (MsgCmdAdd cmd id)    -> do 
      _ <- swapMVar mPlugin (plugin {pCmds = cmd:pCmds plugin}) 
      writeCommand (PCSuccess "Command added." id) mPlugin
      return False
    Right (MsgIrcAdd code id)    -> do 
      _ <- swapMVar mPlugin (
           plugin {pCodes = (B.map toLower code):pCodes plugin})
      writeCommand (PCSuccess "IRC Command added." id) mPlugin
      return False
    Left  (id, err)             -> do
      writeCommand (PCError err id) mPlugin
      return False


pluginLoop :: MVar MessageArgs -> MVar Plugin -> IO ()
pluginLoop mArgs mPlugin = do
  plugin <- readMVar mPlugin
  
  -- This will wait until some output appears, and let us know when
  -- stdout is EOF
  outEof <- hIsEOF (pStdout plugin)

  if not outEof
    then do
      line <- hGetLine (pStdout plugin)
      putStrLn $ "Got line from plugin(" ++ (B.unpack $ pName plugin) ++ "): " ++ line
      
      if ("{" `isPrefixOf` line) -- Make sure the line starts with {
        then do stopWait <- eventsPlugin mArgs mPlugin line
                if stopWait
                  then do forkIO (pluginLoop mArgs mPlugin)
                          return ()
                  else pluginLoop mArgs mPlugin
        else pluginLoop mArgs mPlugin
      
    else do
      -- Get the error message
      errs <- getErrs plugin

      -- Plugin crashed
      putStrLn $ "WARNING: Plugin(" ++ (B.unpack $ pName plugin) ++ ") crashed, " ++ 
                 errs
      args <- takeMVar mArgs
      let filt = filter (mPlugin /=) (plugins args)
      putMVar mArgs (args {plugins = filt})

compareAddr :: B.ByteString -> B.ByteString -> Bool
compareAddr addr properAddr =
  if "*." `B.isPrefixOf` addr
    then (B.drop 2 addr) `B.isSuffixOf` properAddr
    else addr == properAddr

sendRawToServer :: MVar MessageArgs -> B.ByteString -> B.ByteString -> IO Bool
sendRawToServer mArgs server msg = do
  args <- readMVar mArgs 
  servers <- readMVar $ argServers args
  filtered <- filterM (\srv -> do addr <- getAddress srv
                                  return $ server `compareAddr` addr) 
                         servers
  if not $ null filtered
    then do forM filtered ((flip sendRaw) msg)
            return True
    else return False

writeCommand :: PluginCommand -> MVar Plugin -> IO ()
writeCommand cmd mPlugin = do
  plugin <- readMVar mPlugin
  
  (JSObject json) <- showJSONCommand cmd
  let js = ((showJSObject json) "")
  --putStrLn $ "Sending to plugin: " ++ (showJSObject json) ""
  hPutStrLn (pStdin plugin) js -- TODO: Check for errors, if elysia tries to
                               -- use this function after the plugin crashes,
                               -- it will fail.

pluginHasCode :: B.ByteString -> MVar Plugin -> IO Bool
pluginHasCode code mPlugin = do
  plugin <- readMVar mPlugin
  if pAllCodes plugin
    then return True
    else return $ (B.map toLower code) `elem` (pCodes plugin)

-- Get's called whenever a message is received by a server.
messagePlugin :: MVar MessageArgs -> EventFunc
messagePlugin mArgs s m = do
  args <- readMVar mArgs
  mapM_ (condWrite) (plugins args)

  where condWrite p = do
          hasCode <- pluginHasCode (mCode m) p
          if hasCode
            then writeCommand (PCMessage m s) p
            else return ()

findPlugin :: MVar MessageArgs -> B.ByteString -> IO (Maybe (MVar Plugin))
findPlugin mArgs name = do
  args <- readMVar mArgs
  pls <- filterM (\p -> do pl <- readMVar p
                           return $ (B.map toLower $ pName pl) == (B.map toLower name))
                 (plugins args)
  if null pls
    then return Nothing
    else return $ Just (pls !! 0)

loadPlugin :: MVar MessageArgs -> B.ByteString -> IO Bool
loadPlugin mArgs name = do
  currWorkDir <- getCurrentDirectory
  let plWorkDir = currWorkDir </> "Plugins/" </> (B.unpack name)
  dirExist <- doesDirectoryExist plWorkDir
  if dirExist
    then do plugin <- runPlugin (B.unpack name)
            pluginLoop mArgs plugin
            modifyMVar_ mArgs (\a -> return $ a {plugins =  plugin:(plugins a)})
            return True
    else return False


unloadPlugin :: MVar MessageArgs -> B.ByteString -> IO Bool
unloadPlugin mArgs name = do
  pl <- findPlugin mArgs name
  if isJust pl
    then do stopPlugin (fromJust pl)
            modifyMVar_ mArgs 
                        (\arg -> return $
                                 arg {plugins = (delete (fromJust pl) $ 
                                          plugins arg)})
            return True
    else return False

getPluginProperty_ :: MVar Plugin -> (Plugin -> a) -> IO a
getPluginProperty_ mPlugin prop = do
  plugin <- readMVar mPlugin
  return $ prop plugin

getPluginProperty :: MVar MessageArgs -> B.ByteString -> (Plugin -> a) -> IO (Maybe a)
getPluginProperty mArgs name prop = do
  pl <- findPlugin mArgs name
  if isJust pl
    then do ret <- getPluginProperty_ (fromJust pl) prop
            return $ Just ret
    else return Nothing
