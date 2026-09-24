#!/usr/bin/env python3
"""Oracle comparison harness: render every tests/svg/*.svg with both lean-svg and
resvg, then score our output against the reference pixel by pixel.

Outputs per test go to tests/out/:
    <name>_ref.png   reference render (resvg)
    <name>_ours.png  our render (lean-svg)
    <name>_cmp.png   reference | ours | diff, side by side
plus results.json and report.html for the whole run.
"""

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SVG_DIR = REPO / "tests" / "svg"
OUT_DIR = REPO / "tests" / "out"
DEFAULT_BIN = REPO / ".lake" / "build" / "bin" / "lean-svg"
RESVG_FONTS_DIR = REPO / "tests" / "corpora" / "resvg-test-suite" / "fonts"

RENDER_TIMEOUT = 60  # seconds, per subprocess
BAR_WIDTH = 4  # gray separator between composite panels
BAR_GRAY = 128
DIFF_GAIN = 4  # diff image red intensity = d * DIFF_GAIN, clamped


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------


def resvg_font_args(no_font_pin=False, suite_generics=False):
    """Extra `resvg` flags that pin the oracle to the test suite's own bundled
    fonts, so text renders against known font files instead of whatever the
    system happens to have installed. Returns [] (no pinning) when disabled
    or when the fonts directory is missing (with a warning on stderr).

    T110: with `suite_generics` (`run_corpora.py`), the CSS generic families
    also map to suite fonts exactly as resvg's own test harness does (`crates/resvg/tests/integration/main.rs`, v0.48.1),
    which is the setup the suite's `resvg=1` verdicts were made with. The
    CLI's defaults (Times New Roman, Arial, ...) are not in the suite's font
    dir, so without these flags `serif`, an unmatched list and an unparsable
    `font-family` (which usvg replaces by Times New Roman, then `serif`)
    draw no text at all. The local tests keep the CLI defaults: they are
    not the suite, and their generic-family files target Chromium."""
    if no_font_pin:
        return []
    if not RESVG_FONTS_DIR.is_dir():
        print(
            "warning: resvg fonts dir not found at %s, not pinning fonts"
            % RESVG_FONTS_DIR,
            file=sys.stderr,
        )
        return []
    pin = ["--skip-system-fonts", "--use-fonts-dir", str(RESVG_FONTS_DIR)]
    return pin + (RESVG_GENERIC_ARGS if suite_generics else [])


# `--<generic>-family` flags matching resvg's integration-test fontdb setup.
RESVG_GENERIC_ARGS = [
    "--serif-family", "Noto Serif",
    "--sans-serif-family", "Noto Sans",
    "--cursive-family", "Yellowtail",
    "--fantasy-family", "Sedgwick Ave Display",
    "--monospace-family", "Noto Mono",
]


def run_renderer(cmd):
    """Run a renderer subprocess. Returns (rc, elapsed_ms, stderr, timed_out)."""
    start = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=RENDER_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        elapsed = (time.perf_counter() - start) * 1000.0
        return None, elapsed, "timed out after %ds" % RENDER_TIMEOUT, True
    elapsed = (time.perf_counter() - start) * 1000.0
    stderr = proc.stderr.decode("utf-8", "replace").strip()
    return proc.returncode, elapsed, stderr, False


def load_rgba(path):
    """Load a PNG as an (h, w, 4) int16 array, or None if it cannot be read."""
    try:
        with Image.open(path) as img:
            return np.asarray(img.convert("RGBA"), dtype=np.int16)
    except Exception:
        return None


# --------------------------------------------------------------------------
# metrics
# --------------------------------------------------------------------------


def compare(ref, ours, tol):
    """Per-pixel max absolute channel difference, summarised."""
    delta = np.abs(ref.astype(np.int32) - ours.astype(np.int32))
    d = delta.max(axis=2)  # worst channel per pixel
    total = float(d.size)
    return {
        "exact": float((d == 0).sum()) / total,
        "within": float((d <= tol).sum()) / total,
        "within32": float((d <= 32).sum()) / total,
        "mean_abs": float(delta.mean()),
        "max_d": int(d.max()),
    }, d


