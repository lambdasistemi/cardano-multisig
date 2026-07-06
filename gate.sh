#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix build --quiet .#cardano-multisig .#unit-tests
nix develop --quiet -c just ci
