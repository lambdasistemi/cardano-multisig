{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.Filter
    ( FilterPolicy (..)
    , canonicalFilterPolicyBytes
    , decodeFilterPolicyBytes
    , encodeFilterPolicyBytes
    , filterEntries
    , parseFilterPolicy
    , parseKeyHash
    , renderKeyHash
    , verifyFilterPolicyWitness
    )
where

-- \|
-- Module      : Cardano.Multisig.Filter
-- Description : Signer-controlled entry filtering policy
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0

import Cardano.Crypto.DSIGN.Class (verifySignedDSIGN)
import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Crypto.Hash.Class
    ( Hash
    , castHash
    , hashToBytes
    , hashWith
    )
import Cardano.Ledger.Hashes
    ( EraIndependentTxBody
    , HASH
    , KeyHash (..)
    )
import Cardano.Ledger.Keys
    ( KeyRole (Guard, Witness)
    , VKey (..)
    , WitVKey (..)
    )
import Cardano.Multisig.Store (Entry (..))
import Cardano.Multisig.Witness
    ( entryWitnesses
    , witnessKeyHash
    )
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding

data FilterPolicy
    = TrustOrdered (Set (KeyHash Guard))
    | RosterOpen
    deriving stock (Eq, Show)

filterEntries :: FilterPolicy -> KeyHash Guard -> [Entry] -> [Entry]
filterEntries policy signer =
    filter (entryVisibleTo policy signer)

canonicalFilterPolicyBytes :: FilterPolicy -> ByteString
canonicalFilterPolicyBytes =
    TextEncoding.encodeUtf8 . \case
        TrustOrdered allowlist ->
            "cardano-multisig-filter-v1\n"
                <> "predicate=trust-ordered\n"
                <> "allowlist="
                <> Text.intercalate
                    ","
                    (renderKeyHash <$> Set.toAscList allowlist)
                <> "\n"
        RosterOpen ->
            "cardano-multisig-filter-v1\npredicate=roster-open\n"

encodeFilterPolicyBytes :: FilterPolicy -> ByteString
encodeFilterPolicyBytes =
    canonicalFilterPolicyBytes

decodeFilterPolicyBytes :: ByteString -> Either Text FilterPolicy
decodeFilterPolicyBytes =
    parseCanonicalPolicy . TextEncoding.decodeUtf8

parseFilterPolicy
    :: Text
    -> Maybe [Text]
    -> Either Text FilterPolicy
parseFilterPolicy name rawAllowlist =
    case name of
        "roster-open" ->
            case rawAllowlist of
                Nothing -> Right RosterOpen
                Just [] -> Right RosterOpen
                Just _ -> Left "roster-open does not take an allowlist"
        "trust-ordered" ->
            case rawAllowlist of
                Nothing -> Left "trust-ordered requires allowlist"
                Just [] -> Left "trust-ordered requires allowlist"
                Just allowlist ->
                    TrustOrdered . Set.fromList
                        <$> traverse parseKeyHash allowlist
        _ -> Left "unknown filter predicate"

verifyFilterPolicyWitness
    :: KeyHash Guard
    -> FilterPolicy
    -> WitVKey Witness
    -> Bool
verifyFilterPolicyWitness signer policy witness@(WitVKey vkey signature) =
    witnessKeyHash witness == signer
        && case verifySignedDSIGN
            ()
            (unVKey vkey)
            (policyHash policy)
            signature of
            Right () -> True
            Left _ -> False

policyHash :: FilterPolicy -> Hash HASH EraIndependentTxBody
policyHash =
    castHash . hashWith @HASH id . canonicalFilterPolicyBytes

parseKeyHash :: Text -> Either Text (KeyHash kr)
parseKeyHash raw = do
    bytes <-
        case Base16.decode (TextEncoding.encodeUtf8 raw) of
            Right value -> Right value
            Left err -> Left (Text.pack err)
    case hashFromBytes bytes of
        Just hash -> Right (KeyHash hash)
        Nothing -> Left "key hash must be 28 bytes"

renderKeyHash :: KeyHash kr -> Text
renderKeyHash (KeyHash h) =
    TextEncoding.decodeUtf8 $ Base16.encode $ hashToBytes h

entryVisibleTo :: FilterPolicy -> KeyHash Guard -> Entry -> Bool
entryVisibleTo policy signer entry =
    Set.member signer (entryRequiredSigners entry)
        && case policy of
            RosterOpen -> True
            TrustOrdered allowlist ->
                not
                    $ Set.null
                    $ entryWitnesses entry `Set.intersection` allowlist

parseCanonicalPolicy :: Text -> Either Text FilterPolicy
parseCanonicalPolicy raw =
    case Text.lines raw of
        ["cardano-multisig-filter-v1", "predicate=roster-open"] ->
            Right RosterOpen
        [ "cardano-multisig-filter-v1"
            , "predicate=trust-ordered"
            , allowlistLine
            ] ->
                case Text.stripPrefix "allowlist=" allowlistLine of
                    Nothing -> Left "missing allowlist"
                    Just allowlist ->
                        parseFilterPolicy
                            "trust-ordered"
                            (Just (Text.splitOn "," allowlist))
        _ -> Left "invalid filter policy encoding"
