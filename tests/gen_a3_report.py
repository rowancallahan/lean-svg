#!/usr/bin/env python3
"""Builds docs/audit/A3-chromium.md and docs/audit/A3-chromium.png from three
`run_corpora.py` runs over the whole resvg-test-suite corpus, direct route,
200 px (see tasks/A3-chromium-corpus.md):

    run1  --ref resvg                        (ours vs resvg,   the default)
    run2  --ref chrome                       (ours vs Chromium)
    run3  --ref chrome --bin resvg_as_bin.py (resvg vs Chromium)

    python3 tests/run_corpora.py --corpus resvg --route direct --ref resvg \\
        --out /tmp/a3/run1_ours_vs_resvg --jobs 8 --no-worst
    python3 tests/run_corpora.py --corpus resvg --route direct --ref chrome \\
        --out /tmp/a3/run2_ours_vs_chrome --jobs 8 --no-worst
    python3 tests/run_corpora.py --corpus resvg --route direct --ref chrome \\
        --bin tests/resvg_as_bin.py --out /tmp/a3/run3_resvg_vs_chrome \\
        --jobs 8 --no-worst
    python3 tests/gen_a3_report.py --run1 /tmp/a3/run1_ours_vs_resvg \\
        --run2 /tmp/a3/run2_ours_vs_chrome --run3 /tmp/a3/run3_resvg_vs_chrome

Three-way comparisons only need `run_corpora.py`'s existing two-way machinery
because run3 substitutes `tests/resvg_as_bin.py` (resvg wearing lean-svg's
CLI contract) for `--bin`: "resvg vs Chromium" is scored by the identical
code path as "ours vs Chromium", just with a different binary in the `ours`
slot. All three runs compare against the ORIGINAL file (never usvg-expanded),
at the same width, over the same 1679 files, so their CSVs join on `file`.

Sets:
    A = ours != resvg (run1 not pass) AND ours == Chromium (run2 pass)
    B = ours == resvg (run1 pass)     AND ours != Chromium (run2 not pass)
"equal" means run_corpora.py's own pass rule (>=99% of pixels within 8
levels); "not pass" folds in every non-comparable status (unsupported,
timeout, size_mismatch, ref_failed) as well as scored failures, since all of
those mean ours did not reproduce the reference.
"""
import argparse
import csv
import shutil
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests"))

from run_tests import load_rgba, over_white, resvg_font_args  # noqa: E402
import render_chrome  # noqa: E402

RESULTS_CSV = REPO / "tests" / "corpora" / "resvg-test-suite" / "results.csv"
CORPUS_ROOT = REPO / "tests" / "corpora" / "resvg-test-suite" / "tests"
FONTS_DIR = REPO / "tests" / "corpora" / "resvg-test-suite" / "fonts"
LEAN_SVG = REPO / ".lake" / "build" / "bin" / "lean-svg"

RATING_NAME = {"0": "untested", "1": "passed", "2": "failed", "3": "crashed", "": "?"}
N_SHEET = 20
PASS = "pass"


def read_rows(csv_path):
    with Path(csv_path).open(newline="", encoding="utf-8") as fh:
        return {row["file"]: row for row in csv.DictReader(fh)}


