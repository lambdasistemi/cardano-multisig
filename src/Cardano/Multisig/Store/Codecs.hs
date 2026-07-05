{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.Store.Codecs
    ( byteStringCodec
    , entryIdCodec
    )
where

import Cardano.Multisig.Store (EntryId (..))
import Control.Lens (Prism', prism')
import Data.ByteString (ByteString)

import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Binary
    ( DecCBOR
    , EncCBOR
    , decodeFull'
    , serialize'
    )
import Cardano.Ledger.Conway (ConwayEra)

entryIdCodec :: Prism' ByteString EntryId
entryIdCodec =
    prism'
        (ledgerEncode . unEntryId)
        (fmap EntryId . ledgerDecode)

byteStringCodec :: Prism' ByteString ByteString
byteStringCodec =
    prism' id Just

ledgerEncode :: EncCBOR a => a -> ByteString
ledgerEncode =
    serialize' (eraProtVerLow @ConwayEra)

ledgerDecode :: DecCBOR a => ByteString -> Maybe a
ledgerDecode =
    either (const Nothing) Just
        . decodeFull' (eraProtVerLow @ConwayEra)
