#!/usr/bin/env python3
"""Static side-by-side review page for the tests/criteria.csv rows with no
known-correct oracle (reference == human): ours | resvg-test-suite's own PNG
| Chromium, so Rowan can look and fill tests/human_verdicts.csv by hand
(file,verdict,note ; verdict pass/fail).

Skips any file that already has a verdict in tests/human_verdicts.csv, so
re-running only builds cards for what is still unreviewed.

    python3 tests/make_human_review.py
    python3 tests/make_human_review.py --out tests/out/human_review --limit 20
"""
import argparse
import csv
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests"))

import run_corpora as rc  # noqa: E402  (path must be set up first)
import render_chrome  # noqa: E402

CRITERIA = REPO / "tests" / "criteria.csv"
VERDICTS = REPO / "tests" / "human_verdicts.csv"
OUT_DIR = REPO / "tests" / "out" / "human_review"
WIDTH = rc.CORPORA["resvg"][2]  # 200px, same default as the resvg-suite corpus


def reviewed_files():
    if not VERDICTS.is_file():
        return set()
    with VERDICTS.open(newline="", encoding="utf-8") as fh:
        return {r["file"] for r in csv.DictReader(fh) if r.get("verdict") in ("pass", "fail")}


def human_rows(limit):
    with CRITERIA.open(newline="", encoding="utf-8") as fh:
        rows = [r for r in csv.DictReader(fh) if r["reference"] == "human"]
    done = reviewed_files()
    rows = [r for r in rows if r["file"] not in done]
    return rows[:limit] if limit else rows


def render_ours(svg, binary, dest):
    """None on success, else an error string."""
    rc_code, _, err, timed_out = rc.run_cmd(
        [str(binary), str(svg), str(dest), "--width", str(WIDTH)]
    )
    if timed_out or rc_code not in (0, 2):  # T98b: 2 = PNG written, with warnings
        return err or "rc=%s" % rc_code
    return None


def build_cards(rows, binary, jobs):
    """Render ours/suite/chrome for every row, write PNGs to OUT_DIR, return
    the list of card dicts write_page needs."""
    root = rc.CORPORA_DIR / rc.CORPORA["resvg"][0]
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    tmpdir = Path(tempfile.mkdtemp(prefix="human_review_"))
    try:
        pairs, by_stem = [], {}
        for i, row in enumerate(rows):
            svg = root / row["file"]
            stem = "%06d" % i
            by_stem[stem] = row
            src = svg
            stripped = rc.strip_external_refs(svg)
            if stripped is not None and stripped[1] > 0:
                src = tmpdir / (stem + "_src.svg")
                src.write_text(stripped[0], encoding="utf-8")
            pairs.append((src, stem))

        chrome_rendered = render_chrome.render_batch(pairs, tmpdir / "chrome", WIDTH, jobs)

        cards = []
        for stem, row in by_stem.items():
            svg = root / row["file"]
            flat = row["file"].replace("/", "__")
            ours_dest = OUT_DIR / (flat + ".ours.png")
            suite_dest = OUT_DIR / (flat + ".suite.png")
            chrome_dest = OUT_DIR / (flat + ".chrome.png")
            for stale in (ours_dest, suite_dest, chrome_dest):
                stale.unlink(missing_ok=True)

            ours_err = render_ours(svg, binary, ours_dest)
            suite_err = rc.suite_ref_png(svg, WIDTH, suite_dest)
            chrome_png = chrome_rendered.get(stem)
            if chrome_png is not None and Path(chrome_png).is_file():
                shutil.copy2(chrome_png, chrome_dest)
                chrome_err = None
            else:
                chrome_err = "chromium could not render this file"

            cards.append({
                "file": row["file"],
                "reason": row["reason"],
                "ours": (flat + ".ours.png", ours_err),
                "suite": (flat + ".suite.png", suite_err),
                "chrome": (flat + ".chrome.png", chrome_err),
            })
        return sorted(cards, key=lambda c: c["file"])
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


