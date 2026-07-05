{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.Store
    ( Entry (..)
    , EntryId (..)
    , EntryStatus (..)
    , Receipt (..)
    , Store (..)
    , decodeEntry
    , decodeReceipt
    , encodeEntry
    , encodeReceipt
    , entryIdFromTx
    )
where

import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Binary
    ( Annotator
    , DecCBOR (..)
    , Decoder
    , EncCBOR
    , decodeFull'
    , decodeFullAnnotator
    , serialize'
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (TopTx, TxBody, TxWits)
import Cardano.Ledger.Hashes (hashAnnotated)
import Cardano.Ledger.Keys (KeyHash, KeyRole (Guard))
import Cardano.Ledger.TxIn (TxId (..), TxIn)
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Ledger (ConwayTx)
import Codec.CBOR.Decoding qualified as CBOR
import Codec.CBOR.Encoding qualified as CBOR
import Codec.CBOR.Read qualified as CBOR
import Codec.CBOR.Write qualified as CBOR
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Set (Set)
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX
    ( posixSecondsToUTCTime
    , utcTimeToPOSIXSeconds
    )
import Lens.Micro ((^.))

newtype EntryId = EntryId
    { unEntryId :: TxId
    }
    deriving stock (Eq, Ord, Show)

data EntryStatus
    = EntryCollecting
    | EntryReady
    | EntrySubmitted
    | EntryExpired
    deriving stock (Eq, Ord, Show)

data Receipt = Receipt
    { receiptTxId :: EntryId
    , receiptSubmittedAt :: UTCTime
    }
    deriving stock (Eq, Show)

data Entry = Entry
    { entryId :: EntryId
    , entryTx :: ConwayTx
    , entryRequiredSigners :: Set (KeyHash Guard)
    , entryCollectedWitnesses :: TxWits ConwayEra
    , entryInvalidHereafter :: SlotNo
    , entryFeePayment :: TxIn
    , entryStatus :: EntryStatus
    }
    deriving stock (Eq, Show)

data Store m = Store
    { storePutEntry :: Entry -> m ()
    , storeLookupEntry :: EntryId -> m (Maybe Entry)
    , storeCollectWitnesses :: EntryId -> TxWits ConwayEra -> m ()
    , storePutReceipt :: EntryId -> Receipt -> m ()
    , storeLookupReceipt :: EntryId -> m (Maybe Receipt)
    }

entryIdFromTx :: ConwayTx -> EntryId
entryIdFromTx tx =
    EntryId (TxId (hashAnnotated body))
  where
    body :: TxBody TopTx ConwayEra
    body = tx ^. bodyTxL

encodeEntry :: Entry -> ByteString
encodeEntry Entry{..} =
    encodeCBOR
        $ CBOR.encodeListLen 7
            <> CBOR.encodeBytes (encodeEntryId entryId)
            <> CBOR.encodeBytes (encodeTx entryTx)
            <> CBOR.encodeBytes (encodeLedger entryRequiredSigners)
            <> CBOR.encodeBytes (encodeTxWits entryCollectedWitnesses)
            <> CBOR.encodeBytes (encodeLedger entryInvalidHereafter)
            <> CBOR.encodeBytes (encodeLedger entryFeePayment)
            <> encodeEntryStatus entryStatus

decodeEntry :: ByteString -> Maybe Entry
decodeEntry =
    decodeCBOR $ do
        decodeListLenOf 7
        decodedEntryId <- decodeBytesWith decodeEntryId
        decodedEntryTx <- decodeBytesWith decodeTx
        decodedEntryRequiredSigners <- decodeBytesWith decodeLedger
        decodedEntryCollectedWitnesses <- decodeBytesWith decodeTxWits
        decodedEntryInvalidHereafter <- decodeBytesWith decodeLedger
        decodedEntryFeePayment <- decodeBytesWith decodeLedger
        decodedEntryStatus <- decodeEntryStatus
        pure
            Entry
                { entryId = decodedEntryId
                , entryTx = decodedEntryTx
                , entryRequiredSigners = decodedEntryRequiredSigners
                , entryCollectedWitnesses = decodedEntryCollectedWitnesses
                , entryInvalidHereafter = decodedEntryInvalidHereafter
                , entryFeePayment = decodedEntryFeePayment
                , entryStatus = decodedEntryStatus
                }

encodeReceipt :: Receipt -> ByteString
encodeReceipt Receipt{..} =
    encodeCBOR
        $ CBOR.encodeListLen 2
            <> CBOR.encodeBytes (encodeEntryId receiptTxId)
            <> CBOR.encodeInteger
                (floor (utcTimeToPOSIXSeconds receiptSubmittedAt))

decodeReceipt :: ByteString -> Maybe Receipt
decodeReceipt =
    decodeCBOR $ do
        decodeListLenOf 2
        decodedReceiptTxId <- decodeBytesWith decodeEntryId
        decodedReceiptSubmittedAt <-
            posixSecondsToUTCTime . fromInteger
                <$> CBOR.decodeInteger
        pure
            Receipt
                { receiptTxId = decodedReceiptTxId
                , receiptSubmittedAt = decodedReceiptSubmittedAt
                }

encodeEntryId :: EntryId -> ByteString
encodeEntryId = encodeLedger . unEntryId

decodeEntryId :: ByteString -> Maybe EntryId
decodeEntryId = fmap EntryId . decodeLedger

encodeTx :: ConwayTx -> ByteString
encodeTx =
    serialize' (eraProtVerLow @ConwayEra)

decodeTx :: ByteString -> Maybe ConwayTx
decodeTx =
    either (const Nothing) Just
        . decodeFullAnnotator
            (eraProtVerLow @ConwayEra)
            "ConwayTx"
            (decCBOR :: forall s. Decoder s (Annotator ConwayTx))
        . BL.fromStrict

encodeTxWits :: TxWits ConwayEra -> ByteString
encodeTxWits =
    serialize' (eraProtVerLow @ConwayEra)

decodeTxWits :: ByteString -> Maybe (TxWits ConwayEra)
decodeTxWits =
    either (const Nothing) Just
        . decodeFullAnnotator
            (eraProtVerLow @ConwayEra)
            "ConwayTxWits"
            (decCBOR :: forall s. Decoder s (Annotator (TxWits ConwayEra)))
        . BL.fromStrict

encodeLedger :: EncCBOR a => a -> ByteString
encodeLedger =
    serialize' (eraProtVerLow @ConwayEra)

decodeLedger :: DecCBOR a => ByteString -> Maybe a
decodeLedger =
    either (const Nothing) Just
        . decodeFull' (eraProtVerLow @ConwayEra)

encodeEntryStatus :: EntryStatus -> CBOR.Encoding
encodeEntryStatus =
    CBOR.encodeWord . \case
        EntryCollecting -> 0
        EntryReady -> 1
        EntrySubmitted -> 2
        EntryExpired -> 3

decodeEntryStatus :: CBOR.Decoder s EntryStatus
decodeEntryStatus =
    CBOR.decodeWord >>= \case
        0 -> pure EntryCollecting
        1 -> pure EntryReady
        2 -> pure EntrySubmitted
        3 -> pure EntryExpired
        n -> fail ("invalid EntryStatus tag " <> show n)

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
