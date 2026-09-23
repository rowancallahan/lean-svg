#!/usr/bin/env python3
"""Score lean-svg against tests/criteria.csv: each file judged against the
reference tests/make_criteria.py picked for it (resvg, chrome, or a human
verdict), not uniformly against resvg.

Inputs:
    --resvg-csv   a run_corpora.py --ref resvg  --corpus resvg --route direct  CSV
    --chrome-csv  a run_corpora.py --ref chrome --corpus resvg --route direct  CSV
    --local-json  a run_tests.py results.json (local tests/svg/*.svg corpus;
                  reference is always resvg, see make_criteria.py)
    --verdicts    tests/human_verdicts.csv (file,verdict,note)

    python3 tests/score_criteria.py \\
        --resvg-csv /tmp/crit_resvg/resvg_direct.csv \\
        --chrome-csv /tmp/crit_chrome/resvg_direct.csv
    python3 tests/score_criteria.py ... --strict   # exit 1 if any scored file fails
"""
import argparse
import csv
import json
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PASS = "pass"


def read_csv_rows(path):
    with Path(path).open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def load_criteria(path):
    return read_csv_rows(path)


def load_verdicts(path):
    """{file: (verdict, note)}; verdict is 'pass'/'fail', anything else ignored."""
    out = {}
    p = Path(path)
    if not p.is_file():
        return out
    for r in read_csv_rows(p):
        if r.get("file") and r.get("verdict") in ("pass", "fail"):
            out[r["file"]] = (r["verdict"], r.get("note", ""))
    return out


def index_by_file(rows):
    """{file: status}, last row wins if a file appears more than once."""
    return {r["file"]: r["status"] for r in rows if r.get("file")}


def load_local(path):
    """{svg basename: passed bool} from a run_tests.py results.json, or {} if
    `path` is None or missing."""
    if path is None:
        return {}
    p = Path(path)
    if not p.is_file():
        return {}
    data = json.loads(p.read_text(encoding="utf-8"))
    return {Path(t["svg"]).name: bool(t["passed"]) for t in data["tests"]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--criteria", default=str(REPO / "tests" / "criteria.csv"))
    ap.add_argument("--verdicts", default=str(REPO / "tests" / "human_verdicts.csv"))
    ap.add_argument("--resvg-csv", required=True, help="run_corpora.py --ref resvg CSV")
    ap.add_argument("--chrome-csv", required=True, help="run_corpora.py --ref chrome CSV")
    ap.add_argument(
        "--local-json", default=None,
        help="run_tests.py results.json, to score the local tests/svg/*.svg rows "
             "(all reference=resvg); omitted -> local rows are not scored",
    )
    ap.add_argument(
        "--strict", action="store_true",
        help="exit 1 if any scored file failed (unreviewed human rows never count as failures)",
    )
    args = ap.parse_args()

    criteria = load_criteria(args.criteria)
    verdicts = load_verdicts(args.verdicts)
    resvg_status = index_by_file(read_csv_rows(args.resvg_csv))
    chrome_status = index_by_file(read_csv_rows(args.chrome_csv))
    local_passed = load_local(args.local_json)

    counts = Counter()  # (reference, outcome) -> n ; outcome in pass/fail/missing/unreviewed
    failures = []  # (file, reference, detail)

    for row in criteria:
        f, corpus, ref = row["file"], row["corpus"], row["reference"]
        assert ref in ("resvg", "chrome", "human", "excluded"), (f, ref)
        if ref == "excluded":
            # behaviour decided by Rowan (make_criteria.py): not scored
            counts[(ref, "excluded")] += 1
            continue
        if ref == "human":
            v = verdicts.get(f)
            if v is None:
                counts[(ref, "unreviewed")] += 1
                continue
            outcome = "pass" if v[0] == "pass" else "fail"
            counts[(ref, outcome)] += 1
            if outcome == "fail":
                failures.append((f, ref, "human verdict: fail (%s)" % v[1]))
            continue

        if corpus == "local":
            if f not in local_passed:
                counts[(ref, "missing")] += 1
                continue
            outcome = "pass" if local_passed[f] else "fail"
        else:
            status_map = resvg_status if ref == "resvg" else chrome_status
            status = status_map.get(f)
            if status is None:
                counts[(ref, "missing")] += 1
                continue
            outcome = "pass" if status == PASS else "fail"
            if outcome == "fail":
                failures.append((f, ref, "status=%s" % status))
        counts[(ref, outcome)] += 1
        if outcome == "fail" and corpus == "local":
            failures.append((f, ref, "run_tests.py: fail"))

    print("== per reference kind ==")
    for ref in ("resvg", "chrome", "human"):
        sub = {o: counts[(ref, o)] for o in ("pass", "fail", "missing", "unreviewed") if counts[(ref, o)]}
        total = sum(sub.values())
        p = sub.get("pass", 0)
        scored = p + sub.get("fail", 0)
        rate = "%.1f%%" % (100.0 * p / scored) if scored else "-"
        print("  %-6s  %4d file(s)  pass %4d  fail %3d  missing %3d  unreviewed %3d  (pass rate of scored: %s)"
              % (ref, total, p, sub.get("fail", 0), sub.get("missing", 0), sub.get("unreviewed", 0), rate))

    print("  excluded %4d file(s)  (decided behaviour, not scored; see tests/criteria.csv)"
          % counts[("excluded", "excluded")])

    all_pass = sum(counts[(r, "pass")] for r in ("resvg", "chrome", "human"))
    all_fail = sum(counts[(r, "fail")] for r in ("resvg", "chrome", "human"))
    all_missing = sum(counts[(r, "missing")] for r in ("resvg", "chrome", "human"))
    all_unreviewed = counts[("human", "unreviewed")]
    scored = all_pass + all_fail
    print(
        "\n== overall ==\n  total %d (incl. excluded)  pass %d  fail %d  missing %d  unreviewed %d  "
        "(pass rate of scored: %s)"
        % (
            scored + all_missing + all_unreviewed + counts[("excluded", "excluded")], all_pass, all_fail, all_missing, all_unreviewed,
            "%.1f%%" % (100.0 * all_pass / scored) if scored else "-",
        )
    )

    if failures:
        print("\n== failures (%d) ==" % len(failures))
        for f, ref, detail in sorted(failures):
            print("  [%s] %-70s %s" % (ref, f, detail))

    if args.strict and all_fail:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
