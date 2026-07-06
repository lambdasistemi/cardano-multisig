{-# LANGUAGE DataKinds #-}

module Cardano.Multisig.FeeIndexerSpec
    ( spec
    ) where

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , genKeyDSIGN
    )
import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm)
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , TxIx (..)
    )
import Cardano.Ledger.Credential
    ( Credential (KeyHashObj)
    , StakeReference (StakeRefNull)
    )
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Keys
    ( KeyHash
    , KeyRole (Payment)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Shelley.TxAuxData (Metadatum (I, Map, S))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.FeeIndexer
    ( FeeIndexResult (..)
    , FeeIndexerBlock (..)
    , FeeIndexerChainEvent (..)
    , FeeIndexerConfig (..)
    , FeeIndexerDeps (..)
    , FeeIndexerOutput (..)
    , FeeIndexerTx (..)
    , classifyFeeTx
    , loadFeeIndexerCheckpoint
    , runFeeIndexerOnce
    , runFeeIndexerSupervisorWith
    , runFeeIndexerWith
    , saveFeeIndexerCheckpoint
    )
import Cardano.Multisig.FeeTag
    ( encodeFeeTag
    , feeTagBodyHashKey
    , feeTagLabel
    )
import Cardano.Multisig.Store
    ( EntryId (..)
    , FeeAllowance (..)
    , FeePayment (..)
    , MalformedFeePayment (..)
    , Store (..)
    )
import Cardano.Node.Client.N2C.ChainSync
    ( Fetched (..)
    , HeaderPoint
    )
import Cardano.Slotting.Slot (SlotNo (..))
import ChainFollower
    ( Follower (..)
    , Intersector (..)
    )
import Control.Exception
    ( AsyncException (ThreadKilled)
    , throwIO
    )
import Control.Monad.State.Strict
    ( State
    , execState
    , gets
    , modify'
    )
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word16, Word64, Word8)
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Point qualified as Network.Point
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldReturn
    , shouldThrow
    )
import Unsafe.Coerce (unsafeCoerce)

