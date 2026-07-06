# Tasks: Allowance Store Model

## Slice 0 - Orchestrator Bootstrap

- [X] T000-S0 ORCHESTRATOR-OWNED Refresh `main`, create worktree
  `/code/cardano-multisig-29`, branch `feat/allowance-store`.
- [X] T000-S0 ORCHESTRATOR-OWNED Add the PR-local `gate.sh`, enforce the
  repository-wide forbidden-token grep, and run `./gate.sh` on the baseline.
- [X] T000-S0 ORCHESTRATOR-OWNED Push branch and open draft PR #34 linked to
  issue #29.

## Slice 1 - Store Model and RocksDB Behavior

- [X] T001-S1 Add public `FeePayment` and `FeeAllowance` store model types.
- [X] T001-S1 Add fee-payment key/value codecs and the RocksDB fee-payment
  column family.
- [X] T001-S1 Extend the public `Store` API with upsert, rollback-from-slot,
  and allowance lookup operations.
- [X] T001-S1 Implement RocksDB upsert, rollback, and allowance lookup using
  the existing transaction discipline.
- [X] T001-S1 Update in-repo `StoreWithFilters` test mocks to compile with the
  widened store API.
- [X] T001-S1 Add temp-RocksDB unit tests for multi-payment sum, idempotent
  reinsertion, exact rollback removal, finality-depth filtering, and pending
  payment reporting.
- [X] T001-S1 Run
  `nix develop --quiet -c just unit "Cardano.Multisig.Store.RocksDB"` and
  `./gate.sh`.
- [X] T001-S1 Commit as `feat: add allowance store model` with trailer
  `Tasks: T001`.

## Slice 2 - Orchestrator-Owned Finalization

- [X] T002-S2 ORCHESTRATOR-OWNED Verify every implementation task is checked
  and rerun `./gate.sh` at HEAD.
- [X] T002-S2 ORCHESTRATOR-OWNED Verify GitHub CI for PR #34 is green and log
  `CI-PASS`.
- [X] T002-S2 ORCHESTRATOR-OWNED Update PR #34 body with delivered behavior,
  tests, and the hard-rule grep evidence.
- [X] T002-S2 ORCHESTRATOR-OWNED Drop `gate.sh`, commit
  `chore: drop gate.sh (ready for review)`, and mark PR #34 ready.
- [X] T002-S2 ORCHESTRATOR-OWNED Append `READY` and `COMPLETE`; do not merge.
