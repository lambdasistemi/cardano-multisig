# Feature Specification: E4 Publish Path

## User Story

As a transaction proposer, I need to pay an operator-quoted fee and publish
an unsigned Conway transaction without proving I am one of its required
signers, so the coordinator can start collecting witnesses from the roster.

## Functional Requirements

- FR-001: `POST /v1/fee-quote` decodes a CBOR-hex Conway transaction and
  derives the body hash from the transaction body using ledger hashing.
- FR-002: The fee quote computes
  `base_lovelace + rate_lovelace_per_slot * (invalidHereafter - tip)` from
  the operator schedule, the transaction TTL, and the chain tip.
- FR-003: The quote response returns `body_hash`, `required_fee_lovelace`,
  `fee_address`, `tag`, and `invalid_hereafter` per `openapi/v1.yaml`.
- FR-004: `POST /v1/entries` gates admission in this order: decode
  transaction, verify the on-chain fee payment, run phase-1 preflight,
  enforce bounded TTL within horizon, reject duplicates, persist the entry.
- FR-005: Fee verification uses the E2 payment reader result and confirms
  the referenced output pays the configured fee address, carries the body hash
  tag, and covers the required fee.
- FR-006: Publish is proposer-open. No witness or required-signer proof is
  required to admit an entry.
- FR-007: Duplicate body hashes return HTTP `409`; missing/insufficient fees
  return HTTP `402`; decode, preflight, and TTL failures return HTTP `422`.
- FR-008: Operator fee settings and TTL horizon come from configuration and
  are reflected in `GET /v1/operator`.
- FR-009: The implementation reuses E2 `ChainSource`/payment-reader concepts
  and E3 `Store`; it does not change either interface.

## Acceptance Criteria

- AC-001: Unit tests cover fee-insufficient, over-horizon or unbounded TTL,
  phase-1 failure, duplicate, and happy-path publish cases with mock chain and
  store dependencies.
- AC-002: The happy path returns `201` with entry id, roster, missing
  signers, invalid TTL, and `collecting` status without requiring a witness.
- AC-003: `POST /v1/fee-quote` returns a validity-weighted fee and body-hash
  tag for a bounded transaction.
- AC-004: `GET /v1/operator` reflects configured fee address, base, rate, and
  TTL horizon rather than the static skeleton.
- AC-005: The ticket gate passes on a clean tree before completion.

## Constraints

- The wire contract is `openapi/v1.yaml`; do not change it for this ticket.
- Owned implementation files are limited to `src/Cardano/Multisig/Server.hs`,
  new `src/Cardano/Multisig/Publish.hs`, tests, and
  `cardano-multisig.cabal`.
- Do not change the public `ChainSource` or `Store` interfaces.
- Do not implement witness collection, entry listing, submission, receipt
  reads, liveness sweeps, or filter policy behavior.
