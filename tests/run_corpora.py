#!/usr/bin/env python3
"""External-corpus fidelity harness: score lean-svg against resvg on SVG files
we did not write.

Three corpora are expected under tests/corpora/ (clone them with the commands
in tasks/T15-external-corpora.md; the directory is gitignored):

    resvg-test-suite   linebender/resvg-test-suite  (MIT)   tests/**/*.svg
    simple-icons       simple-icons/simple-icons    (CC0)   icons/*.svg
    feather            feathericons/feather         (MIT)   icons/*.svg

Two render routes are measured:

    direct   lean-svg reads the original file.  Exercises our own parser and
             subset support; a non-zero exit is counted as "unsupported",
             not as a rendering failure.
    usvg     the file is first simplified by the usvg CLI (text -> paths, CSS
             resolved, `use` expanded, units resolved) and lean-svg reads that.

The reference for BOTH routes is `resvg -w W` on the *original* file, so the
two routes are directly comparable.

Outputs land in tests/out/corpora/ (or --out DIR):

    <corpus>_<route>.csv   every file, with metrics and error text
    summary.md             per-corpus/route, per-feature-directory and
                           worst-file tables
    worst/*.png            ref | ours | diff composites for the worst files

Metric and composite helpers are imported from tests/run_tests.py so the
numbers mean exactly what they mean there.

The fast iteration loop, for a feature task that wants to see only what it
changed and prove it broke nothing else:

    # baseline for the directories you are about to touch
    python3 tests/run_corpora.py --fast --corpus resvg --route direct \\
        --dir shapes/path --out /tmp/base --no-worst
    # after the change: same files, delta table against the baseline
    python3 tests/run_corpora.py --fast --corpus resvg --route direct \\
        --dir shapes/path --out /tmp/after --no-worst \\
        --compare /tmp/base/resvg_direct.csv
    # or re-run just what did not pass, at small sizes
    python3 tests/run_corpora.py --fast --limit 50 --no-worst \\
        --failing-from /tmp/base/resvg_direct.csv --out /tmp/after
"""

import argparse
import csv
import os
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
    resvg_font_args,
    write_composite,
)
import render_chrome  # noqa: E402  (path must be set up first)

CORPORA_DIR = REPO / "tests" / "corpora"
OUT_DIR = REPO / "tests" / "out" / "corpora"
WORST_DIR = OUT_DIR / "worst"
DEFAULT_BIN = REPO / ".lake" / "build" / "bin" / "lean-svg"

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

# `--fast`: smaller renders for the iterate-on-failures loop. Small enough to
# be quick, large enough that the metric still sees antialiasing detail.
FAST_WIDTHS = {"resvg": 100, "simple-icons": 64, "feather": 64}

# Effective render width per corpus; main() fills this in (defaults, or
# FAST_WIDTHS under --fast). Everything that renders goes through width_for.
WIDTHS = {}

# A file "passed" only with this status; every other status (fail, unsupported,
# timeout, size_mismatch, usvg_failed, ref_failed, unreadable_png) is a
# non-pass and is what --failing-from re-selects.
PASS_STATUS = "pass"

# What `ours` is scored against. `resvg` (default) is live resvg on a copy
# with external hrefs stripped, unchanged from before --ref existed. `chrome`
# renders the same stripped copy with headless Chromium, one browser launch
# per corpus/route batch (see `prerender_chrome_refs`). `suite` reads the
# resvg-test-suite's own bundled PNG next to the SVG (resvg only; other
# corpora have none), resizing it to the render width if it is not already
# that size.
REF_MODES = ("resvg", "chrome", "suite")

# --compare reports a file as changed when within-8 moved by more than this
# many percentage points.
DELTA_EPS = 0.1


def width_for(corpus):
    return WIDTHS.get(corpus, CORPORA[corpus][2])


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


# Rowan's policy: lean-svg never loads anything outside the SVG itself (no file
# paths, no URLs). For a file that references an external resource, the right
# output is the file rendered *without* it, so the reference is resvg on a copy
# with every such `href`/`xlink:href` removed. Only same-document (`#id`) and
# `data:` hrefs are kept. The row carries a note saying so.
EXTERNAL_HREF = re.compile(r"""\s(?:xlink:)?href\s*=\s*(["'])(?!\s*#|\s*data:)[^"']*\1""")