# --------------------------------------------------------------------------
# composite image
# --------------------------------------------------------------------------


def over_white(img):
    """Composite an RGBA array over a white background -> (h, w, 3) uint8."""
    rgb = img[:, :, :3].astype(np.float32)
    alpha = img[:, :, 3:4].astype(np.float32) / 255.0
    flat = rgb * alpha + 255.0 * (1.0 - alpha)
    return np.clip(flat, 0, 255).astype(np.uint8)


def diff_panel(d):
    """White image tinted red where the images differ."""
    v = np.clip(d.astype(np.int32) * DIFF_GAIN, 0, 255).astype(np.uint8)
    panel = np.full(d.shape + (3,), 255, dtype=np.uint8)
    panel[:, :, 1] = 255 - v
    panel[:, :, 2] = 255 - v
    return panel


def pad_to_height(panel, height):
    """Pad a panel with white at the bottom so all panels line up."""
    if panel.shape[0] >= height:
        return panel
    pad = np.full((height - panel.shape[0],) + panel.shape[1:], 255, dtype=np.uint8)
    return np.vstack([panel, pad])


def write_composite(path, panels):
    """Write panels side by side, separated by gray bars."""
    height = max(p.shape[0] for p in panels)
    bar = np.full((height, BAR_WIDTH, 3), BAR_GRAY, dtype=np.uint8)
    pieces = []
    for i, panel in enumerate(panels):
        if i:
            pieces.append(bar)
        pieces.append(pad_to_height(panel, height))
    Image.fromarray(np.hstack(pieces), "RGB").save(path)


# --------------------------------------------------------------------------
# one test
# --------------------------------------------------------------------------


def run_one(svg, binary, tol, threshold, resvg_args=None):
    name = svg.stem
    result = {
        "name": name,
        "svg": str(svg.relative_to(REPO)),
        "ref_png": name + "_ref.png",
        "ours_png": name + "_ours.png",
        "cmp_png": name + "_cmp.png",
        "size": None,
        "exact": None,
        "within": None,
        "within32": None,
        "mean_abs": None,
        "max_d": None,
        "ms_ours": None,
        "ms_resvg": None,
        "passed": False,
        "error": None,
    }

    ref_png = OUT_DIR / result["ref_png"]
    ours_png = OUT_DIR / result["ours_png"]
    # T98: lean-svg also refuses to run if `<out>.warnings.txt` exists.
    ours_warn = OUT_DIR / (result["ours_png"] + ".warnings.txt")
    for stale in (ref_png, ours_png, OUT_DIR / result["cmp_png"], ours_warn):
        stale.unlink(missing_ok=True)

    rc_ref, ms_ref, err_ref, to_ref = run_renderer(
        ["resvg"] + (resvg_args or []) + [str(svg), str(ref_png)]
    )
    rc_ours, ms_ours, err_ours, to_ours = run_renderer(
        [str(binary), str(svg), str(ours_png)]
    )
    result["ms_resvg"] = ms_ref
    result["ms_ours"] = ms_ours

    if to_ref or rc_ref != 0:
        result["error"] = "resvg failed: " + (err_ref or "rc=%s" % rc_ref)
        return result
    if to_ours or rc_ours not in (0, 2):  # T98b: 2 = PNG written, with warnings
        result["error"] = "lean-svg failed: " + (err_ours or "rc=%s" % rc_ours)
        return result

    ref = load_rgba(ref_png)
    ours = load_rgba(ours_png)
    if ref is None:
        result["error"] = "reference PNG could not be read"
        return result
    if ours is None:
        result["error"] = "our PNG could not be read"
        return result

    ref_size = (ref.shape[1], ref.shape[0])
    ours_size = (ours.shape[1], ours.shape[0])
    result["size"] = "%dx%d" % ref_size

    if ref_size != ours_size:
        result["size"] = "%dx%d vs %dx%d" % (ref_size + ours_size)
        result["error"] = "size mismatch: reference %dx%d, ours %dx%d" % (
            ref_size + ours_size
        )
        write_composite(
            OUT_DIR / result["cmp_png"], [over_white(ref), over_white(ours)]
        )
        return result

    metrics, d = compare(ref, ours, tol)
    result.update(metrics)
    result["passed"] = metrics["within"] >= threshold
    write_composite(
        OUT_DIR / result["cmp_png"],
        [over_white(ref), over_white(ours), diff_panel(d)],
    )
    return result


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

