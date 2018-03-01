
module Pos.Diffusion.Subscription.Dns
    ( dnsSubscriptionWorker
    ) where

-- Why put MVars in a prelude? Weird.
import           Universum hiding (newMVar)

import           Control.Concurrent (threadDelay)
import           Control.Concurrent.MVar (modifyMVar, newMVar)
import           Control.Concurrent.Async (forConcurrently)
import           Control.Exception (IOException)
import           Data.Either (partitionEithers)
import qualified Data.Map.Strict as M
import           Data.Time.Units (Millisecond, Second, convertUnit)
import           Formatting (int, sformat, shown, (%))
import qualified Network.DNS as DNS
import           System.Wlog (LoggerNameBox, usingLoggerName, logError, logNotice, logWarning)

import qualified Network.Broadcast.OutboundQueue as OQ
import           Network.Broadcast.OutboundQueue.Types (Alts, peersFromList)

import           Pos.Communication.Protocol (SendActions)
import           Pos.Diffusion.Subscription.Common
import           Pos.Network.DnsDomains (NodeAddr)
import           Pos.Network.Types (Bucket (..), DnsDomains (..), NetworkConfig (..), NodeId (..),
                                    NodeType (..), resolveDnsDomains)
import           Pos.Util.Timer (Timer)

logger :: LoggerNameBox IO t -> IO t
logger = usingLoggerName "dns-subscription"

dnsSubscriptionWorker
    :: forall pack kademlia.
     ( SubscriptionMode )
    => OQ.OutboundQ pack NodeId Bucket
    -> NetworkConfig kademlia
    -> DnsDomains DNS.Domain
    -> Timer
    -> IO Millisecond
    -> SendActions
    -> IO ()
dnsSubscriptionWorker oq networkCfg DnsDomains{..} keepaliveTimer nextSlotDuration sendActions = do
    -- Shared state between the threads which do subscriptions.
    -- It's a 'Map Int (Alts NodeId)' used to determine the current
    -- peers set for our bucket 'BucketBehindNatWorker'. Each thread takes
    -- care of its own index and updates the peers while holding the lock, so
    -- that the threads don't erase each-others' work.
    let initialDnsPeers :: Map Int (Alts NodeId)
        initialDnsPeers = M.fromList $ map (\(i, _) -> (i, [])) allOf
    dnsPeersVar <- newMVar initialDnsPeers
    -- There's a thread for each conjunct which attempts to subscribe to one of
    -- the alternatives.
    -- This gives valency and fallbacks implicitly, just as for static
    -- routes. Valency is the length of the outer list (conjuncts) and
    -- fallbacks (for a given outer list element) is the length of the inner
    -- list (disjuncts).
    logger $ logNotice $ sformat ("dnsSubscriptionWorker: valency "%int) (length allOf)
    void $ forConcurrently allOf (subscribeAlts dnsPeersVar)
    logger $ logNotice $ sformat ("dnsSubscriptionWorker: all "%int%" threads finished") (length allOf)
  where

    allOf :: [(Int, Alts (NodeAddr DNS.Domain))]
    allOf = zip [1..] dnsDomains

    -- Resolve all of the names and try to subscribe to one.
    -- If a subscription goes down, try later names.
    -- When the list is exhausted (either because it's empty to begin with, or
    -- because all subscriptions to have failed), wait a while before retrying
    -- (see 'retryInterval').
    subscribeAlts
        :: MVar (Map Int (Alts NodeId))
        -> (Int, Alts (NodeAddr DNS.Domain))
        -> IO ()
    subscribeAlts _ (index, []) =
        logger $ logWarning $ sformat ("dnsSubscriptionWorker: no alternatives given for index "%int) index
    subscribeAlts dnsPeersVar (index, alts) = do
        -- Any DNSError is squelched. So are IOExceptions, for good measure.
        -- This does not include async exceptions.
        -- It does handle the case in which there's no internet connection, or
        -- a bad configuration, so that the subscription thread will keep on
        -- retrying.
        findAndSubscribe dnsPeersVar index alts
            `catch` logDNSError
            `catch` logIOException
        retryInterval >>= threadDelay . (* 1000) . fromIntegral
        subscribeAlts dnsPeersVar (index, alts)

    -- Subscribe to all alternatives, one-at-a-time, until the list is
    -- exhausted.
    subscribeToOne :: Alts NodeId -> IO ()
    subscribeToOne dnsPeers = case dnsPeers of
        [] -> return ()
        (peer:peers) -> do
            void $ subscribeTo keepaliveTimer sendActions peer
            subscribeToOne peers

    -- Resolve a name and subscribe to the node(s) at the addresses.
    findAndSubscribe
        :: MVar (Map Int (Alts NodeId))
        -> Int
        -> Alts (NodeAddr DNS.Domain)
        -> IO ()
    findAndSubscribe dnsPeersVar index alts = do
        -- Resolve all of the names and update the known peers in the queue.
        dnsPeersList <- findDnsPeers index alts
        modifyMVar dnsPeersVar $ \dnsPeers -> do
            let dnsPeers' = M.insert index dnsPeersList dnsPeers
            void $ OQ.updatePeersBucket oq BucketBehindNatWorker $ \_ ->
                peersFromList mempty ((,) NodeRelay <$> M.elems dnsPeers')
            pure (dnsPeers', ())
        -- Try to subscribe to some peer.
        -- If they all fail, wait a while before trying again.
        subscribeToOne dnsPeersList

    logIOException :: IOException -> IO ()
    logIOException ioException =
        logger $ logError $ sformat ("dnsSubscriptionWorker: "%shown) ioException

    logDNSError :: DNS.DNSError -> IO ()
    logDNSError dnsError =
        logger $ logError $ sformat ("dnsSubscriptionWorker: "%shown) dnsError

    -- Find peers via DNS, preserving order.
    -- In case multiple addresses are returned for one name, they're flattened
    -- and we forget the boundaries, but all of the addresses for a given name
    -- are adjacent.
    findDnsPeers :: Int -> Alts (NodeAddr DNS.Domain) -> IO (Alts NodeId)
    findDnsPeers index alts = do
        mNodeIds <- resolveDnsDomains networkCfg alts
        let (errs, nids_) = partitionEithers mNodeIds
            nids = mconcat nids_
        when (null nids)       $ logger $ logError (msgNoRelays index)
        when (not (null errs)) $ logger $ logError (msgDnsFailure index errs)
        return nids

    -- How long to wait before retrying in case no alternative can be
    -- subscribed to.
    retryInterval :: IO Millisecond
    retryInterval = do
        slotDur <- nextSlotDuration
        pure $ max (slotDur `div` 4) (convertUnit (5 :: Second))

    msgDnsFailure :: Int -> [DNS.DNSError] -> Text
    msgDnsFailure = sformat ("dnsSubscriptionWorker: DNS failure for index "%int%": "%shown)

    msgNoRelays :: Int -> Text
    msgNoRelays = sformat ("dnsSubscriptionWorker: no relays found for index "%int)

{-# ANN dnsSubscriptionWorker ("HLint: ignore Use unless" :: String) #-}
