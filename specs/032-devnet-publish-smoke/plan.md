# Plan - Devnet Publish Smoke

## Baseline

- Worktree: `/code/cardano-multisig-32`
- Branch: `feat/devnet-publish-smoke`
- PR: https://github.com/lambdasistemi/cardano-multisig/pull/38
- Base: fresh `origin/main` including merged #28 through #31.

## Existing Patterns To Reuse

- `/code/cardano-node-clients/e2e-test/Cardano/Node/Client/E2E/Devnet.hs`
  copies genesis files, patches Shelley and Byron start times, chmods delegate
  keys, starts `cardano-node`, waits for the socket, and probes N2C readiness.
- `/code/cardano-node-clients/e2e-test/Cardano/Node/Client/E2E/Setup.hs`
  defines magic `42`, the genesis Ed25519 seed
  `e2e-genesis-utxo-key-seed-000001`, the genesis address, and signing helpers.
- `/code/cardano-node-clients/nix/checks.nix` proves a forging devnet can run on
  the same `nixos` runner class by wrapping `cardano-node` and its e2e test
  binary in a flake app/check.
- Existing `cardano-multisig` unit tests provide transaction CBOR helpers,
  `entryIdFromTx`, fee-status assertions, and submit/receipt JSON shapes.

## Technical Shape

Add a dedicated smoke executable/test target named `devnet-publish-smoke`.
It should:

1. Prepare a fresh temporary run directory; never use `pkill`.
2. Copy the devnet genesis fixture from test data and patch:
   Shelley `systemStart = now + 15s`, Byron `startTime = same epoch seconds`.
3. Restrict delegate key modes to owner-read/write only.
4. Boot `cardano-node` with magic `42` and wait for the N2C socket to answer.
5. Derive the genesis key from `e2e-genesis-utxo-key-seed-000001`.
6. Fund a generated wallet from genesis.
7. Build a fully signed publish transaction from funded wallet funds with a
   bounded TTL and no coordinator-required signers, so `/submit` can broadcast
   the stored transaction without a separate witness step.
8. Start the real `cardano-multisig-server` against the node with:
   `BASE_LOVELACE=1024000`, `RATE_LOVELACE_PER_SLOT=0`,
   `TTL_HORIZON_SLOTS` large enough for the smoke, a fresh RocksDB store, and
   fee-indexer checkpoint directory.
9. `POST /v1/fee-quote` for the publish transaction.
10. Poll `GET /v1/fee-status/{body_hash}` before paying and assert
    `reason=fee_not_seen`.
11. Build and submit an ordinary fee payment with
    `cardano-cli transaction build-raw`, exact quoted lovelace, no datum, and
    metadata JSON:
    `{ "9721": { "body_hash": "<body_hash>" } }`.
12. Poll fee status until `fee_unconfirmed` is observed, then until
    `ready_to_publish=true`.
13. `POST /v1/entries` without `fee_payment`, assert `201`.
14. `POST /v1/entries/{id}/submit`, assert receipt JSON with `tx_id` and
    `submitted_at`.

The smoke may be written in Haskell, shell, or a small combination, but it must
drive real binaries over HTTP and N2C. If shell is used, prefer structured
tools (`jq`, `curl`, `cardano-cli`) and avoid ad-hoc parsing where JSON parsing
is available.

## Nix And CI Shape

Wire the smoke as both a flake app and a real check:

- the app runtime must put `cardano-node`, `cardano-cli`,
  `cardano-multisig-server`, the smoke binary/script, and needed shell tools in
  `PATH`;
- the check must be a `runCommand` that invokes the app, not a bare
  `writeShellApplication` exposed as a check;
- CI must add a distinct `Devnet publish smoke` job on `pull_request` and
  `push` to `main`.

Keep the existing five CI jobs intact. The final acceptance target is six green
jobs: Build, Unit tests, Dev shell build gate, Formatting, HLint, and Devnet
publish smoke.

## Slice Breakdown

### Slice 1 - Devnet Smoke And Required Check

One behavior-changing commit adds the smoke target, fixture, Nix/app/check
wiring, CI job, just recipe, and extends `gate.sh`. The slice is intentionally
vertical because the test target and runner wiring must be green together.

Owned files:

- `test/...`
- `cardano-multisig.cabal`
- `justfile`
- `flake.nix`
- `flake.lock`
- `nix/...`
- `.github/workflows/CI.yaml`
- `gate.sh`

Forbidden scope:

- no production module behavior changes under `src/` or `app/`;
- no `cardano-api`;
- no PR finalization or `gate.sh` drop.

Focused proof:

- RED: the new smoke command/check exists and fails before the implementation
  can complete the flow.
- GREEN: `nix run --quiet .#devnet-publish-smoke` exits 0 and logs the
  fee-status sequence.
- Gate: `./gate.sh`.

Commit:

```text
test: add devnet publish smoke

Tasks: T032
```

### Slice 2 - Finalization

Orchestrator-owned after Slice 1 is accepted:

- update PR body to describe delivered behavior and include `Closes #32`;
- run final gate and finalization audit;
- drop `gate.sh`;
- push;
- mark the PR ready for review;
- verify all six CI jobs are green.

Do not merge.
