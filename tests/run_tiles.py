#!/usr/bin/env python3
"""Viewport (tile) harness: check that rendering a window of the zoomed image
gives exactly the same pixels as cutting that window out of the whole image.

For every tests/svg/*.svg it renders the full image at --width 800, renders the
four quadrants as tiles at the same zoom, stitches them with numpy and requires
the result to be byte-identical to the full render.  It then checks a tile that
lies entirely off the document (must be transparent) and one that only partly
overlaps it (the overlap must equal the matching crop of the full render).

Finally it times a 512x512 tile at --width 4000 for a few corpus files: the
number a zoomable viewer cares about, since that is one tile of a 4000 px wide
virtual image.

Nothing is written outside a temporary directory.
"""

import argparse
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SVG_DIR = REPO / "tests" / "svg"
DEFAULT_BIN = REPO / ".lake" / "build" / "bin" / "lean-svg"

RENDER_TIMEOUT = 120  # seconds, per subprocess

STITCH_WIDTH = 800  # zoom used for the stitching tests
OFF_TILE = (-100, -100, 50, 50)  # a tile that cannot touch the document
PARTIAL_TILE = (-20, -20, 100, 100)  # a tile whose bottom-right corner overlaps

TIMING_WIDTH = 4000  # virtual image width for the timing test
TIMING_TILE = 512  # tile edge, in pixels
TIMING_REPEATS = 5
TIMING_FILES = ["12_badge", "16_stress_2000", "18_rose_lissajous"]


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------


class RenderError(Exception):
    pass


def render(binary, svg, out, extra):
    """Render one file. Returns the elapsed wall-clock time in ms.

    Deletes `out` first: lean-svg refuses to overwrite an existing output
    file, and every caller here reuses a fixed path across multiple renders
    on purpose (quadrant tiles, timing repeats).
    """
    out = Path(out)
    out.unlink(missing_ok=True)
    Path(str(out) + ".warnings.txt").unlink(missing_ok=True)  # T98
    cmd = [str(binary), str(svg), str(out)] + [str(a) for a in extra]
    start = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=RENDER_TIMEOUT
        )
    except subprocess.TimeoutExpired:
        raise RenderError("timed out after %ds: %s" % (RENDER_TIMEOUT, " ".join(cmd)))
    elapsed = (time.perf_counter() - start) * 1000.0
    if proc.returncode != 0:
        raise RenderError(
            "%s\n      %s" % (proc.stderr.decode("utf-8", "replace").strip(), " ".join(cmd))
        )
    return elapsed


def render_rgba(binary, svg, out, extra):
    """Render one file and return its pixels as an (h, w, 4) uint8 array."""
    render(binary, svg, out, extra)
    with Image.open(out) as img:
        if img.mode != "RGBA":
            raise RenderError("expected an RGBA PNG, got %s" % img.mode)
        return np.asarray(img, dtype=np.uint8).copy()


def tile_args(width, x, y, w, h):
    return ["--width", width, "--viewport", x, y, w, h]


# --------------------------------------------------------------------------
# checks
# --------------------------------------------------------------------------


def mismatch(a, b):
    """Describe how two pixel arrays differ, or None if they are identical."""
    if a.shape != b.shape:
        return "shape %s vs %s" % (a.shape, b.shape)
    if np.array_equal(a, b):
        return None
    delta = np.abs(a.astype(np.int32) - b.astype(np.int32)).max(axis=2)
    ys, xs = np.nonzero(delta)
    return "%d of %d pixels differ (max channel delta %d, first at row %d col %d)" % (
        len(ys),
        delta.size,
        int(delta.max()),
        int(ys[0]),
        int(xs[0]),
    )