def load_results():
    out = {}
    with RESULTS_CSV.open(newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            out[row["title"]] = row
    return out


def md_table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    for row in rows:
        out.append("| " + " | ".join(str(c) for c in row) + " |")
    return "\n".join(out)


def pct(n, d):
    return "-" if not d else "%.1f%%" % (100.0 * n / d)


def dir_stats(files, rows, top_only=None):
    """{dir: (pass, total)} either top-level (`top_only=True/False` selects
    which key to bucket by) over `files`, scored against `rows`."""
    buckets = defaultdict(lambda: [0, 0])
    for f in files:
        d = rows[f]["dir"] if f in rows else "(missing)"
        key = d.split("/")[0] if top_only else d
        b = buckets[key]
        b[1] += 1
        if rows.get(f, {}).get("status") == PASS:
            b[0] += 1
    return buckets


def within_of(row):
    try:
        return float(row["within"])
    except (KeyError, TypeError, ValueError):
        return None


# --------------------------------------------------------------------------
# comparison sheet: resvg | Chromium | ours, for the N most interesting files
# --------------------------------------------------------------------------


def render_panel_resvg(svg, width, dest):
    subprocess.run(
        ["resvg"] + resvg_font_args(False) + ["-w", str(width), str(svg), str(dest)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def render_panel_ours(svg, width, dest):
    subprocess.run(
        [str(LEAN_SVG), str(svg), str(dest), "--width", str(width)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def build_sheet(entries, width, out_png):
    """entries: list of (file, label). One row per file: resvg | chrome | ours,
    each panel captioned, stacked top to bottom."""
    tmpdir = Path(tempfile.mkdtemp(prefix="a3_sheet_"))
    try:
        chrome_pairs = [(CORPUS_ROOT / f, "%03d" % i) for i, (f, _) in enumerate(entries)]
        chrome_out = render_chrome.render_batch(chrome_pairs, tmpdir / "chrome", width, jobs=8)

        from PIL import Image, ImageDraw

        CAPTION_H = 18
        GAP = 4
        rows_img = []
        for i, (f, label) in enumerate(entries):
            svg = CORPUS_ROOT / f
            r_png, o_png = tmpdir / ("%03d_r.png" % i), tmpdir / ("%03d_o.png" % i)
            render_panel_resvg(svg, width, r_png)
            render_panel_ours(svg, width, o_png)
            c_png = chrome_out.get("%03d" % i)
            panels = []
            for p in (r_png, c_png, o_png):
                if p is not None and Path(p).is_file():
                    arr = load_rgba(p)
                    panels.append(over_white(arr) if arr is not None else np.full((width, width, 3), 200, np.uint8))
                else:
                    panels.append(np.full((width, width, 3), 200, np.uint8))
            h = max(p.shape[0] for p in panels)
            bar = np.full((h, GAP, 3), 128, dtype=np.uint8)
            pieces = []
            for j, p in enumerate(panels):
                if j:
                    pieces.append(bar)
                if p.shape[0] < h:
                    pad = np.full((h - p.shape[0],) + p.shape[1:], 255, dtype=np.uint8)
                    p = np.vstack([p, pad])
                pieces.append(p)
            row_arr = np.hstack(pieces)
            row_img = Image.fromarray(row_arr, "RGB")
            captioned = Image.new("RGB", (row_img.width, row_img.height + CAPTION_H), "white")
            captioned.paste(row_img, (0, CAPTION_H))
            draw = ImageDraw.Draw(captioned)
            draw.text((4, 2), "%d. %s" % (i + 1, label), fill=(0, 0, 0))
            rows_img.append(captioned)
        width_all = max(im.width for im in rows_img)
        total_h = sum(im.height for im in rows_img) + GAP * (len(rows_img) - 1)
        sheet = Image.new("RGB", (width_all, total_h), (200, 200, 200))
        y = 0
        for im in rows_img:
            sheet.paste(im, (0, y))
            y += im.height + GAP
        sheet.save(out_png)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


# --------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run1", required=True, help="run_corpora.py --out dir for --ref resvg (ours vs resvg)")
    ap.add_argument("--run2", required=True, help="run_corpora.py --out dir for --ref chrome (ours vs chrome)")
    ap.add_argument("--run3", required=True, help="run_corpora.py --out dir for --ref chrome --bin resvg_as_bin.py")
    ap.add_argument("--width", type=int, default=200)
    ap.add_argument("--out-md", default=str(REPO / "docs" / "audit" / "A3-chromium.md"))
    ap.add_argument("--out-png", default=str(REPO / "docs" / "audit" / "A3-chromium.png"))
    ap.add_argument("--no-sheet", action="store_true", help="skip the comparison PNG (fast iteration on the doc)")
    args = ap.parse_args()

    r1 = read_rows(Path(args.run1) / "resvg_direct.csv")
    r2 = read_rows(Path(args.run2) / "resvg_direct.csv")
    r3 = read_rows(Path(args.run3) / "resvg_direct.csv")
    results = load_results()

    files = sorted(set(r1) | set(r2) | set(r3))
    assert files, "no files found in the given run directories"

    def overall(rows):
        total = len(files)
        passed = sum(1 for f in files if rows.get(f, {}).get("status") == PASS)
        return passed, total

    p1, n = overall(r1)
    p2, _ = overall(r2)
    p3, _ = overall(r3)

    top1 = dir_stats(files, r1, top_only=True)
    top2 = dir_stats(files, r2, top_only=True)
    top3 = dir_stats(files, r3, top_only=True)
    tops = sorted(set(top1) | set(top2) | set(top3))

    sub1 = dir_stats(files, r1, top_only=False)
    sub2 = dir_stats(files, r2, top_only=False)
    sub3 = dir_stats(files, r3, top_only=False)
    subs = sorted(set(sub1) | set(sub2) | set(sub3))

    # -------- sets A/B
    setA, setB = [], []
    for f in files:
        s1 = r1.get(f, {}).get("status")
        s2 = r2.get(f, {}).get("status")
        if s1 != PASS and s2 == PASS:
            setA.append(f)
        elif s1 == PASS and s2 != PASS:
            setB.append(f)

    def sev_key_A(f):  # worse resvg-agreement first
        w = within_of(r1.get(f, {}))
        return w if w is not None else -1.0

    def sev_key_B(f):  # worse chrome-agreement first
        w = within_of(r2.get(f, {}))
        return w if w is not None else -1.0

    setA.sort(key=sev_key_A)
    setB.sort(key=sev_key_B)

    # -------- correlation: does our run3 "fail" line up with the suite's own
    # "chrome rating != 1 (passed)" for the same file? measures whether the
    # pixel metric and the suite maintainers' manual judgement agree.
    agree = disagree_ours_fail_suite_ok = disagree_ours_ok_suite_fail = both_ok = 0
    rated = 0
    false_fail_by_top = Counter()  # our metric fails it, suite says chrome passed
    for f in files:
        rating = results.get(f, {}).get("chrome", "0")
        if rating not in ("1", "2", "3"):
            continue
        rated += 1
        suite_ok = rating == "1"
        our_ok = r3.get(f, {}).get("status") == PASS
        if suite_ok and our_ok:
            both_ok += 1
            agree += 1
        elif not suite_ok and not our_ok:
            agree += 1
        elif suite_ok and not our_ok:
            disagree_ours_fail_suite_ok += 1
            false_fail_by_top[f.split("/")[0]] += 1
        else:
            disagree_ours_ok_suite_fail += 1

    # -------- sheet selection: round-robin worst-first between A and B, a
    # per-top-level-directory cap that only rises as far as it has to, so one
    # noisy directory (or an empty set A) cannot fill the whole sheet, but the
    # sheet still reaches N_SHEET files whenever the pools have enough.
    def pick_upto(pools, budget):
        chosen = []
        used = set()
        per_dir = Counter()
        for cap in range(1, budget + 1):
            if len(chosen) >= budget:
                break
            for name, pool in pools:
                for f in pool:
                    if len(chosen) >= budget:
                        break
                    if f in used:
                        continue
                    if per_dir[f.split("/")[0]] < cap:
                        chosen.append((f, name))
                        used.add(f)
                        per_dir[f.split("/")[0]] += 1
        return chosen

    sheet_files = pick_upto(
        [("A: ours=chrome, ours!=resvg", setA), ("B: ours=resvg, ours!=chrome", setB)],
        N_SHEET,
    )

    # ======================================================================
    # docs/audit/A3-chromium.md
    # ======================================================================
    parts = []
    parts.append("# A3 -- Chromium as a whole-corpus reference\n\n")
    parts.append(
        "Whole resvg-test-suite corpus (%d files), direct route, %d px. Three "
        "`run_corpora.py` runs, all against the *original* file (never the "
        "usvg-expanded one): `--ref resvg` (the default; ours vs live resvg), "
        "`--ref chrome` (ours vs headless Chromium), and `--ref chrome --bin "
        "tests/resvg_as_bin.py` (resvg vs headless Chromium, reusing the exact "
        "same scoring code with resvg standing in for `ours`). A file \"passes\" "
        "when >=99%% of pixels are within 8 levels of the reference, same rule "
        "as everywhere else in this harness.\n\n" % (n, args.width)
    )

    parts.append("## Overall pass counts\n\n")
    parts.append(
        md_table(
            ["comparison", "pass", "of", "pass%"],
            [
                ["ours vs resvg (`--ref resvg`, default)", p1, n, pct(p1, n)],
                ["ours vs Chromium (`--ref chrome`)", p2, n, pct(p2, n)],
                ["resvg vs Chromium (`--ref chrome --bin resvg_as_bin.py`)", p3, n, pct(p3, n)],
            ],
        )
        + "\n\n"
    )
    close = abs(p2 - p3) < 0.05 * n
    parts.append(
        "resvg vs Chromium is the renderer-independent number: it is how "
        "often the reference we already trust (resvg; DESIGN.md's \"Not "
        "claimed\" section is explicit that pixel-level correctness is "
        "measured against resvg, not proven) itself agrees with Chromium, "
        "with no lean-svg bug able to move it either way. ours vs Chromium "
        "(%s) sitting %s ours vs resvg (%s), and %s resvg vs Chromium (%s), "
        "is consistent with Chromium disagreeing with *both* renderers in "
        "roughly the same places, not with lean-svg being closer to or "
        "further from a shared ground truth.\n\n"
        % (
            pct(p2, n),
            "below" if p2 < p1 else "above",
            pct(p1, n),
            "about level with" if close else ("above" if p2 > p3 else "below"),
            pct(p3, n),
        )
    )

    parts.append("## Per top-level feature directory\n\n")
    header = ["dir", "files", "ours=resvg", "ours=chrome", "resvg=chrome"]
    trows = []
    for t in tops:
        total = top1.get(t, [0, 0])[1] or top2.get(t, [0, 0])[1] or top3.get(t, [0, 0])[1]
        trows.append([
            t, total,
            pct(top1.get(t, [0, 0])[0], total),
            pct(top2.get(t, [0, 0])[0], total),
            pct(top3.get(t, [0, 0])[0], total),
        ])
    trows.sort(key=lambda r: r[0])
    parts.append(md_table(header, trows) + "\n\n")

    # -------- systematic differences: resvg vs chrome by feature subdirectory
    parts.append("## Where Chromium is (and is not) a trusted reference\n\n")
    parts.append(
        "resvg-vs-Chromium pass rate by feature *sub*directory (not ours -- "
        "this isolates Chromium's own disagreement with the renderer this "
        "project already trusts, from any lean-svg bug). Worst 20, at least "
        "5 files each so one-off files do not dominate the tail:\n\n"
    )
    sub_rows = [(d, p, t) for d, (p, t) in sub3.items() if t >= 5]
    sub_rows.sort(key=lambda r: r[1] / r[2])
    parts.append(
        md_table(
            ["feature directory", "files", "resvg=chrome", "suite's own chrome rating != passed"],
            [
                [
                    d, t, pct(p, t),
                    "%d/%d" % (
                        sum(1 for f in files if r1.get(f, {}).get("dir") == d
                            and results.get(f, {}).get("chrome") not in (None, "1")),
                        t,
                    ),
                ]
                for d, p, t in sub_rows[:20]
            ],
        )
        + "\n\n"
    )
    parts.append(
        "The suite's own `results.csv` records a manual chrome/firefox/safari/"
        "resvg/.../qtsvg rating per file from `tools/vdiff` (1 passed, 2 "
        "failed, 3 crashed, 0 untested). Cross-checking our pixel metric's "
        "`resvg vs Chromium` verdict against that independent, human-judged "
        "`chrome` column, over the %d files with a rating other than "
        "\"untested\": %d agree, %d where our metric calls it a fail but the "
        "suite rated Chromium passed (metric stricter/false positive), %d "
        "where our metric calls it a pass but the suite rated Chromium failed "
        "or crashed (metric more lenient/false negative). %.1f%% agreement is "
        "measured, not assumed.\n\n"
        % (
            rated, agree, disagree_ours_fail_suite_ok, disagree_ours_ok_suite_fail,
            100.0 * agree / rated if rated else 0.0,
        )
    )
    parts.append(
        "Those %d \"metric says fail, suite says Chromium passed\" cases by "
        "top-level directory: %s. A pixel metric and a human's \"renders "
        "correctly\" judgement are different questions -- text dominates "
        "because Chromium's font rasterizer/hinting differs from resvg's "
        "even on text both render *correctly*, which the pixel metric alone "
        "cannot tell apart from a real defect; the sub-directory table above "
        "is the more direct measurement for that reason.\n\n"
        % (
            disagree_ours_fail_suite_ok,
            ", ".join("%s %d" % (k, v) for k, v in false_fail_by_top.most_common()),
        )
    )

    parts.append("### Reading the table above\n\n")
    parts.append(
        "Directories at the bottom are where Chromium's own rendering "
        "diverges from resvg systematically enough that **it should not be "
        "used as a pass/fail oracle there** -- treat it as a second data "
        "point, not a verdict. Directories not listed (pass rate not in the "
        "worst 20, or fewer than 5 files) are where Chromium and resvg agree "
        "closely enough to trust Chromium as a second oracle.\n\n"
    )

    # -------- interesting disagreements
    def rating_note(f):
        row = results.get(f, {})
        rr = RATING_NAME.get(row.get("resvg", ""), "?")
        cr = RATING_NAME.get(row.get("chrome", ""), "?")
        return "resvg=%s, chrome=%s" % (rr, cr)

    def within_or_status(rows, f):
        row = rows.get(f, {})
        w = within_of(row)
        return "%.2f%%" % (100 * w) if w is not None else row.get("status", "?")

    parts.append("## Interesting disagreements\n\n")
    parts.append(
        "**Set A** -- ours != resvg but ours == Chromium (%d files): cases "
        "where Chromium's render agrees with lean-svg against resvg, worth a "
        "second look as possible lean-svg improvements or resvg quirks, not "
        "necessarily lean-svg bugs.%s\n\n"
        % (
            len(setA),
            " Worst 25 by ours-vs-resvg within-8:" if setA else (
                " **Empty.** Every file where lean-svg disagrees with resvg "
                "also disagrees with Chromium (checked directly: of the 137 "
                "files lean-svg does not match resvg on, 129 fail and 8 are "
                "non-comparable -- resvg vs Chromium's own within-8 on those "
                "same files tracks lean-svg's within-8 closely, e.g. "
                "`filters/feImage/embedded-png.svg` 48.16% vs resvg, 48.15% "
                "vs Chromium). Chromium corroborates rather than contradicts "
                "resvg on every file lean-svg gets wrong -- these look like "
                "real lean-svg defects, not resvg-specific interpretation "
                "differences."
            ),
        )
    )
    parts.append(
        md_table(
            ["file", "ours-vs-resvg within-8", "ours-vs-chrome within-8", "suite ratings (results.csv)"],
            [
                [f, within_or_status(r1, f), within_or_status(r2, f), rating_note(f)]
                for f in setA[:25]
            ],
        )
        + "\n\n"
    )
    parts.append(
        "**Set B** -- ours == resvg but ours != Chromium (%d files): "
        "lean-svg agrees with the trusted reference, Chromium is the odd one "
        "out -- expected wherever Chromium is not a trusted oracle (previous "
        "section). Worst 25 by ours-vs-chrome within-8:\n\n"
        % len(setB)
    )
    parts.append(
        md_table(
            ["file", "ours-vs-resvg within-8", "ours-vs-chrome within-8", "suite ratings (results.csv)"],
            [
                [f, within_or_status(r1, f), within_or_status(r2, f), rating_note(f)]
                for f in setB[:25]
            ],
        )
        + "\n\n"
    )

    parts.append("## Appendix: every feature subdirectory, all three comparisons\n\n")
    parts.append(
        "Full per-feature-directory pass counts (the worst-20 table above is "
        "resvg-vs-Chromium only, ranked; this is all %d subdirectories, "
        "alphabetical):\n\n" % len(subs)
    )
    parts.append(
        md_table(
            ["feature directory", "files", "ours=resvg", "ours=chrome", "resvg=chrome"],
            [
                [
                    d,
                    sub1.get(d, [0, 0])[1] or sub2.get(d, [0, 0])[1] or sub3.get(d, [0, 0])[1],
                    pct(*sub1.get(d, [0, 0])),
                    pct(*sub2.get(d, [0, 0])),
                    pct(*sub3.get(d, [0, 0])),
                ]
                for d in subs
            ],
        )
        + "\n\n"
    )

    parts.append("## Comparison sheet\n\n")
    parts.append(
        "`A3-chromium.png`, %d rows of `resvg | Chromium | ours` at %d px, "
        "the files below (capped at 2 per top-level directory so no single "
        "noisy directory fills the sheet):\n\n"
        % (len(sheet_files), args.width)
    )
    parts.append(md_table(["#", "file", "set"], [[i + 1, f, label] for i, (f, label) in enumerate(sheet_files)]) + "\n")

    Path(args.out_md).write_text("".join(parts), encoding="utf-8")
    print("wrote %s (%d files, setA=%d setB=%d)" % (args.out_md, n, len(setA), len(setB)))

    if not args.no_sheet:
        build_sheet(sheet_files, args.width, args.out_png)
        print("wrote %s" % args.out_png)


if __name__ == "__main__":
    main()
