{-# LANGUAGE Rank2Types      #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}

-- | Framework for Inv\/Req\/Data message handling

module Pos.Communication.Relay.Logic
       ( Relay (..)
       , InvMsg (..)
       , ReqMsg (..)
       , ResMsg (..)
       , MempoolMsg (..)
       , DataMsg (..)
       , InvOrData
       , ReqOrRes
       , relayListeners
       , relayMsg
       , propagateData
       , relayPropagateOut
       , handleDataDo
       , handleInvDo

       , invReqDataFlow
       , invReqDataFlowTK
       , dataFlow
       , InvReqDataFlowLog (..)
       ) where

import           Control.Exception (throwIO)
import           Control.Exception.Safe (handleAny, try)
import           Data.Aeson.TH (defaultOptions, deriveJSON)
import           Data.Proxy (asProxyTypeOf)
import           Data.Tagged (Tagged, tagWith)
import           Data.Typeable (typeRep)
import           Formatting (build, sformat, shown, stext, (%))
import qualified Network.Broadcast.OutboundQueue as OQ
import           Node.Message.Class (Message)
import           System.Wlog (LoggerNameBox, usingLoggerName, logDebug, logError, logWarning)
import           Universum

import           Pos.Binary.Class (Bi (..))
import           Pos.Communication.Limits.Instances ()
import           Pos.Communication.Limits.Types (MessageLimited, recvLimited)
import           Pos.Communication.Listener (listenerConv)
import           Pos.Communication.Protocol (Conversation (..), ConversationActions (..),
                                             EnqueueMsg, ListenerSpec, MkListeners, Msg, NodeId,
                                             Origin (..), OutSpecs, constantListeners, convH,
                                             toOutSpecs, waitForConversations)
import           Pos.Communication.Relay.Class (DataParams (..), InvReqDataParams (..),
                                                MempoolParams (..), Relay (..))
import           Pos.Communication.Relay.Types (PropagationMsg (..))
import           Pos.Communication.Relay.Util (expectData, expectInv)
import           Pos.Communication.Types.Relay (DataMsg (..), InvMsg (..), InvOrData,
                                                MempoolMsg (..), ReqMsg (..), ReqOrRes, ResMsg (..))
import           Pos.Network.Types (Bucket)

logger :: LoggerNameBox IO t -> IO t
logger = usingLoggerName "relay"

data InvReqCommunicationException =
      UnexpectedRequest
    | UnexpectedResponse
    | UnexpectedEnd
    | MismatchedKey
    deriving (Show)

instance Exception InvReqCommunicationException

handleReqL
    :: forall pack key contents .
       ( Bi (ReqMsg key)
       , Bi (InvOrData key contents)
       , Message (InvOrData key contents)
       , Message (ReqMsg key)
       , Buildable key
       )
    => OQ.OutboundQ pack NodeId Bucket
    -> (NodeId -> key -> IO (Maybe contents))
    -> (ListenerSpec, OutSpecs)
handleReqL oq handleReq = listenerConv oq $ \__ourVerInfo nodeId conv ->
    let handlingLoop = do
            mbMsg <- recvLimited conv
            case mbMsg of
                Just (ReqMsg (Just key)) -> do
                    dtMB <- handleReq nodeId key
                    case dtMB of
                        Nothing -> logNoData key
                        Just dt -> logHaveData key >> send conv (constructDataMsg dt)
                    handlingLoop
                _ -> return ()
    in handlingLoop
  where
    constructDataMsg :: contents -> InvOrData key contents
    constructDataMsg = Right . DataMsg
    logNoData rmKey = logger $ logDebug $ sformat
        ("We don't have data for key "%build)
        rmKey
    logHaveData rmKey= logger $ logDebug $ sformat
        ("We have data for key "%build)
        rmKey

handleMempoolL
    :: forall pack.
       OQ.OutboundQ pack NodeId Bucket
    -> MempoolParams
    -> [(ListenerSpec, OutSpecs)]
handleMempoolL _ NoMempool = []
handleMempoolL oq (KeyMempool tagP handleMempool) = pure $ listenerConv oq $
    \__ourVerInfo __nodeId conv -> do
        mbMsg <- recvLimited conv
        whenJust mbMsg $ \msg@MempoolMsg -> do
            let _ = msg `asProxyTypeOf` mmP
            res <- handleMempool
            case nonEmpty res of
                Nothing ->
                    logger $ logDebug $ sformat
                        ("We don't have mempool data "%shown) (typeRep tagP)
                Just xs -> do
                    logger $ logDebug $ sformat ("We have mempool data "%shown) (typeRep tagP)
                    mapM_ (send conv . InvMsg) xs
  where
    mmP = (const Proxy :: Proxy tag -> Proxy (MempoolMsg tag)) tagP

handleDataOnlyL
    :: forall pack contents.
       ( Bi (DataMsg contents)
       , Message Void
       , Message (DataMsg contents)
       , Buildable contents
       , MessageLimited (DataMsg contents) IO
       )
    => OQ.OutboundQ pack NodeId Bucket
    -> EnqueueMsg
    -> (Origin NodeId -> Msg)
    -> (NodeId -> contents -> IO Bool)
    -> (ListenerSpec, OutSpecs)
handleDataOnlyL oq enqueue mkMsg handleData = listenerConv oq $ \__ourVerInfo nodeId conv ->
    -- First binding is to inform GHC that the send type is Void.
    let msg :: Msg
        msg = mkMsg (OriginForward nodeId)
        _ = send conv :: Void -> IO ()
        handlingLoop = do
            mbMsg <- recvLimited conv
            whenJust mbMsg $ \DataMsg{..} -> do
                ifM (handleData nodeId dmContents)
                    (void $ propagateData enqueue $ DataOnlyPM msg dmContents)
                    (logUseless dmContents)
                handlingLoop
    in handlingLoop
  where
    logUseless dmContents = logger $ logWarning $ sformat
        ("Ignoring data "%build) dmContents

handleDataDo
    :: forall key contents.
       ( Buildable key
       , Eq key
       , Buildable contents
       , Message (InvOrData key contents)
       , Message (ReqOrRes key)
       , Bi (InvOrData key contents)
       , Bi (ReqOrRes key)
       , Message Void
       )
    => NodeId
    -> (Origin NodeId -> Msg)
    -> EnqueueMsg
    -> (contents -> IO key)
    -> (contents -> IO Bool)
    -> contents
    -> IO (ResMsg key)
handleDataDo provenance mkMsg enqueue contentsToKey handleData dmContents = do
    dmKey <- contentsToKey dmContents
    ifM (handleData dmContents)
        -- IMPORTANT that we propagate it asynchronously.
        -- enqueueMsg can do that: simply don't force the values in
        -- the resulting map.
        (ResMsg dmKey True <$ propagateData enqueue (InvReqDataPM (mkMsg (OriginForward provenance)) dmKey dmContents))
        (ResMsg dmKey False <$ (logger $ logDebug (sformat ("Ignoring data "%build%" for key "%build) dmContents dmKey)))

-- | Synchronously propagate data.
relayMsg
    :: ( Message Void )
    => EnqueueMsg
    -> PropagationMsg
    -> IO ()
relayMsg enqueue pm = void $ propagateData enqueue pm >>= waitForConversations

-- | Asynchronously propagate data.
propagateData
    :: ( Message Void )
    => EnqueueMsg
    -> PropagationMsg
    -> IO (Map NodeId (IO ()))
propagateData enqueue pm = case pm of
    InvReqDataPM msg key contents -> do
        logger $ logDebug $ sformat
            ("Propagation data with key: "%build) key
        enqueue msg $ \peer _ ->
            pure $ Conversation $ (void <$> invReqDataFlowDo "propagation" key contents peer)
    DataOnlyPM msg contents -> do
        logger $ logDebug $ sformat
            ("Propagation data: "%build) contents
        enqueue msg $ \__node _ ->
            pure $ Conversation $ doHandler contents

  where

    doHandler
        :: contents1
        -> ConversationActions
             (DataMsg contents1) Void
        -> IO ()
    doHandler contents conv = send conv $ DataMsg contents

handleInvDo
    :: forall key.
       ( Buildable key)
    => (key -> IO Bool)
    -> key
    -> IO (Maybe key)
handleInvDo handleInv imKey =
    ifM (handleInv imKey)
        (Just imKey <$ logUseful)
        (Nothing <$ logUseless)
  where
    logUseless = logger $ logDebug $ sformat
        ("Ignoring inv for key "%build%", because it's useless")
        imKey
    logUseful = logger $ logDebug $ sformat
        ("We'll request data for key "%build%", because it's useful")
        imKey

relayListenersOne
  :: forall pack.
     ( Message Void )
  => OQ.OutboundQ pack NodeId Bucket -> EnqueueMsg -> Relay -> MkListeners
relayListenersOne oq enqueue (InvReqData mP irdP@InvReqDataParams{..}) =
    constantListeners $
    [handleReqL oq handleReq, invDataListener oq enqueue irdP] ++ handleMempoolL oq mP
relayListenersOne oq enqueue (Data DataParams{..}) =
    constantListeners $
    [handleDataOnlyL oq enqueue dataMsgType (handleDataOnly enqueue)]

relayListeners
  :: forall pack.
     ( Message Void )
  => OQ.OutboundQ pack NodeId Bucket -> EnqueueMsg -> [Relay] -> MkListeners
relayListeners oq enqueue = mconcat . map (relayListenersOne oq enqueue)

invDataListener
  :: forall pack key contents.
     ( Message (ReqOrRes key)
     , Message (InvOrData key contents)
     , Bi (ReqOrRes key)
     , Bi (InvOrData key contents)
     , Buildable contents
     , Buildable key
     , Eq key
     , MessageLimited (DataMsg contents) IO
     , Message Void
     )
  => OQ.OutboundQ pack NodeId Bucket
  -> EnqueueMsg
  -> InvReqDataParams key contents
  -> (ListenerSpec, OutSpecs)
invDataListener oq enqueue InvReqDataParams{..} = listenerConv oq $ \__ourVerInfo nodeId conv ->
    let handlingLoop = do
            inv' <- recvLimited conv
            whenJust inv' $ expectInv $ \InvMsg{..} -> do
                useful <- handleInvDo (handleInv nodeId) imKey
                case useful of
                    Nothing -> send conv (Left (ReqMsg Nothing))
                    Just ne -> do
                        send conv $ Left (ReqMsg (Just ne))
                        dt' <- recvLimited conv
                        whenJust dt' $ expectData $ \DataMsg{..} -> do
                              res <- handleDataDo nodeId invReqMsgType enqueue contentsToKey (handleData nodeId) dmContents
                              send conv $ Right res
                              -- handlingLoop

                              -- TODO CSL-1148 Improve relaing: support multiple data
                              -- Need to receive Inv and Data messages simultaneously
                              -- Maintain state of sent Reqs
                              -- And check data we are sent is what we expect (currently not)
    in handlingLoop

relayPropagateOut :: Message Void => [Relay] -> OutSpecs
relayPropagateOut = mconcat . map propagateOutImpl

propagateOutImpl :: Message Void => Relay -> OutSpecs
propagateOutImpl (InvReqData _ irdp) = toOutSpecs
      [ convH invProxy reqResProxy ]
  where
    invProxy    = (const Proxy :: InvReqDataParams key contents
                               -> Proxy (InvOrData key contents)) irdp
    reqResProxy = (const Proxy :: InvReqDataParams key contents
                               -> Proxy (ReqOrRes key)) irdp
propagateOutImpl (Data dp) = toOutSpecs
      [ convH dataProxy (Proxy @Void)
      ]
  where
    dataProxy = (const Proxy :: DataParams contents
                             -> Proxy (DataMsg contents)) dp

invReqDataFlowDo
    :: ( Buildable key
       , MessageLimited (ReqOrRes key) IO
       , Eq key
       )
    => Text
    -> key
    -> contents
    -> NodeId
    -> ConversationActions (InvOrData key contents) (ReqOrRes key)
    -> IO (Maybe (ResMsg key))
invReqDataFlowDo what key dt peer conv = do
    send conv $ Left $ InvMsg key
    it <- recvLimited conv
    maybe handleD replyWithData it
  where
    replyWithData (Left (ReqMsg (Just key'))) = do
        -- Stop if the peer sends the wrong key. Basically a protocol error.
        unless (key' == key) (throwIO MismatchedKey)
        send conv $ Right $ DataMsg dt
        it <- recvLimited conv
        maybe handleD checkResponse it
    -- The peer indicated that he doesn't want the data.
    replyWithData (Left (ReqMsg Nothing)) = return Nothing
    -- The peer sent a ResMsg where a ReqMsg was expected.
    replyWithData (Right (ResMsg _ _)) = do
        logger $ logError $
            sformat ("InvReqDataFlow ("%stext%"): "%shown %" unexpected response")
                    what peer
        throwIO UnexpectedResponse

    checkResponse (Right resMsg) = return (Just resMsg)
    -- The peer sent a ReqMsg where a ResMsg was expected.
    checkResponse (Left (ReqMsg _)) = do
        logger $ logError $
            sformat ("InvReqDataFlow ("%stext%"): "%shown %" unexpected request")
                    what peer
        throwIO UnexpectedRequest

    handleD = do
        logger $ logError $
            sformat ("InvReqDataFlow ("%stext%"): "%shown %" closed conversation on \
                     \Inv key = "%build)
                    what peer key
        throwIO UnexpectedEnd

dataFlow
    :: forall contents.
       ( Message (DataMsg contents)
       , Bi (DataMsg contents)
       , Buildable contents
       , Message Void
       )
    => Text -> EnqueueMsg -> Msg -> contents -> IO ()
dataFlow what enqueue msg dt = handleAny handleE $ do
    its <- enqueue msg $
        \_ _ -> pure $ Conversation $ \(conv :: ConversationActions (DataMsg contents) Void) ->
            send conv $ DataMsg dt
    void $ waitForConversations its
  where
    -- TODO: is this function really special that it wants to catch
    -- all exceptions and log them instead of letting higher-level
    -- code to do it?
    -- FIXME: are we sure we don't want to propagate exception to caller???
    -- Fortunatelly, it's used only in auxx, so I don't care much.
    -- @gromak
    handleE e =
        logger $ logWarning $
        sformat ("Error sending "%stext%", data = "%build%": "%shown)
                what dt e

----------------------------------------------------------------------------
-- Helpers for Communication.Methods
----------------------------------------------------------------------------

data InvReqDataFlowLog =
      InvReqAccepted
        { invReqStart    :: !Integer
        , invReqReceived :: !Integer
        , invReqSent     :: !Integer
        , invReqClosed   :: !Integer
        }
    | InvReqRejected
        { invReqStart    :: !Integer
        , invReqReceived :: !Integer
        }
    | InvReqException !Text
    deriving Show

$(deriveJSON defaultOptions ''InvReqDataFlowLog)

invReqDataFlowTK
    :: forall key contents.
       ( Message (InvOrData (Tagged contents key) contents)
       , Message (ReqOrRes (Tagged contents key))
       , Buildable key
       , Typeable contents
       , Bi (InvOrData (Tagged contents key) contents)
       , Bi (ReqOrRes (Tagged contents key))
       , Eq key
       )
    => Text
    -> EnqueueMsg
    -> Msg
    -> key
    -> contents
    -> IO (Map NodeId (Either SomeException (Maybe (ResMsg (Tagged contents key)))))
invReqDataFlowTK what enqueue msg key dt =
    invReqDataFlow what enqueue msg key' dt
  where
    contProxy = (const Proxy :: contents -> Proxy contents) dt
    key' = tagWith contProxy key

-- | Do an Inv/Req/Data/Res conversation (peers determined by the 'EnqueueMsg'
-- argument) and wait for the results.
-- This will wait for all conversations to finish. Exceptions in the conversations
-- themselves are caught and returned as Left. If the peer did not ask for the
-- data, then Right Nothing is given, otherwise their response to the data is
-- given.
invReqDataFlow
    :: forall key contents.
       ( Message (InvOrData key contents)
       , Message (ReqOrRes key)
       , Bi (InvOrData key contents)
       , Bi (ReqOrRes key)
       , Buildable key
       , Eq key
       )
    => Text
    -> EnqueueMsg
    -> Msg
    -> key
    -> contents
    -> IO (Map NodeId (Either SomeException (Maybe (ResMsg key))))
invReqDataFlow what enqueue msg key dt = handleAny handleE $ do
    its <- enqueue msg $
        \addr _ -> pure $ Conversation $ invReqDataFlowDo what key dt addr
    waitForConversations (fmap try its)
  where
    -- TODO: is this function really special that it wants to catch
    -- all exceptions and log them instead of letting higher-level
    -- code to do it?
    -- Anyway, 'reportOrLog' is not used here, because exception is rethrown.
    -- @gromak
    handleE e = do
        logger $ logWarning $
            sformat ("Error sending "%stext%", key = "%build%": "%shown)
                what key e
        throwIO e
