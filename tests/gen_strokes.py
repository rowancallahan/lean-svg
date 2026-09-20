#!/usr/bin/env python3
"""Generate the stroker probe set into tests/out/strokes/ (not committed).

The corpus in tests/svg/ barely exercises the stroker: it has one file with the
three join types and three cap types, and a couple of stroked polygons.  This
script writes a set of small SVGs that isolate each thing the stroker has to
get right, so a change to it can be judged on more than five stroke-heavy
corpus files.

    python3 tests/gen_strokes.py            # write the SVGs
    python3 tests/gen_strokes.py --compare BIN_OLD BIN_NEW

`--compare` renders every probe with two microsvg binaries and with resvg, at
natural size and at --width 800, and prints exact%/within8% for each.
"""

import argparse
import math
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "tests" / "out" / "strokes"
DEFAULT_BIN = REPO / ".lake" / "build" / "bin" / "microsvg"

W = H = 200
JOINS = ("miter", "round", "bevel")
CAPS = ("butt", "round", "square")


def svg(body, w=W, h=H):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">\n'
        '  <rect width="%d" height="%d" fill="#ffffff"/>\n'
        "%s\n</svg>\n" % (w, h, w, h, body)
    )


def path(d, width=12, join="miter", cap="butt", miter=4, fill="none",
         color="#1d3557", extra=""):
    return (
        '  <path d="%s" fill="%s" stroke="%s" stroke-width="%s"'
        ' stroke-linejoin="%s" stroke-linecap="%s" stroke-miterlimit="%s"%s/>'
        % (d, fill, color, width, join, cap, miter, extra)
    )


# --------------------------------------------------------------------------
# the probes
# --------------------------------------------------------------------------


def zigzag(angle_deg, n=4, span=38.0, y0=60.0):
    """A zigzag whose interior angle at every vertex is `angle_deg`.

    Each leg turns by 180 - angle, alternating sign, so a small angle is a
    sharp spike (the miter-limit case) and a large one is a gentle bend.
    """
    turn = math.radians(180.0 - angle_deg)
    pts = [(20.0, y0)]
    heading = 0.0
    for i in range(n):
        heading += turn if i % 2 == 0 else -turn
        # keep the run going left to right: mirror the heading into (-90, 90)
        hx, hy = math.cos(heading), math.sin(heading)
        if hx < 0:
            hx = -hx
        x, y = pts[-1]
        pts.append((x + span * hx, y + span * hy))
    return "M " + " L ".join("%.2f %.2f" % p for p in pts)


def spiral(turns=3.2, r0=6.0, r1=72.0, steps=220, cx=100.0, cy=100.0):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        a = t * turns * 2 * math.pi
        r = r0 + (r1 - r0) * t
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return "M " + " L ".join("%.2f %.2f" % p for p in pts)


def circle_path(cx=100.0, cy=100.0, r=60.0, steps=64):
    pts = [
        (cx + r * math.cos(2 * math.pi * i / steps),
         cy + r * math.sin(2 * math.pi * i / steps))
        for i in range(steps)
    ]
    return "M " + " L ".join("%.2f %.2f" % p for p in pts) + " Z"


def tiny_segments(n=40, step=1.2, y=100.0, amp=3.0):
    """Segments much shorter than the stroke width, with direction changes."""
    pts = [(30.0 + i * step, y + (amp if i % 2 else -amp)) for i in range(n)]
    return "M " + " L ".join("%.2f %.2f" % p for p in pts)


