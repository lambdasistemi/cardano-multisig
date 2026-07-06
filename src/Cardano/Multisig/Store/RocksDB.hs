module Cardano.Multisig.Store.RocksDB
    ( mkRocksDBStore
    , withRocksDBStore
    )
where

import Cardano.Multisig.Store
    ( Entry (..)
    , EntryId
    , Store (..)
    , decodeEntry
    , decodeReceipt
    , encodeEntry
    , encodeReceipt
    )
import Cardano.Multisig.Store.Columns
    ( Columns (..)
    , codecs
    )
import Data.ByteString (ByteString)
import Database.KV.Cursor qualified as Cursor
import Database.KV.Database (Database, mkColumns)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction qualified as KV
import Database.RocksDB
    ( BatchOp
    , ColumnFamily
    , Config (..)
    , DB
    , columnFamilies
    , withDBCF
    )

withRocksDBStore :: FilePath -> (Store IO -> IO a) -> IO a
withRocksDBStore path action =
    withDBCF path storeConfig storeColumnFamilies $ \db -> do
        runTx <- KV.newRunTransaction (mkStoreDatabase db)
        action (mkRocksDBStore runTx)

mkRocksDBStore
    :: KV.RunTransaction IO ColumnFamily Columns BatchOp
    -> Store IO
mkRocksDBStore (KV.RunTransaction runTx) =
    StoreWithFilters
        { storePutEntry = \entry ->
            runTx $ KV.insert EntriesCol (entryId entry) (encodeEntry entry)
        , storeLookupEntry = \eid ->
            runTx
                $ decodeStored "entry" decodeEntry
                    <$> KV.query EntriesCol eid
        , storeListEntries =
            runTx
                $ KV.iterating EntriesCol
                $ collectEntries []
        , storeCollectWitnesses = \eid witnesses ->
            runTx $ do
                current <-
                    decodeStored "entry" decodeEntry
                        <$> KV.query EntriesCol eid
                case current of
                    Nothing -> pure ()
                    Just entry ->
                        KV.insert EntriesCol eid
                            $ encodeEntry
                                entry
                                    { entryCollectedWitnesses =
                                        entryCollectedWitnesses entry <> witnesses
                                    }
        , storePutReceipt = \eid receipt ->
            runTx $ KV.insert ReceiptsCol eid (encodeReceipt receipt)
        , storeLookupReceipt = \eid ->
            runTx
                $ decodeStored "receipt" decodeReceipt
                    <$> KV.query ReceiptsCol eid
        , storePutSignerFilter = \signer policy ->
            runTx $ KV.insert SignerFiltersCol signer policy
        , storeLookupSignerFilter =
            runTx . KV.query SignerFiltersCol
        }

mkStoreDatabase :: DB -> Database IO ColumnFamily Columns BatchOp
mkStoreDatabase db =
    mkRocksDBDatabase db $ mkColumns (columnFamilies db) codecs

decodeStored
    :: String
    -> (ByteString -> Maybe a)
    -> Maybe ByteString
    -> Maybe a
decodeStored _ _ Nothing =
    Nothing
decodeStored label decoder (Just bytes) =
    case decoder bytes of
        Just value -> Just value
        Nothing -> error ("could not decode stored " <> label)

storeColumnFamilies :: [(String, Config)]
storeColumnFamilies =
    [ ("entries", storeConfig)
    , ("receipts", storeConfig)
    , ("signer_filters", storeConfig)
    ]

storeConfig :: Config
storeConfig =
    Config
        { createIfMissing = True
        , errorIfExists = False
        , paranoidChecks = False
        , maxFiles = Nothing
        , prefixLength = Nothing
        , bloomFilter = False
        }

collectEntries
    :: [Entry]
    -> Cursor.Cursor
        (KV.Transaction IO ColumnFamily Columns BatchOp)
        (KV.KV EntryId ByteString)
        [Entry]
collectEntries acc = do
    next <-
        if null acc
            then Cursor.firstEntry
            else Cursor.nextEntry
    case next of
        Nothing -> pure (reverse acc)
        Just Cursor.Entry{Cursor.entryValue = bytes} ->
            case decodeStored "entry" decodeEntry (Just bytes) of
                Nothing -> collectEntries acc
                Just entry -> collectEntries (entry : acc)