COLUMNS = [
    ("name", 22, "<"),
    ("size", 13, ">"),
    ("exact%", 8, ">"),
    ("within%", 8, ">"),
    ("within32%", 10, ">"),
    ("mean_abs", 9, ">"),
    ("max_d", 6, ">"),
    ("ms ours", 9, ">"),
    ("ms resvg", 9, ">"),
    ("result", 6, "<"),
]


def fmt_row(values):
    return "  ".join(
        "{:{align}{width}}".format(str(v), align=col[2], width=col[1])
        for v, col in zip(values, COLUMNS)
    )


def pct(x):
    return "-" if x is None else "%.3f" % (x * 100.0)


def num(x, spec="%.3f"):
    return "-" if x is None else spec % x


def print_table(results):
    header = fmt_row([c[0] for c in COLUMNS])
    print(header)
    print("-" * len(header))
    for r in results:
        print(
            fmt_row(
                [
                    r["name"],
                    r["size"] or "-",
                    pct(r["exact"]),
                    pct(r["within"]),
                    pct(r["within32"]),
                    num(r["mean_abs"]),
                    "-" if r["max_d"] is None else r["max_d"],
                    num(r["ms_ours"], "%.1f"),
                    num(r["ms_resvg"], "%.1f"),
                    "PASS" if r["passed"] else "FAIL",
                ]
            )
        )
        if r["error"]:
            print("      ! %s" % r["error"])


