# E5 Witness Tasks

## Slice 1 - Witness Core

- [ ] T014-S1 Add `Cardano.Multisig.Witness` with detached witness decode,
  signature verification, duplicate detection, status/missing helpers, and
  ledger witness-set assembly.
- [ ] T014-S1 Add unit tests for invalid signature, non-required key,
  duplicate detection, valid witness acceptance, ready status, and assembly.
- [ ] T014-S1 Update the cabal module lists needed by the new module/tests.
- [ ] T014-S1 Run the focused witness tests and `./gate.sh`.

## Slice 2 - Read And Collect Routes

- [ ] T014-S2 Wire `GET /v1/entries/{id}` and
  `POST /v1/entries/{id}/witnesses` in `Cardano.Multisig.Server`.
- [ ] T014-S2 Add HTTP tests for missing entry `404`, invalid/non-required
  witness `422`, duplicate witness `409`, valid witness persistence, and full
  roster status `ready`.
- [ ] T014-S2 Keep the E4 publish behavior and OpenAPI file unchanged.
- [ ] T014-S2 Run the focused server tests and `./gate.sh`.

## Slice 3 - Submit And Receipt Routes

- [ ] T014-S3 Extend runtime dependencies with injected submit support backed
  by the N2C LTxS path in production.
- [ ] T014-S3 Wire `POST /v1/entries/{id}/submit` and
  `GET /v1/entries/{id}/receipt`, including non-ready `409`, receipt
  persistence, and submitted status.
- [ ] T014-S3 Add unit/HTTP tests with a stub submitter; keep live broadcast
  behind an opt-in smoke flag.
- [ ] T014-S3 Run the focused submit/receipt tests and `./gate.sh`.