TAG_OPEN = re.compile(r"<([A-Za-z][\w:.-]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*)")


def strip_external_refs(svg_path):
    """(text without external hrefs, number removed); None if unreadable."""
    try:
        text = svg_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    count = [0]

    def strip_tag(m):
        # `<a href>` is a hyperlink, not a resource: nothing is loaded for it
        if m.group(1) == "a":
            return m.group(0)
        attrs, n = EXTERNAL_HREF.subn("", m.group(2))
        count[0] += n
        return "<" + m.group(1) + attrs

    stripped = TAG_OPEN.sub(strip_tag, text)
    return stripped, count[0]


def prerender_chrome_refs(corpus, files, width, jobs):
    """Render every file's Chromium reference once, up front, for `--ref chrome`.

    Applies the same external-href stripping as the resvg reference path
    (`strip_external_refs`), so Chromium never loads anything outside the SVG
    either. One browser launch for the whole list (`render_chrome.render_batch`,
    `jobs` pages pulling from a shared queue), not one per file.

    Returns ({rel: {"png": Path|None, "note": str, "err": str}}, tmpdir); the
    caller must rmtree tmpdir once every row referencing these PNGs is done
    (render_one copies them out before returning).
    """
    root = CORPORA_DIR / CORPORA[corpus][0]
    tmpdir = Path(tempfile.mkdtemp(prefix="chromeref_%s_" % corpus))
    pairs = []
    stem_meta = {}
    for i, svg in enumerate(files):
        rel = svg.relative_to(root).as_posix()
        stem = "%06d" % i
        src = svg
        note = ""
        stripped = strip_external_refs(svg)
        if stripped is not None and stripped[1] > 0:
            src = tmpdir / (stem + "_src.svg")
            src.write_text(stripped[0], encoding="utf-8")
            note = "external resource not loaded by design; reference rendered without it"
        pairs.append((src, stem))
        stem_meta[stem] = (rel, note)
    rendered = render_chrome.render_batch(pairs, tmpdir / "out", width, jobs)
    out = {}
    for stem, (rel, note) in stem_meta.items():
        png = rendered.get(stem)
        out[rel] = {
            "png": png,
            "note": note,
            "err": "" if png is not None else "chromium could not render this file",
        }
    return out, tmpdir


def suite_ref_png(svg, width, dest):
    """Write the resvg-test-suite's own PNG for `svg`, resized to `width` if
    needed, to `dest`. Returns an error string, or None on success."""
    suite_png = svg.with_suffix(".png")
    if not suite_png.is_file():
        return "no suite PNG next to this file"
    img = load_rgba(suite_png)
    if img is None:
        return "suite PNG could not be read"
    if img.shape[1] == width:
        shutil.copy2(suite_png, dest)
        return None
    from PIL import Image  # local: only `suite` ref mode needs PIL's resize

    height = max(1, round(img.shape[0] * width / img.shape[1]))
    with Image.open(suite_png) as im:
        im.convert("RGBA").resize((width, height), Image.LANCZOS).save(dest)
    return None


