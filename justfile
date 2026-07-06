# shellcheck shell=bash

set unstable := true

# List available recipes
default:
    @just --list

# Format all source files
format:
    #!/usr/bin/env bash
    set -euo pipefail
    hs_files=$(find . -name '*.hs' -not -path './dist-newstyle/*' -not -path './.direnv/*')
    for i in {1..3}; do
        fourmolu -i $hs_files
    done
    find . -name '*.cabal' -not -path './dist-newstyle/*' | xargs cabal-fmt -i

# Check formatting without modifying files
format-check:
    #!/usr/bin/env bash
    set -euo pipefail
    hs_files=$(find . -name '*.hs' -not -path './dist-newstyle/*' -not -path './.direnv/*')
    fourmolu -m check $hs_files
    find . -name '*.cabal' -not -path './dist-newstyle/*' | xargs cabal-fmt -c

# Run hlint
hlint:
    #!/usr/bin/env bash
    set -euo pipefail
    find . -name '*.hs' -not -path './dist-newstyle/*' -not -path './.direnv/*' | xargs hlint

# Check cabal package metadata
cabal-check:
    #!/usr/bin/env bash
    set -euo pipefail
    cabal check --ignore=missing-upper-bounds --ignore=no-modules-exposed --ignore=option-o2

# Build all components
build:
    #!/usr/bin/env bash
    set -euo pipefail
    cabal build all --enable-tests

# Run unit tests with optional match pattern
test match="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ '{{ match }}' == "" ]]; then
        cabal test unit-tests --test-show-details=direct
    else
        cabal test unit-tests \
            --test-show-details=direct \
            --test-option=--match \
            --test-option="{{ match }}"
    fi

# Alias for test
unit match="":
    just test "{{ match }}"

# Run the live devnet publish smoke
devnet-publish-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    nix run --quiet .#devnet-publish-smoke

# Run the server against a devnet node
devnet-server:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${CARDANO_NODE_SOCKET:?set to the devnet node socket path}"
    export CARDANO_NODE_MAGIC="${CARDANO_NODE_MAGIC:-42}"
    : "${CARDANO_MULTISIG_STORE:?set to the server RocksDB store path}"
    : "${FEE_ADDRESS:?set to the devnet fee payment address}"
    : "${BASE_LOVELACE:?set to the fixed fee floor in lovelace}"
    : "${RATE_LOVELACE_PER_SLOT:?set to the fee rate per TTL slot}"
    : "${TTL_HORIZON_SLOTS:?set to the accepted TTL horizon in slots}"
    exec nix run --quiet .#cardano-multisig-server

# Opt-in live N2C smoke against the preprod node on development.
live-chain-payment-read:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${CARDANO_MULTISIG_LIVE_TXIN:?set to <64-hex-txid>#<index> for a currently unspent preprod output}"
    socket="${CARDANO_MULTISIG_LIVE_SOCKET:-/node/preprod/ipc/node.socket}"
    magic="${CARDANO_MULTISIG_LIVE_MAGIC:-1}"
    remote_dir="${CARDANO_MULTISIG_LIVE_REMOTE_DIR:-/code/cardano-multisig-e2}"
    ssh development \
        "test -S '$socket' && cd '$remote_dir' && CARDANO_MULTISIG_LIVE_SMOKE=1 CARDANO_MULTISIG_LIVE_TXIN='$CARDANO_MULTISIG_LIVE_TXIN' CARDANO_MULTISIG_LIVE_SOCKET='$socket' CARDANO_MULTISIG_LIVE_MAGIC='$magic' nix develop --quiet -c just unit 'live N2C payment reader smoke'"

# Full CI pipeline (run inside nix develop)
ci:
    #!/usr/bin/env bash
    set -euo pipefail
    just build
    just test
    just format-check
    just hlint

# Serve mkdocs documentation locally
serve-docs:
    #!/usr/bin/env bash
    mkdocs serve

# Build mkdocs documentation
build-docs:
    #!/usr/bin/env bash
    mkdocs build

# Build and load the docker image
build-docker tag='latest':
    #!/usr/bin/env bash
    set -euo pipefail
    nix build .#docker-image
    docker load < result
    version=$(nix eval --raw .#version)
    docker image tag \
        ghcr.io/lambdasistemi/cardano-multisig:"$version" \
        "ghcr.io/lambdasistemi/cardano-multisig:{{ tag }}"

# Start the self-host docker compose
start-docker bg="false":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ '{{ bg }}' == "true" ]]; then
        docker compose -f CD/docker-compose.yaml up -d --remove-orphans
    else
        docker compose -f CD/docker-compose.yaml up --remove-orphans
    fi

# Stop the self-host docker compose
stop-docker:
    #!/usr/bin/env bash
    docker compose -f CD/docker-compose.yaml down

# Clean build artifacts
clean:
    #!/usr/bin/env bash
    cabal clean
    rm -rf result
