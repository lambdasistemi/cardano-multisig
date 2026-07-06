{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.Server
    ( application
    , applicationWith
    , runServer
    , RuntimeConfig (..)
    , ServerDeps (..)
    , operatorSchedule
    , errorEnvelope
    , feeIndexerConfigFromRuntimeConfig
    , readRuntimeConfigWith
    , withServerBackgroundTasks
    ) where

-- \|
-- Module      : Cardano.Multisig.Server
-- Description : WAI application for the /v1 coordinator API
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr
    , serialiseAddr
    )
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , TxIx (..)
    )
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)
import Cardano.Ledger.Keys
    ( KeyHash (..)
    , KeyRole (Guard)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.Chain
    ( ChainSource (..)
    , N2cConfig (..)
    , PaymentReadResult (..)
    , chainSourceFromProvider
    , networkFromMagic
    , readPaymentConfirmation
    , withNodeProviderAndSubmitter
    )
import Cardano.Multisig.FeeIndexer
    ( FeeIndexerConfig (..)
    , FeeIndexerDeps (..)
    , runFeeIndexerSupervisor
    )
import Cardano.Multisig.Filter qualified as Filter
import Cardano.Multisig.Liveness
    ( EntryLiveness (..)
    , LivenessDeps (..)
    , entryLiveness
    , runLivenessMonitor
    )
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
    , Receipt (..)
    , Store (..)
    )
import Cardano.Multisig.Store.RocksDB (withRocksDBStore)
import Cardano.Multisig.Witness
    ( WitnessFailure (..)
    , assembleEntryTx
    , decodeVKeyWitnessHex
    , entryMissingSigners
    , entryWitnessStatus
    , entryWitnesses
    , verifyEntryWitness
    )
import Cardano.Node.Client.Provider
    ( Provider (..)
    , ledgerTipSlot
    )
import Cardano.Node.Client.Submitter qualified as NodeSubmitter
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Diff (decodeBech32Address)
import Cardano.Tx.Ledger (ConwayTx)
import Cardano.Tx.Validate.Cli
    ( VerdictStatus (..)
    , renderHuman
    , verdictStatus
    )
