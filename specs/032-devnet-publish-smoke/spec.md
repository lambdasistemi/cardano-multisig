# 032 - Devnet Publish Smoke

## P1 User Story

As the operator of `cardano-multisig`, I need a required live-boundary smoke
that proves the metadata-tagged fee path works against a real Conway ledger, so
a mock-green publish path can no longer merge while the service is dead at the
fee-payment boundary.

## Context

This is child 5/5 of epic #26 and lands after #28 through #31. The full
metadata fee path is on `main`: metadata label `9721`, allowance storage, the
fee-address indexer, `GET /v1/fee-status/{body_hash}`, and publish admission by
indexed allowance.

The smoke must follow the existing `cardano-node-clients` devnet harness rather
than inventing a new node boot flow. The required recipe is:

- copy `e2e-test/genesis`;
- patch Shelley `systemStart` from `PLACEHOLDER` to roughly now plus 15 seconds;
- patch Byron `"startTime": 0` to the matching Unix seconds;
- chmod delegate KES, VRF, and opcert keys to `600`;
- derive the genesis UTxO signing key from the 32-byte Ed25519 seed
  `e2e-genesis-utxo-key-seed-000001`;
- build fee transactions with `cardano-cli transaction build-raw`, not
  `transaction build`;
- avoid `pkill -f` patterns that can match the smoke command itself.

## Functional Requirements

- FR-001: The smoke MUST boot a forging Conway devnet with network magic `42`
  using the `cardano-node-clients` devnet harness pattern.
- FR-002: The smoke MUST fund a normal wallet from the genesis UTxO key before
  making the fee payment.
- FR-003: The smoke MUST start the real `cardano-multisig-server` with its
  N2C provider, LocalTxSubmission submitter, RocksDB store, and fee indexer
  pointed at the devnet.
- FR-004: The smoke MUST call `POST /v1/fee-quote` and record
  `fee_address`, `required_fee_lovelace`, and `body_hash`.
- FR-005: The smoke MUST make an ordinary ADA payment with no datum to
  `fee_address`, carrying metadata label `9721` with
  `{ "body_hash": "<body_hash>" }`.
- FR-006: The smoke MUST pay exactly the quoted base fee in lovelace and assert
  that this exact amount is accepted by the server, proving the inline-datum
  min-UTxO defect is gone.
- FR-007: The smoke MUST poll `GET /v1/fee-status/{body_hash}` and assert the
  observed sequence includes `fee_not_seen`, then `fee_unconfirmed`, then
  `ready_to_publish=true`.
- FR-008: The smoke MUST call `POST /v1/entries` and assert HTTP `201`.
- FR-009: The smoke MUST call `POST /v1/entries/{id}/submit` and assert a real
  receipt response backed by LocalTxSubmission.
- FR-010: The branch MUST keep `cardano-api` absent from `cabal.project`,
  `cardano-multisig.cabal`, Nix files, source, tests, and CI wiring.
- FR-011: The smoke MUST be wired as a required CI check. If implementation
  evidence proves the shared runners cannot run a forging devnet, the worker
  MUST stop and raise a Q-file with the evidence and a proposed operator-run
  required check plus runbook.

## Acceptance Criteria

- AC-001: `nix run .#devnet-publish-smoke` boots the devnet and completes the
  quote -> exact metadata fee payment -> fee-status -> publish -> submit flow.
- AC-002: The CI workflow has a distinct required job for the devnet publish
  smoke.
- AC-003: `./gate.sh` runs the existing build/test gate and the devnet publish
  smoke.
- AC-004: `rg -n "cardano-api" cabal.project cardano-multisig.cabal flake.nix
  nix src app test .github` returns no matches.
- AC-005: The final PR body contains `Closes #32`, `gate.sh` is absent at HEAD,
  the PR is ready for review, and all six CI jobs are green.

## Out Of Scope

- No production behavior changes to the fee tag, allowance store, fee indexer,
  publish admission, fee-status response mapping, or submit path.
- No `cardano-api` dependency.
- No merge to `main`.
