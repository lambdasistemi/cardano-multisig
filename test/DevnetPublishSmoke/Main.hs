{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Main
    ( main
    ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, onException)
import Control.Monad (when)
import Data.Aeson
    ( FromJSON (..)
    , Value (..)
    , eitherDecodeStrict'
    , encode
    , object
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock
    ( UTCTime
    , addUTCTime
    , getCurrentTime
    )
import Data.Time.Clock.POSIX
    ( utcTimeToPOSIXSeconds
    )
import Data.Time.Format
    ( defaultTimeLocale
    , formatTime
    )
import Network.Socket
    ( Family (AF_INET)
    , SockAddr (SockAddrInet)
    , SocketType (Stream)
    , bind
    , close
    , defaultProtocol
    , getSocketName
    , socket
    , tupleToHostAddress
    )
import System.Directory
    ( copyFile
    , createDirectoryIfMissing
    , doesFileExist
    , getCurrentDirectory
    , removePathForcibly
    )
import System.Environment
    ( getEnvironment
    , lookupEnv
    )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
    ( BufferMode (..)
    , Handle
    , IOMode (..)
    , hClose
    , hSetBuffering
    , openFile
    )
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
    ( ownerReadMode
    , ownerWriteMode
    , setFileMode
    , unionFileModes
    )
import System.Process
    ( CreateProcess (..)
    , ProcessHandle
    , StdStream (..)
    , createProcess
    , getProcessExitCode
    , proc
    , readCreateProcessWithExitCode
    , readProcessWithExitCode
    , terminateProcess
    , waitForProcess
    )

networkMagic :: String
networkMagic = "42"

baseLovelace :: Integer
baseLovelace = 1_024_000

fixedFee :: Integer
fixedFee = 200_000

fundingLovelace :: Integer
fundingLovelace = 80_000_000

main :: IO ()
main = do
    cwd <- getCurrentDirectory
    genesisDir <-
        fromMaybe (cwd </> "test/fixtures/devnet-genesis")
            <$> lookupEnv "E2E_GENESIS_DIR"
    withSystemTempDirectory "devnet-publish-smoke" $ \tmp -> do
        putStrLn ("devnet-publish-smoke: run dir " <> tmp)
        withNode genesisDir tmp $ \nodeSock -> do
            waitForCliTip nodeSock
            writeGenesisKey tmp
            wallet <- createWallet tmp "wallet"
            fee <- createWallet tmp "fee"
            genesisAddr <- addressFromKey tmp "genesis"

            genesisUtxo <- waitForUtxos nodeSock genesisAddr 1
            fundWallet nodeSock tmp genesisAddr wallet genesisUtxo
            walletUtxos <- waitForUtxos nodeSock (walletAddress wallet) 2
            (publishUtxo, feeUtxo) <-
                case sortOn (Down . utxoLovelace) walletUtxos of
                    publishUtxo : feeUtxo : _ ->
                        pure (publishUtxo, feeUtxo)
                    other ->
                        fail
                            ( "expected at least two wallet UTxOs, got "
                                <> show other
                            )

            publishTx <-
                buildPublishTx
                    nodeSock
                    tmp
                    wallet
                    publishUtxo
            withServer nodeSock tmp (walletAddress fee) $ \baseUrl -> do
                quote <-
                    postJson 200 baseUrl "/v1/fee-quote"
                        $ object ["transaction" .= publishTx]
                quoteBody <- decodeJson "fee quote" quote
                assertEqual
                    "required fee"
                    baseLovelace
                    (quoteRequiredFee quoteBody)

                firstStatus <-
                    getJson
                        200
                        baseUrl
                        ("/v1/fee-status/" <> quoteBodyHash quoteBody)
                status0 <- decodeJson "initial fee status" firstStatus
                assertEqual
                    "initial fee reason"
                    (Just "fee_not_seen")
                    (statusReason status0)
                putStrLn "devnet-publish-smoke: observed fee_not_seen"

                payQuotedFee
                    nodeSock
                    tmp
                    wallet
                    feeUtxo
                    (quoteFeeAddress quoteBody)
                    (quoteBodyHash quoteBody)
                    (quoteRequiredFee quoteBody)

                pollReady baseUrl (quoteBodyHash quoteBody) False 2_400

                entry <-
                    postJson 201 baseUrl "/v1/entries"
                        $ object ["transaction" .= publishTx]
                entryBody <- decodeJson "entry response" entry
                receipt <-
                    postJson
                        200
                        baseUrl
                        ( "/v1/entries/"
                            <> entryId entryBody
                            <> "/submit"
                        )
                        (object [])
                assertReceipt receipt
                putStrLn
                    "devnet-publish-smoke: OK fee_not_seen -> fee_unconfirmed -> ready_to_publish"

data Wallet = Wallet
    { walletName :: String
    , walletSkey :: FilePath
    , walletVkey :: FilePath
    , walletAddress :: Text
    }

data UTxO = UTxO
    { utxoRef :: Text
    , utxoLovelace :: Integer
    }
    deriving stock (Eq, Show)

data Quote = Quote
    { quoteBodyHash :: Text
    , quoteRequiredFee :: Integer
    , quoteFeeAddress :: Text
    }

instance FromJSON Quote where
    parseJSON =
        withObject "Quote" $ \o ->
            Quote
                <$> o .: "body_hash"
                <*> o .: "required_fee_lovelace"
                <*> o .: "fee_address"

data FeeStatus = FeeStatus
    { statusReason :: Maybe Text
    , statusReady :: Bool
    }
    deriving stock (Show)

instance FromJSON FeeStatus where
    parseJSON =
        withObject "FeeStatus" $ \o ->
            FeeStatus
                <$> o .:? "reason"
                <*> o .: "ready_to_publish"

newtype EntryResponse = EntryResponse
    { entryId :: Text
    }

instance FromJSON EntryResponse where
    parseJSON =
        withObject "EntryResponse" $ \o ->
            EntryResponse <$> o .: "entry_id"

decodeJson :: FromJSON a => String -> Value -> IO a
decodeJson name value =
    case fromJSONValue value of
        Left err -> fail (name <> ": " <> err)
        Right parsed -> pure parsed

fromJSONValue :: FromJSON a => Value -> Either String a
fromJSONValue value =
    eitherDecodeStrict' (BL.toStrict (encode value))

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
    if actual == expected
        then pure ()
        else
            fail
                $ label
                    <> ": expected "
                    <> show expected
                    <> ", got "
                    <> show actual

withNode :: FilePath -> FilePath -> (FilePath -> IO a) -> IO a
withNode srcGenesis tmp action = do
    nodeDir <- prepareNodeDir srcGenesis tmp
    let logPath = tmp </> "cardano-node.log"
        sock = nodeDir </> "node.sock"
    bracket
        (spawnLogged logPath "cardano-node" (nodeArgs nodeDir) [])
        cleanupProcess
        ( \_ -> do
            waitForFile sock 300
            action sock
        )
        `onException` dumpLog logPath

prepareNodeDir :: FilePath -> FilePath -> IO FilePath
prepareNodeDir srcGenesis tmp = do
    now <- getCurrentTime
    let startTime = addUTCTime 15 now
        nodeDir = tmp </> "node"
        keysDir = nodeDir </> "delegate-keys"
    removePathForcibly nodeDir
    createDirectoryIfMissing True keysDir
    createDirectoryIfMissing True (nodeDir </> "db")
    mapM_
        (copyGenesisFile srcGenesis nodeDir)
        [ "alonzo-genesis.json"
        , "conway-genesis.json"
        , "dijkstra-genesis.json"
        , "node-config.json"
        , "topology.json"
        ]
    patchShelley startTime srcGenesis nodeDir
    patchByron startTime srcGenesis nodeDir
    mapM_
        (copyDelegateKey srcGenesis keysDir)
        [ "delegate1.kes.skey"
        , "delegate1.vrf.skey"
        , "delegate1.opcert"
        ]
    pure nodeDir

copyGenesisFile :: FilePath -> FilePath -> FilePath -> IO ()
copyGenesisFile src dst name =
    copyFile (src </> name) (dst </> name)

copyDelegateKey :: FilePath -> FilePath -> FilePath -> IO ()
copyDelegateKey src dst name = do
    let path = dst </> name
    copyFile (src </> "delegate-keys" </> name) path
    setFileMode path (ownerReadMode `unionFileModes` ownerWriteMode)

patchShelley :: UTCTime -> FilePath -> FilePath -> IO ()
patchShelley startTime src dst = do
    let formatted =
            BS8.pack
                $ formatTime
                    defaultTimeLocale
                    "%Y-%m-%dT%H:%M:%SZ"
                    startTime
    patchFile
        (src </> "shelley-genesis.json")
        (dst </> "shelley-genesis.json")
        "PLACEHOLDER"
        formatted

patchByron :: UTCTime -> FilePath -> FilePath -> IO ()
patchByron startTime src dst = do
    let epoch =
            BS8.pack
                $ show
                    ( floor (utcTimeToPOSIXSeconds startTime)
                        :: Int
                    )
    patchFile
        (src </> "byron-genesis.json")
        (dst </> "byron-genesis.json")
        "\"startTime\": 0"
        ("\"startTime\": " <> epoch)

patchFile
    :: FilePath -> FilePath -> BS.ByteString -> BS.ByteString -> IO ()
patchFile src dst needle replacement = do
    content <- BS.readFile src
    BS.writeFile dst (replaceOnce needle replacement content)

replaceOnce
    :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
replaceOnce needle replacement content =
    let (before, after) = BS.breakSubstring needle content
    in  if BS.null after
            then content
            else before <> replacement <> BS.drop (BS.length needle) after

nodeArgs :: FilePath -> [String]
nodeArgs nodeDir =
    [ "run"
    , "--config"
    , nodeDir </> "node-config.json"
    , "--topology"
    , nodeDir </> "topology.json"
    , "--database-path"
    , nodeDir </> "db"
    , "--socket-path"
    , nodeDir </> "node.sock"
    , "--shelley-kes-key"
    , nodeDir </> "delegate-keys/delegate1.kes.skey"
    , "--shelley-vrf-key"
    , nodeDir </> "delegate-keys/delegate1.vrf.skey"
    , "--shelley-operational-certificate"
    , nodeDir </> "delegate-keys/delegate1.opcert"
    ]

writeGenesisKey :: FilePath -> IO ()
writeGenesisKey tmp =
    BL.writeFile (tmp </> "genesis.skey")
        $ encode
        $ object
            [ "type" .= ("PaymentSigningKeyShelley_ed25519" :: Text)
            , "description" .= ("Genesis UTxO signing key" :: Text)
            , "cborHex"
                .= ( "58206532652d67656e657369732d7574786f2d6b65792d736565642d303030303031"
                        :: Text
                   )
            ]

createWallet :: FilePath -> String -> IO Wallet
createWallet tmp name = do
    let skey = tmp </> name <> ".skey"
        vkey = tmp </> name <> ".vkey"
    runCli
        [ "address"
        , "key-gen"
        , "--verification-key-file"
        , vkey
        , "--signing-key-file"
        , skey
        ]
    addr <- addressFromKey tmp name
    pure
        Wallet
            { walletName = name
            , walletSkey = skey
            , walletVkey = vkey
            , walletAddress = addr
            }

addressFromKey :: FilePath -> String -> IO Text
addressFromKey tmp name = do
    let skey = tmp </> name <> ".skey"
        vkey = tmp </> name <> ".vkey"
        addr = tmp </> name <> ".addr"
    exists <- doesFileExist vkey
    if exists
        then pure ()
        else
            runCli
                [ "key"
                , "verification-key"
                , "--signing-key-file"
                , skey
                , "--verification-key-file"
                , vkey
                ]
    runCli
        [ "address"
        , "build"
        , "--payment-verification-key-file"
        , vkey
        , "--testnet-magic"
        , networkMagic
        , "--out-file"
        , addr
        ]
    Text.strip . Text.decodeUtf8 <$> BS.readFile addr

fundWallet
    :: FilePath -> FilePath -> Text -> Wallet -> [UTxO] -> IO ()
fundWallet nodeSock tmp genesisAddr wallet utxos =
    case sortOn (Down . utxoLovelace) utxos of
        [] -> fail "no genesis UTxO"
        seed : _ -> do
            ttl <- ttlSlot nodeSock
            let out1 = fundingLovelace
                out2 = fundingLovelace
                change = utxoLovelace seed - out1 - out2 - fixedFee
            when (change <= 0)
                $ fail "genesis UTxO too small to fund smoke wallet"
            buildRaw
                nodeSock
                tmp
                "fund-wallet"
                [ "--tx-in"
                , Text.unpack (utxoRef seed)
                , "--tx-out"
                , Text.unpack (walletAddress wallet) <> "+" <> show out1
                , "--tx-out"
                , Text.unpack (walletAddress wallet) <> "+" <> show out2
                , "--tx-out"
                , Text.unpack genesisAddr <> "+" <> show change
                , "--invalid-hereafter"
                , show ttl
                , "--fee"
                , show fixedFee
                ]
                [tmp </> "genesis.skey"]
            submitTx nodeSock (tmp </> "fund-wallet.signed")

buildPublishTx :: FilePath -> FilePath -> Wallet -> UTxO -> IO Text
buildPublishTx nodeSock tmp wallet utxo = do
    ttl <- ttlSlot nodeSock
    let change = utxoLovelace utxo - fixedFee
    when (change <= 0) $ fail "publish UTxO too small"
    buildRaw
        nodeSock
        tmp
        "publish"
        [ "--tx-in"
        , Text.unpack (utxoRef utxo)
        , "--tx-out"
        , Text.unpack (walletAddress wallet) <> "+" <> show change
        , "--invalid-hereafter"
        , show ttl
        , "--fee"
        , show fixedFee
        ]
        [walletSkey wallet]
    readTxCborHex (tmp </> "publish.signed")

payQuotedFee
    :: FilePath
    -> FilePath
    -> Wallet
    -> UTxO
    -> Text
    -> Text
    -> Integer
    -> IO ()
payQuotedFee nodeSock tmp wallet utxo feeAddress bodyHash required = do
    assertEqual "quoted fee amount" baseLovelace required
    ttl <- ttlSlot nodeSock
    let change = utxoLovelace utxo - required - fixedFee
        meta = tmp </> "fee-metadata.json"
    when (change <= 0) $ fail "fee UTxO too small"
    BL.writeFile meta
        $ encode
        $ object
            [ "9721" .= object ["body_hash" .= bodyHash]
            ]
    buildRaw
        nodeSock
        tmp
        "fee-payment"
        [ "--tx-in"
        , Text.unpack (utxoRef utxo)
        , "--tx-out"
        , Text.unpack feeAddress <> "+" <> show required
        , "--tx-out"
        , Text.unpack (walletAddress wallet) <> "+" <> show change
        , "--invalid-hereafter"
        , show ttl
        , "--fee"
        , show fixedFee
        , "--json-metadata-no-schema"
        , "--metadata-json-file"
        , meta
        ]
        [walletSkey wallet]
    submitTx nodeSock (tmp </> "fee-payment.signed")

buildRaw
    :: FilePath -> FilePath -> String -> [String] -> [FilePath] -> IO ()
buildRaw nodeSock tmp name rawArgs skeys = do
    let body = tmp </> name <> ".body"
        signed = tmp </> name <> ".signed"
    runCli
        $ [ "latest"
          , "transaction"
          , "build-raw"
          ]
            <> rawArgs
            <> ["--out-file", body]
    runCli
        $ [ "latest"
          , "transaction"
          , "sign"
          , "--tx-body-file"
          , body
          , "--testnet-magic"
          , networkMagic
          ]
            <> concatMap
                (\skey -> ["--signing-key-file", skey])
                skeys
            <> ["--out-file", signed]
    _ <- nodeSock `seq` pure ()
    pure ()

submitTx :: FilePath -> FilePath -> IO ()
submitTx nodeSock txFile =
    runCli
        [ "latest"
        , "transaction"
        , "submit"
        , "--tx-file"
        , txFile
        , "--testnet-magic"
        , networkMagic
        , "--socket-path"
        , nodeSock
        ]

readTxCborHex :: FilePath -> IO Text
readTxCborHex path = do
    bytes <- BS.readFile path
    case eitherDecodeStrict' bytes of
        Right (Object o)
            | Just (String cborHex) <- KeyMap.lookup "cborHex" o ->
                pure cborHex
        _ ->
            pure (Text.decodeUtf8 (Base16.encode bytes))

waitForCliTip :: FilePath -> IO ()
waitForCliTip nodeSock = go (120 :: Int)
  where
    go 0 = fail "cardano-cli query tip never succeeded"
    go n =
        queryTip nodeSock >>= \case
            Just{} -> pure ()
            Nothing -> threadDelay 1_000_000 >> go (n - 1)

ttlSlot :: FilePath -> IO Integer
ttlSlot nodeSock = do
    tip <- queryTip nodeSock
    case tip of
        Just slot -> pure (slot + 1_000)
        Nothing -> fail "cannot query tip for TTL"

queryTip :: FilePath -> IO (Maybe Integer)
queryTip nodeSock = do
    result <-
        tryCli
            [ "query"
            , "tip"
            , "--testnet-magic"
            , networkMagic
            , "--socket-path"
            , nodeSock
            , "--out-file"
            , "/dev/stdout"
            ]
    case result of
        Left{} -> pure Nothing
        Right out ->
            case eitherDecodeStrict' (BS8.pack out) of
                Right (Object o)
                    | Just (Number n) <- KeyMap.lookup "slot" o ->
                        pure (Just (floor n))
                _ -> pure Nothing

waitForUtxos :: FilePath -> Text -> Int -> IO [UTxO]
waitForUtxos nodeSock addr minimumCount = go (90 :: Int)
  where
    go 0 = fail ("timed out waiting for UTxOs at " <> Text.unpack addr)
    go n = do
        utxos <- queryUtxos nodeSock addr
        if length utxos >= minimumCount
            then pure utxos
            else threadDelay 1_000_000 >> go (n - 1)

queryUtxos :: FilePath -> Text -> IO [UTxO]
queryUtxos nodeSock addr = do
    out <-
        runCliOut
            [ "query"
            , "utxo"
            , "--address"
            , Text.unpack addr
            , "--testnet-magic"
            , networkMagic
            , "--socket-path"
            , nodeSock
            , "--out-file"
            , "/dev/stdout"
            ]
    case eitherDecodeStrict' (BS8.pack out) of
        Right (Object o) ->
            traverse parseUtxo (KeyMap.toList o)
        Right{} -> fail "query utxo returned non-object JSON"
        Left err -> fail ("query utxo JSON decode failed: " <> err)

parseUtxo :: (Key.Key, Value) -> IO UTxO
parseUtxo (key, value) =
    case value of
        Object o
            | Just (Object v) <- KeyMap.lookup "value" o
            , Just (Number n) <- KeyMap.lookup "lovelace" v ->
                pure
                    UTxO
                        { utxoRef = Key.toText key
                        , utxoLovelace = floor n
                        }
        _ -> fail ("unexpected UTxO JSON for " <> Text.unpack (Key.toText key))

withServer :: FilePath -> FilePath -> Text -> (String -> IO a) -> IO a
withServer nodeSock tmp feeAddr action = do
    port <- show <$> openFreePort
    let
        baseUrl = "http://127.0.0.1:" <> port
        logPath = tmp </> "cardano-multisig-server.log"
        env =
            [ ("PORT", port)
            , ("NETWORK", "devnet")
            , ("CARDANO_NODE_SOCKET", nodeSock)
            , ("CARDANO_NODE_MAGIC", networkMagic)
            , ("CARDANO_MULTISIG_STORE", tmp </> "store")
            , ("FEE_ADDRESS", Text.unpack feeAddr)
            , ("BASE_LOVELACE", show baseLovelace)
            , ("RATE_LOVELACE_PER_SLOT", "0")
            , ("TTL_HORIZON_SLOTS", "100000")
            , ("FEE_INDEXER_CHECKPOINT_DIR", tmp </> "fee-indexer")
            , ("FEE_INDEXER_RETRY_DELAY_MICROS", "1000000")
            , ("FEE_INDEXER_BYRON_EPOCH_SLOTS", "42")
            ]
    bracket
        (spawnLogged logPath "cardano-multisig-server" [] env)
        cleanupProcess
        ( \(ph, _) -> do
            waitForHealth ph baseUrl 180 Nothing
            action baseUrl
        )
        `onException` dumpLog logPath

openFreePort :: IO Int
openFreePort =
    bracket
        (socket AF_INET Stream defaultProtocol)
        close
        ( \sock -> do
            bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
            getSocketName sock >>= \case
                SockAddrInet port _ ->
                    pure (fromIntegral port)
                other ->
                    fail ("unexpected socket address: " <> show other)
        )

waitForHealth
    :: ProcessHandle -> String -> Int -> Maybe String -> IO ()
waitForHealth ph baseUrl = go
  where
    go 0 seen =
        fail
            $ "server health endpoint never became ready; last probe: "
                <> fromMaybe "<none>" seen
    go n _seen = do
        getProcessExitCode ph >>= \case
            Just code ->
                fail ("server process exited before health: " <> show code)
            Nothing ->
                curl "GET" (baseUrl <> "/health") Nothing >>= \case
                    Right (200, _) -> pure ()
                    Right (status, body) ->
                        threadDelay 1_000_000
                            >> go
                                (n - 1)
                                (Just ("HTTP " <> show status <> " " <> body))
                    Left err ->
                        threadDelay 1_000_000 >> go (n - 1) (Just err)

pollReady :: String -> Text -> Bool -> Int -> IO ()
pollReady baseUrl bodyHash seenUnconfirmed attempts =
    go seenUnconfirmed attempts Nothing
  where
    go _ 0 lastStatus =
        fail
            $ "fee status never reached ready_to_publish; last status: "
                <> show lastStatus
    go seen n _lastStatus = do
        value <- getJson 200 baseUrl ("/v1/fee-status/" <> bodyHash)
        status <- decodeJson "fee status" value
        let sawUnconfirmed =
                seen || statusReason status == Just "fee_unconfirmed"
        when (statusReason status == Just "fee_unconfirmed" && not seen)
            $ putStrLn "devnet-publish-smoke: observed fee_unconfirmed"
        if statusReady status && sawUnconfirmed
            then putStrLn "devnet-publish-smoke: observed ready_to_publish"
            else do
                threadDelay 50_000
                go sawUnconfirmed (n - 1) (Just status)

getJson :: Int -> String -> Text -> IO Value
getJson expected baseUrl path =
    requestJson expected "GET" (baseUrl <> Text.unpack path) Nothing

postJson :: Int -> String -> Text -> Value -> IO Value
postJson expected baseUrl path body =
    requestJson expected "POST" (baseUrl <> Text.unpack path) (Just body)

requestJson :: Int -> String -> String -> Maybe Value -> IO Value
requestJson expected method url body = do
    result <- curl method url body
    case result of
        Left err -> fail err
        Right (status, response)
            | status == expected ->
                case eitherDecodeStrict' (BS8.pack response) of
                    Right value -> pure value
                    Left err ->
                        fail
                            ( "invalid JSON response from "
                                <> url
                                <> ": "
                                <> err
                                <> "\n"
                                <> response
                            )
            | otherwise ->
                fail
                    ( "unexpected HTTP "
                        <> show status
                        <> " from "
                        <> url
                        <> ": "
                        <> response
                    )

curl
    :: String -> String -> Maybe Value -> IO (Either String (Int, String))
curl method url body = do
    let bodyArgs =
            case body of
                Nothing -> []
                Just{} ->
                    [ "--header"
                    , "Content-Type: application/json"
                    , "--data-binary"
                    , "@-"
                    ]
        input =
            maybe "" (BS8.unpack . BL.toStrict . encode) body
    (code, out, err) <-
        readCreateProcessWithExitCode
            ( proc
                "curl"
                ( [ "--silent"
                  , "--show-error"
                  , "--request"
                  , method
                  , "--write-out"
                  , "\n%{http_code}"
                  ]
                    <> bodyArgs
                    <> [url]
                )
            )
            input
    case code of
        ExitFailure n ->
            pure (Left ("curl exited " <> show n <> ": " <> err))
        ExitSuccess ->
            case reverse (lines out) of
                statusLine : bodyLines
                    | all isDigit statusLine ->
                        pure
                            ( Right
                                ( read statusLine
                                , unlines (reverse bodyLines)
                                )
                            )
                _ -> pure (Left ("curl returned no HTTP status: " <> out))

assertReceipt :: Value -> IO ()
assertReceipt = \case
    Object o
        | Just (String txId) <- KeyMap.lookup "tx_id" o
        , not (Text.null txId)
        , Just{} <- KeyMap.lookup "submitted_at" o ->
            pure ()
    other -> fail ("unexpected receipt JSON: " <> show other)

spawnLogged
    :: FilePath
    -> FilePath
    -> [String]
    -> [(String, String)]
    -> IO (ProcessHandle, Handle)
spawnLogged logPath exe args overrides = do
    logH <- openFile logPath AppendMode
    hSetBuffering logH LineBuffering
    baseEnv <- getEnvironment
    let cp =
            (proc exe args)
                { std_out = UseHandle logH
                , std_err = UseHandle logH
                , env = Just (overrides <> baseEnv)
                }
    (_, _, _, ph) <- createProcess cp
    pure (ph, logH)

cleanupProcess :: (ProcessHandle, Handle) -> IO ()
cleanupProcess (ph, logH) = do
    terminateProcess ph
    _ <- waitForProcess ph
    hClose logH

runCli :: [String] -> IO ()
runCli args = do
    _ <- runCliOut args
    pure ()

runCliOut :: [String] -> IO String
runCliOut args =
    tryCli args >>= \case
        Right out -> pure out
        Left err -> fail err

tryCli :: [String] -> IO (Either String String)
tryCli args = do
    (code, out, err) <- readProcessWithExitCode "cardano-cli" args ""
    pure $ case code of
        ExitSuccess -> Right out
        ExitFailure n ->
            Left
                $ "cardano-cli "
                    <> unwords args
                    <> " exited "
                    <> show n
                    <> "\nstdout:\n"
                    <> out
                    <> "\nstderr:\n"
                    <> err

waitForFile :: FilePath -> Int -> IO ()
waitForFile path = go
  where
    go 0 = fail ("timed out waiting for " <> path)
    go n = do
        exists <- doesFileExist path
        if exists
            then pure ()
            else threadDelay 100_000 >> go (n - 1)

dumpLog :: FilePath -> IO ()
dumpLog path = do
    exists <- doesFileExist path
    when exists $ do
        content <- BS8.readFile path
        let logLines = BS8.lines content
            tailLines = drop (max 0 (length logLines - 80)) logLines
        BS8.putStrLn
            $ BS8.unlines ("=== " <> BS8.pack path <> " ===" : tailLines)
