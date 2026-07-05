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
    , EntryStatus (..)
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
import Data.Word (Word8)
import Lens.Micro ((%~), (&), (.~))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe)

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

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    case hashFromBytes (BS.pack (replicate 31 0 ++ [n])) of
        Just h -> h
        Nothing -> error "mkHash32: invalid hash length"
