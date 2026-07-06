module Main
    ( main
    ) where

-- \|
-- Module      : Main
-- Description : Unit test entry point
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0

import Cardano.Multisig.ChainSpec qualified as ChainSpec
import Cardano.Multisig.PublishSpec qualified as PublishSpec
import Cardano.Multisig.ServerSpec qualified as ServerSpec
import Cardano.Multisig.StoreSpec qualified as StoreSpec
import Cardano.Multisig.WitnessSpec qualified as WitnessSpec
import Test.Hspec (hspec)

-- | Run the full unit-test suite.
main :: IO ()
main = hspec $ do
    ServerSpec.spec
    ChainSpec.spec
    PublishSpec.spec
    StoreSpec.spec
    WitnessSpec.spec
