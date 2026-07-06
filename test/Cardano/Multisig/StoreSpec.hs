{-# LANGUAGE DataKinds #-}

module Cardano.Multisig.StoreSpec
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
    ( addrTxWitsL
    , bodyTxL
    , mkBasicTx
    , txIdTx
    )
import Cardano.Ledger.Api.Tx.Body
    ( mkBasicTxBody
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.BaseTypes
    ( StrictMaybe (SJust, SNothing)
    , TxIx (..)
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (TxWits, extractHash)
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Keys
    ( KeyHash
    , KeyRole (Guard, Witness)
    , VKey (..)
    , WitVKey (..)
    , asWitness
    , hashKey
    , signedDSIGN
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryId (..)
    , EntryStatus (..)
    , FeeAllowance (..)
    , FeePayment (..)
    , Receipt (..)
    , Store (..)
    , entryIdFromTx
    )
import Cardano.Multisig.Store.RocksDB (withRocksDBStore)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent.Async (mapConcurrently_)
import Data.ByteString qualified as BS
import Data.Foldable (fold)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Word (Word64, Word8)
import Lens.Micro ((%~), (&), (.~))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)

spec :: Spec
spec =
    describe "Cardano.Multisig.Store.RocksDB" $ do
        it "round-trips an entry through the public Store interface"
            $ withSystemTempDirectory "cardano-multisig-store"
            $ \dir ->
                withRocksDBStore dir $ \store -> do
                    let entry = testEntry
                        receipt = testReceipt entry
                    storePutEntry store entry
                    storePutReceipt store (entryId entry) receipt
                    storeLookupEntry store (entryId entry)
                        `shouldReturnEntry` Just entry
                    storeLookupReceipt store (entryId entry)
                        `shouldReturnReceipt` Just receipt

        it "persists entries across close and reopen"
            $ withSystemTempDirectory "cardano-multisig-store"
            $ \dir -> do
                let entry = testEntry{entryStatus = EntryReady}
                withRocksDBStore dir $ \store ->
                    storePutEntry store entry
                withRocksDBStore dir $ \store ->
                    storeLookupEntry store (entryId entry)
                        `shouldReturnEntry` Just entry

        it "persists signer filter policies across close and reopen"
            $ withSystemTempDirectory "cardano-multisig-store"
            $ \dir -> do
                let signer = signerHash 1
                    policyBytes =
                        "cardano-multisig-filter-v1\npredicate=roster-open\n"
                withRocksDBStore dir $ \store ->
                    storePutSignerFilter store signer policyBytes
                withRocksDBStore dir $ \store ->
                    storeLookupSignerFilter store signer
                        `shouldReturn` Just policyBytes

        it
            "serializes concurrent witness writes and preserves distinct witnesses"
            $ withSystemTempDirectory "cardano-multisig-store"
            $ \dir ->
                withRocksDBStore dir $ \store -> do
                    let entry = testEntry
                        witnesses = [witnessSet 1, witnessSet 2, witnessSet 3]
                    storePutEntry store entry
                    mapConcurrently_
                        (storeCollectWitnesses store (entryId entry))
                        witnesses
                    stored <- storeLookupEntry store (entryId entry)
                    fmap entryCollectedWitnesses stored
                        `shouldBe` Just (fold witnesses)

        it "sums multiple final fee payments for the same body hash"
            $ withStore
            $ \store -> do
                let bodyHash = bodyHashN 1
                    otherBodyHash = bodyHashN 2
                storeUpsertFeePayment store
                    $ testFeePayment bodyHash 1 1_000 10
                storeUpsertFeePayment store
                    $ testFeePayment bodyHash 2 2_500 11
                storeUpsertFeePayment store
                    $ testFeePayment otherBodyHash 3 9_999 10
                storeAllowanceFor store bodyHash (SlotNo 20) 5
                    `shouldReturn` FeeAllowance 3_500 5 False

        it "does not double count reinserting the same fee payment"
            $ withStore
            $ \store -> do
                let bodyHash = bodyHashN 1
                    payment = testFeePayment bodyHash 1 1_000 10
                storeUpsertFeePayment store payment
                storeUpsertFeePayment store payment
                storeAllowanceFor store bodyHash (SlotNo 20) 5
                    `shouldReturn` FeeAllowance 1_000 5 False

        it "rolls back fee payments after the rollback slot exactly"
            $ withStore
            $ \store -> do
                let bodyHash = bodyHashN 1
                    otherBodyHash = bodyHashN 2
                storeUpsertFeePayment store
                    $ testFeePayment bodyHash 1 1_000 10
                storeUpsertFeePayment store
                    $ testFeePayment bodyHash 2 2_000 11
                storeUpsertFeePayment store
                    $ testFeePayment bodyHash 3 4_000 12
                storeUpsertFeePayment store
                    $ testFeePayment otherBodyHash 4 8_000 12
                storeRollbackFeePaymentsFrom store (SlotNo 11)
                storeAllowanceFor store bodyHash (SlotNo 20) 1
                    `shouldReturn` FeeAllowance 3_000 1 False
                storeAllowanceFor store otherBodyHash (SlotNo 20) 1
                    `shouldReturn` FeeAllowance 0 1 False

        it "counts only fee payments final at the requested depth"
            $ withStore
            $ \store -> do
                let bodyHash = bodyHashN 1
                storeUpsertFeePayment store
                    $ testFeePayment bodyHash 1 1_000 10
                storeUpsertFeePayment store
                    $ testFeePayment bodyHash 2 2_000 16
                storeAllowanceFor store bodyHash (SlotNo 20) 5
                    `shouldReturn` FeeAllowance 1_000 5 True

        it "reports pending fee payments without counting them"
            $ withStore
            $ \store -> do
                let bodyHash = bodyHashN 1
                storeUpsertFeePayment store
                    $ testFeePayment bodyHash 1 1_000 10
                storeAllowanceFor store bodyHash (SlotNo 12) 5
                    `shouldReturn` FeeAllowance 0 5 True

withStore :: (Store IO -> IO a) -> IO a
withStore action =
    withSystemTempDirectory "cardano-multisig-store" $ \dir ->
        withRocksDBStore dir action

shouldReturnEntry :: IO (Maybe Entry) -> Maybe Entry -> IO ()
shouldReturnEntry action expected = do
    actual <- action
    actual `shouldBe` expected

shouldReturnReceipt :: IO (Maybe Receipt) -> Maybe Receipt -> IO ()
shouldReturnReceipt action expected = do
    actual <- action
    actual `shouldBe` expected

testEntry :: Entry
testEntry =
    Entry
        { entryId = entryIdFromTx tx
        , entryTx = tx
        , entryRequiredSigners = requiredSigners
        , entryCollectedWitnesses = mempty
        , entryInvalidHereafter = SlotNo 120
        , entryFeePayment = mkTxIn 9
        , entryStatus = EntryCollecting
        }
  where
    tx =
        (mkBasicTx mkBasicTxBody :: ConwayTx)
            & bodyTxL . reqSignerHashesTxBodyL .~ requiredSigners
            & bodyTxL . vldtTxBodyL
                .~ ValidityInterval SNothing (SJust (SlotNo 120))

testReceipt :: Entry -> Receipt
testReceipt entry =
    Receipt
        { receiptTxId = entryId entry
        , receiptSubmittedAt = posixSecondsToUTCTime 1_700_000_000
        }

requiredSigners :: Set (KeyHash Guard)
requiredSigners =
    Set.fromList [signerHash 1, signerHash 2]

signerHash :: Word -> KeyHash Guard
signerHash n =
    hashKey (VKey (deriveVerKeyDSIGN (testKey n)))

witnessSet :: Word -> TxWits ConwayEra
witnessSet n =
    mempty & addrTxWitsL %~ Set.insert (testWitness n)

testWitness :: Word -> WitVKey Witness
testWitness n =
    case txIdTx tx of
        TxId h -> WitVKey (asWitness vk) (signedDSIGN sk (extractHash h))
  where
    sk = testKey n
    vk = VKey (deriveVerKeyDSIGN sk)
    tx = mkBasicTx mkBasicTxBody :: ConwayTx

testKey :: Word -> SignKeyDSIGN Ed25519DSIGN
testKey n =
    genKeyDSIGN (mkSeedFromBytes (BS.replicate 32 (fromIntegral n)))

mkTxIn :: Word -> TxIn
mkTxIn n =
    TxIn
        (TxId $ unsafeMakeSafeHash $ mkHash32 (fromIntegral n))
        (TxIx (fromIntegral n))

bodyHashN :: Word8 -> EntryId
bodyHashN n =
    EntryId (TxId $ unsafeMakeSafeHash $ mkHash32 n)

testFeePayment
    :: EntryId
    -> Word
    -> Word64
    -> Word64
    -> FeePayment
testFeePayment bodyHash txIn lovelace slot =
    FeePayment
        { feePaymentBodyHash = bodyHash
        , feePaymentTxIn = mkTxIn txIn
        , feePaymentLovelace = lovelace
        , feePaymentBlockSlot = SlotNo slot
        }

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    case hashFromBytes (BS.pack (replicate 31 0 ++ [n])) of
        Just h -> h
        Nothing -> error "mkHash32: invalid hash length"
