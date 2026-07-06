# Feature Specification: Fee-Address Chain Follower / Indexer

## User Story

As the multisig service, I need a supervised fee-address indexer that follows
the local node chain, records metadata-tagged payments to the operator fee
address, and rewinds those records on rollback so publish admission in the next
child can rely on a current allowance view.

## Background

Epic #26 replaces inline-datum fee checks with ordinary ADA payments tagged by
transaction metadata. Child #28 landed the metadata contract and
`decodeFeeTag`. Child #29 landed the fee-payment store operations:
`storeUpsertFeePayment`, `storeRollbackFeePaymentsFrom`, and
`storeAllowanceFor`.

This ticket is child #30. It is the writer for indexed fee payments. It does
not add the `fee-status` route and does not rewrite publish admission. It may
add the user-approved malformed-payment store column/read needed by #31, but
does not change #29's attributed-payment allowance schema or logic.

## Functional Requirements

- FR-001: The service MUST run a background indexer that follows the local node
  over node-to-client ChainSync and receives full blocks.
- FR-002: The indexer MUST resume from a persisted chain point on restart when
  one is available, instead of replaying from genesis every boot.
- FR-003: For each Shelley-family transaction in a followed block, the indexer
  MUST inspect transaction outputs and auxiliary metadata from the block body.
- FR-004: A transaction MUST be considered a fee-payment candidate when at
  least one output pays the configured operator fee address with a positive ADA
  amount.
- FR-005: For each candidate transaction, the indexer MUST call
  `decodeFeeTag` on that transaction's metadata map.
- FR-006: When the candidate metadata decodes, the indexer MUST write a
  `FeePayment` with the decoded body hash, created output `TxIn`, lovelace
  amount, and containing block slot via `storeUpsertFeePayment`.
- FR-007: Payments to the fee address with absent metadata or a present but
  undecodable fee tag MUST be recorded as malformed fee payments keyed by
  `TxIn`; they MUST NOT be silently ignored or written as attributed
  `FeePayment`s.
- FR-008: The malformed-payment store support MUST be additive, rollback-aware,
  carry at least the containing block slot, and expose a read such as
  `storeMalformedFeePayment` so #31 can detect `fee_metadata_malformed`.
- FR-009: Transactions that do not pay the configured fee address MUST NOT
  write attributed or malformed fee-payment records, even if they carry valid
  fee metadata.
- FR-010: On ChainSync rollback, the indexer MUST roll back both attributed fee
  payments and malformed fee-payment records from the rollback point slot, then
  continue from the rewound follower state when possible.
- FR-011: The indexer MUST track the current chain tip observed by ChainSync so
  later readers can evaluate confirmation depth against the same follower view.
- FR-012: Transient node/socket/ChainSync failures MUST NOT crash the server.
  The indexer supervisor MUST catch synchronous failures, sleep, and retry until
  shutdown.
- FR-013: Shutdown MUST be graceful: when the server action exits, the indexer
  async must be cancelled together with the existing liveness monitor.
- FR-014: Server startup wiring MUST share the existing store and node
  connection configuration and remain limited to startup/background task
  wiring. Publish handlers, route matching, and fee-status behavior are out of
  scope for this child.
- FR-015: The implementation MUST use ledger types, `cardano-node-clients`, and
  the pinned `chain-follower` pattern. It MUST NOT add or import the forbidden
  high-level Cardano API package.

## Acceptance Criteria

- AC-001: Unit tests prove pure per-transaction classification:
  fee-address output plus decodable tag writes a payment; wrong address is
  ignored; missing or malformed tag records a malformed fee payment keyed by
  the output `TxIn`.
- AC-002: Unit tests prove multiple matching fee-address outputs in one
  transaction write distinct payment records with output-index-specific txins.
- AC-003: Store tests prove malformed fee payments can be written, read by
  `TxIn`, and removed by rollback from the containing block slot.
- AC-004: A mock chain-source test proves one roll-forward event writes indexed
  payments and malformed records, and one rollback event rolls both stores back
  at the rollback slot.
- AC-005: A checkpoint/resume test proves a persisted point is offered to the
  ChainSync intersector on warm start.
- AC-006: A supervisor test proves a transient follower failure is retried
  without escaping the server startup wrapper.
- AC-007: `Server.hs` changes are limited to startup wiring; no route,
  publish, request, response, or fee-status logic changes land in this child.
- AC-008: The branch passes `./gate.sh`, including the Nix build, dev-shell CI,
  and empty forbidden-token grep.
- AC-009: PR #36 is linked to #30, CI is green, and the PR is marked ready for
  review but not merged.

## Out of Scope

- No publish admission rewrite, `GET /fee-status`, or fee reason-code
  rendering. Those belong to #31.
- No devnet end-to-end publish smoke. That belongs to #32.
- No changes to #29's attributed-payment allowance semantics. This ticket may
  add the user-approved malformed-payment column/accessors needed by #31.
- No Plutus scripts, validators, datums, per-request addresses, source pins, or
  Nix dependency pin changes.
