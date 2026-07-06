# Implementation Plan: Fee-Address Chain Follower / Indexer

## Technical Context

- Repo: `/code/cardano-multisig-30`
- Branch: `feat/fee-indexer`
- PR: <https://github.com/lambdasistemi/cardano-multisig/pull/36>
- Parent epic: #26
- Child ticket: #30
- Dependencies consumed from #28 and #29:
  `Cardano.Multisig.FeeTag.decodeFeeTag`,
  `Cardano.Multisig.Store.FeePayment`, `storeUpsertFeePayment`,
  and `storeRollbackFeePaymentsFrom`.
- Existing startup shape: `runServer` opens one node provider/submitter, opens
  one RocksDB store, starts `runLivenessMonitor` with `withAsync`, then runs
  Warp.
- External patterns studied:
  `/code/chain-follower/lib/ChainFollower.hs`,
  `/code/chain-follower/lib/ChainFollower/Runner.hs`,
  `/code/cardano-stake-csmt/lib/Cardano/StakeCSMT/Ledger/Replay.hs`,
  and the pinned `cardano-node-clients`
  `Cardano.Node.Client.N2C.ChainSync` / `UTxOIndexer.Follower` modules.

The implementation should copy the local shape rather than inventing a second
indexer architecture: build a small `Intersector` / `Follower`, feed it through
`mkChainSyncN2C` + `runChainSyncN2C`, persist resume points, and wrap the whole
session in a supervised retry loop.

## Module Shape

Add `Cardano.Multisig.FeeIndexer` as the only new production module. Expected
exports:

```haskell
data FeeIndexerConfig = FeeIndexerConfig
    { ficSocketPath :: FilePath
    , ficNetworkMagic :: Word32
    , ficByronEpochSlots :: Word64
    , ficFeeAddress :: Addr
    , ficCheckpointDir :: FilePath
    , ficRetryDelayMicros :: Int
    }

data FeeIndexerDeps m = FeeIndexerDeps
    { fidStore :: Store m
    , fidReadTip :: m SlotNo
    }

data FeeIndexerChainEvent
    = FeeIndexerRollForward FeeIndexerBlock SlotNo
    | FeeIndexerRollBackward SlotNo

classifyFeeTx :: Addr -> SlotNo -> FeeIndexerTx -> [FeePayment]
runFeeIndexerOnce :: Monad m => FeeIndexerDeps m -> FeeIndexerChainEvent -> m ()
runFeeIndexer :: FeeIndexerConfig -> FeeIndexerDeps IO -> IO ()
runFeeIndexerSupervisor :: FeeIndexerConfig -> FeeIndexerDeps IO -> IO ()
```

Names may vary if the final code reads better, but keep this separation:

- pure transaction/block classification is testable without a node;
- one chain event application writes store effects;
- production ChainSync and retry are thin wrappers around those pieces.

## Classification Details

For Shelley-family transactions extracted from a block:

- read outputs from the transaction body with ledger lenses
  (`bodyTxL`, `outputsTxBodyL`, `addrTxOutL`, `valueTxOutL`);
- derive created `TxIn`s from the transaction body id plus output index, using
  `TxIx`;
- extract ADA lovelace with the same `MaryValue (Coin n) _` pattern used by
  `Cardano.Multisig.Publish.lovelaceOf`;
- read auxiliary metadata from the ledger transaction, normalize it to
  `Map Word64 Metadatum`, and pass it to `decodeFeeTag`;
- for every output whose address equals `ficFeeAddress` and whose lovelace is
  positive, emit one `FeePayment` when the tag decodes;
- emit nothing for wrong-address outputs or undecodable/missing metadata.

The real block extractor can follow the pinned `cardano-node-clients`
`UTxOIndexer.BlockExtract` pattern: `fromConsensusBlock`,
`getEraTransactions`, and `applyEraFun`. If direct ledger auxiliary-data lenses
are noisy, adding the already-pinned `cardano-ledger-read` package to
`cardano-multisig.cabal` is allowed; changing source pins is not.

## ChainSync / Checkpoint Details

Production follower:

- Use `Cardano.Node.Client.N2C.ChainSync.Fetched`, `HeaderPoint`,
  `mkChainSyncN2C`, and `runChainSyncN2C`.
- Use `ChainFollower.Intersector`, `Follower`, and `ProgressOrRewind`.
- Persist at least the newest usable resume point as `(slot, block-hash)` under
  `ficCheckpointDir`, using a small file-backed encoding. The checkpoint must
  be durable across process restart.
- On cold start, offer `Origin`.
- On warm start, offer the persisted point first.
- On `intersectFound`, roll the store back to the intersected slot before
  following.
- On `intersectNotFound` from a warm checkpoint, reset safely by rolling fee
  payments back from slot 0 and then retrying from `Origin`; never replay from
  genesis over a populated fee-payment set without first clearing indexed
  payment rows.
- On roll-forward, apply classified payments, persist the new checkpoint, and
  update the observed tip.
- On roll-backward, call `storeRollbackFeePaymentsFrom rollbackSlot`, persist
  the rollback point when it is concrete, and continue with `Progress`.

Supervisor:

