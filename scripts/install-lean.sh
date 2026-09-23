#!/usr/bin/env bash
# Install elan and the pinned Lean toolchain (lean-toolchain).
#
# Tries the standard elan path first, which is what works on GitHub runners.
# Falls back to linking a toolchain unpacked from the GitHub release zip,
# which is what a sandboxed environment needs when its egress proxy blocks
# elan's toolchain download (release.lean-lang.org, as of this writing).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LEAN_VER="$(sed 's/.*:v//' "$REPO/lean-toolchain")"

if [ ! -x "$HOME/.elan/bin/elan" ]; then
  curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --default-toolchain none
fi
export PATH="$HOME/.elan/bin:$PATH"

if elan toolchain install "leanprover/lean4:v$LEAN_VER"; then
  echo "lean $LEAN_VER installed via elan"
else
  echo "elan toolchain install failed; falling back to the GitHub release zip"
  TC="$HOME/toolchains/lean-$LEAN_VER-linux"
  if [ ! -x "$TC/bin/lean" ]; then
    mkdir -p "$HOME/toolchains"
    curl -sSfL -o "$HOME/toolchains/lean.zip" \
      "https://github.com/leanprover/lean4/releases/download/v$LEAN_VER/lean-$LEAN_VER-linux.zip"
    python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
      "$HOME/toolchains/lean.zip" "$HOME/toolchains"
    chmod -R +x "$TC/bin"
    rm "$HOME/toolchains/lean.zip"
  fi
  elan toolchain link "leanprover/lean4:v$LEAN_VER" "$TC"
  echo "lean $LEAN_VER linked from GitHub release zip"
fi
echo "lean ready: export PATH=\$HOME/.elan/bin:\$PATH"
