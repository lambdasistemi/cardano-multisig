# Specification: Publish Fee-Status Rewrite

## Issue

GitHub issue: #31, child 4/5 of epic #26.

The publish fee gate must stop authenticating payments through inline datum
matching. The fee-address indexer now owns payment observation, rollback
handling, malformed metadata tracking, and allowance summing. Publish and
fee-status must consume that Store surface.

## Primary User Story

As a proposer, I can pay the operator's fee address with the pinned metadata tag,
poll the service until the indexed allowance is ready, and publish the unsigned
transaction without constructing a datum-bearing output or guessing why a fee was
not accepted.

## Functional Requirements

- `Cardano.Multisig.Publish` removes the old datum-tag helper entirely, and the
  old tag-mismatch publish failure is not a possible result.
- `PublishRequest.fee_payment` is optional and no longer binds authorization.
  Admission depends on `storeAllowanceFor bodyHash tip requiredDepth`.
- A publish request is admitted when the final indexed allowance is greater than
  or equal to the validity-weighted required fee for the transaction at the
  current tip.
- Non-admission via the fee gate returns the named reason code using this order:
  sufficient allowance admits; optional malformed `fee_payment` tx-in reports
  `fee_metadata_malformed`; unconfirmed indexed allowance reports
  `fee_unconfirmed`; final-but-short allowance reports `fee_insufficient`;
  otherwise report `fee_not_seen`.
- `GET /v1/fee-status/{id}` returns a read-only, point-in-time fee status using
  the same mapping as publish. Optional query parameter `payment=<txid#ix>`
  enables the malformed metadata branch.
- Fee-status response fields are the ticket contract:
  `observed`, `confirmed`, `sufficient`, `ready_to_publish`, `paid_lovelace`,
  `required_lovelace`, `confirmations`, and `reason`.
- Existing #30 server startup wiring for the fee indexer remains intact.
- The codebase continues to contain no forbidden legacy API package dependency
  or import string.

## Compatibility Notes

- The current Store API from merged #30 is
  `storeMalformedFeePayment :: TxIn -> m (Maybe MalformedFeePayment)`. Presence
  of a value implements the brief's malformed-payment boolean check.
- The existing persisted `Entry` schema still requires `entryFeePayment :: TxIn`;
  #31 does not change Store schema. Implementation may preserve a provided
  optional hint or store an inert deterministic placeholder for legacy storage,
  but that field must not participate in fee authorization.
- OpenAPI/docs already contain the route and reason vocabulary from prior
  children. This ticket's owned files are implementation and tests.

## Acceptance Criteria

- Unit tests cover publish admission and each named fee reason with mock Store
  allowances.
- Unit tests cover fee-status readiness and each named fee reason, including
  `fee_metadata_malformed` through optional `payment`.
- The old datum-tag helper and old tag-mismatch reason are absent from
  implementation and tests at the end of the PR.
- `src/Cardano/Multisig/Server.hs` keeps #30's fee-indexer startup wiring while
  adding the new handler behavior.
- Local gates pass: `nix build .#cardano-multisig .#unit-tests`,
  `nix develop --quiet -c just ci`, clean tree, and grep checks.
