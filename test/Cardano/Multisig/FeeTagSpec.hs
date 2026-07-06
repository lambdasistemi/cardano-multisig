{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.FeeTagSpec
    ( spec
    ) where

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Shelley.TxAuxData (Metadatum (I, Map, S))
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Multisig.FeeTag
    ( BodyHash
    , FeeMetadata
    , decodeFeeTag
    , encodeFeeTag
    , feeTagBodyHashKey
    , feeTagLabel
    )
import Cardano.Multisig.Store (EntryId (..))
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64, Word8)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.QuickCheck
    ( Gen
    , Property
    , chooseAny
    , forAll
    , property
    , vectorOf
    , (===)
    )

spec :: Spec
spec =
    describe "Cardano.Multisig.FeeTag" $ do
        it "roundtrips generated body hashes"
            $ property propRoundtrip

        it "ignores unrelated top-level metadata labels" $ do
            decodeFeeTag
                ( metadata
                    [ (1, S "operator memo")
                    , (feeTagLabel, validFeeTagValue sampleBodyHashText)
                    ]
                )
                `shouldBe` Just sampleBodyHash

        it "rejects malformed fee tag metadata" $ do
            let malformed =
                    [ metadata []
                    , metadata [(feeTagLabel + 1, validFeeTagValue sampleBodyHashText)]
                    , tagged (validFeeTagValue (Text.replicate 64 "g"))
                    , tagged (validFeeTagValue (Text.replicate 63 "0"))
                    , tagged
                        ( validFeeTagValue
                            "000000000000000000000000000000000000000000000000000000000000002A"
                        )
                    , tagged (Map [(S "tag", S sampleBodyHashText)])
                    , tagged (Map [(S feeTagBodyHashKey, I 0)])
                    , tagged
                        ( Map
                            [ (S feeTagBodyHashKey, S sampleBodyHashText)
                            , (S "extra", S "ignored")
                            ]
                        )
                    ]
            fmap decodeFeeTag malformed
                `shouldBe` replicate (length malformed) Nothing

        it "matches the real cardano-cli no-schema metadata CBOR fixture" $ do
            -- Fixture provenance:
            -- cardano-cli 11.0.0.0 latest transaction build-raw
            --   --tx-in 000...000#0 --fee 0
            --   --json-metadata-no-schema
            --   --metadata-json-file meta.json --out-file tx.body
            --
            -- meta.json was:
            -- { "9721": { "body_hash": "<sampleBodyHashText>" } }
            --
            -- The fixture is the inner metadata map bytes from tx.body's
            -- auxiliary data, excluding the transaction and aux-data wrapper.
            golden <-
                BS.readFile "test/fixtures/fee-tag/metadata-no-schema.cbor"
            serialiseMetadata (encodeFeeTag sampleBodyHash) `shouldBe` golden

propRoundtrip :: Property
propRoundtrip =
    forAll genBodyHash $ \bodyHash ->
        decodeFeeTag (encodeFeeTag bodyHash) === Just bodyHash

genBodyHash :: Gen BodyHash
genBodyHash =
    mkBodyHash <$> vectorOf 32 chooseAny

sampleBodyHash :: BodyHash
sampleBodyHash =
    mkBodyHash (replicate 31 0 ++ [42])

sampleBodyHashText :: Text
sampleBodyHashText =
    Text.replicate 62 "0" <> "2a"

tagged :: Metadatum -> FeeMetadata
tagged value =
    metadata [(feeTagLabel, value)]

metadata :: [(Word64, Metadatum)] -> FeeMetadata
metadata =
    Map.fromList

validFeeTagValue :: Text -> Metadatum
validFeeTagValue bodyHashText =
    Map [(S feeTagBodyHashKey, S bodyHashText)]

serialiseMetadata :: FeeMetadata -> BS.ByteString
serialiseMetadata =
    serialize' (eraProtVerLow @ConwayEra)

mkBodyHash :: [Word8] -> BodyHash
mkBodyHash bytes =
    case hashFromBytes (BS.pack bytes) of
        Just h -> EntryId (TxId (unsafeMakeSafeHash h))
        Nothing -> error "mkBodyHash: invalid hash length"
