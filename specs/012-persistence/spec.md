# Feature Specification: E3 Pending Transaction Store

## User Story

As the multisig coordinator, I need pending transaction state to live in a durable store so a restart does not lose unsigned transactions, collected witnesses, fee-payment references, or submission receipts.

## Functional Requirements

- FR-001: The library exposes a swappable `Store` interface, preferably a record of operations, for pending transaction wallet state.
- FR-002: A pending `Entry` stores an unsigned `ConwayTx`, its body-hash transaction id, the roster of required signers, collected witnesses, `invalidHereafter`, a fee-payment `TxIn`, and a status.
- FR-003: `EntryStatus` is limited to collecting, ready, submitted, and expired.
- FR-004: A `Receipt` stores the transaction id and the submission time.
- FR-005: The implementation reuses Cardano ledger/cardano-tx-tools chain types such as `ConwayTx` and `TxIn`; it does not redefine them.
- FR-006: At least one concrete backend is restart-safe and concurrency-safe.
- FR-007: Entries cannot be manually deleted. They leave active use only by expiry or resolution, with durable state as the source of truth.
- FR-008: Witness writes serialize under concurrent callers and preserve every distinct collected witness.

## Acceptance Criteria

- AC-001: Unit tests round-trip an entry through the public store interface.
- AC-002: Unit tests close and reopen the concrete backend and observe the same entry.
- AC-003: Unit tests perform concurrent witness writes and observe the serialized combined result.
- AC-004: The gate commands from the ticket brief pass locally before completion.

## Constraints

- Scope is limited to `src/Cardano/Multisig/Store.hs`, optional modules under `src/Cardano/Multisig/Store/`, `test/Cardano/Multisig/StoreSpec.hs`, and `cardano-multisig.cabal`.
- `Chain.hs` and `Server.hs` behavior are out of scope.
- The backend should follow the org RocksDB pattern already pinned in `cabal.project`: a single RocksDB instance, named column families, `mkRocksDBDatabase`, `mkColumns`, and atomic transaction writes.
