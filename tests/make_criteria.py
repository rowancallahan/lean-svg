#!/usr/bin/env python3
"""Build tests/criteria.csv: the per-file reference (resvg | chrome | human)
every other harness in tests/ should judge that file against.

Rule, in order, from resvg-test-suite's own results.csv (`1` = correct,
`2` = known wrong, `0` = unrated):

    1. resvg == 1              -> reference resvg
    2. else chrome == 1        -> reference chrome
    3. else                    -> reference human (no known-correct oracle)

Overriding all three, a file whose behaviour Rowan has decided (see
docs/DECISIONS.md) gets reference `excluded`: it is not scored and not
queued for human review. The rules are `EXCLUDED` below:

    - DTD entities (`<!ENTITY`): not supported.
    - `enable-background`, `BackgroundImage`, `BackgroundAlpha`: not
      supported (removed in SVG 2, no browser implements them); files where
      resvg is rated correct stay scored against resvg.
    - Zero or negative document size: lean-svg refuses the file, as resvg does.
    - Legacy/removed features Chromium also ignores (`clip` property,
      `icc-color`, `glyph-orientation-*`, `kerning=<length>`), where resvg
      is not the reference: they stay ignored.
    - External resources (another file, a URL, an external stylesheet), for
      files that would otherwise need a human check: nothing outside the SVG
      is loaded. Where resvg is the reference, run_corpora.py already scores
      these against resvg on a copy with the external hrefs removed.

Our own tests/svg/*.svg files have no results.csv row; their reference is
resvg today (the only oracle run_tests.py has ever used).

    python3 tests/make_criteria.py > tests/criteria.csv
"""
import csv
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RESULTS = REPO / "tests" / "corpora" / "resvg-test-suite" / "results.csv"
LOCAL_DIR = REPO / "tests" / "svg"
OUT_FIELDS = ["file", "corpus", "reference", "reason"]
SUITE_DIR = REPO / "tests" / "corpora" / "resvg-test-suite" / "tests"
EXTERNAL_HREF = re.compile(r"""href\s*=\s*["'](?!\s*#|\s*data:)[^"']*[./:][^"']*["']""")
EXTERNAL_CSS = re.compile(r"<\?xml-stylesheet|@import")


def excluded(rel, ref):
    """The decision that excludes `rel` from scoring, or None."""
    text = (SUITE_DIR / rel).read_bytes().decode("utf-8", "replace")
    if "<!ENTITY" in text:
        return "DTD entities are not supported (Rowan, 2026-09-23)"
    if ref != "resvg" and re.search(r"enable-background|BackgroundImage|BackgroundAlpha", text):
        return "enable-background/BackgroundImage stay unsupported (Rowan, 2026-09-23)"
    if ref != "resvg" and (rel.startswith(("masking/clip/", "text/glyph-orientation-", "text/kerning/"))
                           or "icc-color" in text.lower()):
        return "legacy/removed feature Chromium also ignores; stays ignored (Rowan, 2026-09-24)"
    if rel in ("structure/svg/zero-size.svg", "structure/svg/negative-size.svg"):
        return "invalid document size: lean-svg refuses it, as resvg does"
    if ref == "human":
        # a file path or URL; a bare name like `href="path2"` is a broken
        # same-document reference, which the file itself tests
        if EXTERNAL_HREF.search(text) or EXTERNAL_CSS.search(text):
            return "external resources are never loaded (Rowan, 2026-09-23)"
    return None


def suite_rows():
    with RESULTS.open(newline="", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            resvg, chrome = r["resvg"], r["chrome"]
            if resvg == "1":
                ref, why = "resvg", "resvg=1 (correct) in resvg-test-suite results.csv"
            elif chrome == "1":
                ref, why = "chrome", "resvg=%s (not correct), chrome=1 (correct)" % resvg
            else:
                ref, why = "human", (
                    "resvg=%s, chrome=%s: neither is a known-correct oracle for this file"
                    % (resvg, chrome)
                )
            ex = excluded(r["title"], ref)
            if ex is not None:
                ref, why = "excluded", ex
            yield {"file": r["title"], "corpus": "resvg-suite", "reference": ref, "reason": why}


def local_rows():
    for svg in sorted(LOCAL_DIR.glob("*.svg")):
        yield {
            "file": svg.name,
            "corpus": "local",
            "reference": "resvg",
            "reason": "local regression file, no results.csv row; resvg is the only oracle used for it today",
        }


def main():
    assert RESULTS.is_file(), "missing %s (run scripts/cloud-setup.sh first)" % RESULTS
    writer = csv.DictWriter(sys.stdout, fieldnames=OUT_FIELDS)
    writer.writeheader()
    n = 0
    for row in suite_rows():
        writer.writerow(row)
        n += 1
    for row in local_rows():
        writer.writerow(row)
        n += 1
    print("wrote %d rows" % n, file=sys.stderr)


if __name__ == "__main__":
    main()
