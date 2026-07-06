#!/usr/bin/env bash
set -euo pipefail

git diff --check

if rg -n "cardano-api" \
    app \
    src \
    test \
    cardano-multisig.cabal \
    cabal.project \
    flake.nix \
    nix \
    justfile
then
    echo "cardano-api surfaced in code, dependency, or run configuration"
    exit 1
fi

nix build --quiet .#cardano-multisig .#unit-tests
nix develop --quiet -c just ci
nix develop --quiet -c just build-docs
