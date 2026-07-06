{-# LANGUAGE DataKinds #-}

module Cardano.Multisig.PublishSpec
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
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Scripts.Data (Datum)
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , mkBasicTx
    )
import Cardano.Ledger.Api.Tx.Body
    ( mkBasicTxBody
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (SJust, SNothing)
    , TxIx (..)
    )
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Credential
    ( Credential (KeyHashObj)
    , StakeReference (StakeRefNull)
    )
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Keys
    ( KeyHash
    , KeyRole (Guard, Payment)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.Chain
    ( PaymentConfirmation (..)
    , PaymentConfirmationEvidence (..)
    , PaymentReadResult (..)
    )
import Cardano.Multisig.Publish
    ( FeeQuote (..)
    , OperatorSchedule (..)
    , PreflightResult (..)
    , PublishDeps (..)
    , PublishFailure (..)
    , PublishRequest (..)
    , bodyHashTagDatum
    , publishEntry
    , quoteTx
    )
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryId
    , EntryStatus (..)
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
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word8)
import Lens.Micro ((&), (.~))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

spec :: Spec
spec =
    describe "Cardano.Multisig.Publish" $ do
        describe "quoteTx"
            $ it "computes a body-hash-tagged fee quote from bounded tx TTL"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                    quote = quoteTx schedule (SlotNo 100) (txHex tx)
                fmap qBodyHash quote `shouldBe` Right (entryIdFromTx tx)
                fmap qInvalidHereafter quote `shouldBe` Right (SlotNo 125)
                fmap qRequiredFeeLovelace quote `shouldBe` Right 1_250

        it "maps insufficient fee to a typed 402 publish failure" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                deps =
                    happyDeps
                        { mdPayment =
                            payment tx 1_249 (bodyHashTagDatum (entryIdFromTx tx))
                        }
            result <-
                runMock
                    deps
                    ( publishEntry
                        schedule
                        (mockPublishDeps tx)
                        request{prTxCborHex = txHex tx}
                    )
            result
                `shouldBe` Left
                    PublishFeeInsufficient
                        { pfRequiredLovelace = 1_250
                        , pfPaidLovelace = 1_249
                        }

        it "maps unbounded TTL to a typed 422 publish failure" $ do
            let tx = testTx SNothing requiredSigners
            result <-
                runMock
                    happyDeps
                    ( publishEntry
                        schedule
                        (mockPublishDeps tx)
                        request{prTxCborHex = txHex tx}
                    )
            result `shouldBe` Left PublishTtlUnbounded

        it "maps over-horizon TTL to a typed 422 publish failure" $ do
            let tx = testTx (SJust (SlotNo 151)) requiredSigners
                deps =
                    happyDeps
                        { mdPayment =
                            payment tx 1_510 (bodyHashTagDatum (entryIdFromTx tx))
                        }
            result <-
                runMock
                    deps
                    ( publishEntry
                        schedule
                        (mockPublishDeps tx)
                        request{prTxCborHex = txHex tx}
                    )
            result
                `shouldBe` Left
                    PublishTtlOverHorizon
                        { pfInvalidHereafter = SlotNo 151
                        , pfHorizon = SlotNo 150
                        }

        it "maps phase-1 preflight failure to a typed 422 publish failure" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                deps = happyDeps{mdPreflight = PreflightRejected "missing input"}
            result <-
                runMock
                    deps
                    ( publishEntry
                        schedule
                        (mockPublishDeps tx)
                        request{prTxCborHex = txHex tx}
                    )
            result `shouldBe` Left (PublishPreflightFailed "missing input")

        it "maps duplicate entry ids to a typed 409 publish failure" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                duplicate = storedEntry tx
                deps =
                    happyDeps
                        { mdEntries = Map.singleton (entryIdFromTx tx) duplicate
                        }
            result <-
                runMock
                    deps
                    ( publishEntry
                        schedule
                        (mockPublishDeps tx)
                        request{prTxCborHex = txHex tx}
                    )
            result `shouldBe` Left (PublishDuplicate (entryIdFromTx tx))

        it
            "persists an E3 collecting entry without requiring a publisher witness"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                stored <-
                    runMock happyDeps $ do
                        result <-
                            publishEntry
                                schedule
                                (mockPublishDeps tx)
                                request{prTxCborHex = txHex tx}
                        entries <- gets mdEntries
                        pure (result, Map.lookup (entryIdFromTx tx) entries)
                let expected = storedEntry tx
                stored `shouldBe` (Right expected, Just expected)

