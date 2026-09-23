#!/usr/bin/env bash
# Bootstrap a fresh cloud container: Lean toolchain, resvg/usvg oracle, the
# resvg test suite, and a first build. Idempotent. Run from the repo root.
#
# release.lean-lang.org is blocked by the egress proxy in these sessions, so
# the toolchain comes from the GitHub release zip and is linked into elan.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LEAN_VER="$(sed 's/.*:v//' "$REPO/lean-toolchain")"
TC="$HOME/toolchains/lean-$LEAN_VER-linux"

if [ ! -x "$HOME/.elan/bin/elan" ]; then
  curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --default-toolchain none || true
fi
test -x "$HOME/.elan/bin/elan"

if [ ! -x "$TC/bin/lean" ]; then
  mkdir -p "$HOME/toolchains"
  curl -sSfL -o "$HOME/toolchains/lean.zip" \
    "https://github.com/leanprover/lean4/releases/download/v$LEAN_VER/lean-$LEAN_VER-linux.zip"
  python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
    "$HOME/toolchains/lean.zip" "$HOME/toolchains"
  chmod -R +x "$TC/bin"
  rm "$HOME/toolchains/lean.zip"
fi
"$HOME/.elan/bin/elan" toolchain link "leanprover/lean4:v$LEAN_VER" "$TC"

command -v resvg >/dev/null || cargo install resvg --version 0.48.1 --locked
command -v usvg >/dev/null || cargo install usvg --version 0.48.1 --locked
python3 -c "import numpy, PIL" 2>/dev/null || pip install -q numpy pillow

mkdir -p "$REPO/tests/corpora"
if [ ! -d "$REPO/tests/corpora/resvg-test-suite/tests" ]; then
  git clone --depth 1 https://github.com/linebender/resvg-test-suite \
    "$REPO/tests/corpora/resvg-test-suite"
fi

cd "$REPO"
"$HOME/.elan/bin/lake" build
echo "setup ok: export PATH=\$HOME/.elan/bin:\$PATH"
