# cardano-multisig Constitution

`cardano-multisig` is a permissionless, stateful **backend service** that
coordinates the collection of witnesses over Conway transactions until they
are fully signed and can be submitted. It is the extractable coordination
core that consumers (e.g. `amaru-treasury-tx`) sit on top of, and the
interoperable standard that a federation of independent operators can
implement. This document governs what the service is — and, as importantly,
what it must never become.

## Core Principles

### I. Permissionless by signature — no accounts, ever

The service has no user model, no login, no membership, and no admin role.
Authorization is never an identity the service stores; it is a fact it
checks per request:

- **Publish** requires the unsigned transaction and a **proof of a paid,
  non-refundable per-request fee** (see Economic model). The publisher need
  not be a required-signer: they act as a **proposer / courier**, and a
  valid proposal is one that is *paid for*, not one that is *enrolled*. A
  malicious proposal is harmless — no signer signs a transaction they have
  not verified, and no party can forge a witness.
- **Adding a witness** is self-securing: an invalid or non-required witness
  is rejected; a valid required-signer witness needs no other credential.
- **Signer-scoped preferences** (the filter policy of Principle III) require
  a signature by the relevant required-signer key. Nobody can set another
  signer's policy.

There is no unauthenticated privileged bypass and no stored balance:
publishing is a paid, identity-free act; witnessing is authorized by a
signature the ledger itself would honour; a signer's own policy is
authorized by that signer's key. Anyone who can reach the service can
*read*; changing an entry's fate requires paying for it, signing it, or
owning the policy. A per-request toll creates no account, identity, or
membership — it is pay-per-use and stateless, consistent with this
principle.

### II. The transaction defines its own roster

The service derives the expected signer set from the transaction itself,
never from out-of-band configuration or a registry of enrolled members.
**Milestone 1** treats the Conway body's `required_signers` field (key 14)
as the authoritative roster. Later milestones MAY add roster providers
(native-script or Plutus-derived signer sets) behind a single interface,
but no roster source may ever require pre-registered participants — that is
the membership model this project exists to avoid.

### III. Anti-spam: paid resources, signer-controlled surface (NON-NEGOTIABLE)

Denial of service has two distinct surfaces, met by two distinct defences,
and both hold without accounts:

- **The service's own resources** — each publish costs a live phase-1
  pre-flight, durable storage, and continuous liveness monitoring for the
  entry's bounded lifetime — are protected by the **per-request fee** (see
  Economic model). Because publishing is open to any proposer, the fee is
  the sole gate on a public instance: a flood must pay per entry.
