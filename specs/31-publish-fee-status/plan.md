# Plan: Publish Fee-Status Rewrite

## Context

Merged #28 supplies the reason vocabulary and optional publish fee-payment
contract. Merged #29/#30 supply the indexed allowance Store API and malformed
fee-payment lookup. The old publish flow still reads a caller-supplied UTxO and
compares an inline datum; #31 replaces that read path with Store allowance
checks and adds the fee-status HTTP handler.

## Implementation Shape

- Introduce publish-level fee-status/reason data in
  `Cardano.Multisig.Publish` so publish and HTTP fee-status share one mapping.
- Keep validity-weighted fee calculation as-is:
  `base + rate * max 0 (invalidHereafter - tip)`.
- Query `storeAllowanceFor` using the body hash, current tip, and a single
  required confirmation-depth constant chosen in the publish layer. Use the
  returned `allowanceRequiredDepth` in responses.
- Interpret `storeMalformedFeePayment txIn` with `isJust` for the optional
  malformed branch.
- Remove all datum imports, construction, comparisons, exports, and tests.
- Parse `PublishRequest.fee_payment` as optional in `Server.hs`; parse
  fee-status `payment` from the query string when present.
- Preserve #30 runtime wiring in `runServer`: liveness and fee-indexer sibling
  tasks remain unchanged.
- Do not edit `openapi/` or docs in this ticket unless the code cannot satisfy
  the issue contract without it.

## Slice Breakdown

### Slice A: Publish Allowance Gate

Rewrite `Cardano.Multisig.Publish` and the publish HTTP route to admit on
indexed allowance, surface named fee reasons, parse optional `fee_payment`, and
delete the datum path. Update publish-focused tests in `PublishSpec` and
`ServerSpec`.

Expected proof:
`nix develop --quiet -c just unit "Cardano.Multisig.Publish"`
and `nix develop --quiet -c just unit "Cardano.Multisig.Server publish HTTP routes"`,
then `./gate.sh`.

### Slice B: Fee-Status Handler

Add `GET /v1/fee-status/{id}` in `Server.hs` on top of the same publish-layer
fee-status mapping. Cover ready, not-seen, unconfirmed, insufficient, malformed,
and invalid query/path behavior in `ServerSpec`.

Expected proof:
`nix develop --quiet -c just unit "Cardano.Multisig.Server fee-status"`
then `./gate.sh`.

## Finalization

- Verify grep checks: no forbidden legacy API package string, no old datum-tag
  helper name, and no old tag-mismatch reason string.
- Verify every task in `tasks.md` is checked and every behavior-changing commit
  carries matching `Tasks:` trailers.
- Ensure PR body contains `Closes #31`.
- Drop `gate.sh` in the final ready-for-review commit, mark PR ready, and wait
  for all six CI checks to report success. Do not merge.
