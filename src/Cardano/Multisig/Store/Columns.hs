{-# LANGUAGE GADTs #-}

module Cardano.Multisig.Store.Columns
    ( Columns (..)
    , codecs
    )
where

import Cardano.Multisig.Store (EntryId)
import Cardano.Multisig.Store.Codecs
    ( byteStringCodec
    , entryIdCodec
    )
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

instance GEq Columns where
    geq EntriesCol EntriesCol = Just Refl
    geq ReceiptsCol ReceiptsCol = Just Refl
    geq _ _ = Nothing

instance GCompare Columns where
    gcompare EntriesCol EntriesCol = GEQ
    gcompare EntriesCol ReceiptsCol = GLT
    gcompare ReceiptsCol ReceiptsCol = GEQ
    gcompare ReceiptsCol EntriesCol = GGT

codecs :: DMap Columns Codecs
codecs =
    fromList
        [ EntriesCol :=> bytesCodec
        , ReceiptsCol :=> bytesCodec
        ]
  where
    bytesCodec =
        Codecs
            { keyCodec = entryIdCodec
            , valueCodec = byteStringCodec
            }
