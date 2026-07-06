{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.Server
    ( application
    , applicationWith
    , runServer
    , operatorSchedule
    , errorEnvelope
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
    , networkFromMagic
    , readPaymentConfirmation
    , withNodeChainSource
    , withNodeProvider
    )
import Cardano.Multisig.Publish
    ( FeeQuote (..)
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
    , Store (..)
    )
import Cardano.Multisig.Store.RocksDB (withRocksDBStore)
import Cardano.Multisig.Witness
    ( WitnessFailure (..)
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
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Diff (decodeBech32Address)
import Cardano.Tx.Ledger (ConwayTx)
import Cardano.Tx.Validate.Cli
    ( VerdictStatus (..)
    , renderHuman
    , verdictStatus
    )
import Codec.Binary.Bech32 qualified as Bech32
import Data.Aeson
    ( FromJSON (..)
    , Value
    , eitherDecode
    , encode
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.ByteString.Base16 qualified as Base16
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word32, Word64)
import Network.HTTP.Types
    ( Status
    , hContentType
    , status200
    , status201
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
applicationWith
    :: String
    -> OperatorSchedule
    -> PublishDeps IO
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
            quoteHandler schedule deps request respond
        ("POST", ["v1", "entries"]) ->
            entriesHandler schedule deps request respond
        ("GET", ["v1", "entries", rawEntryId]) ->
            readEntryHandler deps rawEntryId request respond
        ("POST", ["v1", "entries", rawEntryId, "witnesses"]) ->
            witnessHandler deps rawEntryId request respond
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
            case parseTxIn pbFeePayment of
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
    , pbFeePayment :: Text
    }

instance FromJSON PublishBody where
    parseJSON =
        withObject "PublishRequest" $ \obj ->
            PublishBody
                <$> obj .: "transaction"
                <*> obj .: "fee_payment"

newtype WitnessBody = WitnessBody
    { wbWitness :: Text
    }

instance FromJSON WitnessBody where
    parseJSON =
        withObject "WitnessRequest" $ \obj ->
            WitnessBody <$> obj .: "witness"

feeQuoteJson :: OperatorSchedule -> FeeQuote -> Value
feeQuoteJson schedule FeeQuote{..} =
    object
        [ "body_hash" .= renderEntryId qBodyHash
        , "required_fee_lovelace" .= qRequiredFeeLovelace
        , "fee_address" .= renderAddr schedule qFeeAddress
        , "tag" .= renderEntryId qBodyHash
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

storedEntryJson :: Entry -> Value
storedEntryJson entry =
    entryJsonWithTx (txHexText (entryTx entry)) entry

witnessResultJson :: Entry -> Value
witnessResultJson entry =
    object
        [ "witnesses" .= renderKeyHashes (entryWitnesses entry)
        , "missing" .= renderKeyHashes (entryMissingSigners entry)
        , "status" .= renderEntryStatus (entryWitnessStatus entry)
        ]

txHexText :: ConwayTx -> Text
txHexText =
    TextEncoding.decodeUtf8
        . Base16.encode
        . serialize' (eraProtVerLow @ConwayEra)

readEntryHandler
    :: PublishDeps IO
    -> Text
    -> Application
readEntryHandler deps rawEntryId _request respond =
    case parseEntryId rawEntryId of
        Left _ ->
            respond entryNotFound
        Right entryId -> do
            found <- storeLookupEntry (pdStore deps) entryId
            respond $ case found of
                Nothing ->
                    entryNotFound
                Just entry ->
                    jsonResponse status200 (storedEntryJson entry)

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
        PublishFeeMissing ->
            failureResponse status402 "fee_missing" "fee payment not found"
        PublishFeeWrongAddress ->
            failureResponse
                status402
                "fee_wrong_address"
                "fee paid to wrong address"
        PublishFeeTagMismatch ->
            failureResponse
                status402
                "fee_tag_mismatch"
                "fee tag does not match body hash"
        PublishFeeInsufficient{} ->
            failureResponse
                status402
                "fee_insufficient"
                "fee payment is insufficient"
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
    withNodeProvider (rcN2c cfg) $ \provider ->
        withNodeChainSource (rcN2c cfg) $ \chainSource ->
            withRocksDBStore (rcStorePath cfg) $ \store -> do
                let deps =
                        PublishDeps
                            { pdReadTip =
                                ledgerTipSlot <$> queryLedgerSnapshot provider
                            , pdReadPayment = readPaymentConfirmation provider
                            , pdPreflight =
                                preflightResult chainSource
                            , pdStore = store
                            }
                run port
                    $ cors (const $ Just policy)
                    $ applicationWith network (rcSchedule cfg) deps
  where
    policy =
        simpleCorsResourcePolicy
            { corsMethods = ["GET", "POST", "PUT", "OPTIONS"]
            , corsRequestHeaders = ["Content-Type"]
            }

preflightResult :: ChainSource -> ConwayTx -> IO PreflightResult
preflightResult chainSource tx = do
    verdict <- csPreflight chainSource tx
    pure $ case verdictStatus verdict of
        StructurallyClean -> PreflightAccepted
        StructuralFailure -> PreflightRejected (renderHuman verdict)
        MempoolShortCircuit -> PreflightRejected (renderHuman verdict)

data RuntimeConfig = RuntimeConfig
    { rcN2c :: N2cConfig
    , rcStorePath :: FilePath
    , rcSchedule :: OperatorSchedule
    }

readRuntimeConfig :: IO RuntimeConfig
readRuntimeConfig = do
    socket <- requireEnv "CARDANO_NODE_SOCKET"
    magic <- requireReadEnv "CARDANO_NODE_MAGIC"
    storePath <- requireEnv "CARDANO_MULTISIG_STORE"
    feeAddressText <- Text.pack <$> requireEnv "FEE_ADDRESS"
    feeAddress <-
        case decodeBech32Address feeAddressText of
            Right addr -> pure addr
            Left err -> fail ("invalid FEE_ADDRESS: " <> err)
    base <- requireReadEnv "BASE_LOVELACE"
    rate <- requireReadEnv "RATE_LOVELACE_PER_SLOT"
    horizon <- requireReadEnv "TTL_HORIZON_SLOTS"
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
            }

requireEnv :: String -> IO String
requireEnv name = do
    value <- lookupEnv name
    case value of
        Just v
            | not (null v) -> pure v
        _ -> fail ("missing required environment variable " <> name)

requireReadEnv :: Read a => String -> IO a
requireReadEnv name = do
    raw <- requireEnv name
    case readMaybe raw of
        Just value -> pure value
        Nothing -> fail ("invalid numeric environment variable " <> name)
