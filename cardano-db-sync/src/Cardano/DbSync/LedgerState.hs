{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.DbSync.LedgerState
  ( CardanoLedgerState (..)
  , LedgerStateVar (..)
  , applyBlock
  , initLedgerStateVar
  , loadLedgerState
  , saveLedgerState
  ) where

import qualified Cardano.Binary as Serialize

import           Cardano.DbSync.Config
import           Cardano.DbSync.Config.Cardano
import           Cardano.DbSync.Config.Types
import           Cardano.DbSync.Types
import           Cardano.DbSync.Util

import           Cardano.Prelude

import           Cardano.Slotting.Slot (SlotNo (..), fromWithOrigin)

import           Control.Concurrent.STM.TMVar (TMVar, newTMVarIO, putTMVar, takeTMVar)
import           Control.Exception (IOException, handle)
import qualified Control.Exception as Exception
import           Control.Monad.Extra (firstJustM)

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import           Data.Either (partitionEithers)
import qualified Data.List as List

import           Ouroboros.Consensus.Block (CodecConfig, blockNo, blockPrevHash)
import           Ouroboros.Consensus.Byron.Ledger (initByronLedgerState)
import           Ouroboros.Consensus.Cardano.CanHardFork ()
import           Ouroboros.Consensus.Config (TopLevelConfig (..))
import           Ouroboros.Consensus.Ledger.Abstract (LedgerConfig, ledgerTipHash, ledgerTipSlot, tickThenReapply)
import           Ouroboros.Consensus.HardFork.Combinator.Basics (LedgerState (..))
import           Ouroboros.Consensus.HardFork.Combinator.State.Infra (initHardForkState)
import           Ouroboros.Consensus.Storage.ChainDB.Serialisation (DecodeDisk (..), EncodeDisk (..))

import           System.Directory (listDirectory, removeFile)
import           System.FilePath ((</>), dropExtension, takeExtension)

data CardanoLedgerState = CardanoLedgerState
  { clsState :: !(LedgerState CardanoBlock)
  , clsConfig :: !(LedgerConfig CardanoBlock)
  , clsCodec :: !(CodecConfig CardanoBlock)
  }

newtype LedgerStateVar = LedgerStateVar
  { unLedgerStateVar :: TMVar CardanoLedgerState
  }

data LedgerStateFile = LedgerStateFile -- Internal use only.
  { lsfSlotNo :: !Word64
  , lsfFilePath :: !FilePath
  }

initLedgerStateVar :: GenesisConfig -> IO LedgerStateVar
initLedgerStateVar genesisConfig = do
  LedgerStateVar <$>
    case genesisConfig of
      GenesisCardano byronConfig _ -> do
        let topConfig = mkTopLevelConfig genesisConfig
        newTMVarIO $
          CardanoLedgerState
            { clsState = HardForkLedgerState $ initHardForkState (initByronLedgerState byronConfig Nothing)
            , clsConfig = topLevelConfigLedger topConfig
            , clsCodec = topLevelConfigCodec topConfig
            }

-- The function 'tickThenReapply' does zero validation, so add minimal validation ('blockPrevHash'
-- matches the tip hash of the 'LedgerState'). This was originally for debugging but the check is
-- cheap enough to keep.
applyBlock :: LedgerStateVar -> CardanoBlock -> IO CardanoLedgerState
applyBlock (LedgerStateVar stateVar) blk =
  -- 'LedgerStateVar' is just being used as a mutable variable. There should not ever
  -- be any contention on this variable, so putting everything inside 'atomically'
  -- is fine.
  atomically $ do
    oldState <- takeTMVar stateVar
    if ledgerTipHash (clsState oldState) == blockPrevHash blk
      then do
        let !newState = oldState { clsState = tickThenReapply (clsConfig oldState) blk (clsState oldState) }
        putTMVar stateVar newState
        pure newState
      else panic $ "applyBlock: Hash mismatch for block no " <> textShow (blockNo blk)


saveLedgerState :: LedgerStateDir -> CardanoLedgerState -> SyncState -> IO ()
saveLedgerState lsd@(LedgerStateDir stateDir) ledger synced =
  case synced of
    SyncFollowing -> saveState                      -- If following, save every state.
    SyncLagging
      | unSlotNo slot `mod` 10000 == 0 -> saveState -- Only save state ocassionally.
      | otherwise -> pure ()
  where
    filename :: FilePath
    filename = stateDir </> show (unSlotNo slot) ++ ".lstate"

    slot :: SlotNo
    slot = fromWithOrigin (SlotNo 0) (ledgerTipSlot $ clsState ledger)

    saveState :: IO ()
    saveState = do
      -- Encode and write lazily.
      LBS.writeFile filename $
        Serialize.serializeEncoding (encodeDisk (clsCodec ledger) $ clsState ledger)
      cleanupLedgerStateFiles lsd slot

loadLedgerState :: LedgerStateDir -> CardanoLedgerState -> SlotNo -> IO (Maybe CardanoLedgerState)
loadLedgerState stateDir ledger slotNo = do
    files <- listLedgerStateFilesOrdered stateDir
    let (invalid, valid) = partitionEithers $ map keepFile files
    -- Remove invalid (ie SlotNo >= current) ledger state files (occurs on rollback).
    mapM_ safeRemoveFile invalid
    -- Want the highest numbered snapshot.
    firstJustM loadFile valid
  where
    -- Left files are deleted, Right files are kept.
    keepFile :: LedgerStateFile ->  Either FilePath LedgerStateFile
    keepFile lsf@(LedgerStateFile w fp) =
      if SlotNo w <= slotNo
        then Right lsf
        else Left fp

    loadFile :: LedgerStateFile -> IO (Maybe CardanoLedgerState)
    loadFile lsf = do
      mst <- safeReadFile (lsfFilePath lsf)
      case mst of
        Nothing -> pure Nothing
        Just st -> pure . Just $ ledger { clsState = st }

    safeReadFile :: FilePath -> IO (Maybe (LedgerState CardanoBlock))
    safeReadFile fp = do
      mbs <- Exception.try $ BS.readFile fp
      case mbs of
        Left (_ :: IOException) -> pure Nothing
        Right bs -> pure $ decode bs

    decode :: ByteString -> Maybe (LedgerState CardanoBlock)
    decode =
      either (const Nothing) Just
        . Serialize.decodeFullDecoder "Ledger state file" (decodeDisk (clsCodec ledger))
        . LBS.fromStrict

-- Get a list of the ledger state files order most recent
listLedgerStateFilesOrdered :: LedgerStateDir -> IO [LedgerStateFile]
listLedgerStateFilesOrdered (LedgerStateDir stateDir) = do
    files <- filter isLedgerStateFile <$> listDirectory stateDir
    pure . List.sortBy revSlotNoOrder $ map extractIndex files
  where
    isLedgerStateFile :: FilePath -> Bool
    isLedgerStateFile fp = takeExtension fp == ".lstate"

    extractIndex :: FilePath -> LedgerStateFile
    extractIndex fp =
      case readMaybe (dropExtension fp) of
        Nothing -> LedgerStateFile 0 fp -- Should never happen.
        Just w -> LedgerStateFile w (stateDir </> fp)

    revSlotNoOrder :: LedgerStateFile -> LedgerStateFile -> Ordering
    revSlotNoOrder a b = compare (lsfSlotNo b) (lsfSlotNo a)

-- Find the ledger state files and keep the 4 most recent.
cleanupLedgerStateFiles :: LedgerStateDir -> SlotNo -> IO ()
cleanupLedgerStateFiles stateDir slotNo = do
    files <- listLedgerStateFilesOrdered stateDir
    let (invalid, valid) = partitionEithers $ map keepFile files
    -- Remove invalid (ie SlotNo >= current) ledger state files (occurs on rollback).
    mapM_ safeRemoveFile invalid
    -- Remove all by 5 most recent state files.
    mapM_ safeRemoveFile $ map lsfFilePath (List.drop 5 valid)
  where
    -- Left files are deleted, Right files are kept.
    keepFile :: LedgerStateFile ->  Either FilePath LedgerStateFile
    keepFile lsf@(LedgerStateFile w fp) =
      if SlotNo w <= slotNo
        then Right lsf
        else Left fp

-- | Remove given file path and ignore any IOEXceptions.
safeRemoveFile :: FilePath -> IO ()
safeRemoveFile fp = handle (\(_ :: IOException) -> pure ()) $ removeFile fp

