{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.Publish
    ( FeeQuote (..)
    , OperatorSchedule (..)
    , PreflightResult (..)
    , PublishDeps (..)
    , PublishFailure (..)
    , PublishRequest (..)
    , bodyHashTagDatum
    , publishEntry
    , quoteTx
    )
where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body
    ( reqSignerHashesTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.BaseTypes (Network, StrictMaybe (..))
import Cardano.Ledger.Binary
    ( Annotator
    , DecCBOR (..)
    , Decoder
    , decodeFullAnnotator
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.Plutus.Data
    ( Data (Data)
    , dataToBinaryData
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn)
import Cardano.Multisig.Chain
    ( PaymentConfirmation (..)
    , PaymentReadResult (..)
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
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Lens.Micro ((^.))
import PlutusLedgerApi.V1 qualified as Plutus

data OperatorSchedule = OperatorSchedule
    { osNetwork :: Network
    , osFeeAddress :: Addr
    , osBaseLovelace :: Integer
    , osRateLovelacePerSlot :: Integer
    , osTtlHorizonSlots :: Word64
    }
    deriving stock (Eq, Show)

data FeeQuote = FeeQuote
    { qBodyHash :: EntryId
    , qRequiredFeeLovelace :: Integer
    , qFeeAddress :: Addr
    , qTag :: Datum ConwayEra
    , qInvalidHereafter :: SlotNo
    }
    deriving stock (Eq, Show)

data PublishRequest = PublishRequest
    { prTxCborHex :: ByteString
    , prFeePayment :: TxIn
    }
    deriving stock (Eq, Show)

data PreflightResult
    = PreflightAccepted
    | PreflightRejected Text
    deriving stock (Eq, Show)

data PublishDeps m = PublishDeps
    { pdReadTip :: m SlotNo
    , pdReadPayment :: TxIn -> m PaymentReadResult
    , pdPreflight :: ConwayTx -> m PreflightResult
    , pdStore :: Store m
    }

data PublishFailure
    = PublishDecodeFailed Text
    | PublishTtlUnbounded
    | PublishTtlOverHorizon
        { pfInvalidHereafter :: SlotNo
        , pfHorizon :: SlotNo
        }
    | PublishFeeMissing
    | PublishFeeWrongAddress
    | PublishFeeTagMismatch
    | PublishFeeInsufficient
        { pfRequiredLovelace :: Integer
        , pfPaidLovelace :: Integer
        }
    | PublishPreflightFailed Text
    | PublishDuplicate EntryId
    deriving stock (Eq, Show)

quoteTx
    :: OperatorSchedule
    -> SlotNo
    -> ByteString
    -> Either PublishFailure FeeQuote
quoteTx schedule tip txHex = do
    tx <- decodeTxHex txHex
    invalidHereafter <- txInvalidHereafter tx
    let bodyHash = entryIdFromTx tx
    pure
        FeeQuote
            { qBodyHash = bodyHash
            , qRequiredFeeLovelace =
                requiredFee schedule tip invalidHereafter
            , qFeeAddress = osFeeAddress schedule
            , qTag = bodyHashTagDatum bodyHash
            , qInvalidHereafter = invalidHereafter
            }

publishEntry
    :: Monad m
    => OperatorSchedule
    -> PublishDeps m
    -> PublishRequest
    -> m (Either PublishFailure Entry)
publishEntry schedule deps request =
    case decodeTxHex (prTxCborHex request) of
        Left err -> pure (Left err)
        Right tx -> do
            tip <- pdReadTip deps
            case quoteFromTx schedule tip tx of
                Left err -> pure (Left err)
                Right quote -> do
                    payment <-
                        pdReadPayment deps (prFeePayment request)
                    case verifyPayment schedule quote payment of
                        Left err -> pure (Left err)
                        Right () -> do
                            preflight <- pdPreflight deps tx
                            case preflight of
                                PreflightRejected reason ->
                                    pure
                                        ( Left
                                            (PublishPreflightFailed reason)
                                        )
                                PreflightAccepted ->
                                    enforceHorizonAndPersist
                                        schedule
                                        deps
                                        tx
                                        quote
                                        tip
                                        request

bodyHashTagDatum :: EntryId -> Datum ConwayEra
bodyHashTagDatum (EntryId (TxId safeHash)) =
    Datum
        $ dataToBinaryData
        $ Data
        $ Plutus.B
        $ hashToBytes (extractHash safeHash)

decodeTxHex :: ByteString -> Either PublishFailure ConwayTx
decodeTxHex txHex = do
    raw <-
        case Base16.decode (stripWhitespace txHex) of
            Right bytes -> Right bytes
            Left err ->
                Left
                    ( PublishDecodeFailed
                        ("invalid base16 transaction: " <> Text.pack err)
                    )
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "ConwayTx"
        (decCBOR :: forall s. Decoder s (Annotator ConwayTx))
        (BL.fromStrict raw) of
        Right tx -> Right tx
        Left err ->
            Left
                ( PublishDecodeFailed
                    ("invalid Conway transaction CBOR: " <> Text.pack (show err))
                )

stripWhitespace :: ByteString -> ByteString
stripWhitespace =
    BS8.filter (not . isSpace)

quoteFromTx
    :: OperatorSchedule
    -> SlotNo
    -> ConwayTx
    -> Either PublishFailure FeeQuote
quoteFromTx schedule tip tx = do
    invalidHereafter <- txInvalidHereafter tx
    let bodyHash = entryIdFromTx tx
    pure
        FeeQuote
            { qBodyHash = bodyHash
            , qRequiredFeeLovelace =
                requiredFee schedule tip invalidHereafter
            , qFeeAddress = osFeeAddress schedule
            , qTag = bodyHashTagDatum bodyHash
            , qInvalidHereafter = invalidHereafter
            }

txInvalidHereafter :: ConwayTx -> Either PublishFailure SlotNo
txInvalidHereafter tx =
    case tx ^. bodyTxL . vldtTxBodyL of
        ValidityInterval _ (SJust slot) -> Right slot
        ValidityInterval _ SNothing -> Left PublishTtlUnbounded

requiredFee :: OperatorSchedule -> SlotNo -> SlotNo -> Integer
requiredFee schedule (SlotNo tip) (SlotNo invalidHereafter) =
    osBaseLovelace schedule
        + osRateLovelacePerSlot schedule
            * max 0 (fromIntegral invalidHereafter - fromIntegral tip)

verifyPayment
    :: OperatorSchedule
    -> FeeQuote
    -> PaymentReadResult
    -> Either PublishFailure ()
verifyPayment _schedule quote = \case
    PaymentReadMissing{} -> Left PublishFeeMissing
    PaymentReadResolved confirmation
        | pcAddress confirmation /= qFeeAddress quote ->
            Left PublishFeeWrongAddress
        | pcDatum confirmation /= qTag quote ->
            Left PublishFeeTagMismatch
        | paid < qRequiredFeeLovelace quote ->
            Left
                PublishFeeInsufficient
                    { pfRequiredLovelace = qRequiredFeeLovelace quote
                    , pfPaidLovelace = paid
                    }
        | otherwise -> Right ()
      where
        paid = lovelaceOf (pcValue confirmation)

lovelaceOf :: MaryValue -> Integer
lovelaceOf (MaryValue (Coin lovelace) _) =
    lovelace

enforceHorizonAndPersist
    :: Monad m
    => OperatorSchedule
    -> PublishDeps m
    -> ConwayTx
    -> FeeQuote
    -> SlotNo
    -> PublishRequest
    -> m (Either PublishFailure Entry)
enforceHorizonAndPersist schedule deps tx quote tip request = do
    let invalidHereafter = qInvalidHereafter quote
        horizon = horizonSlot schedule tip
    if invalidHereafter > horizon
        then
            pure
                ( Left
                    PublishTtlOverHorizon
                        { pfInvalidHereafter = invalidHereafter
                        , pfHorizon = horizon
                        }
                )
        else do
            existing <-
                storeLookupEntry (pdStore deps) (qBodyHash quote)
            case existing of
                Just _ ->
                    pure (Left (PublishDuplicate (qBodyHash quote)))
                Nothing -> do
                    let entry = buildEntry tx quote request
                    storePutEntry (pdStore deps) entry
                    pure (Right entry)

horizonSlot :: OperatorSchedule -> SlotNo -> SlotNo
horizonSlot schedule (SlotNo tip) =
    SlotNo (tip + osTtlHorizonSlots schedule)

buildEntry :: ConwayTx -> FeeQuote -> PublishRequest -> Entry
buildEntry tx quote request =
    Entry
        { entryId = qBodyHash quote
        , entryTx = tx
        , entryRequiredSigners =
            tx ^. bodyTxL . reqSignerHashesTxBodyL
        , entryCollectedWitnesses = mempty
        , entryInvalidHereafter = qInvalidHereafter quote
        , entryFeePayment = prFeePayment request
        , entryStatus = EntryCollecting
        }
