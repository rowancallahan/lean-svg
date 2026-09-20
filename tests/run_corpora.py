#!/usr/bin/env python3
"""External-corpus fidelity harness: score microsvg against resvg on SVG files
we did not write.

Three corpora are expected under tests/corpora/ (clone them with the commands
in tasks/T15-external-corpora.md; the directory is gitignored):

    resvg-test-suite   linebender/resvg-test-suite  (MIT)   tests/**/*.svg
    simple-icons       simple-icons/simple-icons    (CC0)   icons/*.svg
    feather            feathericons/feather         (MIT)   icons/*.svg

Two render routes are measured:

    direct   microsvg reads the original file.  Exercises our own parser and
             subset support; a non-zero exit is counted as "unsupported",
             not as a rendering failure.
    usvg     the file is first simplified by the usvg CLI (text -> paths, CSS
             resolved, `use` expanded, units resolved) and microsvg reads that.

The reference for BOTH routes is `resvg -w W` on the *original* file, so the
two routes are directly comparable.

Outputs land in tests/out/corpora/:

    <corpus>_<route>.csv   every file, with metrics and error text
    summary.md             per-corpus/route, per-feature-directory and
                           worst-file tables
    worst/*.png            ref | ours | diff composites for the worst files

Metric and composite helpers are imported from tests/run_tests.py so the
numbers mean exactly what they mean there.
"""

import argparse
import csv
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests"))

from run_tests import (  # noqa: E402  (path must be set up first)
    compare,
    diff_panel,
    load_rgba,
    over_white,
    write_composite,
)

CORPORA_DIR = REPO / "tests" / "corpora"
OUT_DIR = REPO / "tests" / "out" / "corpora"
WORST_DIR = OUT_DIR / "worst"
DEFAULT_BIN = REPO / ".lake" / "build" / "bin" / "microsvg"

RENDER_TIMEOUT = 30  # seconds, per subprocess
SAMPLE_SEED = 20240915  # fixed, so --limit runs are reproducible
N_WORST = 20
TOP_ERRORS = 10

# root (relative to tests/corpora), glob, render width, default --limit.
# The icon sets are 24 px files; 96 px gives the metric some area to work with.
# No corpus samples by default: the whole `--corpus all --route both` run takes
# ~1.5 minutes on this machine, well inside the ~15 minute budget. `--limit N`
# is there for quick iteration.
CORPORA = {
    "resvg": ("resvg-test-suite/tests", "**/*.svg", 200, None),
    "simple-icons": ("simple-icons/icons", "*.svg", 96, None),
    "feather": ("feather/icons", "*.svg", 96, None),
}
ROUTES = ("direct", "usvg")


# --------------------------------------------------------------------------
# subprocesses
# --------------------------------------------------------------------------


def run_cmd(cmd):
    """Run one renderer/converter. Returns (rc, elapsed_ms, stderr, timed_out).

    rc is None on timeout, matching run_tests.run_renderer's convention.
    """
    start = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=RENDER_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return None, (time.perf_counter() - start) * 1000.0, "timed out after %ds" % RENDER_TIMEOUT, True
    except OSError as exc:
        return None, (time.perf_counter() - start) * 1000.0, str(exc), False
    elapsed = (time.perf_counter() - start) * 1000.0
    return proc.returncode, elapsed, proc.stderr.decode("utf-8", "replace").strip(), False


def first_line(text, limit=160):
    """First non-empty line of a stderr blob, truncated."""
    for line in (text or "").splitlines():
        line = line.strip()
        if line:
            return line[:limit]
    return ""


# --------------------------------------------------------------------------
# one file
# --------------------------------------------------------------------------


