{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.ServerSpec
    ( spec
    ) where

-- \|
-- Module      : Cardano.Multisig.ServerSpec
-- Description : Unit tests for the WAI application
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , genKeyDSIGN
    )
import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashToBytes)
import Cardano.Crypto.Hash.Class qualified as Hash
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Address
    ( Addr (..)
    , serialiseAddr
    )
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx
    ( addrTxWitsL
    , bodyTxL
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
import Cardano.Ledger.Hashes
    ( EraIndependentTxBody
    , HASH
    , extractHash
    , hashAnnotated
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys
    ( KeyHash (..)
    , KeyRole (Guard, Payment, Witness)
    , VKey (..)
    , WitVKey (..)
    , asWitness
    , hashKey
    , signedDSIGN
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.Chain
    ( N2cConfig (..)
    )
import Cardano.Multisig.FeeIndexer (FeeIndexerConfig (..))
import Cardano.Multisig.Filter
    ( FilterPolicy (..)
    , canonicalFilterPolicyBytes
    )
import Cardano.Multisig.Liveness (EntryLiveness (..))
import Cardano.Multisig.Publish
    ( OperatorSchedule (..)
    , PreflightResult (..)
    , PublishDeps (..)
    )
import Cardano.Multisig.Server
    ( RuntimeConfig (..)
    , ServerDeps (..)
    , applicationWith
    , errorEnvelope
    , feeIndexerConfigFromRuntimeConfig
    , readRuntimeConfigWith
    , withServerBackgroundTasks
    )
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryId (..)
    , EntryStatus (..)
    , FeeAllowance (..)
    , MalformedFeePayment (..)
    , Receipt (..)
    , Store (..)
    , entryIdFromTx
    )
import Cardano.Multisig.Witness
    ( assembleEntryTx
    , entryMissingSigners
    , entryWitnessStatus
    , entryWitnesses
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Concurrent
    ( newEmptyMVar
    , readMVar
    , threadDelay
    )
import Data.Aeson
    ( Value
    , decode
    , encode
    , object
    , (.=)
    )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BL
import Data.IORef
    ( IORef
    , atomicModifyIORef'
    , newIORef
    , readIORef
    )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock
    ( UTCTime
    , addUTCTime
    )
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Word (Word64, Word8)
import Lens.Micro ((&), (.~), (^.))
import Network.HTTP.Types
    ( hContentType
    , methodGet
    , methodPost
    , methodPut
    , parseQuery
    , status200
    , status201
    , status204
    , status401
    , status402
    , status404
    , status409
    , status422
    )
import Network.Wai
    ( defaultRequest
    , pathInfo
    , queryString
    , rawQueryString
    , requestHeaders
    , requestMethod
    )
import Network.Wai.Test
    ( SRequest (..)
    , SResponse (..)
    , runSession
    , srequest
    )
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

spec :: Spec
spec = do
    describe "errorEnvelope"
        $ it "nests code and message under an error key"
        $ errorEnvelope "not_found" "no such route"
        `shouldBe` object
            [ "error"
                .= object
                    [ "code" .= ("not_found" :: String)
                    , "message" .= ("no such route" :: String)
                    ]
            ]

    describe "Cardano.Multisig.Server fee indexer startup config" $ do
        it "defaults fee indexer runtime settings from the store path" $ do
            cfg <- readRuntimeConfigWith (lookupFixture baseRuntimeEnv)
            rcFeeIndexerCheckpointDir cfg
                `shouldBe` "/tmp/cardano-multisig-fee-indexer"
            rcFeeIndexerByronEpochSlots cfg `shouldBe` 21_600
            rcFeeIndexerRetryDelayMicros cfg `shouldBe` 30_000_000

        it "honors explicit fee indexer runtime overrides" $ do
            cfg <-
                readRuntimeConfigWith
                    ( lookupFixture
                        $ baseRuntimeEnv
                            <> [ ("FEE_INDEXER_CHECKPOINT_DIR", "/tmp/fee-checkpoints")
                               , ("FEE_INDEXER_BYRON_EPOCH_SLOTS", "43200")
                               , ("FEE_INDEXER_RETRY_DELAY_MICROS", "500000")
                               ]
                    )
            rcFeeIndexerCheckpointDir cfg `shouldBe` "/tmp/fee-checkpoints"
            rcFeeIndexerByronEpochSlots cfg `shouldBe` 43_200
            rcFeeIndexerRetryDelayMicros cfg `shouldBe` 500_000

        it
            "builds fee indexer config from existing node, store, and schedule settings"
            $ feeIndexerConfigFromRuntimeConfig
                testRuntimeConfig
                    { rcFeeIndexerCheckpointDir = "/tmp/checkpoints"
                    , rcFeeIndexerByronEpochSlots = 43_200
                    , rcFeeIndexerRetryDelayMicros = 500_000
                    }
            `shouldBe` FeeIndexerConfig
                { ficSocketPath = "/tmp/node.socket"
                , ficNetworkMagic = 42
                , ficByronEpochSlots = 43_200
                , ficFeeAddress = testAddr
                , ficCheckpointDir = "/tmp/checkpoints"
                , ficRetryDelayMicros = 500_000
                }

    describe "Cardano.Multisig.Server startup background tasks"
        $ it
            "starts liveness and fee indexer as sibling tasks scoped under the server action"
        $ do
            started <- newIORef Set.empty
            blocker <- newEmptyMVar
            let mark name = do
                    atomicModifyIORef' started (\seen -> (Set.insert name seen, ()))
                    readMVar blocker
            withServerBackgroundTasks
                (mark ("liveness" :: Text))
                (mark "fee-indexer")
                (waitForStarted started)
            seen <- readIORef started
            seen `shouldBe` Set.fromList ["liveness", "fee-indexer"]

    describe "Cardano.Multisig.Server publish HTTP routes" $ do
        it "returns the configured operator schedule" $ do
            body <- getJson "/v1/operator" happyDeps
            body
                `shouldBe` object
                    [ "network" .= ("preprod" :: Text)
                    , "fee"
                        .= object
                            [ "base_lovelace" .= (1_000 :: Integer)
                            , "rate_lovelace_per_slot" .= (10 :: Integer)
                            , "address" .= renderAddr testAddr
                            , "tag_field"
                                .= ("body_hash_blake2b_256" :: Text)
                            ]
                    , "ttl_horizon_slots" .= (50 :: Word64)
                    , "roster_types" .= (["required_signers"] :: [Text])
                    ]

        it "quotes the exact validity-weighted fee for a bounded transaction"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                response <-
                    postJson
                        "/v1/fee-quote"
                        happyDeps
                        (object ["transaction" .= txHexText tx])
                simpleStatus response `shouldBe` status200
                decode (simpleBody response)
                    `shouldBe` Just
                        ( object
                            [ "body_hash" .= renderEntryId (entryIdFromTx tx)
                            , "required_fee_lovelace" .= (1_250 :: Integer)
                            , "fee_address" .= renderAddr testAddr
                            , "tag" .= renderEntryId (entryIdFromTx tx)
                            , "invalid_hereafter" .= (125 :: Word64)
                            ]
                        )

        it "admits a paid entry and returns the OpenAPI Entry fields" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            response <-
                postJson
                    "/v1/entries"
                    happyDeps
                    ( object
                        [ "transaction" .= txHexText tx
                        , "fee_payment" .= renderTxIn (mkTxIn 9)
                        ]
                    )
            simpleStatus response `shouldBe` status201
            decode (simpleBody response)
                `shouldBe` Just
                    ( object
                        [ "entry_id" .= renderEntryId (entryIdFromTx tx)
                        , "transaction" .= txHexText tx
                        , "required_signers" .= renderKeyHashes requiredSigners
                        , "witnesses" .= ([] :: [Text])
                        , "missing" .= renderKeyHashes requiredSigners
                        , "invalid_hereafter" .= (125 :: Word64)
                        , "status" .= ("collecting" :: Text)
                        ]
                    )

        it
            "admits an entry without a fee_payment when final allowance is sufficient"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                response <-
                    postJson
                        "/v1/entries"
                        happyDeps{mdAllowance = FeeAllowance 1_250 5 False}
                        (object ["transaction" .= txHexText tx])
                simpleStatus response `shouldBe` status201

        it "maps insufficient fee failures to HTTP 402" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                deps =
                    happyDeps
                        { mdAllowance = FeeAllowance 1_249 5 False
                        }
            response <-
                postJson
                    "/v1/entries"
                    deps
                    ( object
                        [ "transaction" .= txHexText tx
                        , "fee_payment" .= renderTxIn (mkTxIn 9)
                        ]
                    )
            simpleStatus response `shouldBe` status402
            decode (simpleBody response)
                `shouldBe` Just
                    ( feeError
                        "fee_insufficient"
                        "fee allowance is insufficient"
                        ( object
                            [ "paid_lovelace" .= (1_249 :: Word64)
                            , "required_lovelace" .= (1_250 :: Integer)
                            ]
                        )
                    )

        it "maps absent allowance without a payment hint to fee_not_seen" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            response <-
                postJson
                    "/v1/entries"
                    happyDeps{mdAllowance = FeeAllowance 0 5 False}
                    (object ["transaction" .= txHexText tx])
            simpleStatus response `shouldBe` status402
            decode (simpleBody response)
                `shouldBe` Just
                    ( feeError
                        "fee_not_seen"
                        "fee allowance was not seen"
                        ( object
                            [ "paid_lovelace" .= (0 :: Word64)
                            , "required_lovelace" .= (1_250 :: Integer)
                            ]
                        )
                    )

        it "maps unconfirmed allowance to fee_unconfirmed" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            response <-
                postJson
                    "/v1/entries"
                    happyDeps{mdAllowance = FeeAllowance 0 5 True}
                    (object ["transaction" .= txHexText tx])
            simpleStatus response `shouldBe` status402
            decode (simpleBody response)
                `shouldBe` Just
                    ( feeError
                        "fee_unconfirmed"
                        "fee allowance is not yet confirmed"
                        ( object
                            [ "required_depth" .= (5 :: Word)
                            , "paid_lovelace" .= (0 :: Word64)
                            , "required_lovelace" .= (1_250 :: Integer)
                            ]
                        )
                    )

        it
            "maps malformed optional payment metadata to fee_metadata_malformed"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                    feePayment = mkTxIn 9
                    malformed =
                        MalformedFeePayment
                            { malformedFeePaymentTxIn = feePayment
                            , malformedFeePaymentBlockSlot = SlotNo 99
                            }
                response <-
                    postJson
                        "/v1/entries"
                        happyDeps
                            { mdAllowance = FeeAllowance 0 5 False
                            , mdMalformed = Just malformed
                            }
                        ( object
                            [ "transaction" .= txHexText tx
                            , "fee_payment" .= renderTxIn feePayment
                            ]
                        )
                simpleStatus response `shouldBe` status402
                decode (simpleBody response)
                    `shouldBe` Just
                        ( feeError
                            "fee_metadata_malformed"
                            "fee payment metadata is malformed"
                            (object ["fee_payment" .= renderTxIn feePayment])
                        )

        it "maps duplicate entry ids to HTTP 409" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                deps =
                    happyDeps
                        { mdEntries = Map.singleton (entryIdFromTx tx) (storedEntry tx)
                        }
            response <-
                postJson
                    "/v1/entries"
                    deps
                    ( object
                        [ "transaction" .= txHexText tx
                        , "fee_payment" .= renderTxIn (mkTxIn 9)
                        ]
                    )
            simpleStatus response `shouldBe` status409

        it "maps malformed, unbounded, and preflight failures to HTTP 422"
            $ do
                malformed <-
                    postJson
                        "/v1/fee-quote"
                        happyDeps
                        (object ["transaction" .= ("not-hex" :: Text)])
                simpleStatus malformed `shouldBe` status422

                let unbounded = testTx SNothing requiredSigners
                ttl <-
                    postJson
                        "/v1/entries"
                        happyDeps
                        ( object
                            [ "transaction" .= txHexText unbounded
                            , "fee_payment" .= renderTxIn (mkTxIn 9)
                            ]
                        )
                simpleStatus ttl `shouldBe` status422

                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                    deps = happyDeps{mdPreflight = PreflightRejected "missing input"}
                preflight <-
                    postJson
                        "/v1/entries"
                        deps
                        ( object
                            [ "transaction" .= txHexText tx
                            , "fee_payment" .= renderTxIn (mkTxIn 9)
                            ]
                        )
                simpleStatus preflight `shouldBe` status422

    describe "Cardano.Multisig.Server fee-status HTTP routes" $ do
        it "returns ready status when final allowance is sufficient" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            body <-
                getJson
                    (feeStatusPath (entryIdFromTx tx))
                    happyDeps{mdAllowance = FeeAllowance 1_500 5 False}
            body
                `shouldBe` feeStatusJson
                    True
                    True
                    True
                    True
                    1_500
                    1_500
                    5
                    Nothing

        it "returns fee_not_seen when no payment was observed" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            body <-
                getJson
                    (feeStatusPath (entryIdFromTx tx))
                    happyDeps{mdAllowance = FeeAllowance 0 5 False}
            body
                `shouldBe` feeStatusJson
                    False
                    False
                    False
                    False
                    0
                    1_500
                    5
                    (Just "fee_not_seen")

        it "returns fee_unconfirmed when allowance is not final" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            body <-
                getJson
                    (feeStatusPath (entryIdFromTx tx))
                    happyDeps{mdAllowance = FeeAllowance 0 5 True}
            body
                `shouldBe` feeStatusJson
                    True
                    False
                    False
                    False
                    0
                    1_500
                    5
                    (Just "fee_unconfirmed")

        it "returns fee_insufficient when final allowance is short" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            body <-
                getJson
                    (feeStatusPath (entryIdFromTx tx))
                    happyDeps{mdAllowance = FeeAllowance 1_499 5 False}
            body
                `shouldBe` feeStatusJson
                    True
                    True
                    False
                    False
                    1_499
                    1_500
                    5
                    (Just "fee_insufficient")

        it "returns fee_metadata_malformed for a malformed payment hint" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                feePayment = mkTxIn 9
                malformed =
                    MalformedFeePayment
                        { malformedFeePaymentTxIn = feePayment
                        , malformedFeePaymentBlockSlot = SlotNo 99
                        }
            body <-
                getJson
                    ( feeStatusPath (entryIdFromTx tx)
                        <> "?payment="
                        <> TextEncoding.encodeUtf8 (renderTxIn feePayment)
                    )
                    happyDeps
                        { mdAllowance = FeeAllowance 0 5 False
                        , mdMalformed = Just malformed
                        }
            body
                `shouldBe` feeStatusJson
                    True
                    False
                    False
                    False
                    0
                    1_500
                    5
                    (Just "fee_metadata_malformed")

        it "rejects an invalid payment query" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            response <-
                waiRequest
                    methodGet
                    (feeStatusPath (entryIdFromTx tx) <> "?payment=not-a-txin")
                    happyDeps
                    mempty
            simpleStatus response `shouldBe` status422
            decode (simpleBody response)
                `shouldBe` Just
                    ( errorEnvelope
                        "invalid_fee_payment"
                        "expected <txid>#<ix>"
                    )

    describe "Cardano.Multisig.Server witness HTTP routes" $ do
        it
            "returns a stored entry with collected witnesses and missing signers"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                    witness = testWitness 1 tx
                    entry = storedEntryWithCollected tx [witness]
                    deps =
                        happyDeps
                            { mdEntries =
                                Map.singleton (entryIdFromTx tx) entry
                            }
                body <-
                    getJson
                        (entryPath (entryIdFromTx tx))
                        deps
                body
                    `shouldBe` object
                        [ "entry_id" .= renderEntryId (entryIdFromTx tx)
                        , "transaction" .= txHexText tx
                        , "required_signers" .= renderKeyHashes requiredSigners
                        , "witnesses" .= renderKeyHashes (Set.singleton (signerHash 1))
                        , "missing" .= renderKeyHashes (Set.singleton (signerHash 2))
                        , "invalid_hereafter" .= (125 :: Word64)
                        , "status" .= ("collecting" :: Text)
                        , "liveness" .= entryLivenessJson liveLiveness
                        ]

        it
            "returns stale liveness from the injected read dependency"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                    entry = readyEntry tx
                    deps =
                        happyDeps
                            { mdEntries =
                                Map.singleton (entryIdFromTx tx) entry
                            , mdLiveness = staleLiveness
                            }
                body <-
                    getJson
                        (entryPath (entryIdFromTx tx))
                        deps
                body
                    `shouldBe` object
                        [ "entry_id" .= renderEntryId (entryIdFromTx tx)
                        , "transaction" .= txHexText tx
                        , "required_signers" .= renderKeyHashes requiredSigners
                        , "witnesses" .= renderKeyHashes requiredSigners
                        , "missing" .= ([] :: [Text])
                        , "invalid_hereafter" .= (125 :: Word64)
                        , "status" .= ("ready" :: Text)
                        , "liveness" .= entryLivenessJson staleLiveness
                        ]

        it "renders expired status on a persisted expired entry" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                entry = (storedEntry tx){entryStatus = EntryExpired}
                deps =
                    happyDeps
                        { mdEntries =
                            Map.singleton (entryIdFromTx tx) entry
                        }
            body <-
                getJson
                    (entryPath (entryIdFromTx tx))
                    deps
            body
                `shouldBe` object
                    [ "entry_id" .= renderEntryId (entryIdFromTx tx)
                    , "transaction" .= txHexText tx
                    , "required_signers" .= renderKeyHashes requiredSigners
                    , "witnesses" .= ([] :: [Text])
                    , "missing" .= renderKeyHashes requiredSigners
                    , "invalid_hereafter" .= (125 :: Word64)
                    , "status" .= ("expired" :: Text)
                    , "liveness" .= entryLivenessJson liveLiveness
                    ]

        it "returns 404 for an absent entry" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
            response <-
                waiRequest methodGet (entryPath (entryIdFromTx tx)) happyDeps mempty
            simpleStatus response `shouldBe` status404

        it "returns 422 for an invalid signature witness" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                otherTx = testTx (SJust (SlotNo 126)) requiredSigners
                deps =
                    happyDeps
                        { mdEntries =
                            Map.singleton (entryIdFromTx tx) (storedEntry tx)
                        }
            response <-
                postJson
                    (witnessPath (entryIdFromTx tx))
                    deps
                    (witnessBody (testWitness 1 otherTx))
            simpleStatus response `shouldBe` status422

        it "returns 422 for a non-required signer witness" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                deps =
                    happyDeps
                        { mdEntries =
                            Map.singleton (entryIdFromTx tx) (storedEntry tx)
                        }
            response <-
                postJson
                    (witnessPath (entryIdFromTx tx))
                    deps
                    (witnessBody (testWitness 3 tx))
            simpleStatus response `shouldBe` status422

        it "returns 409 for a duplicate witness" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                witness = testWitness 1 tx
                deps =
                    happyDeps
                        { mdEntries =
                            Map.singleton
                                (entryIdFromTx tx)
                                (storedEntryWithCollected tx [witness])
                        }
            response <-
                postJson
                    (witnessPath (entryIdFromTx tx))
                    deps
                    (witnessBody witness)
            simpleStatus response `shouldBe` status409

        it "persists a valid witness and returns updated missing signers" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                witness = testWitness 1 tx
                entryId = entryIdFromTx tx
                deps =
                    happyDeps
                        { mdEntries = Map.singleton entryId (storedEntry tx)
                        }
            ref <- newIORef deps
            response <-
                waiRequestWithRef
                    methodPost
                    (witnessPath entryId)
                    ref
                    (encode (witnessBody witness))
            simpleStatus response `shouldBe` status200
            decode (simpleBody response)
                `shouldBe` Just
                    ( object
                        [ "witnesses" .= renderKeyHashes (Set.singleton (signerHash 1))
                        , "missing" .= renderKeyHashes (Set.singleton (signerHash 2))
                        , "status" .= ("collecting" :: Text)
                        ]
                    )
            stored <- Map.lookup entryId . mdEntries <$> readIORef ref
            fmap
                ( renderKeyHashes
                    . Set.map witnessSignerHash
                    . (^. addrTxWitsL)
                    . entryCollectedWitnesses
                )
                stored
                `shouldBe` Just (renderKeyHashes (Set.singleton (signerHash 1)))

        it "returns ready after collecting the full signer roster" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                firstWitness = testWitness 1 tx
                secondWitness = testWitness 2 tx
                entryId = entryIdFromTx tx
                deps =
                    happyDeps
                        { mdEntries =
                            Map.singleton
                                entryId
                                (storedEntryWithCollected tx [firstWitness])
                        }
            response <-
                postJson
                    (witnessPath entryId)
                    deps
                    (witnessBody secondWitness)
            simpleStatus response `shouldBe` status200
            decode (simpleBody response)
                `shouldBe` Just
                    ( object
                        [ "witnesses" .= renderKeyHashes requiredSigners
                        , "missing" .= ([] :: [Text])
                        , "status" .= ("ready" :: Text)
                        ]
                    )

        it "rejects signer filter policy updates signed by the wrong key" $ do
            let body =
                    object
                        [ "predicate" .= object ["name" .= ("roster-open" :: Text)]
                        , "signature" .= witnessHexText (testWitness 2 testTxForPolicy)
                        ]
            response <-
                waiRequest
                    methodPut
                    (filterPolicyPath (signerHash 1))
                    happyDeps
                    (encode body)
            simpleStatus response `shouldBe` status401

    describe "Cardano.Multisig.Server filter HTTP routes" $ do
        it
            "filters explicit trust-ordered entries by trusted witness"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                    entryId = entryIdFromTx tx
                    emptyDeps =
                        happyDeps
                            { mdEntries =
                                Map.singleton entryId (storedEntry tx)
                            }
                    witnessedDeps =
                        happyDeps
                            { mdEntries =
                                Map.singleton
                                    entryId
                                    ( storedEntryWithCollected
                                        tx
                                        [testWitness 2 tx]
                                    )
                            }
                    path =
                        entriesFilterPath
                            (signerHash 1)
                            "trust-ordered"
                            (Just [signerHash 2])

                hidden <- getJson path emptyDeps
                hidden `shouldBe` object ["entries" .= ([] :: [Value])]

                visible <- getJson path witnessedDeps
                visible
                    `shouldBe` object
                        [ "entries"
                            .= [entrySummaryJson (storedEntryWithCollected tx [testWitness 2 tx])]
                        ]

        it "returns zero-witness roster entries with roster-open" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                entry = storedEntry tx
                deps =
                    happyDeps
                        { mdEntries = Map.singleton (entryIdFromTx tx) entry
                        }
            body <-
                getJson
                    (entriesFilterPath (signerHash 1) "roster-open" Nothing)
                    deps
            body `shouldBe` object ["entries" .= [entrySummaryJson entry]]

        it "returns no roster-open entries to non-roster signers" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                deps =
                    happyDeps
                        { mdEntries =
                            Map.singleton (entryIdFromTx tx) (storedEntry tx)
                        }
            body <-
                getJson
                    (entriesFilterPath (signerHash 3) "roster-open" Nothing)
                    deps
            body `shouldBe` object ["entries" .= ([] :: [Value])]

        it "persists a signer default policy and uses it for entry lists" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                entry = storedEntry tx
                deps =
                    happyDeps
                        { mdEntries = Map.singleton (entryIdFromTx tx) entry
                        }
                policy = RosterOpen
                signer = signerHash 1
            ref <- newIORef deps
            putResponse <-
                waiRequestWithRef
                    methodPut
                    (filterPolicyPath signer)
                    ref
                    (encode (policyBody policy (policyWitness 1 policy)))
            simpleStatus putResponse `shouldBe` status204
            simpleBody putResponse `shouldBe` mempty

            body <- getJsonWithRef (entriesDefaultFilterPath signer) ref
            body `shouldBe` object ["entries" .= [entrySummaryJson entry]]

    describe "Cardano.Multisig.Server submit and receipt HTTP routes" $ do
        it "returns 409 when submitting a non-ready entry" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                entryId = entryIdFromTx tx
                deps =
                    happyDeps
                        { mdEntries = Map.singleton entryId (storedEntry tx)
                        }
            response <- postJson (submitPath entryId) deps (object [])
            simpleStatus response `shouldBe` status409

        it "returns 404 for a receipt before submit" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                entryId = entryIdFromTx tx
                deps =
                    happyDeps
                        { mdEntries =
                            Map.singleton entryId (readyEntry tx)
                        }
            response <- waiRequest methodGet (receiptPath entryId) deps mempty
            simpleStatus response `shouldBe` status404

        it
            "submits a ready entry, stores a receipt, and marks it submitted"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                    entry = readyEntry tx
                    entryId = entryIdFromTx tx
                    deps =
                        happyDeps
                            { mdEntries = Map.singleton entryId entry
                            , mdNow = receiptTime
                            }
                ref <- newIORef deps
                response <-
                    waiRequestWithRef methodPost (submitPath entryId) ref mempty
                simpleStatus response `shouldBe` status200
                decode (simpleBody response)
                    `shouldBe` Just (receiptJson (Receipt entryId receiptTime))
                updated <- readIORef ref
                mdSubmitted updated `shouldBe` [assembledEntryTx entry]
                Map.lookup entryId (mdReceipts updated)
                    `shouldBe` Just (Receipt entryId receiptTime)
                entryStatus <$> Map.lookup entryId (mdEntries updated)
                    `shouldBe` Just EntrySubmitted

                body <- getJsonWithRef (entryPath entryId) ref
                body
                    `shouldBe` object
                        [ "entry_id" .= renderEntryId entryId
                        , "transaction" .= txHexText tx
                        , "required_signers" .= renderKeyHashes requiredSigners
                        , "witnesses" .= renderKeyHashes requiredSigners
                        , "missing" .= ([] :: [Text])
                        , "invalid_hereafter" .= (125 :: Word64)
                        , "status" .= ("submitted" :: Text)
                        , "liveness" .= entryLivenessJson liveLiveness
                        ]

        it "returns a persisted receipt after submit" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                entryId = entryIdFromTx tx
                receipt = Receipt entryId receiptTime
                deps =
                    happyDeps
                        { mdReceipts = Map.singleton entryId receipt
                        }
            body <- getJson (receiptPath entryId) deps
            body `shouldBe` receiptJson receipt

        it "returns 422 when the submitter rejects the assembled transaction"
            $ do
                let tx = testTx (SJust (SlotNo 125)) requiredSigners
                    entryId = entryIdFromTx tx
                    deps =
                        happyDeps
                            { mdEntries = Map.singleton entryId (readyEntry tx)
                            , mdSubmitResult = Left "mempool rejected"
                            }
                response <- postJson (submitPath entryId) deps (object [])
                simpleStatus response `shouldBe` status422

data MockDeps = MockDeps
    { mdTip :: SlotNo
    , mdAllowance :: FeeAllowance
    , mdMalformed :: Maybe MalformedFeePayment
    , mdPreflight :: PreflightResult
    , mdEntries :: Map EntryId Entry
    , mdReceipts :: Map EntryId Receipt
    , mdSignerFilters :: Map (KeyHash Guard) ByteString
    , mdSubmitResult :: Either Text ()
    , mdSubmitted :: [ConwayTx]
    , mdNow :: UTCTime
    , mdLiveness :: EntryLiveness
    }

happyDeps :: MockDeps
happyDeps =
    MockDeps
        { mdTip = SlotNo 100
        , mdAllowance = FeeAllowance 1_250 5 False
        , mdMalformed = Nothing
        , mdPreflight = PreflightAccepted
        , mdEntries = mempty
        , mdReceipts = mempty
        , mdSignerFilters = mempty
        , mdSubmitResult = Right ()
        , mdSubmitted = mempty
        , mdNow = receiptTime
        , mdLiveness = liveLiveness
        }

baseRuntimeEnv :: [(String, String)]
baseRuntimeEnv =
    [ ("CARDANO_NODE_SOCKET", "/tmp/node.socket")
    , ("CARDANO_NODE_MAGIC", "42")
    , ("CARDANO_MULTISIG_STORE", "/tmp/cardano-multisig")
    , ("FEE_ADDRESS", Text.unpack (renderAddr testAddr))
    , ("BASE_LOVELACE", "1000")
    , ("RATE_LOVELACE_PER_SLOT", "10")
    , ("TTL_HORIZON_SLOTS", "50")
    ]

lookupFixture :: [(String, String)] -> String -> IO (Maybe String)
lookupFixture env name =
    pure (lookup name env)

testRuntimeConfig :: RuntimeConfig
testRuntimeConfig =
    RuntimeConfig
        { rcN2c = N2cConfig{n2cSocket = "/tmp/node.socket", n2cMagic = 42}
        , rcStorePath = "/tmp/cardano-multisig"
        , rcSchedule = schedule
        , rcFeeIndexerCheckpointDir = "/tmp/cardano-multisig-fee-indexer"
        , rcFeeIndexerByronEpochSlots = 21_600
        , rcFeeIndexerRetryDelayMicros = 30_000_000
        }

waitForStarted :: IORef (Set Text) -> IO ()
waitForStarted started =
    go (100 :: Int)
  where
    expected = Set.fromList ["liveness", "fee-indexer"]
    go attempts = do
        seen <- readIORef started
        if expected `Set.isSubsetOf` seen
            then pure ()
            else
                if attempts <= 0
                    then expectationFailure ("backgrounds not started: " <> show seen)
                    else do
                        threadDelay 10_000
                        go (attempts - 1)

getJson :: ByteString -> MockDeps -> IO Value
getJson path deps = do
    response <- waiRequest methodGet path deps mempty
    simpleStatus response `shouldBe` status200
    case decode (simpleBody response) of
        Just value -> pure value
        Nothing -> do
            expectationFailure "expected valid JSON response"
            pure (object [])

getJsonWithRef :: ByteString -> IORef MockDeps -> IO Value
getJsonWithRef path ref = do
    response <- waiRequestWithRef methodGet path ref mempty
    simpleStatus response `shouldBe` status200
    case decode (simpleBody response) of
        Just value -> pure value
        Nothing -> do
            expectationFailure "expected valid JSON response"
            pure (object [])

postJson :: ByteString -> MockDeps -> Value -> IO SResponse
postJson path deps body =
    waiRequest methodPost path deps (encode body)

splitRequestTarget :: ByteString -> (ByteString, ByteString)
splitRequestTarget =
    BS.break (== questionMark)
  where
    questionMark = 0x3f

waiRequest
    :: ByteString
    -> ByteString
    -> MockDeps
    -> BL.ByteString
    -> IO SResponse
waiRequest method path deps body = do
    ref <- newIORef deps
    waiRequestWithRef method path ref body

waiRequestWithRef
    :: ByteString
    -> ByteString
    -> IORef MockDeps
    -> BL.ByteString
    -> IO SResponse
waiRequestWithRef method path ref body =
    let (requestPath, requestQuery) = splitRequestTarget path
    in  runSession
            ( srequest
                SRequest
                    { simpleRequest =
                        defaultRequest
                            { requestMethod = method
                            , pathInfo =
                                filter (not . Text.null)
                                    $ Text.splitOn "/" (TextEncoding.decodeUtf8 requestPath)
                            , rawQueryString = requestQuery
                            , queryString = parseQuery requestQuery
                            , requestHeaders = [(hContentType, "application/json")]
                            }
                    , simpleRequestBody = body
                    }
            )
            (applicationWith "preprod" schedule (mockServerDeps ref))

mockServerDeps :: IORef MockDeps -> ServerDeps IO
mockServerDeps ref =
    ServerDeps
        { sdPublish = mockPublishDeps ref
        , sdSubmitTx = \tx ->
            atomicModifyIORef'
                ref
                ( \s ->
                    ( s{mdSubmitted = mdSubmitted s <> [tx]}
                    , mdSubmitResult s
                    )
                )
        , sdNow = mdNow <$> readIORef ref
        , sdEntryLiveness = \_ -> mdLiveness <$> readIORef ref
        }

mockPublishDeps :: IORef MockDeps -> PublishDeps IO
mockPublishDeps ref =
    PublishDeps
        { pdReadTip = mdTip <$> readIORef ref
        , pdPreflight = \_ -> mdPreflight <$> readIORef ref
        , pdStore =
            StoreWithFilters
                { storePutEntry = \entry ->
                    atomicModifyIORef'
                        ref
                        ( \s ->
                            ( s
                                { mdEntries =
                                    Map.insert
                                        (entryId entry)
                                        entry
                                        (mdEntries s)
                                }
                            , ()
                            )
                        )
                , storeLookupEntry = \entryId ->
                    Map.lookup entryId . mdEntries <$> readIORef ref
                , storeListEntries =
                    Map.elems . mdEntries <$> readIORef ref
                , storeCollectWitnesses = \entryId txWits ->
                    atomicModifyIORef'
                        ref
                        ( \s ->
                            let entries =
                                    Map.adjust
                                        ( \entry ->
                                            entry
                                                { entryCollectedWitnesses =
                                                    txWits
                                                }
                                        )
                                        entryId
                                        (mdEntries s)
                            in  (s{mdEntries = entries}, ())
                        )
                , storePutReceipt = \entryId receipt ->
                    atomicModifyIORef'
                        ref
                        ( \s ->
                            ( s
                                { mdReceipts =
                                    Map.insert entryId receipt (mdReceipts s)
                                }
                            , ()
                            )
                        )
                , storeLookupReceipt = \entryId ->
                    Map.lookup entryId . mdReceipts <$> readIORef ref
                , storePutSignerFilter = \signer policy ->
                    atomicModifyIORef'
                        ref
                        ( \s ->
                            ( s
                                { mdSignerFilters =
                                    Map.insert
                                        signer
                                        policy
                                        (mdSignerFilters s)
                                }
                            , ()
                            )
                        )
                , storeLookupSignerFilter = \signer ->
                    Map.lookup signer . mdSignerFilters <$> readIORef ref
                , storeUpsertFeePayment = \_ -> pure ()
                , storeRollbackFeePaymentsFrom = \_ -> pure ()
                , storeAllowanceFor = \_ _ depth -> do
                    allowance <- mdAllowance <$> readIORef ref
                    pure allowance{allowanceRequiredDepth = depth}
                , storePutMalformedFeePayment = \_ -> pure ()
                , storeMalformedFeePayment = \_ -> mdMalformed <$> readIORef ref
                , storeRollbackMalformedFeePaymentsFrom = \_ -> pure ()
                }
        }

schedule :: OperatorSchedule
schedule =
    OperatorSchedule
        { osNetwork = Testnet
        , osFeeAddress = testAddr
        , osBaseLovelace = 1_000
        , osRateLovelacePerSlot = 10
        , osTtlHorizonSlots = 50
        }

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

storedEntryWithCollected :: ConwayTx -> [WitVKey Witness] -> Entry
storedEntryWithCollected tx witnesses =
    (storedEntry tx)
        { entryCollectedWitnesses =
            mempty & addrTxWitsL .~ Set.fromList witnesses
        }

readyEntry :: ConwayTx -> Entry
readyEntry tx =
    storedEntryWithCollected tx [testWitness 1 tx, testWitness 2 tx]

assembledEntryTx :: Entry -> ConwayTx
assembledEntryTx =
    assembleEntryTx

receiptTime :: UTCTime
receiptTime =
    addUTCTime 123 (posixSecondsToUTCTime 1_893_456_000)

receiptJson :: Receipt -> Value
receiptJson Receipt{..} =
    object
        [ "tx_id" .= renderEntryId receiptTxId
        , "submitted_at" .= receiptSubmittedAt
        ]

feeError :: Text -> Text -> Value -> Value
feeError code message details =
    object
        [ "error"
            .= object
                [ "code" .= code
                , "message" .= message
                , "details" .= details
                ]
        ]

liveLiveness :: EntryLiveness
liveLiveness =
    EntryLiveness
        { elInputsUnspent = True
        , elPhase1Ok = True
        }

staleLiveness :: EntryLiveness
staleLiveness =
    EntryLiveness
        { elInputsUnspent = False
        , elPhase1Ok = False
        }

entryLivenessJson :: EntryLiveness -> Value
entryLivenessJson EntryLiveness{..} =
    object
        [ "inputs_unspent" .= elInputsUnspent
        , "phase1_ok" .= elPhase1Ok
        ]

testTx
    :: StrictMaybe SlotNo
    -> Set (KeyHash Guard)
    -> ConwayTx
testTx invalidHereafter signers =
    (mkBasicTx mkBasicTxBody :: ConwayTx)
        & bodyTxL . reqSignerHashesTxBodyL .~ signers
        & bodyTxL . vldtTxBodyL
            .~ ValidityInterval SNothing invalidHereafter

txHexText :: ConwayTx -> Text
txHexText =
    TextEncoding.decodeUtf8
        . Base16.encode
        . serialize' (eraProtVerLow @ConwayEra)

entryPath :: EntryId -> ByteString
entryPath entryId =
    TextEncoding.encodeUtf8 ("/v1/entries/" <> renderEntryId entryId)

feeStatusPath :: EntryId -> ByteString
feeStatusPath entryId =
    TextEncoding.encodeUtf8 ("/v1/fee-status/" <> renderEntryId entryId)

witnessPath :: EntryId -> ByteString
witnessPath entryId =
    entryPath entryId <> "/witnesses"

submitPath :: EntryId -> ByteString
submitPath entryId =
    entryPath entryId <> "/submit"

receiptPath :: EntryId -> ByteString
receiptPath entryId =
    entryPath entryId <> "/receipt"

filterPolicyPath :: KeyHash Guard -> ByteString
filterPolicyPath signer =
    TextEncoding.encodeUtf8
        ("/v1/signers/" <> renderKeyHash signer <> "/filter")

entriesFilterPath
    :: KeyHash Guard
    -> Text
    -> Maybe [KeyHash Guard]
    -> ByteString
entriesFilterPath signer predicate allowlist =
    TextEncoding.encodeUtf8
        $ "/v1/entries?signer="
            <> renderKeyHash signer
            <> "&predicate="
            <> predicate
            <> foldMap
                ( ("&allowlist=" <>)
                    . Text.intercalate ","
                    . fmap renderKeyHash
                )
                allowlist

entriesDefaultFilterPath :: KeyHash Guard -> ByteString
entriesDefaultFilterPath signer =
    TextEncoding.encodeUtf8
        $ "/v1/entries?signer="
            <> renderKeyHash signer

entrySummaryJson :: Entry -> Value
entrySummaryJson entry@Entry{..} =
    object
        [ "entry_id" .= renderEntryId entryId
        , "required_signers" .= renderKeyHashes entryRequiredSigners
        , "witnesses" .= renderKeyHashes (entryWitnesses entry)
        , "missing" .= renderKeyHashes (entryMissingSigners entry)
        , "invalid_hereafter" .= renderSlot entryInvalidHereafter
        , "status" .= renderEntryStatus (entryWitnessStatus entry)
        ]

feeStatusJson
    :: Bool
    -> Bool
    -> Bool
    -> Bool
    -> Word64
    -> Integer
    -> Word
    -> Maybe Text
    -> Value
feeStatusJson observed confirmed sufficient ready paid required confirmations reason =
    object
        [ "observed" .= observed
        , "confirmed" .= confirmed
        , "sufficient" .= sufficient
        , "ready_to_publish" .= ready
        , "paid_lovelace" .= paid
        , "required_lovelace" .= required
        , "confirmations" .= confirmations
        , "reason" .= reason
        ]

policyBody :: FilterPolicy -> WitVKey Witness -> Value
policyBody policy witness =
    object
        [ "predicate" .= policyPredicateJson policy
        , "signature" .= witnessHexText witness
        ]

policyPredicateJson :: FilterPolicy -> Value
policyPredicateJson = \case
    RosterOpen ->
        object ["name" .= ("roster-open" :: Text)]
    TrustOrdered allowlist ->
        object
            [ "name" .= ("trust-ordered" :: Text)
            , "allowlist" .= fmap renderKeyHash (Set.toAscList allowlist)
            ]

witnessBody :: WitVKey Witness -> Value
witnessBody witness =
    object ["witness" .= witnessHexText witness]

witnessHexText :: WitVKey Witness -> Text
witnessHexText =
    TextEncoding.decodeUtf8
        . Base16.encode
        . serialize' (eraProtVerLow @ConwayEra)

testWitness :: Word -> ConwayTx -> WitVKey Witness
testWitness n tx =
    WitVKey (asWitness vk) (signedDSIGN sk bodyHash)
  where
    sk = testKey n
    vk = VKey (deriveVerKeyDSIGN sk)
    bodyHash = extractHash (hashAnnotated (tx ^. bodyTxL))

policyWitness :: Word -> FilterPolicy -> WitVKey Witness
policyWitness n policy =
    WitVKey (asWitness vk) (signedDSIGN sk (policyHash policy))
  where
    sk = testKey n
    vk = VKey (deriveVerKeyDSIGN sk)

-- Filter policies sign the ledger-typed hash of these documented
-- canonical bytes, matching the WitVKey witness machinery.
policyHash :: FilterPolicy -> Hash HASH EraIndependentTxBody
policyHash =
    Hash.castHash . Hash.hashWith @HASH id . canonicalFilterPolicyBytes

testTxForPolicy :: ConwayTx
testTxForPolicy =
    testTx (SJust (SlotNo 125)) requiredSigners

witnessSignerHash :: WitVKey Witness -> KeyHash Guard
witnessSignerHash (WitVKey vkey _) =
    case hashKey vkey of
        KeyHash h -> KeyHash h

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

renderAddr :: Addr -> Text
renderAddr addr =
    Bech32.encodeLenient hrp dataPart
  where
    hrp =
        either (error . show) id
            $ Bech32.humanReadablePartFromText "addr_test"
    dataPart = Bech32.dataPartFromBytes (serialiseAddr addr)

renderEntryId :: EntryId -> Text
renderEntryId (EntryId (TxId safeHash)) =
    TextEncoding.decodeUtf8
        $ Base16.encode
        $ hashToBytes
        $ extractHash safeHash

renderTxIn :: TxIn -> Text
renderTxIn (TxIn txId (TxIx ix)) =
    renderEntryId (EntryId txId) <> "#" <> Text.pack (show ix)

renderKeyHashes :: Set (KeyHash kr) -> [Text]
renderKeyHashes =
    fmap renderKeyHash . Set.toAscList

renderKeyHash :: KeyHash kr -> Text
renderKeyHash (KeyHash h) =
    TextEncoding.decodeUtf8 $ Base16.encode $ hashToBytes h

renderEntryStatus :: EntryStatus -> Text
renderEntryStatus = \case
    EntryCollecting -> "collecting"
    EntryReady -> "ready"
    EntrySubmitted -> "submitted"
    EntryExpired -> "expired"

renderSlot :: SlotNo -> Word64
renderSlot (SlotNo slot) =
    slot
