module Cardano.Multisig.FeeIndexer
    ( FeeIndexResult (..)
    , FeeIndexerBlock (..)
    , FeeIndexerChainEvent (..)
    , FeeIndexerOutput (..)
    , FeeIndexerTx (..)
    , classifyFeeTx
    , runFeeIndexerOnce
    )
where

-- \|
-- Module      : Cardano.Multisig.FeeIndexer
-- Description : Fee-address indexer classification model
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0
--
-- Pure fee-payment classification and a mockable chain-event application
-- surface for the fee-address indexer.

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Multisig.FeeTag
    ( FeeMetadata
    , decodeFeeTag
    )
import Cardano.Multisig.Store
    ( FeePayment (..)
    , MalformedFeePayment (..)
    , Store (..)
    )
import Cardano.Slotting.Slot (SlotNo)
import Data.Foldable (traverse_)
import Data.Word (Word64)

data FeeIndexerOutput = FeeIndexerOutput
    { fioTxIn :: TxIn
    , fioAddress :: Addr
    , fioLovelace :: Word64
    }
    deriving stock (Eq, Show)

data FeeIndexerTx = FeeIndexerTx
    { fitMetadata :: FeeMetadata
    , fitOutputs :: [FeeIndexerOutput]
    }
    deriving stock (Eq, Show)

data FeeIndexerBlock = FeeIndexerBlock
    { fibSlot :: SlotNo
    , fibTransactions :: [FeeIndexerTx]
    }
    deriving stock (Eq, Show)

data FeeIndexerChainEvent
    = FeeIndexerRollForward FeeIndexerBlock
    | FeeIndexerRollBackward SlotNo
    deriving stock (Eq, Show)

data FeeIndexResult
    = FeeIndexPayment FeePayment
    | FeeIndexMalformed TxIn SlotNo
    deriving stock (Eq, Show)

classifyFeeTx :: Addr -> SlotNo -> FeeIndexerTx -> [FeeIndexResult]
classifyFeeTx feeAddress slot tx =
    case decodeFeeTag (fitMetadata tx) of
        Just bodyHash ->
            [ FeeIndexPayment
                FeePayment
                    { feePaymentBodyHash = bodyHash
                    , feePaymentTxIn = fioTxIn output
                    , feePaymentLovelace = fioLovelace output
                    , feePaymentBlockSlot = slot
                    }
            | output <- matchingOutputs
            ]
        Nothing ->
            [ FeeIndexMalformed (fioTxIn output) slot
            | output <- matchingOutputs
            ]
  where
    matchingOutputs =
        [ output
        | output <- fitOutputs tx
        , fioAddress output == feeAddress
        , fioLovelace output > 0
        ]

runFeeIndexerOnce
    :: Monad m
    => Store m
    -> Addr
    -> FeeIndexerChainEvent
    -> m ()
runFeeIndexerOnce store feeAddress = \case
    FeeIndexerRollForward block ->
        traverse_
            (applyResult store)
            [ result
            | tx <- fibTransactions block
            , result <- classifyFeeTx feeAddress (fibSlot block) tx
            ]
    FeeIndexerRollBackward slot -> do
        storeRollbackFeePaymentsFrom store slot
        storeRollbackMalformedFeePaymentsFrom store slot

applyResult :: Store m -> FeeIndexResult -> m ()
applyResult store = \case
    FeeIndexPayment payment ->
        storeUpsertFeePayment store payment
    FeeIndexMalformed txIn slot ->
        storePutMalformedFeePayment
            store
            MalformedFeePayment
                { malformedFeePaymentTxIn = txIn
                , malformedFeePaymentBlockSlot = slot
                }