def render_one(svg, corpus, route, width, binary, tmpdir, slot, tol, threshold, keep,
                keep_renders_dir=None, resvg_args=None, ref_mode="resvg", chrome_ref=None):
    """Render one file both ways and score it.

    Returns a row dict. When `keep` is true the loaded RGBA arrays and the
    on-disk PNG paths are kept on the row so a composite can be written; the
    scratch PNGs are deleted otherwise.

    When `keep_renders_dir` is given, whatever reference/ours PNGs exist at
    the point the file's row is finished (i.e. as far as rendering got) are
    copied to `keep_renders_dir/<corpus>/<route>/<relative path>.{ref,ours}.png`,
    for a gallery to read later. This is independent of `keep`.
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
        "note": "",
    }

    ref_png = tmpdir / ("%06d_ref.png" % slot)
    ours_png = tmpdir / ("%06d_ours.png" % slot)
    mid_svg = tmpdir / ("%06d_usvg.svg" % slot)
    # T98: lean-svg writes `<out>.warnings.txt` next to its PNG when it has
    # warnings, and refuses to run if that file already exists.
    scratch = [ref_png, ours_png, mid_svg, Path(str(ours_png) + ".warnings.txt")]
    for stale in scratch:
        stale.unlink(missing_ok=True)

    def save_renders():
        if keep_renders_dir is None:
            return
        dest = keep_renders_dir / corpus / route / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        if ref_png.is_file():
            shutil.copy2(ref_png, str(dest) + ".ref.png")
        if ours_png.is_file():
            shutil.copy2(ours_png, str(dest) + ".ours.png")

    def cleanup():
        save_renders()
        if not keep:
            for path in scratch:
                path.unlink(missing_ok=True)

    # `--ref suite`: the suite's PNGs are 500 px renders, and a resampled
    # reference never matches a native render (every file fails), so under
    # `suite` both sides are compared at the PNG's own width instead.
    if ref_mode == "suite":
        native = load_rgba(svg.with_suffix(".png"))
        if native is not None:
            width = native.shape[1]
            row["width"] = width

    # reference: resvg on the ORIGINAL file, for both routes -- except that
    # external resources are removed first (see `strip_external_refs`). Under
    # `--ref chrome`/`--ref suite` a different reference is substituted below,
    # but the external-resource policy still applies (chrome: stripped same as
    # resvg, upstream in prerender_chrome_refs; suite: the suite PNG is itself
    # already rendered without external resources, by the same suite policy).
    if ref_mode == "resvg":
        ref_src = svg
        stripped = strip_external_refs(svg)
        if stripped is not None and stripped[1] > 0:
            ref_src = tmpdir / ("%06d_noext.svg" % slot)
            ref_src.write_text(stripped[0], encoding="utf-8")
            scratch.append(ref_src)
            row["note"] = "external resource not loaded by design; reference rendered without it"
        rc_ref, ms_ref, err_ref, to_ref = run_cmd(
            ["resvg"] + (resvg_args or []) + ["-w", str(width), str(ref_src), str(ref_png)]
        )
        row["ref_rc"] = "timeout" if to_ref else rc_ref
        row["ref_err"] = first_line(err_ref)
        row["ms_ref"] = "%.1f" % ms_ref
        if to_ref or rc_ref != 0:
            row["status"] = "ref_failed"
            cleanup()
            return row
    elif ref_mode == "chrome":
        info = (chrome_ref or {}).get(rel)
        if info is None or info.get("png") is None:
            row["status"] = "ref_failed"
            row["ref_err"] = (info or {}).get("err") or "no chromium render for this file"
            cleanup()
            return row
        row["note"] = info.get("note", "")
        shutil.copy2(info["png"], ref_png)
        row["ref_rc"] = 0
    elif ref_mode == "suite":
        err = suite_ref_png(svg, width, ref_png)
        if err is not None:
            row["status"] = "ref_failed"
            row["ref_err"] = err
            cleanup()
            return row
        row["ref_rc"] = 0
    else:
        assert False, "unknown --ref mode %r" % ref_mode

    # input for lean-svg
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


def dir_match(rel, prefixes):
    """True if the file's directory is, or is under, one of the prefixes.

    `rel` is the path relative to the corpus root; a prefix like
    `shapes/path` matches `shapes/path/*.svg`, `shapes` matches every
    `shapes/**` file.
    """
    parent = Path(rel).parent.as_posix()
    for prefix in prefixes:
        if parent == prefix or parent.startswith(prefix + "/"):
            return True
    return False


def collect_files(corpus, limit, dir_prefixes=None, failing=None, has_arcs=None):
    """Select the files to run for one corpus.

    Filters compose in this order: feature directory (`--dir`, resvg suite
    only), earlier non-passes (`--failing-from`), arc content (`--has-arcs`),
    then the random `--limit` sample, so the sample is drawn from what the
    filters left. Returns (files, base, counts) with counts recording each
    stage for the console line and the summary's sampling note.
    """
    root, pattern, _, default_limit = CORPORA[corpus]
    base = CORPORA_DIR / root
    if not base.is_dir():
        return None, base, {}
    files = sorted(p for p in base.glob(pattern) if p.is_file())
    counts = {"total": len(files)}
    if dir_prefixes and corpus == "resvg":
        files = [p for p in files if dir_match(p.relative_to(base).as_posix(), dir_prefixes)]
        counts["dir"] = len(files)
    if failing is not None:
        files = [p for p in files if p.relative_to(base).as_posix() in failing]
        counts["failing"] = len(files)
    if has_arcs is not None:
        want = has_arcs == "yes"
        files = [p for p in files if uses_arcs(p) is want]
        counts["has_arcs"] = len(files)
    effective = default_limit if limit is None else (None if limit == 0 else limit)
    if effective is not None and len(files) > effective:
        files = sorted(random.Random(SAMPLE_SEED).sample(files, effective))
        counts["sampled"] = len(files)
    counts["selected"] = len(files)
    return files, base, counts


def selection_note(corpus, counts):
    """One line describing how this corpus/route's file list was narrowed."""
    bits = []
    if "dir" in counts:
        bits.append("`--dir` %d/%d" % (counts["dir"], counts["total"]))
    if "failing" in counts:
        bits.append("non-passing in the given CSVs: %d" % counts["failing"])
    if "has_arcs" in counts:
        bits.append("`--has-arcs` %d" % counts["has_arcs"])
    if "sampled" in counts:
        bits.append("random sample of %d (seed %d)" % (counts["sampled"], SAMPLE_SEED))
    if not bits:
        bits.append("all %d files" % counts["total"])
    return "%s, rendered at `--width %d`" % (", ".join(bits), width_for(corpus))


