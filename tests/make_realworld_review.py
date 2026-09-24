#!/usr/bin/env python3
"""Static side-by-side review page for the realworld corpus (T103):
ours | Chromium | matplotlib's own PNG baseline (mpl-tests files only, when
tests/corpora/matplotlib-baseline-png has been fetched), grouped by source
type, worst within-8-vs-Chromium first. Same style as make_human_review.py.

    python3 tests/make_realworld_review.py
    python3 tests/make_realworld_review.py --out tests/out/realworld_review --group tikz

Also writes results.csv (per file: status, within-8 vs Chromium and vs the
matplotlib PNG, our render time) and summary.md (per-group table, slowest
files, failures) next to index.html. Our renders run one at a time so the
timings are not skewed by parallel jobs.
"""
import argparse
import csv
import shutil
import statistics
import sys
from collections import defaultdict
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests"))

import run_corpora as rc  # noqa: E402  (path must be set up first)
from run_tests import compare, load_rgba  # noqa: E402

ROOT = rc.CORPORA_DIR / "realworld"
MPL_PNG = rc.CORPORA_DIR / "matplotlib-baseline-png"
OUT_DIR = REPO / "tests" / "out" / "realworld_review"
TOL = 8


def group_of(rel):
    return rel.split("/", 1)[0]


def render_ours(svg, binary, dest, width):
    """(error or None, ms)."""
    dest.unlink(missing_ok=True)
    Path(str(dest) + ".warnings.txt").unlink(missing_ok=True)
    code, ms, err, timed_out = rc.run_cmd([str(binary), str(svg), str(dest), "--width", str(width)])
    if timed_out or code not in (0, 2):  # 2 = PNG written, with warnings
        return (err or "rc=%s" % code), ms
    return None, ms


def score(ref_png, ours_png):
    """within-8 fraction, or a reason string. Chromium's height can round 1 px
    differently from ours (see run_corpora.render_one); compare common rows."""
    ref, ours = load_rgba(ref_png), load_rgba(ours_png)
    assert ref is not None and ours is not None, (ref_png, ours_png)
    if ref.shape[1] != ours.shape[1] or abs(ref.shape[0] - ours.shape[0]) > 1:
        return "size %dx%d vs ours %dx%d" % (ref.shape[1], ref.shape[0], ours.shape[1], ours.shape[0])
    h = min(ref.shape[0], ours.shape[0])
    return compare(ref[:h], ours[:h], TOL)[0]["within"]


def mpl_png_for(rel, width, dest):
    """Resize matplotlib's baseline PNG to `width` into dest; False if none."""
    if not rel.startswith("mpl-tests/"):
        return False
    src = MPL_PNG / Path(rel[len("mpl-tests/"):]).with_suffix(".png")
    if not src.is_file():
        return False
    with Image.open(src) as im:
        h = max(1, round(im.height * width / im.width))
        im.convert("RGBA").resize((width, h), Image.LANCZOS).save(dest)
    return True


def build(files, binary, width, jobs, out):
    chrome, tmpdir = rc.prerender_chrome_refs("realworld", files, width, jobs)
    rows = []
    try:
        for svg in files:
            rel = svg.relative_to(ROOT).as_posix()
            flat = rel.replace("/", "__")
            row = {"file": rel, "group": group_of(rel), "ours": flat + ".ours.png",
                   "chrome": flat + ".chrome.png", "mpl": "", "ours_err": "", "chrome_err": "",
                   "ms": 0.0, "within_chrome": "", "within_mpl": "", "note": chrome[rel]["note"]}
            err, row["ms"] = render_ours(svg, binary, out / row["ours"], width)
            row["ours_err"] = err or ""
            png = chrome[rel]["png"]
            if png is None:
                row["chrome_err"] = chrome[rel]["err"]
            else:
                shutil.copy2(png, out / row["chrome"])
            if mpl_png_for(rel, width, out / (flat + ".mpl.png")):
                row["mpl"] = flat + ".mpl.png"
            if not row["ours_err"]:
                if png is not None:
                    row["within_chrome"] = score(out / row["chrome"], out / row["ours"])
                if row["mpl"]:
                    row["within_mpl"] = score(out / row["mpl"], out / row["ours"])
            rows.append(row)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return rows


def fmt(v):
    return "%.1f%%" % (v * 100) if isinstance(v, float) else (v or "–")