spec :: Spec
spec =
    describe "Cardano.Multisig.FeeIndexer" $ do
        it "classifies fee-address output plus decodable tag as one payment" $ do
            classifyFeeTx feeAddress (SlotNo 20) taggedTx
                `shouldBe` [FeeIndexPayment expectedPayment]

        it "ignores wrong-address outputs" $ do
            classifyFeeTx feeAddress (SlotNo 20) taggedWrongAddressTx
                `shouldBe` []

        it "records missing metadata as malformed by tx input" $ do
            classifyFeeTx feeAddress (SlotNo 20) missingMetadataTx
                `shouldBe` [FeeIndexMalformed feeTxIn (SlotNo 20)]

        it "records malformed metadata as malformed by tx input" $ do
            classifyFeeTx feeAddress (SlotNo 20) malformedMetadataTx
                `shouldBe` [FeeIndexMalformed feeTxIn (SlotNo 20)]

        it "uses distinct tx inputs for multiple matching outputs" $ do
            classifyFeeTx feeAddress (SlotNo 20) multiOutputTaggedTx
                `shouldBe` [ FeeIndexPayment expectedPayment
                           , FeeIndexPayment expectedSecondPayment
                           ]

        it
            "roll-forward writes attributed payments and malformed records"
            $ do
                let finalState =
                        execState
                            ( runFeeIndexerOnce
                                mockStore
                                feeAddress
                                ( FeeIndexerRollForward
                                    FeeIndexerBlock
                                        { fibSlot = SlotNo 20
                                        , fibTransactions =
                                            [ taggedTx
                                            , malformedMetadataTx
                                            ]
                                        }
                                )
                            )
                            emptyMockState
                mockPayments finalState `shouldBe` [expectedPayment]
                mockMalformed finalState
                    `shouldBe` [ MalformedFeePayment
                                    { malformedFeePaymentTxIn = feeTxIn
                                    , malformedFeePaymentBlockSlot = SlotNo 20
                                    }
                               ]

        it "rollback calls both fee-payment rollback operations" $ do
            let finalState =
                    execState
                        ( runFeeIndexerOnce
                            mockStore
                            feeAddress
                            (FeeIndexerRollBackward (SlotNo 33))
                        )
                        emptyMockState
            mockAttributedRollbacks finalState `shouldBe` [SlotNo 33]
            mockMalformedRollbacks finalState `shouldBe` [SlotNo 33]

        it "cold start offers origin when no checkpoint exists"
            $ withSystemTempDirectory "fee-indexer-cold"
            $ \dir -> do
                offeredRef <- newIORef []
                stateRef <- newIORef emptyIOIndexerState
                let runner _ _ _ _ points = do
                        writeIORef offeredRef points
                        pure (Right ())
                runFeeIndexerWith
                    runner
                    emptyExtract
                    (testConfig dir)
                    (testDeps stateRef)
                readIORef offeredRef
                    `shouldReturn` [Network.Point Network.Point.Origin]

        it "warm start offers the persisted checkpoint first"
            $ withSystemTempDirectory "fee-indexer-warm"
            $ \dir -> do
                let checkpoint = headerPointAt 44
                saveFeeIndexerCheckpoint dir checkpoint
                offeredRef <- newIORef []
                stateRef <- newIORef emptyIOIndexerState
                let runner _ _ _ _ points = do
                        writeIORef offeredRef points
                        pure (Right ())
                runFeeIndexerWith
                    runner
                    emptyExtract
                    (testConfig dir)
                    (testDeps stateRef)
                readIORef offeredRef `shouldReturn` [checkpoint]

        it "intersectFound rolls both row families back before following"
            $ withSystemTempDirectory "fee-indexer-intersect"
            $ \dir -> do
                stateRef <- newIORef emptyIOIndexerState
                let runner _ _ _ intersector _ = do
                        _ <- intersectFound intersector (headerPointAt 12)
                        pure (Right ())
                runFeeIndexerWith
                    runner
                    emptyExtract
                    (testConfig dir)
                    (testDeps stateRef)
                state <- readIORef stateRef
                ioAttributedRollbacks state `shouldBe` [SlotNo 12]
                ioMalformedRollbacks state `shouldBe` [SlotNo 12]

        it
            "roll-forward writes payments and malformed rows, checkpoints, and updates the tip"
            $ withSystemTempDirectory "fee-indexer-forward"
            $ \dir -> do
                stateRef <- newIORef emptyIOIndexerState
                let point = headerPointAt 20
                    runner _ _ _ intersector _ = do
                        follower <-
                            intersectFound
                                intersector
                                (Network.Point Network.Point.Origin)
                        _ <-
                            rollForward
                                follower
                                (fetchedAt point 99)
                                (Network.SlotNo 99)
                        pure (Right ())
                runFeeIndexerWith
                    runner
                    (const $ pure indexedBlock)
                    (testConfig dir)
                    (testDeps stateRef)
                state <- readIORef stateRef
                ioPayments state `shouldBe` [expectedPayment]
                ioMalformed state
                    `shouldBe` [ MalformedFeePayment
                                    { malformedFeePaymentTxIn = feeTxIn
                                    , malformedFeePaymentBlockSlot = SlotNo 20
                                    }
                               ]
                ioObservedTips state `shouldBe` [SlotNo 99]
                loadFeeIndexerCheckpoint dir `shouldReturn` Just point

        it
            "roll-backward rolls both rows back and persists a concrete checkpoint"
            $ withSystemTempDirectory "fee-indexer-backward"
            $ \dir -> do
                stateRef <- newIORef emptyIOIndexerState
                let point = headerPointAt 12
                    runner _ _ _ intersector _ = do
                        follower <-
                            intersectFound
                                intersector
                                (Network.Point Network.Point.Origin)
                        writeIORef stateRef emptyIOIndexerState
                        _ <- rollBackward follower point
                        pure (Right ())
                runFeeIndexerWith
                    runner
                    emptyExtract
                    (testConfig dir)
                    (testDeps stateRef)
                state <- readIORef stateRef
                ioAttributedRollbacks state `shouldBe` [SlotNo 12]
                ioMalformedRollbacks state `shouldBe` [SlotNo 12]
                loadFeeIndexerCheckpoint dir `shouldReturn` Just point

        it
            "warm intersectNotFound clears both row families before retrying from origin"
            $ withSystemTempDirectory "fee-indexer-reset"
            $ \dir -> do
                saveFeeIndexerCheckpoint dir (headerPointAt 88)
                retryPointsRef <- newIORef []
                stateRef <- newIORef emptyIOIndexerState
                let runner _ _ _ intersector _ = do
                        (_intersector', retryPoints) <-
                            intersectNotFound intersector
                        writeIORef retryPointsRef retryPoints
                        pure (Right ())
                runFeeIndexerWith
                    runner
                    emptyExtract
                    (testConfig dir)
                    (testDeps stateRef)
                state <- readIORef stateRef
                ioAttributedRollbacks state `shouldBe` [SlotNo 0]
                ioMalformedRollbacks state `shouldBe` [SlotNo 0]
                readIORef retryPointsRef
                    `shouldReturn` [Network.Point Network.Point.Origin]

        it "supervisor retries one synchronous transient failure"
            $ withSystemTempDirectory "fee-indexer-retry"
            $ \dir -> do
                attemptsRef <- newIORef (0 :: Int)
                stateRef <- newIORef emptyIOIndexerState
                let runner _ _ _ _ _ = do
                        modifyIORef' attemptsRef (+ 1)
                        attempts <- readIORef attemptsRef
                        if attempts == 1
                            then throwIO (userError "transient")
                            else pure (Right ())
                runFeeIndexerSupervisorWith
                    runner
                    emptyExtract
                    (testConfig dir)
                    (testDeps stateRef)
                readIORef attemptsRef `shouldReturn` 2

        it "supervisor preserves async cancellation"
            $ withSystemTempDirectory "fee-indexer-cancel"
            $ \dir -> do
                stateRef <- newIORef emptyIOIndexerState
                let runner _ _ _ _ _ = throwIO ThreadKilled
                runFeeIndexerSupervisorWith
                    runner
                    emptyExtract
                    (testConfig dir)
                    (testDeps stateRef)
                    `shouldThrow` (== ThreadKilled)

data MockState = MockState
    { mockPayments :: [FeePayment]
    , mockMalformed :: [MalformedFeePayment]
    , mockAttributedRollbacks :: [SlotNo]
    , mockMalformedRollbacks :: [SlotNo]
    }
    deriving stock (Eq, Show)

data IOIndexerState = IOIndexerState
    { ioPayments :: [FeePayment]
    , ioMalformed :: [MalformedFeePayment]
    , ioAttributedRollbacks :: [SlotNo]
    , ioMalformedRollbacks :: [SlotNo]
    , ioObservedTips :: [SlotNo]
    }
    deriving stock (Eq, Show)

emptyIOIndexerState :: IOIndexerState
emptyIOIndexerState =
    IOIndexerState
        { ioPayments = []
        , ioMalformed = []
        , ioAttributedRollbacks = []
        , ioMalformedRollbacks = []
        , ioObservedTips = []
        }

testDeps :: IORef IOIndexerState -> FeeIndexerDeps IO
testDeps stateRef =
    FeeIndexerDeps
        { fidStore = mockIOStore stateRef
        , fidObserveTip = \slot ->
            modifyIORef'
                stateRef
                (\s -> s{ioObservedTips = ioObservedTips s <> [slot]})
        }

mockIOStore :: IORef IOIndexerState -> Store IO
mockIOStore stateRef =
    StoreWithFilters
        { storePutEntry = \_ -> pure ()
        , storeLookupEntry = \_ -> pure Nothing
        , storeListEntries = pure []
        , storeCollectWitnesses = \_ _ -> pure ()
        , storePutReceipt = \_ _ -> pure ()
        , storeLookupReceipt = \_ -> pure Nothing
        , storePutSignerFilter = \_ _ -> pure ()
        , storeLookupSignerFilter = \_ -> pure Nothing
        , storeUpsertFeePayment = \payment ->
            modifyIORef'
                stateRef
                (\s -> s{ioPayments = ioPayments s <> [payment]})
        , storeRollbackFeePaymentsFrom = \slot ->
            modifyIORef'
                stateRef
                ( \s ->
                    s
                        { ioAttributedRollbacks =
                            ioAttributedRollbacks s <> [slot]
                        }
                )
        , storeAllowanceFor = \_ _ _ -> pure (FeeAllowance 0 0 False)
        , storePutMalformedFeePayment = \payment ->
            modifyIORef'
                stateRef
                (\s -> s{ioMalformed = ioMalformed s <> [payment]})
        , storeMalformedFeePayment = \txIn ->
            lookup txIn
                . fmap
                    ( \payment ->
                        (malformedFeePaymentTxIn payment, payment)
                    )
                . ioMalformed
                <$> readIORef stateRef
        , storeRollbackMalformedFeePaymentsFrom = \slot ->
            modifyIORef'
                stateRef
                ( \s ->
                    s
                        { ioMalformedRollbacks =
                            ioMalformedRollbacks s <> [slot]
                        }
                )
        }

testConfig :: FilePath -> FeeIndexerConfig
testConfig dir =
    FeeIndexerConfig
        { ficSocketPath = "node.socket"
        , ficNetworkMagic = 42
        , ficByronEpochSlots = 21_600
        , ficFeeAddress = feeAddress
        , ficCheckpointDir = dir
        , ficRetryDelayMicros = 0
        }

emptyExtract :: fetched -> IO FeeIndexerBlock
emptyExtract _ =
    pure FeeIndexerBlock{fibSlot = SlotNo 0, fibTransactions = []}

indexedBlock :: FeeIndexerBlock
indexedBlock =
    FeeIndexerBlock
        { fibSlot = SlotNo 20
        , fibTransactions = [taggedTx, malformedMetadataTx]
        }

fetchedAt :: HeaderPoint -> Word64 -> Fetched
fetchedAt point tip =
    Fetched
        { fetchedPoint = point
        , fetchedBlock = unsafeCoerce ()
        , fetchedTip = Network.SlotNo tip
        }

headerPointAt :: Word64 -> HeaderPoint
headerPointAt slot =
    Network.BlockPoint
        (Network.SlotNo slot)
        (OneEraHash (SBS.toShort (BS.replicate 32 (fromIntegral slot))))

emptyMockState :: MockState
emptyMockState =
    MockState
        { mockPayments = []
        , mockMalformed = []
        , mockAttributedRollbacks = []
        , mockMalformedRollbacks = []
        }

mockStore :: Store (State MockState)
mockStore =
    StoreWithFilters
        { storePutEntry = \_ -> pure ()
        , storeLookupEntry = \_ -> pure Nothing
        , storeListEntries = pure []
        , storeCollectWitnesses = \_ _ -> pure ()
        , storePutReceipt = \_ _ -> pure ()
        , storeLookupReceipt = \_ -> pure Nothing
        , storePutSignerFilter = \_ _ -> pure ()
        , storeLookupSignerFilter = \_ -> pure Nothing
        , storeUpsertFeePayment = \payment ->
            modify'
                ( \s ->
                    s{mockPayments = mockPayments s <> [payment]}
                )
        , storeRollbackFeePaymentsFrom = \slot ->
            modify'
                ( \s ->
                    s
                        { mockAttributedRollbacks =
                            mockAttributedRollbacks s <> [slot]
                        }
                )
        , storeAllowanceFor = \_ _ _ -> pure (FeeAllowance 0 0 False)
        , storePutMalformedFeePayment = \payment ->
            modify'
                ( \s ->
                    s{mockMalformed = mockMalformed s <> [payment]}
                )
        , storeMalformedFeePayment = \txIn ->
            gets
                ( \s ->
                    lookup
                        txIn
                        [ (malformedFeePaymentTxIn payment, payment)
                        | payment <- mockMalformed s
                        ]
                )
        , storeRollbackMalformedFeePaymentsFrom = \slot ->
            modify'
                ( \s ->
                    s
                        { mockMalformedRollbacks =
                            mockMalformedRollbacks s <> [slot]
                        }
                )
        }

taggedTx :: FeeIndexerTx
taggedTx =
    FeeIndexerTx
        { fitMetadata = encodeFeeTag bodyHash
        , fitOutputs =
            [ FeeIndexerOutput
                { fioTxIn = feeTxIn
                , fioAddress = feeAddress
                , fioLovelace = 1_500
                }
            ]
        }

taggedWrongAddressTx :: FeeIndexerTx
taggedWrongAddressTx =
    taggedTx
        { fitOutputs =
            [ FeeIndexerOutput
                { fioTxIn = feeTxIn
                , fioAddress = otherAddress
                , fioLovelace = 1_500
                }
            ]
        }

missingMetadataTx :: FeeIndexerTx
missingMetadataTx =
    taggedTx{fitMetadata = mempty}

malformedMetadataTx :: FeeIndexerTx
malformedMetadataTx =
    taggedTx{fitMetadata = malformedMetadata}

multiOutputTaggedTx :: FeeIndexerTx
multiOutputTaggedTx =
    taggedTx
        { fitOutputs =
            [ FeeIndexerOutput
                { fioTxIn = feeTxIn
                , fioAddress = feeAddress
                , fioLovelace = 1_500
                }
            , FeeIndexerOutput
                { fioTxIn = secondFeeTxIn
                , fioAddress = feeAddress
                , fioLovelace = 2_000
                }
            ]
        }

expectedPayment :: FeePayment
expectedPayment =
    FeePayment
        { feePaymentBodyHash = bodyHash
        , feePaymentTxIn = feeTxIn
        , feePaymentLovelace = 1_500
        , feePaymentBlockSlot = SlotNo 20
        }

expectedSecondPayment :: FeePayment
expectedSecondPayment =
    expectedPayment
        { feePaymentTxIn = secondFeeTxIn
        , feePaymentLovelace = 2_000
        }

malformedMetadata :: Map Word64 Metadatum
malformedMetadata =
    Map.singleton
        feeTagLabel
        (Map [(S feeTagBodyHashKey, I 0)])

bodyHash :: EntryId
bodyHash =
    EntryId (TxId $ unsafeMakeSafeHash $ mkHash32 42)

feeTxIn :: TxIn
feeTxIn =
    mkTxIn 8 0

secondFeeTxIn :: TxIn
secondFeeTxIn =
    mkTxIn 8 1

feeAddress :: Addr
feeAddress =
    testAddress 9

otherAddress :: Addr
otherAddress =
    testAddress 10

testAddress :: Word8 -> Addr
testAddress n =
    Addr
        Testnet
        (KeyHashObj (paymentHash n))
        StakeRefNull

paymentHash :: Word8 -> KeyHash Payment
paymentHash n =
    hashKey (VKey (deriveVerKeyDSIGN (testKey n)))

testKey :: Word8 -> SignKeyDSIGN Ed25519DSIGN
testKey n =
    genKeyDSIGN (mkSeedFromBytes (BS.replicate 32 n))

mkTxIn :: Word8 -> Word16 -> TxIn
mkTxIn n ix =
    TxIn
        (TxId $ unsafeMakeSafeHash $ mkHash32 n)
        (TxIx ix)

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    case hashFromBytes (BS.pack (replicate 31 0 ++ [n])) of
        Just h -> h
        Nothing -> error "mkHash32: invalid hash length"