def render_one(svg, corpus, route, width, binary, tmpdir, slot, tol, threshold, keep):
    """Render one file both ways and score it.

    Returns a row dict. When `keep` is true the loaded RGBA arrays and the
    on-disk PNG paths are kept on the row so a composite can be written; the
    scratch PNGs are deleted otherwise.
    """
    root = CORPORA_DIR / CORPORA[corpus][0]
    rel = svg.relative_to(root).as_posix()
    row = {
        "corpus": corpus,
        "route": route,
        "file": rel,
        "dir": str(Path(rel).parent) if str(Path(rel).parent) != "." else "(root)",
        "width": width,
        "status": "",
        "ours_rc": "",
        "ours_err": "",
        "ref_rc": "",
        "ref_err": "",
        "usvg_rc": "",
        "usvg_err": "",
        "size": "",
        "exact": "",
        "within": "",
        "within32": "",
        "mean_abs": "",
        "max_d": "",
        "ms_ours": "",
        "ms_ref": "",
    }

    ref_png = tmpdir / ("%06d_ref.png" % slot)
    ours_png = tmpdir / ("%06d_ours.png" % slot)
    mid_svg = tmpdir / ("%06d_usvg.svg" % slot)
    scratch = [ref_png, ours_png, mid_svg]
    for stale in scratch:
        stale.unlink(missing_ok=True)

    def cleanup():
        if not keep:
            for path in scratch:
                path.unlink(missing_ok=True)

    # reference: resvg on the ORIGINAL file, for both routes
    rc_ref, ms_ref, err_ref, to_ref = run_cmd(
        ["resvg", "-w", str(width), str(svg), str(ref_png)]
    )
    row["ref_rc"] = "timeout" if to_ref else rc_ref
    row["ref_err"] = first_line(err_ref)
    row["ms_ref"] = "%.1f" % ms_ref
    if to_ref or rc_ref != 0:
        row["status"] = "ref_failed"
        cleanup()
        return row

    # input for microsvg
    src = svg
    if route == "usvg":
        rc_u, _, err_u, to_u = run_cmd(["usvg", str(svg), str(mid_svg)])
        row["usvg_rc"] = "timeout" if to_u else rc_u
        row["usvg_err"] = first_line(err_u)
        if to_u or rc_u != 0 or not mid_svg.is_file():
            row["status"] = "usvg_failed"
            cleanup()
            return row
        src = mid_svg

    rc_ours, ms_ours, err_ours, to_ours = run_cmd(
        [str(binary), str(src), str(ours_png), "--width", str(width)]
    )
    row["ours_rc"] = "timeout" if to_ours else rc_ours
    row["ours_err"] = first_line(err_ours)
    row["ms_ours"] = "%.1f" % ms_ours
    if to_ours or rc_ours != 0:
        row["status"] = "timeout" if to_ours else "unsupported"
        cleanup()
        return row

    ref = load_rgba(ref_png)
    ours = load_rgba(ours_png)
    if ref is None or ours is None:
        row["status"] = "unreadable_png"
        row["ours_err"] = row["ours_err"] or "output PNG could not be read"
        cleanup()
        return row

    ref_size = (ref.shape[1], ref.shape[0])
    ours_size = (ours.shape[1], ours.shape[0])
    if ref_size != ours_size:
        row["status"] = "size_mismatch"
        row["size"] = "%dx%d vs %dx%d" % (ref_size + ours_size)
        cleanup()
        return row
    row["size"] = "%dx%d" % ref_size

    metrics, d = compare(ref, ours, tol)
    row["exact"] = "%.6f" % metrics["exact"]
    row["within"] = "%.6f" % metrics["within"]
    row["within32"] = "%.6f" % metrics["within32"]
    row["mean_abs"] = "%.4f" % metrics["mean_abs"]
    row["max_d"] = metrics["max_d"]
    row["status"] = "pass" if metrics["within"] >= threshold else "fail"
    row["_within"] = metrics["within"]
    row["_exact"] = metrics["exact"]
    if keep:
        row["_panels"] = [over_white(ref), over_white(ours), diff_panel(d)]
    cleanup()
    return row


# --------------------------------------------------------------------------
# a corpus/route run
# --------------------------------------------------------------------------


