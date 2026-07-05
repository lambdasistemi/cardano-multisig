module Cardano.Multisig.Version
    ( version
    ) where

{- |
Module      : Cardano.Multisig.Version
Description : Package version string
Copyright   : (c) lambdasistemi, 2026
License     : Apache-2.0

The build-time package version, surfaced by the service for operator
discovery.
-}

import Data.Version (showVersion)
import Paths_cardano_multisig qualified as Paths

-- | The package version as a dotted string, e.g. @"0.1.0.0"@.
version :: String
version = showVersion Paths.version
