#!/usr/bin/env python3
"""Split a run_corpora.py resvg CSV by whether resvg itself renders each file
correctly, per the suite's own results.csv (1 passed, 2 failed, 0 unknown).

Matching resvg is only the right target where resvg is right. Files where
resvg is known wrong are reported separately: passing them means we copy
resvg's bug, and they are candidates for a different reference later.

    python3 tests/score_known.py tests/out/corpora/resvg_direct.csv
"""
import csv
import sys
from collections import Counter
from pathlib import Path

RESULTS = Path(__file__).parent / "corpora" / "resvg-test-suite" / "results.csv"
NAMES = {"1": "resvg correct", "2": "resvg known wrong", "0": "resvg unrated"}

res = {r["title"]: r["resvg"] for r in csv.DictReader(open(RESULTS))}
rows = list(csv.DictReader(open(sys.argv[1])))
assert rows and all(r["file"] in res for r in rows), "CSV files not in results.csv"
tot, ok = Counter(), Counter()
for r in rows:
    s = res[r["file"]]
    tot[s] += 1
    ok[s] += r["status"] == "pass"
for s in ("1", "2", "0"):
    print(f"{NAMES[s]:18s} {ok[s]:5d}/{tot[s]:<5d} {100 * ok[s] / max(tot[s], 1):5.1f}%")
