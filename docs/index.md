# cardano-multisig

A permissionless, stateful **backend service** that coordinates the
collection of witnesses over Conway transactions until they are fully
signed and ready to submit.

Publish an unsigned transaction, collect witnesses from its required
signers, watch it against the live chain, submit when complete. No
accounts, no membership — a valid signature is the only credential.

## Design

- **[Architecture](architecture/index.md)** — the reasoned walkthrough of
  the design: the trust model, the fee mechanics, how the service discovers
  a payment, the request lifecycle, and the load-bearing decisions worth
  pushing back on.
- **Governing document:** the
  [constitution](https://github.com/lambdasistemi/cardano-multisig/blob/main/.specify/memory/constitution.md)
  fixes what the service is and must never become.
- **[API (/v1)](api-v1.md)** — the wire contract: who pays or signs at
  each step, backed by the checked-in
  [OpenAPI 3.1 document](https://github.com/lambdasistemi/cardano-multisig/blob/main/openapi/v1.yaml).

## Key properties

- **Permissionless.** Publishing is a paid, identity-free act; a valid
  witness is the only credential to sign.
- **No on-chain code.** The anti-spam fee is a bare, validity-weighted
  on-chain payment the service *reads* — never a contract it calls.
- **Keyless.** The service verifies, assembles, and submits; it never
  holds a signing key over user funds.
- **Federated.** Any operator can run the service; clients treat
  operators as interchangeable and may multi-home.

## Run it

```bash
docker compose -f CD/docker-compose.yaml up
```
