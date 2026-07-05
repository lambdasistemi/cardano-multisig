# Implementation Plan: E3 Pending Transaction Store

## Current Context

The branch starts clean at `f13d7f4`, which is also `origin/main` and includes the E2 chain-source work. `cabal.project` already pins `rocksdb-haskell`, `rocksdb-kv-transactions`, and `cardano-tx-tools`.

Existing local patterns:

- `/code/cardano-stake-csmt/lib/Cardano/StakeCSMT/Store/RocksDB.hs` opens one RocksDB handle with all column families and adapts it via `mkRocksDBDatabase db $ mkColumns (columnFamilies db) codecs`.
- `/code/cardano-stake-csmt/lib/Cardano/StakeCSMT/*/Columns.hs` models typed `KV` columns using a GADT plus `GEq`, `GCompare`, and a `DMap Columns Codecs`.
- `/code/cardano-utxo-csmt/lib/Cardano/UTxOCSMT/Application/Database/RocksDB.hs` wraps `Database.KV.Transaction.newRunTransaction` for guarded serialized writes.

## Design

Add `Cardano.Multisig.Store` as the public interface and domain module. Use a record-of-ops store shape so HTTP and later ticket work can inject alternative implementations without typeclass plumbing.

Expected public surface:

- `EntryId` wraps the body-hash `TxId`.
- `Entry` includes the unsigned `ConwayTx`, required signers, collected witnesses, `invalidHereafter`, fee-payment `TxIn`, and `EntryStatus`.
- `Receipt` includes `TxId` and a submitted-at timestamp.
- `Store` exposes write/read entry operations, witness collection, status transitions, expiry/resolution helpers, and receipt read/write as needed by the tests.
- `entryIdFromTx` computes `TxId (hashAnnotated (tx ^. bodyTxL))`, matching cardano-tx-tools `tx-graph`.

Add a concrete RocksDB backend under `Cardano.Multisig.Store.RocksDB` plus small internal column/codecs modules if needed. The backend should:

- Open a single RocksDB DB with named column families such as `entries` and `receipts`.
- Use `rocksdb-kv-transactions` `KV` columns and guarded `newRunTransaction` or an explicit `MVar`/guard around `runTransactionUnguarded` if the library surface requires it.
- Store ledger values as CBOR bytes through ledger `EncCBOR`/`DecCBOR` codecs and `eraProtVerLow @ConwayEra`/`natVersion @11`-style helpers used in sibling repos.
- Preserve all state durably; no manual delete API is exported.

## Slices

### Slice A: Store interface and RocksDB backend

One bisect-safe behavior-changing commit implements the full ticket surface and tests. This is acceptable as one slice because the public interface, backend, cabal exposure, and tests are tightly coupled: splitting the interface from the backend would create either unused API churn or a backend-less acceptance gap.

Owned files:

- `src/Cardano/Multisig/Store.hs`
- `src/Cardano/Multisig/Store/RocksDB.hs`
- Optional `src/Cardano/Multisig/Store/Columns.hs`
- Optional `src/Cardano/Multisig/Store/Codecs.hs`
- `test/Cardano/Multisig/StoreSpec.hs`
- `test/Main.hs`
- `cardano-multisig.cabal`

Focused verification:

- `nix develop --quiet -c just unit Store`
- `nix build .#cardano-multisig .#unit-tests`
- `nix develop --quiet -c just ci`

## Risks

- Ledger witness types and CBOR instances are easy to misname. The driver should use `hoogle`/local source rather than guessing imports.
- If `Database.KV.Transaction.newRunTransaction` type constraints are awkward in this repo, a narrow `MVar` around `runTransactionUnguarded` is acceptable only if the backend still writes via one RocksDB instance and one atomic transaction per operation.
- The tests may need lightweight synthetic `ConwayTx`/witness fixtures. Use existing ledger constructors or decode a small CBOR fixture in the test; do not introduce broad fixture infrastructure.
