#!/usr/bin/env python3
"""Adapts the `resvg` CLI to lean-svg's `run_corpora.py --bin` contract, so the
harness can score resvg itself against a chosen `--ref` (e.g. `--ref chrome`)
using the exact same code path as scoring lean-svg -- no separate "resvg vs
the reference" plumbing needed.

    python3 tests/run_corpora.py --ref chrome --bin tests/resvg_as_bin.py ...

lean-svg's contract is `bin SRC DST --width N`; resvg's is `resvg --skip...
-w N SRC DST`. This just reorders/renames and pins the suite's fonts, the
same way `run_tests.resvg_font_args` does for the oracle role.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FONTS_DIR = REPO / "tests" / "corpora" / "resvg-test-suite" / "fonts"

src, dst = sys.argv[1], sys.argv[2]
width = sys.argv[sys.argv.index("--width") + 1] if "--width" in sys.argv else None

cmd = ["resvg"]
if FONTS_DIR.is_dir():
    cmd += ["--skip-system-fonts", "--use-fonts-dir", str(FONTS_DIR)]
if width is not None:
    cmd += ["-w", width]
cmd += [src, dst]

sys.exit(subprocess.run(cmd).returncode)
