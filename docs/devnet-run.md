# Devnet runbook

Use the `devnet-server` recipe to run `cardano-multisig-server` against a
local Cardano devnet node. The recipe reuses the server's runtime environment
and only supplies a devnet default for `CARDANO_NODE_MAGIC`.

```bash
export CARDANO_NODE_SOCKET=/path/to/devnet/node.socket
export CARDANO_MULTISIG_STORE=/tmp/cardano-multisig-devnet/store
export FEE_ADDRESS=addr_test...
export BASE_LOVELACE=1000000
export RATE_LOVELACE_PER_SLOT=0
export TTL_HORIZON_SLOTS=100000

just devnet-server
```

## Runtime environment

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `CARDANO_NODE_SOCKET` | yes | none | Path to the devnet node socket. |
| `CARDANO_NODE_MAGIC` | no | `42` | Devnet network magic passed to node-to-client queries. |
| `CARDANO_MULTISIG_STORE` | yes | none | RocksDB store path for published entries and collected witnesses. |
| `FEE_ADDRESS` | yes | none | Bech32 address that must receive the publish fee. |
| `BASE_LOVELACE` | yes | none | Fixed lovelace floor for a valid publish fee. |
| `RATE_LOVELACE_PER_SLOT` | yes | none | Extra lovelace charged per TTL slot. |
| `TTL_HORIZON_SLOTS` | yes | none | Maximum accepted TTL horizon for fee calculation. |
| `FEE_INDEXER_CHECKPOINT_DIR` | no | `${CARDANO_MULTISIG_STORE}-fee-indexer` | Fee-indexer checkpoint directory. |
| `FEE_INDEXER_BYRON_EPOCH_SLOTS` | no | `21600` | Byron epoch length used by the fee indexer. |
| `FEE_INDEXER_RETRY_DELAY_MICROS` | no | `30000000` | Fee-indexer retry delay in microseconds. |

## Fee schedule

The server accepts a publish request only after it finds a fee payment to
`FEE_ADDRESS` on the configured devnet. The required fee is:

```text
BASE_LOVELACE + RATE_LOVELACE_PER_SLOT * max(0, invalid_hereafter - current_slot)
```

Choose a `BASE_LOVELACE` high enough to make spam expensive on the devnet.
Use `RATE_LOVELACE_PER_SLOT=0` for a flat devnet fee, or set a positive rate
when longer-lived transactions should pay more.

## Confirmation depth

Published fee payments must remain visible for the fixed confirmation depth
compiled into the server. `publishRequiredConfirmationDepth` is `5`, so the
server waits for five confirmations before treating a publish fee as settled.
