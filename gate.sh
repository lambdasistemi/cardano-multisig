#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix build .#cardano-multisig .#unit-tests
nix develop --quiet -c just ci