def build():
    cases = {}

    # 1. sharp zigzags: every angle x every join x every miter limit
    for ang in (10, 45, 120):
        for join in JOINS:
            for ml in (1, 4, 20):
                cases["zig_%03d_%s_ml%02d" % (ang, join, ml)] = svg(
                    path(zigzag(ang), width=14, join=join, cap="butt", miter=ml)
                )

    # 2. closed subpaths: the ring hole must stay clear
    cases["closed_triangle"] = svg(
        path("M 40 170 L 100 30 L 160 170 Z", width=18, join="miter")
    )
    cases["closed_triangle_round"] = svg(
        path("M 40 170 L 100 30 L 160 170 Z", width=18, join="round")
    )
    cases["closed_triangle_bevel"] = svg(
        path("M 40 170 L 100 30 L 160 170 Z", width=18, join="bevel")
    )
    cases["closed_rect"] = svg(
        path("M 45 55 L 155 55 L 155 145 L 45 145 Z", width=16, join="miter")
    )
    cases["closed_rect_thick"] = svg(
        # half width larger than half the rect: the hole closes up entirely
        path("M 80 90 L 120 90 L 120 110 L 80 110 Z", width=40, join="miter")
    )
    cases["closed_circle"] = svg(path(circle_path(), width=14, join="round"))
    cases["closed_circle_miter"] = svg(path(circle_path(), width=14, join="miter"))
    cases["closed_filled_ring"] = svg(
        path(circle_path(r=55), width=14, join="round", fill="#ffbe0b")
    )

    # 3. a self-crossing polyline (winding 2 in the overlap)
    cases["self_cross"] = svg(
        path("M 30 30 L 170 170 L 30 170 L 170 30", width=16, join="miter")
    )
    cases["self_cross_round"] = svg(
        path("M 30 30 L 170 170 L 30 170 L 170 30", width=16, join="round", cap="round")
    )
    cases["self_cross_closed"] = svg(
        path("M 30 30 L 170 170 L 30 170 L 170 30 Z", width=16, join="miter")
    )

    # 4. segments shorter than the stroke width
    for cap in CAPS:
        cases["tiny_segs_%s" % cap] = svg(
            path(tiny_segments(), width=20, join="round", cap=cap)
        )
    cases["tiny_segs_miter"] = svg(
        path(tiny_segments(), width=20, join="miter", cap="butt", miter=20)
    )

    # 5. a thick stroke on a tight spiral
    cases["spiral_thick_round"] = svg(path(spiral(), width=16, join="round", cap="round"))
    cases["spiral_thick_miter"] = svg(path(spiral(), width=16, join="miter", cap="butt"))
    cases["spiral_thick_bevel"] = svg(path(spiral(), width=16, join="bevel", cap="butt"))
    cases["spiral_thin"] = svg(path(spiral(), width=3, join="round", cap="round"))

    # 6. open paths with each cap
    for cap in CAPS:
        cases["caps_%s" % cap] = svg(
            path("M 30 50 L 170 50 M 30 100 L 120 140 M 30 160 L 170 155",
                 width=18, cap=cap)
        )

    # 7. a single-point subpath with each cap
    for cap in CAPS:
        cases["dot_%s" % cap] = svg(
            path("M 60 100 L 60 100 M 100 100 Z M 140 100 L 140 100",
                 width=24, cap=cap)
        )

    # 8. a path that folds back on itself by 180 degrees
    for cap in CAPS:
        cases["fold_%s" % cap] = svg(
            path("M 40 100 L 160 100 L 60 100", width=20, join="miter", cap=cap)
        )
    cases["fold_round_join"] = svg(
        path("M 40 100 L 160 100 L 60 100", width=20, join="round", cap="butt")
    )
    cases["fold_closed"] = svg(path("M 40 100 L 160 100 Z", width=20, join="miter"))

    # 9. a couple of mixed shapes that stress joins and caps together
    cases["star_closed"] = svg(
        path("M 100 20 L 40 180 L 190 70 L 10 70 L 160 180 Z", width=9, join="miter")
    )
    cases["star_closed_ml1"] = svg(
        path("M 100 20 L 40 180 L 190 70 L 10 70 L 160 180 Z", width=9,
             join="miter", miter=1)
    )
    cases["comb"] = svg(
        path(" ".join("M %d 40 L %d 160" % (20 + 12 * i, 20 + 12 * i) for i in range(14)),
             width=7, cap="round")
    )
    return cases


# --------------------------------------------------------------------------
# comparison
# --------------------------------------------------------------------------


