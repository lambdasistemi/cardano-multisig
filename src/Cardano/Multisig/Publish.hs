{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.Publish
    ( FeeReason (..)
    , FeeQuote (..)
    , FeeStatus (..)
    , OperatorSchedule (..)
    , PreflightResult (..)
    , PublishDeps (..)
    , PublishFailure (..)
    , PublishRequest (..)
    , publishEntry
    , quoteTx
    )
where

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body
    ( reqSignerHashesTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.BaseTypes
    ( Network
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Binary
    ( Annotator
    , DecCBOR (..)
    , Decoder
    , decodeFullAnnotator
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryId (..)
    , EntryStatus (..)
    , FeeAllowance (..)
    , MalformedFeePayment (..)
    , Store (..)
    , entryIdFromTx
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Char (isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import Lens.Micro ((^.))

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
    , qTag :: Text
    , qInvalidHereafter :: SlotNo
    }
    deriving stock (Eq, Show)

data PublishRequest = PublishRequest
    { prTxCborHex :: ByteString
    , prFeePayment :: Maybe TxIn
    }
    deriving stock (Eq, Show)

data PreflightResult
    = PreflightAccepted
    | PreflightRejected Text
    deriving stock (Eq, Show)

data PublishDeps m = PublishDeps
    { pdReadTip :: m SlotNo
    , pdPreflight :: ConwayTx -> m PreflightResult
    , pdStore :: Store m
    }

data FeeReason
    = FeeNotSeen
    | FeeUnconfirmed
    | FeeInsufficient
    | FeeMetadataMalformed
    deriving stock (Eq, Show)

data FeeStatus = FeeStatus
    { feeStatusBodyHash :: EntryId
    , feeStatusRequiredLovelace :: Integer
    , feeStatusPaidLovelace :: Word64
    , feeStatusRequiredDepth :: Word
    , feeStatusHasUnconfirmed :: Bool
    , feeStatusReason :: FeeReason
    , feeStatusMalformedPayment :: Maybe TxIn
    }
    deriving stock (Eq, Show)

data PublishFailure
    = PublishDecodeFailed Text
    | PublishTtlUnbounded
    | PublishTtlOverHorizon
        { pfInvalidHereafter :: SlotNo
        , pfHorizon :: SlotNo
        }
    | PublishFeeRejected FeeStatus
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
            , qTag = renderEntryId bodyHash
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
                    feeResult <- verifyFeeAllowance deps quote tip request
                    case feeResult of
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
            , qTag = renderEntryId bodyHash
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

publishRequiredConfirmationDepth :: Word
publishRequiredConfirmationDepth =
    5

verifyFeeAllowance
    :: Monad m
    => PublishDeps m
    -> FeeQuote
    -> SlotNo
    -> PublishRequest
    -> m (Either PublishFailure ())
verifyFeeAllowance deps quote tip request = do
    allowance <-
        storeAllowanceFor
            (pdStore deps)
            (qBodyHash quote)
            tip
            publishRequiredConfirmationDepth
    if fromIntegral (allowanceLovelace allowance)
        >= qRequiredFeeLovelace quote
        then pure (Right ())
        else do
            malformed <- case prFeePayment request of
                Nothing -> pure Nothing
                Just txIn -> storeMalformedFeePayment (pdStore deps) txIn
            let reason =
                    case malformed of
                        Just{} -> FeeMetadataMalformed
                        Nothing
                            | allowanceHasUnconfirmed allowance -> FeeUnconfirmed
                            | allowanceLovelace allowance > 0 -> FeeInsufficient
                            | otherwise -> FeeNotSeen
            pure
                $ Left
                $ PublishFeeRejected
                    FeeStatus
                        { feeStatusBodyHash = qBodyHash quote
                        , feeStatusRequiredLovelace = qRequiredFeeLovelace quote
                        , feeStatusPaidLovelace = allowanceLovelace allowance
                        , feeStatusRequiredDepth = allowanceRequiredDepth allowance
                        , feeStatusHasUnconfirmed = allowanceHasUnconfirmed allowance
                        , feeStatusReason = reason
                        , feeStatusMalformedPayment = malformedFeePaymentTxIn <$> malformed
                        }

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
        , entryFeePayment = fromMaybe inertFeePayment (prFeePayment request)
        , entryStatus = EntryCollecting
        }

inertFeePayment :: TxIn
inertFeePayment =
    TxIn
        (TxId $ unsafeMakeSafeHash zeroHash)
        (TxIx 0)
  where
    zeroHash =
        case hashFromBytes (BS.replicate 32 0) of
            Just h -> h
            Nothing -> error "inertFeePayment: invalid hash length"

renderEntryId :: EntryId -> Text
renderEntryId (EntryId (TxId safeHash)) =
    TextEncoding.decodeUtf8
        $ Base16.encode
        $ hashToBytes
        $ extractHash safeHash
