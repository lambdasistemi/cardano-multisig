{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

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
import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashToBytes)
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Era (eraProtVerLow)
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
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Credential
    ( Credential (KeyHashObj)
    , StakeReference (StakeRefNull)
    )
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)
import Cardano.Ledger.Keys
    ( KeyHash
    , KeyRole (Guard, Payment)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.Publish
    ( FeeQuote (..)
    , FeeReason (..)
    , FeeStatus (..)
    , OperatorSchedule (..)
    , PreflightResult (..)
    , PublishDeps (..)
    , PublishFailure (..)
    , PublishRequest (..)
    , publishEntry
    , quoteTx
    )
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryId (..)
    , EntryStatus (..)
    , FeeAllowance (..)
    , MalformedFeePayment (..)
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
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word8)
import Lens.Micro ((&), (.~))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
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
                fmap qTag quote `shouldBe` Right (renderEntryId (entryIdFromTx tx))
                fmap qInvalidHereafter quote `shouldBe` Right (SlotNo 125)
                fmap qRequiredFeeLovelace quote `shouldBe` Right 1_250

        it "admits when final indexed allowance covers the required fee" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                deps =
                    happyDeps
                        { mdAllowance = FeeAllowance 1_250 5 False
                        }
            result <-
                runMock
                    deps
                    ( publishEntry
                        schedule
                        (mockPublishDeps tx)
                        request{prTxCborHex = txHex tx, prFeePayment = Nothing}
                    )
            result `shouldBe` Right (storedEntryWithFeePayment tx inertFeePayment)

        it
            "returns fee_not_seen when no final or unconfirmed allowance exists"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                result <-
                    runMock
                        happyDeps{mdAllowance = FeeAllowance 0 5 False}
                        ( publishEntry
                            schedule
                            (mockPublishDeps tx)
                            request{prTxCborHex = txHex tx, prFeePayment = Nothing}
                        )
                expectFeeReason FeeNotSeen result

        it "returns fee_unconfirmed when only unconfirmed allowance exists" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            result <-
                runMock
                    happyDeps{mdAllowance = FeeAllowance 0 5 True}
                    ( publishEntry
                        schedule
                        (mockPublishDeps tx)
                        request{prTxCborHex = txHex tx, prFeePayment = Nothing}
                    )
            expectFeeReason FeeUnconfirmed result

        it "returns fee_insufficient with paid and required lovelace" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            result <-
                runMock
                    happyDeps{mdAllowance = FeeAllowance 1_249 5 False}
                    ( publishEntry
                        schedule
                        (mockPublishDeps tx)
                        request{prTxCborHex = txHex tx, prFeePayment = Nothing}
                    )
            case result of
                Left (PublishFeeRejected status) -> do
                    feeStatusReason status `shouldBe` FeeInsufficient
                    feeStatusPaidLovelace status `shouldBe` 1_249
                    feeStatusRequiredLovelace status `shouldBe` 1_250
                _ ->
                    expectationFailure ("expected fee_insufficient, got " <> show result)

        it
            "returns fee_metadata_malformed for an optional malformed payment hint"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                    malformed =
                        MalformedFeePayment
                            { malformedFeePaymentTxIn = mkTxIn 9
                            , malformedFeePaymentBlockSlot = SlotNo 99
                            }
                result <-
                    runMock
                        happyDeps
                            { mdAllowance = FeeAllowance 0 5 False
                            , mdMalformed = Just malformed
                            }
                        ( publishEntry
                            schedule
                            (mockPublishDeps tx)
                            request{prTxCborHex = txHex tx}
                        )
                expectFeeReason FeeMetadataMalformed result

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
                        { mdAllowance = FeeAllowance 1_510 5 False
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
        , prFeePayment = Just (mkTxIn 9)
        }

data MockDeps = MockDeps
    { mdTip :: SlotNo
    , mdAllowance :: FeeAllowance
    , mdMalformed :: Maybe MalformedFeePayment
    , mdPreflight :: PreflightResult
    , mdEntries :: Map EntryId Entry
    }

happyDeps :: MockDeps
happyDeps =
    MockDeps
        { mdTip = SlotNo 100
        , mdAllowance = FeeAllowance 1_250 5 False
        , mdMalformed = Nothing
        , mdPreflight = PreflightAccepted
        , mdEntries = mempty
        }

mockPublishDeps :: ConwayTx -> PublishDeps (StateT MockDeps IO)
mockPublishDeps _tx =
    PublishDeps
        { pdReadTip = gets mdTip
        , pdPreflight = \_ -> gets mdPreflight
        , pdStore =
            StoreWithFilters
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
                , storeListEntries = pure []
                , storePutSignerFilter = \_ _ -> pure ()
                , storeLookupSignerFilter = \_ -> pure Nothing
                , storeUpsertFeePayment = \_ -> pure ()
                , storeRollbackFeePaymentsFrom = \_ -> pure ()
                , storeAllowanceFor = \_ _ depth -> do
                    allowance <- gets mdAllowance
                    pure allowance{allowanceRequiredDepth = depth}
                , storePutMalformedFeePayment = \_ -> pure ()
                , storeMalformedFeePayment = \_ -> gets mdMalformed
                , storeRollbackMalformedFeePaymentsFrom = \_ -> pure ()
                }
        }

runMock :: MockDeps -> StateT MockDeps IO a -> IO a
runMock = flip evalStateT

storedEntry :: ConwayTx -> Entry
storedEntry tx =
    storedEntryWithFeePayment tx (mkTxIn 9)

storedEntryWithFeePayment :: ConwayTx -> TxIn -> Entry
storedEntryWithFeePayment tx feePayment =
    Entry
        { entryId = entryIdFromTx tx
        , entryTx = tx
        , entryRequiredSigners = requiredSigners
        , entryCollectedWitnesses = mempty
        , entryInvalidHereafter = SlotNo 125
        , entryFeePayment = feePayment
        , entryStatus = EntryCollecting
        }

expectFeeReason :: FeeReason -> Either PublishFailure Entry -> IO ()
expectFeeReason expected = \case
    Left (PublishFeeRejected status) ->
        feeStatusReason status `shouldBe` expected
    other ->
        expectationFailure
            ("expected fee rejection " <> show expected <> ", got " <> show other)

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

inertFeePayment :: TxIn
inertFeePayment =
    mkTxIn 0

renderEntryId :: EntryId -> Text
renderEntryId (EntryId (TxId safeHash)) =
    TextEncoding.decodeUtf8
        $ Base16.encode
        $ hashToBytes
        $ extractHash safeHash

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    case hashFromBytes (BS.pack (replicate 31 0 ++ [n])) of
        Just h -> h
        Nothing -> error "mkHash32: invalid hash length"
