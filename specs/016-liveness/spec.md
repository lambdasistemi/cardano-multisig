# Feature Specification: Continuous Liveness And Self-Cleaning Queue

## User Story

As an operator of a public multisig coordinator, I want the service to
continuously detect entries whose TTL has elapsed or whose inputs have been
spent, so signers and submitters never discover stale work only at submit time.

## Requirements

- FR-001: The service MUST evaluate only live entries: `collecting` and `ready`.
- FR-002: When the current chain tip is past an entry's `invalid_hereafter`, the
  service MUST automatically persist the entry as `expired`.
- FR-003: When any transaction input for a live entry no longer resolves from
  the chain source, the service MUST report `inputs_unspent = false`.
- FR-004: `GET /v1/entries/{id}` MUST include the OpenAPI `liveness` object with
  `inputs_unspent` and `phase1_ok`.
- FR-005: The background monitor MUST run beside Warp at startup and share the
  same store and chain provider as the request handlers.
- FR-006: Transient chain-read failures in the monitor MUST be caught, delayed,
  and retried without crashing the HTTP server.
- FR-007: The implementation MUST NOT add a manual delete endpoint.

## Acceptance Criteria

- A live entry whose `invalid_hereafter` is lower than the observed tip is
  marked `expired` by one monitor tick.
- A live entry with at least one spent input is reported stale without requiring
  submit.
- A live entry with unspent inputs and a valid phase-1 preflight remains live
  and reports healthy liveness.
- The unit suite covers pure decisions and one monitor tick using mocks only.
