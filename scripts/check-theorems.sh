#!/usr/bin/env bash
# Elaborate every theorem file and fail on sorry or on any axiom beyond the
# standard three. Stopgap until T43's CI lands.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.elan/bin:$PATH"
tmp="$(mktemp --suffix=.lean)"
cat > "$tmp" <<'LEAN'
import LeanSvg
#print axioms LeanSvg.Prog.runFS_frame
#print axioms LeanSvg.Prog.runFS_input_only
#print axioms LeanSvg.Prog.renderProgram_spec
#print axioms LeanSvg.Prog.renderProgram_error_no_write
#print axioms LeanSvg.Prog.renderProgram_ok_output
#print axioms LeanSvg.Prog.renderProgram_ok_frame
LEAN
out="$(lake env lean "$tmp"; for f in proofs/*.lean tests/*.lean; do case "$f" in *-wip.lean) continue;; esac; lake env lean "$f"; done)"
rm "$tmp"
echo "$out"
! echo "$out" | grep -E "sorryAx|declaration uses 'sorry'|error:"
! echo "$out" | grep "axioms:" | grep -vE "^'[^']*' depends on axioms: \[(propext|Classical.choice|Quot.sound)(, (propext|Classical.choice|Quot.sound))*\]$"
echo "theorems ok"
