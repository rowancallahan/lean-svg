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

from run_tests import RESVG_FONTS_DIR as FONTS_DIR, resvg_font_file_args

src, dst = sys.argv[1], sys.argv[2]
width = sys.argv[sys.argv.index("--width") + 1] if "--width" in sys.argv else None

cmd = ["resvg"]
if FONTS_DIR.is_dir():
    # sorted --use-font-file, not --use-fonts-dir: see run_tests.resvg_font_file_args
    cmd += ["--skip-system-fonts"] + resvg_font_file_args()
    # T110: generic families as resvg's integration tests set them
    # (keep in step with `run_tests.RESVG_GENERIC_ARGS`)
    cmd += ["--serif-family", "Noto Serif", "--sans-serif-family", "Noto Sans",
            "--cursive-family", "Yellowtail", "--fantasy-family", "Sedgwick Ave Display",
            "--monospace-family", "Noto Mono"]
if width is not None:
    cmd += ["-w", width]
cmd += [src, dst]

sys.exit(subprocess.run(cmd).returncode)
