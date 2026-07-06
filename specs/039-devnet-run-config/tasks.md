# Tasks: Devnet Run Config + Partial-Witness Regression

## Slice 1: Devnet Server Run Recipe

- [ ] T001 Add a flake app for the existing `cardano-multisig-server`
  executable without changing executable behavior.
- [ ] T002 Add a `just` recipe that runs the server against a devnet node
  using the existing runtime env surface, defaulting
  `CARDANO_NODE_MAGIC=42`.
- [ ] T003 Add a MkDocs runbook and navigation entry documenting the devnet
  env, fee schedule, store path, and fixed publish confirmation depth.

## Slice 2: Partial-Witness Regression Tests

- [ ] T004 Add RED/GREEN unit coverage proving `assembleEntryTx` preserves a
  pre-existing non-roster vkey witness while adding collected roster
  witnesses.
- [ ] T005 Assert assembly leaves the body hash, script data hash, and
  non-vkey witness components unchanged for the script-bearing fixture.
- [ ] T006 Add the feasible no-live-node `collectInputs` boundary check for
  spend/reference/collateral inputs, or record a precise infeasibility
  rationale in `WIP.md`.
