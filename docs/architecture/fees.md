# Fees & the economic model

The fee is **one mechanism doing three jobs**: spam-defence, revenue, and
price signal. This page explains its shape and the decisions inside it. How
the service *discovers* a payment is a separate concern — see
[Fee discovery](fee-discovery.md).

## Two DoS surfaces, two defences

Denial of service has two distinct surfaces, and they are met **separately**:

- **A signer's attention** is protected by the signer-controlled,
  default-deny [filter](lifecycle.md#witness-collection) — **no payment
  involved**.
- **The service's own resources** — each publish costs a live phase-1
  pre-flight, durable storage, and continuous liveness monitoring for the
  entry's bounded lifetime — are protected by the **per-request fee**.

Because publishing is open to *any* proposer, the fee is the **sole** gate on
a public instance: a flood must pay per entry.

## The shape: a validity-weighted two-part tariff

```
required_fee = base + rate × (invalidHereafter − tip)     (evaluated at admission)
```

- **`base`** — a fixed floor (≈1 ADA, the min-UTxO minimum) covering the
  one-time phase-1 pre-flight and admission.
- **`rate × window`** — a validity-linear term covering continuous monitoring
  over the entry's live duration.

### Why weighted by validity, not flat ⚠

The dominant cost of an entry is **continuous liveness monitoring for its
bounded lifetime**, which is linear in its live duration. A flat fee
mis-prices this and is **gameable**: the cheapest attack is a max-TTL entry
that pays once and imposes the full horizon of monitoring.

Weighting by the requested window prices the real cost driver and makes it
**incentive-compatible** — an attacker's cost tracks the service's cost
across the whole TTL range. An operator MAY *additionally* weight by input
count (also a monitoring driver), but validity is the primary and sufficient
axis.

### Point-in-time, not a forever price

The fee is evaluated **at admission** against the current tip. A
further-out `invalidHereafter` costs more; for a fixed `invalidHereafter` the
required fee **drops as the tip advances** (the remaining window shrinks). A
[quote](lifecycle.md#1-quote) is therefore a price *at this moment*, not a
standing one.

## Non-refundability ⚠ {#non-refundability}

**The fee prices the *reservation*, not the usage.** It buys the *window
reserved*, not the *time consumed*: resolving early forfeits the remainder,
and nothing is ever returned. A proposer **pays to try, not to succeed.**

This is the single most load-bearing economic decision, and it is deliberate
on two grounds:

1. **It keeps the chain validator-free.** Metering actual time-in-queue would
   require refunding the unused portion — and a refund, like any escrow or
   proof-of-service obligation, **reintroduces an on-chain validator**
   ([Principle VI](trust-model.md#zero-on-chain-validators)) and the trust
   machinery this design exists to avoid.
2. **It is more cost-correct.** The service must provision monitoring for the
   window *reserved* whether or not the entry resolves early.

!!! warning "Push back here"
    "Pay to try, not to succeed" is a real UX cost: a request that gets its
    signatures in five minutes still paid for the full reserved window. The
    mitigations inside the design are (a) the fee is small and (b) you choose
    the window — set a tight `invalidHereafter` and you pay less. If that is
    not enough for your use case, the alternative (a refund) is **not** a
    tweak — it changes the trust model. Raise it before M1 if it matters.

## Pricing is set by operators, not decreed

Each operator advertises its own **schedule** (`base` and `rate`) via
[`GET /v1/operator`](../api-v1.md), at or above the marginal cost a live
request imposes over its lifetime. Operators compete **on the curve, not
merely a scalar**.

On a **self-hosted, single-tenant** deployment the fee is meaningless — an
operator charging itself — and is set to **zero**; resource protection there
rests on network control and trusted co-signers.

## Operator market {#operator-market}

The service is a **protocol** (the `/v1` contract) with a reference operator,
designed to admit a **federation** of independent operators. Keylessness and
no custody give **near-zero switching cost** (requests re-publishable,
witnesses re-signable), and the contract-first API makes every operator an
interchangeable implementation of one standard.

- **Censorship-resistance is by exit and redundancy, not by protocol.** A
  single operator can stall or drop a request; the answer is **plurality**.
  High-stakes clients SHOULD **multi-home** — publish to several operators at
  once — so no single operator's censorship matters.
- **The fee is spam-defence, revenue, and price signal at once** — which is
  why pricing is left to operators and their market.
- **Self-hosting is the floor** that keeps operators honest: no operator can
  charge more than the cost of running your own.

!!! note "Roadmap, not M1"
    Milestone 1 ships **self-hostable, with one reference operator**. Operator
    discovery, reputation, and multi-home client logic are deferred until
    adoption proves a market exists — but the publish path is designed so
    multi-homing slots in **without a wire break**.
