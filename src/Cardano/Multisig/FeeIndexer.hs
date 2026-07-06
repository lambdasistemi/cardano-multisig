{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.FeeIndexer
    ( FeeIndexerConfig (..)
    , FeeIndexerDeps (..)
    , FeeIndexerChainSyncRunner
    , FeeIndexResult (..)
    , FeeIndexerBlock (..)
    , FeeIndexerChainEvent (..)
    , FeeIndexerOutput (..)
    , FeeIndexerTx (..)
    , classifyFeeTx
    , loadFeeIndexerCheckpoint
    , runFeeIndexer
    , runFeeIndexerSupervisor
    , runFeeIndexerSupervisorWith
    , runFeeIndexerOnce
    , runFeeIndexerWith
    , saveFeeIndexerCheckpoint
    )
where

-- \|
-- Module      : Cardano.Multisig.FeeIndexer
-- Description : Fee-address indexer classification model
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0
--
-- Pure fee-payment classification, checkpointed chain-sync follower state,
-- and a mockable runner surface for the fee-address indexer.

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.BaseTypes
    ( StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Ledger.TxIn qualified as TxIn
import Cardano.Multisig.FeeTag
    ( FeeMetadata
    , decodeFeeTag
    )
import Cardano.Multisig.Store
    ( FeePayment (..)
    , MalformedFeePayment (..)
    , Store (..)
    )
import Cardano.Node.Client.N2C.ChainSync
    ( Fetched (..)
    , HeaderPoint
    , mkChainSyncN2C
    , runChainSyncN2C
    )
import Cardano.Read.Ledger.Block.Block (fromConsensusBlock)
import Cardano.Read.Ledger.Block.Txs (getEraTransactions)
import Cardano.Read.Ledger.Eras.EraValue (applyEraFun)
import Cardano.Read.Ledger.Eras.KnownEras
    ( Era (..)
    , IsEra
    , theEra
    )
import Cardano.Read.Ledger.Tx.Tx (Tx (..))
import Cardano.Slotting.Slot (SlotNo (..))
import ChainFollower
    ( Follower (..)
    , Intersector (..)
    , ProgressOrRewind (..)
    )
import Control.Concurrent (threadDelay)
import Control.Exception
    ( AsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (when)
import Control.Tracer (nullTracer)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Short qualified as SBS
import Data.Foldable (traverse_)
import Data.Foldable qualified as Foldable
import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
import Data.Word (Word32, Word64)
import Lens.Micro ((^.))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    , getOneEraHash
    )
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Network.Point
import System.Directory
    ( createDirectoryIfMissing
    , doesFileExist
    , removeFile
    )

data FeeIndexerConfig = FeeIndexerConfig
    { ficSocketPath :: FilePath
    , ficNetworkMagic :: Word32
    , ficByronEpochSlots :: Word64
    , ficFeeAddress :: Addr
    , ficCheckpointDir :: FilePath
    , ficRetryDelayMicros :: Int
    }
    deriving stock (Eq, Show)

data FeeIndexerDeps m = FeeIndexerDeps
    { fidStore :: Store m
    , fidObserveTip :: SlotNo -> m ()
    }

type FeeIndexerChainSyncRunner =
    EpochSlots
    -> NetworkMagic
    -> FilePath
    -> Intersector HeaderPoint Network.SlotNo Fetched
    -> [HeaderPoint]
    -> IO (Either SomeException ())

data FeeIndexerOutput = FeeIndexerOutput
    { fioTxIn :: TxIn
    , fioAddress :: Addr
    , fioLovelace :: Word64
    }
    deriving stock (Eq, Show)

data FeeIndexerTx = FeeIndexerTx
    { fitMetadata :: FeeMetadata
    , fitOutputs :: [FeeIndexerOutput]
    }
    deriving stock (Eq, Show)

data FeeIndexerBlock = FeeIndexerBlock
    { fibSlot :: SlotNo
    , fibTransactions :: [FeeIndexerTx]
    }
    deriving stock (Eq, Show)

data FeeIndexerChainEvent
    = FeeIndexerRollForward FeeIndexerBlock
    | FeeIndexerRollBackward SlotNo
    deriving stock (Eq, Show)

data FeeIndexResult
    = FeeIndexPayment FeePayment
    | FeeIndexMalformed TxIn SlotNo
    deriving stock (Eq, Show)

runFeeIndexer :: FeeIndexerConfig -> FeeIndexerDeps IO -> IO ()
runFeeIndexer =
    runFeeIndexerWith
        defaultFeeIndexerChainSyncRunner
        extractFeeIndexerBlock

runFeeIndexerWith
    :: FeeIndexerChainSyncRunner
    -> (Fetched -> IO FeeIndexerBlock)
    -> FeeIndexerConfig
    -> FeeIndexerDeps IO
    -> IO ()
runFeeIndexerWith chainSyncRunner extractBlock cfg deps = do
    checkpoint <- loadFeeIndexerCheckpoint (ficCheckpointDir cfg)
    let startPoints =
            case checkpoint of
                Nothing -> [originPoint]
                Just point -> [point]
        intersector =
            mkFeeIndexerIntersector
                extractBlock
                cfg
                deps
                (not (null (maybeToList checkpoint)))
    result <-
        chainSyncRunner
            (EpochSlots (ficByronEpochSlots cfg))
            (NetworkMagic (fromIntegral (ficNetworkMagic cfg)))
            (ficSocketPath cfg)
            intersector
            startPoints
    case result of
        Left err -> throwIO err
        Right () -> pure ()

runFeeIndexerSupervisor
    :: FeeIndexerConfig -> FeeIndexerDeps IO -> IO ()
runFeeIndexerSupervisor =
    runFeeIndexerSupervisorWith
        defaultFeeIndexerChainSyncRunner
        extractFeeIndexerBlock

runFeeIndexerSupervisorWith
    :: FeeIndexerChainSyncRunner
    -> (Fetched -> IO FeeIndexerBlock)
    -> FeeIndexerConfig
    -> FeeIndexerDeps IO
    -> IO ()
runFeeIndexerSupervisorWith chainSyncRunner extractBlock cfg deps =
    go
  where
    go = do
        result <-
            try
                ( runFeeIndexerWith
                    chainSyncRunner
                    extractBlock
                    cfg
                    deps
                )
        case result of
            Right () ->
                pure ()
            Left err
                | isAsyncException err ->
                    throwIO err
                | otherwise -> do
                    threadDelay (ficRetryDelayMicros cfg)
                    go

classifyFeeTx :: Addr -> SlotNo -> FeeIndexerTx -> [FeeIndexResult]
classifyFeeTx feeAddress slot tx =
    case decodeFeeTag (fitMetadata tx) of
        Just bodyHash ->
            [ FeeIndexPayment
                FeePayment
                    { feePaymentBodyHash = bodyHash
                    , feePaymentTxIn = fioTxIn output
                    , feePaymentLovelace = fioLovelace output
                    , feePaymentBlockSlot = slot
                    }
            | output <- matchingOutputs
            ]
        Nothing ->
            [ FeeIndexMalformed (fioTxIn output) slot
            | output <- matchingOutputs
            ]
  where
    matchingOutputs =
        [ output
        | output <- fitOutputs tx
        , fioAddress output == feeAddress
        , fioLovelace output > 0
        ]

runFeeIndexerOnce
    :: Monad m
    => Store m
    -> Addr
    -> FeeIndexerChainEvent
    -> m ()
runFeeIndexerOnce store feeAddress = \case
    FeeIndexerRollForward block ->
        traverse_
            (applyResult store)
            [ result
            | tx <- fibTransactions block
            , result <- classifyFeeTx feeAddress (fibSlot block) tx
            ]
    FeeIndexerRollBackward slot -> do
        storeRollbackFeePaymentsFrom store slot
        storeRollbackMalformedFeePaymentsFrom store slot

applyResult :: Store m -> FeeIndexResult -> m ()
applyResult store = \case
    FeeIndexPayment payment ->
        storeUpsertFeePayment store payment
    FeeIndexMalformed txIn slot ->
        storePutMalformedFeePayment
            store
            MalformedFeePayment
                { malformedFeePaymentTxIn = txIn
                , malformedFeePaymentBlockSlot = slot
                }

mkFeeIndexerIntersector
    :: (Fetched -> IO FeeIndexerBlock)
    -> FeeIndexerConfig
    -> FeeIndexerDeps IO
    -> Bool
    -> Intersector HeaderPoint Network.SlotNo Fetched
mkFeeIndexerIntersector extractBlock cfg deps warmBoot = self
  where
    self =
        Intersector
            { intersectFound = \point -> do
                rollbackIndexedRows deps (slotOfPoint point)
                pure $ mkFeeIndexerFollower extractBlock cfg deps
            , intersectNotFound =
                if warmBoot
                    then do
                        rollbackIndexedRows deps (SlotNo 0)
                        clearFeeIndexerCheckpoint (ficCheckpointDir cfg)
                        pure
                            ( mkFeeIndexerIntersector
                                extractBlock
                                cfg
                                deps
                                False
                            , [originPoint]
                            )
                    else pure (self, [originPoint])
            }

mkFeeIndexerFollower
    :: (Fetched -> IO FeeIndexerBlock)
    -> FeeIndexerConfig
    -> FeeIndexerDeps IO
    -> Follower HeaderPoint Network.SlotNo Fetched
mkFeeIndexerFollower extractBlock cfg deps = self
  where
    self =
        Follower
            { rollForward = \fetched tip -> do
                block <- extractBlock fetched
                runFeeIndexerOnce
                    (fidStore deps)
                    (ficFeeAddress cfg)
                    (FeeIndexerRollForward block)
                saveFeeIndexerCheckpoint
                    (ficCheckpointDir cfg)
                    (fetchedPoint fetched)
                fidObserveTip deps (networkSlotToSlotNo tip)
                pure self
            , rollBackward = \point -> do
                rollbackIndexedRows deps (slotOfPoint point)
                case point of
                    Network.Point Network.Point.Origin ->
                        clearFeeIndexerCheckpoint (ficCheckpointDir cfg)
                    Network.Point (Network.Point.At _) ->
                        saveFeeIndexerCheckpoint
                            (ficCheckpointDir cfg)
                            point
                pure (Progress self)
            }

rollbackIndexedRows :: FeeIndexerDeps IO -> SlotNo -> IO ()
rollbackIndexedRows deps slot = do
    storeRollbackFeePaymentsFrom (fidStore deps) slot
    storeRollbackMalformedFeePaymentsFrom (fidStore deps) slot

defaultFeeIndexerChainSyncRunner :: FeeIndexerChainSyncRunner
defaultFeeIndexerChainSyncRunner epochSlots magic socketPath intersector points =
    runChainSyncN2C
        epochSlots
        magic
        socketPath
        (mkChainSyncN2C nullTracer nullTracer intersector points)

extractFeeIndexerBlock :: Fetched -> IO FeeIndexerBlock
extractFeeIndexerBlock fetched =
    pure
        FeeIndexerBlock
            { fibSlot = slotOfPoint (fetchedPoint fetched)
            , fibTransactions =
                applyEraFun
                    (extractEraTransactions . getEraTransactions)
                    (fromConsensusBlock (fetchedBlock fetched))
            }

extractEraTransactions
    :: forall era. IsEra era => [Tx era] -> [FeeIndexerTx]
extractEraTransactions txs =
    case theEra @era of
        Byron -> []
        Shelley ->
            extractShelleyFamilyTx coinLovelace . unTx <$> txs
        Allegra ->
            extractShelleyFamilyTx coinLovelace . unTx <$> txs
        Mary ->
            extractShelleyFamilyTx maryValueLovelace . unTx <$> txs
        Alonzo ->
            extractShelleyFamilyTx maryValueLovelace . unTx <$> txs
        Babbage ->
            extractShelleyFamilyTx maryValueLovelace . unTx <$> txs
        Conway ->
            extractShelleyFamilyTx maryValueLovelace . unTx <$> txs
        Dijkstra ->
            extractShelleyFamilyTx maryValueLovelace . unTx <$> txs

extractShelleyFamilyTx
    :: forall era
     . Ledger.EraTx era
    => (Ledger.Value era -> Word64)
    -> Ledger.Tx Ledger.TopTx era
    -> FeeIndexerTx
extractShelleyFamilyTx lovelaceOf tx =
    FeeIndexerTx
        { fitMetadata = txMetadata tx
        , fitOutputs =
            zipWith
                (mkFeeIndexerOutput @era lovelaceOf txId)
                [0 ..]
                (Foldable.toList outputs)
        }
  where
    body = tx ^. Ledger.bodyTxL
    txId = Ledger.txIdTxBody body
    outputs = body ^. Ledger.outputsTxBodyL

mkFeeIndexerOutput
    :: forall era
     . Ledger.EraTxOut era
    => (Ledger.Value era -> Word64)
    -> TxIn.TxId
    -> Word64
    -> Ledger.TxOut era
    -> FeeIndexerOutput
mkFeeIndexerOutput lovelaceOf txId outputIndex output =
    FeeIndexerOutput
        { fioTxIn =
            TxIn.TxIn
                txId
                (TxIx (fromIntegral outputIndex))
        , fioAddress = output ^. Ledger.addrTxOutL
        , fioLovelace = lovelaceOf (output ^. Ledger.valueTxOutL)
        }

txMetadata
    :: Ledger.EraTx era
    => Ledger.Tx Ledger.TopTx era
    -> FeeMetadata
txMetadata tx =
    case tx ^. Ledger.auxDataTxL of
        SNothing -> Map.empty
        SJust auxData -> auxData ^. Ledger.metadataTxAuxDataL

coinLovelace :: Coin -> Word64
coinLovelace (Coin lovelace) =
    fromIntegral lovelace

maryValueLovelace :: MaryValue -> Word64
maryValueLovelace (MaryValue (Coin lovelace) _) =
    fromIntegral lovelace

saveFeeIndexerCheckpoint :: FilePath -> HeaderPoint -> IO ()
saveFeeIndexerCheckpoint dir point =
    case checkpointFromPoint point of
        Nothing -> clearFeeIndexerCheckpoint dir
        Just (slot, hashBytes) -> do
            createDirectoryIfMissing True dir
            BS8.writeFile
                (checkpointPath dir)
                (encodeCheckpoint slot hashBytes)

loadFeeIndexerCheckpoint :: FilePath -> IO (Maybe HeaderPoint)
loadFeeIndexerCheckpoint dir = do
    exists <- doesFileExist (checkpointPath dir)
    if exists
        then do
            bytes <- BS8.readFile (checkpointPath dir)
            pure $ pointFromCheckpoint =<< decodeCheckpoint bytes
        else pure Nothing

clearFeeIndexerCheckpoint :: FilePath -> IO ()
clearFeeIndexerCheckpoint dir = do
    exists <- doesFileExist (checkpointPath dir)
    when exists $ removeFile (checkpointPath dir)

checkpointPath :: FilePath -> FilePath
checkpointPath dir =
    dir <> "/checkpoint"

checkpointFromPoint :: HeaderPoint -> Maybe (Word64, ByteString)
checkpointFromPoint = \case
    Network.Point Network.Point.Origin ->
        Nothing
    Network.Point
        (Network.Point.At (Network.Point.Block slot hash)) ->
            Just
                ( Network.unSlotNo slot
                , SBS.fromShort (getOneEraHash hash)
                )

pointFromCheckpoint :: (Word64, ByteString) -> Maybe HeaderPoint
pointFromCheckpoint (slot, hashBytes)
    | BS8.length hashBytes == 32 =
        Just
            $ Network.Point
            $ Network.Point.At
            $ Network.Point.Block
                (Network.SlotNo slot)
                (OneEraHash (SBS.toShort hashBytes))
    | otherwise =
        Nothing

encodeCheckpoint :: Word64 -> ByteString -> ByteString
encodeCheckpoint slot hashBytes =
    BS8.unwords
        [ BS8.pack (show slot)
        , Base16.encode hashBytes
        ]

decodeCheckpoint :: ByteString -> Maybe (Word64, ByteString)
decodeCheckpoint bytes =
    case BS8.words bytes of
        [slotBytes, hashHex] -> do
            slot <- readMaybeWord64 slotBytes
            hashBytes <-
                case Base16.decode hashHex of
                    Right decoded -> Just decoded
                    Left _ -> Nothing
            Just (slot, hashBytes)
        _ ->
            Nothing

readMaybeWord64 :: ByteString -> Maybe Word64
readMaybeWord64 bytes =
    case reads (BS8.unpack bytes) of
        [(n, "")] -> Just n
        _ -> Nothing

slotOfPoint :: HeaderPoint -> SlotNo
slotOfPoint point =
    case Network.pointSlot point of
        Network.Point.Origin -> SlotNo 0
        Network.Point.At slot -> networkSlotToSlotNo slot

networkSlotToSlotNo :: Network.SlotNo -> SlotNo
networkSlotToSlotNo slot =
    SlotNo (Network.unSlotNo slot)

originPoint :: HeaderPoint
originPoint =
    Network.Point Network.Point.Origin

isAsyncException :: SomeException -> Bool
isAsyncException err =
    case fromException err :: Maybe AsyncException of
        Just _ -> True
        Nothing -> False
