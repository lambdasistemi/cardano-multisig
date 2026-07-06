{-# LANGUAGE DataKinds #-}

module Cardano.Multisig.LivenessSpec
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
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , mkBasicTx
    )
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mkBasicTxBody
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.BaseTypes
    ( StrictMaybe (SJust)
    , TxIx (..)
    )
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Keys
    ( KeyHash
    , KeyRole (Guard)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.Liveness
    ( EntryLiveness (..)
    , LivenessDeps (..)
    , entryLiveness
    , runLivenessTick
    )
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryId
    , EntryStatus (..)
    , FeeAllowance (..)
    , Store (..)
    , entryIdFromTx
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Monad.State.Strict
    ( StateT
    , evalStateT
    , gets
    , modify'
    )
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word8)
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

spec :: Spec
spec =
    describe "Cardano.Multisig.Liveness" $ do
        it "liveness tick persists a live entry as expired past the tip" $ do
            let entry = testEntry EntryCollecting (SlotNo 99) [mkTxIn 1]
            entries <-
                runMock (mockState (SlotNo 100) [entry]) $ do
                    runLivenessTick mockLivenessDeps
                    gets msEntries
            Map.lookup (entryId entry) entries
                `shouldBe` Just entry{entryStatus = EntryExpired}

        it "liveness reports a live entry with any spent input as stale" $ do
            let spent = mkTxIn 2
                entry =
                    testEntry EntryReady (SlotNo 120) [mkTxIn 1, spent]
                state =
                    (mockState (SlotNo 100) [entry])
                        { msUnspent = Set.singleton (mkTxIn 1)
                        }
            result <- runMock state (entryLiveness mockLivenessDeps entry)
            result
                `shouldBe` EntryLiveness
                    { elInputsUnspent = False
                    , elPhase1Ok = True
                    }

        it "liveness leaves a healthy live entry untouched" $ do
            let entry = testEntry EntryCollecting (SlotNo 120) [mkTxIn 1]
            (result, entries) <-
                runMock (mockState (SlotNo 100) [entry]) $ do
                    liveness <- entryLiveness mockLivenessDeps entry
                    runLivenessTick mockLivenessDeps
                    stored <- gets msEntries
                    pure (liveness, stored)
            result
                `shouldBe` EntryLiveness
                    { elInputsUnspent = True
                    , elPhase1Ok = True
                    }
            Map.lookup (entryId entry) entries `shouldBe` Just entry

data MockState = MockState
    { msTip :: SlotNo
    , msEntries :: Map EntryId Entry
    , msUnspent :: Set TxIn
    , msPhase1Ok :: Bool
    }

mockState :: SlotNo -> [Entry] -> MockState
mockState tip entries =
    MockState
        { msTip = tip
        , msEntries = Map.fromList [(entryId entry, entry) | entry <- entries]
        , msUnspent = Set.fromList (concatMap entryInputs entries)
        , msPhase1Ok = True
        }

mockLivenessDeps :: LivenessDeps (StateT MockState IO)
mockLivenessDeps =
    LivenessDeps
        { ldReadTip = gets msTip
        , ldInputUnspent = \txIn -> gets (Set.member txIn . msUnspent)
        , ldPhase1Ok = \_ -> gets msPhase1Ok
        , ldStore =
            StoreWithFilters
                { storePutEntry = \entry ->
                    modify'
                        ( \state ->
                            state
                                { msEntries =
                                    Map.insert
                                        (entryId entry)
                                        entry
                                        (msEntries state)
                                }
                        )
                , storeLookupEntry = \entryId ->
                    gets (Map.lookup entryId . msEntries)
                , storeListEntries = gets (Map.elems . msEntries)
                , storeCollectWitnesses = \_ _ -> pure ()
                , storePutReceipt = \_ _ -> pure ()
                , storeLookupReceipt = \_ -> pure Nothing
                , storePutSignerFilter = \_ _ -> pure ()
                , storeLookupSignerFilter = \_ -> pure Nothing
                , storeUpsertFeePayment = \_ -> pure ()
                , storeRollbackFeePaymentsFrom = \_ -> pure ()
                , storeAllowanceFor = \_ _ depth ->
                    pure (FeeAllowance 0 depth False)
                , storePutMalformedFeePayment = \_ -> pure ()
                , storeMalformedFeePayment = \_ -> pure Nothing
                , storeRollbackMalformedFeePaymentsFrom = \_ -> pure ()
                }
        }

runMock :: MockState -> StateT MockState IO a -> IO a
runMock = flip evalStateT

testEntry :: EntryStatus -> SlotNo -> [TxIn] -> Entry
testEntry status invalidHereafter inputs =
    Entry
        { entryId = entryIdFromTx tx
        , entryTx = tx
        , entryRequiredSigners = requiredSigners
        , entryCollectedWitnesses = mempty
        , entryInvalidHereafter = invalidHereafter
        , entryFeePayment = mkTxIn 9
        , entryStatus = status
        }
  where
    tx = testTx invalidHereafter inputs

testTx :: SlotNo -> [TxIn] -> ConwayTx
testTx invalidHereafter inputs =
    (mkBasicTx mkBasicTxBody :: ConwayTx)
        & bodyTxL . inputsTxBodyL .~ Set.fromList inputs
        & bodyTxL . reqSignerHashesTxBodyL .~ requiredSigners
        & bodyTxL . vldtTxBodyL
            .~ ValidityInterval (SJust (SlotNo 10)) (SJust invalidHereafter)

entryInputs :: Entry -> [TxIn]
entryInputs entry =
    Set.toList $ entryTx entry ^. bodyTxL . inputsTxBodyL

requiredSigners :: Set (KeyHash Guard)
requiredSigners =
    Set.singleton (signerHash 1)

signerHash :: Word -> KeyHash Guard
signerHash n =
    hashKey (VKey (deriveVerKeyDSIGN (testKey n)))

testKey :: Word -> SignKeyDSIGN Ed25519DSIGN
testKey n =
    genKeyDSIGN (mkSeedFromBytes (BS.replicate 32 (fromIntegral n)))

mkTxIn :: Word8 -> TxIn
mkTxIn n =
    TxIn
        (TxId $ unsafeMakeSafeHash $ mkHash32 n)
        (TxIx (fromIntegral n))

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    case hashFromBytes (BS.pack (replicate 31 0 ++ [n])) of
        Just h -> h
        Nothing -> error "mkHash32: invalid hash length"