import Codec.Binary.Bech32 qualified as Bech32
import Control.Concurrent.Async (withAsync)
import Data.Aeson
    ( FromJSON (..)
    , Value
    , eitherDecode
    , encode
    , object
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock
    ( UTCTime
    , getCurrentTime
    )
import Data.Word (Word32, Word64)
import Network.HTTP.Types
    ( Status
    , hContentType
    , status200
    , status201
    , status204
    , status401
    , status402
    , status404
    , status409
    , status422
    , status501
    )
import Network.Wai
    ( Application
    , Response
    , pathInfo
    , queryString
    , requestMethod
    , responseLBS
    , strictRequestBody
    )
import Network.Wai.Handler.Warp (Port, run)
import Network.Wai.Middleware.Cors
    ( CorsResourcePolicy (..)
    , cors
    , simpleCorsResourcePolicy
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | A JSON error envelope,
-- @{ "error": { "code": code, "message": message } }@.
errorEnvelope :: String -> String -> Value
errorEnvelope code message =
    object
        [ "error"
            .= object
                [ "code" .= code
                , "message" .= message
                ]
        ]

-- | The operator discovery and fee-schedule document.
operatorSchedule :: String -> OperatorSchedule -> Value
operatorSchedule network schedule =
    object
        [ "network" .= network
        , "fee"
            .= object
                [ "base_lovelace" .= osBaseLovelace schedule
                , "rate_lovelace_per_slot"
                    .= osRateLovelacePerSlot schedule
                , "address" .= renderAddr schedule (osFeeAddress schedule)
                , "tag_field" .= ("body_hash_blake2b_256" :: Text)
                ]
        , "ttl_horizon_slots" .= osTtlHorizonSlots schedule
        , "roster_types" .= (["required_signers"] :: [Text])
        ]

healthy :: Value
healthy = object ["status" .= ("ok" :: String)]

jsonResponse :: Status -> Value -> Response
jsonResponse status body =
    responseLBS
        status
        [(hContentType, "application/json")]
        (encode body)

-- | Backwards-compatible static application wrapper for skeleton tests and
-- callers that do not inject publish dependencies.
application :: String -> Application
application network request respond =
    respond $ case (requestMethod request, pathInfo request) of
        ("GET", ["v1", "operator"]) ->
            jsonResponse status200 (legacyOperatorSchedule network)
        ("GET", ["v1", "health"]) ->
            jsonResponse status200 healthy
        ("GET", ["health"]) ->
            jsonResponse status200 healthy
        (_, "v1" : _) ->
            jsonResponse status501 notImplemented
        _ ->
            jsonResponse status404
                $ errorEnvelope "not_found" "no such route"

legacyOperatorSchedule :: String -> Value
legacyOperatorSchedule network =
    object
        [ "network" .= network
        , "fee"
            .= object
                [ "base_lovelace" .= (1000000 :: Int)
                , "rate_lovelace_per_slot" .= (12 :: Int)
                , "address" .= ("" :: String)
                , "tag_field" .= ("body_hash_blake2b_256" :: String)
                ]
        , "ttl_horizon_slots" .= (864000 :: Int)
        , "roster_types" .= (["required_signers"] :: [String])
        ]

-- | Dependency-injected WAI application used by tests and by 'runServer'.
data ServerDeps m = ServerDeps
    { sdPublish :: PublishDeps m
    , sdSubmitTx :: ConwayTx -> m (Either Text ())
    , sdNow :: m UTCTime
    , sdEntryLiveness :: Entry -> m EntryLiveness
    }

applicationWith
    :: String
    -> OperatorSchedule
    -> ServerDeps IO
    -> Application
applicationWith network schedule deps request respond =
    case (requestMethod request, pathInfo request) of
        ("GET", ["v1", "operator"]) ->
            respond $ jsonResponse status200 (operatorSchedule network schedule)
        ("GET", ["v1", "health"]) ->
            respond $ jsonResponse status200 healthy
        ("GET", ["health"]) ->
            respond $ jsonResponse status200 healthy
        ("POST", ["v1", "fee-quote"]) ->
            quoteHandler schedule (sdPublish deps) request respond
        ("POST", ["v1", "entries"]) ->
            entriesHandler schedule (sdPublish deps) request respond
        ("GET", ["v1", "entries"]) ->
            listEntriesHandler (sdPublish deps) request respond
        ("GET", ["v1", "entries", rawEntryId]) ->
            readEntryHandler deps rawEntryId request respond
        ("PUT", ["v1", "signers", rawSigner, "filter"]) ->
            signerFilterHandler (sdPublish deps) rawSigner request respond
        ("POST", ["v1", "entries", rawEntryId, "witnesses"]) ->
            witnessHandler (sdPublish deps) rawEntryId request respond
        ("POST", ["v1", "entries", rawEntryId, "submit"]) ->
            submitHandler deps rawEntryId request respond
        ("GET", ["v1", "entries", rawEntryId, "receipt"]) ->
            receiptHandler (sdPublish deps) rawEntryId request respond
        (_, "v1" : _) ->
            respond $ jsonResponse status501 notImplemented
        _ ->
            respond
                $ jsonResponse status404
                $ errorEnvelope "not_found" "no such route"

quoteHandler
    :: OperatorSchedule
    -> PublishDeps IO
    -> Application
quoteHandler schedule deps request respond = do
    body <- strictRequestBody request
    case eitherDecode body of
        Left err ->
            respond $ failureResponse status422 "invalid_request" err
        Right FeeQuoteBody{..} -> do
            tip <- pdReadTip deps
            respond $ case quoteTx schedule tip (TextEncoding.encodeUtf8 fqTransaction) of
                Left err ->
                    publishFailureResponse err
                Right quote ->
                    jsonResponse status200 (feeQuoteJson schedule quote)

entriesHandler
    :: OperatorSchedule
    -> PublishDeps IO
    -> Application
entriesHandler schedule deps request respond = do
    body <- strictRequestBody request
    case eitherDecode body of
        Left err ->
            respond $ failureResponse status422 "invalid_request" err
        Right PublishBody{..} ->
            case traverse parseTxIn pbFeePayment of
                Left err ->
                    respond $ failureResponse status422 "invalid_fee_payment" err
                Right feePayment -> do
                    result <-
                        publishEntry
                            schedule
                            deps
                            PublishRequest
                                { prTxCborHex =
                                    TextEncoding.encodeUtf8 pbTransaction
                                , prFeePayment = feePayment
                                }
                    respond $ case result of
                        Left err ->
                            publishFailureResponse err
                        Right entry ->
                            jsonResponse status201 (entryJson pbTransaction entry)

newtype FeeQuoteBody = FeeQuoteBody
    { fqTransaction :: Text
    }

instance FromJSON FeeQuoteBody where
    parseJSON =
        withObject "FeeQuoteRequest" $ \obj ->
            FeeQuoteBody <$> obj .: "transaction"

data PublishBody = PublishBody
    { pbTransaction :: Text
    , pbFeePayment :: Maybe Text
    }

instance FromJSON PublishBody where
    parseJSON =
        withObject "PublishRequest" $ \obj ->
            PublishBody
                <$> obj .: "transaction"
                <*> obj .:? "fee_payment"

newtype WitnessBody = WitnessBody
    { wbWitness :: Text
    }

instance FromJSON WitnessBody where
    parseJSON =
        withObject "WitnessRequest" $ \obj ->
            WitnessBody <$> obj .: "witness"

data FilterPredicateBody = FilterPredicateBody
    { fpbName :: Text
    , fpbAllowlist :: Maybe [Text]
    }

instance FromJSON FilterPredicateBody where
    parseJSON =
        withObject "FilterPredicate" $ \obj ->
            FilterPredicateBody
                <$> obj .: "name"
                <*> obj .:? "allowlist"

data FilterPolicyBody = FilterPolicyBody
    { fpbPredicate :: FilterPredicateBody
    , fpbSignature :: Text
    }

instance FromJSON FilterPolicyBody where
    parseJSON =
        withObject "FilterPolicyRequest" $ \obj ->
            FilterPolicyBody
                <$> obj .: "predicate"
                <*> obj .: "signature"

feeQuoteJson :: OperatorSchedule -> FeeQuote -> Value
feeQuoteJson schedule FeeQuote{..} =
    object
        [ "body_hash" .= renderEntryId qBodyHash
        , "required_fee_lovelace" .= qRequiredFeeLovelace
        , "fee_address" .= renderAddr schedule qFeeAddress
        , "tag" .= qTag
        , "invalid_hereafter" .= renderSlot qInvalidHereafter
        ]

entryJson :: Text -> Entry -> Value
entryJson =
    entryJsonWithTx

entryJsonWithTx :: Text -> Entry -> Value
entryJsonWithTx txHex entry@Entry{..} =
    object
        [ "entry_id" .= renderEntryId entryId
        , "transaction" .= txHex
        , "required_signers" .= renderKeyHashes entryRequiredSigners
        , "witnesses" .= renderKeyHashes (entryWitnesses entry)
        , "missing" .= renderKeyHashes (entryMissingSigners entry)
        , "invalid_hereafter" .= renderSlot entryInvalidHereafter
        , "status" .= renderEntryStatus (entryWitnessStatus entry)
        ]

storedEntryJsonWithLiveness :: EntryLiveness -> Entry -> Value
storedEntryJsonWithLiveness liveness entry =
    object
        [ "entry_id" .= renderEntryId (entryId entry)
        , "transaction" .= txHexText (entryTx entry)
        , "required_signers" .= renderKeyHashes (entryRequiredSigners entry)
        , "witnesses" .= renderKeyHashes (entryWitnesses entry)
        , "missing" .= renderKeyHashes (entryMissingSigners entry)
        , "invalid_hereafter" .= renderSlot (entryInvalidHereafter entry)
        , "status" .= renderEntryStatus (entryWitnessStatus entry)
        , "liveness" .= entryLivenessJson liveness
        ]

entryLivenessJson :: EntryLiveness -> Value
entryLivenessJson EntryLiveness{..} =
    object
        [ "inputs_unspent" .= elInputsUnspent
        , "phase1_ok" .= elPhase1Ok
        ]

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

witnessResultJson :: Entry -> Value
witnessResultJson entry =
    object
        [ "witnesses" .= renderKeyHashes (entryWitnesses entry)
        , "missing" .= renderKeyHashes (entryMissingSigners entry)
        , "status" .= renderEntryStatus (entryWitnessStatus entry)
        ]

receiptJson :: Receipt -> Value
receiptJson Receipt{..} =
    object
        [ "tx_id" .= renderEntryId receiptTxId
        , "submitted_at" .= receiptSubmittedAt
        ]

txHexText :: ConwayTx -> Text
txHexText =
    TextEncoding.decodeUtf8
        . Base16.encode
        . serialize' (eraProtVerLow @ConwayEra)

readEntryHandler
    :: ServerDeps IO
    -> Text
    -> Application
readEntryHandler deps rawEntryId _request respond =
    case parseEntryId rawEntryId of
        Left _ ->
            respond entryNotFound
        Right entryId -> do
            found <- storeLookupEntry store entryId
            case found of
                Nothing ->
                    respond entryNotFound
                Just entry -> do
                    liveness <- sdEntryLiveness deps entry
                    respond
                        $ jsonResponse status200
                        $ storedEntryJsonWithLiveness liveness entry
  where
    store = pdStore (sdPublish deps)

listEntriesHandler
    :: PublishDeps IO
    -> Application
listEntriesHandler deps request respond =
    case parseListFilterQuery (queryString request) of
        Left err ->
            respond $ failureResponse status422 "invalid_filter" (Text.unpack err)
        Right (signer, Nothing) -> do
            stored <- storeLookupSignerFilter store signer
            case stored
                >>= either (const Nothing) Just . Filter.decodeFilterPolicyBytes of
                Nothing ->
                    respond
                        $ failureResponse
                            status422
                            "invalid_filter"
                            "missing signer default filter policy"
                Just policy ->
                    respondEntries signer policy
        Right (signer, Just policy) ->
            respondEntries signer policy
  where
    store = pdStore deps
    respondEntries signer policy = do
        entries <- storeListEntries store
        respond
            $ jsonResponse status200
            $ object
                [ "entries"
                    .= fmap
                        entrySummaryJson
                        (Filter.filterEntries policy signer entries)
                ]

signerFilterHandler
    :: PublishDeps IO
    -> Text
    -> Application
signerFilterHandler deps rawSigner request respond =
    case Filter.parseKeyHash rawSigner of
        Left err ->
            respond $ failureResponse status422 "invalid_signer" (Text.unpack err)
        Right signer -> do
            body <- strictRequestBody request
            case eitherDecode body of
                Left err ->
                    respond $ failureResponse status422 "invalid_request" err
                Right FilterPolicyBody{..} ->
                    case filterPredicateFromBody fpbPredicate of
                        Left err ->
                            respond
                                $ failureResponse
                                    status422
                                    "invalid_filter"
                                    (Text.unpack err)
                        Right policy ->
                            case decodeVKeyWitnessHex
                                (TextEncoding.encodeUtf8 fpbSignature) of
                                Left{} ->
                                    respond unauthorizedFilter
                                Right witness
                                    | Filter.verifyFilterPolicyWitness
                                        signer
                                        policy
                                        witness -> do
                                        storePutSignerFilter
                                            (pdStore deps)
                                            signer
                                            (Filter.encodeFilterPolicyBytes policy)
                                        respond noContentResponse
                                    | otherwise ->
                                        respond unauthorizedFilter

witnessHandler
    :: PublishDeps IO
    -> Text
    -> Application
witnessHandler deps rawEntryId request respond =
    case parseEntryId rawEntryId of
        Left _ ->
            respond entryNotFound
        Right entryId -> do
            found <- storeLookupEntry (pdStore deps) entryId
            case found of
                Nothing ->
                    respond entryNotFound
                Just entry -> do
                    body <- strictRequestBody request
                    case eitherDecode body of
                        Left err ->
                            respond $ failureResponse status422 "invalid_request" err
                        Right WitnessBody{..} ->
                            case decodeVKeyWitnessHex (TextEncoding.encodeUtf8 wbWitness)
                                >>= verifyEntryWitness entry of
                                Left failure ->
                                    respond $ witnessFailureResponse failure
                                Right updated -> do
                                    storePutEntry (pdStore deps) updated
                                    respond
                                        $ jsonResponse
                                            status200
                                            (witnessResultJson updated)

submitHandler
    :: ServerDeps IO
    -> Text
    -> Application
submitHandler deps rawEntryId _request respond =
    case parseEntryId rawEntryId of
        Left _ ->
            respond entryNotFound
        Right entryId -> do
            found <- storeLookupEntry store entryId
            case found of
                Nothing ->
                    respond entryNotFound
                Just entry
                    | entryWitnessStatus entry /= EntryReady ->
                        respond
                            $ failureResponse
                                status409
                                "not_ready"
                                "entry is not ready to submit"
                    | otherwise -> do
                        let assembled = assembleEntryTx entry
                        submitted <- sdSubmitTx deps assembled
                        case submitted of
                            Left reason ->
                                respond
                                    $ failureResponse
                                        status422
                                        "submit_rejected"
                                        (Text.unpack reason)
                            Right () -> do
                                now <- sdNow deps
                                let receipt =
                                        Receipt
                                            { receiptTxId = entryId
                                            , receiptSubmittedAt = now
                                            }
                                    submittedEntry =
                                        entry{entryStatus = EntrySubmitted}
                                storePutReceipt store entryId receipt
                                storePutEntry store submittedEntry
                                respond $ jsonResponse status200 (receiptJson receipt)
  where
    store = pdStore (sdPublish deps)

receiptHandler
    :: PublishDeps IO
    -> Text
    -> Application
receiptHandler deps rawEntryId _request respond =
    case parseEntryId rawEntryId of
        Left _ ->
            respond entryNotFound
        Right entryId -> do
            found <- storeLookupReceipt (pdStore deps) entryId
            respond $ case found of
                Nothing ->
                    entryNotFound
                Just receipt ->
                    jsonResponse status200 (receiptJson receipt)

filterPredicateFromBody
    :: FilterPredicateBody
    -> Either Text Filter.FilterPolicy
filterPredicateFromBody FilterPredicateBody{..} =
    Filter.parseFilterPolicy fpbName fpbAllowlist

parseListFilterQuery
    :: [(ByteString, Maybe ByteString)]
    -> Either Text (KeyHash Guard, Maybe Filter.FilterPolicy)
parseListFilterQuery query = do
    signerText <- requireQueryParam "signer" query
    signer <- Filter.parseKeyHash signerText
    let policyName = optionalQueryParam "predicate" query
    policy <- case policyName of
        Nothing -> Right Nothing
        Just name -> do
            let allowlist =
                    filter (not . Text.null) . Text.splitOn ","
                        <$> optionalQueryParam "allowlist" query
            Just <$> Filter.parseFilterPolicy name allowlist
    Right (signer, policy)

requireQueryParam
    :: ByteString
    -> [(ByteString, Maybe ByteString)]
    -> Either Text Text
requireQueryParam name query =
    case optionalQueryParam name query of
        Just value
            | not (Text.null value) -> Right value
        _ -> Left ("missing query parameter: " <> decodeParamName name)

optionalQueryParam
    :: ByteString
    -> [(ByteString, Maybe ByteString)]
    -> Maybe Text
optionalQueryParam name query =
    case [value | (key, Just value) <- query, key == name] of
        [value] -> Just (TextEncoding.decodeUtf8 value)
        _ -> Nothing

decodeParamName :: ByteString -> Text
decodeParamName =
    TextEncoding.decodeUtf8

unauthorizedFilter :: Response
unauthorizedFilter =
    failureResponse
        status401
        "unauthorized"
        "filter policy signature is not authorized"

noContentResponse :: Response
noContentResponse =
    responseLBS status204 [] mempty

entryNotFound :: Response
entryNotFound =
    failureResponse status404 "not_found" "entry not found"

parseEntryId :: Text -> Either String EntryId
parseEntryId raw = do
    bytes <-
        case Base16.decode (TextEncoding.encodeUtf8 raw) of
            Right value -> Right value
            Left err -> Left ("invalid entry id base16: " <> err)
    txHash <-
        case hashFromBytes bytes of
            Just h -> Right h
            Nothing -> Left "entry id must be 32 bytes"
    pure (EntryId (TxId (unsafeMakeSafeHash txHash)))

witnessFailureResponse :: WitnessFailure -> Response
witnessFailureResponse = \case
    WitnessAlreadyCollected{} ->
        failureResponse status409 "duplicate" "witness already collected"
    WitnessInvalidHex reason ->
        failureResponse status422 "invalid_witness" (Text.unpack reason)
    WitnessDecodeFailed reason ->
        failureResponse status422 "invalid_witness" (Text.unpack reason)
    WitnessInvalidSignature ->
        failureResponse
            status422
            "invalid_witness"
            "invalid witness signature"
    WitnessSignerNotRequired{} ->
        failureResponse status422 "invalid_witness" "signer is not required"

publishFailureResponse :: PublishFailure -> Response
publishFailureResponse failure =
    case failure of
        PublishFeeRejected status ->
            feeFailureResponse status
        PublishDuplicate{} ->
            failureResponse status409 "duplicate" "entry already exists"
        PublishDecodeFailed reason ->
            failureResponse status422 "decode_failed" (Text.unpack reason)
        PublishTtlUnbounded ->
            failureResponse
                status422
                "ttl_unbounded"
                "transaction TTL is unbounded"
        PublishTtlOverHorizon{} ->
            failureResponse
                status422
                "ttl_over_horizon"
                "transaction TTL exceeds horizon"
        PublishPreflightFailed reason ->
            failureResponse status422 "preflight_failed" (Text.unpack reason)

failureResponse :: Status -> String -> String -> Response
failureResponse status code message =
    jsonResponse status (errorEnvelope code message)

failureResponseWithDetails
    :: Status -> Text -> Text -> Value -> Response
failureResponseWithDetails status code message details =
    jsonResponse status
        $ object
            [ "error"
                .= object
                    [ "code" .= code
                    , "message" .= message
                    , "details" .= details
                    ]
            ]

feeFailureResponse :: FeeStatus -> Response
feeFailureResponse status =
    failureResponseWithDetails
        status402
        (feeReasonCode (feeStatusReason status))
        (feeReasonMessage (feeStatusReason status))
        (feeFailureDetails status)

feeReasonCode :: FeeReason -> Text
feeReasonCode = \case
    FeeNotSeen -> "fee_not_seen"
    FeeUnconfirmed -> "fee_unconfirmed"
    FeeInsufficient -> "fee_insufficient"
    FeeMetadataMalformed -> "fee_metadata_malformed"

feeReasonMessage :: FeeReason -> Text
feeReasonMessage = \case
    FeeNotSeen -> "fee allowance was not seen"
    FeeUnconfirmed -> "fee allowance is not yet confirmed"
    FeeInsufficient -> "fee allowance is insufficient"
    FeeMetadataMalformed -> "fee payment metadata is malformed"

feeFailureDetails :: FeeStatus -> Value
feeFailureDetails status =
    case feeStatusReason status of
        FeeMetadataMalformed ->
            object
                [ "fee_payment"
                    .= maybe ("" :: Text) renderTxIn (feeStatusMalformedPayment status)
                ]
        FeeUnconfirmed ->
            object
                [ "required_depth" .= feeStatusRequiredDepth status
                , "paid_lovelace" .= feeStatusPaidLovelace status
                , "required_lovelace" .= feeStatusRequiredLovelace status
                ]
        FeeInsufficient ->
            commonDetails
        FeeNotSeen ->
            commonDetails
  where
    commonDetails =
        object
            [ "paid_lovelace" .= feeStatusPaidLovelace status
            , "required_lovelace" .= feeStatusRequiredLovelace status
            ]

notImplemented :: Value
notImplemented =
    errorEnvelope
        "not_implemented"
        "route not implemented in Milestone-1 foundations"

parseTxIn :: Text -> Either String TxIn
parseTxIn raw = do
    let (txIdText, ixWithHash) = Text.breakOn "#" raw
    ixText <-
        case Text.stripPrefix "#" ixWithHash of
            Just value
                | not (Text.null value) -> Right value
            _ -> Left "expected <txid>#<ix>"
    bytes <-
        case Base16.decode (TextEncoding.encodeUtf8 txIdText) of
            Right value -> Right value
            Left err -> Left ("invalid txid base16: " <> err)
    txHash <-
        case hashFromBytes bytes of
            Just h -> Right h
            Nothing -> Left "txid must be 32 bytes"
    ix <-
        case readMaybe (Text.unpack ixText) of
            Just n
                | n <= fromIntegral (maxBound :: Word32) ->
                    Right (TxIx (fromIntegral (n :: Integer)))
            _ -> Left "invalid tx input index"
    pure (TxIn (TxId (unsafeMakeSafeHash txHash)) ix)

renderAddr :: OperatorSchedule -> Addr -> Text
renderAddr schedule addr =
    Bech32.encodeLenient hrp dataPart
  where
    hrp =
        either (error . show) id
            $ Bech32.humanReadablePartFromText
            $ case osNetwork schedule of
                Mainnet -> "addr"
                Testnet -> "addr_test"
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

renderKeyHashes :: Set (KeyHash Guard) -> [Text]
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

-- | Run the service with a credential-free CORS policy on the given port.
--
-- Publish runtime configuration is read from:
-- FEE_ADDRESS, BASE_LOVELACE, RATE_LOVELACE_PER_SLOT, TTL_HORIZON_SLOTS,
-- CARDANO_NODE_SOCKET, CARDANO_NODE_MAGIC, and CARDANO_MULTISIG_STORE.
runServer :: Port -> String -> IO ()
runServer port network = do
    cfg <- readRuntimeConfig
    withNodeProviderAndSubmitter (rcN2c cfg) $ \provider submitter ->
        withRocksDBStore (rcStorePath cfg) $ \store -> do
            let chainSource = chainSourceFromProvider (osNetwork (rcSchedule cfg)) provider
                publishDeps =
                    PublishDeps
                        { pdReadTip =
                            ledgerTipSlot <$> queryLedgerSnapshot provider
                        , pdPreflight =
                            preflightResult chainSource
                        , pdStore = store
                        }
                deps =
                    ServerDeps
                        { sdPublish = publishDeps
                        , sdSubmitTx = submitWith submitter
                        , sdNow = getCurrentTime
                        , sdEntryLiveness = entryLiveness livenessDeps
                        }
                livenessDeps =
                    LivenessDeps
                        { ldReadTip =
                            ledgerTipSlot <$> queryLedgerSnapshot provider
                        , ldInputUnspent = inputUnspent provider
                        , ldPhase1Ok = phase1Ok chainSource
                        , ldStore = store
                        }
                feeIndexerDeps =
                    FeeIndexerDeps
                        { fidStore = store
                        , fidObserveTip = observeFeeIndexerTip
                        }
            withServerBackgroundTasks
                (runLivenessMonitor defaultLivenessIntervalMicros livenessDeps)
                ( runFeeIndexerSupervisor
                    (feeIndexerConfigFromRuntimeConfig cfg)
                    feeIndexerDeps
                )
                ( run port
                    $ cors (const $ Just policy)
                    $ applicationWith network (rcSchedule cfg) deps
                )
  where
    policy =
        simpleCorsResourcePolicy
            { corsMethods = ["GET", "POST", "PUT", "OPTIONS"]
            , corsRequestHeaders = ["Content-Type"]
            }

defaultLivenessIntervalMicros :: Int
defaultLivenessIntervalMicros =
    30 * 1_000_000

withServerBackgroundTasks :: IO () -> IO () -> IO a -> IO a
withServerBackgroundTasks liveness feeIndexer server =
    withAsync liveness
        $ const
        $ withAsync feeIndexer
        $ const server

observeFeeIndexerTip :: SlotNo -> IO ()
observeFeeIndexerTip _ =
    pure ()

inputUnspent :: Provider IO -> TxIn -> IO Bool
inputUnspent provider txIn =
    readPaymentConfirmation provider txIn >>= \case
        PaymentReadResolved{} -> pure True
        PaymentReadMissing{} -> pure False

phase1Ok :: ChainSource -> ConwayTx -> IO Bool
phase1Ok chainSource tx =
    preflightResult chainSource tx >>= \case
        PreflightAccepted -> pure True
        PreflightRejected{} -> pure False

preflightResult :: ChainSource -> ConwayTx -> IO PreflightResult
preflightResult chainSource tx = do
    verdict <- csPreflight chainSource tx
    pure $ case verdictStatus verdict of
        StructurallyClean -> PreflightAccepted
        StructuralFailure -> PreflightRejected (renderHuman verdict)
        MempoolShortCircuit -> PreflightRejected (renderHuman verdict)

submitWith
    :: NodeSubmitter.Submitter IO -> ConwayTx -> IO (Either Text ())
submitWith submitter tx = do
    NodeSubmitter.submitTx submitter tx >>= \case
        NodeSubmitter.Submitted _ ->
            pure (Right ())
        NodeSubmitter.Rejected reason ->
            pure (Left (TextEncoding.decodeUtf8With lenientDecode reason))

data RuntimeConfig = RuntimeConfig
    { rcN2c :: N2cConfig
    , rcStorePath :: FilePath
    , rcSchedule :: OperatorSchedule
    , rcFeeIndexerCheckpointDir :: FilePath
    , rcFeeIndexerByronEpochSlots :: Word64
    , rcFeeIndexerRetryDelayMicros :: Int
    }

readRuntimeConfig :: IO RuntimeConfig
readRuntimeConfig =
    readRuntimeConfigWith lookupEnv

readRuntimeConfigWith
    :: (String -> IO (Maybe String)) -> IO RuntimeConfig
readRuntimeConfigWith lookupValue = do
    socket <- requireEnvWith lookupValue "CARDANO_NODE_SOCKET"
    magic <- requireReadEnvWith lookupValue "CARDANO_NODE_MAGIC"
    storePath <- requireEnvWith lookupValue "CARDANO_MULTISIG_STORE"
    feeAddressText <-
        Text.pack <$> requireEnvWith lookupValue "FEE_ADDRESS"
    feeAddress <-
        case decodeBech32Address feeAddressText of
            Right addr -> pure addr
            Left err -> fail ("invalid FEE_ADDRESS: " <> err)
    base <- requireReadEnvWith lookupValue "BASE_LOVELACE"
    rate <- requireReadEnvWith lookupValue "RATE_LOVELACE_PER_SLOT"
    horizon <- requireReadEnvWith lookupValue "TTL_HORIZON_SLOTS"
    checkpointDir <-
        optionalEnvWith
            lookupValue
            "FEE_INDEXER_CHECKPOINT_DIR"
            (storePath <> "-fee-indexer")
    byronEpochSlots <-
        optionalReadEnvWith
            lookupValue
            "FEE_INDEXER_BYRON_EPOCH_SLOTS"
            21_600
    retryDelayMicros <-
        optionalReadEnvWith
            lookupValue
            "FEE_INDEXER_RETRY_DELAY_MICROS"
            30_000_000
    let n2c = N2cConfig{n2cSocket = socket, n2cMagic = magic}
        schedule =
            OperatorSchedule
                { osNetwork = networkFromMagic (NetworkMagic magic)
                , osFeeAddress = feeAddress
                , osBaseLovelace = base
                , osRateLovelacePerSlot = rate
                , osTtlHorizonSlots = horizon
                }
    pure
        RuntimeConfig
            { rcN2c = n2c
            , rcStorePath = storePath
            , rcSchedule = schedule
            , rcFeeIndexerCheckpointDir = checkpointDir
            , rcFeeIndexerByronEpochSlots = byronEpochSlots
            , rcFeeIndexerRetryDelayMicros = retryDelayMicros
            }

feeIndexerConfigFromRuntimeConfig :: RuntimeConfig -> FeeIndexerConfig
feeIndexerConfigFromRuntimeConfig cfg =
    FeeIndexerConfig
        { ficSocketPath = n2cSocket (rcN2c cfg)
        , ficNetworkMagic = n2cMagic (rcN2c cfg)
        , ficByronEpochSlots = rcFeeIndexerByronEpochSlots cfg
        , ficFeeAddress = osFeeAddress (rcSchedule cfg)
        , ficCheckpointDir = rcFeeIndexerCheckpointDir cfg
        , ficRetryDelayMicros = rcFeeIndexerRetryDelayMicros cfg
        }

requireEnvWith :: (String -> IO (Maybe String)) -> String -> IO String
requireEnvWith lookupValue name = do
    value <- lookupValue name
    case value of
        Just v
            | not (null v) -> pure v
        _ -> fail ("missing required environment variable " <> name)

requireReadEnvWith
    :: Read a => (String -> IO (Maybe String)) -> String -> IO a
requireReadEnvWith lookupValue name = do
    raw <- requireEnvWith lookupValue name
    case readMaybe raw of
        Just value -> pure value
        Nothing -> fail ("invalid numeric environment variable " <> name)

optionalEnvWith
    :: (String -> IO (Maybe String))
    -> String
    -> String
    -> IO String
optionalEnvWith lookupValue name fallback = do
    value <- lookupValue name
    pure $ case value of
        Just v | not (null v) -> v
        _ -> fallback

optionalReadEnvWith
    :: Read a
    => (String -> IO (Maybe String))
    -> String
    -> a
    -> IO a
optionalReadEnvWith lookupValue name fallback = do
    value <- lookupValue name
    case value of
        Just raw
            | not (null raw) ->
                case readMaybe raw of
                    Just parsed -> pure parsed
                    Nothing -> fail ("invalid numeric environment variable " <> name)
        _ -> pure fallback