PAGE_HEAD = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>lean-svg human review</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; color: #222; }
  h1 { font-size: 1.4rem; }
  .meta { color: #666; font-size: .9rem; margin-bottom: 1.5rem; }
  .card { border: 1px solid #ddd; border-radius: 6px; padding: 1rem;
          margin-bottom: 1.5rem; background: #fafafa; }
  .card h2 { font-size: 1rem; margin: 0 0 .25rem; font-family: ui-monospace, Menlo, monospace; }
  .reason { color: #666; font-size: .85rem; margin: 0 0 .5rem; }
  .csvline { font-family: ui-monospace, Menlo, monospace; font-size: .8rem;
             background: #eee; padding: .2rem .4rem; border-radius: 3px; }
  .imgs { display: flex; gap: .5rem; flex-wrap: wrap; align-items: flex-start; }
  .imgs figure { margin: 0; }
  .imgs figcaption { font-size: .75rem; color: #666; text-align: center; }
  .imgs img { background: #fff; border: 1px solid #ccc; max-width: 280px; }
  .err { color: #c0392b; font-size: .8rem; width: 280px; }
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


def write_page(cards):
    parts = [PAGE_HEAD, "<h1>lean-svg human review</h1>\n"]
    parts.append(
        '<div class="meta">%d file(s) with no known-correct oracle in '
        "resvg-test-suite/results.csv. For each, decide whether lean-svg's "
        "render (left) is acceptable, then add a row to "
        '<code>tests/human_verdicts.csv</code>: '
        '<code>file,pass|fail,note</code>.</div>\n' % len(cards)
    )
    for c in cards:
        parts.append('<div class="card">\n')
        parts.append("<h2>%s</h2>\n" % esc(c["file"]))
        parts.append('<p class="reason">%s</p>\n' % esc(c["reason"]))
        parts.append(
            '<p class="csvline">%s,pass,\n%s,fail,&lt;why&gt;</p>\n'
            % (esc(c["file"]), esc(c["file"]))
        )
        parts.append('<div class="imgs">\n')
        for key, caption in (
            ("ours", "ours (lean-svg)"),
            ("suite", "resvg-test-suite PNG"),
            ("chrome", "chromium"),
        ):
            name, err = c[key]
            if err is None and (OUT_DIR / name).is_file():
                parts.append(
                    '<figure><img src="%s" alt="%s"><figcaption>%s</figcaption></figure>\n'
                    % (esc(name), esc(caption), esc(caption))
                )
            else:
                parts.append(
                    '<figure><div class="err">%s: %s</div>'
                    '<figcaption>%s</figcaption></figure>\n'
                    % (esc(caption), esc(err or "no image"), esc(caption))
                )
        parts.append("</div>\n</div>\n")
    parts.append("</body>\n</html>\n")
    (OUT_DIR / "index.html").write_text("".join(parts), encoding="utf-8")


def main():
    global OUT_DIR
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(OUT_DIR), help="output directory for the page and PNGs")
    ap.add_argument("--bin", default=str(rc.DEFAULT_BIN), help="path to the lean-svg binary")
    ap.add_argument("--limit", type=int, default=None, help="only the first N unreviewed files")
    ap.add_argument("--jobs", type=int, default=4, help="concurrent chromium pages")
    args = ap.parse_args()
    OUT_DIR = Path(args.out).expanduser().resolve()

    binary = Path(args.bin).resolve()
    if not binary.is_file():
        print("lean-svg binary not found at %s (build it first)" % binary, file=sys.stderr)
        return 2

    rows = human_rows(args.limit)
    if not rows:
        print("nothing to review: every human row in tests/criteria.csv already has a verdict")
        return 0

    cards = build_cards(rows, binary, args.jobs)
    write_page(cards)
    print("wrote %d card(s) to %s/index.html" % (len(cards), OUT_DIR))
    return 0


if __name__ == "__main__":
    sys.exit(main())
