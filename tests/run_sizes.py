#!/usr/bin/env python3
"""Fidelity and speed across render sizes.

For every tests/svg/*.svg and every requested width, render with both lean-svg
and resvg, score our output against the reference, and time both renderers
(median of N runs, wall clock).

Two questions this answers with numbers:
  1. does agreement with resvg improve at larger sizes (edge pixels become a
     smaller fraction of the image)?
  2. how does our render time scale with output size, in absolute ms and in
     ms per megapixel, compared with resvg?

Process-start cost is measured once by rendering a trivial 1x1 SVG; the "net"
time is the median minus that baseline, and ms/Mpx is computed from net.

Outputs:
    tests/out/sizes.csv   one row per (file, width) cell
    tests/out/sizes.md    the same tables in Markdown

Metric and rendering helpers are imported from run_tests.py so the numbers are
comparable with the oracle harness.
"""

import argparse
import csv
import shutil
import statistics
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from run_tests import (  # noqa: E402  (path set up above)
    DEFAULT_BIN,
    OUT_DIR,
    RENDER_TIMEOUT,
    SVG_DIR,
    compare,
    load_rgba,
    run_renderer,
)

DEFAULT_WIDTHS = [100, 200, 400, 800, 1600, 3200]
TOL = 8

# Per the task: at width 3200 these two files may be skipped, but only if a
# single run actually exceeds the RENDER_TIMEOUT wall.
SKIPPABLE = {("16_stress_2000", 3200), ("18_rose_lissajous", 3200)}

TINY_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'


# --------------------------------------------------------------------------
# timing
# --------------------------------------------------------------------------


def time_runs(cmd, runs):
    """Run `cmd` `runs` times. Returns (median_ms, rc, stderr, timed_out).

    Stops early on a timeout or a non-zero exit so a broken cell costs one run.
    """
    samples = []
    rc, err = None, ""
    for _ in range(runs):
        rc, ms, err, timed_out = run_renderer(cmd)
        if timed_out:
            return None, None, err, True
        samples.append(ms)
        if rc != 0:
            return statistics.median(samples), rc, err, False
    return statistics.median(samples), rc, err, False


def measure_baseline(binary, tmp, runs):
    """Median wall time of both renderers on a trivial 1x1 SVG (process start).

    One warm-up run per renderer is discarded so the first page-in of the
    binary does not inflate the baseline that every net time is measured
    against, and at least 5 samples are taken since this is subtracted
    everywhere.
    """
    svg = tmp / "baseline.svg"
    svg.write_text(TINY_SVG, encoding="utf-8")
    n = max(runs, 5)
    cmds = {
        "ours": [str(binary), str(svg), str(tmp / "b_ours.png")],
        "resvg": ["resvg", str(svg), str(tmp / "b_ref.png")],
    }
    out = {}
    for key, cmd in cmds.items():
        run_renderer(cmd)  # warm-up, discarded
        ms, _, _, _ = time_runs(cmd, n)
        out[key] = ms or 0.0
    return out["ours"], out["resvg"]


# --------------------------------------------------------------------------
# one cell
# --------------------------------------------------------------------------


def new_cell(name, width):
    return {
        "file": name,
        "width": width,
        "size": None,
        "mpx": None,
        "exact": None,
        "within": None,
        "within32": None,
        "mean_abs": None,
        "max_d": None,
        "ours_ms": None,
        "ours_net_ms": None,
        "resvg_ms": None,
        "resvg_net_ms": None,
        "ratio": None,
        "ratio_net": None,
        "ours_ms_per_mpx": None,
        "resvg_ms_per_mpx": None,
        "status": "ok",
        "note": "",
    }


