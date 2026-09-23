#!/usr/bin/env python3
"""Build tests/criteria.csv: the per-file reference (resvg | chrome | human)
every other harness in tests/ should judge that file against.

Rule, in order, from resvg-test-suite's own results.csv (`1` = correct,
`2` = known wrong, `0` = unrated):

    1. resvg == 1              -> reference resvg
    2. else chrome == 1        -> reference chrome
    3. else                    -> reference human (no known-correct oracle)

Our own tests/svg/*.svg files have no results.csv row; their reference is
resvg today (the only oracle run_tests.py has ever used).

    python3 tests/make_criteria.py > tests/criteria.csv
"""
import csv
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RESULTS = REPO / "tests" / "corpora" / "resvg-test-suite" / "results.csv"
LOCAL_DIR = REPO / "tests" / "svg"
OUT_FIELDS = ["file", "corpus", "reference", "reason"]


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
