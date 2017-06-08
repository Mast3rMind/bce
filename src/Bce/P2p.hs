{-# LANGUAGE DeriveGeneric #-}

module Bce.P2p where

import Bce.Util
    
import Data.Binary
import GHC.Generics (Generic)
import GHC.Int (Int32)
import Control.Concurrent
import Control.Concurrent.STM    
import Control.Monad
import Control.Monad.Trans
import Control.Applicative   
import Data.Either
import Data.Maybe    
import qualified Control.Monad.Trans.State as State
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Network.Socket.ByteString as SBS    
import qualified Network.Socket as Sock
import qualified Data.Binary as Bin
import qualified Data.Binary.Get as BinGet
import qualified Data.Binary.Put as BinPut    
import qualified Data.Set as Set
import qualified Control.Exception as Exception    


data P2pConfig = P2pConfig {
      p2pConfigBindAddress :: PeerAddress
    , p2pConfigReconnectTimeout :: Int
    , p2pConfigAnnounceTimeout :: Int                                   
      } deriving (Show)


data PeerAddress = PeerAddress {
      peerIp :: String
    , peerPort :: Int32
      } deriving (Show, Eq, Generic, Ord)
instance Binary PeerAddress                                          


data P2p = P2p {
      p2pConfig :: P2pConfig
    , p2pPeers :: TVar (Set.Set PeerAddress)
    , p2pConnectedPeers :: TVar (Set.Set PeerAddress)
    , p2pConnectingPeers :: TVar (Set.Set PeerAddress)                           
    , p2pRecvChan :: TChan PeerEvent
    , p2pSendChan :: TChan PeerSend
      } 


data P2pMessage =
                P2pMessageHello PeerAddress
                | P2pMessageAnounce (Set.Set PeerAddress)
                | P2pMessagePayload BS.ByteString
                deriving (Show, Eq, Generic)
instance Binary P2pMessage

data P2pClientState = P2pClientState {
      clientStateDecoder :: BinGet.Decoder P2pMessage
    , clientStatePeer :: Maybe PeerAddress
      }

clientStateUpdateDecoder :: BinGet.Decoder P2pMessage -> P2pClientState -> P2pClientState
clientStateUpdateDecoder newDecoder p2pState  =
    P2pClientState newDecoder $ clientStatePeer p2pState
clientStateUpdatePeer :: PeerAddress -> P2pClientState -> P2pClientState
clientStateUpdatePeer newPeer p2pState  =
    P2pClientState (clientStateDecoder p2pState) $ Just newPeer


data PeerEvent = PeerDisconnected PeerAddress
                 | PeerMessage PeerAddress BS.ByteString  deriving (Show, Eq)

data PeerSend = PeerSend { sendMsg :: BS.ByteString, sendDestination :: Maybe PeerAddress } deriving (Show, Eq)

msgDecoder :: BinGet.Get P2pMessage
msgDecoder = do
  msgLen <- BinGet.getInt64le
  msgBs <- BinGet.getLazyByteString (fromIntegral msgLen) 
  return $ BinGet.runGet Bin.get msgBs :: BinGet.Get P2pMessage  

pollMessageFromClienBuffer :: BS.ByteString ->  State.StateT P2pClientState IO (Maybe P2pMessage)
pollMessageFromClienBuffer bs = do
    decoder <- clientStateDecoder <$> State.get
    olds <- State.get
    let nextDecoder = BinGet.pushChunk decoder bs  :: BinGet.Decoder P2pMessage
    case nextDecoder of
      BinGet.Fail _ _ _ -> error "msg decoding failed"
      BinGet.Partial _ -> do
          State.put (clientStateUpdateDecoder nextDecoder olds)
          return Nothing
      BinGet.Done leftover _ msg -> do
          let leftoverDecoder = BinGet.runGetIncremental msgDecoder
          State.put (clientStateUpdateDecoder (BinGet.pushChunk leftoverDecoder leftover) olds)
          return $ Just msg

clientRecvLoop :: Sock.Socket -> Sock.SockAddr -> P2p -> State.StateT P2pClientState IO ()
clientRecvLoop sock addr p2p =
    do
      olds <- State.get      
      s <- liftIO $ SBS.recv sock 1024
      if BS.length s > 0
      then do
          msgOpt <- pollMessageFromClienBuffer s
          case msgOpt of
            Nothing -> clientRecvLoop sock addr p2p
            Just msg ->
                case msg of
                  P2pMessageHello peer -> do
                           liftIO $ putStrLn $ "hello from " ++ show peer
                           liftIO $ atomically $ do
                             writeTVar (p2pPeers p2p)
                                           <$> (Set.insert peer <$> readTVar (p2pPeers p2p))
                             writeTVar (p2pConnectedPeers p2p)
                                           <$> (Set.insert peer <$> readTVar (p2pConnectedPeers p2p))
                           oldState <- State.get
                           liftIO $ forkIO $ clientSendLoop sock peer p2p
                           State.put $ clientStateUpdatePeer peer oldState
                           return ()
                  P2pMessageAnounce peers -> do
                           liftIO $ atomically $ do
                                  writeTVar (p2pPeers p2p) <$> (Set.union peers <$> (readTVar $ p2pPeers p2p))
                                  return ()
                  P2pMessagePayload userMsg -> do
                        -- TODO: check do we have bloody peer
                        peer <- fromJust <$> clientStatePeer <$> State.get
                        liftIO $ atomically $ writeTChan (p2pRecvChan p2p)
                                   (PeerMessage peer userMsg)
          clientRecvLoop sock addr p2p
      else do
        peer <- clientStatePeer <$> State.get
        case peer of
          Just peerAddress -> 
              liftIO $ atomically $ do
                    writeTVar (p2pConnectedPeers p2p)
                                  <$> (Set.delete peerAddress <$> readTVar (p2pConnectedPeers p2p))
                    writeTChan (p2pRecvChan p2p) (PeerDisconnected peerAddress)
          Nothing -> pure ()
        return ()

encodeMsg :: P2pMessage -> BS.ByteString
encodeMsg msg =
    let payload = BinPut.runPut $ Bin.put msg
        payloadSize = BinPut.runPut (BinPut.putWord64le $ fromIntegral (BSL.length payload))
    in BSL.toStrict $ mappend payloadSize payload

clientSendLoop :: Sock.Socket -> PeerAddress ->  P2p -> IO ()
clientSendLoop sock peerAddr p2p = do
    chan <- atomically $ dupTChan $ p2pSendChan p2p
    let loop = do
          snd <- atomically $ readTChan chan
          let encodedMsg = encodeMsg (P2pMessagePayload $ sendMsg snd) 
          case sendDestination snd of
            Nothing -> SBS.send sock encodedMsg
            Just dst -> if dst == peerAddr
                        then SBS.send sock encodedMsg
                        else return 0
          loop 
    loop

                    
handlePeer :: Sock.Socket -> Sock.SockAddr -> P2p -> IO ()
handlePeer sock addr p2p = do
  forkIO (State.evalStateT (clientRecvLoop sock addr p2p)
                   (P2pClientState (BinGet.runGetIncremental msgDecoder) Nothing))
  return ()

serverMainLoop :: Sock.Socket -> P2p -> IO ()
serverMainLoop sock p2p =
    forever $ do
      (conn, addr) <- Sock.accept sock
      handlePeer conn addr p2p
      return ()



startServerListener :: P2pConfig -> P2p -> IO ()
startServerListener config p2p  = do                       
  sock <- Sock.socket Sock.AF_INET Sock.Stream 0
  Sock.setSocketOption sock Sock.ReuseAddr 1
  Sock.bind sock (Sock.SockAddrInet (fromIntegral $ peerPort $ p2pConfigBindAddress config) Sock.iNADDR_ANY)
  Sock.listen sock 2
  forkIO $ serverMainLoop sock p2p
  return ()

peerAddressToSockAddr :: PeerAddress -> Sock.SockAddr
peerAddressToSockAddr (PeerAddress host port) =
    Sock.SockAddrInet (fromIntegral port) readedHost
        where readedHost = Sock.tupleToHostAddress $ read host

reconnectPeer :: P2p -> PeerAddress -> IO ()
reconnectPeer p2p peerAddress = do
      putStrLn $ "reconnecting peer" ++ show peerAddress
      proceed <- atomically $ do
                   isConnecting <- Set.member peerAddress <$> readTVar (p2pConnectingPeers p2p)
                   isConnected <- Set.member peerAddress <$> readTVar (p2pConnectedPeers p2p)
                   let r  = or [isConnecting, isConnected]
                   if  r 
                   then return False
                   else do
                     writeTVar (p2pConnectingPeers p2p) <$>
                                   (Set.insert peerAddress <$> readTVar (p2pConnectingPeers p2p))
                     return True
      if not proceed
      then do
          putStrLn $ "already connecting to " ++ show peerAddress
          return()
      else do
        let removeFromConnecting = do
                                  oldConnecting <- readTVar $ p2pConnectingPeers p2p
                                  writeTVar (p2pConnectingPeers p2p) (Set.delete peerAddress oldConnecting)
        sock <- Sock.socket Sock.AF_INET Sock.Stream 0
        success <- Exception.try $
                         do
                           Sock.connect sock $ peerAddressToSockAddr peerAddress
                           putStrLn $ "connected to " ++ show peerAddress
        case success of
          Right _ -> do
             SBS.send sock $ encodeMsg $ P2pMessageHello $ p2pConfigBindAddress $ p2pConfig p2p
             atomically $ do
                       oldConnected <- readTVar (p2pConnectedPeers p2p)
                       writeTVar (p2pConnectedPeers p2p) (Set.insert peerAddress oldConnected)
                       removeFromConnecting
             forkIO $ handlePeer sock (peerAddressToSockAddr peerAddress) p2p
             return ()
          Left err -> do
             putStrLn $  "connect failed to " ++ show peerAddress
                          ++ "; err: " ++ show (err::Exception.IOException)
             atomically removeFromConnecting


reconnectorLoop :: P2p -> IO ()
reconnectorLoop p2p = do
    threadDelay (secondsToMicroseconds $ p2pConfigReconnectTimeout $ p2pConfig p2p)
    toConnect <- atomically $ do
                        all <- readTVar $ p2pPeers p2p
                        connected <- readTVar $ p2pConnectedPeers p2p
                        return $ (Set.\\) all connected
    forM_ toConnect (\p -> forkIO $ reconnectPeer p2p p)
    reconnectorLoop p2p

announcerLoop :: P2p -> IO ()
announcerLoop p2p =
    let loop = do
          threadDelay (secondsToMicroseconds $ p2pConfigAnnounceTimeout $ p2pConfig p2p)
          (peersToAnnounce, toPeers) <- atomically $ do
                                        (,) <$> (readTVar $ p2pPeers p2p)
                                                 <*> (readTVar $ p2pConnectedPeers p2p)
          putStrLn $ "announcing peers" ++ show peersToAnnounce ++ " to " ++ show toPeers
          broadcast p2p $ P2pMessageAnounce peersToAnnounce
          loop
    in loop

start :: [PeerAddress] -> P2pConfig -> IO P2p
start seeds config = do
  p2p <- P2p config <$> newTVarIO (Set.fromList seeds) <*> newTVarIO Set.empty
         <*> newTVarIO Set.empty <*> newTChanIO <*> newTChanIO
  forkIO $ startServerListener config p2p
  forkIO $ reconnectorLoop p2p
  forkIO $ announcerLoop p2p
  return p2p

broadcast :: P2p -> P2pMessage -> IO ()
broadcast p2p msg = do
    atomically $ writeTChan (p2pSendChan p2p) (PeerSend (encodeMsg msg) Nothing)

send :: P2p -> PeerAddress -> P2pMessage -> IO ()
send p2p peer msg =
        atomically $ writeTChan (p2pSendChan p2p) (PeerSend (encodeMsg msg) $ Just peer)

broadcastPayload :: P2p -> BS.ByteString -> IO ()
broadcastPayload p2p payload = broadcast p2p $ P2pMessagePayload payload

sendPayload :: P2p -> PeerAddress -> BS.ByteString -> IO ()
sendPayload p2p peer payload = send p2p peer $ P2pMessagePayload payload
