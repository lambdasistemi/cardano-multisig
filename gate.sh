#!/usr/bin/env bash
set -euo pipefail

git diff --check

forbidden_package='cardano''-api'
if rg -n "$forbidden_package" .; then
  echo "forbidden legacy API package string found" >&2
  exit 1
fi

nix build .#cardano-multisig .#unit-tests
nix develop --quiet -c just ci