def halves(n):
    """Split n into two spans, giving the extra pixel of an odd n to the second."""
    return [(0, n // 2), (n // 2, n - n // 2)]


def check_stitch(binary, svg, tmp, failures):
    """Full render vs the four quadrant tiles stitched back together."""
    full = render_rgba(binary, svg, tmp / "full.png", ["--width", STITCH_WIDTH])
    h, w = full.shape[:2]
    stitched = np.zeros_like(full)
    for x0, tw in halves(w):
        for y0, th in halves(h):
            tile = render_rgba(
                binary, svg, tmp / "tile.png", tile_args(STITCH_WIDTH, x0, y0, tw, th)
            )
            if tile.shape != (th, tw, 4):
                failures.append(
                    "%s: tile %d %d %d %d came out %dx%d"
                    % (svg.stem, x0, y0, tw, th, tile.shape[1], tile.shape[0])
                )
                return full, "size"
            stitched[y0 : y0 + th, x0 : x0 + tw] = tile
    bad = mismatch(full, stitched)
    if bad:
        failures.append("%s: stitched quadrants != full render: %s" % (svg.stem, bad))
    return full, bad


def check_off_document(binary, svg, tmp, failures):
    """A tile that cannot touch the document must be fully transparent."""
    x, y, w, h = OFF_TILE
    tile = render_rgba(binary, svg, tmp / "off.png", tile_args(STITCH_WIDTH, x, y, w, h))
    if tile.shape != (h, w, 4):
        failures.append("%s: off-document tile came out %dx%d" % (svg.stem, tile.shape[1], tile.shape[0]))
        return False
    if tile.any():
        failures.append(
            "%s: off-document tile is not transparent (%d non-zero pixels)"
            % (svg.stem, int((tile.any(axis=2)).sum()))
        )
        return False
    return True


def check_partial(binary, svg, full, tmp, failures):
    """A tile straddling the top-left corner: overlap equals the crop, rest is clear."""
    x, y, w, h = PARTIAL_TILE
    tile = render_rgba(binary, svg, tmp / "part.png", tile_args(STITCH_WIDTH, x, y, w, h))
    if tile.shape != (h, w, 4):
        failures.append("%s: partial tile came out %dx%d" % (svg.stem, tile.shape[1], tile.shape[0]))
        return False
    ok = True
    ox, oy = -x, -y  # where the document starts inside the tile
    cw, ch = min(w - ox, full.shape[1]), min(h - oy, full.shape[0])
    bad = mismatch(tile[oy : oy + ch, ox : ox + cw], full[0:ch, 0:cw])
    if bad:
        failures.append("%s: partial tile overlap != crop of full render: %s" % (svg.stem, bad))
        ok = False
    if tile[:oy, :].any() or tile[:, :ox].any():
        failures.append("%s: partial tile is not transparent outside the document" % svg.stem)
        ok = False
    return ok


# --------------------------------------------------------------------------
# timing
# --------------------------------------------------------------------------


def time_tile(binary, svg, tmp, full_height_800):
    """Median ms for one centred TIMING_TILE tile of a TIMING_WIDTH wide image."""
    scale = TIMING_WIDTH / float(STITCH_WIDTH)
    virtual_h = int(round(full_height_800 * scale))
    x = max(0, (TIMING_WIDTH - TIMING_TILE) // 2)
    y = max(0, (virtual_h - TIMING_TILE) // 2)
    args = tile_args(TIMING_WIDTH, x, y, TIMING_TILE, TIMING_TILE)
    times = [render(binary, svg, tmp / "timing.png", args) for _ in range(TIMING_REPEATS)]
    return statistics.median(times), (x, y)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filter", help="only run tests whose name contains SUBSTR")
    parser.add_argument("--bin", default=str(DEFAULT_BIN), help="path to the lean-svg binary")
    parser.add_argument("--no-timing", action="store_true", help="skip the timing section")
    args = parser.parse_args()

    binary = Path(args.bin).resolve()
    if not binary.is_file():
        print("lean-svg binary not found at %s" % binary, file=sys.stderr)
        print("build it first:  lake build", file=sys.stderr)
        return 2

    svgs = sorted(SVG_DIR.glob("*.svg"))
    if args.filter:
        svgs = [s for s in svgs if args.filter in s.name]
    if not svgs:
        print("no SVGs to test in %s" % SVG_DIR, file=sys.stderr)
        return 2

    tmp = Path(tempfile.mkdtemp(prefix="lean-svg_tiles_"))
    failures = []
    heights = {}
    try:
        header = "%-22s  %13s  %9s  %9s  %9s  %s" % (
            "name",
            "size",
            "stitch",
            "off-doc",
            "partial",
            "result",
        )
        print(header)
        print("-" * len(header))
        for svg in svgs:
            try:
                full, bad = check_stitch(binary, svg, tmp, failures)
                heights[svg.stem] = full.shape[0]
                off = check_off_document(binary, svg, tmp, failures)
                part = check_partial(binary, svg, full, tmp, failures)
            except RenderError as exc:
                failures.append("%s: %s" % (svg.stem, exc))
                print("%-22s  %13s  %9s  %9s  %9s  %s" % (svg.stem, "-", "-", "-", "-", "ERROR"))
                print("      ! %s" % exc)
                continue
            ok = bad is None and off and part
            print(
                "%-22s  %13s  %9s  %9s  %9s  %s"
                % (
                    svg.stem,
                    "%dx%d" % (full.shape[1], full.shape[0]),
                    "exact" if bad is None else "DIFFERS",
                    "clear" if off else "BAD",
                    "exact" if part else "BAD",
                    "PASS" if ok else "FAIL",
                )
            )

        if not args.no_timing:
            print()
            print(
                "interactive tile: %dx%d window of a %d px wide image (median of %d)"
                % (TIMING_TILE, TIMING_TILE, TIMING_WIDTH, TIMING_REPEATS)
            )
            print("%-22s  %10s  %s" % ("name", "ms", "viewport"))
            print("-" * 48)
            for name in TIMING_FILES:
                svg = SVG_DIR / (name + ".svg")
                if not svg.is_file() or name not in heights:
                    print("%-22s  %10s  %s" % (name, "-", "not rendered"))
                    continue
                try:
                    ms, (x, y) = time_tile(binary, svg, tmp, heights[name])
                except RenderError as exc:
                    failures.append("%s: timing: %s" % (name, exc))
                    print("%-22s  %10s  %s" % (name, "-", "ERROR"))
                    continue
                print(
                    "%-22s  %10.1f  --viewport %d %d %d %d"
                    % (name, ms, x, y, TIMING_TILE, TIMING_TILE)
                )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    if failures:
        print("%d failure(s):" % len(failures))
        for f in failures:
            print("  ! %s" % f)
        return 1
    print("%d/%d files: quadrant tiles stitch byte-identically to the full render" % (len(svgs), len(svgs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
