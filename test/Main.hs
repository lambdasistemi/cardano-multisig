module Main
    ( main
    ) where

{- |
Module      : Main
Description : Unit test entry point
Copyright   : (c) lambdasistemi, 2026
License     : Apache-2.0
-}

import Cardano.Multisig.ServerSpec qualified as ServerSpec
import Test.Hspec (hspec)

-- | Run the full unit-test suite.
main :: IO ()
main = hspec ServerSpec.spec
