{-# LANGUAGE DataKinds #-}

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
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Address
    ( Addr (..)
    , serialiseAddr
    )
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
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)
import Cardano.Ledger.Keys
    ( KeyHash (..)
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
    ( OperatorSchedule (..)
    , PreflightResult (..)
    , PublishDeps (..)
    , bodyHashTagDatum
    )
import Cardano.Multisig.Server
    ( applicationWith
    , errorEnvelope
    )
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryId (..)
    , EntryStatus (..)
    , Store (..)
    , entryIdFromTx
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
import Data.Word (Word64, Word8)
import Lens.Micro ((&), (.~))
import Network.HTTP.Types
    ( hContentType
    , methodGet
    , methodPost
    , status200
    , status201
    , status402
    , status409
    , status422
    )
import Network.Wai
    ( defaultRequest
    , pathInfo
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

getJson :: ByteString -> MockDeps -> IO Value
getJson path deps = do
    response <- waiRequest methodGet path deps mempty
    simpleStatus response `shouldBe` status200
    case decode (simpleBody response) of
        Just value -> pure value
        Nothing -> do
            expectationFailure "expected valid JSON response"
            pure (object [])

postJson :: ByteString -> MockDeps -> Value -> IO SResponse
postJson path deps body =
    waiRequest methodPost path deps (encode body)

waiRequest
    :: ByteString
    -> ByteString
    -> MockDeps
    -> BL.ByteString
    -> IO SResponse
waiRequest method path deps body = do
    ref <- newIORef deps
    runSession
        ( srequest
            SRequest
                { simpleRequest =
                    defaultRequest
                        { requestMethod = method
                        , pathInfo =
                            filter (not . Text.null)
                                $ Text.splitOn "/" (TextEncoding.decodeUtf8 path)
                        , requestHeaders = [(hContentType, "application/json")]
                        }
                , simpleRequestBody = body
                }
        )
        (applicationWith "preprod" schedule (mockPublishDeps ref))

mockPublishDeps :: IORef MockDeps -> PublishDeps IO
mockPublishDeps ref =
    PublishDeps
        { pdReadTip = mdTip <$> readIORef ref
        , pdReadPayment = \_ -> PaymentReadResolved . mdPayment <$> readIORef ref
        , pdPreflight = \_ -> mdPreflight <$> readIORef ref
        , pdStore =
            Store
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
                , storeCollectWitnesses = \_ _ -> pure ()
                , storePutReceipt = \_ _ -> pure ()
                , storeLookupReceipt = \_ -> pure Nothing
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
