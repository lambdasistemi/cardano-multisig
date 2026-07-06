# Feature Specification: Signer-Controlled Filter Query

## User Story

As a required signer, I can ask the service "what must I sign?" without
letting arbitrary paid proposers fill my inbox. The query is scoped to my
verification-key hash and uses a signer-controlled open-to-sign predicate.

## Functional Requirements

- FR-001: `GET /v1/entries` requires a valid `signer` key hash and a valid
  predicate, either supplied in the query or loaded from the signer's stored
  policy.
- FR-002: `trust-ordered` returns only entries where `signer` is in
  `required_signers` and an existing collected witness belongs to the supplied
  trusted co-signer allowlist.
- FR-003: `roster-open` returns entries where `signer` is in
  `required_signers`, regardless of existing witnesses.
- FR-004: A non-roster signer sees no entries for either predicate.
- FR-005: Missing or malformed filter input returns HTTP 422.
- FR-006: `PUT /v1/signers/{vkeyhash}/filter` persists the signer's default
  predicate only when the supplied Ed25519 witness signature is made by the
  path key over the canonical policy bytes.
- FR-007: A wrong-key or invalid policy signature returns HTTP 401 and does
  not update the stored policy.

## Success Criteria

- Unit tests cover `trust-ordered`, `roster-open`, non-roster denial, stored
  default policy use, and wrong-key policy authorization.
- The store persists filter policies across RocksDB reopen.
- The full gate passes under the repository Nix development shell.