def run_cell(svg, width, binary, tmp, runs, base_ours, base_resvg):
    cell = new_cell(svg.stem, width)
    ours_png = tmp / ("%s_%d_ours.png" % (svg.stem, width))
    ref_png = tmp / ("%s_%d_ref.png" % (svg.stem, width))

    ms_ours, rc_ours, err_ours, to_ours = time_runs(
        [str(binary), str(svg), str(ours_png), "--width", str(width)], runs
    )
    if to_ours:
        if (svg.stem, width) in SKIPPABLE:
            cell["status"] = "skipped"
            cell["note"] = "a single run exceeded %d s" % RENDER_TIMEOUT
        else:
            cell["status"] = "error"
            cell["note"] = "lean-svg timed out after %d s" % RENDER_TIMEOUT
        return cell
    cell["ours_ms"] = ms_ours
    # Not clamped: at small widths our render cost is below the process-start
    # baseline, and a small negative net says exactly that.
    cell["ours_net_ms"] = ms_ours - base_ours
    if rc_ours != 0:
        cell["status"] = "error"
        cell["note"] = "lean-svg failed: " + (err_ours or "rc=%s" % rc_ours)
        return cell

    ms_resvg, rc_resvg, err_resvg, to_resvg = time_runs(
        ["resvg", "-w", str(width), str(svg), str(ref_png)], runs
    )
    if to_resvg:
        cell["status"] = "error"
        cell["note"] = "resvg timed out after %d s" % RENDER_TIMEOUT
        return cell
    cell["resvg_ms"] = ms_resvg
    cell["resvg_net_ms"] = ms_resvg - base_resvg
    if rc_resvg != 0:
        cell["status"] = "error"
        cell["note"] = "resvg failed: " + (err_resvg or "rc=%s" % rc_resvg)
        return cell

    if ms_resvg > 0:
        cell["ratio"] = cell["ours_net_ms"] / ms_resvg
    if cell["resvg_net_ms"] > 0:
        cell["ratio_net"] = cell["ours_net_ms"] / cell["resvg_net_ms"]

    ours = load_rgba(ours_png)
    ref = load_rgba(ref_png)
    if ours is None or ref is None:
        cell["status"] = "error"
        cell["note"] = "PNG could not be read (%s)" % (
            "ours" if ours is None else "reference"
        )
        return cell

    ours_size = (ours.shape[1], ours.shape[0])
    ref_size = (ref.shape[1], ref.shape[0])
    mpx = ours_size[0] * ours_size[1] / 1e6
    cell["mpx"] = mpx
    if mpx > 0:
        cell["ours_ms_per_mpx"] = cell["ours_net_ms"] / mpx
        cell["resvg_ms_per_mpx"] = cell["resvg_ms"] / mpx

    if ours_size != ref_size:
        cell["size"] = "%dx%d vs %dx%d" % (ref_size + ours_size)
        cell["status"] = "size mismatch"
        cell["note"] = "reference %dx%d, ours %dx%d; metrics skipped" % (
            ref_size + ours_size
        )
        return cell

    cell["size"] = "%dx%d" % ours_size
    metrics, _ = compare(ref, ours, TOL)
    cell.update(metrics)

    ours_png.unlink(missing_ok=True)
    ref_png.unlink(missing_ok=True)
    return cell


# --------------------------------------------------------------------------
# formatting
# --------------------------------------------------------------------------

COLUMNS = [
    ("width", 6, ">", lambda c: c["width"]),
    ("size", 11, ">", lambda c: c["size"] or "-"),
    ("exact%", 8, ">", lambda c: pct(c["exact"])),
    ("within8%", 9, ">", lambda c: pct(c["within"])),
    ("within32%", 10, ">", lambda c: pct(c["within32"])),
    ("mean_abs", 9, ">", lambda c: num(c["mean_abs"])),
    ("ours net", 10, ">", lambda c: num(c["ours_net_ms"], "%.1f")),
    ("resvg ms", 9, ">", lambda c: num(c["resvg_ms"], "%.1f")),
    ("ratio", 7, ">", lambda c: num(c["ratio"], "%.1f")),
    ("ours/Mpx", 9, ">", lambda c: num(c["ours_ms_per_mpx"], "%.1f")),
]


