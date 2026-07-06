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
import Cardano.Ledger.Api.Scripts.Data (Datum)
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
import Cardano.Ledger.Coin (Coin (..))
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
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.Chain
    ( PaymentConfirmation (..)
    , PaymentConfirmationEvidence (..)
    , PaymentReadResult (..)
    )
import Cardano.Multisig.Filter
    ( FilterPolicy (..)
    , canonicalFilterPolicyBytes
    )
import Cardano.Multisig.Publish
    ( OperatorSchedule (..)
    , PreflightResult (..)
    , PublishDeps (..)
    , bodyHashTagDatum
    )
import Cardano.Multisig.Server
    ( ServerDeps (..)
    , applicationWith
    , errorEnvelope
    )
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryId (..)
    , EntryStatus (..)
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

        it "maps insufficient fee failures to HTTP 402" $ do
            let tx = testTx (SJust (SlotNo 125)) requiredSigners
                deps =
                    happyDeps
                        { mdPayment =
                            payment tx 1_249 (bodyHashTagDatum (entryIdFromTx tx))
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
    , mdPayment :: PaymentConfirmation
    , mdPreflight :: PreflightResult
    , mdEntries :: Map EntryId Entry
    , mdReceipts :: Map EntryId Receipt
    , mdSignerFilters :: Map (KeyHash Guard) ByteString
    , mdSubmitResult :: Either Text ()
    , mdSubmitted :: [ConwayTx]
    , mdNow :: UTCTime
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
            , mdReceipts = mempty
            , mdSignerFilters = mempty
            , mdSubmitResult = Right ()
            , mdSubmitted = mempty
            , mdNow = receiptTime
            }

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
        }

mockPublishDeps :: IORef MockDeps -> PublishDeps IO
mockPublishDeps ref =
    PublishDeps
        { pdReadTip = mdTip <$> readIORef ref
        , pdReadPayment = \_ -> PaymentReadResolved . mdPayment <$> readIORef ref
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

txHexText :: ConwayTx -> Text
txHexText =
    TextEncoding.decodeUtf8
        . Base16.encode
        . serialize' (eraProtVerLow @ConwayEra)

entryPath :: EntryId -> ByteString
entryPath entryId =
    TextEncoding.encodeUtf8 ("/v1/entries/" <> renderEntryId entryId)

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
