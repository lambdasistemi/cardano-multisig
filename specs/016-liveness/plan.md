# Implementation Plan: Continuous Liveness And Self-Cleaning Queue

## Scope

Implement child ticket #16 on branch `feat/e7-liveness`.

## Design

- Add `Cardano.Multisig.Liveness` for the pure decision logic, a single-tick
  runner, and a supervised interval loop.
- Keep chain access behind injected functions so tests use mocks and the runtime
  uses the existing N2C `Provider` shared by `runServer`.
- Use `storeListEntries` plus `storePutEntry` to mark expired entries. The
  existing store has no manual delete API; expired entries remain durable and
  render as `expired`.
- Add input collection in the liveness module from the Conway transaction body,
  and check each input through a chain read that treats a missing output as
  spent.
- Extend single-entry JSON to include the documented `liveness` object. Submitted
  and expired entries may still render, but the monitor only mutates collecting
  and ready entries.
- Start the monitor with `withAsync` beside Warp in `runServer`; the loop catches
  chain/store exceptions around each tick, sleeps, and retries so node hiccups do
  not bring down the API.

## Existing Patterns Studied

- `/code/chain-follower/lib/ChainFollower/Runner.hs` keeps the per-block state
  transitions small and testable, with rollback/follow decisions separate from
  the runner machinery.
- `/code/cardano-stake-csmt/application/Cardano/StakeCSMT/Application/Run/Main.hs`
  links a foreground service with a background worker and normalizes worker
  exceptions. For this ticket the monitor is deliberately softer: transient
  failures are caught inside the monitor loop and retried.

## Slices

### Slice 1: Liveness domain and monitor tick

Create the liveness module, pure classification, mockable chain/store
dependencies, and focused tests. Include cabal/test wiring.

### Slice 2: HTTP payload and runtime monitor wiring

Extend `GET /v1/entries/{id}` with live liveness fields, then start the monitor
from `runServer` beside Warp using the shared provider and store.

## Verification

- Focused RED/GREEN:
  `nix develop --quiet -c just unit liveness`
- Server payload RED/GREEN:
  `nix develop --quiet -c just unit server`
- Full gate:
  `./gate.sh`
