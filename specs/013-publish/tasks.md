# Tasks: E4 Publish Path

## Slice A — Publish gate domain

- [X] T013-S1 Add `Cardano.Multisig.Publish` with schedule, quote, decode,
  TTL, fee, preflight, dedup, and entry-building logic.
- [X] T013-S1 Unit-test fee-insufficient -> `402` domain failure,
  unbounded/over-horizon TTL -> `422` domain failure, phase-1 failure ->
  `422` domain failure, duplicate -> `409` domain failure, and happy-path
  publish -> `201` equivalent with no witness requirement.
- [X] T013-S1 Wire the new module and test module in `cardano-multisig.cabal`
  and `test/Main.hs`.
- [X] T013-S1 Run focused publish tests and `./gate.sh`.

## Slice B — Server routes and operator config

- [ ] T013-S2 Replace only the `POST /v1/fee-quote` and `POST /v1/entries`
  `501` stubs with real handlers backed by the publish domain.
- [ ] T013-S2 Make operator fee schedule and TTL horizon configurable and
  surface those values in `GET /v1/operator`.
- [ ] T013-S2 Unit-test the HTTP JSON/status behavior for fee quote, publish
  success, and mapped publish failures.
- [ ] T013-S2 Run focused server tests and `./gate.sh`.
