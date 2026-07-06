# Feature Specification: Fee-Tag Metadata Contract and Codec

## User Story

As a downstream fee indexer and publish gate implementer, I need one pinned
metadata contract and one shared Haskell codec so the fee-payment tag cannot
drift between clients, the indexer, and publish admission.

## Background

Epic #26 replaces the old inline-datum fee tag. The datum path is dead because
it raises the minimum UTxO above the advertised fee and wallet/CLI JSON produces
a map shape rather than the raw `Data.B` bytes expected by the server.

This ticket is child #1 of the epic. It lands before the allowance store,
indexer, publish rewrite, and devnet smoke. Its output is the agreement layer:
the exact metadata label, value shape, codec, OpenAPI text, and operator docs
that later children consume.

## Functional Requirements

- FR-001: The protocol-wide metadatum label MUST be `9721`. It is identical for
  every operator and is not operator configurable.
- FR-002: The metadata value at label `9721` MUST be a map with exactly one key,
  text key `body_hash`, whose value is the transaction body hash as 64-character
  lowercase hex text.
- FR-003: The Haskell API MUST provide
  `encodeFeeTag :: BodyHash -> TxMetadata` and
  `decodeFeeTag :: TxMetadata -> Maybe BodyHash` from
  `Cardano.Multisig.FeeTag`.
- FR-004: In this codebase, `BodyHash` MUST be the same semantic value as the
  existing `EntryId` body-hash type. The new module may expose a type alias so
  the issue contract uses the requested name without duplicating storage types.
- FR-005: `decodeFeeTag` MUST return `Nothing` when label `9721` is absent, the
  value at that label is not the exact one-key map, the key is wrong, the value
  is not text, or the text is not exactly 64 lowercase hex characters.
- FR-006: `decodeFeeTag` MAY ignore unrelated top-level metadata labels. The
  exactness requirement applies to the value stored under label `9721`.
- FR-007: Tests MUST prove `decodeFeeTag . encodeFeeTag = Just` for generated
  body hashes using an explicit generator, not an `Arbitrary` instance.
- FR-008: Tests MUST include malformed metadata cases for wrong/missing label,
  non-hex text, wrong length, uppercase hex, wrong key, and wrong value type.
- FR-009: Tests MUST include a checked-in golden CBOR sample produced from a
  real `cardano-cli` no-schema metadata JSON flow for:

  ```json
  { "9721": { "body_hash": "<64 lowercase hex body hash>" } }
  ```

  The encoded `TxMetadata` from `encodeFeeTag` MUST match that golden byte for
  byte.
- FR-010: `openapi/v1.yaml` MUST pin `FeeSchedule.tag_field` to the exact label
  and map convention, document fee address semantics, add
  `GET /fee-status/{id}`, define `FeeStatus`, define `FeeReason` with
  `fee_not_seen`, `fee_unconfirmed`, `fee_insufficient`, and
  `fee_metadata_malformed`, and make `PublishRequest.fee_payment` optional.
- FR-011: `docs/api-v1.md` MUST document the pinned metadata JSON, a
  copy-pasteable `cardano-cli` no-schema metadata example, and the flow:
  pay -> poll `fee-status` -> publish.

## Acceptance Criteria

- AC-001: `Cardano.Multisig.FeeTag` builds with `-Werror` and exposes the codec
  contract named in the issue.
- AC-002: Focused tests for `Cardano.Multisig.FeeTag` pass, including
  round-trip, malformed-input, and CLI-CBOR golden checks.
- AC-003: OpenAPI and docs describe the same label, key, body-hash hex
  encoding, and pay/poll/publish sequence.
- AC-004: The branch passes `./gate.sh`, including
  `nix build .#cardano-multisig .#unit-tests` and
  `nix develop -c just ci`.
- AC-005: The PR is linked to #28, CI is green, and the PR is marked ready for
  review but not merged.

## Out of Scope

- No changes to `Publish.hs`, `Chain.hs`, `Store`, allowance accounting, chain
  following, rollback handling, or publish admission logic. Those are later
  epic children.
- No new Plutus scripts, validators, datums, or per-request fee addresses.
