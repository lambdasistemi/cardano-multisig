{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.Store.Columns
    ( Columns (..)
    , FeePaymentKey (..)
    , codecs
    )
where

import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Binary
    ( DecCBOR
    , EncCBOR
    , decodeFull'
    , serialize'
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Keys (KeyHash, KeyRole (Guard))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Multisig.Store (EntryId (..))
import Cardano.Multisig.Store.Codecs (entryIdCodec)
import Codec.CBOR.Decoding qualified as CBOR
import Codec.CBOR.Encoding qualified as CBOR
import Codec.CBOR.Read qualified as CBOR
import Codec.CBOR.Write qualified as CBOR
import Control.Lens (Prism', prism')
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Type.Equality ((:~:) (Refl))
import Database.KV.Transaction
    ( Codecs (..)
    , DMap
    , DSum ((:=>))
    , GCompare (..)
    , GEq (..)
    , GOrdering (..)
    , KV
    , fromList
    )

data Columns c where
    EntriesCol :: Columns (KV EntryId ByteString)
    ReceiptsCol :: Columns (KV EntryId ByteString)
    SignerFiltersCol :: Columns (KV (KeyHash Guard) ByteString)
    FeePaymentsCol :: Columns (KV FeePaymentKey ByteString)

data FeePaymentKey = FeePaymentKey EntryId TxIn
    deriving stock (Eq, Ord, Show)

instance GEq Columns where
    geq EntriesCol EntriesCol = Just Refl
    geq ReceiptsCol ReceiptsCol = Just Refl
    geq SignerFiltersCol SignerFiltersCol = Just Refl
    geq FeePaymentsCol FeePaymentsCol = Just Refl
    geq _ _ = Nothing

instance GCompare Columns where
    gcompare EntriesCol EntriesCol = GEQ
    gcompare ReceiptsCol ReceiptsCol = GEQ
    gcompare SignerFiltersCol SignerFiltersCol = GEQ
    gcompare FeePaymentsCol FeePaymentsCol = GEQ
    gcompare a b =
        case compare (columnRank a) (columnRank b) of
            LT -> GLT
            EQ -> error "gcompare: impossible unequal columns with same rank"
            GT -> GGT

codecs :: DMap Columns Codecs
codecs =
    fromList
        [ EntriesCol :=> bytesCodec
        , ReceiptsCol :=> bytesCodec
        , SignerFiltersCol :=> signerFilterCodec
        , FeePaymentsCol :=> feePaymentCodec
        ]
  where
    bytesCodec =
        Codecs
            { keyCodec = entryIdCodec
            , valueCodec = byteStringCodec
            }
    signerFilterCodec =
        Codecs
            { keyCodec = keyHashCodec
            , valueCodec = byteStringCodec
            }
    feePaymentCodec =
        Codecs
            { keyCodec = feePaymentKeyCodec
            , valueCodec = byteStringCodec
            }

columnRank :: Columns c -> Int
columnRank = \case
    EntriesCol -> 0
    ReceiptsCol -> 1
    SignerFiltersCol -> 2
    FeePaymentsCol -> 3

keyHashCodec :: Prism' ByteString (KeyHash Guard)
keyHashCodec =
    prism' ledgerEncode ledgerDecode

byteStringCodec :: Prism' ByteString ByteString
byteStringCodec =
    prism' id Just

feePaymentKeyCodec :: Prism' ByteString FeePaymentKey
feePaymentKeyCodec =
    prism' encodeFeePaymentKey decodeFeePaymentKey

encodeFeePaymentKey :: FeePaymentKey -> ByteString
encodeFeePaymentKey (FeePaymentKey bodyHash txIn) =
    encodeCBOR
        $ CBOR.encodeListLen 2
            <> CBOR.encodeBytes (ledgerEncode (unEntryId bodyHash))
            <> CBOR.encodeBytes (ledgerEncode txIn)

decodeFeePaymentKey :: ByteString -> Maybe FeePaymentKey
decodeFeePaymentKey =
    decodeCBOR $ do
        decodeListLenOf 2
        bodyHash <- decodeBytesWith (fmap EntryId . ledgerDecode)
        txIn <- decodeBytesWith ledgerDecode
        pure (FeePaymentKey bodyHash txIn)

ledgerEncode :: EncCBOR a => a -> ByteString
ledgerEncode =
    serialize' (eraProtVerLow @ConwayEra)

ledgerDecode :: DecCBOR a => ByteString -> Maybe a
ledgerDecode =
    either (const Nothing) Just
        . decodeFull' (eraProtVerLow @ConwayEra)

decodeBytesWith
    :: (ByteString -> Maybe a)
    -> CBOR.Decoder s a
decodeBytesWith decoder = do
    bytes <- CBOR.decodeBytes
    case decoder bytes of
        Just value -> pure value
        Nothing -> fail "invalid nested ledger value"

encodeCBOR :: CBOR.Encoding -> ByteString
encodeCBOR =
    BL.toStrict . CBOR.toLazyByteString

decodeCBOR
    :: (forall s. CBOR.Decoder s a)
    -> ByteString
    -> Maybe a
decodeCBOR decoder bs =
    case CBOR.deserialiseFromBytes decoder (BL.fromStrict bs) of
        Right (rest, value)
            | BL.null rest -> Just value
        _ -> Nothing

decodeListLenOf :: Int -> CBOR.Decoder s ()
decodeListLenOf expected = do
    actual <- CBOR.decodeListLen
    if actual == fromIntegral expected
        then pure ()
        else fail ("expected list length " <> show expected)
