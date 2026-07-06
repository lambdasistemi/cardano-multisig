module Cardano.Multisig.ChainSpec
    ( spec
    ) where

-- \|
-- Module      : Cardano.Multisig.ChainSpec
-- Description : Unit tests for chain-access pure helpers
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0

import Cardano.Crypto.Hash (hashFromBytes, hashFromStringAsHex)
import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Scripts.Data (Datum (NoDatum))
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , mkBasicTx
    )
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (..), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Credential
    ( Credential (KeyHashObj)
    , StakeReference (StakeRefNull)
    )
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Multisig.Chain
    ( N2cConfig (..)
    , PaymentConfirmation (..)
    , PaymentConfirmationEvidence (..)
    , PaymentReadResult (..)
    , networkFromMagic
    , paymentConfirmationFromTxOut
    , readPaymentConfirmation
    , withNodeProvider
    )
import Cardano.Node.Client.Provider
    ( EpochNo (..)
    , LedgerSnapshot (..)
    , Provider (..)
    , singleShotWithAcquired
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Cardano.Tx.Validate.Cli (collectInputs)
import Control.Exception (ErrorCall (..), throwIO)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16, Word8)
import Lens.Micro ((&), (.~))
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Environment (lookupEnv)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , pendingWith
    , shouldBe
    )

spec :: Spec
spec =
    describe "Cardano.Multisig.Chain" $ do
        describe "networkFromMagic" $ do
            it "maps the mainnet magic to Mainnet"
                $ networkFromMagic (NetworkMagic 764824073)
                `shouldBe` Mainnet
            it "maps any other magic to Testnet"
                $ networkFromMagic (NetworkMagic 2)
                `shouldBe` Testnet

        describe "paymentConfirmationFromTxOut"
            $ it "keeps the requested TxIn, output fields, and N2C evidence"
            $ do
                let txIn = mkTxIn 1
                    out = mkTestTxOut 42
                    evidence =
                        PaymentConfirmationEvidence
                            { pceLedgerTipSlot = SlotNo 1234
                            , pceExactDepth = Nothing
                            }
                    confirmation =
                        paymentConfirmationFromTxOut txIn evidence out
                pcRequestedTxIn confirmation `shouldBe` txIn
                pcValue confirmation
                    `shouldBe` MaryValue (Coin 42) (MultiAsset mempty)
                pcAddress confirmation `shouldBe` mkTestAddr 42
                pcDatum confirmation `shouldBe` NoDatum
                pcEvidence confirmation `shouldBe` evidence

        describe "readPaymentConfirmation" $ do
            it "resolves a requested TxIn through queryUTxOByTxIn" $ do
                let txIn = mkTxIn 7
                    provider =
                        stubProvider
                            (SlotNo 88)
                            (Map.singleton txIn (mkTestTxOut 99))
                result <- readPaymentConfirmation provider txIn
                result
                    `shouldBe` PaymentReadResolved
                        ( paymentConfirmationFromTxOut
                            txIn
                            PaymentConfirmationEvidence
                                { pceLedgerTipSlot = SlotNo 88
                                , pceExactDepth = Nothing
                                }
                            (mkTestTxOut 99)
                        )

            it
                "returns a typed miss with tip evidence when the node cannot resolve it"
                $ do
                    let txIn = mkTxIn 8
                        provider = stubProvider (SlotNo 89) Map.empty
                    result <- readPaymentConfirmation provider txIn
                    result
                        `shouldBe` PaymentReadMissing
                            txIn
                            PaymentConfirmationEvidence
                                { pceLedgerTipSlot = SlotNo 89
                                , pceExactDepth = Nothing
                                }

        describe "collectInputs boundary"
            $ it "includes spend, reference, and collateral inputs"
            $ do
                let spend = mkTxIn 11
                    reference = mkTxIn 12
                    collateral = mkTxIn 13
                    tx =
                        (mkBasicTx mkBasicTxBody :: ConwayTx)
                            & bodyTxL . inputsTxBodyL
                                .~ Set.singleton spend
                            & bodyTxL . referenceInputsTxBodyL
                                .~ Set.singleton reference
                            & bodyTxL . collateralInputsTxBodyL
                                .~ Set.singleton collateral
                collectInputs tx
                    `shouldBe` Set.fromList
                        [ spend
                        , reference
                        , collateral
                        ]

        describe "live N2C payment reader smoke"
            $ it "reads a known preprod TxIn from the live node when enabled"
            $ do
                enabled <- lookupEnv "CARDANO_MULTISIG_LIVE_SMOKE"
                case enabled of
                    Just "1" -> livePaymentSmoke
                    _ ->
                        pendingWith
                            "set CARDANO_MULTISIG_LIVE_SMOKE=1 via just live-chain-payment-read"

