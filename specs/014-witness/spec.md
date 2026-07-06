# E5 Witness Collection, Assembly, And Submit

## User Story

As a signer or observer, I can add detached witnesses to an admitted
multisig entry, see which required signers remain missing, and submit the
fully witnessed transaction without the coordinator ever signing on my behalf.

## Functional Requirements

- `POST /v1/entries/{id}/witnesses` accepts one detached Conway vkey witness
  as CBOR hex.
- A witness is self-securing: the server verifies the Ed25519 signature over
  the entry body hash and requires the witness key hash to be in the entry's
  `required_signers`.
- Invalid signatures and non-required keys return `422`; duplicate witnesses
  return `409`; absent entries return `404`.
- Accepted witnesses are persisted through the E3 `Store`.
- When every required signer has a collected witness, the entry reports
  `ready`; otherwise it reports `collecting`.
- `GET /v1/entries/{id}` returns the OpenAPI `Entry` shape with transaction,
  required signers, collected witnesses, missing signers, invalid_hereafter,
  and status.
- Assembly attaches collected vkey witnesses to the original Conway
  transaction body using ledger witness-set APIs, preserving the body hash.
- `POST /v1/entries/{id}/submit` is permissionless. It only submits `ready`
  entries, runs the injected broadcast path, persists a receipt, and marks the
  entry submitted.
- `GET /v1/entries/{id}/receipt` returns the persisted receipt after submit
  and returns `404` before submission.

## Out Of Scope

- Filtering and signer policy endpoints from E6.
- Expiry sweeping and live liveness reporting from E7.
- Any server-side transaction signing.
- Changes to the E4 publish admission gate or OpenAPI contract.

## Acceptance Criteria

- Invalid detached witness signature -> HTTP `422`.
- Valid signature from a key not in `required_signers` -> HTTP `422`.
- Duplicate witness -> HTTP `409`.
- First valid witness is stored and the missing set shrinks.
- Full roster produces status `ready`.
- Assembled transaction has a populated vkey witness set and the same body id.
- Submit on a non-ready entry -> HTTP `409`.
- Submit on a ready entry broadcasts via the injected submit dependency,
  persists a receipt, and subsequent receipt reads return it.
