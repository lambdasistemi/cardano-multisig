module Cardano.Multisig.Liveness
    ( EntryLiveness (..)
    , LivenessDeps (..)
    , entryLiveness
    , liveEntry
    , runLivenessMonitor
    , runLivenessTick
    )
where

-- \|
-- Module      : Cardano.Multisig.Liveness
-- Description : Liveness checks and expiry tick for multisig entries
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0
--
-- The liveness module keeps chain-dependent checks behind injected
-- functions so request handlers, the background monitor, and unit tests
-- can share the same small decisions. A monitor tick only mutates entries
-- that are still live from the coordinator's point of view: collecting or
-- ready entries whose TTL is already behind the observed chain tip.

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Multisig.Store
    ( Entry (..)
    , EntryStatus (..)
    , Store (..)
    )
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forever, when)
import Data.Set qualified as Set
import Lens.Micro ((^.))

-- | Public liveness result for a coordinator entry.
data EntryLiveness = EntryLiveness
    { elInputsUnspent :: Bool
    , elPhase1Ok :: Bool
    }
    deriving stock (Eq, Show)

-- | Chain and store dependencies required by liveness checks.
data LivenessDeps m = LivenessDeps
    { ldReadTip :: m SlotNo
    , ldInputUnspent :: TxIn -> m Bool
    , ldPhase1Ok :: ConwayTx -> m Bool
    , ldStore :: Store m
    }

-- | Check whether an entry is still live and should be monitored.
liveEntry :: Entry -> Bool
liveEntry entry =
    case entryStatus entry of
        EntryCollecting -> True
        EntryReady -> True
        EntrySubmitted -> False
        EntryExpired -> False

-- | Evaluate input and phase-1 liveness for an entry.
entryLiveness :: Monad m => LivenessDeps m -> Entry -> m EntryLiveness
entryLiveness deps entry = do
    inputsUnspent <-
        and
            <$> traverse
                (ldInputUnspent deps)
                (Set.toList $ entryTx entry ^. bodyTxL . inputsTxBodyL)
    phase1Ok <- ldPhase1Ok deps (entryTx entry)
    pure
        EntryLiveness
            { elInputsUnspent = inputsUnspent
            , elPhase1Ok = phase1Ok
            }

-- | Run one liveness monitor tick.
runLivenessTick :: Monad m => LivenessDeps m -> m ()
runLivenessTick deps = do
    tip <- ldReadTip deps
    entries <- storeListEntries (ldStore deps)
    mapM_ (expireIfPastTip tip) (filter liveEntry entries)
  where
    expireIfPastTip tip entry =
        when (entryInvalidHereafter entry < tip)
            $ storePutEntry (ldStore deps) entry{entryStatus = EntryExpired}

-- | Run the liveness monitor forever.
--
-- The interval is expressed in microseconds, matching 'threadDelay'. Any
-- exception raised by a tick is caught; the monitor then sleeps and retries.
runLivenessMonitor :: Int -> LivenessDeps IO -> IO ()
runLivenessMonitor intervalMicros deps =
    forever $ do
        _ <- try (runLivenessTick deps) :: IO (Either SomeException ())
        threadDelay intervalMicros
