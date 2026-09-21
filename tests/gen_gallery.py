#!/usr/bin/env python3
"""Browsable gallery of the resvg-test-suite corpus run.

Wraps `run_corpora.py --corpus resvg --keep-renders` (see that script for the
direct/usvg route semantics) and turns its output into a static, filterable
HTML page: one card per file, with reference / ours / diff thumbnails, a
status badge, the scored metrics, and a link to the SVG source.

    python3 tests/gen_gallery.py --out tests/out/gallery
    python3 tests/gen_gallery.py --out tests/out/gallery --route direct
    python3 tests/gen_gallery.py --out tests/out/gallery --reuse   # skip the harness, redo the diffs/page only

Layout under --out:

    run/            the run_corpora.py CSVs + summary.md (its own --out)
    renders/        resvg/<route>/<relative path>.{ref,ours,diff}.png
    data.json       one record per CSV row, read by index.html
    index.html      the gallery page (served by `python3 -m http.server`
                     from the repo root, e.g. the `reports` entry in
                     .claude/launch.json)

--width does not change the render resolution (the harness always uses its
`--fast` resvg width, currently 100px) — it only sets the CSS display size of
the thumbnails in the page; the underlying PNGs are used at native size.
"""

import argparse
import csv
import json
import os
import subprocess
import sys
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests"))

import run_corpora as RC  # noqa: E402  (path must be set up first)
from run_tests import load_rgba, over_white  # noqa: E402

CORPUS = "resvg"
ROUTES = ("direct", "usvg")
PASS_STATUS = "pass"

# CSV status -> one of the five filter buckets in the spec.
STATUS_GROUP = {
    "pass": "pass",
    "fail": "fail",
    "unsupported": "unsupported",
    "timeout": "error",
    "usvg_failed": "error",
    "ref_failed": "error",
    "unreadable_png": "error",
    "size_mismatch": "size-mismatch",
}


def urlpath(path_str):
    """URL-encode a relative filesystem path for use in an href/src (some
    resvg-test-suite files start with `#`, which would otherwise be read as
    a URL fragment)."""
    return "/".join(urllib.parse.quote(part, safe="") for part in path_str.split("/"))


# --------------------------------------------------------------------------
# step 1: run the harness (or reuse an earlier run)
# --------------------------------------------------------------------------


def run_harness(args, run_dir, renders_dir, routes, jobs):
    csvs = [run_dir / ("resvg_%s.csv" % r) for r in routes]
    if args.reuse and all(p.is_file() for p in csvs) and renders_dir.is_dir():
        print("-- --reuse: found %s, skipping run_corpora.py" % run_dir)
        return None
    cmd = [
        sys.executable, str(REPO / "tests" / "run_corpora.py"),
        "--no-worst",
        "--corpus", CORPUS, "--route", args.route,
        "--keep-renders", str(renders_dir),
        "--out", str(run_dir),
        "--bin", args.bin,
        "--tol", str(args.tol), "--threshold", str(args.threshold),
    ]
    if args.render_width is None:
        cmd.append("--fast")
    else:
        cmd += ["--width", str(args.render_width), "--jobs", str(jobs)]
    print("-- running: %s" % " ".join(cmd), flush=True)
    start = time.perf_counter()
    subprocess.run(cmd, check=True)
    return time.perf_counter() - start


# --------------------------------------------------------------------------
# step 2: diff PNGs
# --------------------------------------------------------------------------


def diff_image(ref_png, ours_png, gain):
    """Per-pixel max-channel diff of the two images composited over white,
    amplified by `gain` and rendered as white-tinted-red. Returns None if
    either PNG is missing or unreadable, or the sizes disagree (a
    size-mismatch row already says so via its status badge)."""
    ref = load_rgba(ref_png)
    ours = load_rgba(ours_png)
    if ref is None or ours is None or ref.shape != ours.shape:
        return None
    ref_w = over_white(ref).astype(np.int32)
    ours_w = over_white(ours).astype(np.int32)
    d = np.abs(ref_w - ours_w).max(axis=2)
    v = np.clip(d * gain, 0, 255).astype(np.uint8)
    panel = np.full(d.shape + (3,), 255, dtype=np.uint8)
    panel[:, :, 1] = 255 - v
    panel[:, :, 2] = 255 - v
    return panel


