module Main
    ( main
    ) where

{- |
Module      : Main
Description : cardano-multisig service entry point
Copyright   : (c) lambdasistemi, 2026
License     : Apache-2.0

Runs the Milestone-1 coordinator skeleton on a fixed port.
-}

import Cardano.Multisig.Server (runServer)

-- | Start the coordinator on port 8080.
main :: IO ()
main = runServer 8080
