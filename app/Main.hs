module Main
    ( main
    ) where

-- \|
-- Module      : Main
-- Description : cardano-multisig service entry point
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0
--
-- Reads @NETWORK@ (default @mainnet@) and @PORT@ (default @8080@) from
-- the environment and runs the Milestone-1 coordinator skeleton.

import Cardano.Multisig.Server (runServer)
import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | Start the coordinator, configured from the environment.
main :: IO ()
main = do
    network <- fromMaybe "mainnet" <$> lookupEnv "NETWORK"
    port <- fromMaybe 8080 . (>>= readMaybe) <$> lookupEnv "PORT"
    runServer port network