def write_diffs(rows_by_route, renders_dir, gain, jobs, reuse):
    """For every row with both a .ref.png and .ours.png, write a .diff.png
    next to them (skip if --reuse and it already exists). Returns elapsed
    seconds and how many were (re)written."""
    jobs_list = []
    for route, rows in rows_by_route.items():
        base_dir = renders_dir / CORPUS / route
        for row in rows:
            base = base_dir / row["file"]
            ref_png = Path(str(base) + ".ref.png")
            ours_png = Path(str(base) + ".ours.png")
            diff_png = Path(str(base) + ".diff.png")
            if not (ref_png.is_file() and ours_png.is_file()):
                continue
            if reuse and diff_png.is_file():
                continue
            jobs_list.append((ref_png, ours_png, diff_png))

    def task(item):
        ref_png, ours_png, diff_png = item
        panel = diff_image(ref_png, ours_png, gain)
        if panel is not None:
            Image.fromarray(panel, "RGB").save(diff_png)

    start = time.perf_counter()
    if jobs_list:
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            list(pool.map(task, jobs_list))
    return time.perf_counter() - start, len(jobs_list)


# --------------------------------------------------------------------------
# step 3: data.json + per-directory table
# --------------------------------------------------------------------------


def read_rows(run_dir, routes):
    out = {}
    for route in routes:
        path = run_dir / ("resvg_%s.csv" % route)
        with path.open(newline="", encoding="utf-8") as fh:
            out[route] = list(csv.DictReader(fh))
    return out


def pctf(row, key):
    try:
        return round(float(row[key]) * 100.0, 3)
    except (KeyError, ValueError):
        return None


def build_cards(rows_by_route, renders_dir, out_dir, svg_root):
    cards = []
    for route, rows in rows_by_route.items():
        render_base = renders_dir / CORPUS / route
        for row in rows:
            rel = row["file"]
            top = row["dir"].split("/")[0] if row["dir"] != "(root)" else "(root)"
            base = render_base / rel
            ref_png = Path(str(base) + ".ref.png")
            ours_png = Path(str(base) + ".ours.png")
            diff_png = Path(str(base) + ".diff.png")
            svg_path = svg_root / rel
            cards.append({
                "route": route,
                "file": rel,
                "top": top,
                "dir": row["dir"],
                "status": row["status"],
                "group": STATUS_GROUP.get(row["status"], "error"),
                "exact": pctf(row, "exact"),
                "within": pctf(row, "within"),
                "max_d": int(row["max_d"]) if row["max_d"] not in ("", None) else None,
                "size": row["size"],
                "ours_rc": row["ours_rc"],
                "ours_err": row["ours_err"] or row["ref_err"] or row["usvg_err"],
                "ref": urlpath(os.path.relpath(ref_png, out_dir)) if ref_png.is_file() else None,
                "ours": urlpath(os.path.relpath(ours_png, out_dir)) if ours_png.is_file() else None,
                "diff": urlpath(os.path.relpath(diff_png, out_dir)) if diff_png.is_file() else None,
                "svg": urlpath(os.path.relpath(svg_path, out_dir)),
            })
    return cards


def dir_table(rows):
    """[(top_dir, files, pass, pass_pct)], sorted by pass_pct ascending."""
    by_top = {}
    for row in rows:
        top = row["dir"].split("/")[0] if row["dir"] != "(root)" else "(root)"
        d = by_top.setdefault(top, {"files": 0, "pass": 0})
        d["files"] += 1
        if row["status"] == PASS_STATUS:
            d["pass"] += 1
    out = []
    for top, d in by_top.items():
        pct = (d["pass"] / d["files"] * 100.0) if d["files"] else 0.0
        out.append((top, d["files"], d["pass"], pct))
    out.sort(key=lambda t: t[3])
    return out