def write_csv(rows, out):
    fields = ["file", "group", "ours_err", "chrome_err", "within_chrome", "within_mpl", "ms", "note"]
    with (out / "results.csv").open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fields, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({**r, "within_chrome": ("%.6f" % r["within_chrome"]) if isinstance(r["within_chrome"], float) else r["within_chrome"],
                        "within_mpl": ("%.6f" % r["within_mpl"]) if isinstance(r["within_mpl"], float) else r["within_mpl"],
                        "ms": "%.1f" % r["ms"]})


def summary(rows, width):
    by = defaultdict(list)
    for r in rows:
        by[r["group"]].append(r)
    lines = ["# realworld corpus: lean-svg vs Chromium (width %d, tol %d)\n" % (width, TOL),
             "| group | files | lean-svg errors | chromium errors | median within-8 | mean within-8 | files >= 99% | median ms | max ms |",
             "|---|---|---|---|---|---|---|---|---|"]
    for g in sorted(by) + ["ALL"]:
        rs = rows if g == "ALL" else by[g]
        w = [r["within_chrome"] for r in rs if isinstance(r["within_chrome"], float)]
        ms = [r["ms"] for r in rs]
        lines.append("| %s | %d | %d | %d | %s | %s | %d | %.0f | %.0f |" % (
            g, len(rs), sum(1 for r in rs if r["ours_err"]), sum(1 for r in rs if r["chrome_err"]),
            fmt(statistics.median(w)) if w else "–", fmt(statistics.mean(w)) if w else "–",
            sum(1 for x in w if x >= 0.99), statistics.median(ms), max(ms)))
    wm = [(r["within_mpl"], r["within_chrome"]) for r in rows if isinstance(r["within_mpl"], float) and isinstance(r["within_chrome"], float)]
    if wm:
        lines.append("\nmpl-tests with a matplotlib PNG baseline: %d; median within-8 ours vs mpl PNG %s, ours vs Chromium %s\n"
                     % (len(wm), fmt(statistics.median([a for a, _ in wm])), fmt(statistics.median([b for _, b in wm]))))
    lines += ["\n## slowest 15 (our render, sequential)\n", "| file | ms |", "|---|---|"]
    lines += ["| %s | %.0f |" % (r["file"], r["ms"]) for r in sorted(rows, key=lambda r: -r["ms"])[:15]]
    lines += ["\n## lean-svg errors / refusals\n"]
    lines += ["- %s: %s" % (r["file"], r["ours_err"]) for r in rows if r["ours_err"]] or ["none"]
    lines += ["\n## chromium failures / not comparable\n"]
    lines += ["- %s: %s" % (r["file"], r["chrome_err"] or r["within_chrome"]) for r in rows
              if r["chrome_err"] or isinstance(r["within_chrome"], str) and r["within_chrome"]] or ["none"]
    return "\n".join(lines) + "\n"


