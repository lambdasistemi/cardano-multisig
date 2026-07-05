# cardano-multisig Constitution

`cardano-multisig` is a permissionless, stateful **backend service** that
coordinates the collection of witnesses over Conway transactions until they
are fully signed and can be submitted. It is the extractable coordination
core that consumers (e.g. `amaru-treasury-tx`) sit on top of. This document
governs what the service is — and, as importantly, what it must never
become.

## Core Principles

### I. Permissionless by signature — no accounts, ever

The service has no user model, no login, no membership, and no admin role.
Every state-changing request is authorized by an Ed25519 signature that the
service **verifies but never holds**:

- **Publish** requires the unsigned transaction plus at least one witness
  that verifies against the transaction body hash and whose key is in the
  transaction's required-signer set.
- **Adding a witness** is self-securing: an invalid or non-required witness
  is rejected; a valid one needs no other credential.
- **Retraction** and any **signer-scoped preference** (see Principle III)
  require a signature by the relevant required-signer key.

There is no unauthenticated write and no privileged bypass. A request is
authorized because it carries a signature the ledger itself would honour,
or it is refused. Anyone who can reach the service can *read*; only a key
holder can *change*.

### II. The transaction defines its own roster

The service derives the expected signer set from the transaction itself,
never from out-of-band configuration or a registry of enrolled members.
**Milestone 1** treats the Conway body's `required_signers` field (key 14)
as the authoritative roster. Later milestones MAY add roster providers
(native-script or Plutus-derived signer sets) behind a single interface,
but no roster source may ever require pre-registered participants — that is
the membership model this project exists to avoid.

### III. Anti-spam: co-signer-only reach, signer-controlled surface (NON-NEGOTIABLE)

A signer's attention is a protected resource. Two layers guard it, and both
hold without accounts:

- **Reach is limited to co-signers.** Because publish requires a valid
  required-signer witness, the only parties who can place an entry in front
  of a given key are parties already holding a key in a required-signer set
  shared with it — parties who could co-sign anyway. A stranger cannot
  reach another signer's queue at all.
