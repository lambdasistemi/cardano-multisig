module Cardano.Multisig.Server
    ( application
    , runServer
    , operatorSchedule
    , errorEnvelope
    ) where

{- |
Module      : Cardano.Multisig.Server
Description : WAI application skeleton for the /v1 coordinator API
Copyright   : (c) lambdasistemi, 2026
License     : Apache-2.0

Milestone-1 foundations: a credential-free CORS WAI application that
serves the operator discovery document and a health probe, and returns a
JSON error envelope with @501 Not Implemented@ for every documented but
not-yet-implemented @/v1@ route. Endpoint logic lands in later epics.
-}

import Data.Aeson (Value, encode, object, (.=))
import Network.HTTP.Types
    ( Status
    , hContentType
    , status200
    , status404
    , status501
    )
import Network.Wai
    ( Application
    , Response
    , pathInfo
    , requestMethod
    , responseLBS
    )
import Network.Wai.Handler.Warp (Port, run)
import Network.Wai.Middleware.Cors
    ( CorsResourcePolicy (..)
    , cors
    , simpleCorsResourcePolicy
    )

{- | A JSON error envelope,
@{ "error": { "code": code, "message": message } }@.
-}
errorEnvelope :: String -> String -> Value
errorEnvelope code message =
    object
        [ "error"
            .= object
                [ "code" .= code
                , "message" .= message
                ]
        ]

{- | The operator discovery and fee-schedule document. Static in
Milestone-1 foundations; a real schedule is wired in the publish epic.
-}
operatorSchedule :: Value
operatorSchedule =
    object
        [ "network" .= ("mainnet" :: String)
        , "fee"
            .= object
                [ "base_lovelace" .= (1000000 :: Int)
                , "rate_lovelace_per_slot" .= (12 :: Int)
                , "address" .= ("" :: String)
                , "tag_field" .= ("body_hash_blake2b_256" :: String)
                ]
        , "ttl_horizon_slots" .= (864000 :: Int)
        , "roster_types" .= (["required_signers"] :: [String])
        ]

healthy :: Value
healthy = object ["status" .= ("ok" :: String)]

jsonResponse :: Status -> Value -> Response
jsonResponse status body =
    responseLBS
        status
        [(hContentType, "application/json")]
        (encode body)

{- | The WAI application. Serves the operator schedule and a health
probe; every other @/v1@ route returns a @501@ envelope, and anything
else a @404@.
-}
application :: Application
application request respond =
    respond $ case (requestMethod request, pathInfo request) of
        ("GET", ["v1", "operator"]) ->
            jsonResponse status200 operatorSchedule
        ("GET", ["v1", "health"]) ->
            jsonResponse status200 healthy
        ("GET", ["health"]) ->
            jsonResponse status200 healthy
        (_, "v1" : _) ->
            jsonResponse status501
                $ errorEnvelope
                    "not_implemented"
                    "route not implemented in Milestone-1 foundations"
        _ ->
            jsonResponse status404
                $ errorEnvelope "not_found" "no such route"

-- | Run the service with a credential-free CORS policy on the given port.
runServer :: Port -> IO ()
runServer port = run port $ cors (const $ Just policy) application
  where
    policy =
        simpleCorsResourcePolicy
            { corsMethods = ["GET", "POST", "PUT", "OPTIONS"]
            , corsRequestHeaders = ["Content-Type"]
            }
