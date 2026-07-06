# Tasks: Signer-Controlled Filter Query

## Slice 1 - Filter End-To-End

- [ ] T015-S1 Add pure filter policy logic and policy signature verification.
- [ ] T015-S1 Persist filter policies and support listing stored entries.
- [ ] T015-S1 Wire `GET /v1/entries` and `PUT /v1/signers/{vkeyhash}/filter`.
- [ ] T015-S1 Cover trust-ordered, roster-open, non-roster denial, stored
  policy fallback, and wrong-key policy PUT tests.
- [ ] T015-S1 Run focused tests and the full gate, then commit the slice.
