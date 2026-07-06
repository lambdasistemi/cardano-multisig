# Tasks: Fee-Address Chain Follower / Indexer

## Slice 0 - Orchestrator Bootstrap and Planning

- [X] T000-S0 ORCHESTRATOR-OWNED Refresh `main`, create worktree
  `/code/cardano-multisig-30`, branch `feat/fee-indexer`.
- [X] T000-S0 ORCHESTRATOR-OWNED Add the PR-local `gate.sh`, enforce the
  forbidden-token grep, and run `./gate.sh` on the baseline.
- [X] T000-S0 ORCHESTRATOR-OWNED Push branch and open draft PR #36 linked to
  issue #30.
- [X] T000-S0 ORCHESTRATOR-OWNED Study `/code/chain-follower`, the
  `cardano-stake-csmt` daemon, and pinned `cardano-node-clients` ChainSync
  patterns before dispatch.
- [X] T000-S0 ORCHESTRATOR-OWNED Write `spec.md`, `plan.md`, and `tasks.md`.

## Slice 1 - Malformed Store, Classifier, and Mock Event Loop

- [X] T001-S1 Add additive malformed-payment store support keyed by `TxIn`,
  with value carrying the containing block slot.
- [X] T001-S1 Add malformed-payment write/read/rollback operations through
  `Store`, `StoreWithFilters`, and RocksDB without changing #29 allowance
  semantics.
- [X] T001-S1 Add store tests proving malformed fee payments can be written,
  read by `TxIn`, and rolled back from the containing block slot.
- [X] T001-S1 Add `Cardano.Multisig.FeeIndexer` with pure classification that
  returns attributed payment results and malformed-payment results, plus
  `runFeeIndexerOnce`.
- [X] T001-S1 Register the module and focused test spec in
  `cardano-multisig.cabal` and `test/Main.hs`.
- [X] T001-S1 Add tests for fee-address plus decodable tag, wrong address,
  missing or malformed tag recorded as malformed, and multiple fee outputs with
  distinct txins.
- [X] T001-S1 Add a mock chain-event test proving roll-forward writes
  attributed payments and malformed records, and rollback calls both rollback
  operations.
- [X] T001-S1 Run
  `nix develop --quiet -c just unit "Cardano.Multisig.FeeIndexer"`,
  `nix develop --quiet -c just unit "Cardano.Multisig.Store"`, and
  `./gate.sh`.
- [X] T001-S1 Commit as `feat: record malformed fee payments` with trailer
  `Tasks: T001`.

## Slice 2 - Checkpointed N2C Follower

- [X] T002-S2 Add the production ChainSync runner using `chain-follower` and
  `cardano-node-clients`.
- [X] T002-S2 Add file-backed checkpoint save/load helpers and warm-resume
  start-point selection.
- [X] T002-S2 On roll-forward, apply classified attributed payments and
  malformed records, persist checkpoint, and update observed tip.
- [X] T002-S2 On roll-backward, roll back both attributed payments and
  malformed records, persist the rollback point when concrete, and continue.
- [X] T002-S2 Add safe reset behavior for warm `intersectNotFound`: roll
  attributed payments and malformed records back from slot 0 before retrying
  from origin.
- [X] T002-S2 Add a supervised retry wrapper that retries synchronous
  transient failures while preserving async cancellation.
- [X] T002-S2 Add injected-runner tests for warm resume, rollback, safe reset,
  malformed-row rollback, and one transient retry.
- [X] T002-S2 Run
  `nix develop --quiet -c just unit "Cardano.Multisig.FeeIndexer"` and
  `./gate.sh`.
- [X] T002-S2 Commit as `feat: add checkpointed fee chain follower` with
  trailer `Tasks: T002`.

## Slice 3 - Server Startup Wiring

- [ ] T003-S3 Extend runtime config with fee-indexer checkpoint directory,
  Byron epoch slots, and retry delay only.
- [ ] T003-S3 Build `FeeIndexerConfig` from existing node/store/operator
  startup settings.
- [ ] T003-S3 Start `runFeeIndexerSupervisor` as a sibling async to the
  existing liveness monitor and preserve graceful shutdown.
- [ ] T003-S3 Add focused startup/config coverage where the current test
  harness can do so without opening a node socket.
- [ ] T003-S3 Confirm `Server.hs` has startup wiring only: no route, publish,
  request, response, fee-status, OpenAPI, or docs changes.
- [ ] T003-S3 Run
  `nix develop --quiet -c just unit "Cardano.Multisig.Server"` and
  `./gate.sh`.
- [ ] T003-S3 Commit as `feat: start fee indexer with server` with trailer
  `Tasks: T003`.

## Slice 4 - Orchestrator-Owned Finalization

- [ ] T004-S4 ORCHESTRATOR-OWNED Verify every implementation task is checked
  and rerun `./gate.sh` at HEAD.
- [ ] T004-S4 ORCHESTRATOR-OWNED Verify the forbidden-token grep is empty
  across the worktree.
- [ ] T004-S4 ORCHESTRATOR-OWNED Verify GitHub CI for PR #36 is green and log
  `CI-PASS`.
- [ ] T004-S4 ORCHESTRATOR-OWNED Update PR #36 body with delivered behavior,
  tests, and hard-rule evidence.
- [ ] T004-S4 ORCHESTRATOR-OWNED Drop `gate.sh`, commit
  `chore: drop gate.sh (ready for review)`, and mark PR #36 ready.
- [ ] T004-S4 ORCHESTRATOR-OWNED Append `READY` and `COMPLETE`; do not merge.