def render(binary, svg_path, out, width=None):
    cmd = [str(binary), str(svg_path), str(out)]
    if width:
        cmd += ["--width", str(width)]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    return r.returncode == 0


def render_resvg(svg_path, out, width=None):
    cmd = ["resvg", str(svg_path), str(out)]
    if width:
        cmd += ["--width", str(width)]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    return r.returncode == 0


def compare(old_bin, new_bin, widths=(None, 800), verbose=True):
    import numpy as np
    from PIL import Image

    def load(p):
        with Image.open(p) as im:
            return np.asarray(im.convert("RGBA"), dtype=np.int32)

    names = sorted(p.stem for p in OUT_DIR.glob("*.svg"))
    rows = []
    for width in widths:
        tag = "nat" if width is None else str(width)
        for name in names:
            src = OUT_DIR / (name + ".svg")
            po = OUT_DIR / ("%s_%s_old.png" % (name, tag))
            pn = OUT_DIR / ("%s_%s_new.png" % (name, tag))
            pr = OUT_DIR / ("%s_%s_ref.png" % (name, tag))
            if not (render(old_bin, src, po, width)
                    and render(new_bin, src, pn, width)
                    and render_resvg(src, pr, width)):
                print("render failed: %s %s" % (name, tag), file=sys.stderr)
                continue
            ref, old, new = load(pr), load(po), load(pn)
            do = np.abs(ref - old).max(axis=2)
            dn = np.abs(ref - new).max(axis=2)
            n = float(do.size)
            rows.append({
                "name": name, "tag": tag,
                "exact_old": (do == 0).sum() / n * 100,
                "exact_new": (dn == 0).sum() / n * 100,
                "w8_old": (do <= 8).sum() / n * 100,
                "w8_new": (dn <= 8).sum() / n * 100,
                "max_old": int(do.max()), "max_new": int(dn.max()),
            })
    if verbose:
        print("%-28s %4s  %8s %8s   %8s %8s  %5s %5s  %s"
              % ("probe", "size", "exact-", "exact+", "w8-", "w8+",
                 "max-", "max+", ""))
        for r in rows:
            d = r["w8_new"] - r["w8_old"]
            flag = "WORSE" if d < -1e-9 else ("better" if d > 1e-9 else "")
            print("%-28s %4s  %8.3f %8.3f   %8.3f %8.3f  %5d %5d  %s"
                  % (r["name"], r["tag"], r["exact_old"], r["exact_new"],
                     r["w8_old"], r["w8_new"], r["max_old"], r["max_new"], flag))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compare", nargs=2, metavar=("OLD_BIN", "NEW_BIN"),
                    help="render every probe with both binaries and score vs resvg")
    ap.add_argument("--widths", default="nat,800",
                    help="comma separated, 'nat' for the SVG's own size")
    args = ap.parse_args()

    if OUT_DIR.exists():
        shutil.rmtree(OUT_DIR)
    OUT_DIR.mkdir(parents=True)
    cases = build()
    for name, text in cases.items():
        (OUT_DIR / (name + ".svg")).write_text(text)
    print("wrote %d probe SVGs to %s" % (len(cases), OUT_DIR))

    if args.compare:
        widths = tuple(None if w == "nat" else int(w)
                       for w in args.widths.split(","))
        rows = compare(args.compare[0], args.compare[1], widths)
        worse = [r for r in rows if r["w8_new"] < r["w8_old"] - 1e-9]
        better = [r for r in rows if r["w8_new"] > r["w8_old"] + 1e-9]
        print("\n%d cases x %d sizes: %d better on within8, %d worse, %d unchanged"
              % (len(rows) // len(widths), len(widths), len(better), len(worse),
                 len(rows) - len(better) - len(worse)))
        print("mean within8 %.4f -> %.4f" % (
            sum(r["w8_old"] for r in rows) / len(rows),
            sum(r["w8_new"] for r in rows) / len(rows)))


if __name__ == "__main__":
    main()
