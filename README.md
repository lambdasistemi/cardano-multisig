# cardano-multisig

A permissionless, stateful **backend service** that coordinates the
collection of witnesses over Conway transactions until they are fully
signed and ready to submit.

It is the extractable coordination core beneath multi-owner Cardano
signing: publish an unsigned transaction, collect witnesses from its
required signers, watch it against the live chain, submit when complete.
No accounts, no membership — a valid signature is the only credential.

## Why this exists

Every multisig coordinator in the ecosystem uses a **membership model**:
you enrol named cosigners into a shared wallet, then trade partial
signatures among known members. `cardano-multisig` is the opposite:

- **Permissionless.** No login, no enrolled members. Authorization is an
  Ed25519 signature the service verifies but never holds.
- **Self-cleaning.** An entry may only enter if it is submittable *now*
  (live phase-1 pre-flight) and carries a bounded expiry; expired entries
  are removed automatically. There is no manual delete.
- **Spam-resistant.** Only a required co-signer can place an entry in front
  of you, and you control your own to-sign surface with a signed filter.
- **Minimal trust surface.** All crypto and ledger validation is Haskell,
  reusing [`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools);
  no JavaScript in the fund-adjacent path.
- **Keyless.** The service verifies, assembles, and submits — it never
  holds a signing key and never signs.

## Status

Bootstrapping. See the governing principles in
[`.specify/memory/constitution.md`](.specify/memory/constitution.md).

**Milestone 1** — serve `required_signers` multisig end-to-end: the roster
is the Conway body's `required_signers` field; publish is witness- and
phase-1-gated with a bounded TTL; witnesses are collected and assembled;
the "what must I sign?" query is signer-filterable; liveness and expiry are
tracked continuously; submit persists a receipt.

## Consumers

- [`amaru-treasury-tx`](https://github.com/lambdasistemi/amaru-treasury-tx)
  delegates its shared co-signing queue to this service
  ([epic #430](https://github.com/lambdasistemi/amaru-treasury-tx/issues/430)).

## License

Apache-2.0. See [LICENSE](LICENSE).