- Wrap one ChainSync session in `try`.
- Re-throw asynchronous exceptions so server shutdown cancels cleanly.
- For synchronous exceptions, sleep `ficRetryDelayMicros` and retry forever.
- Keep this local if importing `Cardano.Node.Client.N2C.Reconnect` would force
  unrelated tracer/probe configuration into this service.

## Runtime Configuration

Extend `RuntimeConfig` only with startup fields needed by the indexer:

- checkpoint directory: default `CARDANO_MULTISIG_STORE <> "-fee-indexer"`,
  overridable by `FEE_INDEXER_CHECKPOINT_DIR`;
- Byron epoch slots: `FEE_INDEXER_BYRON_EPOCH_SLOTS`, default `21600`;
- retry delay: `FEE_INDEXER_RETRY_DELAY_MICROS`, default `30000000`.

Do not change `PORT`, `NETWORK`, request parsing, publish request shape, route
matching, OpenAPI, docs, or publish failure behavior in this ticket.

## Slice Plan

### Slice 1: Classifier and Mock Event Loop

Worker-owned files:

- `src/Cardano/Multisig/FeeIndexer.hs`
- `test/Cardano/Multisig/FeeIndexerSpec.hs`
- `test/Main.hs`
- `cardano-multisig.cabal`

Work:

- Add the new module with pure transaction/block classification types and
  `runFeeIndexerOnce`.
- Add library exposure and test-suite registration.
- Add RED tests for fee-address+valid-tag writes, wrong address ignored,
  malformed or missing tag ignored, and multiple matching outputs producing
  distinct `TxIn`s.
- Add a mock chain event test proving roll-forward writes payments and rollback
  calls `storeRollbackFeePaymentsFrom`.
- Do not add production ChainSync or server startup wiring yet.

Focused proof:

```bash
nix develop --quiet -c just unit "Cardano.Multisig.FeeIndexer"
./gate.sh
```

Commit:

```text
feat: add fee payment classifier

Tasks: T001
```

### Slice 2: Checkpointed N2C Follower

Worker-owned files:

- `src/Cardano/Multisig/FeeIndexer.hs`
- `test/Cardano/Multisig/FeeIndexerSpec.hs`
- `cardano-multisig.cabal`

Work:

- Add the real `runFeeIndexer` implementation using `chain-follower` and
  `cardano-node-clients` ChainSync.
- Add file-backed checkpoint save/load/list helpers inside `FeeIndexer`.
- Add a supervised retry wrapper that catches synchronous transient failures
  and preserves async cancellation.
- Add tests with an injected ChainSync runner proving warm resume points,
  rollback store calls, safe reset when warm intersection is missing, and retry
  after one transient failure.
- Keep server startup untouched in this slice.

Focused proof:

```bash
nix develop --quiet -c just unit "Cardano.Multisig.FeeIndexer"
./gate.sh
```

Commit:

```text
feat: add checkpointed fee chain follower

Tasks: T002
```

### Slice 3: Server Startup Wiring

Worker-owned files:

- `src/Cardano/Multisig/Server.hs`
- `app/Main.hs`
- `test/Cardano/Multisig/ServerSpec.hs`
- `src/Cardano/Multisig/FeeIndexer.hs`
- `cardano-multisig.cabal`

Work:

- Extend runtime config with fee-indexer startup fields only.
- Build `FeeIndexerConfig` from the existing node socket, network magic, store
  path, and operator fee address.
- Start `runFeeIndexerSupervisor` as a sibling `withAsync` to
  `runLivenessMonitor`, sharing the existing store and node connection
  settings.
- Ensure server shutdown cancels both background asyncs.
- Add a focused server/startup or config test if the current harness can cover
  it without opening a node socket. Otherwise document the no-live-node proof in
  `WIP.md` and rely on unit + gate for this slice.
- Do not touch route matching, publish handlers, request bodies, response
  schemas, OpenAPI, or docs.

Focused proof:

```bash
nix develop --quiet -c just unit "Cardano.Multisig.Server"
./gate.sh
```

Commit:

```text
feat: start fee indexer with server

Tasks: T003
```

### Slice 4: Orchestrator-Owned Finalization

Orchestrator-owned files/actions:

- `specs/030-fee-indexer/tasks.md`
- PR #36 body and readiness state
- `gate.sh` removal after the final gate passes

Work:

- Verify every implementation task is checked and every behavior commit has the
  matching `Tasks:` trailer.
- Rerun `./gate.sh` at HEAD.
- Verify the forbidden-token grep is empty across the worktree.
- Verify GitHub CI for PR #36 is green and log `CI-PASS`.
- Update PR #36 body with delivered behavior and verification evidence.
- Drop `gate.sh` in the final ready-for-review commit.
- Mark PR #36 ready for review.
- Do not merge the PR.

## Risks and Controls

- Ledger auxiliary-data extraction may be type-noisy across eras. Control:
  isolate extraction behind a small function and use `cardano-ledger-read`
  helpers if direct lenses are brittle.
- Warm checkpoint not found can otherwise mix old fork rows with replayed
  canonical rows. Control: roll fee payments back from slot 0 before origin
  reset.
- Startup wiring can drift into #31 scope. Control: Slice 3 owned scope forbids
  route, publish, request, response, OpenAPI, and docs changes.
- A high-level package can sneak in through imports or dependencies. Control:
  `./gate.sh` constructs the forbidden tokens at runtime and fails if a
  worktree grep finds them.
