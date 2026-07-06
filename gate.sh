#!/usr/bin/env bash
set -euo pipefail

nix build .#cardano-multisig .#unit-tests
nix develop --quiet -c just ci
