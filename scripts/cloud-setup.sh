#!/usr/bin/env bash
# Bootstrap a fresh cloud container: Lean toolchain, resvg/usvg oracle, the
# resvg test suite, and a first build. Idempotent. Run from the repo root.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
bash "$REPO/scripts/install-lean.sh"

command -v resvg >/dev/null || cargo install resvg --version 0.48.1 --locked
command -v usvg >/dev/null || cargo install usvg --version 0.48.1 --locked
python3 -c "import numpy, PIL" 2>/dev/null || pip install -q numpy pillow
python3 -c "import playwright" 2>/dev/null || pip install -q playwright

mkdir -p "$REPO/tests/corpora"
if [ ! -d "$REPO/tests/corpora/resvg-test-suite/tests" ]; then
  git clone --depth 1 https://github.com/linebender/resvg-test-suite \
    "$REPO/tests/corpora/resvg-test-suite"
fi

cd "$REPO"
"$HOME/.elan/bin/lake" build
echo "setup ok: export PATH=\$HOME/.elan/bin:\$PATH"
