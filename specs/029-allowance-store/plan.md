# Implementation Plan: Allowance Store Model

## Technical Context

- Repo: `/code/cardano-multisig-29`
- Branch: `feat/allowance-store`
- PR: <https://github.com/lambdasistemi/cardano-multisig/pull/34>
- Parent epic: #26
- Child ticket: #29
- Dependency consumed from #28: `Cardano.Multisig.FeeTag.BodyHash`, currently
  an alias for `Cardano.Multisig.Store.EntryId`.
- Existing persistence: `Cardano.Multisig.Store`, `Store.Columns`, and
  `Store.RocksDB` use typed RocksDB column families with
  `rocksdb-kv-transactions`.

The inherited store already has three column families: entries, receipts, and
signer filters. Add one fee-payment column family and keep all mutations inside
the existing `RunTransaction` wrapper. The chain-follower rollback store in
`/code/chain-follower` uses cursor iteration plus `delete`; this ticket only
needs the simpler local pattern: scan fee-payment records and delete rows with
`block_slot > rollbackSlot` inside one transaction.

## Data Shape

Add public store model types in `Cardano.Multisig.Store`:

```haskell
data FeePayment = FeePayment
    { feePaymentBodyHash :: BodyHash
    , feePaymentTxIn :: TxIn
    , feePaymentLovelace :: Word64
    , feePaymentBlockSlot :: SlotNo
    }

data FeeAllowance = FeeAllowance
    { allowanceLovelace :: Word64
    , allowanceRequiredDepth :: Word
    , allowanceHasUnconfirmed :: Bool
    }
```

The implementation may add an internal `FeePaymentKey` newtype if that makes
the column codec clearer. The key semantics are exactly `(body_hash, txin)`.

Encode fee payments with the same local CBOR style used for `Entry` and
`Receipt`: fixed-length list, nested ledger encodings for `BodyHash`, `TxIn`,
and `SlotNo`, and a plain unsigned integer for lovelace. Expose
`encodeFeePayment` and `decodeFeePayment` only if useful for tests; otherwise
keep them private.

## Store API

Extend `StoreWithFilters` with:

```haskell
storeUpsertFeePayment :: FeePayment -> m ()
storeRollbackFeePaymentsFrom :: SlotNo -> m ()
storeAllowanceFor :: BodyHash -> SlotNo -> Word -> m FeeAllowance
```

RocksDB implementation:

- `storeUpsertFeePayment`: `insert FeePaymentsCol key (encodeFeePayment p)`.
  Because the key is `(body_hash, txin)`, reinserting the same payment replaces
  the row and remains idempotent.
- `storeRollbackFeePaymentsFrom`: iterate `FeePaymentsCol`, decode each value,
  and `delete` each row where `feePaymentBlockSlot > rollbackSlot`.
- `storeAllowanceFor`: iterate `FeePaymentsCol`, filter rows by body hash, then
  sum only final payments. Compute finality as:

  ```haskell
  fromIntegral (unSlotNo blockSlot) + fromIntegral depth
      <= fromIntegral (unSlotNo tip)
  ```

  so large depths cannot underflow. Set `allowanceHasUnconfirmed` when at least
  one matching payment is not final.

The plain `Store` constructor stays unchanged. This matches the existing split:
`StoreWithFilters` carries operations needed by the full service store, while
plain `Store` remains the narrower test/mock surface used by older publish
tests. The public record selectors are still exported from
`Cardano.Multisig.Store` because they are fields of `StoreWithFilters`.

## Slice Plan

### Slice 1: Store Model and RocksDB Behavior

Worker-owned files:

- `src/Cardano/Multisig/Store.hs`
- `src/Cardano/Multisig/Store/Columns.hs`
- `src/Cardano/Multisig/Store/RocksDB.hs`
- `test/Cardano/Multisig/StoreSpec.hs`
- `test/Cardano/Multisig/LivenessSpec.hs`
- `test/Cardano/Multisig/ServerSpec.hs`
- `cardano-multisig.cabal`

Work:

- Add `FeePayment` and `FeeAllowance` to the public store module and export
  them.
- Add fee-payment storage encoding/decoding and, if needed, an internal key
  codec.
- Add `FeePaymentsCol` to the store column GADT, ordering, equality, codec map,
  and RocksDB `storeColumnFamilies`.
- Extend `Store` and `StoreWithFilters` with the three new operations.
- Implement the operations in `mkRocksDBStore`.
- Update test mocks that construct `StoreWithFilters`.
- Add temp-RocksDB tests for all #29 acceptance cases, using an explicit
  `genFeePayment` QuickCheck generator where property coverage is useful.
- Do not touch `Publish.hs`, `Server.hs`, `Chain.hs`, OpenAPI, docs, Nix, or
  source pins.

Focused proof:

```bash
nix develop --quiet -c just unit "Cardano.Multisig.Store.RocksDB"
./gate.sh
```

Commit:

```text
feat: add allowance store model

Tasks: T001
```

### Slice 2: Orchestrator-Owned Finalization

Orchestrator-owned files/actions:

- `specs/029-allowance-store/tasks.md`
- PR #34 body and readiness state
- `gate.sh` removal after the final gate passes

Work:

- Verify implementation tasks are checked and commit history is coherent.
- Rerun `./gate.sh` at HEAD.
- Verify the repository-wide forbidden-token grep is empty.
- Verify GitHub CI for PR #34 is green and log `CI-PASS`.
- Update the PR body with delivered behavior and verification evidence.
- Drop `gate.sh` in the final ready-for-review commit.
- Mark PR #34 ready for review.
- Do not merge the PR.

## Risks and Controls

- Store API widening breaks mocks. Control: include every `StoreWithFilters`
  constructor in the slice owned-files list and run the full gate.
- Rollback can accidentally delete by body hash instead of by block slot.
  Control: acceptance tests must store payments for multiple body hashes across
  both sides of the rollback slot.
- Confirmation-depth arithmetic can underflow. Control: compare using widened
  integers instead of subtracting from `tip`.
- Idempotence can be hidden by a running-total design. Control: persist
  per-payment records keyed by `(body_hash, txin)` and compute sums from rows.
- The forbidden dependency can reappear in specs, comments, or cabal files.
  Control: `gate.sh` constructs the token at runtime and fails if `rg` finds a
  literal occurrence anywhere in the repo.
