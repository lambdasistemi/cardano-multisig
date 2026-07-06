module Cardano.Multisig.Chain
    ( ChainSource (..)
    , N2cConfig (..)
    , PaymentConfirmation (..)
    , PaymentConfirmationEvidence (..)
    , PaymentReadResult (..)
    , Verdict
    , chainSourceFromProvider
    , paymentConfirmationFromTxOut
    , readPaymentConfirmation
    , withNodeChainSource
    , withNodeProvider
    , withNodeProviderAndSubmitter
    , networkFromMagic
    ) where

-- \|
-- Module      : Cardano.Multisig.Chain
-- Description : Node-to-Client chain access and Conway phase-1 pre-flight
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0
--
-- A 'ChainSource' is the coordinator's live view of the chain: a Conway
-- phase-1 pre-flight backed by a Node-to-Client session, reusing the
-- validator and resolver chain from cardano-tx-tools rather than
-- reimplementing either. The session + validation wiring is adapted from
-- cardano-tx-tools\' @tx-validate@ executable. The record shape keeps the
-- interface swappable for tests and alternative chain backends.

import Control.Concurrent.Async (withAsync)
import Control.Monad (void)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Numeric.Natural (Natural)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Scripts.Data (Datum)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider
    ( LedgerSnapshot (..)
    , Provider (..)
    )
import Cardano.Node.Client.Submitter (Submitter)
import Cardano.Slotting.Slot (SlotNo)
import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build (mkPParamsBound)
import Cardano.Tx.Diff.Resolver (resolveChain, resolverName)
import Cardano.Tx.Diff.Resolver.N2C (n2cResolver)
import Cardano.Tx.Ledger (ConwayTx)
import Cardano.Tx.Validate (validatePhase1WithRewardAccounts)
import Cardano.Tx.Validate.Cli
    ( N2cConfig (..)
    , RewardAccountSource (..)
    , Session (..)
    , Verdict
    , buildVerdict
    , collectInputs
    , collectWithdrawalAccounts
    , mkSessionWithRewardAccounts
    )
import Lens.Micro ((^.))

-- | The coordinator's live view of the chain. Milestone-1 needs a single
-- capability — a Conway phase-1 pre-flight of a candidate transaction — and
-- the record shape lets a node-backed source, a mock, or an alternative
-- backend all satisfy it.
newtype ChainSource = ChainSource
    { csPreflight :: ConwayTx -> IO Verdict
    }

-- | Evidence attached to an N2C-backed payment read.
--
-- N2C LocalStateQuery proves the output is currently present in the UTxO
-- set at the acquired ledger tip. It does not expose the block slot that
-- created the output, so exact confirmation depth is absent unless a
-- different backend supplies it.
data PaymentConfirmationEvidence = PaymentConfirmationEvidence
    { pceLedgerTipSlot :: SlotNo
    , pceExactDepth :: Maybe Natural
    }
    deriving stock (Eq, Show)

-- | Resolved payment output information for a requested 'TxIn'.
data PaymentConfirmation = PaymentConfirmation
    { pcRequestedTxIn :: TxIn
    , pcValue :: Ledger.Value ConwayEra
    , pcAddress :: Addr
    , pcDatum :: Datum ConwayEra
    , pcEvidence :: PaymentConfirmationEvidence
    }
    deriving stock (Eq, Show)

-- | Result of asking the chain for a payment output.
data PaymentReadResult
    = PaymentReadResolved PaymentConfirmation
    | PaymentReadMissing TxIn PaymentConfirmationEvidence
    deriving stock (Eq, Show)

-- | Open a Node-to-Client session to a local node and run the action with
-- a 'ChainSource' backed by it. Adapts the session bracket and validation
-- flow from cardano-tx-tools\' @tx-validate@.
withNodeChainSource :: N2cConfig -> (ChainSource -> IO a) -> IO a
withNodeChainSource cfg k = do
    let magic = NetworkMagic (n2cMagic cfg)
        network = networkFromMagic magic
    withNodeProvider cfg $ \provider ->
        k (chainSourceFromProvider network provider)

-- | Build a pre-flight source from an already-open provider.
chainSourceFromProvider :: Network -> Provider IO -> ChainSource
chainSourceFromProvider network provider =
    ChainSource{csPreflight = preflight network provider}