schedule :: OperatorSchedule
schedule =
    OperatorSchedule
        { osNetwork = Testnet
        , osFeeAddress = testAddr
        , osBaseLovelace = 1_000
        , osRateLovelacePerSlot = 10
        , osTtlHorizonSlots = 50
        }

request :: PublishRequest
request =
    PublishRequest
        { prTxCborHex = ""
        , prFeePayment = mkTxIn 9
        }

data MockDeps = MockDeps
    { mdTip :: SlotNo
    , mdPayment :: PaymentConfirmation
    , mdPreflight :: PreflightResult
    , mdEntries :: Map EntryId Entry
    }

happyDeps :: MockDeps
happyDeps =
    let tx = testTx (SJust (SlotNo 125)) requiredSigners
    in  MockDeps
            { mdTip = SlotNo 100
            , mdPayment =
                payment tx 1_250 (bodyHashTagDatum (entryIdFromTx tx))
            , mdPreflight = PreflightAccepted
            , mdEntries = mempty
            }

mockPublishDeps :: ConwayTx -> PublishDeps (StateT MockDeps IO)
mockPublishDeps _tx =
    PublishDeps
        { pdReadTip = gets mdTip
        , pdReadPayment = \_ -> PaymentReadResolved <$> gets mdPayment
        , pdPreflight = \_ -> gets mdPreflight
        , pdStore =
            Store
                { storePutEntry = \entry ->
                    modify'
                        ( \s ->
                            s
                                { mdEntries =
                                    Map.insert
                                        (entryId entry)
                                        entry
                                        (mdEntries s)
                                }
                        )
                , storeLookupEntry = \entryId ->
                    gets (Map.lookup entryId . mdEntries)
                , storeCollectWitnesses = \_ _ -> pure ()
                , storePutReceipt = \_ _ -> pure ()
                , storeLookupReceipt = \_ -> pure Nothing
                }
        }

runMock :: MockDeps -> StateT MockDeps IO a -> IO a
runMock = flip evalStateT

storedEntry :: ConwayTx -> Entry
storedEntry tx =
    Entry
        { entryId = entryIdFromTx tx
        , entryTx = tx
        , entryRequiredSigners = requiredSigners
        , entryCollectedWitnesses = mempty
        , entryInvalidHereafter = SlotNo 125
        , entryFeePayment = mkTxIn 9
        , entryStatus = EntryCollecting
        }

payment
    :: ConwayTx -> Integer -> Datum ConwayEra -> PaymentConfirmation
payment tx lovelace datum =
    PaymentConfirmation
        { pcRequestedTxIn = mkTxIn 9
        , pcValue = MaryValue (Coin lovelace) (MultiAsset mempty)
        , pcAddress = testAddr
        , pcDatum = datum
        , pcEvidence =
            PaymentConfirmationEvidence
                { pceLedgerTipSlot = SlotNo 100
                , pceExactDepth = Nothing
                }
        }
  where
    _ = tx

testTx
    :: StrictMaybe SlotNo
    -> Set (KeyHash Guard)
    -> ConwayTx
testTx invalidHereafter signers =
    (mkBasicTx mkBasicTxBody :: ConwayTx)
        & bodyTxL . reqSignerHashesTxBodyL .~ signers
        & bodyTxL . vldtTxBodyL
            .~ ValidityInterval SNothing invalidHereafter

txHex :: ConwayTx -> ByteString
txHex =
    Base16.encode
        . serialize' (eraProtVerLow @ConwayEra)

requiredSigners :: Set (KeyHash Guard)
requiredSigners =
    Set.fromList [signerHash 1, signerHash 2]

signerHash :: Word -> KeyHash Guard
signerHash n =
    hashKey (VKey (deriveVerKeyDSIGN (testKey n)))

testKey :: Word -> SignKeyDSIGN Ed25519DSIGN
testKey n =
    genKeyDSIGN (mkSeedFromBytes (BS.replicate 32 (fromIntegral n)))

testAddr :: Addr
testAddr =
    Addr
        Testnet
        (KeyHashObj (paymentHash 9))
        StakeRefNull

paymentHash :: Word -> KeyHash Payment
paymentHash n =
    hashKey (VKey (deriveVerKeyDSIGN (testKey n)))

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
