# Tasks: Continuous Liveness And Self-Cleaning Queue

## Slice 1 - Liveness Domain And Tick

- [X] T016-S1 Add `Cardano.Multisig.Liveness` with live-entry filtering,
  expiry decisions, input staleness checks, and one monitor tick.
- [X] T016-S1 Unit-test expired TTL selection, spent-input staleness, and a live
  entry left untouched through mock dependencies.
- [X] T016-S1 Wire the new module and liveness spec into
  `cardano-multisig.cabal` and `test/Main.hs`.
- [X] T016-S1 Run focused liveness tests and `./gate.sh`, then commit the slice.

## Slice 2 - HTTP Payload And Startup Wiring

- [ ] T016-S2 Extend `GET /v1/entries/{id}` to include
  `liveness.inputs_unspent` and `liveness.phase1_ok`, while rendering `expired`
  status when persisted.
- [ ] T016-S2 Start the supervised monitor beside Warp in `runServer`, sharing
  the store and N2C provider and retrying after transient monitor failures.
- [ ] T016-S2 Add focused HTTP/runtime tests for the liveness payload and
  monitor startup shape without requiring a live node.
- [ ] T016-S2 Run focused server tests and `./gate.sh`, then commit the slice.
