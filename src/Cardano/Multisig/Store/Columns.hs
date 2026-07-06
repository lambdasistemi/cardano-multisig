{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Multisig.Store.Columns
    ( Columns (..)
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
import Cardano.Multisig.Store (EntryId)
import Cardano.Multisig.Store.Codecs (entryIdCodec)
import Control.Lens (Prism', prism')
import Data.ByteString (ByteString)
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

instance GEq Columns where
    geq EntriesCol EntriesCol = Just Refl
    geq ReceiptsCol ReceiptsCol = Just Refl
    geq SignerFiltersCol SignerFiltersCol = Just Refl
    geq _ _ = Nothing

instance GCompare Columns where
    gcompare EntriesCol EntriesCol = GEQ
    gcompare EntriesCol ReceiptsCol = GLT
    gcompare EntriesCol SignerFiltersCol = GLT
    gcompare ReceiptsCol ReceiptsCol = GEQ
    gcompare ReceiptsCol EntriesCol = GGT
    gcompare ReceiptsCol SignerFiltersCol = GLT
    gcompare SignerFiltersCol SignerFiltersCol = GEQ
    gcompare SignerFiltersCol EntriesCol = GGT
    gcompare SignerFiltersCol ReceiptsCol = GGT

codecs :: DMap Columns Codecs
codecs =
    fromList
        [ EntriesCol :=> bytesCodec
        , ReceiptsCol :=> bytesCodec
        , SignerFiltersCol :=> signerFilterCodec
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

keyHashCodec :: Prism' ByteString (KeyHash Guard)
keyHashCodec =
    prism' ledgerEncode ledgerDecode

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
