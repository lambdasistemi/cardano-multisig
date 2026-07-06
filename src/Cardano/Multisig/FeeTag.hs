module Cardano.Multisig.FeeTag
    ( BodyHash
    , FeeMetadata
    , decodeFeeTag
    , encodeFeeTag
    , feeTagBodyHashKey
    , feeTagLabel
    ) where

-- \|
-- Module      : Cardano.Multisig.FeeTag
-- Description : Fee-payment metadata tag codec
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0
--
-- This module pins the protocol metadata shape used to associate a fee
-- payment with a multisig transaction body hash.

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)
import Cardano.Ledger.Shelley.TxAuxData (Metadatum (Map, S))
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Multisig.Store (EntryId (..))
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Char (isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)

-- | Transaction body hash type used by fee metadata.
type BodyHash = EntryId

-- | Ledger metadata map used for fee-tag encoding.
type FeeMetadata = Map Word64 Metadatum

-- | Protocol-wide fee-tag metadata label.
feeTagLabel :: Word64
feeTagLabel = 9721

-- | Fee-tag metadata key carrying the body hash.
feeTagBodyHashKey :: Text
feeTagBodyHashKey = "body_hash"

-- | Encode a transaction body hash as fee-tag metadata.
encodeFeeTag :: BodyHash -> FeeMetadata
encodeFeeTag bodyHash =
    Map.singleton
        feeTagLabel
        (Map [(S feeTagBodyHashKey, S (renderBodyHash bodyHash))])

-- | Decode fee-tag metadata, rejecting malformed tag values.
decodeFeeTag :: FeeMetadata -> Maybe BodyHash
decodeFeeTag metadata = do
    value <- Map.lookup feeTagLabel metadata
    case value of
        Map [(S key, S bodyHashText)]
            | key == feeTagBodyHashKey -> parseBodyHash bodyHashText
        _ -> Nothing

renderBodyHash :: BodyHash -> Text
renderBodyHash (EntryId (TxId safeHash)) =
    TextEncoding.decodeUtf8
        $ Base16.encode
        $ hashToBytes
        $ extractHash safeHash

parseBodyHash :: Text -> Maybe BodyHash
parseBodyHash raw = do
    unless
        (Text.length raw == 64 && Text.all isLowerHex raw)
        Nothing
    bytes <-
        case Base16.decode (TextEncoding.encodeUtf8 raw) of
            Right value -> Just value
            Left _ -> Nothing
    unless (BS.length bytes == 32) Nothing
    txHash <- hashFromBytes bytes
    pure (EntryId (TxId (unsafeMakeSafeHash txHash)))

isLowerHex :: Char -> Bool
isLowerHex c =
    isDigit c || ('a' <= c && c <= 'f')