-- | Open a Node-to-Client session and run the action with its provider.
withNodeProvider :: N2cConfig -> (Provider IO -> IO a) -> IO a
withNodeProvider cfg k =
    withNodeProviderAndSubmitter cfg $ \provider _submitter -> k provider

-- | Open one Node-to-Client session and expose both LocalStateQuery-backed
-- reads and LocalTxSubmission-backed transaction submission.
withNodeProviderAndSubmitter
    :: N2cConfig -> (Provider IO -> Submitter IO -> IO a) -> IO a
withNodeProviderAndSubmitter cfg k = do
    let magic = NetworkMagic (n2cMagic cfg)
    lsqCh <- newLSQChannel 64
    ltxsCh <- newLTxSChannel 64
    withAsync (void $ runNodeClient magic (n2cSocket cfg) lsqCh ltxsCh)
        $ \_ -> do
            let provider = mkN2CProvider lsqCh
                submitter = mkN2CSubmitter ltxsCh
            k provider submitter

-- | Read a payment output through the same N2C provider/resolver path used
-- for transaction pre-flight.
readPaymentConfirmation :: Provider IO -> TxIn -> IO PaymentReadResult
readPaymentConfirmation provider txIn = do
    snap <- queryLedgerSnapshot provider
    (resolved, _unresolved) <-
        resolveChain [n2cResolver provider] (Set.singleton txIn)
    let evidence = paymentEvidenceFromSnapshot snap
    pure
        $ maybe
            (PaymentReadMissing txIn evidence)
            (PaymentReadResolved . paymentConfirmationFromTxOut txIn evidence)
            (listToMaybe (Map.elems resolved))

-- | Project a resolved Conway output into the public payment-reader type.
paymentConfirmationFromTxOut
    :: TxIn
    -> PaymentConfirmationEvidence
    -> TxOut ConwayEra
    -> PaymentConfirmation
paymentConfirmationFromTxOut txIn evidence txOut =
    PaymentConfirmation
        { pcRequestedTxIn = txIn
        , pcValue = txOut ^. valueTxOutL
        , pcAddress = txOut ^. addrTxOutL
        , pcDatum = txOut ^. datumTxOutL
        , pcEvidence = evidence
        }

paymentEvidenceFromSnapshot
    :: LedgerSnapshot -> PaymentConfirmationEvidence
paymentEvidenceFromSnapshot snap =
    PaymentConfirmationEvidence
        { pceLedgerTipSlot = ledgerTipSlot snap
        , pceExactDepth = Nothing
        }

-- | Resolve the transaction's inputs against the node, build a session
-- from current protocol parameters and tip, and run the phase-1 validator
-- (with reward-account resolution when the tx has withdrawals).
preflight
    :: Network
    -> Provider IO
    -> ConwayTx
    -> IO Verdict
preflight network provider tx = do
    pp <- queryProtocolParams provider
    snap <- queryLedgerSnapshot provider
    let withdrawals = collectWithdrawalAccounts tx
    rewardAccounts <-
        if Set.null withdrawals
            then pure Map.empty
            else queryRewardAccounts provider withdrawals
    let rewardSource =
            if Set.null withdrawals
                then RewardAccountsNotRequired
                else RewardAccountsN2C
        session =
            mkSessionWithRewardAccounts
                network
                pp
                (ledgerTipSlot snap)
                [n2cResolver provider]
                rewardAccounts
                rewardSource
    (resolved, _unresolved) <-
        resolveChain (sessionUtxoResolvers session) (collectInputs tx)
    let resolverTag = case sessionUtxoResolvers session of
            (r : _) -> resolverName r
            [] -> "unknown"
        utxoSources = Map.map (const resolverTag) resolved
        result =
            validatePhase1WithRewardAccounts
                (sessionNetwork session)
                (mkPParamsBound (sessionPParams session))
                (Map.toList resolved)
                (sessionRewardAccounts session)
                (sessionSlot session)
                tx
    pure (buildVerdict session utxoSources result)

-- | The Cardano mainnet network magic; anything else is a testnet.
networkFromMagic :: NetworkMagic -> Network
networkFromMagic (NetworkMagic 764824073) = Mainnet
networkFromMagic _ = Testnet
