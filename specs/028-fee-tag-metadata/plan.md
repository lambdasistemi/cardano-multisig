# Implementation Plan: Fee-Tag Metadata Contract and Codec

## Technical Context

- Repo: `/code/cardano-multisig-28`
- Branch: `feat/fee-tag-metadata`
- PR: <https://github.com/lambdasistemi/cardano-multisig/pull/33>
- Parent epic: #26
- Child ticket: #28
- Current body-hash type: `Cardano.Multisig.Store.EntryId`
- Fee metadata API in the stack:
  `Cardano.Ledger.Shelley.TxAuxData.Metadatum`

Q-002 resolved a cabal solver conflict and is binding for this ticket and the
later indexer child: do not add `cardano-api`, do not change Nix or source pins,
and implement the agreement surface with the ledger metadata map consumed by
the indexer:

```haskell
type FeeMetadata = Map Word64 Metadatum
encodeFeeTag :: BodyHash -> FeeMetadata
decodeFeeTag :: FeeMetadata -> Maybe BodyHash
```

The current `cardano-cli` in the local Nix closure is 11.0.0.0. Its no-schema
metadata flags are `--json-metadata-no-schema` and `--metadata-json-file`.
Docs should use those current flags while describing the same no-schema
metadata contract requested by the issue.

`just update-swagger` is not present in this repo. Q-001 resolved this as a
stale instruction: do not touch `justfile`, hand-edit `openapi/v1.yaml`, verify
by direct review plus `./gate.sh`, and note the absence of an OpenAPI validator
in the PR body.

## Design

Add `Cardano.Multisig.FeeTag` as a narrow contract module:

```haskell
module Cardano.Multisig.FeeTag
    ( BodyHash
    , FeeMetadata
    , feeTagLabel
    , feeTagBodyHashKey
    , encodeFeeTag
    , decodeFeeTag
    ) where
```

`BodyHash` should alias `EntryId` unless implementation finds an existing,
better local type. The encoding is:

```haskell
Map.singleton
    9721
    ( Map
        [ (S "body_hash", S "<64 lowercase hex>")
        ]
    )
```

Rendering/parsing the body hash should reuse the existing ledger hash pattern:
`EntryId (TxId safeHash)` -> `extractHash` -> `hashToBytes` -> lowercase base16
text; parsing should mirror `Server.parseEntryId` behavior using
`Base16.decode`, `hashFromBytes`, and `unsafeMakeSafeHash` after exact 32-byte
validation.

`decodeFeeTag` should look up label `9721`, validate that value exactly, and
ignore unrelated top-level metadata labels so ordinary wallet metadata does not
make an otherwise valid fee tag undecodable.

## Slice Plan

### Slice 1: Codec, cabal wiring, and tests

Worker-owned files:

- `src/Cardano/Multisig/FeeTag.hs`
- `test/Cardano/Multisig/FeeTagSpec.hs`
- `test/fixtures/fee-tag/metadata-no-schema.cbor`
- `test/Main.hs`
- `cardano-multisig.cabal`

Work:

- Add the `FeeTag` module with the label/key constants and encode/decode
  functions.
- Add `cardano-ledger-shelley` to the library and test dependencies as needed
  for `Metadatum`.
- Expose `Cardano.Multisig.FeeTag` in the library stanza.
- Add `FeeTagSpec` to `other-modules` and `test/Main.hs`.
- Write RED first: round-trip property with explicit `genBodyHash`, malformed
  cases, and golden CBOR comparison.
- Generate the golden from a real `cardano-cli` no-schema metadata flow and
  check it in as fixture data or an explicit hex fixture.

Focused proof:

```bash
nix develop --quiet -c just unit "Cardano.Multisig.FeeTag"
./gate.sh
```

Commit:

```text
feat: add fee tag metadata codec

Tasks: T001
```

### Slice 2: OpenAPI and API docs

Worker-owned files:

- `openapi/v1.yaml`
- `docs/api-v1.md`

Work:

- Pin `FeeSchedule.address` semantics to the operator's published fee address.
- Pin `FeeSchedule.tag_field` to label `9721` with value
  `{ "body_hash": "<64 lowercase hex body hash>" }` under no-schema JSON
  metadata.
- Add `GET /fee-status/{id}` to OpenAPI.
- Add `FeeStatus` and `FeeReason` schemas.
- Make `PublishRequest.fee_payment` optional by removing it from the required
  list, without changing server implementation in this ticket.
- Update docs with the pay -> poll `fee-status` -> publish flow and a
  copy-pasteable current `cardano-cli` example using
  `--json-metadata-no-schema --metadata-json-file`.

Focused proof:

```bash
nix develop --quiet -c just build-docs
./gate.sh
```

Q-001 rejected adding `just update-swagger`; the OpenAPI YAML is hand-authored
for this ticket. The worker must directly review the YAML shape and run the
gate. If an existing validator is discovered, use it, but do not add new
validation tooling in this child.

Commit:

```text
docs: pin fee metadata contract in API docs

Tasks: T002
```

### Slice 3: Orchestrator-owned finalization

Orchestrator-owned files/actions:

- `specs/028-fee-tag-metadata/tasks.md`
- PR body for #33
- `gate.sh` removal after the final gate passes

Work:

- Verify every task in `tasks.md` is checked.
- Rerun `./gate.sh` at HEAD.
- Verify GitHub CI for PR #33 is green.
- Update the PR body with delivered behavior and verification evidence.
- Drop `gate.sh` in the final ready-for-review commit.
- Mark the PR ready for review.
- Do not merge the PR.

## Risks and Controls

- The golden test can become circular if it only uses the codec under test.
  Control: record the actual `cardano-cli` command used to produce the golden
  in the test or comments and compare bytes against the checked-in golden.
- Adding `cardano-api` is forbidden for this child after Q-002 because it does
  not solve against the current pins. Control: use ledger `Metadatum` only and
  do not edit `cabal.project`, `flake.nix`, `flake.lock`, or other pins.
- Documentation can drift from codec constants. Control: Slice 2 text must use
  the same label and key names as `FeeTag`; final PR body calls out both.
