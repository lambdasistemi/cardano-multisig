# Feature Specification: Allowance Store Model for Indexed Fee Payments

## User Story

As the fee-address indexer and publish admission gate, I need a rollback-aware
store model for tagged fee payments so the service can sum confirmed payments
for a body hash, ignore not-yet-final payments, and revoke payments from
orphaned blocks after a chain rollback.

## Background

Epic #26 replaces inline-datum fee checks with ordinary ADA payments tagged by
transaction metadata. Child #28 landed the shared `BodyHash` and metadata tag
contract. This ticket is child #2: it does not read blocks or decode metadata.
It persists already-decoded payment records that later children will produce or
consume.

The existing store already uses typed RocksDB column families and
`rocksdb-kv-transactions` for atomic operations. This ticket extends that
model rather than introducing a second persistence stack.

## Functional Requirements

- FR-001: The store MUST persist individual tagged fee payments keyed by
  `(body_hash, txin)`.
- FR-002: A fee payment record MUST contain `body_hash`, `txin`, `lovelace`,
  and `block_slot`.
- FR-003: `upsertFeePayment` MUST be idempotent: inserting the same
  `(body_hash, txin)` more than once MUST NOT double count the payment.
- FR-004: `rollbackFeePaymentsFrom rollbackSlot` MUST drop every stored fee
  payment whose `block_slot > rollbackSlot`, and MUST keep every payment whose
  `block_slot <= rollbackSlot`.
- FR-005: `allowanceFor bodyHash tip depth` MUST return the sum of lovelace for
  payments with the requested body hash that are final at the supplied tip and
  confirmation depth.
- FR-006: A payment is final when its `block_slot + depth <= tip`. This avoids
  underflow when `depth > tip` and is equivalent to `block_slot <= tip - depth`
  when subtraction is defined.
- FR-007: `allowanceFor` MUST report the required confirmation depth and whether
  any matching payment exists that is not final yet. Pending payments MUST NOT
  contribute to the confirmed lovelace sum.
- FR-008: Multiple final payments tagged with the same body hash MUST add
  together. A dust payment can only increase the allowance and cannot reduce or
  replace an existing payment.
- FR-009: The public store API MUST expose the fee-payment operations from
  `Cardano.Multisig.Store` so #30 can write indexed payments and #31 can read
  allowances.
- FR-010: The implementation MUST add a RocksDB column family for fee payments
  and reuse the existing transactional write/read discipline.

## Acceptance Criteria

- AC-001: Temp-RocksDB unit tests prove multi-payment summing for a body hash.
- AC-002: Temp-RocksDB unit tests prove idempotent reinsertion of the same txin.
- AC-003: Temp-RocksDB unit tests prove rollback removes exactly payments after
  the rollback slot and then re-derives the total from the remaining records.
- AC-004: Temp-RocksDB unit tests prove confirmation depth counts only final
  payments.
- AC-005: Temp-RocksDB unit tests prove a below-depth payment is reported as
  pending and is not counted.
- AC-006: The implementation uses existing ledger packages and MUST NOT add the
  forbidden high-level dependency or change Nix/source pins.
- AC-007: The branch passes `./gate.sh`, including
  `nix build .#cardano-multisig .#unit-tests`,
  `nix develop --quiet -c just ci`, and the repository-wide forbidden-token
  grep.
- AC-008: PR #34 is linked to #29, CI is green, and the PR is marked ready for
  review but not merged.

## Out of Scope

- No chain follower, block parsing, metadata decoding, or rollback event loop.
  Those belong to #30.
- No publish admission rewrite, `GET /fee-status`, reason-code rendering, or
  server route changes. Those belong to #31.
- No Plutus scripts, validators, datums, per-request addresses, dependency pin
  changes, or Nix changes.
