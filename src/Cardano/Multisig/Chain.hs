module Cardano.Multisig.Chain
    ( module Cardano.Tx.Validate
    ) where

-- \|
-- Module      : Cardano.Multisig.Chain
-- Description : Chain-access seam (E2 slice 1 — cardano-tx-tools linkage)
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0
--
-- E2 slice 1 proves the Cardano dependency closure builds and links by
-- re-exporting the phase-1 validator from cardano-tx-tools. Slice 2
-- replaces this with the real @ChainSource@ interface and an N2C-backed
-- implementation (cardano-tx-tools\' @n2c-resolver@ sublibrary).

import Cardano.Tx.Validate
