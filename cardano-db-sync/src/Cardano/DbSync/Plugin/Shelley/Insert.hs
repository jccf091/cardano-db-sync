{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.DbSync.Plugin.Shelley.Insert
  ( insertShelleyBlock
  ) where

import           Cardano.Prelude
import           Cardano.Binary (serialize')

import           Cardano.BM.Trace (Trace, logDebug, logInfo)

import           Control.Monad.Logger (LoggingT)
import           Control.Monad.Trans.Except.Extra (runExceptT)

import qualified Cardano.Crypto as Crypto

import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Reader (ReaderT)

import           Data.Sequence.Strict (StrictSeq (..))
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.Text.Encoding as Text

import           Database.Persist.Sql (SqlBackend)

import qualified Cardano.Db as DB
import           Cardano.DbSync.Error
import           Cardano.DbSync.Util (textShow, renderByteArray, addrToBase58)

import qualified Shelley.Spec.Ledger.BlockChain as SL
import           Shelley.Spec.Ledger.Tx
import           Shelley.Spec.Ledger.TxData
import           Shelley.Spec.Ledger.Coin
import           Shelley.Spec.Ledger.BaseTypes (strictMaybeToMaybe)


import           Ouroboros.Consensus.Shelley.Ledger (ShelleyBlock (..), Crypto)
import           Ouroboros.Network.Block (BlockNo (..), Tip, SlotNo (..), getTipBlockNo)
import           Ouroboros.Network.Point (withOrigin)


insertShelleyBlock
    :: Crypto crypto
    => Trace IO Text
    -> ShelleyBlock crypto
    -> Tip (ShelleyBlock crypto)
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertShelleyBlock tracer blk tip = do
  runExceptT $ do
    let block = shelleyBlockRaw blk
    insertAShelleyBlock tracer block tip

insertAShelleyBlock
    :: forall crypto m. (Crypto crypto, MonadIO m)
    => Trace IO Text -> SL.Block crypto -> Tip (ShelleyBlock crypto)
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertAShelleyBlock tracer blk tip = do
    meta <- liftLookupFail "insertABlock" DB.queryMeta

    let blockId = show . SL.unHashHeader . SL.bhHash . SL.bheader $ blk
    pbid <- liftLookupFail "insertABlock" $ DB.queryBlockId blockId

    let slotsPerEpoch = 10 * DB.metaProtocolConst meta

    slid <- lift . DB.insertSlotLeader $ mkSlotLeader blk
    blkId <- lift . DB.insertBlock $
                  DB.Block
                    { DB.blockHash       = blockHash
                    , DB.blockEpochNo    = Just $ slotNumber `div` slotsPerEpoch
                    , DB.blockSlotNo     = Just $ slotNumber
                    , DB.blockBlockNo    = Just $ blockNumber
                    , DB.blockPrevious   = Just pbid
                    , DB.blockMerkelRoot = Nothing -- This doesn't exist in Byron?
                    , DB.blockSlotLeader = slid
                    , DB.blockSize       = fromIntegral blockHeaderSize
                    , DB.blockTime       = DB.slotUtcTime meta slotNumber
                    , DB.blockTxCount    = fromIntegral txsCount
                    -- Shelley specific
                    , DB.blockBlockIssuer = Just . Crypto.abstractHashToBytes . Crypto.serializeCborHash . SL.bheaderVk . SL.bhbody . SL.bheader $ blk
                    , DB.blockVrfKey = Nothing
                    --Just . Crypto.abstractHashToBytes . Crypto.serializeCborHash . SL.bheaderVrfVk . SL.bhbody . SL.bheader $ blk
                    , DB.blockNonceVrf = Just . Crypto.abstractHashToBytes . Crypto.serializeCborHash . SL.bheaderEta . SL.bhbody . SL.bheader $ blk
                    , DB.blockLeaderVrf = Just . Crypto.abstractHashToBytes . Crypto.serializeCborHash . SL.bheaderL . SL.bhbody . SL.bheader $ blk
                    , DB.blockOpCert = Just . Crypto.abstractHashToBytes . Crypto.serializeCborHash . SL.bheaderOCert . SL.bhbody . SL.bheader $ blk
                    , DB.blockProtoVersion = Just . Crypto.abstractHashToBytes . Crypto.serializeCborHash . SL.bprotver . SL.bhbody . SL.bheader $ blk
                    }

    -- Insert the transaction
    _ <-    mapMExceptT
                (\tx -> insertTx tracer blkId tx)
                (zip (toList . getTxSequence . SL.bbody $ blk) [0..])

    liftIO $ do
      let followingClosely = withOrigin 0 unBlockNo (getTipBlockNo tip) - blockNumber < 20
          (epoch, slotWithin) = slotNumber `divMod` slotsPerEpoch
      when (followingClosely && slotWithin /= 0 && slotNumber > 0 && slotNumber `mod` 20 == 0) $ do
        logInfo tracer $
          mconcat
            [ "insertABlock: continuing epoch ", textShow epoch
            , " (slot ", textShow slotWithin, ")"
            ]
      logger tracer $ mconcat
        [ "insertABlock: slot ", textShow slotNumber
        , ", block ", textShow blockNumber
        , ", hash ", renderByteArray blockHash
        ]
  where

    blockHash :: ByteString
    blockHash = Crypto.abstractHashToBytes . Crypto.serializeCborHash . SL.bhash . SL.bhbody . SL.bheader $ blk

    blockHeaderSize :: Int
    blockHeaderSize = SL.bHeaderSize . SL.bheader $ blk

    getTxSequence :: SL.TxSeq crypto -> StrictSeq (Tx crypto)
    getTxSequence (SL.TxSeq txSeq) = txSeq

    txsCount :: Int
    txsCount = length . getTxSequence . SL.bbody $ blk

    slotNumber :: Word64
    slotNumber = unSlotNo . SL.bheaderSlotNo . SL.bhbody . SL.bheader $ blk

    blockNumber :: Word64
    blockNumber = unBlockNo . SL.bheaderBlockNo . SL.bhbody . SL.bheader $ blk

    logger :: Trace IO a -> a -> IO ()
    logger
      | withOrigin 0 unBlockNo (getTipBlockNo tip) - blockNumber < 20 = logInfo
      | slotNumber `mod` 5000 == 0 = logInfo
      | otherwise = logDebug


-- Get all pool certificates from a sequence of certificates of a tx.
getAllPoolCertificates :: forall crypto. StrictSeq (DCert crypto) -> Maybe [PoolMetaData]
getAllPoolCertificates certs = do

    -- Convert to lists, easier to move around.
    let certsList :: [DCert crypto]
        certsList = toList certs

    -- poolCertificates :: [PoolParams crypto]
    poolCertificates <- traverse (getPoolRegCertificate <=< getPoolCertificate) certsList

    -- Easier to read then to cram in one line
    strictMaybeToMaybe $ traverse _poolMD poolCertificates

  where

    getPoolCertificate :: DCert crypto -> Maybe (PoolCert crypto)
    getPoolCertificate (DCertPool dCert) = Just dCert
    getPoolCertificate _                 = Nothing

    getPoolRegCertificate :: PoolCert crypto -> Maybe (PoolParams crypto)
    getPoolRegCertificate (RegPool pp)   = Just pp
    getPoolRegCertificate _              = Nothing

-- Transactions!

insertTx
    :: forall crypto m. (Crypto crypto, MonadIO m)
    => Trace IO Text -> DB.BlockId -> (Tx crypto, Word64)
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertTx tracer blkId (tx, blockIndex) = do
    let txFee = calculateTxFee tx

    -- Insert transaction and get txId from the DB.
    txId <- lift . DB.insertTx $
              DB.Tx
                { DB.txHash = Crypto.abstractHashToBytes . Crypto.serializeCborHash $ tx
                , DB.txBlock = blkId
                , DB.txBlockIndex = blockIndex
                , DB.txOutSum = vfValue txFee
                , DB.txFee = vfFee txFee
                -- Would be really nice to have a way to get the transaction size
                -- without re-serializing it.
                -- TODO(KS): This seems hacky and prone to error!
                , DB.txSize = fromIntegral $ BS.length (serialize' tx)
                }

    -- Insert outputs for a transaction before inputs in case the inputs for this transaction
    -- references the output (not sure this can even happen).
    lift $ zipWithM_ (insertTxOut tracer txId) [0 ..] (toList . _outputs . _body $ tx)

    -- Insert the transaction inputs.
    mapMVExceptT (insertTxIn tracer txId) (toList . _inputs . _body $ tx)

    let certificates :: StrictSeq (DCert crypto)
        certificates = _certs . _body $ tx

    let poolCertificates :: [PoolMetaData]
        poolCertificates =  case (getAllPoolCertificates certificates) of
                                Nothing     -> []
                                Just certs  -> certs

    -- Finally, insert the pool certificates.
    insertPoolCertificates tracer txId poolCertificates


insertTxOut
    :: (Crypto crypto, MonadIO m)
    => Trace IO Text
    -> DB.TxId
    -> Word32
    -> TxOut crypto
    -> ReaderT SqlBackend m ()
insertTxOut _tracer txId index (TxOut txOutAddress txOutValue) =
  void . DB.insertTxOut $
            DB.TxOut
              { DB.txOutTxId = txId
              , DB.txOutIndex = fromIntegral index
              , DB.txOutAddress = Text.decodeUtf8 $ addrToBase58 txOutAddress
              , DB.txOutValue = fromIntegral txOutValue
              }


insertTxIn
    :: (Crypto crypto, MonadIO m)
    => Trace IO Text -> DB.TxId -> TxIn crypto
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertTxIn _tracer txInId (TxIn (TxId txId) inIndex) = do
  txOutId <- liftLookupFail "insertTxIn" $ DB.queryTxId (Crypto.abstractHashToBytes $ Crypto.serializeCborHash txId)
  void . lift . DB.insertTxIn $
            DB.TxIn
              { DB.txInTxInId = txInId
              , DB.txInTxOutId = txOutId
              , DB.txInTxOutIndex = fromIntegral inIndex
              }

insertPoolCertificates
    :: forall m. (MonadIO m)
    => Trace IO Text -> DB.TxId -> [PoolMetaData]
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertPoolCertificates _tracer txId poolMetaDatas = do
  void . lift $ forM poolMetaDatas $ \poolMetaData -> DB.insertPoolOnData $
            DB.PoolOnData
              { DB.poolOnDataTxId = txId
              , DB.poolOnDataPoolUrl = show $ _poolMDUrl poolMetaData
              , DB.poolOnDataPoolHash = _poolMDHash poolMetaData
              }

-------------------------------------------------------------------------------

-- Trivial local data type for use in place of a tuple.
data ValueFee = ValueFee
  { vfValue :: !Word64
  , vfFee :: !Word64
  }

calculateTxFee :: Crypto crypto => Tx crypto -> ValueFee
calculateTxFee tx =
    let fee :: Coin
        fee = _txfee $ _body tx

        coinFromTxOut :: TxOut crypto -> Coin
        coinFromTxOut (TxOut _ coin) = coin

        sumCoins :: Foldable f => f Coin -> Coin
        sumCoins coins = foldr (+) 0 coins

        txOutTotal :: Coin
        txOutTotal = sumCoins $ map coinFromTxOut (_outputs $ _body tx)
    in
        ValueFee (fromIntegral txOutTotal) (fromIntegral fee)

mkSlotLeader :: Crypto crypto => SL.Block crypto -> DB.SlotLeader
mkSlotLeader blk =
  let slHash = Crypto.abstractHashToBytes . Crypto.serializeCborHash . SL.bheaderVk . SL.bhbody . SL.bheader $ blk
      slName = "SlotLeader-" <> Text.decodeUtf8 (Base16.encode $ BS.take 8 slHash)
  in DB.SlotLeader slHash slName

-- | An 'ExceptT' version of 'mapM' which will 'left' the first 'Left' it finds.
mapMExceptT :: Monad m => (a -> ExceptT e m b) -> [a] -> ExceptT e m [b]
mapMExceptT action xs =
  case xs of
    [] -> pure []
    (y:ys) -> (:) <$> action y <*> mapMExceptT action ys

-- | An 'ExceptT' version of 'mapM_' which will 'left' the first 'Left' it finds.
mapMVExceptT :: Monad m => (a -> ExceptT e m ()) -> [a] -> ExceptT e m ()
mapMVExceptT action xs =
  case xs of
    [] -> pure ()
    (y:ys) -> action y >> mapMVExceptT action ys


