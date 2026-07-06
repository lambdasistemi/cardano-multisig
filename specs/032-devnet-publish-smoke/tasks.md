# Tasks - Devnet Publish Smoke

## Slice 1 - Devnet Smoke And Required Check

- [x] T032 Add a devnet publish smoke target that boots a forging Conway devnet
  with magic `42` using the cardano-node-clients harness recipe.
- [x] T032 Copy and patch the devnet genesis fixture at runtime, including
  Shelley `systemStart`, Byron `startTime`, and `chmod 600` delegate keys.
- [x] T032 Derive the genesis UTxO signing key from the 32-byte seed
  `e2e-genesis-utxo-key-seed-000001` and fund a normal wallet.
- [x] T032 Start the real server and fee indexer against the devnet.
- [x] T032 Quote the publish transaction, pay exactly the quoted base fee to
  the fee address with metadata label `9721`, and assert no datum is used.
- [x] T032 Poll fee status and assert `fee_not_seen -> fee_unconfirmed ->
  ready_to_publish`.
- [x] T032 Assert `POST /v1/entries` returns `201` and
  `POST /v1/entries/{id}/submit` returns a real receipt.
- [x] T032 Wire the smoke as a flake app/check, just recipe, CI job, and
  `gate.sh` step.
- [x] T032 Prove `cardano-api` remains absent.
- [x] T032 Run `nix run --quiet .#devnet-publish-smoke` and `./gate.sh`.
- [x] T032 Commit as `test: add devnet publish smoke` with trailer
  `Tasks: T032`.

## Slice 2 - Finalization

- [x] T033 Update PR #38 body so it describes the delivered smoke and contains
  `Closes #32`.
- [x] T033 Run the final local gate and audit all open task boxes are closed.
- [x] T033 Drop `gate.sh` in the final `chore: drop gate.sh (ready for review)`
  commit.
- [x] T033 Mark PR #38 ready for review.
- [x] T033 Verify all six CI jobs are green.
- [x] T033 Append `READY` and `COMPLETE` to ticket STATUS after verification.
