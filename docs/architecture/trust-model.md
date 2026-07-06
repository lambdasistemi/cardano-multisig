# Trust model

This page is the security spine: **who is trusted with what, what an attacker
can and cannot do, and why the trust boundary is exhaustively the off-chain
dependency tree.**

## Authorization: a fact, not an identity

There is no session, cookie, account, login, or admin role. Every
state-changing call **carries its own proof in the request payload**. The
service verifies the proof and acts; it stores no credential.

| Action | Proof carried | What the service checks |
|--------|---------------|-------------------------|
| **Publish** | a confirmed, tagged on-chain **fee payment** | payment is on-chain, tagged with this body hash, covers the required amount, confirmed |
| **Add witness** | the **witness itself** (Ed25519 over the body hash) | signature valid, key ∈ `required_signers`, not already present |
| **Set filter policy** | an **Ed25519 signature** by the signer's key | signature verifies against the path key |
| **Submit** | **none** | a fully-witnessed tx is broadcastable by anyone |
| **All reads** | none | — |

Because authorization travels in the body — never in cookies — CORS is
**credential-free**: browser clients call the service cross-origin with no
`Access-Control-Allow-Credentials`. There is no privileged unauthenticated
bypass and no stored balance.

!!! note "Why this is safe without accounts"
    Anyone who can reach the service can **read**. Changing an entry's fate
    requires *paying for it*, *signing it*, or *owning the policy key*. A
    toll creates no account, identity, or membership — it is pay-per-use and
    stateless.

## Zero on-chain validators ⚠

**The service requires no Plutus script, no minting policy, no on-chain code
to deploy or audit.** Two facts make this possible:

- the **fee** is a bare payment tagged with the request body hash — the
  service *reads* it, it never calls a contract;
- the **roster** is the ledger's native `required_signers` field (key 14),
  not a script-derived set.

This is a fund-adjacent service, so its trust boundary is deliberately made
*exhaustively the off-chain dependency tree*, kept small (crypto reused from
[`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools), never
reimplemented, never delegated to JavaScript).

!!! warning "This property is load-bearing and depends on non-refundability"
    Any conditional refund, escrow, or proof-of-service obligation would
    reintroduce a validator and its audit surface. That is precisely why the
    fee is [non-refundable](fees.md#non-refundability). If you want to
    challenge non-refundability, you are challenging the zero-validator
    invariant — they stand or fall together.

## No custody, keyless ⚠

The service **verifies, assembles, and submits** — it never holds a signing
key over user funds and never signs on behalf of a signer. Witnesses are
produced by clients offline against their own key material. Key custody is
out of scope, permanently.

The one key an operator *may* hold is the key to **its own fee-collection
address** — its revenue. That key is **not in the request path** (the service
only *reads* fee payments to admit a publish; sweeping them to a wallet is
out-of-band housekeeping) and is never custody of user or coordinated funds.

## What an attacker can and cannot do

| Actor | Can | Cannot |
|-------|-----|--------|
| **Malicious proposer** | publish any unsigned tx they pay for; put junk in the queue | make anyone sign it; forge a witness; reach an honest signer's inbox before a *trusted* co-signer has signed (default-deny filter) |
| **Third party** | pay a fee tagged for someone else's request (merely *helps* it publish — publication is open anyway) | steal or reuse another request's fee (the body-hash tag binds one payment to one request); publish for free |
| **Spammer / DoS** | flood the queue — **at a per-entry, validity-weighted cost** | exhaust resources for free; a flood must pay per entry over its whole TTL |
| **Compromised signer key** | publish; sign | be un-noticed by co-signers whose filter is trust-ordered — a rogue signature does not propagate to signers who did not list that key |
| **The operator** | stall, drop, or censor a request; set its own price | steal funds (holds none); forge authority (holds no user key); be un-routable-around (clients [multi-home](fees.md#operator-market)) |

The recurring theme: **the worst an adversary achieves is nuisance or
censorship, never theft of funds or forgery of authority** — because the
service holds neither.

## No off-operator durability ⚠

Durable state is scoped **deliberately to restart, not to an operator's
disappearance.** The store (the pending-transaction wallet) MUST survive a
process restart. It is **not** replicated off-operator or anchored on-chain.

The justification: an in-flight request holds no custody. Its witnesses are
re-signable and its unsigned transaction is re-publishable, so a vanished
operator costs at most the **re-collection** of a request — never funds,
never authority. For high-stakes requests, **multi-homing** (publishing to
several operators at once) removes even that cost.

!!! warning "Closed decision — but the place to push back"
    Durable off-operator request state would reintroduce the very on-chain /
    replicated footprint this design eliminates. It is revisited **only**
    given a concrete case where re-collection is genuinely expensive *and*
    multi-homing is unavailable — e.g. a slow air-gapped signing ceremony
    that cannot be run against parallel operators. If you have such a case,
    raise it before M1.

## Compliance gates

Every PR is checked against these invariants (constitution, Governance):

- **Principle I** — no account / no stored credential.
- **Principle IV** — the core imports no consumer domain type (treasury
  scopes, address labels, metadata anchors). A domain leak is rejected on
  sight; it is also what keeps operators interchangeable.
- **Principle VI** — no on-chain code. (For this epic specifically, an
  additional gate: `grep` for `cardano-api` must be empty — the crypto path
  is ledger-level, not the api umbrella.)
- **Non-refundability** may not be reversed without acknowledging it
  reintroduces on-chain validation.
