#!/usr/bin/env bash
# T43/T43b invariants gate: the single script the CI `invariants` job calls.
# Runs the axiom audit (proofs/*.lean and LeanSvg/Cli.lean, discovered
# from source so a new theorem can't dodge it) and the structural checks
# (no IO under LeanSvg/, Main.lean's file-system calls exactly an allowlist,
# no output on the main path, no partial/unsafe/@[extern]/panic!/Float/
# !-indexing under LeanSvg/).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.elan/bin:$PATH"
python3 scripts/axiom_audit.py
python3 tests/check_invariants.py
echo "theorems ok"
