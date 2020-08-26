{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Main (main) where

import           Control.Applicative
import           Control.Concurrent
import           Control.Exception
import           Control.Monad
import           Data.Bits
import           Data.ByteString                (ByteString)
import qualified Data.ByteString                as BS
import           Data.Char                      (toLower)
import           Data.Hashable
import           Data.IntSet                    (IntSet)
import qualified Data.IntSet as IntSet
import           Data.IORef
import           Data.List
import           Data.Maybe
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import qualified Data.Text.IO                   as T
import           Data.Time
import           Data.Time.Format
import           GitHash
import           Language.Haskell.Exts.Parser
import           Language.Haskell.Exts.Pretty
import           Language.Haskell.Exts.SrcLoc   (SrcSpanInfo, noSrcSpan)
import           Language.Haskell.Exts.Syntax
import           Language.Haskell.Ghcid
import           Network.Wai.Application.Static
import           Network.Wai.Handler.Warp
import           Network.WebSockets
import           System.Directory
import           System.Environment
import           System.Exit
import           System.FilePath
import           System.IO.Temp
import           System.IO
import           System.Process
import           System.Timeout
import           Text.Printf

gi :: GitInfo
gi = $$tGitInfoCwd

playgroundCommitDate :: UTCTime
Just playgroundCommitDate = parseTimeM
  True
  defaultTimeLocale
  "%a %b %e %X %Y %z" (giCommitDate gi)

playgroundVersion :: Text
playgroundVersion = T.pack $
  formatTime defaultTimeLocale "%F" playgroundCommitDate ++
  " (" ++ take 5 (giHash gi) ++ ")"

computeLimit :: Int
computeLimit = 15 * 10^(6::Int) -- 15 seconds

-- Maximum size of error messages
charLimit :: Int
charLimit = 2000

memoryLimit :: String
memoryLimit = "-M1G"

frameRate :: Int
frameRate = 30

main :: IO ()
main = do
  backend <- newBackend
  args <- getArgs
  case args of
    ["test"] -> putStrLn "Test OK"
    ["snippets", folder] -> do
      files <- sort <$> getDirectoryContents folder
      ghci <- takeMVar (backendGhci backend)
      snippets <- mapM (genSnippet ghci)
        [ folder </> file
        | file <- files, takeExtension file == ".hs" ]
      putStr "const snippets = "
      putStrLn $
        "[" ++ intercalate ","
        [ "{" ++
          "\"title\": " ++ show title ++ "," ++
          "\"url\": " ++ show url ++ "," ++
          "\"code\": " ++ show inp ++
          "}\n  "
        | (title, url, inp) <- snippets ] ++
        "];"
      putStrLn $ "const playgroundVersion = " ++ show playgroundVersion ++ ";"
    [] -> do
      root <- cacheDir
      tid <- forkIO $ run 10162 (staticApp $ defaultWebAppSettings root)
      serverMain backend `finally` killThread tid
    _ -> do
      hPutStrLn stderr "Invalid arguments"
      exitWith (ExitFailure 1)

genSnippet :: Ghci -> FilePath -> IO (String, String, Text)
genSnippet ghci path = do
    inp <- T.readFile path
    let ParseOk m = parseHaskell inp
        h = sourceHash m
    withHaskellFile m $ \hsFile -> do
      _ <- reqGhcOutput ghci $ ":load " ++ hsFile
      out <- reqGhcOutput ghci "Reanimate.duration animation"
      let dur = read (unlines out) :: Double
          frames = round (dur * fromIntegral frameRate) :: Int
          url = "https://reanimate.clozecards.com/" ++ h ++ "/" ++ show (frames `div` 2) ++ ".svg"
          title = takeWhileEnd (/= '_') (takeBaseName path)
      return (title, url, inp)
  where
    takeWhileEnd f = reverse . takeWhile f . reverse


opts :: ConnectionOptions
opts = defaultConnectionOptions
  { connectionCompressionOptions = PermessageDeflateCompression defaultPermessageDeflate }

serverMain :: Backend -> IO ()
serverMain backend = do
  let options = ServerOptions
        { serverHost = "0.0.0.0"
        , serverPort = 10161
        , serverConnectionOptions = opts
        , serverRequirePong = Nothing }
  runServerWithOptions options $ \pending -> do
    logMsg "New connection received."
    conn <- acceptRequest pending
    requestHandler backend conn

requestHandler :: Backend -> Connection -> IO ()
requestHandler backend conn = loop =<< newMVar True
  where
    loop wantLastRequest = do
      msg <- receiveData conn :: IO T.Text
      _ <- swapMVar wantLastRequest False

      wantThisRequest <- newMVar True
      case parseHaskell msg of
        ParseFailed _ msg -> sendWebMessage conn (WebError msg)
        ParseOk m -> do

          requestRender backend $ Render
            { renderCode       = m
            , renderHash       = sourceHash m
            , renderFrameCount = \i -> sendWebMessage conn (WebFrameCount i)
            , renderFrameReady = \i path -> sendWebMessage conn (WebFrame i path)
            , renderError      = \msg -> sendWebMessage conn (WebError msg)
            , renderWanted     = wantThisRequest
            }
      loop wantThisRequest

data Backend = Backend
  { backendGhci  :: MVar Ghci
  , backendQueue :: MVar Render
  }

data CacheResult
  = CacheMiss
  | CacheHit Int
  | CacheHitPartial Int IntSet
  deriving (Show)

checkCache :: String -> IO CacheResult
checkCache key = handle (\SomeException{} -> pure CacheMiss) $ do
  root <- cacheDir
  let svgFolder = root </> key
      framesFile = svgFolder </> "frames"
  framesTxt <- readFile framesFile
  frames <- case reads framesTxt of
    [(frames,"")] -> pure frames
    _ -> error "Bad parse"
  files <- listDirectory svgFolder
  let set = IntSet.fromList
        [ idx
        | file <- map dropExtension files
        , (idx,"") <- reads file
        ]
  if IntSet.size set == frames
    then pure $ CacheHit frames
    else pure $ CacheHitPartial frames set

data Render = Render
  { renderCode       :: Module SrcSpanInfo
  , renderHash       :: String
  , renderFrameCount :: Int -> IO ()
  , renderFrameReady :: Int -> FilePath -> IO ()
  , renderError      :: String -> IO ()
  , renderWanted     :: MVar Bool
  }

requestRender :: Backend -> Render -> IO ()
requestRender backend render = do
  cache <- checkCache (renderHash render)
  logMsg $ "Cache: " ++ show cache
  case cache of
    CacheMiss -> void $ forkIO $ putMVar (backendQueue backend) render
    CacheHit frames -> do
      renderFrameCount render frames
      forM_ [0..frames-1] $ \i -> do
        let path = renderHash render </> show i <.> "svg"
        renderFrameReady render i path
    CacheHitPartial frames frameSet -> do
      renderFrameCount render frames
      forM_ (IntSet.toList frameSet) $ \i -> do
        let path = renderHash render </> show i <.> "svg"
        renderFrameReady render i path
      void $ forkIO $ putMVar (backendQueue backend) render

newGhci :: IO Ghci
newGhci = do
  let fastProc = proc "stack" ["exec", "ghci", "--rts-options="++memoryLimit]
  (fastGhci, _loads) <- startGhciProcess fastProc (\_stream msg -> hPutStrLn stderr msg)

  void $ reqGhcOutput fastGhci "import qualified Reanimate"
  void $ reqGhcOutput fastGhci "import qualified Reanimate.Render as Reanimate"
  return fastGhci

newBackend :: IO Backend
newBackend = do
  ghciRef <- newMVar =<< newGhci
  queue <- newEmptyMVar
  tid <- forkIO $ forever $ do
    req <- takeMVar queue
    guardWanted req $ withHaskellFile (renderCode req) $ \hs -> do
      ghci <- readMVar ghciRef
      guardGhci req ghci (":load " ++ hs) $ \_ -> guardWanted req $
        guardGhci req ghci "Reanimate.duration animation" $ \out -> do
          root <- cacheDir
          let dur = read (unlines out) :: Double
              frameCount = round (dur * fromIntegral frameRate) :: Int
              durFile = root </> renderHash req </> "frames"
          createDirectoryIfMissing True (root </> renderHash req)
          writeFile durFile (show frameCount)
          renderFrameCount req frameCount
          renderFrames req ghci
  return $ Backend ghciRef queue
  where
    renderFrames req ghci = guardWanted req $ do
      root <- cacheDir
      let svgFolder = root </> renderHash req
      createDirectoryIfMissing True svgFolder
      let cmd = printf "Reanimate.renderOneFrame \"%s\" 0 False %d animation" svgFolder frameRate
      guardGhci req ghci cmd $ \out ->
        case unlines out of
          "Done\n" -> return ()
          _ -> do
            let frameIdx = read (unlines out)
                path = renderHash req </> show frameIdx <.> "svg"
            renderFrameReady req frameIdx path
            renderFrames req ghci
    guardGhci req ghci cmd action = do
      (err, out) <- splitGhciOutput ghci cmd
      if not (null err)
        then do
          logMsg $ "Error:\n" ++ unlines err
          renderError req (unlines err)
        else action out
    guardWanted req action = do
      wanted <- readMVar (renderWanted req)
      unless wanted $ logMsg "Results no longer wanted"
      when wanted action

cacheDir :: IO FilePath
cacheDir = do
  root <- getXdgDirectory XdgCache "reanimate-playground"
  createDirectoryIfMissing True root
  return root

withHaskellFile :: Module SrcSpanInfo -> (FilePath -> IO a) -> IO a
withHaskellFile m action = withSystemTempFile "playground.hs" $ \target h -> do
    hClose h
    T.writeFile target
      "{-# LANGUAGE OverloadedStrings #-}\n\
      \module Animation where\n\
      \import Reanimate\n\
      \import Reanimate.Builtin.Documentation\n\
      \import Reanimate.Builtin.Images\n\
      \import Reanimate.Builtin.CirclePlot\n\
      \import Reanimate.Builtin.TernaryPlot\n\
      \import Reanimate.Builtin.Slide\n\
      \import Geom2D.CubicBezier.Linear\n\
      \import Reanimate.Transition\n\
      \import Reanimate.Morph.Common\n\
      \import Reanimate.Morph.Linear\n\
      \import Reanimate.Scene\n\
      \import qualified Graphics.SvgTree as SVG\n\
      \import Control.Lens\n\
      \import qualified Data.Text as T\n\
      \import Linear.V2\n\
      \import Linear.Metric\n\
      \import Linear.Vector\n\
      \import Text.Printf\n\
      \import Codec.Picture.Types\n\
      \{-# LINE 1 \"playground\" #-}\n"
    T.appendFile target $ T.pack $ prettyPrint m
    action target

splitGhciOutput :: Ghci -> String -> IO ([String], [String])
splitGhciOutput ghci cmd = do
  out <- newIORef []
  err <- newIORef []
  execStream ghci cmd $ \strm msg ->
    case strm of
      Stdout -> modifyIORef out (++[msg])
      Stderr -> modifyIORef err (++[msg])
  (,) <$> readIORef err <*> readIORef out

reqGhcOutput :: Ghci -> String -> IO [String]
reqGhcOutput ghci cmd = do
  (err, out) <- splitGhciOutput ghci cmd
  unless (null err) $
    error (unlines err)
  return out

logMsg :: String -> IO ()
logMsg msg = do
    now <- getCurrentTime
    putStrLn $ formatTime defaultTimeLocale fmt now ++ ": " ++ msg
  where
    fmt = "%F %T%2Q"

encodeInt :: Int -> String
encodeInt i = worker (fromIntegral i) 60
  where
    worker :: Word -> Int -> String
    worker key sh
      | sh < 0 = []
      | otherwise =
        case (key `shiftR` sh) `mod` 64 of
          idx -> alphabet !! fromIntegral idx : worker key (sh-6)
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+$"

sourceHash :: Module SrcSpanInfo -> String
sourceHash = encodeInt . hash . prettyPrint

parseHaskell :: Text -> ParseResult (Module SrcSpanInfo)
parseHaskell txt =
    clean <$> parse (T.unpack txt)
  where
    -- mHead = ModuleHead noSrcSpan (ModuleName noSrcSpan "Animation") Nothing Nothing
    clean (Module _ _ _ _ decls) =
      Module noSrcSpan Nothing [] [] (sort decls)
    clean _ =
      Module noSrcSpan Nothing [] [] []

data WebMessage
  = WebStatus String
  | WebError String
  | WebFrameCount Int
  | WebFrame Int FilePath

sendWebMessage :: Connection -> WebMessage -> IO ()
sendWebMessage conn msg = sendTextData conn $
  case msg of
    WebStatus txt   -> T.pack "status\n" <> T.pack txt
    WebError txt    -> T.pack "error\n" <> T.pack txt
    WebFrameCount n -> T.pack $ "frame_count\n" ++ show n
    WebFrame n path -> T.pack $ "frame\n" ++ show n ++ "\n" ++ path

