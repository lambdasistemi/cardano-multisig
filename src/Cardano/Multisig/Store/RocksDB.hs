module Cardano.Multisig.Store.RocksDB
    ( mkRocksDBStore
    , withRocksDBStore
    )
where

import Cardano.Multisig.Store
    ( Entry (..)
    , EntryId
    , FeeAllowance (..)
    , FeePayment (..)
    , Store (..)
    , decodeEntry
    , decodeFeePayment
    , decodeReceipt
    , encodeEntry
    , encodeFeePayment
    , encodeReceipt
    )
import Cardano.Multisig.Store.Columns
    ( Columns (..)
    , FeePaymentKey (..)
    , codecs
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
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
        , storeUpsertFeePayment = \payment ->
            runTx
                $ KV.insert
                    FeePaymentsCol
                    (feePaymentKey payment)
                    (encodeFeePayment payment)
        , storeRollbackFeePaymentsFrom = \rollbackSlot ->
            runTx $ do
                rows <-
                    KV.iterating FeePaymentsCol
                        $ collectFeePaymentRows []
                let stale =
                        [ key
                        | (key, payment) <- rows
                        , feePaymentBlockSlot payment > rollbackSlot
                        ]
                traverse_ (KV.delete FeePaymentsCol) stale
        , storeAllowanceFor = \bodyHash tip depth ->
            runTx $ do
                rows <-
                    KV.iterating FeePaymentsCol
                        $ collectFeePaymentRows []
                pure
                    $ allowanceFromPayments
                        bodyHash
                        tip
                        depth
                        (map snd rows)
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
    , ("fee_payments", storeConfig)
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

feePaymentKey :: FeePayment -> FeePaymentKey
feePaymentKey FeePayment{..} =
    FeePaymentKey feePaymentBodyHash feePaymentTxIn

collectFeePaymentRows
    :: [(FeePaymentKey, FeePayment)]
    -> Cursor.Cursor
        (KV.Transaction IO ColumnFamily Columns BatchOp)
        (KV.KV FeePaymentKey ByteString)
        [(FeePaymentKey, FeePayment)]
collectFeePaymentRows acc = do
    next <-
        if null acc
            then Cursor.firstEntry
            else Cursor.nextEntry
    case next of
        Nothing -> pure (reverse acc)
        Just
            Cursor.Entry
                { Cursor.entryKey = key
                , Cursor.entryValue = bytes
                } ->
                case decodeStored "fee payment" decodeFeePayment (Just bytes) of
                    Nothing -> collectFeePaymentRows acc
                    Just payment -> collectFeePaymentRows ((key, payment) : acc)

allowanceFromPayments
    :: EntryId
    -> SlotNo
    -> Word
    -> [FeePayment]
    -> FeeAllowance
allowanceFromPayments bodyHash tip depth =
    toAllowance . foldl' step (0, False)
  where
    toAllowance (lovelace, hasPending) =
        FeeAllowance
            { allowanceLovelace = lovelace
            , allowanceRequiredDepth = depth
            , allowanceHasUnconfirmed = hasPending
            }

    step (lovelace, hasPending) payment
        | feePaymentBodyHash payment /= bodyHash = (lovelace, hasPending)
        | paymentIsFinal tip depth payment =
            (lovelace + feePaymentLovelace payment, hasPending)
        | otherwise = (lovelace, True)

paymentIsFinal :: SlotNo -> Word -> FeePayment -> Bool
paymentIsFinal tip depth payment =
    toInteger (unSlotNo (feePaymentBlockSlot payment))
        + toInteger depth
        <= toInteger (unSlotNo tip)
