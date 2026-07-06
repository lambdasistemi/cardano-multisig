# Tasks: Publish Fee-Status Rewrite

## Slice A - Publish Allowance Gate

- [ ] T31-S1 Remove the datum-tag publish path from `Publish.hs` and tests.
- [ ] T31-S1 Admit publish requests on `storeAllowanceFor` final allowance.
- [ ] T31-S1 Return fee reasons in the required order:
  `fee_metadata_malformed`, `fee_unconfirmed`, `fee_insufficient`,
  `fee_not_seen`.
- [ ] T31-S1 Make HTTP `fee_payment` optional for `POST /v1/entries`.
- [ ] T31-S1 Preserve #30 `Server.hs` fee-indexer startup wiring.
- [ ] T31-S1 Pass focused publish/server tests and `./gate.sh`.

## Slice B - Fee-Status Handler

- [ ] T31-S2 Add `GET /v1/fee-status/{id}` with optional `payment` query parsing.
- [ ] T31-S2 Return `observed`, `confirmed`, `sufficient`, `ready_to_publish`,
  `paid_lovelace`, `required_lovelace`, `confirmations`, and `reason`.
- [ ] T31-S2 Cover ready, not-seen, unconfirmed, insufficient, and malformed
  fee-status cases in tests.
- [ ] T31-S2 Pass focused fee-status tests and `./gate.sh`.

## Finalization

- [ ] T31-F1 Verify no forbidden legacy API package string,
  `bodyHashTagDatum`, or `fee_tag_mismatch` strings remain in code/tests.
- [ ] T31-F1 Verify PR body contains `Closes #31`.
- [ ] T31-F1 Drop `gate.sh`, mark the PR ready for review, and verify all six CI
  checks are green.
