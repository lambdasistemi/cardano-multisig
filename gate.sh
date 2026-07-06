#!/usr/bin/env bash
set -euo pipefail

git diff --check
forbidden_pkg='cardano-''api'
forbidden_mod='Cardano''.Api'
if rg -n "$forbidden_pkg|$forbidden_mod" \
  --glob '!dist-newstyle/**' \
  --glob '!.git/**' \
  .; then
  echo "$forbidden_pkg is forbidden in this PR" >&2
  exit 1
fi
nix build .#cardano-multisig .#unit-tests
nix develop --quiet -c just ci