def pct(x):
    return "-" if x is None else "%.3f" % (x * 100.0)


def num(x, spec="%.3f"):
    return "-" if x is None else spec % x


def fmt_row(values):
    return "  ".join(
        "{:{align}{width}}".format(str(v), align=col[2], width=col[1])
        for v, col in zip(values, COLUMNS)
    )


def print_file_table(name, cells):
    header = fmt_row([c[0] for c in COLUMNS])
    print()
    print(name)
    print(header)
    print("-" * len(header))
    for cell in cells:
        print(fmt_row([col[3](cell) for col in COLUMNS]))
        if cell["note"]:
            print("      ! %s: %s" % (cell["status"], cell["note"]))


def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |"]
    out.append("|" + "|".join(["---"] * len(headers)) + "|")
    for row in rows:
        out.append("| " + " | ".join(str(v) for v in row) + " |")
    return "\n".join(out)


def file_md(cells):
    rows = []
    for cell in cells:
        rows.append([col[3](cell) for col in COLUMNS])
        if cell["note"]:
            rows[-1][1] = "%s (%s)" % (rows[-1][1], cell["status"])
    return md_table([c[0] for c in COLUMNS], rows)


# --------------------------------------------------------------------------
# summary
# --------------------------------------------------------------------------


def mean(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


def summarise(cells, widths):
    """Per width: mean within8% and mean ratio over all files with metrics."""
    rows = []
    for w in widths:
        at_w = [c for c in cells if c["width"] == w]
        scored = [c for c in at_w if c["within"] is not None]
        timed = [c for c in at_w if c["ratio"] is not None]
        rows.append(
            {
                "width": w,
                "files": len(scored),
                "of": len(at_w),
                "within": mean([c["within"] for c in scored]),
                "exact": mean([c["exact"] for c in scored]),
                "ratio": mean([c["ratio"] for c in timed]),
                "ours_net_ms": mean([c["ours_net_ms"] for c in timed]),
                "resvg_ms": mean([c["resvg_ms"] for c in timed]),
                "ours_ms_per_mpx": mean([c["ours_ms_per_mpx"] for c in timed]),
            }
        )
    return rows


SUMMARY_COLUMNS = [
    ("width", lambda r: r["width"]),
    ("files", lambda r: "%d/%d" % (r["files"], r["of"])),
    ("mean exact%", lambda r: pct(r["exact"])),
    ("mean within8%", lambda r: pct(r["within"])),
    ("mean ours net ms", lambda r: num(r["ours_net_ms"], "%.1f")),
    ("mean resvg ms", lambda r: num(r["resvg_ms"], "%.1f")),
    ("mean ratio ours/resvg", lambda r: num(r["ratio"], "%.1f")),
    ("mean ours ms/Mpx", lambda r: num(r["ours_ms_per_mpx"], "%.1f")),
]


def print_summary(rows):
    widths = [max(len(h), 12) for h, _ in SUMMARY_COLUMNS]
    header = "  ".join(
        "{:>{w}}".format(h, w=wd) for (h, _), wd in zip(SUMMARY_COLUMNS, widths)
    )
    print()
    print("summary (mean over all files with metrics)")
    print(header)
    print("-" * len(header))
    for r in rows:
        print(
            "  ".join(
                "{:>{w}}".format(str(fn(r)), w=wd)
                for (_, fn), wd in zip(SUMMARY_COLUMNS, widths)
            )
        )


def summary_md(rows):
    return md_table(
        [h for h, _ in SUMMARY_COLUMNS],
        [[fn(r) for _, fn in SUMMARY_COLUMNS] for r in rows],
    )


# --------------------------------------------------------------------------
# output files
# --------------------------------------------------------------------------

CSV_FIELDS = [
    "file",
    "width",
    "size",
    "mpx",
    "status",
    "exact",
    "within8",
    "within32",
    "mean_abs",
    "max_d",
    "ours_ms",
    "ours_net_ms",
    "resvg_ms",
    "resvg_net_ms",
    "ratio_ours_resvg",
    "ratio_net_net",
    "ours_ms_per_mpx",
    "resvg_ms_per_mpx",
    "note",
]


def csvnum(x, spec="%.6f"):
    return "" if x is None else spec % x


def write_csv(path, cells):
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for c in cells:
            writer.writerow(
                {
                    "file": c["file"],
                    "width": c["width"],
                    "size": c["size"] or "",
                    "mpx": csvnum(c["mpx"], "%.4f"),
                    "status": c["status"],
                    "exact": csvnum(c["exact"]),
                    "within8": csvnum(c["within"]),
                    "within32": csvnum(c["within32"]),
                    "mean_abs": csvnum(c["mean_abs"]),
                    "max_d": "" if c["max_d"] is None else c["max_d"],
                    "ours_ms": csvnum(c["ours_ms"], "%.2f"),
                    "ours_net_ms": csvnum(c["ours_net_ms"], "%.2f"),
                    "resvg_ms": csvnum(c["resvg_ms"], "%.2f"),
                    "resvg_net_ms": csvnum(c["resvg_net_ms"], "%.2f"),
                    "ratio_ours_resvg": csvnum(c["ratio"], "%.4f"),
                    "ratio_net_net": csvnum(c["ratio_net"], "%.4f"),
                    "ours_ms_per_mpx": csvnum(c["ours_ms_per_mpx"], "%.2f"),
                    "resvg_ms_per_mpx": csvnum(c["resvg_ms_per_mpx"], "%.2f"),
                    "note": c["note"],
                }
            )


def write_md(path, cells, summary_rows, meta, slowest):
    parts = [
        "# lean-svg: fidelity and speed across render sizes",
        "",
        "%s · widths %s · median of %d runs · tolerance %d"
        % (meta["generated"], meta["widths"], meta["runs"], TOL),
        "",
        "Process-start baseline (trivial 1x1 SVG, median of %d runs): "
        "ours %.1f ms, resvg %.1f ms. `ours net` is the median minus our "
        "baseline; `ours/Mpx` is net time per megapixel of output. "
        "`ratio` is `ours net / resvg ms`." % (
            meta["runs"],
            meta["base_ours"],
            meta["base_resvg"],
        ),
        "",
        "Net time is not clamped: at the smallest widths our render cost sits "
        "at or below the process-start baseline, so a near-zero or slightly "
        "negative net (and the ratio and ms/Mpx derived from it) is noise, not "
        "a measurement. `sizes.csv` also carries `ratio_net_net`, which "
        "subtracts resvg's own start-up cost from the denominator.",
        "",
        "## Summary",
        "",
        summary_md(summary_rows),
        "",
        "## Slowest cells",
        "",
        md_table(
            ["file", "width", "size", "ours net ms", "resvg ms", "ratio"],
            [
                [
                    c["file"],
                    c["width"],
                    c["size"] or "-",
                    num(c["ours_net_ms"], "%.1f"),
                    num(c["resvg_ms"], "%.1f"),
                    num(c["ratio"], "%.1f"),
                ]
                for c in slowest
            ],
        ),
        "",
        "## Per file",
        "",
    ]
    by_file = {}
    for c in cells:
        by_file.setdefault(c["file"], []).append(c)
    for name in sorted(by_file):
        parts.append("### %s" % name)
        parts.append("")
        parts.append(file_md(by_file[name]))
        notes = [c for c in by_file[name] if c["note"]]
        if notes:
            parts.append("")
            for c in notes:
                parts.append("- width %d: %s — %s" % (c["width"], c["status"], c["note"]))
        parts.append("")
    path.write_text("\n".join(parts) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def parse_widths(text):
    widths = []
    for piece in text.split(","):
        piece = piece.strip()
        if not piece:
            continue
        w = int(piece)
        if w <= 0:
            raise ValueError("width must be positive: %s" % piece)
        widths.append(w)
    return widths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--widths",
        default=",".join(str(w) for w in DEFAULT_WIDTHS),
        help="comma-separated output widths (default %(default)s)",
    )
    parser.add_argument("--filter", help="only run files whose name contains SUBSTR")
    parser.add_argument(
        "--runs", type=int, default=3, help="timing runs per cell, median (default 3)"
    )
    parser.add_argument(
        "--bin", default=str(DEFAULT_BIN), help="path to the lean-svg binary"
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
    if args.runs < 1:
        print("--runs must be at least 1", file=sys.stderr)
        return 2

    try:
        widths = parse_widths(args.widths)
    except ValueError as exc:
        print("bad --widths: %s" % exc, file=sys.stderr)
        return 2
    if not widths:
        print("no widths to run", file=sys.stderr)
        return 2

    svgs = sorted(SVG_DIR.glob("*.svg"))
    if args.filter:
        svgs = [s for s in svgs if args.filter in s.name]
    if not svgs:
        print("no SVGs to test in %s" % SVG_DIR, file=sys.stderr)
        return 2

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    started = time.perf_counter()
    cells = []
    with tempfile.TemporaryDirectory(prefix="lean-svg-sizes-") as tmpdir:
        tmp = Path(tmpdir)
        base_ours, base_resvg = measure_baseline(binary, tmp, args.runs)
        print(
            "baseline (1x1 svg, median of %d): ours %.1f ms, resvg %.1f ms"
            % (args.runs, base_ours, base_resvg)
        )
        print(
            "%d files x %d widths x %d runs, timeout %d s per run"
            % (len(svgs), len(widths), args.runs, RENDER_TIMEOUT)
        )

        for svg in svgs:
            file_cells = []
            for width in widths:
                cell = run_cell(
                    svg, width, binary, tmp, args.runs, base_ours, base_resvg
                )
                file_cells.append(cell)
                cells.append(cell)
            print_file_table(svg.stem, file_cells)
            sys.stdout.flush()

    summary_rows = summarise(cells, widths)
    print_summary(summary_rows)

    slowest = sorted(
        (c for c in cells if c["ours_net_ms"] is not None),
        key=lambda c: c["ours_net_ms"],
        reverse=True,
    )[:3]
    print()
    print("slowest cells (ours, net):")
    for c in slowest:
        print(
            "  %-22s w=%-5d %-11s %8.1f ms net  (resvg %.1f ms, ratio %s)"
            % (
                c["file"],
                c["width"],
                c["size"] or "-",
                c["ours_net_ms"],
                c["resvg_ms"] or 0.0,
                num(c["ratio"], "%.1f"),
            )
        )

    skipped = [c for c in cells if c["status"] == "skipped"]
    errors = [c for c in cells if c["status"] == "error"]
    mismatched = [c for c in cells if c["status"] == "size mismatch"]
    print()
    print(
        "%d cells: %d scored, %d size mismatch, %d skipped, %d errors  (%.1f s total)"
        % (
            len(cells),
            sum(1 for c in cells if c["within"] is not None),
            len(mismatched),
            len(skipped),
            len(errors),
            time.perf_counter() - started,
        )
    )
    for c in mismatched + skipped + errors:
        print("  %s w=%d: %s — %s" % (c["file"], c["width"], c["status"], c["note"]))

    meta = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "widths": ",".join(str(w) for w in widths),
        "runs": args.runs,
        "base_ours": base_ours,
        "base_resvg": base_resvg,
    }
    csv_path = OUT_DIR / "sizes.csv"
    md_path = OUT_DIR / "sizes.md"
    write_csv(csv_path, cells)
    write_md(md_path, cells, summary_rows, meta, slowest)
    print("wrote %s and %s" % (csv_path, md_path))

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
