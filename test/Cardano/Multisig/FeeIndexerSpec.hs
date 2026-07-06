{-# LANGUAGE DataKinds #-}

module Cardano.Multisig.FeeIndexerSpec
    ( spec
    ) where

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , genKeyDSIGN
    )
import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm)
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , TxIx (..)
    )
import Cardano.Ledger.Credential
    ( Credential (KeyHashObj)
    , StakeReference (StakeRefNull)
    )
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Keys
    ( KeyHash
    , KeyRole (Payment)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Shelley.TxAuxData (Metadatum (I, Map, S))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.FeeIndexer
    ( FeeIndexResult (..)
    , FeeIndexerBlock (..)
    , FeeIndexerChainEvent (..)
    , FeeIndexerOutput (..)
    , FeeIndexerTx (..)
    , classifyFeeTx
    , runFeeIndexerOnce
    )
import Cardano.Multisig.FeeTag
    ( encodeFeeTag
    , feeTagBodyHashKey
    , feeTagLabel
    )
import Cardano.Multisig.Store
    ( EntryId (..)
    , FeeAllowance (..)
    , FeePayment (..)
    , MalformedFeePayment (..)
    , Store (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Monad.State.Strict
    ( State
    , execState
    , gets
    , modify'
    )
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word16, Word64, Word8)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

spec :: Spec
spec =
    describe "Cardano.Multisig.FeeIndexer" $ do
        it "classifies fee-address output plus decodable tag as one payment" $ do
            classifyFeeTx feeAddress (SlotNo 20) taggedTx
                `shouldBe` [FeeIndexPayment expectedPayment]

        it "ignores wrong-address outputs" $ do
            classifyFeeTx feeAddress (SlotNo 20) taggedWrongAddressTx
                `shouldBe` []

        it "records missing metadata as malformed by tx input" $ do
            classifyFeeTx feeAddress (SlotNo 20) missingMetadataTx
                `shouldBe` [FeeIndexMalformed feeTxIn (SlotNo 20)]

        it "records malformed metadata as malformed by tx input" $ do
            classifyFeeTx feeAddress (SlotNo 20) malformedMetadataTx
                `shouldBe` [FeeIndexMalformed feeTxIn (SlotNo 20)]

        it "uses distinct tx inputs for multiple matching outputs" $ do
            classifyFeeTx feeAddress (SlotNo 20) multiOutputTaggedTx
                `shouldBe` [ FeeIndexPayment expectedPayment
                           , FeeIndexPayment expectedSecondPayment
                           ]

        it
            "roll-forward writes attributed payments and malformed records"
            $ do
                let finalState =
                        execState
                            ( runFeeIndexerOnce
                                mockStore
                                feeAddress
                                ( FeeIndexerRollForward
                                    FeeIndexerBlock
                                        { fibSlot = SlotNo 20
                                        , fibTransactions =
                                            [ taggedTx
                                            , malformedMetadataTx
                                            ]
                                        }
                                )
                            )
                            emptyMockState
                mockPayments finalState `shouldBe` [expectedPayment]
                mockMalformed finalState
                    `shouldBe` [ MalformedFeePayment
                                    { malformedFeePaymentTxIn = feeTxIn
                                    , malformedFeePaymentBlockSlot = SlotNo 20
                                    }
                               ]

        it "rollback calls both fee-payment rollback operations" $ do
            let finalState =
                    execState
                        ( runFeeIndexerOnce
                            mockStore
                            feeAddress
                            (FeeIndexerRollBackward (SlotNo 33))
                        )
                        emptyMockState
            mockAttributedRollbacks finalState `shouldBe` [SlotNo 33]
            mockMalformedRollbacks finalState `shouldBe` [SlotNo 33]

data MockState = MockState
    { mockPayments :: [FeePayment]
    , mockMalformed :: [MalformedFeePayment]
    , mockAttributedRollbacks :: [SlotNo]
    , mockMalformedRollbacks :: [SlotNo]
    }
    deriving stock (Eq, Show)

emptyMockState :: MockState
emptyMockState =
    MockState
        { mockPayments = []
        , mockMalformed = []
        , mockAttributedRollbacks = []
        , mockMalformedRollbacks = []
        }

mockStore :: Store (State MockState)
mockStore =
    StoreWithFilters
        { storePutEntry = \_ -> pure ()
        , storeLookupEntry = \_ -> pure Nothing
        , storeListEntries = pure []
        , storeCollectWitnesses = \_ _ -> pure ()
        , storePutReceipt = \_ _ -> pure ()
        , storeLookupReceipt = \_ -> pure Nothing
        , storePutSignerFilter = \_ _ -> pure ()
        , storeLookupSignerFilter = \_ -> pure Nothing
        , storeUpsertFeePayment = \payment ->
            modify'
                ( \s ->
                    s{mockPayments = mockPayments s <> [payment]}
                )
        , storeRollbackFeePaymentsFrom = \slot ->
            modify'
                ( \s ->
                    s
                        { mockAttributedRollbacks =
                            mockAttributedRollbacks s <> [slot]
                        }
                )
        , storeAllowanceFor = \_ _ _ -> pure (FeeAllowance 0 0 False)
        , storePutMalformedFeePayment = \payment ->
            modify'
                ( \s ->
                    s{mockMalformed = mockMalformed s <> [payment]}
                )
        , storeMalformedFeePayment = \txIn ->
            gets
                ( \s ->
                    lookup
                        txIn
                        [ (malformedFeePaymentTxIn payment, payment)
                        | payment <- mockMalformed s
                        ]
                )
        , storeRollbackMalformedFeePaymentsFrom = \slot ->
            modify'
                ( \s ->
                    s
                        { mockMalformedRollbacks =
                            mockMalformedRollbacks s <> [slot]
                        }
                )
        }

taggedTx :: FeeIndexerTx
taggedTx =
    FeeIndexerTx
        { fitMetadata = encodeFeeTag bodyHash
        , fitOutputs =
            [ FeeIndexerOutput
                { fioTxIn = feeTxIn
                , fioAddress = feeAddress
                , fioLovelace = 1_500
                }
            ]
        }

taggedWrongAddressTx :: FeeIndexerTx
taggedWrongAddressTx =
    taggedTx
        { fitOutputs =
            [ FeeIndexerOutput
                { fioTxIn = feeTxIn
                , fioAddress = otherAddress
                , fioLovelace = 1_500
                }
            ]
        }

missingMetadataTx :: FeeIndexerTx
missingMetadataTx =
    taggedTx{fitMetadata = mempty}

malformedMetadataTx :: FeeIndexerTx
malformedMetadataTx =
    taggedTx{fitMetadata = malformedMetadata}

multiOutputTaggedTx :: FeeIndexerTx
multiOutputTaggedTx =
    taggedTx
        { fitOutputs =
            [ FeeIndexerOutput
                { fioTxIn = feeTxIn
                , fioAddress = feeAddress
                , fioLovelace = 1_500
                }
            , FeeIndexerOutput
                { fioTxIn = secondFeeTxIn
                , fioAddress = feeAddress
                , fioLovelace = 2_000
                }
            ]
        }

expectedPayment :: FeePayment
expectedPayment =
    FeePayment
        { feePaymentBodyHash = bodyHash
        , feePaymentTxIn = feeTxIn
        , feePaymentLovelace = 1_500
        , feePaymentBlockSlot = SlotNo 20
        }

expectedSecondPayment :: FeePayment
expectedSecondPayment =
    expectedPayment
        { feePaymentTxIn = secondFeeTxIn
        , feePaymentLovelace = 2_000
        }

malformedMetadata :: Map Word64 Metadatum
malformedMetadata =
    Map.singleton
        feeTagLabel
        (Map [(S feeTagBodyHashKey, I 0)])

bodyHash :: EntryId
bodyHash =
    EntryId (TxId $ unsafeMakeSafeHash $ mkHash32 42)

feeTxIn :: TxIn
feeTxIn =
    mkTxIn 8 0

secondFeeTxIn :: TxIn
secondFeeTxIn =
    mkTxIn 8 1

feeAddress :: Addr
feeAddress =
    testAddress 9

otherAddress :: Addr
otherAddress =
    testAddress 10

testAddress :: Word8 -> Addr
testAddress n =
    Addr
        Testnet
        (KeyHashObj (paymentHash n))
        StakeRefNull

paymentHash :: Word8 -> KeyHash Payment
paymentHash n =
    hashKey (VKey (deriveVerKeyDSIGN (testKey n)))

testKey :: Word8 -> SignKeyDSIGN Ed25519DSIGN
testKey n =
    genKeyDSIGN (mkSeedFromBytes (BS.replicate 32 n))

mkTxIn :: Word8 -> Word16 -> TxIn
mkTxIn n ix =
    TxIn
        (TxId $ unsafeMakeSafeHash $ mkHash32 n)
        (TxIx ix)

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    case hashFromBytes (BS.pack (replicate 31 0 ++ [n])) of
        Just h -> h
        Nothing -> error "mkHash32: invalid hash length"
