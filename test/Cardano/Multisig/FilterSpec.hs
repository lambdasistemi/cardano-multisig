{-# LANGUAGE DataKinds #-}

module Cardano.Multisig.FilterSpec
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
    , reqSignerHashesTxBodyL
    )
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody, vldtTxBodyL)
import Cardano.Ledger.BaseTypes
    ( StrictMaybe (SJust, SNothing)
    , TxIx (..)
    )
import Cardano.Ledger.Hashes
    ( extractHash
    , hashAnnotated
    , unsafeMakeSafeHash
    )
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
import Cardano.Multisig.Filter
    ( FilterPolicy (RosterOpen, TrustOrdered)
    , filterEntries
    )
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryStatus (EntryCollecting)
    , entryIdFromTx
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Data.Word (Word8)
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "filter policy logic" $ do
        it
            "filter trust-ordered hides roster entries without a trusted witness"
            $ do
                let entry = testEntry [1, 2] []
                filterEntries
                    (TrustOrdered (Set.singleton (signerHash 2)))
                    (signerHash 1)
                    [entry]
                    `shouldBe` []

        it
            "filter trust-ordered returns roster entries with a trusted witness"
            $ do
                let entry = testEntry [1, 2] [2]
                filterEntries
                    (TrustOrdered (Set.singleton (signerHash 2)))
                    (signerHash 1)
                    [entry]
                    `shouldBe` [entry]

        it
            "filter roster-open returns zero-witness entries for roster signers"
            $ do
                let entry = testEntry [1, 2] []
                filterEntries RosterOpen (signerHash 1) [entry]
                    `shouldBe` [entry]

        it "filter does not return entries to non-roster signers" $ do
            let entry = testEntry [1, 2] [2]
            filterEntries RosterOpen (signerHash 3) [entry]
                `shouldBe` []
            filterEntries
                (TrustOrdered (Set.singleton (signerHash 2)))
                (signerHash 3)
                [entry]
                `shouldBe` []

testEntry :: [Word] -> [Word] -> Entry
testEntry required collected =
    Entry
        { entryId = entryIdFromTx testTx
        , entryTx = testTx
        , entryRequiredSigners = Set.fromList (signerHash <$> required)
        , entryCollectedWitnesses =
            mempty
                & addrTxWitsL
                    .~ Set.fromList (testWitness <$> collected)
        , entryInvalidHereafter = SlotNo 120
        , entryFeePayment = mkTxIn 9
        , entryStatus = EntryCollecting
        }

testTx :: ConwayTx
testTx =
    (mkBasicTx mkBasicTxBody :: ConwayTx)
        & bodyTxL . reqSignerHashesTxBodyL
            .~ Set.fromList [signerHash 1, signerHash 2]
        & bodyTxL . vldtTxBodyL
            .~ ValidityInterval SNothing (SJust (SlotNo 120))

testWitness :: Word -> WitVKey Witness
testWitness n =
    WitVKey (asWitness vk) (signedDSIGN sk bodyHash)
  where
    sk = testKey n
    vk = VKey (deriveVerKeyDSIGN sk)
    bodyHash = extractHash (hashAnnotated (testTx ^. bodyTxL))

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
