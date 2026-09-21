#!/usr/bin/env python3
"""Oracle check for `hsl()`/`hsla()`/`rgba()` colour notation (T34).

Generates random colour strings across the forms `parseHslFunc`/`parseRgbFunc`
in LeanSvg/Svg.lean support -- comma and CSS4 space-separated argument
lists, the `deg`/`grad`/`turn` hue units, percentage or raw-number
saturation/lightness, percentage or fractional alpha, and out-of-range hue/
saturation/lightness/alpha meant to exercise `hslToRgb`'s wraparound and
`hslFracOf`/`alphaOf`'s clamping -- renders each as a single solid `<rect>`
at 4x4 px with both lean-svg and resvg, and compares the centre pixel for
exact equality.

    python3 tests/check_hsl.py [N] [--seed SEED] [--bin PATH]

Exits 0 and prints "OK: N/N exact" on a clean run, otherwise lists every
mismatch (string, our RGBA, resvg's RGBA) and exits 1.
"""

import argparse
import random
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
DEFAULT_BIN = REPO / ".lake" / "build" / "bin" / "lean-svg"

RENDER_TIMEOUT = 10


def rand_pct(rng, lo=0, hi=100, decimals=(0, 1, 2)):
    d = rng.choice(decimals)
    v = rng.uniform(lo, hi)
    return round(v, d)


def rand_hue(rng):
    """A hue number, occasionally out of [0, 360) or negative, with an
    optional angle unit (case-sensitive lowercase, matching svgtypes)."""
    h = rng.choice(
        [
            rng.uniform(0, 360),
            rng.uniform(-720, 1080),
            float(rng.randint(0, 360)),
            float(rng.randint(-1000, 1000)),
        ]
    )
    h = round(h, rng.choice([0, 1, 2]))
    unit = rng.choice(["", "", "", "deg", "deg", "grad", "turn"])
    return fmt_num(h) + unit


def fmt_num(x):
    """Render a float without a trailing `.0` for whole numbers (either
    form is valid CSS, this just keeps the generated strings varied)."""
    if float(x).is_integer() and random.random() < 0.5:
        return str(int(x))
    return repr(float(x))


def rand_sl(rng, as_percent=True):
    v = rand_pct(rng, -20, 120)
    if as_percent:
        return fmt_num(v) + "%"
    return fmt_num(v / 100.0)


def rand_alpha(rng):
    kind = rng.choice(["frac", "frac", "percent"])
    if kind == "percent":
        return fmt_num(rand_pct(rng, -20, 120)) + "%"
    return fmt_num(round(rng.uniform(-0.3, 1.3), rng.choice([0, 1, 2, 3])))


def rand_rgb_component(rng):
    kind = rng.choice(["int", "int", "float", "percent"])
    if kind == "percent":
        return fmt_num(rand_pct(rng, -10, 110)) + "%"
    if kind == "float":
        return fmt_num(round(rng.uniform(-10, 265), rng.choice([1, 2])))
    return str(rng.randint(-10, 265))


def gen_color(rng):
    """One random colour string, tagged with the form used (for reporting)."""
    form = rng.choice(
        [
            "hsl_comma",
            "hsl_space",
            "hsla_comma",
            "hsla_space",
            "hsl_raw_sl",
            "hsl_alpha_no_comma",
            "rgba_comma",
            "rgba_percent_alpha",
            "rgb_with_alpha",
        ]
    )
    h = rand_hue(rng)
    s = rand_sl(rng)
    l = rand_sl(rng)
    a = rand_alpha(rng)
    if form == "hsl_comma":
        return "hsl(%s, %s, %s)" % (h, s, l)
    if form == "hsl_space":
        return "hsl(%s %s %s)" % (h, s, l)
    if form == "hsla_comma":
        return "hsla(%s, %s, %s, %s)" % (h, s, l, a)
    if form == "hsla_space":
        return "hsla(%s %s %s %s)" % (h, s, l, a)
    if form == "hsl_raw_sl":
        return "hsl(%s, %s, %s)" % (h, rand_sl(rng, as_percent=False), rand_sl(rng, as_percent=False))
    if form == "hsl_alpha_no_comma":
        return "hsl(%s, %s, %s, %s)" % (h, s, l, a)
    r, g, b = (rand_rgb_component(rng) for _ in range(3))
    if form == "rgba_comma":
        return "rgba(%s, %s, %s, %s)" % (r, g, b, a)
    if form == "rgba_percent_alpha":
        return "rgba(%s, %s, %s, %s)" % (r, g, b, fmt_num(rand_pct(rng, 0, 100)) + "%")
    return "rgb(%s, %s, %s, %s)" % (r, g, b, a)


def render_center_pixel(binary_cmd, svg_path, png_path):
    proc = subprocess.run(binary_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=RENDER_TIMEOUT)
    if proc.returncode != 0:
        return None, proc.stderr.decode("utf-8", "replace").strip()
    with Image.open(png_path) as img:
        rgba = img.convert("RGBA")
        return rgba.getpixel((2, 2)), None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("n", type=int, nargs="?", default=2000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--bin", type=Path, default=DEFAULT_BIN)
    args = parser.parse_args()

    if not args.bin.exists():
        sys.exit("binary not found: %s (run `lake build` first)" % args.bin)

    import shutil

    if shutil.which("resvg") is None:
        sys.exit("resvg not found on PATH (needed as the oracle)")

    rng = random.Random(args.seed)
    mismatches = []
    errors = []

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        svg_path = tmp / "c.svg"
        ours_png = tmp / "ours.png"
        ref_png = tmp / "ref.png"
        for i in range(args.n):
            color = gen_color(rng)
            svg_path.write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4">'
                '<rect width="4" height="4" fill="%s"/></svg>' % color
            )
            try:
                ours, err = render_center_pixel([str(args.bin), str(svg_path), str(ours_png)], svg_path, ours_png)
                if ours is None:
                    errors.append((color, "lean-svg: " + (err or "?")))
                    continue
                ref, err = render_center_pixel(["resvg", str(svg_path), str(ref_png)], svg_path, ref_png)
                if ref is None:
                    errors.append((color, "resvg: " + (err or "?")))
                    continue
            except subprocess.TimeoutExpired:
                errors.append((color, "timed out"))
                continue
            if ours != ref:
                mismatches.append((color, ours, ref))

    total = args.n
    bad = len(mismatches) + len(errors)
    print("OK: %d/%d exact" % (total - bad, total) if bad == 0 else "FAIL: %d/%d exact" % (total - bad, total))
    if errors:
        print("%d render error(s):" % len(errors))
        for color, msg in errors[:20]:
            print("  %-50s %s" % (color, msg))
    if mismatches:
        print("%d mismatch(es):" % len(mismatches))
        for color, ours, ref in mismatches[:40]:
            print("  %-50s ours=%s resvg=%s" % (color, ours, ref))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
