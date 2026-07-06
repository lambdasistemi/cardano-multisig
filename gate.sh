#!/usr/bin/env bash
set -euo pipefail

git diff --check

forbidden='cardano-''api'
if rg -n "$forbidden" .; then
  echo "forbidden dependency name found; remove all literal mentions" >&2
  exit 1
fi

nix build --quiet .#cardano-multisig .#unit-tests
nix develop --quiet -c just ci