CSV_FIELDS = [
    "corpus", "route", "file", "dir", "width", "status",
    "ours_rc", "ours_err", "ref_rc", "ref_err", "usvg_rc", "usvg_err",
    "size", "exact", "within", "within32", "mean_abs", "max_d",
    "ms_ours", "ms_ref", "note",
]


def run_corpus_route(corpus, route, files, binary, tol, threshold, jobs, keep_renders_dir=None,
                     resvg_args=None, ref_mode="resvg", chrome_ref=None):
    width = width_for(corpus)
    tmpdir = Path(tempfile.mkdtemp(prefix="corpora_%s_%s_" % (corpus, route)))
    try:
        def task(pair):
            i, svg = pair
            # The slot must be unique per file, not recycled modulo the pool
            # size: one slow file (feMorphology with a huge radius, say) lets
            # later indices catch up and clobber its scratch PNGs, which showed
            # up as spurious "unreadable_png" rows.  render_one deletes its own
            # scratch files, so unique slots cost nothing.
            return render_one(
                svg, corpus, route, width, binary, tmpdir, i,
                tol, threshold, keep=False, keep_renders_dir=keep_renders_dir,
                resvg_args=resvg_args, ref_mode=ref_mode, chrome_ref=chrome_ref,
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


def write_worst_composites(
    corpus, route, rows, binary, tol, threshold, jobs, resvg_args=None,
    ref_mode="resvg", chrome_ref=None,
):
    """Re-render the N worst scored files and write ref|ours|diff composites."""
    scored = [r for r in rows if "_within" in r]
    worst = sorted(scored, key=lambda r: r["_within"])[:N_WORST]
    if not worst:
        return []
    width = width_for(corpus)
    root = CORPORA_DIR / CORPORA[corpus][0]
    WORST_DIR.mkdir(parents=True, exist_ok=True)
    tmpdir = Path(tempfile.mkdtemp(prefix="worst_%s_%s_" % (corpus, route)))
    try:
        def task(pair):
            i, row = pair
            svg = root / row["file"]
            fresh = render_one(
                svg, corpus, route, width, binary, tmpdir, i,
                tol, threshold, keep=True, resvg_args=resvg_args,
                ref_mode=ref_mode, chrome_ref=chrome_ref,
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
# reading earlier CSVs (--failing-from, --compare)
# --------------------------------------------------------------------------


def infer_corpus_route(path):
    """(corpus, route) encoded in a CSV's name, e.g. `simple-icons_usvg.csv`.

    Corpus names contain hyphens, never underscores, so the last underscore
    splits the two. Returns (None, None) when the name does not parse.
    """
    corpus, _, route = Path(path).stem.rpartition("_")
    if corpus in CORPORA and route in ROUTES:
        return corpus, route
    return None, None


def read_csv_rows(path):
    with Path(path).open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def keyed_rows(paths):
    """{(corpus, route): {file: row}} for one or more earlier CSVs.

    A row's own `corpus`/`route` columns win when they are valid; the file
    name is the fallback, so hand-trimmed CSVs still work.
    """
    out = defaultdict(dict)
    for path in paths:
        name_corpus, name_route = infer_corpus_route(path)
        for row in read_csv_rows(path):
            corpus = row.get("corpus") if row.get("corpus") in CORPORA else name_corpus
            route = row.get("route") if row.get("route") in ROUTES else name_route
            if corpus is None or route is None or not row.get("file"):
                continue
            out[(corpus, route)][row["file"]] = row
    return dict(out)


def failing_sets(paths):
    """{(corpus, route): {file, ...}} for every row that did not pass."""
    out = {}
    for key, rows in keyed_rows(paths).items():
        out[key] = {f for f, r in rows.items() if r.get("status") != PASS_STATUS}
    return out


def row_within(row):
    """within-8 as a percentage, or None when the file produced no metric."""
    try:
        return float(row["within"]) * 100.0
    except (KeyError, TypeError, ValueError):
        return None


def compare_to_base(all_runs, base_paths):
    """Per-file within-8 delta against one or more baseline CSVs.

    Returns (lines, totals): `lines` is the rendered Markdown block, `totals`
    the counters, so the caller can print the same text it writes to the
    summary.
    """
    base = keyed_rows(base_paths)
    changed = []
    totals = Counter()
    for corpus, route, rows, _, _ in all_runs:
        before_rows = base.get((corpus, route))
        if before_rows is None:
            continue
        totals["compared_runs"] += 1
        seen = set()
        for row in rows:
            before = before_rows.get(row["file"])
            if before is None:
                totals["only_new"] += 1
                continue
            seen.add(row["file"])
            b_pass = before.get("status") == PASS_STATUS
            a_pass = row["status"] == PASS_STATUS
            if a_pass and not b_pass:
                totals["newly_passing"] += 1
            elif b_pass and not a_pass:
                totals["newly_failing"] += 1
            b_w, a_w = row_within(before), row_within(row)
            if b_w is None or a_w is None:
                if before.get("status") != row["status"]:
                    changed.append(
                        (corpus, route, row["file"], b_w, a_w, None,
                         "%s -> %s" % (before.get("status"), row["status"]))
                    )
                    totals["changed"] += 1
                else:
                    totals["unchanged"] += 1
                continue
            delta = a_w - b_w
            if abs(delta) > DELTA_EPS:
                changed.append(
                    (corpus, route, row["file"], b_w, a_w, delta,
                     "%s -> %s" % (before.get("status"), row["status"]))
                )
                totals["changed"] += 1
            else:
                totals["unchanged"] += 1
        totals["only_base"] += len(set(before_rows) - seen)

    parts = []
    if not totals["compared_runs"]:
        parts.append(
            "\nNo run in this invocation matched a corpus/route in the "
            "baseline CSV(s); nothing to compare.\n"
        )
        return "".join(parts), totals

    changed.sort(key=lambda t: (t[5] if t[5] is not None else 0.0, t[2]))
    parts.append(
        "\n%d file(s) moved by more than %.1f points of within-8.\n"
        % (len(changed), DELTA_EPS)
    )
    if changed:
        parts.append(
            "\n"
            + md_table(
                ["corpus", "route", "file", "within-8 before", "within-8 after",
                 "delta (points)", "status"],
                [
                    [c, r, f,
                     "-" if b is None else "%.3f%%" % b,
                     "-" if a is None else "%.3f%%" % a,
                     "-" if d is None else "%+.3f" % d,
                     st]
                    for c, r, f, b, a, d, st in changed
                ],
            )
            + "\n"
        )
    parts.append(
        "\nnewly passing %d &middot; newly failing %d &middot; unchanged %d"
        " &middot; only in this run %d &middot; only in baseline %d\n"
        % (
            totals["newly_passing"], totals["newly_failing"], totals["unchanged"],
            totals["only_new"], totals["only_base"],
        )
    )
    return "".join(parts), totals


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
    parts.append("# External corpora: lean-svg vs resvg\n")
    parts.append(
        "generated %s &middot; lean-svg `%s` &middot; commit `%s` &middot; "
        "resvg/usvg %s &middot; tol %d &middot; threshold %.2f &middot; jobs %d "
        "&middot; ref `%s`\n"
        % (
            time.strftime("%Y-%m-%d %H:%M:%S"), config["bin"], config["commit"],
            config["tool_version"], config["tol"], config["threshold"], config["jobs"],
            config["ref"],
        )
    )
    parts.append(
        "\nrender widths: %s%s\n"
        % (
            ", ".join(
                "`%s` %d px" % (c, width_for(c)) for c in config["widths_for"]
            ),
            " (`--fast`)" if config["fast"] else "",
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
    parts.append("\n## lean-svg error messages (exit != 0)\n")
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
        "`%s`.\n" % WORST_DIR
    )

    # ---- comparison against a baseline run
    if config.get("compare_block"):
        parts.append("\n## Change vs baseline `%s`\n" % config["compare_base"])
        parts.append(config["compare_block"])
    return "".join(parts)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main():
    global OUT_DIR, WORST_DIR
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--corpus", default=None,
        choices=["resvg", "simple-icons", "feather", "all"],
        help="which corpus to measure (default all, or the corpora named by "
             "--failing-from's CSVs)",
    )
    parser.add_argument(
        "--route", default=None, choices=["direct", "usvg", "both"],
        help="direct = original file into lean-svg; usvg = usvg-simplified "
             "first (default both, or the routes named by --failing-from's CSVs)",
    )
    parser.add_argument(
        "--failing-from", nargs="+", metavar="CSV", default=None,
        help="re-run only the files that did not pass in these earlier CSVs "
             "(anything but status=pass: fail, unsupported, timeout, size "
             "mismatch, usvg/ref error). Corpus and route come from each "
             "CSV's rows, falling back to its <corpus>_<route>.csv name, so "
             "--corpus/--route can be omitted; give them explicitly to run "
             "the same file set through another route",
    )
    parser.add_argument(
        "--dir", dest="dirs", action="append", metavar="PREFIX", default=None,
        help="restrict the resvg suite to a feature directory, repeatable: "
             "--dir shapes/path --dir painting/stroke-dasharray (a prefix "
             "also matches subdirectories; ignored for the flat icon sets)",
    )
    parser.add_argument(
        "--has-arcs", choices=["yes", "no"], default=None,
        help="only files whose source `d` attributes do (yes) or do not (no) "
             "contain an elliptical-arc command",
    )
    parser.add_argument(
        "--fast", action="store_true",
        help="small-render iteration loop: widths %s instead of the defaults, "
             "and --jobs defaults to hw.ncpu"
             % ", ".join("%s %d" % (c, w) for c, w in FAST_WIDTHS.items()),
    )
    parser.add_argument(
        "--width", type=int, default=None,
        help="override the render width for every selected corpus (beats "
             "both the per-corpus default and --fast)",
    )
    parser.add_argument(
        "--out", metavar="DIR", default=None,
        help="write the CSVs, summary.md and worst/ here instead of %s "
             "(use this from a worktree so the main results are not clobbered)"
             % OUT_DIR,
    )
    parser.add_argument(
        "--compare", nargs="+", metavar="CSV", default=None,
        help="after the run, print a per-file within-8 delta table against "
             "these baseline CSVs, plus newly passing / newly failing / "
             "unchanged totals",
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
    parser.add_argument(
        "--jobs", type=int, default=None,
        help="parallel subprocesses (default 4; hw.ncpu with --fast)",
    )
    parser.add_argument("--bin", default=str(DEFAULT_BIN), help="path to the lean-svg binary")
    parser.add_argument(
        "--no-worst", action="store_true", help="skip the worst-file composites"
    )
    parser.add_argument(
        "--no-font-pin", action="store_true",
        help="do not pin the resvg oracle's fonts to the test suite's bundled "
             "set (falls back to whatever fonts resvg finds on the system)",
    )
    parser.add_argument(
        "--ref", default="resvg", choices=list(REF_MODES),
        help="what to score `ours` against: live resvg (default, unchanged "
             "behaviour), headless Chromium (chrome), or the resvg-test-suite's "
             "own bundled PNG (suite, resvg corpus only)",
    )
    parser.add_argument(
        "--keep-renders", metavar="DIR", default=None,
        help="save each file's reference and our render as PNGs under "
             "DIR/<corpus>/<route>/<relative path>.{ref,ours}.png, for a "
             "gallery to build on; off by default and otherwise no behaviour "
             "change",
    )
    args = parser.parse_args()

    if args.out:
        OUT_DIR = Path(args.out).expanduser().resolve()
        WORST_DIR = OUT_DIR / "worst"

    keep_renders_dir = (
        Path(args.keep_renders).expanduser().resolve() if args.keep_renders else None
    )

    WIDTHS.update(FAST_WIDTHS if args.fast else {c: CORPORA[c][2] for c in CORPORA})
    if args.width is not None:
        WIDTHS.update({c: args.width for c in CORPORA})
    if args.jobs is None:
        args.jobs = (os.cpu_count() or 4) if args.fast else 4

    binary = Path(args.bin).resolve()
    if not binary.is_file():
        print("lean-svg binary not found at %s (build it first)" % binary, file=sys.stderr)
        return 2
    if shutil.which("resvg") is None:
        print("resvg not found on PATH (needed as the oracle)", file=sys.stderr)
        return 2
    for flag, paths in (("--failing-from", args.failing_from), ("--compare", args.compare)):
        for path in paths or []:
            if not Path(path).is_file():
                print("%s: no such CSV: %s" % (flag, path), file=sys.stderr)
                return 2

    corpus_explicit = args.corpus is not None
    route_explicit = args.route is not None
    routes = list(ROUTES) if (args.route or "both") == "both" else [args.route]
    corpora = list(CORPORA) if (args.corpus or "all") == "all" else [args.corpus]

    # ---- --failing-from: which files did not pass last time
    fail_sets = None
    if args.failing_from:
        fail_sets = failing_sets(args.failing_from)
        if not fail_sets:
            print(
                "--failing-from: no rows in %s name a known corpus and route"
                % ", ".join(args.failing_from),
                file=sys.stderr,
            )
            return 2
        print(
            "== --failing-from %s: %d non-passing files (%s)"
            % (
                " ".join(args.failing_from),
                sum(len(s) for s in fail_sets.values()),
                ", ".join(
                    "%s/%s %d" % (c, r, len(s))
                    for (c, r), s in sorted(fail_sets.items())
                ),
            ),
            flush=True,
        )
        if not corpus_explicit:
            corpora = [c for c in CORPORA if any(k[0] == c for k in fail_sets)]
        if not route_explicit:
            routes = [r for r in ROUTES if any(k[1] == r for k in fail_sets)]
        if corpus_explicit and not any(k[0] in corpora for k in fail_sets):
            print(
                "--failing-from: the given CSVs hold no rows for corpus %s"
                % args.corpus,
                file=sys.stderr,
            )
            return 2

    if "usvg" in routes and shutil.which("usvg") is None:
        print("usvg not found on PATH; run with --route direct", file=sys.stderr)
        return 2

    sampling_notes = []
    selected = {}
    noted = set()
    reported_missing = set()
    for corpus in corpora:
        for route in routes:
            failing = None
            if fail_sets is not None:
                failing = fail_sets.get((corpus, route))
                if failing is None and route_explicit:
                    # the user asked for a route the CSVs do not cover: take
                    # the union of that corpus's non-passing files instead.
                    union = set()
                    for (c, _), s in fail_sets.items():
                        if c == corpus:
                            union |= s
                    failing = union or None
                if failing is None:
                    continue
            files, base, counts = collect_files(
                corpus, args.limit, args.dirs, failing, args.has_arcs
            )
            if files is None:
                if corpus not in reported_missing:
                    reported_missing.add(corpus)
                    print(
                        "corpus %s missing at %s, skipping" % (corpus, base),
                        file=sys.stderr,
                    )
                    sampling_notes.append((corpus, "MISSING at `%s` — not measured" % base))
                continue
            if not files:
                print(
                    "%s / %s: no files left after the filters, skipping" % (corpus, route),
                    file=sys.stderr,
                )
                continue
            selected[(corpus, route)] = files
            note = selection_note(corpus, counts)
            label = corpus if fail_sets is None else "%s / %s" % (corpus, route)
            if label not in noted:
                noted.add(label)
                sampling_notes.append((label, note))
            print(
                "-- selected %d file(s) for %s / %s: %s"
                % (len(files), corpus, route, note.replace("`", "")),
                flush=True,
            )
    if not selected:
        if fail_sets is not None and not any(fail_sets.values()):
            # the good end of the iterate-on-failures loop, not an error
            print("--failing-from: every file in the given CSVs passed, nothing to re-run")
            return 0
        print("nothing selected to run (corpora under %s)" % CORPORA_DIR, file=sys.stderr)
        return 2

    commit = subprocess.run(
        ["git", "-C", str(REPO), "log", "-1", "--format=%h"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    ).stdout.decode().strip() or "unknown"
    tool_version = subprocess.run(
        ["resvg", "--version"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    ).stdout.decode().strip() or "unknown"

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    resvg_args = resvg_font_args(args.no_font_pin)
    all_runs = []
    grand_start = time.perf_counter()
    for (corpus, route), files in selected.items():
        print(
            "== %s / %s: %d files at width %d, %d jobs, --ref %s"
            % (corpus, route, len(files), width_for(corpus), args.jobs, args.ref),
            flush=True,
        )
        chrome_ref, chrome_tmpdir = None, None
        if args.ref == "chrome":
            t0 = time.perf_counter()
            chrome_ref, chrome_tmpdir = prerender_chrome_refs(
                corpus, files, width_for(corpus), args.jobs
            )
            n_ok = sum(1 for v in chrome_ref.values() if v["png"] is not None)
            print(
                "   chromium reference: %d/%d rendered in %.1fs"
                % (n_ok, len(chrome_ref), time.perf_counter() - t0),
                flush=True,
            )
        try:
            rows, elapsed, csv_path = run_corpus_route(
                corpus, route, files, binary, args.tol, args.threshold, args.jobs,
                keep_renders_dir, resvg_args=resvg_args,
                ref_mode=args.ref, chrome_ref=chrome_ref,
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
                    corpus, route, rows, binary, args.tol, args.threshold, args.jobs,
                    resvg_args=resvg_args, ref_mode=args.ref, chrome_ref=chrome_ref,
                )
        finally:
            if chrome_tmpdir is not None:
                shutil.rmtree(chrome_tmpdir, ignore_errors=True)
        all_runs.append((corpus, route, rows, elapsed, csv_path))

    # ---- --compare: what moved against a baseline run
    compare_block = ""
    if args.compare:
        compare_block, _ = compare_to_base(all_runs, args.compare)
        print("\n== change vs baseline %s" % " ".join(args.compare), flush=True)
        print(compare_block.replace("&middot;", "-").rstrip(), flush=True)

    config = {
        "bin": str(binary),
        "commit": commit,
        "tool_version": tool_version,
        "tol": args.tol,
        "threshold": args.threshold,
        "jobs": args.jobs,
        "ref": args.ref,
        "sampling_notes": sampling_notes,
        "fast": args.fast,
        "widths_for": sorted({c for c, _ in selected}, key=list(CORPORA).index),
        "compare_block": compare_block,
        "compare_base": " ".join(args.compare) if args.compare else "",
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
