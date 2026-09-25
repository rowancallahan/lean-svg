#!/usr/bin/env bash
# Every test, over the whole corpus. Stops at the first failure.
# Run before finalizing any change (docs/DECISIONS.md). Takes several minutes.
#
# Needs what scripts/cloud-setup.sh installs: Lean, resvg 0.48.1, the
# resvg test suite in tests/corpora/resvg-test-suite, numpy + pillow; plus
# cargo (tests/jpeg_ref), uharfbuzz and python-bidi for the
# oracle checks. Nothing is cloned or installed here.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.elan/bin:$PATH"

need() { command -v "$1" >/dev/null || { echo "full-check: '$1' not on PATH ($2)" >&2; exit 1; }; }
need lake "run scripts/install-lean.sh"
need resvg "cargo install resvg --version 0.48.1 --locked"
need cargo "the Rust toolchain, for tests/jpeg_ref"
[ -d tests/corpora/resvg-test-suite/tests ] || {
  echo "full-check: tests/corpora/resvg-test-suite missing; clone it:" >&2
  echo "  git clone --depth 1 https://github.com/linebender/resvg-test-suite tests/corpora/resvg-test-suite" >&2
  exit 1; }
[ -d tests/corpora/realworld ] || { echo "full-check: tests/corpora/realworld missing (it is committed)" >&2; exit 1; }
python3 -c "import numpy, PIL, uharfbuzz, bidi" || {
  echo "full-check: pip install numpy pillow uharfbuzz python-bidi" >&2; exit 1; }

step() { echo; echo "== $*"; "$@"; }

step lake build
step bash scripts/check-theorems.sh
for f in tests/*.lean; do step lake env lean "$f"; done
step python3 tests/run_tests.py
step python3 tests/run_adversarial.py
step python3 tests/run_tiles.py
step python3 tests/check_licenses.py
# Oracle checks not in CI: CLI contract, colour names, bidi, shaping, decoders.
step python3 tests/check_warnings.py
step python3 tests/check_colors.py
step python3 tests/check_bidi.py
step python3 tests/check_shape.py
step python3 tests/check_png_decode.py --no-fetch
step python3 tests/check_jpeg_decode.py
# The byte lock: renders the entire corpus (resvg suite at 100 and 200 px,
# tests/svg/*.svg at native size, tests/corpora/realworld at 1000 px; 4,297
# renders) and requires every PNG, warnings file and exit code unchanged.
step python3 tests/freeze.py check tests/freeze.json --jobs 8

echo; echo "full-check ok"
