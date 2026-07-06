# cardano-multisig — `/v1` HTTP API (design spec)

**Status:** design. The hand-authored OpenAPI 3.1 document — the wire
contract of record (constitution, *Technology & Interface Constraints*) — is
kept in sync with this design during Milestone 1. This document fixes the
endpoint surface, the authorization model, and **who pays or signs at each
step**. Every endpoint cites the constitutional principle it enforces.

## Roles

- **Proposer / courier** — publishes an unsigned transaction and pays the
  fee. Need not be a required-signer (Principle I).
- **Signer** — a key in a transaction's `required_signers`. Adds witnesses;
  owns their filter policy.
- **Reader** — anyone. Reads are open.
- **Operator** — runs the service, advertises a fee schedule, holds only a
  fee-collection address (Principle VIII). Out of band w.r.t. the request
  path.

## Authorization model

No session, cookie, account, or login (Principle I). Every state-changing
call carries its own proof **in the payload**:

| Action | Proof carried | Who |
|---|---|---|
| Publish | **fee** — a confirmed, tagged on-chain payment | proposer |
| Add witness | **the witness itself** — Ed25519 over the body hash, key ∈ roster | signer |
| Set filter policy | **signature** by the signer's key | signer |
| Submit | **none** — a complete tx is broadcastable by anyone (deferred) | anyone |
| All reads | none | anyone |

CORS is **credential-free** (Technology constraints): authorization is in the
body, never in cookies.

## Lifecycle — who pays / signs at each step

1. **Quote** — `POST /v1/fee-quote { transaction }` → the exact
   validity-weighted fee, the fee address, and the required tag (the body
   hash). *No auth.*
2. **Pay** *(off-chain Cardano payment — not an API call)* — the **proposer**
   sends the quoted lovelace to the fee address, **tagged with the body
   hash**, and waits for confirmation.
3. **Poll fee status** — `GET /v1/fee-status/{id}` where `id` is the body
   hash. The client waits until the operator reports the fee payment as
   confirmed and sufficient.
4. **Publish** — `POST /v1/entries { transaction }`. The client MAY also send
   `fee_payment` as an explicit tx-in hint if it already knows the fee output.
   The service
   re-derives the body hash, runs a live phase-1 pre-flight, checks the
   `invalidHereafter` is bounded within the horizon, and checks the tagged
   payment is confirmed and **covers `base + rate × (invalidHereafter −
   tip)`**. *Auth: fee.*
5. **Find** — signers call `GET /v1/entries?signer=…&predicate=…` to surface
   what they are open to sign (default-deny filter, Principle III). *Read.*
6. **Witness** — each signer `POST /v1/entries/{id}/witnesses { witness }`.
   Verified against the body hash and the roster. *Auth: the witness.*
7. **Watch** — anyone `GET /v1/entries/{id}` for progress, liveness, expiry.
8. **Submit** — `POST /v1/entries/{id}/submit` once fully witnessed: assemble,
   broadcast, persist a receipt. *No auth.*
9. **Receipt** — `GET /v1/entries/{id}/receipt`.

**Multi-homing** (Operator market & federation): a client MAY run steps 1–4
against several operators in parallel; each charges its own fee. Witnesses in
step 6 re-post to each. This is how a client survives a single operator
disappearing (Principle VII).

## Endpoints

### `GET /v1/operator`
Operator discovery + fee schedule (federation; Economic model).
```json
{
  "network": "mainnet",
  "fee": {
    "base_lovelace": 1000000,
    "rate_lovelace_per_slot": 12,
    "address": "addr1...",
    "tag_field": "metadata[9721].body_hash"
  },
  "ttl_horizon_slots": 864000,
  "roster_types": ["required_signers"]
}
```

### `POST /v1/fee-quote`
Body: `{ "transaction": "<unsigned tx CBOR hex>" }`
→ `200`:
```json
{
  "body_hash": "…",
  "required_fee_lovelace": 1600000,
  "fee_address": "addr1...",
  "tag": "<body_hash>",
  "invalid_hereafter": 1234567
}
```
→ `422` — undecodable tx, or `invalidHereafter` absent / unbounded / beyond
the horizon.
Convenience so the proposer pays the exact validity-weighted amount. *No
auth.* Enforces: Economic model (validity-weighted fee).

Fee payments carry the body hash in transaction metadata using no-schema JSON:
label `9721`, a one-key map, key `body_hash`, and a value equal to the
transaction body hash as 64 lowercase hex characters.

```json
{ "9721": { "body_hash": "<64 lowercase hex body hash>" } }
```

Current `cardano-cli` no-schema metadata flags:

```bash
BODY_HASH=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
cat > fee-metadata.json <<JSON
{ "9721": { "body_hash": "${BODY_HASH}" } }
JSON

cardano-cli transaction build \
  --tx-out "${FEE_ADDRESS}+${REQUIRED_FEE_LOVELACE}" \
  --change-address "${CHANGE_ADDRESS}" \
  --json-metadata-no-schema \
  --metadata-json-file fee-metadata.json \
  --out-file fee-payment.body
```