livePaymentSmoke :: IO ()
livePaymentSmoke = do
    txInText <- requireEnv "CARDANO_MULTISIG_LIVE_TXIN"
    socket <- requireEnv "CARDANO_MULTISIG_LIVE_SOCKET"
    magic <-
        maybe 1 read <$> lookupEnv "CARDANO_MULTISIG_LIVE_MAGIC"
    txIn <-
        either
            (ioError . userError . Text.unpack)
            pure
            (parseTxInText (Text.pack txInText))
    withNodeChainSourceSmoke socket magic txIn

withNodeChainSourceSmoke :: FilePath -> Word -> TxIn -> IO ()
withNodeChainSourceSmoke socket magic txIn =
    withNodeProvider
        N2cConfig{n2cSocket = socket, n2cMagic = fromIntegral magic}
        $ \provider -> do
            result <- readPaymentConfirmation provider txIn
            case result of
                PaymentReadResolved confirmation ->
                    pcRequestedTxIn confirmation `shouldBe` txIn
                PaymentReadMissing{} ->
                    expectationFailure
                        ( "live N2C payment reader did not resolve "
                            <> Text.unpack rawTxIn
                        )
  where
    rawTxIn =
        case txIn of
            TxIn{} -> Text.pack (show txIn)

requireEnv :: String -> IO String
requireEnv name =
    lookupEnv name >>= \case
        Just value | not (null value) -> pure value
        _ -> ioError (userError ("missing required env " <> name))

parseTxInText :: Text -> Either Text TxIn
parseTxInText raw =
    case Text.splitOn "#" raw of
        [txIdText, ixText]
            | Text.length txIdText == 64
            , Right ix <- parseTxIx ixText
            , Just h <- hashFromStringAsHex (Text.unpack txIdText) ->
                Right (TxIn (TxId (unsafeMakeSafeHash h)) (TxIx ix))
        _ ->
            Left "expected TxIn as <64-hex-txid>#<index>"

parseTxIx :: Text -> Either Text Word16
parseTxIx t =
    case reads (Text.unpack t) of
        [(n, "")] -> Right n
        _ -> Left ("invalid TxIn index: " <> t)

stubProvider :: SlotNo -> Map TxIn (TxOut ConwayEra) -> Provider IO
stubProvider tip utxo =
    provider
  where
    provider =
        Provider
            { withAcquired = singleShotWithAcquired provider
            , queryUTxOs = \_ -> panicIO "queryUTxOs"
            , queryUTxOByTxIn = pure . Map.restrictKeys utxo
            , queryProtocolParams = panicIO "queryProtocolParams"
            , queryLedgerSnapshot =
                pure
                    LedgerSnapshot
                        { ledgerCurrentEra = "Conway"
                        , ledgerChainPoint = Network.GenesisPoint
                        , ledgerTipSlot = tip
                        , ledgerEpoch = EpochNo 0
                        }
            , queryStakeRewards = \_ -> panicIO "queryStakeRewards"
            , queryRewardAccounts = \_ -> panicIO "queryRewardAccounts"
            , queryVoteDelegatees = \_ -> panicIO "queryVoteDelegatees"
            , queryTreasury = panicIO "queryTreasury"
            , queryGovernanceState = panicIO "queryGovernanceState"
            , evaluateTx = \_ -> panicIO "evaluateTx"
            , posixMsToSlot = \_ -> panicIO "posixMsToSlot"
            , posixMsCeilSlot = \_ -> panicIO "posixMsCeilSlot"
            , queryUpperBoundSlot = \_ -> panicIO "queryUpperBoundSlot"
            }

panicIO :: String -> IO a
panicIO field =
    throwIO (ErrorCall ("stubProvider." <> field <> " called"))

mkTxIn :: Word8 -> TxIn
mkTxIn n =
    TxIn
        (TxId $ unsafeMakeSafeHash $ mkHash32 n)
        (TxIx (fromIntegral n))

mkTestTxOut :: Word8 -> TxOut ConwayEra
mkTestTxOut n =
    mkBasicTxOut
        (mkTestAddr n)
        (MaryValue (Coin (fromIntegral n)) (MultiAsset mempty))

mkTestAddr :: Word8 -> Addr
mkTestAddr n =
    Addr
        Testnet
        (KeyHashObj (KeyHash (mkHash28 n)))
        StakeRefNull

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    case hashFromBytes (BS.pack (replicate 31 0 ++ [n])) of
        Just h -> h
        Nothing -> error "mkHash32: invalid hash length"

mkHash28 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash28 n =
    case hashFromBytes (BS.pack (replicate 27 0 ++ [n])) of
        Just h -> h
        Nothing -> error "mkHash28: invalid hash length"