PAGE_HEAD = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>lean-svg realworld review</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; color: #222; }
  h1 { font-size: 1.4rem; } h2.group { font-size: 1.15rem; margin-top: 2.5rem; border-bottom: 1px solid #ccc; }
  .meta { color: #666; font-size: .9rem; margin-bottom: 1.5rem; }
  table.sum { border-collapse: collapse; font-size: .85rem; margin-bottom: 1rem; }
  table.sum td, table.sum th { border: 1px solid #ddd; padding: .2rem .5rem; text-align: right; }
  table.sum td:first-child { text-align: left; }
  .card { border: 1px solid #ddd; border-radius: 6px; padding: 1rem;
          margin-bottom: 1.5rem; background: #fafafa; }
  .card h3 { font-size: 1rem; margin: 0 0 .25rem; font-family: ui-monospace, Menlo, monospace; }
  .reason { color: #666; font-size: .85rem; margin: 0 0 .5rem; }
  .imgs { display: flex; gap: .5rem; flex-wrap: wrap; align-items: flex-start; }
  .imgs figure { margin: 0; }
  .imgs figcaption { font-size: .75rem; color: #666; text-align: center; }
  .imgs img { background: #fff; border: 1px solid #ccc; max-width: 320px; }
  .err { color: #c0392b; font-size: .8rem; width: 280px; }
  nav a { margin-right: .8rem; }
</style>
</head>
<body>
"""


def esc(text):
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def figure(out, name, err, caption):
    if not err and name and (out / name).is_file():
        return '<figure><img loading="lazy" src="%s" alt="%s"><figcaption>%s</figcaption></figure>\n' % (esc(name), esc(caption), esc(caption))
    return '<figure><div class="err">%s: %s</div><figcaption>%s</figcaption></figure>\n' % (esc(caption), esc(err or "no image"), esc(caption))


def write_page(rows, width, out):
    by = defaultdict(list)
    for r in rows:
        by[r["group"]].append(r)
    parts = [PAGE_HEAD, "<h1>lean-svg realworld review</h1>\n",
             '<div class="meta">%d files, rendered at %d px. Per file: ours (lean-svg) | Chromium | '
             "matplotlib's own Agg PNG baseline (mpl-tests only; not a render of this SVG, so text and "
             "antialiasing differ by design). Within each group, worst within-%d vs Chromium first. "
             "Sources and licences: <code>tests/corpora/realworld/SOURCES.csv</code>.</div>\n" % (len(rows), width, TOL)]
    parts.append("<nav>" + "".join('<a href="#g-%s">%s (%d)</a>' % (esc(g), esc(g), len(by[g])) for g in sorted(by)) + "</nav>\n")
    parts.append('<table class="sum"><tr><th>group</th><th>files</th><th>our errors</th><th>median within-8</th><th>&ge; 99%</th></tr>\n')
    for g in sorted(by):
        w = [r["within_chrome"] for r in by[g] if isinstance(r["within_chrome"], float)]
        parts.append("<tr><td>%s</td><td>%d</td><td>%d</td><td>%s</td><td>%d</td></tr>\n" % (
            esc(g), len(by[g]), sum(1 for r in by[g] if r["ours_err"]),
            fmt(statistics.median(w)) if w else "–", sum(1 for x in w if x >= 0.99)))
    parts.append("</table>\n")
    key = lambda r: r["within_chrome"] if isinstance(r["within_chrome"], float) else -1.0
    for g in sorted(by):
        parts.append('<h2 class="group" id="g-%s">%s</h2>\n' % (esc(g), esc(g)))
        for r in sorted(by[g], key=key):
            parts.append('<div class="card">\n<h3>%s</h3>\n' % esc(r["file"]))
            bits = ["within-8 vs Chromium %s" % fmt(r["within_chrome"]), "%.0f ms" % r["ms"]]
            if r["mpl"]:
                bits.append("vs matplotlib PNG %s" % fmt(r["within_mpl"]))
            if r["note"]:
                bits.append(r["note"])
            parts.append('<p class="reason">%s</p>\n<div class="imgs">\n' % esc(" · ".join(bits)))
            parts.append(figure(out, r["ours"], r["ours_err"], "ours (lean-svg)"))
            parts.append(figure(out, r["chrome"], r["chrome_err"], "chromium"))
            if r["mpl"]:
                parts.append(figure(out, r["mpl"], "", "matplotlib PNG baseline"))
            parts.append("</div>\n</div>\n")
    parts.append("</body>\n</html>\n")
    (out / "index.html").write_text("".join(parts), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(OUT_DIR), help="output directory for the page, PNGs, CSV and summary")
    ap.add_argument("--bin", default=str(rc.DEFAULT_BIN), help="path to the lean-svg binary")
    ap.add_argument("--width", type=int, default=rc.CORPORA["realworld"][2])
    ap.add_argument("--group", action="append", default=None, help="only these top-level dirs (repeatable)")
    ap.add_argument("--jobs", type=int, default=4, help="concurrent chromium pages")
    args = ap.parse_args()
    out = Path(args.out).expanduser().resolve()
    binary = Path(args.bin).resolve()
    assert binary.is_file(), "lean-svg binary not found at %s (build it first)" % binary
    files = sorted(p for p in ROOT.glob("**/*.svg") if p.is_file())
    if args.group:
        files = [p for p in files if group_of(p.relative_to(ROOT).as_posix()) in args.group]
    assert files, "no files selected"
    if not MPL_PNG.is_dir():
        print("note: %s missing, no matplotlib PNG column (run src/fetch_matplotlib_tests.sh)" % MPL_PNG, file=sys.stderr)
    out.mkdir(parents=True, exist_ok=True)
    rows = build(files, binary, args.width, args.jobs, out)
    write_csv(rows, out)
    (out / "summary.md").write_text(summary(rows, args.width), encoding="utf-8")
    write_page(rows, args.width, out)
    print("wrote %d card(s) to %s/index.html (+ results.csv, summary.md)" % (len(rows), out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