HTML_HEAD = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>lean-svg oracle report</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; color: #222; }
  h1 { font-size: 1.4rem; }
  .meta { color: #666; font-size: .9rem; margin-bottom: 1.5rem; }
  .test { border: 1px solid #ddd; border-radius: 6px; padding: 1rem;
          margin-bottom: 1.5rem; background: #fafafa; }
  .test.fail { border-color: #c0392b; background: #fdecea; }
  .test h2 { font-size: 1.05rem; margin: 0 0 .25rem; }
  .badge { font-size: .75rem; padding: .1rem .5rem; border-radius: 3px;
           color: #fff; background: #2d8a4e; vertical-align: middle; }
  .fail .badge { background: #c0392b; }
  .metrics { font-family: ui-monospace, Menlo, monospace; font-size: .85rem;
             color: #444; margin: .5rem 0; }
  .err { color: #c0392b; font-weight: 600; margin: .5rem 0; }
  .imgs { display: flex; gap: .5rem; flex-wrap: wrap; align-items: flex-start; }
  .imgs figure { margin: 0; }
  .imgs figcaption { font-size: .75rem; color: #666; text-align: center; }
  .imgs img { background: #fff; border: 1px solid #ccc; max-width: 320px; }
</style>
</head>
<body>
"""


def esc(text):
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def write_report(path, results, config, summary):
    parts = [HTML_HEAD, "<h1>lean-svg oracle report</h1>\n"]
    parts.append(
        '<div class="meta">%s &middot; tol %d &middot; threshold %.3f &middot; %s</div>\n'
        % (
            esc(summary["generated"]),
            config["tol"],
            config["threshold"],
            esc("%d/%d passed" % (summary["passed"], summary["total"])),
        )
    )
    for r in results:
        cls = "test" if r["passed"] else "test fail"
        parts.append('<div class="%s">\n' % cls)
        parts.append(
            '<h2>%s <span class="badge">%s</span></h2>\n'
            % (esc(r["name"]), "PASS" if r["passed"] else "FAIL")
        )
        if r["error"]:
            parts.append('<div class="err">%s</div>\n' % esc(r["error"]))
        parts.append(
            '<div class="metrics">size %s &middot; exact %s%% &middot; within %s%% '
            "&middot; within32 %s%% &middot; mean_abs %s &middot; max_d %s "
            "&middot; ours %s ms &middot; resvg %s ms</div>\n"
            % (
                esc(r["size"] or "-"),
                pct(r["exact"]),
                pct(r["within"]),
                pct(r["within32"]),
                num(r["mean_abs"]),
                "-" if r["max_d"] is None else r["max_d"],
                num(r["ms_ours"], "%.1f"),
                num(r["ms_resvg"], "%.1f"),
            )
        )
        parts.append('<div class="imgs">\n')
        for key, caption in (
            ("ref_png", "reference (resvg)"),
            ("ours_png", "ours (lean-svg)"),
            ("cmp_png", "ref | ours | diff"),
        ):
            if (OUT_DIR / r[key]).exists():
                parts.append(
                    '<figure><img src="%s" alt="%s"><figcaption>%s</figcaption></figure>\n'
                    % (esc(r[key]), esc(caption), esc(caption))
                )
        parts.append("</div>\n</div>\n")
    parts.append("</body>\n</html>\n")
    path.write_text("".join(parts), encoding="utf-8")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filter", help="only run tests whose name contains SUBSTR")
    parser.add_argument(
        "--tol", type=int, default=8, help="per-pixel tolerance for 'within' (default 8)"
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.99,
        help="minimum 'within' fraction to pass (default 0.99)",
    )
    parser.add_argument(
        "--bin", default=str(DEFAULT_BIN), help="path to the lean-svg binary"
    )
    parser.add_argument(
        "--keep-going",
        action="store_true",
        default=True,
        help="run every test even after a failure (always on)",
    )
    parser.add_argument(
        "--no-font-pin",
        action="store_true",
        help="do not pin the resvg oracle's fonts to the test suite's bundled "
             "set (falls back to whatever fonts resvg finds on the system)",
    )
    args = parser.parse_args()

    binary = Path(args.bin).resolve()
    if not binary.is_file():
        print("lean-svg binary not found at %s" % binary, file=sys.stderr)
        print("build it first:  lake build", file=sys.stderr)
        return 2
    if shutil.which("resvg") is None:
        print("resvg not found on PATH (needed as the oracle renderer)", file=sys.stderr)
        return 2

    svgs = sorted(SVG_DIR.glob("*.svg"))
    if args.filter:
        svgs = [s for s in svgs if args.filter in s.name]
    if not svgs:
        print("no SVGs to test in %s" % SVG_DIR, file=sys.stderr)
        return 2

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    resvg_args = resvg_font_args(args.no_font_pin)
    results = [
        run_one(svg, binary, args.tol, args.threshold, resvg_args) for svg in svgs
    ]
    print_table(results)

    passed = sum(1 for r in results if r["passed"])
    errors = sum(1 for r in results if r["error"])
    total = len(results)
    print()
    print(
        "%d/%d passed, %d failed, %d render errors  (tol=%d, threshold=%.3f)"
        % (passed, total, total - passed, errors, args.tol, args.threshold)
    )

    summary = {
        "total": total,
        "passed": passed,
        "failed": total - passed,
        "errors": errors,
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    config = {
        "tol": args.tol,
        "threshold": args.threshold,
        "bin": str(binary),
        "filter": args.filter,
    }
    (OUT_DIR / "results.json").write_text(
        json.dumps(
            {"config": config, "summary": summary, "tests": results}, indent=2
        )
        + "\n",
        encoding="utf-8",
    )
    write_report(OUT_DIR / "report.html", results, config, summary)
    print("wrote %s and %s" % (OUT_DIR / "results.json", OUT_DIR / "report.html"))

    return 1 if (passed != total or errors) else 0


if __name__ == "__main__":
    sys.exit(main())