- **A signer's attention** is protected **solely** by a **signer-controlled
  filter**, and because the filter is an *allowlist* (default-deny) it
  protects the inbox even against strangers. The "what must I sign?" query
  MUST be filterable by criteria the signer defines; entries that do not
  match a signer's declared *open-to-sign* predicate never surface. Any
  stored filter policy is scoped to a key and authorized by that key's
  signature.

  The canonical predicate is a **trust-ordered co-signer allowlist**: a
  signer surfaces an entry only once it *already carries a witness from a
  co-signer on their allowlist* ("show me only entries already signed by
  ktorz, damien, or pi"). This makes trust flow with signing order — a rogue
  proposer or compromised key can publish, but the entry never reaches an
  honest signer's inbox until someone that signer trusts has vouched by
  signing first.

  Because a proposer's entry may be **born with zero witnesses**, the
  trust-ordered allowlist alone would hide every fresh entry from everyone
  and stall the first signature. The filter is therefore the signer's *own*
  policy, not one fixed rule: a first-mover opts into a **bootstrap
  predicate** — e.g. "surface unsigned entries where I am on the roster" —
  accepting more inbox noise in exchange for being able to start the witness
  chain. The trust-ordered allowlist is the default, never the only,
  predicate.

Filters are a signer's own signed policy, never a membership roster or an
account. The service MAY bound resource use (bounded TTL per Principle V)
but MUST NOT protect a signer's inbox by gating *who* may publish —
publication is paid and open; attention is filtered.

*(Amended in v2.0.0: earlier drafts limited publish to required-signers as
an anti-spam reach limit. That pillar is removed — the fee protects
resources, the default-deny filter protects attention, and publication is
open to proposers.)*

### IV. Domain-agnostic core — extraction is the point (NON-NEGOTIABLE)

The coordination engine MUST NOT import, encode, or special-case any
consumer's domain: no treasury scopes, address labels, metadata anchors,
or validator-specific rules. The core knows only Conway transactions,
signatures, time, and the chain. Consumers layer their domain on top as
thin clients. Any PR that leaks a consumer's domain type into the core is
rejected on sight; this is a hard review gate, not a stylistic preference.
A domain-agnostic core is also what makes operators interchangeable — a
commodity any operator can run (see Operator market & federation).

### V. Gated entry, self-cleaning queue

An entry may enter the queue only if it (a) could be submitted *right now*
given a complete roster — a live Conway phase-1 pre-flight against the node
(all inputs resolve, the validity interval contains the current tip, value
is conserved) — (b) carries a **finite, bounded** `invalidHereafter` (no
upper bound is rejected; an expiry more than a configured horizon, default
~2 epochs / ~10 days, ahead of tip is rejected), and (c) carries a valid
**proof of paid fee** (see Economic model). A passed expiry removes the
entry **automatically** — there is no manual delete endpoint. Everything
that can rot after entry (spent inputs, elapsed TTL) is detected
continuously by the service, never discovered at submit time.

### VI. Crypto is Haskell; the trust surface is minimal; no on-chain code (NON-NEGOTIABLE)

All cryptographic verification and ledger validation run as Haskell,
reusing the phase-1 validator and witness-verification path from
[`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools)
rather than reimplementing either. No cryptographic operation is delegated
to a JavaScript dependency or an opaque third-party service.

Moreover, **the service requires zero on-chain validators.** There is no
Plutus script, no minting policy, no custom on-chain code to deploy or
audit. The fee is a bare payment tagged with the request body hash; the
roster is the ledger's native `required_signers` field. This is a
fund-adjacent service, and its trust boundary is therefore *exhaustively*
the off-chain dependency tree, kept deliberately small. The zero-validator
property is load-bearing and depends on the fee being **non-refundable**
(see Economic model): any conditional refund, escrow, or proof-of-service
obligation would reintroduce a validator and its audit surface.

### VII. Stateful backend, no frontend

This repository is a backend service only. It owns durable state — the
pending-transaction wallet — which MUST survive restart, and it ships no
UI. Clients (CLIs, browser apps, other backends) interact over a
contract-first HTTP API. The persistence backend is explicit and swappable
behind an interface; state is never smuggled into client memory as the
source of truth.

Durability is scoped **deliberately to restart, not to an operator's
disappearance.** An in-flight request holds no custody: its witnesses are
re-signable and its unsigned transaction is re-publishable, so a vanished
operator costs at most the *re-collection* of a request — never funds and
never authority. For high-stakes requests, **multi-homing** (publishing to
several operators at once, see Operator market & federation) removes even
that cost. Durable off-operator request state — on-chain or replicated — is
therefore **not** provided: it would reintroduce the very footprint this
design eliminates, and re-collection plus multi-homing already cover the
loss. This is a closed decision, not a deferral; revisiting it requires a
concrete case where re-collection is genuinely expensive *and*
multi-homing is unavailable (e.g. a slow air-gapped signing ceremony that
cannot be run against parallel operators).

### VIII. Verify and relay, never hold keys

The service verifies signatures, assembles fully-witnessed transactions,
and submits them, but it never holds a signing key over user funds and
never signs on behalf of a signer. Witnesses are produced by clients
offline against their own key material. Key custody is out of scope,
permanently.

An operator MAY hold the key to its own **fee-collection address** — its
revenue. That key is not in the request path (the service only *reads* fee
payments to admit a publish; sweeping them to a wallet is out-of-band
housekeeping) and is never custody of user or coordinated funds. Collecting
a toll one owns is not holding a key one must be trusted with.

## Technology & Interface Constraints

- **Language & build:** Haskell, packaged with a Nix flake, matching the
  `cardano-tx-tools` / `amaru-treasury-tx` toolchain. Reuse those libraries
  for phase-1 validation and witness handling; do not fork the crypto.
- **No on-chain code:** the service ships no validator, minting policy, or
  script. The fee is an ordinary payment tagged (datum / metadata) with the
  request body hash; the roster is the native `required_signers` field.
- **Chain access:** a direct Node-to-Client (N2C) connection to a local
  `cardano-node` is the default source of chain state, behind an interface
  that additional sources MAY implement. No chain backend may leak into the
  pure coordination logic.
- **API:** contract-first HTTP under `/v1`, with an OpenAPI document checked
  into the repository. The wire contract is the source of truth for
  consumers **and the interop standard a federation of operators
  implements** — breaking it is a versioned, deliberate act. Because browser
  clients call the service directly (cross-origin), the API MUST support
  **CORS** with a configurable allowed-origin policy and correct preflight
  handling. Authorization travels in the request payload — a signature, or a
  fee-payment reference — never in cookies, so CORS is **credential-free**
  (no `Access-Control-Allow-Credentials`), consistent with the no-account
  model.
- **State:** an explicit persistence layer for the pending-tx wallet,
  swappable behind an interface, durable across restart.

## Economic model & DDoS resistance

The two DoS surfaces are met separately (Principle III): a signer's
**attention** by the signer-controlled, default-deny filter (no payment),
and the **service's own resources** by a per-request fee.

The fee is a **non-refundable, per-request toll, weighted by the requested
validity window**. Publishing carries the unsigned transaction and a
**proof of an on-chain payment** to the operator's fee address, **tagged
with the request's body hash**. Publish verifies the payment is on-chain,
tagged for this request, **covers the required amount**, and is **confirmed
before** admitting the entry (**pay-before-work**: the service is never made
to pre-flight, store, and monitor an entry it has not been paid for). The
body-hash tag binds one payment to one request, so a payment cannot be
replayed across requests; no off-chain balance ledger is required.

**Why weighted by validity.** The dominant cost of an entry is continuous
liveness monitoring for its bounded lifetime (Principle V), linear in its
live duration. A flat fee mis-prices this and is gameable — the cheapest
attack is a max-TTL entry that pays once and imposes the full horizon of
monitoring. Weighting the fee by the requested window prices the real cost
driver and makes it **incentive-compatible**: an attacker's cost tracks the
service's cost across the whole TTL range. The natural shape is a **two-part
tariff** — a fixed floor (≈1 ADA, the min-UTxO minimum, covering the
one-time phase-1 pre-flight and admission) plus a validity-linear term for
monitoring: `fee = base + rate × (invalidHereafter − tip)`, evaluated at
admission.

**Non-refundability is the load-bearing hinge — the fee prices the
reservation, not the usage.** It buys the *window reserved*, not the *time
consumed*: resolving early forfeits the remainder, and nothing is ever
returned. This is deliberate. Metering actual time-in-queue would require
refunding the unused portion, and a refund — like any escrow or
proof-of-service obligation — reintroduces an on-chain validator (Principle
VI) and the trust machinery this design exists to avoid. Pricing the
reservation is also more cost-correct: the service must provision monitoring
for the window reserved whether or not the entry resolves early. A proposer
pays to *try*, not to *succeed*.

The weighting is **off-chain arithmetic at admission**: the service reads
the transaction's own `invalidHereafter`, computes the required fee, and
checks the tagged payment covers it. The chain still holds only a bare
payment; the zero-validator invariant (Principle VI) is untouched. An
operator MAY additionally weight by entry size (input count also drives
monitoring), but validity is the primary and sufficient axis.

**Pricing is set by operators, not decreed.** Each operator advertises its
own **schedule** (`base` and `rate`) at or above the marginal cost a live
request imposes over its lifetime; the market of operators (below) finds the
level, and operators compete on the curve, not merely a scalar. On a
**self-hosted, single-tenant** deployment the fee is meaningless — an
operator charging itself — and is set to zero; resource protection there
rests on network control and trusted co-signers.

The publish path MUST be designed so the fee gate — and, later, per-operator
pricing and multi-homing — slots in without reshaping the API.

## Operator market & federation

The service is a **protocol** (the `/v1` contract) with a reference
operator, designed to admit a **federation** of independent operators. Two
prior commitments make operators a commodity: keylessness and no custody
(Principle VIII) give near-zero switching cost — requests are
re-publishable, witnesses re-signable, nothing is locked in — and the
contract-first API makes every operator an interchangeable implementation
of one standard.

- **Censorship-resistance is by exit and redundancy, not by protocol.** A
  single operator can stall or drop a request; the answer is plurality. For
  high-stakes requests a client SHOULD **multi-home** — publish to several
  operators at once — so no single operator's censorship matters. Reactive
  switching depends on detecting censorship that may be unattributable;
  proactive multi-homing does not.
- **The fee is simultaneously spam-defence, revenue, and price signal** —
  one mechanism, three roles — which is why pricing is left to operators and
  their market.
- **Self-hosting is the floor** that keeps operators honest: no operator can
  charge more than the cost of running your own.

This is roadmap, not Milestone 1. Milestone 1 ships **self-hostable, with
one reference operator**; discovery, reputation, and multi-home client
logic are deferred until adoption proves a market exists. The publish path
is designed so multi-homing slots in without a wire break.

## Milestones & Delivery

- **Milestone 1 — `required_signers` multisig (current):** serve the full
  lifecycle for transactions whose roster is the `required_signers` field:
  - **fee-gated + phase-1-gated + bounded-TTL** publish, open to any
    proposer (not restricted to required-signers);
  - witness collection and signed-transaction assembly;
  - a **signer-controlled, filterable "what must I sign?" query** (Principle
    III) — trust-ordered co-signer allowlist as default, plus a bootstrap
    predicate for first-movers, with any stored filter policy self-signed;
  - continuous liveness / staleness detection with automatic expiry;
  - submit with a persisted receipt.
- **Deferred:** submission authorization (restricting *who* may press
  submit) — a fully-witnessed transaction is broadcastable by anyone, so
  this is operational policy, scoped separately, not a Milestone-1 gate.
- **Future:** additional roster providers (native-script / Plutus signer
  derivation) behind the Principle-II interface; multi-tenancy (many
  independent queues in one deployment); richer filter predicates; and
  **operator-market infrastructure** — operator discovery, reputation, and
  multi-home client publishing.

## Governance

This constitution supersedes ad-hoc practice. Amendments are documented,
versioned (semver on this document), and dated; a principle marked
NON-NEGOTIABLE may be changed only by an explicit amendment, never
incidentally. Every PR and review verifies compliance — in particular the
Principle-IV domain-agnostic-core gate, the Principle-I no-account gate, the
Principle-III filter-is-sole-inbox-defence guarantee, and the Principle-VI
**no-on-chain-code** invariant. Non-refundability of the fee is a
load-bearing decision, not a default, and may not be reversed without
acknowledging that it reintroduces on-chain validation. Added complexity
must be justified against these principles or removed.

**v2.0.0 amendment (2026-07-05):** publish is fee-gated and proposer-open,
not witness-gated (Principle I); the "co-signer-only reach" pillar is
removed and the default-deny filter becomes the sole inbox defence, with a
bootstrap predicate for first-movers (Principle III); the refundable
deposit-token economic model is replaced by a validity-weighted,
non-refundable per-request fee, establishing the **zero-on-chain-validator**
invariant
(Principles V, VI, Economic model); the operator-market / federation
framing is added.

**Version**: 2.0.0 | **Ratified**: 2026-07-05 | **Last Amended**: 2026-07-05
