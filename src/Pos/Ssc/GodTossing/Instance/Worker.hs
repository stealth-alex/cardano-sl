{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Instance of SscWorkersClass.

module Pos.Ssc.GodTossing.Instance.Worker
       ( -- * Instances
         -- ** instance SscWorkersClass SscGodTossing
       ) where

import           Control.Lens                     (view, _2, _3)
import           Control.TimeWarp.Logging         (logDebug, logWarning)
import           Control.TimeWarp.Timed           (repeatForever)
import qualified Data.HashMap.Strict              as HM (toList)
import           Data.List.NonEmpty               (nonEmpty)
import           Data.Tagged                      (Tagged (..))
import           Formatting                       (build, ords, sformat, (%))
import           Serokell.Util.Exceptions         ()
import           Universum

import           Pos.Constants                    (sscTransmitterInterval)
import           Pos.Crypto                       (SecretKey, toPublic)
import           Pos.Slotting                     (getCurrentSlot)
import           Pos.Ssc.Class.Workers            (SscWorkersClass (..))
import           Pos.Ssc.GodTossing.Base          (genCommitmentAndOpening,
                                                   genCommitmentAndOpening,
                                                   isCommitmentIdx, isOpeningIdx,
                                                   isSharesIdx, mkSignedCommitment)
import           Pos.Ssc.GodTossing.Base          (Opening, SignedCommitment)
import           Pos.Ssc.GodTossing.Instance.Type (SscGodTossing)
import           Pos.Ssc.GodTossing.Server        (announceCommitment,
                                                   announceCommitments, announceOpening,
                                                   announceOpenings, announceShares,
                                                   announceSharesMulti,
                                                   announceVssCertificates)
import           Pos.Ssc.GodTossing.Storage       (GtSecret)
import           Pos.Ssc.GodTossing.Types         (GtMessage (..), GtPayload (..),
                                                   hasCommitment, hasOpening, hasShares)
import           Pos.State                        (getGlobalMpcData, getLocalSscPayload,
                                                   getOurShares, getParticipants,
                                                   getSecret, getThreshold,
                                                   processSscMessage, setSecret)
import           Pos.Types                        (EpochIndex, SlotId (..))
import           Pos.WorkMode                     (WorkMode, getNodeContext, ncDbPath,
                                                   ncPublicKey, ncSecretKey, ncVssKeyPair)

import           System.FilePath                  ((</>))

instance SscWorkersClass SscGodTossing where
    sscOnNewSlot = Tagged onNewSlot
    sscWorkers = Tagged [sscTransmitter]

onNewSlot :: WorkMode SscGodTossing m => SlotId -> m ()
onNewSlot slotId = do
    onNewSlotCommitment slotId
    onNewSlotOpening slotId
    onNewSlotShares slotId

-- Commitments-related part of new slot processing
onNewSlotCommitment :: WorkMode SscGodTossing m => SlotId -> m ()
onNewSlotCommitment SlotId {..} = do
    ourPk <- ncPublicKey <$> getNodeContext
    ourSk <- ncSecretKey <$> getNodeContext
    shouldCreateCommitment <- do
        secret <- getToken
        return $ isCommitmentIdx siSlot && isNothing secret
    when shouldCreateCommitment $ do
        logDebug $ sformat ("Generating secret for "%ords%" epoch") siEpoch
        generated <- generateAndSetNewSecret ourSk siEpoch
        case generated of
            Nothing -> logWarning "I failed to generate secret for Mpc"
            Just _ -> logDebug $
                sformat ("Generated secret for "%ords%" epoch") siEpoch
    shouldSendCommitment <- do
        commitmentInBlockchain <- hasCommitment ourPk <$> getGlobalMpcData
        return $ isCommitmentIdx siSlot && not commitmentInBlockchain
    when shouldSendCommitment $ do
        mbComm <- fmap (view _2) <$> getToken
        whenJust mbComm $ \comm -> do
            announceCommitment ourPk comm
            logDebug "Sent commitment to neighbors"
            () <$ processSscMessage (DSCommitments $ pure (ourPk, comm))

-- Openings-related part of new slot processing
onNewSlotOpening :: WorkMode SscGodTossing m => SlotId -> m ()
onNewSlotOpening SlotId {..} = do
    ourPk <- ncPublicKey <$> getNodeContext
    shouldSendOpening <- do
        openingInBlockchain <- hasOpening ourPk <$> getGlobalMpcData
        return $ isOpeningIdx siSlot && not openingInBlockchain
    when shouldSendOpening $ do
        mbOpen <- fmap (view _3) <$> getToken
        whenJust mbOpen $ \open -> do
            announceOpening ourPk open
            logDebug "Sent opening to neighbors"
            () <$ processSscMessage (DSOpenings $ pure (ourPk, open))

-- Shares-related part of new slot processing
onNewSlotShares :: WorkMode SscGodTossing m => SlotId -> m ()
onNewSlotShares SlotId {..} = do
    ourPk <- ncPublicKey <$> getNodeContext
    -- Send decrypted shares that others have sent us
    shouldSendShares <- do
        -- TODO: here we assume that all shares are always sent as a whole
        -- package.
        sharesInBlockchain <- hasShares ourPk <$> getGlobalMpcData
        return $ isSharesIdx siSlot && not sharesInBlockchain
    when shouldSendShares $ do
        ourVss <- ncVssKeyPair <$> getNodeContext
        shares <- getOurShares ourVss
        unless (null shares) $ do
            announceShares ourPk shares
            logDebug "Sent shares to neighbors"
            () <$ processSscMessage (DSSharesMulti $ pure (ourPk, shares))

sscTransmitter :: WorkMode SscGodTossing m => m ()
sscTransmitter =
    repeatForever sscTransmitterInterval onError $
    do GtPayload {..} <- getLocalSscPayload =<< getCurrentSlot
       whenJust (nonEmpty $ HM.toList _mdCommitments) announceCommitments
       whenJust (nonEmpty $ HM.toList _mdOpenings) announceOpenings
       whenJust (nonEmpty $ HM.toList _mdShares) announceSharesMulti
       whenJust
           (nonEmpty $ HM.toList _mdVssCertificates)
           announceVssCertificates
  where
    onError e =
        sscTransmitterInterval <$
        logWarning (sformat ("Error occured in sscTransmitter: " %build) e)

-- | Generate new commitment and opening and use them for the current
-- epoch. Assumes that the genesis block has already been generated and
-- processed by MPC (when the genesis block is processed, the secret is
-- cleared) (otherwise 'generateNewSecret' will fail because 'A.SetSecret'
-- won't set the secret if there's one already).
-- Nothing is returned if node is not ready.
generateAndSetNewSecret
    :: WorkMode SscGodTossing m
    => SecretKey
    -> EpochIndex                         -- ^ Current epoch
    -> m (Maybe (SignedCommitment, Opening))
generateAndSetNewSecret sk epoch = do
    -- TODO: I think it's safe here to perform 3 operations which aren't
    -- grouped into a single transaction here, but I'm still a bit nervous.
    threshold <- getThreshold epoch
    participants <- getParticipants epoch
    case (,) <$> threshold <*> participants of
        Nothing -> return Nothing
        Just (th, ps) -> do
            (comm, op) <-
                first (mkSignedCommitment sk epoch) <$>
                genCommitmentAndOpening th ps
            Just (comm, op) <$ setToken (toPublic sk, comm, op)

setToken :: WorkMode SscGodTossing m => GtSecret -> m ()
setToken secret = do
    dbPath <- ncDbPath <$> getNodeContext
    setSecret ((</> "secret") <$> dbPath) secret


getToken :: WorkMode SscGodTossing m => m (Maybe GtSecret)
getToken = do
    dbPath <- ncDbPath <$> getNodeContext
    getSecret ((</> "secret") <$> dbPath)
