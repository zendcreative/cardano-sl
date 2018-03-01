-- | Common definitions for peer discovery and subscription workers.


module Pos.Diffusion.Subscription.Common
    ( SubscriptionMode
    , SubscriptionTerminationReason (..)
    , subscribeTo
    , subscriptionListeners
    , subscriptionWorker
    ) where

import           Universum

import           Control.Exception.Safe (try)
import qualified Data.List.NonEmpty as NE
import           Data.Time.Units (convertUnit, Second)
import qualified Network.Broadcast.OutboundQueue as OQ
import           Network.Broadcast.OutboundQueue.Types (removePeer, simplePeers)

import           Formatting (sformat, shown, (%))
import           Node.Message.Class (Message)
import           System.Wlog (LoggerNameBox, usingLoggerName, logDebug, logNotice)

import           Pos.Binary.Class (Bi)
import           Pos.Communication.Limits.Types (MessageLimited, recvLimited)
import           Pos.Communication.Listener (listenerConv)
import           Pos.Communication.Protocol (Conversation (..), ConversationActions (..),
                                             ListenerSpec, MkListeners, MsgSubscribe (..),
                                             MsgSubscribe1 (..), NodeId, OutSpecs,
                                             SendActions, constantListeners,
                                             convH, toOutSpecs, withConnectionTo)
import           Pos.Network.Types (Bucket (..), NodeType)
import           Pos.Util.Timer (Timer, startTimer, waitTimer, setTimerDuration)
import           Pos.Worker.Types (Worker, WorkerSpec, worker)

logger :: LoggerNameBox IO t -> IO t
logger = usingLoggerName "subscription"

-- FIXME rename? What's a Mode in this context?
type SubscriptionMode =
    ( Message MsgSubscribe
    , Message MsgSubscribe1
    , MessageLimited MsgSubscribe IO
    , MessageLimited MsgSubscribe1 IO
    , Bi MsgSubscribe
    , Bi MsgSubscribe1
    , Message Void
    )

-- | A subscription ends normally (remote shut it down) or exceptionally
-- (network issues etc.).
data SubscriptionTerminationReason =
      Normal
    | Exceptional SomeException
    deriving (Show)

-- | Subscribe to some peer, blocking until the subscription terminates and
-- giving the reason. Notices will be logged before and after the subscription.
subscribeTo
    :: ( SubscriptionMode )
    => Timer
    -> SendActions
    -> NodeId
    -> IO SubscriptionTerminationReason
subscribeTo keepAliveTimer sendActions peer = do
    logger $ logNotice $ msgSubscribingTo peer
    -- 'try' is from safe-exceptions, so it won't catch asyncs.
    outcome <- try $ withConnectionTo sendActions peer $ \_peerData -> NE.fromList
        -- Sort conversations in descending order based on their version so that
        -- the highest available version of the conversation is picked.
        [ Conversation convMsgSubscribe
        , Conversation convMsgSubscribe1
        ]
    let reason = either Exceptional (maybe Normal absurd) outcome
    logger $ logNotice $ msgSubscriptionTerminated peer reason
    return reason
  where
    convMsgSubscribe :: ConversationActions MsgSubscribe Void -> IO t
    convMsgSubscribe conv = do
        send conv MsgSubscribe
        forever $ do
            startTimer keepAliveTimer
            atomically $ waitTimer keepAliveTimer
            logger $ logDebug $ sformat ("subscriptionWorker: sending keep-alive to "%shown)
                               peer
            send conv MsgSubscribeKeepAlive
            -- If there is a suspicion that subscriptions are no longer valid,
            -- we want to start sending keep-alive packets more frequently. Use
            -- 20 seconds as we don't have access to slot duration here.
            setTimerDuration keepAliveTimer $ convertUnit (20 :: Second)

    convMsgSubscribe1 :: ConversationActions MsgSubscribe1 Void -> IO (Maybe Void)
    convMsgSubscribe1 conv = do
        send conv MsgSubscribe1
        recv conv 0 -- Other side will never send

    msgSubscribingTo :: NodeId -> Text
    msgSubscribingTo = sformat $ "subscriptionWorker: subscribing to "%shown

    msgSubscriptionTerminated :: NodeId -> SubscriptionTerminationReason -> Text
    msgSubscriptionTerminated = sformat $ "subscriptionWorker: lost connection to "%shown%" "%shown

