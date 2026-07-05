# Implementation Plan: E4 Publish Path

## Current Context

The branch starts clean on `feat/e4-publish` and already includes:

- E2 `Cardano.Multisig.Chain`, with `ChainSource{csPreflight}`,
  `withNodeProvider`, and `readPaymentConfirmation`.
- E3 `Cardano.Multisig.Store`, with `Entry`, `EntryId`, `Store`, and
  `entryIdFromTx`.
- `openapi/v1.yaml`, which fixes the `fee-quote`, `entries`, and operator
  response shapes.

Local patterns to reuse:

- `Cardano.Multisig.Store.entryIdFromTx` already computes the tx body hash as
  `TxId (hashAnnotated (tx ^. bodyTxL))`.
- `Amaru.Treasury.Build.Common.txIdText` renders a ledger `TxId` as lowercase
  hex using `extractHash`, `hashToBytes`, and base16.
- `Amaru.Treasury.Report.signerRequirements` reads required signers from
  `reqSignerHashesTxBodyL`.
- MPFS tests format `TxIn` values as `<txid>#<ix>` and use explicit JSON
  request/response records rather than ad-hoc maps.

## Design

Add `Cardano.Multisig.Publish` as the pure-ish admission module. Keep it
independent from WAI so tests can cover gate behavior without HTTP plumbing.

Expected public surface:

- `OperatorSchedule` containing network, fee address text, base lovelace, rate
  lovelace per slot, and TTL horizon slots.
- `PublishDeps m` or equivalent record of operations for the chain tip,
  payment read, phase-1 preflight, store lookup, and store insert.
- `FeeQuoteRequest` / `FeeQuote` helpers or domain-level quote functions that
  decode transaction CBOR hex, derive body hash, extract finite
  `invalidHereafter`, and compute required fee.
- `publishEntry` or equivalent function returning typed admission failures
  that the server maps to HTTP `402`, `409`, and `422`.

Fee tag convention for this ticket: the payment output datum must encode the
body hash bytes exactly. Use ledger datum inspection; do not hand-roll CBOR tx
decoding. If the existing payment-reader surface cannot expose enough
information without changing interfaces, write a Q-file before changing scope.

Wire the WAI server after the domain layer is tested:

- Add JSON request/response records matching `openapi/v1.yaml`.
- Decode request bodies with Aeson and malformed input as `422`.
- Route only `POST /v1/fee-quote` and `POST /v1/entries` away from the existing
  `501` fallback.
- Read operator config from environment in `runServer` and keep a pure
  `application` variant for tests.

## Slices

### Slice A: Publish gate domain

One bisect-safe behavior-changing commit adds the admission/quote domain module
and focused unit tests. It may add test fixture helpers and cabal exposure.

Owned files:

- `src/Cardano/Multisig/Publish.hs`
- `test/Cardano/Multisig/PublishSpec.hs`
- `test/Main.hs`
- `cardano-multisig.cabal`

Focused verification:

- `nix develop --quiet -c just unit Publish`
- `./gate.sh`

### Slice B: Server routes and operator config

One bisect-safe behavior-changing commit wires the domain module into the WAI
server, implements environment-backed operator config, and tests the HTTP JSON
surface.

Owned files:

- `src/Cardano/Multisig/Server.hs`
- `test/Cardano/Multisig/ServerSpec.hs`
- `cardano-multisig.cabal`

Focused verification:

- `nix develop --quiet -c just unit Server`
- `./gate.sh`

## Risks

- The current `ChainSource` exposes only preflight; payment reads are provider
  based. The server may need a private runtime dependency record that includes
  both `ChainSource` and a payment-reader function built from the provider,
  while keeping public E2 interfaces unchanged.
- Fee-address comparison may require a bech32 parse or render helper from
  ledger/cardano-api. The driver should use local Hoogle and sibling repo
  patterns instead of adding an ad-hoc text comparison if the payment reader
  exposes ledger `Addr`.
- The exact `Verdict` success representation is from `cardano-tx-tools`; tests
  should mock the preflight result at the publish-domain boundary if building a
  real success value is unnecessarily coupled to that library.
- The live node path remains behind existing smoke environment flags; this
  ticket's mandatory proof is unit coverage plus the clean-tree gate.
