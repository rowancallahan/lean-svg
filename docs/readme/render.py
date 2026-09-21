#!/usr/bin/env python3
"""Render the README showcase images with lean-svg and resvg, and diff them.

Both SVG sources in this directory are original artwork for this project,
Apache-2.0 like the rest of it, so the PNGs may be committed and shown freely.

    python3 docs/readme/render.py
"""
from __future__ import annotations

import os
import platform
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
BIN = REPO / ".lake" / "build" / "bin" / "lean-svg"
FONTS = REPO / "tests" / "corpora" / "resvg-test-suite" / "fonts"
WIDTH = 800

# name -> source. All three are this project's own artwork (the stress field
# has been in tests/svg since the first commit), so the renders are ours to
# publish.
SOURCES = {
    "confetti": HERE / "confetti.svg",
    "icons": HERE / "icons.svg",
    "stress": REPO / "tests" / "svg" / "16_stress_2000.svg",
}


def run(cmd: list[str], repeats: int = 5) -> float:
    """Run a command `repeats` times, return the median wall time in ms."""
    times = []
    for _ in range(repeats):
        t0 = time.perf_counter()
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        times.append((time.perf_counter() - t0) * 1000.0)
        if proc.returncode != 0:
            sys.exit(f"failed: {' '.join(cmd)}\n{proc.stderr.strip()}")
    return statistics.median(times)


def main() -> int:
    if not BIN.exists():
        sys.exit(f"no binary at {BIN} — run `lake build` first")
    try:
        from PIL import Image, ImageChops
    except ImportError:
        sys.exit("needs Pillow: pip3 install --user pillow")

    rows = []
    for name, src in SOURCES.items():
        ours_p, ref_p, diff_p = (HERE / f"{name}-{k}.png" for k in ("ours", "resvg", "diff"))

        ms_ours = run([str(BIN), str(src), str(ours_p),
                       "--width", str(WIDTH), "--background", "white"])
        raw_bytes = ours_p.stat().st_size

        ref_cmd = ["resvg", "-w", str(WIDTH), "--background", "white"]
        if FONTS.is_dir():
            ref_cmd += ["--skip-system-fonts", "--use-fonts-dir", str(FONTS)]
        ms_ref = run(ref_cmd + [str(src), str(ref_p)])

        a = Image.open(ours_p).convert("RGB")
        b = Image.open(ref_p).convert("RGB")
        if a.size != b.size:
            sys.exit(f"{name}: size mismatch {a.size} vs {b.size}")
        d = ImageChops.difference(a, b)
        px = [max(p) for p in d.getdata()]
        n = len(px)
        exact = 100.0 * sum(v == 0 for v in px) / n
        within8 = 100.0 * sum(v <= 8 for v in px) / n
        # amplify so a one-level edge difference is visible at all
        d.point(lambda v: min(255, v * 12)).save(diff_p, optimize=True)

        # Our PNG encoder writes *stored* (uncompressed) deflate on purpose:
        # a verified DEFLATE is future work (PLAN M7). That makes the file
        # several times larger than resvg's, which is fine for correctness but
        # not for a README, so the committed copy is losslessly recompressed.
        # The pixels are untouched; `raw_bytes` records what we actually emit.
        a.save(ours_p, optimize=True)

        rows.append({
            "name": name, "exact": exact, "within8": within8, "max_d": max(px),
            "ms_ours": ms_ours, "ms_ref": ms_ref,
            "raw_kb": raw_bytes / 1024, "ref_kb": ref_p.stat().st_size / 1024,
        })
        print(f"{name:10} exact {exact:6.2f}%  within 8 {within8:6.2f}%  max {max(px):3d}   "
              f"{ms_ours:7.1f} ms vs resvg {ms_ref:6.1f} ms   "
              f"png {raw_bytes/1024:7.1f} KB vs {ref_p.stat().st_size/1024:6.1f} KB")

    print(f"\nmachine: {platform.machine()}, {os.cpu_count()} cores, "
          f"macOS {platform.mac_ver()[0]}, at --width {WIDTH}\n")
    print("| | lean-svg | resvg 0.48.1 | difference (amplified 12x) |")
    print("|---|---|---|---|")
    for r in rows:
        print(
            f"| **{r['name']}**<br>{r['within8']:.2f}% within 8<br>{r['exact']:.2f}% exact"
            f"<br>{r['ms_ours']:.0f} ms vs {r['ms_ref']:.0f} ms "
            f"| ![{r['name']}, lean-svg](docs/readme/{r['name']}-ours.png) "
            f"| ![{r['name']}, resvg](docs/readme/{r['name']}-resvg.png) "
            f"| ![{r['name']}, difference](docs/readme/{r['name']}-diff.png) |"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
