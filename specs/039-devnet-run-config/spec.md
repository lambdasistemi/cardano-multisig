# Feature Specification: Devnet Run Config + Partial-Witness Regression

## User Story

As the `amaru-treasury-tx` devnet integration operator, I need a
turnkey way to run `cardano-multisig` against a devnet node and a
regression test that protects the already-verified script-bearing,
partially-witnessed transaction behavior, so the epic can rely on the
coordinator without revalidating the same integration seam manually.

## Functional Requirements

- **FR-001**: The repository MUST expose a documented devnet server run
  recipe that uses the existing `readRuntimeConfig` environment surface:
  `CARDANO_NODE_SOCKET`, `CARDANO_NODE_MAGIC`, `CARDANO_MULTISIG_STORE`,
  `FEE_ADDRESS`, `BASE_LOVELACE`, `RATE_LOVELACE_PER_SLOT`, and
  `TTL_HORIZON_SLOTS`.
- **FR-002**: The devnet recipe MUST default the network magic to `42`
  while still allowing operators to override the existing environment
  variables explicitly.
- **FR-003**: The runbook MUST document the fee schedule variables, store
  path, node socket, and current publish confirmation depth. The depth is
  currently the existing fixed `publishRequiredConfirmationDepth = 5`; this
  ticket MUST NOT add a new configuration surface for it.
- **FR-004**: A regression test MUST prove `assembleEntryTx` unions newly
  collected required-signer witnesses with the transaction's existing vkey
  witness set, preserving a pre-existing witness whose key is not in the
  `required_signers` roster.
- **FR-005**: The regression MUST prove assembly is a pure witness union:
  transaction body hash, script data hash, script/redeemer/datum witness
  components, and other non-vkey witness-set fields remain unchanged.
- **FR-006**: Where feasible without a live node, unit coverage SHOULD also
  assert the `cardano-tx-tools` boundary used by `Chain.preflight`: the
  input collection includes spend, reference, and collateral inputs.
- **FR-007**: The implementation MUST NOT change publish, witness, submit,
  liveness, indexer, or server runtime behavior. It may only add docs,
  run recipes, flake app exposure, and tests.
- **FR-008**: The implementation MUST NOT introduce `cardano-api`; the
  gate checks code, dependency, and run-configuration surfaces for that
  string.

## Acceptance Criteria

- A devnet operator can run a documented command from this repo that starts
  `cardano-multisig-server` against a devnet node using network magic `42`.
- `nix build .#cardano-multisig .#unit-tests` passes with `-Werror`.
- `nix develop --quiet -c just ci` passes.
- `./gate.sh` passes, including docs build and the scoped `cardano-api`
  grep.
- The PR body contains `Closes #39`, `gate.sh` is dropped before the PR is
  marked ready, and CI is green. The PR is not merged by this ticket owner.

## Non-Goals

- No new runtime configuration parser.
- No change to `assembleEntryTx`, `Chain.preflight`, publish fee policy,
  witness verification, submit behavior, or indexer behavior.
- No live devnet deployment inside this ticket; the existing #32 live smoke
  remains the live-system cousin of this unit/doc work.
