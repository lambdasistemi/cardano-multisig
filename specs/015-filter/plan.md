# Implementation Plan: Signer-Controlled Filter Query

## Scope

Implement child ticket #15 on branch `feat/e6-filter`.

## Design

- Add `Cardano.Multisig.Filter` for pure policy types, canonical policy bytes,
  signature authorization, and entry predicate evaluation.
- Extend `Store` with listing entries and storing/looking up signer policies.
  RocksDB receives a new column family for policies.
- Wire `GET /v1/entries` in `Server.hs` to parse query filters, fall back to a
  stored default policy when `predicate` is absent, evaluate entries from the
  store, and return OpenAPI `EntrySummary` objects.
- Wire `PUT /v1/signers/{vkeyhash}/filter` to parse the policy body, verify the
  signature using ledger Ed25519 verification, and persist only authorized
  policies.

## Slice

One vertical slice is deliberate: the API behavior depends on the pure filter
type, policy persistence, and server wiring together. Landing only one layer
would create dead or untestable code.

## Verification

- Focused RED/GREEN: `nix develop --quiet -c just unit filter`
- Full gate: `./gate.sh`