- **The signer controls their own surface.** The "what must I sign?" query
  MUST be filterable by criteria the signer defines, so that entries which
  do not match a signer's declared *open-to-sign* predicate never surface
  in that signer's inbox. Any stored filter policy is scoped to a key and
  authorized by that key's signature; nobody can set another signer's
  policy, and nothing can force an entry into a signer's attention.

  The canonical predicate is a **trust-ordered co-signer allowlist**: a
  signer surfaces an entry only once it *already carries a witness from a
  co-signer on their allowlist* (e.g. "show me only entries already signed
  by ktorz, damien, or pi"). This makes trust flow with signing order — a
  rogue or compromised required-signer key can publish, but it never
  reaches an honest signer's inbox until someone that signer trusts has
  vouched by signing first.

Filters are a signer's own signed policy, never a membership roster or an
account. The service MAY additionally bound resource use (per-publisher-key
entry caps, bounded TTL per Principle V) to protect storage, but it MUST
NOT protect a signer's inbox by gating *who* may publish beyond the
required-signer witness rule.

### IV. Domain-agnostic core — extraction is the point (NON-NEGOTIABLE)

The coordination engine MUST NOT import, encode, or special-case any
consumer's domain: no treasury scopes, address labels, metadata anchors,
or validator-specific rules. The core knows only Conway transactions,
signatures, time, and the chain. Consumers layer their domain on top as
thin clients. Any PR that leaks a consumer's domain type into the core is
rejected on sight; this is a hard review gate, not a stylistic preference.

### V. Gated entry, self-cleaning queue

An entry may enter the queue only if it could be submitted *right now* given
a complete roster. Publish runs a live Conway phase-1 pre-flight against the
node (all inputs resolve, the validity interval contains the current tip,
value is conserved) and requires a **finite, bounded** `invalidHereafter`:
no upper bound is rejected, and an expiry more than a configured horizon
(default ~2 epochs / ~10 days) ahead of tip is rejected. A passed expiry
removes the entry **automatically** — there is no manual delete endpoint.
Everything that can rot after entry (spent inputs, elapsed TTL) is detected
continuously by the service, never discovered at submit time.

### VI. Crypto is Haskell; the trust surface is minimal (NON-NEGOTIABLE)

All cryptographic verification and ledger validation run as Haskell,
reusing the phase-1 validator from
[`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools) and
the witness-verification path rather than reimplementing either. No
cryptographic operation is delegated to a JavaScript dependency or an
opaque third-party service. This is a fund-adjacent service: the dependency
tree *is* the trust boundary, and it is kept deliberately small.

### VII. Stateful backend, no frontend

This repository is a backend service only. It owns durable state — the
pending-transaction wallet — which MUST survive restart, and it ships no
UI. Clients (CLIs, browser apps, other backends) interact over a
contract-first HTTP API. The persistence backend is explicit and swappable
behind an interface; state is never smuggled into client memory as the
source of truth.

### VIII. Verify and relay, never hold keys

The service verifies signatures, assembles fully-witnessed transactions,
and submits them, but it never holds signing keys and never signs.
Witnesses are produced by clients offline against their own key material.
Key custody is out of scope, permanently.

## Technology & Interface Constraints

- **Language & build:** Haskell, packaged with a Nix flake, matching the
  `cardano-tx-tools` / `amaru-treasury-tx` toolchain. Reuse those libraries
  for phase-1 validation and witness handling; do not fork the crypto.
- **Chain access:** a direct Node-to-Client (N2C) connection to a local
  `cardano-node` is the default source of chain state, behind an interface
  that additional sources MAY implement. No chain backend may leak into the
  pure coordination logic.
- **API:** contract-first HTTP under `/v1`, with an OpenAPI document checked
  into the repository. The wire contract is the source of truth for
  consumers; breaking it is a versioned, deliberate act. Because browser
  clients call the service directly (cross-origin), the API MUST support
  **CORS** with a configurable allowed-origin policy and correct preflight
  handling. Authorization travels in the request payload as a signature,
  never in cookies, so CORS is **credential-free** (no
  `Access-Control-Allow-Credentials`) — consistent with the no-account
  model.
- **State:** an explicit persistence layer for the pending-tx wallet,
  swappable behind an interface, durable across restart.

## Milestones & Delivery

- **Milestone 1 — `required_signers` multisig (current):** serve the full
  lifecycle for transactions whose roster is the `required_signers` field:
  - witness-gated + phase-1-gated + bounded-TTL publish;
  - witness collection and signed-transaction assembly;
  - a **signer-controlled, filterable "what must I sign?" query** (Principle
    III) — a signer can surface only entries matching their declared
    open-to-sign criteria, with any stored filter policy self-signed; the
    baseline predicate is a trust-ordered co-signer allowlist (surface an
    entry only once it is already witnessed by a co-signer the querying
    signer trusts);
  - continuous liveness / staleness detection with automatic expiry;
  - submit with a persisted receipt.
- **Deferred:** submission authorization (restricting *who* may press
  submit) — a fully-witnessed transaction is broadcastable by anyone, so
  this is operational policy, scoped separately, not a Milestone-1 gate.
- **Future:** additional roster providers (native-script / Plutus signer
  derivation) behind the Principle-II interface; multi-tenancy (many
  independent queues in one deployment); richer filter predicates; **paid
  registration** (a prepaid, refundable deposit token consumed per live
  request — see below).

## Economic model & DDoS resistance

Denial of service has two distinct surfaces, met by two distinct defenses:

- **A signer's attention** is protected by Principle III (co-signer-only
  reach plus a signer-controlled, trust-ordered filter). No payment is
  involved.
- **The service's own resources** are the other surface: every publish
  costs a live phase-1 pre-flight against the node, durable storage, and
  continuous liveness monitoring for up to the entry's bounded lifetime. A
  holder of one valid required-signer key could flood *publish* and exhaust
  the service even if no entry ever surfaces to anyone.

The planned defense for the second surface is **paid registration**: a
publish carries the unsigned transaction, at least one witness, and a
**proof of payment** — an on-chain token the requester holds under a
service-defined minting policy.

Rather than mint and burn a fresh single-use receipt for every request
(one full transaction's worth of lifecycle per registration), the token is
a **prepaid, refundable deposit**: the requester mints it once to deposit
capacity worth many registrations, *consumes* capacity from it to register
each request, and *refunds* the remainder by **burning it to close** their
relationship with the service. This is capital-efficient for honest,
high-volume use while preserving the deterrent.

The load-bearing invariant: the token **must participate in each request's
lifecycle**. Registering a request provably locks a unit of the deposit
that stays tied up for as long as the request is live, and is released only
when the request resolves (submitted, retracted, or expired per Principle
V). This bounds concurrent requests by locked capital — to hold K live
entries a requester must lock K units — so a flood must lock capital
proportional to its size for the full bounded TTL and can reclaim it only
by letting requests resolve. A proof that did not consume capacity would
deter nothing; consumption *is* the protection. Each locked unit binds to
its request (e.g. by the request's body hash) so one consumption cannot be
replayed across transactions.

Permissionless does not mean free: a public toll road has no gatekeeper yet
still charges, and holding a prepaid deposit creates no account or identity
— Principle I holds. Whether a slice of each registration is a
non-refundable fee (to fund operation) on top of the refundable deposit is
a policy dial left to specification.

This is roadmap, not Milestone 1, but the publish path MUST be designed so
the proof-of-payment / deposit gate slots in without reshaping the API.
Open questions for its specification: how locked capacity is represented
and decremented on-chain (a stateful deposit UTxO, a payment-channel-style
open/consume/close, or off-chain accounting settled against an on-chain
deposit); refund and settlement timing; native-vs-Plutus policy; and
pricing a unit at or above the marginal cost a live request imposes over
its lifetime.

## Governance

This constitution supersedes ad-hoc practice. Amendments are documented,
versioned (semver on this document), and dated; a principle marked
NON-NEGOTIABLE may be changed only by an explicit amendment, never
incidentally. Every PR and review verifies compliance — in particular the
Principle-IV domain-agnostic-core gate, the Principle-I no-account gate, and
the Principle-III anti-spam guarantees. The publish path is designed from
the outset to admit the Economic-model proof-of-payment gate without a wire
break. Added complexity must be justified against these principles or
removed.

**Version**: 1.0.0 | **Ratified**: 2026-07-05 | **Last Amended**: 2026-07-05