def collect_files(corpus, limit):
    root, pattern, _, default_limit = CORPORA[corpus]
    base = CORPORA_DIR / root
    if not base.is_dir():
        return None, base
    files = sorted(p for p in base.glob(pattern) if p.is_file())
    effective = default_limit if limit is None else (None if limit == 0 else limit)
    if effective is not None and len(files) > effective:
        files = sorted(random.Random(SAMPLE_SEED).sample(files, effective))
    return files, base


CSV_FIELDS = [
    "corpus", "route", "file", "dir", "width", "status",
    "ours_rc", "ours_err", "ref_rc", "ref_err", "usvg_rc", "usvg_err",
    "size", "exact", "within", "within32", "mean_abs", "max_d",
    "ms_ours", "ms_ref",
]


def run_corpus_route(corpus, route, files, binary, tol, threshold, jobs):
    width = CORPORA[corpus][2]
    tmpdir = Path(tempfile.mkdtemp(prefix="corpora_%s_%s_" % (corpus, route)))
    try:
        def task(pair):
            i, svg = pair
            return render_one(
                svg, corpus, route, width, binary, tmpdir, i % (jobs * 4),
                tol, threshold, keep=False,
            )

        start = time.perf_counter()
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            rows = list(pool.map(task, enumerate(files)))
        elapsed = time.perf_counter() - start
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    csv_path = OUT_DIR / ("%s_%s.csv" % (corpus, route))
    with csv_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_FIELDS, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
    return rows, elapsed, csv_path


def write_worst_composites(corpus, route, rows, binary, tol, threshold, jobs):
    """Re-render the N worst scored files and write ref|ours|diff composites."""
    scored = [r for r in rows if "_within" in r]
    worst = sorted(scored, key=lambda r: r["_within"])[:N_WORST]
    if not worst:
        return []
    width = CORPORA[corpus][2]
    root = CORPORA_DIR / CORPORA[corpus][0]
    WORST_DIR.mkdir(parents=True, exist_ok=True)
    tmpdir = Path(tempfile.mkdtemp(prefix="worst_%s_%s_" % (corpus, route)))
    try:
        def task(pair):
            i, row = pair
            svg = root / row["file"]
            fresh = render_one(
                svg, corpus, route, width, binary, tmpdir, i,
                tol, threshold, keep=True,
            )
            panels = fresh.pop("_panels", None)
            if panels is None:
                return None
            flat = row["file"].replace("/", "__").replace(".svg", "")
            out = WORST_DIR / ("%s_%s__%s_cmp.png" % (corpus, route, flat))
            write_composite(out, panels)
            return out.name

        with ThreadPoolExecutor(max_workers=jobs) as pool:
            list(pool.map(task, enumerate(worst)))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return worst


# --------------------------------------------------------------------------
# summaries
# --------------------------------------------------------------------------


def stats_for(rows):
    """Aggregate a list of rows into the summary numbers."""
    scored = [r for r in rows if "_within" in r]
    counts = Counter(r["status"] for r in rows)
    passes = counts["pass"]
    total = len(rows)
    return {
        "files": total,
        "rendered": len(scored),
        "unsupported": counts["unsupported"],
        "timeout": counts["timeout"],
        "usvg_failed": counts["usvg_failed"],
        "ref_failed": counts["ref_failed"],
        "size_mismatch": counts["size_mismatch"],
        "pass": passes,
        "fail": counts["fail"],
        "pass_all": (passes / total) if total else 0.0,
        "pass_rendered": (passes / len(scored)) if scored else 0.0,
        "med_within": statistics.median(r["_within"] for r in scored) if scored else None,
        "med_exact": statistics.median(r["_exact"] for r in scored) if scored else None,
    }


def pctf(x):
    return "-" if x is None else "%.1f%%" % (x * 100.0)


def pctf3(x):
    return "-" if x is None else "%.3f%%" % (x * 100.0)


def md_table(header, rows):
    out = ["| " + " | ".join(header) + " |"]
    out.append("|" + "|".join("---" for _ in header) + "|")
    for row in rows:
        out.append("| " + " | ".join(str(c) for c in row) + " |")
    return "\n".join(out)


