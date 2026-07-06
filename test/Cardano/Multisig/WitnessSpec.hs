{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.WitnessSpec
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
import Cardano.Ledger.Api.Era (eraProtVerLow)
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
import Cardano.Ledger.Binary
    ( EncCBOR (..)
    , encodeListLen
    , encodeWord
    , serialize'
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (witsTxL)
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
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryStatus (EntryCollecting, EntryReady)
    , entryIdFromTx
    )
import Cardano.Multisig.Witness
    ( WitnessFailure (..)
    , assembleEntryTx
    , decodeVKeyWitnessHex
    , entryMissingSigners
    , entryWitnessStatus
    , entryWitnesses
    , verifyEntryWitness
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word8)
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "Cardano.Multisig.Witness" $ do
        it "decodes bare and cardano-cli envelope vkey witnesses" $ do
            let witness = testWitness 1 testTx
            decodeVKeyWitnessHex (bareWitnessHex witness)
                `shouldBe` Right witness
            decodeVKeyWitnessHex (envelopedWitnessHex witness)
                `shouldBe` Right witness

        it "rejects an invalid signature" $ do
            let entry = testEntry [1] mempty
            verifyEntryWitness entry (testWitness 1 otherTx)
                `shouldBe` Left WitnessInvalidSignature

        it "rejects a witness whose key hash is not required" $ do
            let entry = testEntry [1] mempty
                signer = signerHash 2
            verifyEntryWitness entry (testWitness 2 testTx)
                `shouldBe` Left (WitnessSignerNotRequired signer)

        it "rejects a duplicate witness already collected on the entry" $ do
            let witness = testWitness 1 testTx
                entry = testEntry [1] (witnessSet witness)
            verifyEntryWitness entry witness
                `shouldBe` Left (WitnessAlreadyCollected (signerHash 1))

        it "stores a valid witness and tracks missing signers" $ do
            let witness = testWitness 1 testTx
                entry = testEntry [1, 2] mempty
                accepted = verifyEntryWitness entry witness
            fmap entryWitnesses accepted
                `shouldBe` Right (Set.singleton (signerHash 1))
            fmap entryMissingSigners accepted
                `shouldBe` Right (Set.singleton (signerHash 2))
            fmap entryWitnessStatus accepted
                `shouldBe` Right EntryCollecting

        it "reports ready when the full signer roster is collected" $ do
            let firstWitness = testWitness 1 testTx
                secondWitness = testWitness 2 testTx
                entry = testEntry [1, 2] (witnessSet firstWitness)
            fmap entryWitnessStatus (verifyEntryWitness entry secondWitness)
                `shouldBe` Right EntryReady

        it "assembles the entry transaction with collected witnesses" $ do
            let witness = testWitness 1 testTx
                entry = testEntry [1] (witnessSet witness)
                assembled = assembleEntryTx entry
            hashAnnotated (assembled ^. bodyTxL)
                `shouldBe` hashAnnotated (entryTx entry ^. bodyTxL)
            assembled ^. witsTxL . addrTxWitsL
                `shouldBe` Set.singleton witness

testEntry :: [Word] -> Set (WitVKey Witness) -> Entry
testEntry required collected =
    Entry
        { entryId = entryIdFromTx testTx
        , entryTx = testTx
        , entryRequiredSigners = Set.fromList (signerHash <$> required)
        , entryCollectedWitnesses = mempty & addrTxWitsL .~ collected
        , entryInvalidHereafter = SlotNo 120
        , entryFeePayment = mkTxIn 9
        , entryStatus = EntryCollecting
        }

testTx :: ConwayTx
testTx =
    txWithSigners [1, 2]

otherTx :: ConwayTx
otherTx =
    txWithSigners [1]
        & bodyTxL . vldtTxBodyL
            .~ ValidityInterval SNothing (SJust (SlotNo 121))

txWithSigners :: [Word] -> ConwayTx
txWithSigners signers =
    (mkBasicTx mkBasicTxBody :: ConwayTx)
        & bodyTxL . reqSignerHashesTxBodyL
            .~ Set.fromList (signerHash <$> signers)
        & bodyTxL . vldtTxBodyL
            .~ ValidityInterval SNothing (SJust (SlotNo 120))

testWitness :: Word -> ConwayTx -> WitVKey Witness
testWitness n tx =
    WitVKey (asWitness vk) (signedDSIGN sk bodyHash)
  where
    sk = testKey n
    vk = VKey (deriveVerKeyDSIGN sk)
    bodyHash = extractHash (hashAnnotated (tx ^. bodyTxL))

witnessSet :: WitVKey Witness -> Set (WitVKey Witness)
witnessSet =
    Set.singleton

bareWitnessHex :: WitVKey Witness -> BS.ByteString
bareWitnessHex =
    Base16.encode . serialize' (eraProtVerLow @ConwayEra)

envelopedWitnessHex :: WitVKey Witness -> BS.ByteString
envelopedWitnessHex witness =
    Base16.encode
        $ serialize' (eraProtVerLow @ConwayEra) (KeyWitnessEnvelope witness)

newtype KeyWitnessEnvelope = KeyWitnessEnvelope (WitVKey Witness)

instance EncCBOR KeyWitnessEnvelope where
    encCBOR (KeyWitnessEnvelope witness) =
        encodeListLen 2
            <> encodeWord 0
            <> encCBOR witness

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
