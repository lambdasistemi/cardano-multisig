# Tasks: Fee-Tag Metadata Contract and Codec

## Slice 1 - Codec, Cabal Wiring, and Tests

- [X] T001-S1 Add `Cardano.Multisig.FeeTag` with `BodyHash`, label `9721`,
  key `body_hash`, `encodeFeeTag`, and `decodeFeeTag`.
- [X] T001-S1 Add cabal exposure/dependencies for the new module and tests.
- [X] T001-S1 Add focused tests for round-trip, malformed metadata, and the
  real-CLI no-schema CBOR golden.
- [X] T001-S1 Run
  `nix develop --quiet -c just unit "Cardano.Multisig.FeeTag"` and `./gate.sh`.
- [X] T001-S1 Commit as `feat: add fee tag metadata codec` with trailer
  `Tasks: T001`.

## Slice 2 - OpenAPI and API Docs

- [X] T002-S2 Update `openapi/v1.yaml` with concrete fee address/tag-field
  semantics, `GET /fee-status/{id}`, `FeeStatus`, `FeeReason`, and optional
  `PublishRequest.fee_payment`.
- [X] T002-S2 Update `docs/api-v1.md` with the metadata JSON, current
  `cardano-cli` no-schema example, and pay -> poll `fee-status` -> publish
  flow.
- [X] T002-S2 Run `nix develop --quiet -c just build-docs` and `./gate.sh`;
  do not add `just update-swagger` or any new OpenAPI validator in this child.
- [X] T002-S2 Commit as `docs: pin fee metadata contract in API docs` with
  trailer `Tasks: T002`.

## Slice 3 - Orchestrator-Owned Finalization

- [ ] T003-S3 ORCHESTRATOR-OWNED Verify every implementation task is checked
  and rerun `./gate.sh` at HEAD.
- [ ] T003-S3 ORCHESTRATOR-OWNED Verify GitHub CI for PR #33 is green.
- [ ] T003-S3 ORCHESTRATOR-OWNED Update PR #33 body with delivered behavior,
  tests, and any Q-001 resolution.
- [ ] T003-S3 ORCHESTRATOR-OWNED Drop `gate.sh`, commit
  `chore: drop gate.sh (ready for review)`, and mark PR #33 ready.
- [ ] T003-S3 ORCHESTRATOR-OWNED Append `READY` and `COMPLETE` status lines;
  do not merge.