SUMMARY_HEADER = [
    "corpus", "route", "files", "rendered", "unsupported", "usvg err",
    "size mism.", "ref err", "pass", "pass% (all)", "pass% (rendered)",
    "med within-8", "med exact",
]


def summary_row(label, route, s):
    return [
        label, route, s["files"], s["rendered"],
        s["unsupported"] + s["timeout"], s["usvg_failed"],
        s["size_mismatch"], s["ref_failed"], s["pass"],
        pctf(s["pass_all"]), pctf(s["pass_rendered"]),
        pctf3(s["med_within"]), pctf3(s["med_exact"]),
    ]


D_ATTR = re.compile(r'\bd\s*=\s*"([^"]*)"', re.S)
_ARC_CACHE = {}


def uses_arcs(path):
    """True if any path data in the file contains an elliptical-arc command.

    Path data only uses the letters MmZzLlHhVvCcSsQqTtAa, so looking for a
    bare A/a inside a `d` attribute is unambiguous.
    """
    key = str(path)
    if key not in _ARC_CACHE:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            _ARC_CACHE[key] = False
        else:
            _ARC_CACHE[key] = any(
                "A" in m.group(1) or "a" in m.group(1) for m in D_ATTR.finditer(text)
            )
    return _ARC_CACHE[key]


def arc_table(all_runs):
    """Pass rate split by whether the ORIGINAL file contains arc commands."""
    out = []
    for corpus, route, rows, _, _ in all_runs:
        root = CORPORA_DIR / CORPORA[corpus][0]
        for want in (True, False):
            sel = [r for r in rows if uses_arcs(root / r["file"]) is want]
            if not sel:
                continue
            s = stats_for(sel)
            out.append(
                [
                    corpus, route, "yes" if want else "no", s["files"], s["pass"],
                    pctf(s["pass_all"]), pctf3(s["med_within"]), pctf3(s["med_exact"]),
                ]
            )
    return out


def error_table(rows):
    errs = Counter()
    for r in rows:
        if r["status"] in ("unsupported", "timeout"):
            errs[r["ours_err"] or "(no stderr, rc=%s)" % r["ours_rc"]] += 1
    return errs.most_common(TOP_ERRORS)


