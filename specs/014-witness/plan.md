# E5 Witness Implementation Plan

## Existing Surfaces

- E2 provides N2C session setup in `Cardano.Multisig.Chain`; its
  `withNodeProvider` already opens the LSQ and LTxS channels.
- E3 provides `Entry`, `Receipt`, and `Store` with entry lookup, witness
  collection, and receipt persistence.
- E4 provides `PublishDeps` and `applicationWith`; current post-publish routes
  fall through to `501`.
- `openapi/v1.yaml` is fixed for this ticket.

## Reused Patterns

- Decode detached witnesses like `Amaru.Treasury.Tx.AttachWitness`: accept both
  bare `WitVKey` and cardano-cli `[0, WitVKey]` envelope shapes.
- Verify like `Amaru.Treasury.Api.VerifyWitness`: `verifySignedDSIGN` over
  `extractHash (hashAnnotated (tx ^. bodyTxL))`, convert
  `KeyHash Witness` to `KeyHash Guard`, and check `required_signers`.
- Assemble like `Amaru.Treasury.Tx.AttachWitness`: merge with
  `witsTxL . addrTxWitsL %~ Set.union witnesses`.
- Submit through an injected dependency whose production implementation uses
  `Cardano.Node.Client.N2C.Submitter.mkN2CSubmitter` on the LTxS channel.

## Slices

1. Witness core: add pure witness decode/verify/merge/status helpers and unit
   tests.
2. HTTP read and witness routes: wire `GET /entries/{id}` and
   `POST /entries/{id}/witnesses` with store-backed behavior.
3. Submit and receipt: extend dependencies with submit, persist receipts, wire
   `POST /entries/{id}/submit` and `GET /entries/{id}/receipt`.

Each slice must be one bisect-safe commit with tests and the matching task
checkboxes amended into that same commit by the orchestrator.

## Gate

- Focused slice tests via `nix develop --quiet -c just unit <pattern>`.
- Per-slice gate via `./gate.sh`.
- Final gate on a clean tree after `rm -rf dist-newstyle`:
  `nix build .#cardano-multisig .#unit-tests` and
  `nix develop --quiet -c just ci`.
