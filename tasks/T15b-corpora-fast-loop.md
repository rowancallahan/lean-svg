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

## Report

### What changed

`tests/run_corpora.py` only (447 insertions, 61 deletions). No Lean source,
no `tests/svg/`, no `.worktrees/`, nothing committed. Every verification run
wrote to a scratch directory via the new `--out`, so `tests/out/corpora/` was
read but never written (another session rewrote it at 15:22 while this task
ran, which is exactly the clobbering `--out` is there to avoid).

New flags, all six from the task:

| flag | behaviour |
|---|---|
| `--failing-from CSV [CSV ...]` | re-runs only rows whose `status` is not `pass` (so `fail`, `unsupported`, `timeout`, `size_mismatch`, `usvg_failed`, `ref_failed` all count as "did not pass"). Corpus and route come from each row's own `corpus`/`route` columns, falling back to the `<corpus>_<route>.csv` name, so `--corpus`/`--route` can be omitted. Prints the count per CSV and per selection. |
| `--dir PREFIX` (repeatable) | keeps files whose directory is, or is under, a prefix (`--dir shapes` covers `shapes/**`). Applies to the resvg suite; ignored for the flat icon sets. |
| `--fast` | widths 100 (suite) / 64 (icons) instead of 200 / 96, and `--jobs` defaults to `hw.ncpu` (8 here) instead of 4. The widths are printed on every selection line and in the summary header (`render widths: resvg 100 px, simple-icons 64 px, feather 64 px (--fast)`). |
| `--out DIR` | CSVs, `summary.md` and `worst/` go there instead of `tests/out/corpora/`. |
| `--compare CSV [CSV ...]` | after the run, prints (and appends to the summary) a per-file within-8 before/after table for files that moved by more than 0.1 points, then `newly passing / newly failing / unchanged / only in this run / only in baseline`. |
| `--has-arcs {yes,no}` | keeps files whose source `d` attributes do / do not contain an `A`/`a` command, reusing the `uses_arcs` helper behind the summary's arc split. |

Mechanics: filters compose in the order `--dir` → `--failing-from` →
`--has-arcs` → the random `--limit` sample, so the sample is drawn from what
the filters left, and the summary's sampling note spells that chain out.
File selection is now per `(corpus, route)` rather than per corpus, because
`--failing-from` gives the two routes different file lists. Defaults are
unchanged: with none of the new flags the run is still width 200/96, 4 jobs,
whole corpora, writing to `tests/out/corpora/`.

Two behaviours worth knowing:

- `--failing-from` with an **explicit** `--route` the CSVs do not cover runs
  that corpus's union of non-passing files through the requested route (how
  "do the direct-route failures survive usvg?" gets asked).
- `--failing-from` where everything passed exits **0** with
  "every file in the given CSVs passed, nothing to re-run" — the good end of
  the loop, not an error. An empty selection for any other reason still
  exits 2.

### Verification runs

All against `.lake/build/bin/microsvg` (commit `4ab8990`), resvg/usvg 0.48.1,
`--out` into a scratch dir (written `$S` below). Timings are the harness's
own `total`, with wall clock from `time` in brackets.

| # | invocation (all prefixed `python3 tests/run_corpora.py`) | result | time |
|---|---|---|---|
| 1 | `--fast --limit 50 --no-worst --corpus resvg --route direct --dir shapes/path --dir painting/stroke-dasharray --out $S/base` | `--dir` 74/1679 → sample 50 at width 100, 8 jobs; pass 27 | 0.2s (0.37s) |
| 2 | same as 1 with `--out $S/after --compare $S/base/resvg_direct.csv` | 0 files moved >0.1 pt; newly passing 0, newly failing 0, unchanged 50 | 0.2s (0.36s) |
| 3 | `--fast --limit 50 --no-worst --corpus resvg --route direct --dir shapes/path --out $S/vs200 --compare tests/out/corpora/resvg_direct.csv` | 29 files moved >0.1 pt; newly failing 7, unchanged 21, only in baseline 1629 | 0.2s (0.35s) |
| 4 | `--fast --limit 50 --no-worst --failing-from $S/base/resvg_direct.csv --out $S/fail1` | 23 non-passing selected (corpus/route inferred), 23 rendered, pass 0 | 0.1s (0.23s) |
| 5 | `--fast --limit 50 --no-worst --failing-from $S/base/resvg_direct.csv --route usvg --out $S/fail_usvg` | same 23 files through usvg, pass 9 (39.1%) | 0.2s (0.47s) |
| 6 | `--fast --limit 50 --no-worst --failing-from $S/base/resvg_direct.csv $S/fail_usvg/resvg_usvg.csv --out $S/fail2` | two CSVs → 23 direct + 14 usvg, both routes run | 0.2s (0.36s) |
| 7 | `--fast --limit 50 --no-worst --corpus simple-icons --route direct --has-arcs yes --out $S/arcs_yes` | 2405 arc files → sample 50 at width 64; pass 1 (2.0%) | 0.3s (0.56s) |
| 8 | `--fast --limit 50 --no-worst --corpus simple-icons --route direct --has-arcs no --out $S/arcs_no` | 1056 arc-free files → sample 50; pass 20 (40.0%) | 0.2s (0.41s) |
| 9 | `--fast --limit 12 --corpus feather --route both --out $S/worstchk` | composites honour `--out`: 24 PNGs in `$S/worstchk/worst/` | 0.2s (0.37s) |
| 10 | `--fast --limit 50 --out $S/allfast` | all 3 corpora × both routes, 300 files, composites on | 2.0s (2.28s) |
| 11 | `--limit 5 --no-worst --corpus feather --route direct --out $S/defaults` | defaults intact: width 96, 4 jobs | 0.1s (0.24s) |

Edge cases exercised: `--dir does/not/exist` → "no files left after the
filters" and exit 2; a CSV whose `corpus`/`route` columns are blank but whose
name is `feather_direct.csv` → inferred correctly (11 of 12 selected); a CSV
with every row forced to `pass` → exit 0 with the "nothing to re-run" message;
a missing `--failing-from`/`--compare` path → exit 2 *before* any rendering.

### Notes

- Run 2 is the no-regression proof in its intended form: identical binary,
  identical selection, 0 files moved, 50 unchanged — so rendering is
  deterministic and `--compare` has no floor noise of its own.
- Run 3 compares width 100 against the stored width-200 CSV, which is why 7
  files read as "newly failing": at 100 px the antialiased edge is a larger
  share of the image, and files sitting just over the 99% threshold at 200 px
  drop just under it. **Compare runs at the same width** — generate the
  baseline with the same `--fast`/`--dir` flags as the after-run. The table
  in run 3 is otherwise a genuine per-file delta (−1.13 to +0.17 points).
- Runs 7/8 reproduce the known arc defect at `--fast` widths: 2.0% pass with
  arcs versus 40.0% without, on the same corpus and route.
- `--tol` was tried as a way to synthesise a delta and does not produce one
  on these files: differences are either zero or far larger than 8, so
  `within` is identical at tol 2 and tol 8. Use a width or binary change to
  exercise `--compare`, not the tolerance.
- Nothing in the task could not be done.