def build_summary(all_runs, config):
    """all_runs: list of (corpus, route, rows, elapsed, csv_path)."""
    parts = []
    parts.append("# External corpora: microsvg vs resvg\n")
    parts.append(
        "generated %s &middot; microsvg `%s` &middot; commit `%s` &middot; "
        "resvg/usvg %s &middot; tol %d &middot; threshold %.2f &middot; jobs %d\n"
        % (
            time.strftime("%Y-%m-%d %H:%M:%S"), config["bin"], config["commit"],
            config["tool_version"], config["tol"], config["threshold"], config["jobs"],
        )
    )
    parts.append(
        "\n`pass` = at least %.0f%% of pixels within %d of the resvg reference "
        "(max abs channel difference). `pass%% (all)` divides by every file "
        "attempted, so unsupported files count against it; `pass%% (rendered)` "
        "divides by the files that produced a comparable image. "
        "Reference is always `resvg -w W` on the *original* file, for both routes.\n"
        % (config["threshold"] * 100.0, config["tol"])
    )
    for corpus, note in config["sampling_notes"]:
        parts.append("\n- **%s**: %s" % (corpus, note))
    parts.append("\n")

    # ---- per corpus and route
    parts.append("\n## Per corpus and route\n")
    rows = []
    for corpus, route, rrows, _, _ in all_runs:
        rows.append(summary_row(corpus, route, stats_for(rrows)))
    parts.append(md_table(SUMMARY_HEADER, rows) + "\n")

    parts.append("\n### Wall clock\n")
    parts.append(
        md_table(
            ["corpus", "route", "files", "seconds", "csv"],
            [
                [c, r, len(rr), "%.1f" % el, p.name]
                for c, r, rr, el, p in all_runs
            ],
        )
        + "\n"
    )

    # ---- error messages
    parts.append("\n## microsvg error messages (exit != 0)\n")
    for corpus, route, rrows, _, _ in all_runs:
        errs = error_table(rrows)
        if not errs:
            continue
        parts.append("\n### %s / %s (%d files)\n" % (corpus, route, sum(n for _, n in errs)))
        parts.append(
            md_table(["count", "first stderr line"], [[n, "`%s`" % e] for e, n in errs])
            + "\n"
        )

    # ---- arc cross-tab
    parts.append("\n## Split by elliptical arcs in the source path data\n")
    parts.append(
        "\nThe single largest direct-route defect, so it gets its own table: "
        "files whose `d` attributes contain an `A`/`a` command versus the rest. "
        "usvg converts arcs to cubics, which is why the split closes on that route.\n"
    )
    parts.append(
        md_table(
            ["corpus", "route", "has arcs", "files", "pass", "pass%",
             "med within-8", "med exact"],
            arc_table(all_runs),
        )
        + "\n"
    )

    # ---- resvg suite per feature directory
    for route in ROUTES:
        run = next(
            (r for r in all_runs if r[0] == "resvg" and r[1] == route), None
        )
        if run is None:
            continue
        rrows = run[2]
        parts.append("\n## resvg-test-suite by feature directory — %s route\n" % route)

        top = defaultdict(list)
        sub = defaultdict(list)
        for r in rrows:
            top[r["dir"].split("/")[0]].append(r)
            sub[r["dir"]].append(r)

        parts.append("\nTop level, sorted by pass rate:\n")
        trows = sorted(
            ((k, stats_for(v)) for k, v in top.items()),
            key=lambda kv: (
                -kv[1]["pass_all"],
                -(kv[1]["med_within"] if kv[1]["med_within"] is not None else -1.0),
            ),
        )
        parts.append(
            md_table(SUMMARY_HEADER, [summary_row(k, route, s) for k, s in trows]) + "\n"
        )

        parts.append(
            "\nFeature directory, sorted by pass rate then median within-8 "
            "(so the bottom of the table is genuinely the worst, not just "
            "alphabetically last among the 0% directories):\n"
        )
        srows = sorted(
            ((k, stats_for(v)) for k, v in sub.items()),
            key=lambda kv: (
                -kv[1]["pass_all"],
                -(kv[1]["med_within"] if kv[1]["med_within"] is not None else -1.0),
                kv[0],
            ),
        )
        parts.append(
            md_table(SUMMARY_HEADER, [summary_row(k, route, s) for k, s in srows]) + "\n"
        )

    # ---- worst files
    parts.append("\n## Worst rendered files (lowest within-8, rendered only)\n")
    for corpus, route, rrows, _, _ in all_runs:
        scored = sorted(
            (r for r in rrows if "_within" in r), key=lambda r: r["_within"]
        )[:N_WORST]
        if not scored:
            continue
        parts.append("\n### %s / %s\n" % (corpus, route))
        parts.append(
            md_table(
                ["file", "within-8", "exact", "within-32", "mean_abs", "max_d"],
                [
                    [
                        r["file"], pctf3(r["_within"]), pctf3(r["_exact"]),
                        pctf3(float(r["within32"])), r["mean_abs"], r["max_d"],
                    ]
                    for r in scored
                ],
            )
            + "\n"
        )
    parts.append(
        "\nComposites (`reference | ours | diff`) for the files above are in "
        "`tests/out/corpora/worst/`.\n"
    )
    return "".join(parts)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--corpus", default="all",
        choices=["resvg", "simple-icons", "feather", "all"],
        help="which corpus to measure (default all)",
    )
    parser.add_argument(
        "--route", default="both", choices=["direct", "usvg", "both"],
        help="direct = original file into microsvg; usvg = usvg-simplified first",
    )
    parser.add_argument(
        "--limit", type=int, default=None,
        help="random sample of N files per corpus, fixed seed %d. "
             "Default: the whole of every corpus (--limit 0 means the same)."
             % SAMPLE_SEED,
    )
    parser.add_argument("--tol", type=int, default=8, help="per-pixel tolerance (default 8)")
    parser.add_argument(
        "--threshold", type=float, default=0.99,
        help="minimum within-tol fraction to pass (default 0.99)",
    )
    parser.add_argument("--jobs", type=int, default=4, help="parallel subprocesses (default 4)")
    parser.add_argument("--bin", default=str(DEFAULT_BIN), help="path to the microsvg binary")
    parser.add_argument(
        "--no-worst", action="store_true", help="skip the worst-file composites"
    )
    args = parser.parse_args()

    binary = Path(args.bin).resolve()
    if not binary.is_file():
        print("microsvg binary not found at %s (build it first)" % binary, file=sys.stderr)
        return 2
    if shutil.which("resvg") is None:
        print("resvg not found on PATH (needed as the oracle)", file=sys.stderr)
        return 2
    routes = list(ROUTES) if args.route == "both" else [args.route]
    if "usvg" in routes and shutil.which("usvg") is None:
        print("usvg not found on PATH; run with --route direct", file=sys.stderr)
        return 2

    corpora = list(CORPORA) if args.corpus == "all" else [args.corpus]

    sampling_notes = []
    selected = {}
    for corpus in corpora:
        files, base = collect_files(corpus, args.limit)
        if files is None:
            print("corpus %s missing at %s, skipping" % (corpus, base), file=sys.stderr)
            sampling_notes.append((corpus, "MISSING at `%s` — not measured" % base))
            continue
        if not files:
            print("corpus %s has no SVGs under %s, skipping" % (corpus, base), file=sys.stderr)
            continue
        selected[corpus] = files
        root, pattern, width, default_limit = CORPORA[corpus]
        total = len(sorted(p for p in base.glob(pattern) if p.is_file()))
        if len(files) < total:
            sampling_notes.append(
                (corpus, "random sample of %d/%d files (seed %d), rendered at "
                         "`--width %d`" % (len(files), total, SAMPLE_SEED, width))
            )
        else:
            sampling_notes.append(
                (corpus, "all %d files, rendered at `--width %d`" % (total, width))
            )
    if not selected:
        print("no corpora available under %s" % CORPORA_DIR, file=sys.stderr)
        return 2

    commit = subprocess.run(
        ["git", "-C", str(REPO), "log", "-1", "--format=%h"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    ).stdout.decode().strip() or "unknown"
    tool_version = subprocess.run(
        ["resvg", "--version"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    ).stdout.decode().strip() or "unknown"

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    all_runs = []
    grand_start = time.perf_counter()
    for corpus in selected:
        for route in routes:
            files = selected[corpus]
            print(
                "== %s / %s: %d files at width %d, %d jobs"
                % (corpus, route, len(files), CORPORA[corpus][2], args.jobs),
                flush=True,
            )
            rows, elapsed, csv_path = run_corpus_route(
                corpus, route, files, binary, args.tol, args.threshold, args.jobs
            )
            s = stats_for(rows)
            print(
                "   %.1fs  rendered %d/%d  unsupported %d  size-mism %d  "
                "pass %d (%.1f%% of all, %.1f%% of rendered)"
                % (
                    elapsed, s["rendered"], s["files"],
                    s["unsupported"] + s["timeout"], s["size_mismatch"],
                    s["pass"], s["pass_all"] * 100.0, s["pass_rendered"] * 100.0,
                ),
                flush=True,
            )
            if not args.no_worst:
                write_worst_composites(
                    corpus, route, rows, binary, args.tol, args.threshold, args.jobs
                )
            all_runs.append((corpus, route, rows, elapsed, csv_path))

    config = {
        "bin": str(binary),
        "commit": commit,
        "tool_version": tool_version,
        "tol": args.tol,
        "threshold": args.threshold,
        "jobs": args.jobs,
        "sampling_notes": sampling_notes,
    }
    summary_path = OUT_DIR / "summary.md"
    summary_path.write_text(build_summary(all_runs, config), encoding="utf-8")
    print(
        "\ntotal %.1fs; wrote %s and %d CSVs"
        % (time.perf_counter() - grand_start, summary_path, len(all_runs)),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