# --------------------------------------------------------------------------
# step 4: index.html
# --------------------------------------------------------------------------


def render_dir_tables(rows_by_route):
    parts = []
    for route, rows in rows_by_route.items():
        parts.append('<div class="dirtable-block">')
        parts.append('<h3>%s route</h3>' % route)
        parts.append('<table class="dirtable"><thead><tr>'
                      '<th>directory</th><th>files</th><th>pass</th><th>pass%</th>'
                      '</tr></thead><tbody>')
        for top, files, passed, pct in dir_table(rows):
            parts.append(
                '<tr><td>%s</td><td>%d</td><td>%d</td><td>%.1f%%</td></tr>'
                % (top, files, passed, pct)
            )
        parts.append('</tbody></table>')
        parts.append('</div>')
    return "\n".join(parts)


INDEX_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>microsvg corpus gallery</title>
<style>
  :root { --thumb: %(thumb_width)dpx; }
  body { font-family: -apple-system, system-ui, sans-serif; margin: 1.5rem; color: #222; background: #fff; }
  h1 { font-size: 1.4rem; margin-bottom: .2rem; }
  h3 { font-size: .95rem; margin: .8rem 0 .3rem; }
  .meta { color: #666; font-size: .85rem; margin-bottom: 1rem; }
  .dirtables { display: flex; gap: 2rem; flex-wrap: wrap; margin-bottom: 1rem; }
  table.dirtable { border-collapse: collapse; font-size: .8rem; }
  table.dirtable th, table.dirtable td { border: 1px solid #ddd; padding: .2rem .5rem; text-align: right; }
  table.dirtable th:first-child, table.dirtable td:first-child { text-align: left; }
  .controls { display: flex; flex-wrap: wrap; gap: .6rem; align-items: center;
              margin: 1rem 0; padding: .6rem; background: #f4f4f4; border-radius: 6px;
              position: sticky; top: 0; z-index: 5; }
  .controls select, .controls input { font-size: .85rem; padding: .25rem .4rem; }
  .controls input[type=text] { width: 16rem; }
  #countLabel { font-size: .82rem; color: #444; margin-left: auto; }
  #cards { display: flex; flex-wrap: wrap; gap: .8rem; }
  .card { border: 1px solid #ddd; border-radius: 6px; padding: .6rem; width: calc(var(--thumb) * 3 + 2.4rem);
          background: #fafafa; }
  .card.fail, .card.error { border-color: #c0392b; background: #fdecea; }
  .card.unsupported { border-color: #b8860b; background: #fdf6e3; }
  .card.size-mismatch { border-color: #6a5acd; background: #f1eefc; }
  .card h2 { font-size: .85rem; margin: 0 0 .3rem; word-break: break-all; font-weight: 600; }
  .badge { display: inline-block; white-space: nowrap; font-size: .68rem; padding: .05rem .4rem;
           border-radius: 3px; color: #fff; background: #2d8a4e; vertical-align: middle; margin-left: .3rem; }
  .card.fail .badge, .card.error .badge { background: #c0392b; }
  .card.unsupported .badge { background: #b8860b; }
  .card.size-mismatch .badge { background: #6a5acd; }
  .metrics { font-family: ui-monospace, Menlo, monospace; font-size: .72rem; color: #444; margin: .3rem 0; }
  .err { color: #c0392b; font-size: .72rem; margin: .3rem 0; word-break: break-all; }
  .imgs { display: flex; gap: .3rem; }
  .imgs figure { margin: 0; cursor: zoom-in; }
  .imgs figcaption { font-size: .65rem; color: #666; text-align: center; }
  .imgs img { background:
    repeating-conic-gradient(#eee 0%% 25%%, #fff 0%% 50%%) 50%% / 10px 10px;
    border: 1px solid #ccc; width: var(--thumb); height: var(--thumb); object-fit: contain; }
  .missing { width: var(--thumb); height: var(--thumb); border: 1px dashed #ccc;
             display: flex; align-items: center; justify-content: center; font-size: .65rem; color: #999; }
  .svglink { font-size: .72rem; }
  .overlay { position: fixed; inset: 0; background: rgba(0,0,0,.85); display: flex;
             align-items: center; justify-content: center; gap: 1rem; z-index: 50; padding: 2rem; }
  .overlay.hidden { display: none; }
  .overlay figure { margin: 0; }
  .overlay img { max-width: 30vw; max-height: 80vh; background:
    repeating-conic-gradient(#eee 0%% 25%%, #fff 0%% 50%%) 50%% / 10px 10px; border: 1px solid #666; }
  .overlay figcaption { color: #eee; text-align: center; font-size: .8rem; margin-top: .3rem; }
  .overlay-close { position: fixed; top: 1rem; right: 1.5rem; color: #fff; font-size: 1.6rem;
                   cursor: pointer; z-index: 51; }
</style>
</head>
<body>
<h1>microsvg corpus gallery — resvg-test-suite</h1>
<div class="meta" id="metaLine">%(meta_line)s</div>
<div class="dirtables">%(dir_tables)s</div>
<div class="controls">
  <label>dir <select id="topFilter"><option value="">(all)</option></select></label>
  <label>subdir <select id="subFilter"><option value="">(all)</option></select></label>
  <label>status <select id="statusFilter">
    <option value="">(all)</option>
    <option value="pass">pass</option>
    <option value="fail">fail</option>
    <option value="error">error</option>
    <option value="unsupported">unsupported</option>
    <option value="size-mismatch">size-mismatch</option>
  </select></label>
  <label id="routeLabel" style="display:none">route <select id="routeFilter"></select></label>
  <label>sort <select id="sortSelect">
    <option value="worst">worst first (within-8)</option>
    <option value="path">path</option>
  </select></label>
  <input id="searchBox" type="text" placeholder="search path substring">
  <span id="countLabel"></span>
</div>
<div id="cards"></div>
<div class="overlay hidden" id="overlay">
  <span class="overlay-close" id="overlayClose">&times;</span>
  <figure><img id="ovRef"><figcaption>reference (resvg)</figcaption></figure>
  <figure><img id="ovOurs"><figcaption>ours (microsvg)</figcaption></figure>
  <figure><img id="ovDiff"><figcaption>diff (&times;%(diff_gain)d)</figcaption></figure>
</div>
<script>
const state = { data: [], top: "", sub: "", status: "", route: "", q: "", sort: "worst" };

function badgeText(c) {
  if (c.status === "pass" || c.status === "fail") return c.status.toUpperCase();
  return c.status;
}

function figureOrMissing(src, alt) {
  if (!src) return '<div class="missing">n/a</div>';
  return '<img src="' + src + '" alt="' + alt + '" loading="lazy">';
}

function cardHtml(c, idx) {
  const within = c.within === null ? "-" : c.within.toFixed(3) + "%%";
  const exact = c.exact === null ? "-" : c.exact.toFixed(3) + "%%";
  const maxd = c.max_d === null ? "-" : c.max_d;
  let errHtml = "";
  if (c.ours_err) {
    errHtml = '<div class="err">rc=' + c.ours_rc + ': ' + c.ours_err.replace(/</g, "&lt;") + '</div>';
  } else if (c.ours_rc !== "" && c.ours_rc !== "0") {
    errHtml = '<div class="err">rc=' + c.ours_rc + '</div>';
  }
  return (
    '<div class="card ' + c.group + '" data-idx="' + idx + '">' +
    '<h2>' + c.file + (c.route ? ' <span style="color:#888;font-weight:400">(' + c.route + ')</span>' : '') +
    ' <span class="badge">' + badgeText(c) + '</span></h2>' +
    '<div class="metrics">size ' + (c.size || "-") + ' &middot; within-8 ' + within +
    ' &middot; exact ' + exact + ' &middot; max_d ' + maxd + '</div>' +
    errHtml +
    '<div class="imgs">' +
    '<figure data-kind="ref"><figcaption>ref</figcaption>' + figureOrMissing(c.ref, "reference") + '</figure>' +
    '<figure data-kind="ours"><figcaption>ours</figcaption>' + figureOrMissing(c.ours, "ours") + '</figure>' +
    '<figure data-kind="diff"><figcaption>diff</figcaption>' + figureOrMissing(c.diff, "diff") + '</figure>' +
    '</div>' +
    '<div class="svglink"><a href="' + c.svg + '" target="_blank" rel="noopener">SVG source</a></div>' +
    '</div>'
  );
}

function populateSelect(sel, values, keep) {
  const cur = keep ? sel.value : "";
  sel.innerHTML = '<option value="">(all)</option>' +
    values.map(v => '<option value="' + v + '">' + v + '</option>').join("");
  if (values.includes(cur)) sel.value = cur;
}

function applyFilters() {
  let rows = state.data;
  if (state.route) rows = rows.filter(c => c.route === state.route);
  if (state.top) rows = rows.filter(c => c.top === state.top);
  if (state.sub) rows = rows.filter(c => c.dir === state.sub);
  if (state.status) rows = rows.filter(c => c.group === state.status);
  if (state.q) {
    const q = state.q.toLowerCase();
    rows = rows.filter(c => c.file.toLowerCase().includes(q));
  }
  rows = rows.slice();
  if (state.sort === "worst") {
    rows.sort((a, b) => (a.within === null ? -1 : a.within) - (b.within === null ? -1 : b.within));
  } else {
    rows.sort((a, b) => a.file.localeCompare(b.file) || a.route.localeCompare(b.route));
  }
  return rows;
}

function render() {
  const rows = applyFilters();
  document.getElementById("countLabel").textContent = rows.length + " / " + state.data.length + " files";
  const html = rows.map(c => cardHtml(c, state.data.indexOf(c))).join("");
  document.getElementById("cards").innerHTML = html;
}

function openOverlay(c) {
  document.getElementById("ovRef").src = c.ref || "";
  document.getElementById("ovOurs").src = c.ours || "";
  document.getElementById("ovDiff").src = c.diff || "";
  document.getElementById("overlay").classList.remove("hidden");
}

function closeOverlay() {
  document.getElementById("overlay").classList.add("hidden");
}

async function init() {
  const resp = await fetch("data.json");
  state.data = await resp.json();

  const tops = [...new Set(state.data.map(c => c.top))].sort();
  const subs = [...new Set(state.data.map(c => c.dir))].sort();
  const routes = [...new Set(state.data.map(c => c.route))].sort();
  populateSelect(document.getElementById("topFilter"), tops);
  populateSelect(document.getElementById("subFilter"), subs);
  if (routes.length > 1) {
    document.getElementById("routeLabel").style.display = "";
    populateSelect(document.getElementById("routeFilter"), routes);
  }

  document.getElementById("topFilter").addEventListener("change", e => { state.top = e.target.value; render(); });
  document.getElementById("subFilter").addEventListener("change", e => { state.sub = e.target.value; render(); });
  document.getElementById("statusFilter").addEventListener("change", e => { state.status = e.target.value; render(); });
  document.getElementById("routeFilter").addEventListener("change", e => { state.route = e.target.value; render(); });
  document.getElementById("sortSelect").addEventListener("change", e => { state.sort = e.target.value; render(); });
  document.getElementById("searchBox").addEventListener("input", e => { state.q = e.target.value; render(); });

  document.getElementById("cards").addEventListener("click", e => {
    const card = e.target.closest(".card");
    if (!card) return;
    const fig = e.target.closest("figure");
    if (!fig) return;
    const idx = parseInt(card.dataset.idx, 10);
    openOverlay(state.data[idx]);
  });
  document.getElementById("overlayClose").addEventListener("click", closeOverlay);
  document.getElementById("overlay").addEventListener("click", e => {
    if (e.target.id === "overlay") closeOverlay();
  });
  document.addEventListener("keydown", e => { if (e.key === "Escape") closeOverlay(); });

  render();
}

init();
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--out", default=str(REPO / "tests" / "out" / "gallery"),
                     help="output directory (default tests/out/gallery)")
    ap.add_argument("--width", type=int, default=150,
                     help="thumbnail CSS display width in px (default 150); "
                          "does not change the render resolution")
    ap.add_argument("--render-width", type=int, default=None,
                     help="render the corpus at this width instead of the "
                          "harness's --fast width (thin features vanish at "
                          "the default 100px); passed to run_corpora.py's "
                          "--width, without --fast. Default: unset, same "
                          "--fast behaviour as before")
    ap.add_argument("--route", choices=["direct", "usvg", "both"], default="both",
                     help="which route(s) to run/show (default both)")
    ap.add_argument("--reuse", action="store_true",
                     help="reuse an existing run/renders under --out instead "
                          "of re-running run_corpora.py")
    ap.add_argument("--bin", default=str(RC.DEFAULT_BIN), help="microsvg binary")
    ap.add_argument("--tol", type=int, default=8)
    ap.add_argument("--threshold", type=float, default=0.99)
    ap.add_argument("--diff-gain", type=int, default=8,
                     help="diff-image amplification factor (default 8)")
    ap.add_argument("--jobs", type=int, default=None,
                     help="parallel workers for diff generation (default hw.ncpu)")
    args = ap.parse_args()

    out_dir = Path(args.out).resolve()
    run_dir = out_dir / "run"
    renders_dir = out_dir / "renders"
    out_dir.mkdir(parents=True, exist_ok=True)

    routes = list(ROUTES) if args.route == "both" else [args.route]
    jobs = args.jobs or (os.cpu_count() or 4)

    grand_start = time.perf_counter()
    harness_elapsed = run_harness(args, run_dir, renders_dir, routes, jobs)

    rows_by_route = read_rows(run_dir, routes)
    total_rows = sum(len(v) for v in rows_by_route.values())

    diff_elapsed, n_diffs = write_diffs(rows_by_route, renders_dir, args.diff_gain, jobs, args.reuse)

    svg_root = RC.CORPORA_DIR / RC.CORPORA[CORPUS][0]
    cards = build_cards(rows_by_route, renders_dir, out_dir, svg_root)

    status_counts = {}
    for c in cards:
        status_counts[c["status"]] = status_counts.get(c["status"], 0) + 1

    data_path = out_dir / "data.json"
    data_path.write_text(json.dumps(cards, separators=(",", ":")), encoding="utf-8")

    meta_bits = [
        "generated %s" % time.strftime("%Y-%m-%d %H:%M:%S"),
        "corpus %s" % CORPUS,
        "route(s) %s" % ", ".join(routes),
        "%d cards" % total_rows,
        "bin %s" % args.bin,
    ]
    meta_bits.append(
        "status: " + ", ".join("%s %d" % (k, v) for k, v in sorted(status_counts.items()))
    )
    meta_line = " &middot; ".join(meta_bits)

    html = INDEX_TEMPLATE % {
        "thumb_width": args.width,
        "meta_line": meta_line,
        "dir_tables": render_dir_tables(rows_by_route),
        "diff_gain": args.diff_gain,
    }
    (out_dir / "index.html").write_text(html, encoding="utf-8")

    total_elapsed = time.perf_counter() - grand_start
    print(
        "\ncards: %d (harness %s, diffs written %d in %.1fs)"
        % (total_rows, "%.1fs" % harness_elapsed if harness_elapsed is not None else "reused",
           n_diffs, diff_elapsed)
    )
    print("status counts: %s" % status_counts)
    print("wrote %s (index.html + data.json + run/ + renders/)" % out_dir)
    print("total runtime: %.1fs" % total_elapsed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
