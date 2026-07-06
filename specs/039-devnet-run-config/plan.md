# Implementation Plan: Devnet Run Config + Partial-Witness Regression

## Context

Issue #39 is the coordinator-side preparation for `amaru-treasury-tx`
epic #440. The integration behavior has already been verified:

- `src/Cardano/Multisig/Witness.hs` assembles by `Set.union` on
  `witsTxL . addrTxWitsL`.
- `src/Cardano/Multisig/Chain.hs` preflights through
  `cardano-tx-tools` `collectInputs` and
  `validatePhase1WithRewardAccounts`.
- `src/Cardano/Multisig/Server.hs` already reads the required node, store,
  and fee schedule variables through `readRuntimeConfig`.

The ticket therefore adds a run recipe, docs, and regression coverage. It
does not change runtime behavior.

## Slices

### Slice 1: Devnet Server Run Recipe

Add a flake app and `just` recipe for running the existing
`cardano-multisig-server` executable against a devnet node. Document the
required environment and defaults in a short MkDocs runbook.

Owned files:

- `flake.nix`
- `justfile`
- `docs/devnet-run.md`
- `docs/index.md`
- `mkdocs.yml`

Forbidden files:

- `src/**`
- `test/**`
- `cardano-multisig.cabal`

Proof:

- `nix run --quiet .#cardano-multisig-server -- --help` may fail if the
  executable has no help mode; do not require it.
- Use `nix develop --quiet -c just build-docs` and `./gate.sh`.

Commit subject:

`feat: add devnet server run recipe`

Tasks trailer:

`Tasks: T001, T002, T003`

### Slice 2: Partial-Witness Regression Tests

Extend unit coverage so `assembleEntryTx` is locked as a pure witness-set
union for partially-witnessed script-bearing transactions. Prefer extending
`test/Cardano/Multisig/WitnessSpec.hs`; add a focused
`cardano-tx-tools` `collectInputs` boundary check if it is feasible without
live node access.

Owned files:

- `test/Cardano/Multisig/WitnessSpec.hs`
- `test/Cardano/Multisig/ChainSpec.hs`
- `cardano-multisig.cabal`

Forbidden files:

- `src/**`
- `docs/**`
- `justfile`
- `flake.nix`

Fixture expectations:

- Build the transaction with ledger types only; no `cardano-api`.
- Include a pre-existing vkey witness whose key is not in
  `entryRequiredSigners`.
- Add collected witnesses for all required signers.
- Make the transaction script-bearing enough to pin preservation of script
  data hash and witness-set script/redeemer/datum components. If the pinned
  ledger APIs make a fully populated synthetic script fixture impractical,
  preserve the strongest script-bearing fields available and record the
  rationale in `WIP.md`.
- Assert the assembled transaction body hash and non-address witness
  components are unchanged.
- Assert `addrTxWitsL` is exactly the union of existing and collected vkey
  witnesses.
- If adding the `collectInputs` check, assert spend, reference, and
  collateral `TxIn`s are all present in the returned set.

Proof:

- RED: focused unit command fails before GREEN.
- GREEN: focused unit command passes.
- `./gate.sh` passes before commit.

Commit subject:

`test: cover partial witness assembly`

Tasks trailer:

`Tasks: T004, T005, T006`

## Finalization

After both slices are accepted and pushed:

1. Confirm all tasks are checked.
2. Run `./gate.sh`.
3. Audit commit messages and the PR body.
4. Drop `gate.sh` in `chore: drop gate.sh (ready for review)`.
5. Push, mark PR #40 ready for review, and wait for all CI checks to pass.
6. Do not merge.
