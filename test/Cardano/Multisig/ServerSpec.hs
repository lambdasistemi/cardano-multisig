module Cardano.Multisig.ServerSpec
    ( spec
    ) where

-- \|
-- Module      : Cardano.Multisig.ServerSpec
-- Description : Unit tests for the WAI application skeleton
-- Copyright   : (c) lambdasistemi, 2026
-- License     : Apache-2.0

import Cardano.Multisig.Server (errorEnvelope, operatorSchedule)
import Data.Aeson (Value (Object), object, (.=))
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = do
    describe "errorEnvelope"
        $ it "nests code and message under an error key"
        $ errorEnvelope "not_found" "no such route"
        `shouldBe` object
            [ "error"
                .= object
                    [ "code" .= ("not_found" :: String)
                    , "message" .= ("no such route" :: String)
                    ]
            ]

    describe "operatorSchedule"
        $ it "is a JSON object for the given network"
        $ case operatorSchedule "preprod" of
            Object _ -> True `shouldBe` True
            _ -> operatorSchedule "preprod" `shouldBe` object []
