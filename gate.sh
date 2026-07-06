#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

git diff --check

if rg -n "cardano-api" \
  cabal.project \
  cardano-multisig.cabal \
  flake.nix \
  nix \
  src \
  app \
  test \
  .github; then
  echo "gate failed: cardano-api is forbidden in #32" >&2
  exit 1
fi

nix build --quiet .#cardano-multisig .#unit-tests
nix develop --quiet -c just ci
