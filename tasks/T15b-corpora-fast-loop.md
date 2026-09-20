# T15b — Corpora harness: iterate only on failures, at small sizes

Python only, main tree, `tests/run_corpora.py` (and its summary writer).
Do not touch Lean sources or `.worktrees/`. Do not commit.

Add:

1. `--failing-from PATH.csv [PATH2.csv ...]`: run only the files that did
   not pass (pass = 0, or unsupported / size mismatch / error) in those
   earlier CSVs. Print how many were selected. Works with `--corpus` and
   `--route` as usual; the CSV names encode corpus and route, so infer them
   when `--corpus` is omitted.
2. `--dir PREFIX` (repeatable): restrict the resvg suite to feature
   directories, e.g. `--dir shapes/path --dir painting/stroke-dasharray`.
3. `--fast`: render widths 100 (suite) and 64 (icons) instead of 200/96,
   and default `--jobs` to `hw.ncpu`. Print the widths used in the summary.
4. `--out DIR` to write the CSVs/summary somewhere other than
   `tests/out/corpora/` (agents run this in worktrees and must not clobber
   the main results).
5. A `--compare BASE.csv` option: after the run, print a per-file delta
   table (within-8 before/after) for files that changed by more than 0.1
   points, and totals: newly passing, newly failing, unchanged. This is how
   feature tasks prove "no regression" cheaply.
6. `--has-arcs {yes,no}` filter (the split already computed in the summary).

Verify each flag with a real run (`--fast --limit 50`). Append `## Report`
with example invocations and their timings.
