{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.Witness
    ( WitnessFailure (..)
    , assembleEntryTx
    , decodeVKeyWitnessHex
    , entryMissingSigners
    , entryWitnessStatus
    , entryWitnesses
    , verifyEntryWitness
    , witnessKeyHash
    ) where

import Cardano.Crypto.DSIGN.Class (verifySignedDSIGN)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx
    ( addrTxWitsL
    , bodyTxL
    )
import Cardano.Ledger.Binary
    ( Annotator
    , DecCBOR (..)
    , Decoder
    , DecoderError
    , decodeFullAnnotator
    , decodeListLenOf
    , decodeWord
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (witsTxL)
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , extractHash
    , hashAnnotated
    )
import Cardano.Ledger.Keys
    ( KeyRole (Guard, Witness)
    , VKey (..)
    , WitVKey (..)
    , hashKey
    )
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryStatus (..)
    )
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BL
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word8)
import Lens.Micro ((%~), (&), (^.))

data WitnessFailure
    = WitnessInvalidHex Text
    | WitnessDecodeFailed Text
    | WitnessInvalidSignature
    | WitnessSignerNotRequired (KeyHash Guard)
    | WitnessAlreadyCollected (KeyHash Guard)
    deriving stock (Eq, Show)

decodeVKeyWitnessHex
    :: ByteString -> Either WitnessFailure (WitVKey Witness)
decodeVKeyWitnessHex hex = do
    raw <- decodeHex hex
    let input = BL.fromStrict raw
        tryBare =
            decodeFullAnnotator
                (eraProtVerLow @ConwayEra)
                "WitVKey"
                decCBOR
                input
        tryWrapped =
            decodeFullAnnotator
                (eraProtVerLow @ConwayEra)
                "KeyWitness"
                keyWitnessDecoder
                input
    case tryBare of
        Right witness -> Right witness
        Left bareErr -> case tryWrapped of
            Right witness -> Right witness
            Left wrappedErr ->
                Left
                    $ WitnessDecodeFailed
                    $ "neither bare WitVKey ("
                        <> renderDecoderError bareErr
                        <> ") nor [tag, WitVKey] envelope ("
                        <> renderDecoderError wrappedErr
                        <> ")"

verifyEntryWitness
    :: Entry
    -> WitVKey Witness
    -> Either WitnessFailure Entry
verifyEntryWitness entry witness@(WitVKey vkey signature) = do
    case verifySignedDSIGN () (unVKey vkey) bodyHash signature of
        Left _ -> Left WitnessInvalidSignature
        Right () -> Right ()
    let signer = witnessKeyHash witness
    if Set.member signer (entryRequiredSigners entry)
        then Right ()
        else Left (WitnessSignerNotRequired signer)
    if Set.member signer (entryWitnesses entry)
        then Left (WitnessAlreadyCollected signer)
        else Right ()
    let updated =
            entry
                { entryCollectedWitnesses =
                    entryCollectedWitnesses entry
                        & addrTxWitsL %~ Set.insert witness
                }
    Right updated{entryStatus = entryWitnessStatus updated}
  where
    bodyHash = extractHash (hashAnnotated (entryTx entry ^. bodyTxL))

entryWitnesses :: Entry -> Set (KeyHash Guard)
entryWitnesses entry =
    Set.map witnessKeyHash (entryCollectedWitnesses entry ^. addrTxWitsL)

entryMissingSigners :: Entry -> Set (KeyHash Guard)
entryMissingSigners entry =
    entryRequiredSigners entry `Set.difference` entryWitnesses entry

entryWitnessStatus :: Entry -> EntryStatus
entryWitnessStatus entry =
    case entryStatus entry of
        EntrySubmitted -> EntrySubmitted
        EntryExpired -> EntryExpired
        EntryReady
            | Set.null (entryMissingSigners entry) -> EntryReady
            | otherwise -> EntryCollecting
        EntryCollecting
            | Set.null (entryMissingSigners entry) -> EntryReady
            | otherwise -> EntryCollecting

assembleEntryTx :: Entry -> ConwayTx
assembleEntryTx entry =
    entryTx entry
        & witsTxL . addrTxWitsL
            %~ Set.union (entryCollectedWitnesses entry ^. addrTxWitsL)

witnessKeyHash :: WitVKey Witness -> KeyHash Guard
witnessKeyHash (WitVKey vkey _) =
    witnessKeyHashToGuard (hashKey vkey)

witnessKeyHashToGuard :: KeyHash Witness -> KeyHash Guard
witnessKeyHashToGuard (KeyHash hash) = KeyHash hash

keyWitnessDecoder :: Decoder s (Annotator (WitVKey Witness))
keyWitnessDecoder = do
    decodeListLenOf 2
    tag <- decodeWord
    case tag of
        0 -> decCBOR
        _ -> fail ("unsupported KeyWitness tag: " <> show tag)

decodeHex :: ByteString -> Either WitnessFailure ByteString
decodeHex hex =
    case Base16.decode (stripWhitespace hex) of
        Right raw -> Right raw
        Left err -> Left (WitnessInvalidHex (Text.pack err))

stripWhitespace :: ByteString -> ByteString
stripWhitespace =
    BS.filter (`notElem` whitespaceBytes)

whitespaceBytes :: [Word8]
whitespaceBytes = [0x20, 0x09, 0x0a, 0x0d]

renderDecoderError :: DecoderError -> Text
renderDecoderError = Text.pack . show