-- | A listener for subscriptions: add the subscriber to the set of known
-- peers, annotating it with a given NodeType. Remove that peer from the set
-- of known peers when the connection is dropped.
subscriptionListener
    :: forall pack.
       ( SubscriptionMode )
    => OQ.OutboundQ pack NodeId Bucket
    -> NodeType
    -> (ListenerSpec, OutSpecs)
subscriptionListener oq nodeType = listenerConv @Void oq $ \__ourVerInfo nodeId conv -> do
    recvLimited conv >>= \case
        Just MsgSubscribe -> do
            let peers = simplePeers [(nodeType, nodeId)]
            bracket
              (liftIO $ OQ.updatePeersBucket oq BucketSubscriptionListener (<> peers))
              (\added -> when added $ do
                void $ liftIO $ OQ.updatePeersBucket oq BucketSubscriptionListener (removePeer nodeId)
                logger $ logDebug $ sformat ("subscriptionListener: removed "%shown) nodeId)
              (\added -> when added $ do -- if not added, close the conversation
                  logger $ logDebug $ sformat ("subscriptionListener: added "%shown) nodeId
                  fix $ \loop -> recvLimited conv >>= \case
                      Just MsgSubscribeKeepAlive -> do
                          logger $ logDebug $ sformat
                              ("subscriptionListener: received keep-alive from "%shown)
                              nodeId
                          loop
                      msg -> logger $ logNotice $ expectedMsgFromGot MsgSubscribeKeepAlive
                                                                     nodeId msg)
        msg -> logger $ logNotice $ expectedMsgFromGot MsgSubscribe nodeId msg
  where
    expectedMsgFromGot = sformat
            ("subscriptionListener: expected "%shown%" from "%shown%
             ", got "%shown%", closing the connection")

-- | Version of subscriptionListener for MsgSubscribe1.
subscriptionListener1
    :: forall pack.
       ( SubscriptionMode )
    => OQ.OutboundQ pack NodeId Bucket
    -> NodeType
    -> (ListenerSpec, OutSpecs)
subscriptionListener1 oq nodeType = listenerConv @Void oq $ \_ourVerInfo nodeId conv -> do
    mbMsg <- recvLimited conv
    whenJust mbMsg $ \MsgSubscribe1 -> do
      let peers = simplePeers [(nodeType, nodeId)]
      bracket
          (liftIO $ OQ.updatePeersBucket oq BucketSubscriptionListener (<> peers))
          (\added -> when added $ do
              void $ liftIO $ OQ.updatePeersBucket oq BucketSubscriptionListener (removePeer nodeId)
              logger $ logDebug $ sformat ("subscriptionListener1: removed "%shown) nodeId)
          (\added -> when added $ do -- if not added, close the conversation
              logger $ logDebug $ sformat ("subscriptionListener1: added "%shown) nodeId
              void $ recvLimited conv)

subscriptionListeners
    :: forall pack.
       ( SubscriptionMode )
    => OQ.OutboundQ pack NodeId Bucket
    -> NodeType
    -> MkListeners
subscriptionListeners oq nodeType = constantListeners
    [ subscriptionListener  oq nodeType
    , subscriptionListener1 oq nodeType
    ]

-- | Throw the standard subscription worker OutSpecs onto a given
-- implementation of a single subscription worker.
subscriptionWorker
    :: (SubscriptionMode)
    => Worker IO -> ([WorkerSpec IO], OutSpecs)
subscriptionWorker theWorker = first (:[]) (worker subscriptionWorkerSpec theWorker)
  where
    subscriptionWorkerSpec :: OutSpecs
    subscriptionWorkerSpec = toOutSpecs
        [ convH (Proxy @MsgSubscribe)  (Proxy @Void)
        , convH (Proxy @MsgSubscribe1) (Proxy @Void)
        ]