### `GET /v1/fee-status/{id}` — fee readiness
`id` is the transaction body hash. The operator reads the chain for a payment
to its fee address carrying `metadata[9721].body_hash = id`, then reports
whether the payment is confirmed and sufficient.

→ `200`:
```json
{
  "body_hash": "<body_hash>",
  "paid": false,
  "reason": "fee_unconfirmed",
  "fee_payment": "<txid#ix>"
}
```
`reason ∈ fee_not_seen | fee_unconfirmed | fee_insufficient |
fee_metadata_malformed`. Malformed label `9721` metadata is a fee-status
payment failure, not a phase-1 transaction failure.

### `POST /v1/entries` — publish
Body: `{ "transaction": "<unsigned tx CBOR hex>" }`; optionally
`{ "fee_payment": "<txid#ix>" }` when the client already has the exact fee
payment output.
Auth: **fee**. The service:
1. decodes the tx and derives `body_hash`;
2. runs a live phase-1 pre-flight — inputs resolve, validity interval
   contains the tip, value conserved (Principle V);
3. requires a bounded `invalidHereafter` within the horizon (Principle V);
4. verifies a matching fee payment is on-chain, pays the fee address, carries
   `metadata[9721].body_hash`, is confirmed, and **covers `base + rate ×
   (invalid_hereafter − tip)`** (Economic model).

→ `201`:
```json
{
  "entry_id": "<body_hash>",
  "required_signers": ["…"],
  "witnesses": [],
  "invalid_hereafter": 1234567,
  "status": "collecting"
}
```
→ `402` fee missing / unconfirmed / insufficient / malformed metadata · `422`
phase-1 fail or TTL unbounded / over-horizon · `409` duplicate `entry_id`.
Enforces: Principles I (fee-gated, proposer-open), V, VI, Economic model.

### `GET /v1/entries/{id}`
→ `200`:
```json
{
  "entry_id": "…",
  "transaction": "<unsigned tx CBOR hex>",
  "required_signers": ["…"],
  "witnesses": ["<vkeyhash>"],
  "missing": ["<vkeyhash>"],
  "liveness": { "inputs_unspent": true, "phase1_ok": true },
  "invalid_hereafter": 1234567,
  "status": "collecting"
}
```
`status ∈ collecting | ready | submitted | expired`. Public read.

### `GET /v1/entries` — "what must I sign?"
Query: `signer=<vkeyhash>` (entries whose roster includes this key) plus a
**filter predicate**:
- `predicate=trust-ordered&allowlist=<vkeyhash,…>` — surface only entries
  **already witnessed by a listed co-signer** (default-deny; the canonical
  predicate, Principle III);
- `predicate=roster-open` — the **bootstrap predicate**: surface entries
  where `signer` is on the roster **regardless of existing witnesses** (for
  first-movers, Principle III).

→ `200 { "entries": [ …summaries… ] }`. Public read; the filter is the
signer's own choice. Enforces: Principle III (filter is the sole inbox
defence; bootstrap for zero-witness entries).

### `POST /v1/entries/{id}/witnesses` — add a witness
Body: `{ "witness": "<vkey_witness CBOR hex>" }`. Auth: **self-securing** —
the witness. Verified: signature valid over `body_hash`; key ∈
`required_signers`; not already present.
→ `200 { "witnesses": […], "missing": […], "status": "collecting|ready" }`
→ `422` invalid signature or non-required key · `404` entry expired / absent
· `409` duplicate witness.
Enforces: Principle I (a valid witness needs no other credential).

### `POST /v1/entries/{id}/submit`
Auth: **none** (deferred; Milestones). If `status = ready`, assemble and
broadcast; persist a receipt.
→ `200 { "tx_id": "…", "submitted_at": "…" }`
→ `409` not fully witnessed · `422` phase-1 now fails or entry expired.

### `GET /v1/entries/{id}/receipt`
→ `200 { "tx_id": "…", "submitted_at": "…" }` · `404` if not submitted.

### `PUT /v1/signers/{vkeyhash}/filter` — stored filter policy (optional)
Body: `{ "predicate": { … }, "signature": "<Ed25519 over the canonical policy bytes>" }`
Auth: **signature** by `{vkeyhash}`. Stores the signer's default
open-to-sign predicate so `GET /v1/entries?signer=…` applies it without
re-specifying. Nobody can set another key's policy.
Enforces: Principle III (filter policy scoped to a key, signed).

## What the API deliberately does NOT have

- **No delete** — entries expire automatically (Principle V).
- **No refund** — the fee is non-refundable (Economic model); its absence is
  what keeps the design validator-free (Principle VI).
- **No account / registration / login** (Principle I).
- **No key-custody or signing endpoint** — the service never signs
  (Principle VIII).

## Notes for the OpenAPI of record

- Media type `application/json`; transactions and witnesses as CBOR hex
  strings.
- All errors share `{ "error": { "code": "…", "message": "…", "detail"?: … } }`.
- `entry_id` is the transaction **body hash** (blake2b-256) throughout — the
  single identifier tying quote → payment tag → entry → witnesses →
  submitted `tx_id`.
- The service exposes **zero on-chain interfaces**: the fee is an ordinary
  tagged payment the service *reads*, never a contract it calls (Principle
  VI).
