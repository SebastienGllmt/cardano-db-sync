{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Cardano.DbSync.Era.Shelley.Util
  ( annotateStakingCred
  , blockBody
  , blockHash
  , blockNumber
  , blockPrevHash
  , blockProtoVersion
  , blockSize
  , blockTxCount
  , blockTxs
  , blockOpCert
  , blockVrfKey
  , blockVrfKeyToPoolHash
  , epochNumber
  , fakeGenesisHash

  , ledgerAccountState
  , ledgerDelegationState
  , ledgerRewardsState
  , ledgerState

  , maybePaymentCred
  , mkSlotLeader
  , nonceToBytes
  , renderAddress
  , renderHash
  , renderRewardAcnt
  , rewardUpdates
  , slotLeaderHash
  , slotNumber
  , stakingCredHash
  , txFee
  , txHash
  , txCertificates
  , txInputList
  , txMetadata
  , txOutputList
  , txOutputSum
  , txParamUpdate
  , txWithdrawals
  , txWithdrawalSum
  , unHeaderHash
  , unitIntervalToDouble
  , unKeyHashBS
  , unTxHash
  ) where

import           Cardano.Prelude

import qualified Cardano.Api.Typed as Api

import qualified Cardano.Crypto.Hash as Crypto
import qualified Cardano.Crypto.DSIGN as DSIGN
import qualified Cardano.Crypto.KES.Class as KES
import qualified Cardano.Crypto.VRF.Class as VRF

import qualified Cardano.Db as Db
import           Cardano.DbSync.Config
import           Cardano.DbSync.Types

import qualified Cardano.Ledger.Crypto as Shelley
import qualified Cardano.Ledger.Era as ShelleyEra

import           Cardano.Slotting.Slot (SlotNo (..))

import qualified Data.Binary.Put as Binary
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Map.Strict as Map
import           Data.Sequence.Strict (StrictSeq (..))
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

import           Ouroboros.Consensus.HardFork.Combinator.Basics (LedgerState (..))
import qualified Ouroboros.Consensus.Shelley.Ledger.Block as Consensus
import qualified Ouroboros.Consensus.Shelley.Ledger.Ledger as Consensus
import           Ouroboros.Consensus.Shelley.Protocol (StandardShelley, StandardShelley)
import           Ouroboros.Network.Block (BlockNo (..))

import qualified Shelley.Spec.Ledger.Address as Shelley
import           Shelley.Spec.Ledger.Coin (Coin (..))
import qualified Shelley.Spec.Ledger.BaseTypes as Shelley
import qualified Shelley.Spec.Ledger.BlockChain as Shelley
import qualified Shelley.Spec.Ledger.Credential as Shelley
import qualified Shelley.Spec.Ledger.Hashing as Shelley
import qualified Shelley.Spec.Ledger.Keys as Shelley
import qualified Shelley.Spec.Ledger.LedgerState as Shelley
import qualified Shelley.Spec.Ledger.MetaData as Shelley
import qualified Shelley.Spec.Ledger.OCert as Shelley
import qualified Shelley.Spec.Ledger.PParams as Shelley
import qualified Shelley.Spec.Ledger.Tx as Shelley
import qualified Shelley.Spec.Ledger.TxBody as Shelley

annotateStakingCred :: DbSyncEnv -> ShelleyStakingCred -> Shelley.RewardAcnt StandardShelley
annotateStakingCred env cred =
  let network =
        case envProtocol env of
          DbSyncProtocolCardano -> envNetwork env
  in Shelley.RewardAcnt network cred

blockBody :: ShelleyBlock -> Shelley.BHBody StandardShelley
blockBody = Shelley.bhbody . Shelley.bheader . Consensus.shelleyBlockRaw

blockHash :: ShelleyBlock -> ByteString
blockHash = unHeaderHash . Consensus.shelleyBlockHeaderHash

blockNumber :: ShelleyBlock -> Word64
blockNumber = unBlockNo . Shelley.bheaderBlockNo . blockBody

blockPrevHash :: ShelleyBlock -> ByteString
blockPrevHash blk =
  case Shelley.bheaderPrev (Shelley.bhbody . Shelley.bheader $ Consensus.shelleyBlockRaw blk) of
    Shelley.GenesisHash -> fakeGenesisHash
    Shelley.BlockHash h -> Crypto.hashToBytes $ Shelley.unHashHeader h

blockProtoVersion :: Shelley.BHBody StandardShelley -> Text
blockProtoVersion = Text.pack . show . Shelley.bprotver

blockSize :: ShelleyBlock -> Word64
blockSize = fromIntegral . Shelley.bBodySize . Shelley.bbody . Consensus.shelleyBlockRaw

blockTxCount :: ShelleyBlock -> Word64
blockTxCount = fromIntegral . length . unTxSeq . Shelley.bbody . Consensus.shelleyBlockRaw

blockTxs :: Consensus.ShelleyBlock StandardShelley -> [ShelleyTx]
blockTxs =
    txList . Shelley.bbody . Consensus.shelleyBlockRaw
  where
    txList :: ShelleyTxSeq -> [ShelleyTx]
    txList (Shelley.TxSeq txSeq) = toList txSeq

blockOpCert :: Shelley.BHBody StandardShelley -> ByteString
blockOpCert = KES.rawSerialiseVerKeyKES . Shelley.ocertVkHot . Shelley.bheaderOCert

blockVrfKey :: Shelley.BHBody StandardShelley -> ByteString
blockVrfKey = VRF.rawSerialiseVerKeyVRF . Shelley.bheaderVrfVk

blockVrfKeyToPoolHash :: ShelleyBlock -> ByteString
blockVrfKeyToPoolHash =
 Crypto.digest (Proxy :: Proxy Crypto.Blake2b_224) . slotLeaderHash

epochNumber :: ShelleyBlock -> Word64 -> Word64
epochNumber blk slotsPerEpoch = slotNumber blk `div` slotsPerEpoch

-- | This is both the Genesis Hash and the hash of the previous block.
fakeGenesisHash :: ByteString
fakeGenesisHash = BS.take 32 ("GenesisHash " <> BS.replicate 32 '\0')

maybePaymentCred :: Shelley.Addr StandardShelley -> Maybe ByteString
maybePaymentCred addr =
  case addr of
    Shelley.Addr _nw pcred _sref ->
      Just $ LBS.toStrict (Binary.runPut $ Shelley.putCredential pcred)
    Shelley.AddrBootstrap {} ->
      Nothing

ledgerAccountState :: LedgerState ShelleyBlock -> Shelley.AccountState
ledgerAccountState = Shelley.esAccountState . Shelley.nesEs . Consensus.shelleyLedgerState

ledgerDelegationState :: LedgerState ShelleyBlock -> Shelley.DPState StandardShelley
ledgerDelegationState = Shelley._delegationState . ledgerState

ledgerRewardsState :: LedgerState ShelleyBlock -> Map (Shelley.Credential 'Shelley.Staking StandardShelley) Coin
ledgerRewardsState = Shelley._rewards . Shelley._dstate . ledgerDelegationState

ledgerState :: LedgerState ShelleyBlock -> Shelley.LedgerState StandardShelley
ledgerState = Shelley.esLState . Shelley.nesEs . Consensus.shelleyLedgerState

mkSlotLeader :: ShelleyBlock -> Maybe Db.PoolHashId -> Db.SlotLeader
mkSlotLeader blk mPoolId =
  let slHash = slotLeaderHash blk
      short = Text.decodeUtf8 (Base16.encode $ BS.take 8 slHash)
      slName = case mPoolId of
                Nothing -> "ShelleyGenesis-" <> short
                Just _ -> "Pool-" <> short
  in Db.SlotLeader slHash mPoolId slName


nonceToBytes :: Shelley.Nonce -> ByteString
nonceToBytes nonce =
  case nonce of
    Shelley.Nonce hash -> Crypto.hashToBytes hash
    Shelley.NeutralNonce -> BS.replicate 28 '\0'

renderAddress :: Shelley.Addr StandardShelley -> Text
renderAddress addr =
    case addr of
      Shelley.Addr nw pcred sref ->
        Api.serialiseAddress (Api.ShelleyAddress nw pcred sref)
      Shelley.AddrBootstrap (Shelley.BootstrapAddress baddr) ->
        Api.serialiseAddress (Api.ByronAddress baddr :: Api.Address Api.Byron)

renderHash :: ShelleyHash -> Text
renderHash = Text.decodeUtf8 . Base16.encode . unHeaderHash

renderRewardAcnt :: Shelley.RewardAcnt StandardShelley -> Text
renderRewardAcnt (Shelley.RewardAcnt nw cred) =
    Api.serialiseAddress (Api.StakeAddress nw cred)

rewardUpdates :: Shelley.RewardAccounts era -> Shelley.RewardAccounts era -> Shelley.RewardAccounts era
rewardUpdates =
    Map.differenceWith keepUpdate
  where
    keepUpdate :: Coin -> Coin -> Maybe Coin
    keepUpdate a b =
      if a == b then Nothing else Just b

slotLeaderHash :: ShelleyBlock -> ByteString
slotLeaderHash =
  DSIGN.rawSerialiseVerKeyDSIGN . Shelley.unVKey . Shelley.bheaderVk . blockBody

slotNumber :: ShelleyBlock -> Word64
slotNumber = unSlotNo . Shelley.bheaderSlotNo . blockBody

stakingCredHash :: DbSyncEnv -> ShelleyStakingCred -> ByteString
stakingCredHash env = Shelley.serialiseRewardAcnt . annotateStakingCred env

txCertificates :: Shelley.Tx StandardShelley-> [(Word16, ShelleyDCert)]
txCertificates tx =
    zip [0 ..] (toList . Shelley._certs $ Shelley._body tx)

txFee :: ShelleyTx -> Word64
txFee = fromIntegral . unCoin . Shelley._txfee . Shelley._body

txHash :: ShelleyTx -> ByteString
txHash = Crypto.hashToBytes . Shelley.hashAnnotated . Shelley._body

txInputList :: ShelleyTx -> [ShelleyTxIn]
txInputList = toList . Shelley._inputs . Shelley._body

txMetadata :: ShelleyTx -> Maybe Shelley.MetaData
txMetadata = Shelley.strictMaybeToMaybe . Shelley._metadata

txParamUpdate :: ShelleyTx -> Maybe (Shelley.Update StandardShelley)
txParamUpdate = Shelley.strictMaybeToMaybe . Shelley._txUpdate . Shelley._body

-- Outputs are ordered, so provide them as such with indices.
txOutputList :: ShelleyTx -> [(Word16, ShelleyTxOut)]
txOutputList tx =
  zip [0 .. ] $ toList (Shelley._outputs $ Shelley._body tx)

txOutputSum :: ShelleyTx -> Word64
txOutputSum tx =
    foldl' (+) 0 $ map outValue (Shelley._outputs $ Shelley._body tx)
  where
    outValue :: ShelleyTxOut -> Word64
    outValue (Shelley.TxOut _ coin) = fromIntegral $ unCoin coin

txWithdrawals :: ShelleyTx -> [(Shelley.RewardAcnt StandardShelley, Coin)]
txWithdrawals = Map.toList . Shelley.unWdrl . Shelley._wdrls . Shelley._body

txWithdrawalSum :: ShelleyTx -> Word64
txWithdrawalSum =
  fromIntegral . sum . map (unCoin . snd) . Map.toList . Shelley.unWdrl
    . Shelley._wdrls . Shelley._body

unHeaderHash :: ShelleyHash -> ByteString
unHeaderHash = Crypto.hashToBytes . Shelley.unHashHeader . Consensus.unShelleyHash

unitIntervalToDouble :: Shelley.UnitInterval -> Double
unitIntervalToDouble = fromRational . Shelley.unitIntervalToRational

unKeyHash :: Shelley.KeyHash disc era
                   -> Crypto.Hash
                        (Shelley.ADDRHASH (ShelleyEra.Crypto era))
                        (DSIGN.VerKeyDSIGN (Shelley.DSIGN (ShelleyEra.Crypto era)))

unKeyHash (Shelley.KeyHash x) = x

unKeyHashBS :: Shelley.KeyHash d crypto -> ByteString
unKeyHashBS = Crypto.hashToBytes . unKeyHash

unTxHash :: ShelleyTxId -> ByteString
unTxHash (Shelley.TxId txid) = Crypto.hashToBytes txid

unTxSeq :: ShelleyTxSeq-> StrictSeq ShelleyTx
unTxSeq (Shelley.TxSeq txSeq) = txSeq
