# A1 — audit: what counts as a pass  (branch `claude/audit-a1-pass-rules`)

Our harness says a file passes when ≥99% of pixels are within 8 levels of
live resvg at a given width (`tests/run_tests.py`, `tests/run_corpora.py`).
Rowan wants to be sure we follow the rules resvg's own suite uses for
"correct", and that our numbers are honest.

Find out and write up in `docs/audit/A1-pass-rules.md`:
1. How resvg's own test harness decides pass/fail (the resvg repo's
   integration tests: `crates/resvg/tests/`, the comparison code, its
   tolerance, the width it renders at, whether it compares against the
   suite PNGs). Clone `https://github.com/linebender/resvg` at v0.48.1.
2. What `results.csv` means and how it was produced (`tools/vdiff`, README,
   git history of the suite repo). Are the suite PNGs resvg snapshots or
   independent references? Measure: for resvg=1 files, how often does live
   resvg match the suite PNG under our metric; for resvg=2 files?
3. Whether we should score resvg-correct files against the suite PNG instead
   of live resvg, or both, and what changes in our pass count if we do
   (implement it as an **option** in `run_corpora.py`, e.g. `--ref suite`,
   and report both numbers at 100 and 200 px). Default behaviour unchanged.
4. Whether our tolerance (8 levels, 99%) is stricter or looser than theirs,
   with a table of how many files flip at other thresholds.
5. Anything in our harness that looks like it inflates the numbers.

Commit often; push to your branch only; no PR.

## Rules

**Setup (first thing):** `bash scripts/cloud-setup.sh` then
`export PATH=$HOME/.elan/bin:$PATH`. It installs Lean from the GitHub release,
resvg/usvg 0.48.1, numpy/pillow and the resvg test suite under
`tests/corpora/resvg-test-suite`, and builds. Read `tasks/README.md`,
`DESIGN.md` and the relevant parts of `SPEC.md` before editing.

**Invariants (hard, from tasks/README.md):** no `partial`, `unsafe`,
`@[extern]`, `panic!`, `!`-indexing, `Float`; loops over finite ranges or
structurally decreasing fuel; hot loops in `Nat`; no new build warnings;
`LeanSvg/Effect.lean` untouched unless your task is about it; no IO outside
`Effect.lean`. Code should fail loudly rather than silently: prefer
rejecting/asserting over swallowing errors, but a feature that is not
supported should degrade exactly as it does today (skip), not error.

**Reference behaviour:** match resvg/usvg 0.48.1. The Rust source is the spec
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`
into a scratch dir; `crates/usvg/src/parser/*` and `crates/resvg/src/*`).

## Report

Wrote `docs/audit/A1-pass-rules.md` covering all five points, with
measurements against the real corpus (not just source-reading).

**Files changed:**
- `docs/audit/A1-pass-rules.md` (new) — the audit.
- `tests/run_corpora.py` — added `--ref {resvg,suite}` (default `resvg`,
  behaviour unchanged when omitted); `render_one_suite`, `load_suite_ref`,
  `SUITE_REF_CORPUS`, wired through `run_corpus_route`,
  `write_worst_composites`, `main`, and the `summary.md` text.

**Key findings** (details and full tables in the doc):
1. resvg's own CI (`cargo test --all --release`) is a bit-almost-exact
   *regression* test against PNGs checked into the `resvg` repo itself
   (not `resvg-test-suite`'s), at width 300, requiring zero pixels to
   differ by more than 1 level/channel. It never reads
   `resvg-test-suite`'s PNGs.
2. `resvg-test-suite`'s per-test PNG (`tools/vdiff`'s "Reference" backend)
   is empirically resvg's own historical render, not an independent
   oracle: live resvg 0.48.1 matches it (median within-8 99.87%, native
   resolution, no resampling) for files `results.csv` already calls
   "resvg correct" (1209/1520 clear our 99%/tol-8 bar), but only
   12/95 "resvg known wrong" files and 5/61 unrated files do.
3. Implemented `--ref suite`. At native resolution it's a real,
   informative comparison (used for #2 above). At the widths we actually
   render (100/200 px) it is not: the suite ships one fixed-resolution PNG
   per file (~500 px) and resampling it dominates the result — pass rate
   on the identical 1679 files swings from 7.5% (width 100) to 0.2% (width
   200), purely from resampling-phase artifacts. Recommend keeping live
   resvg as the default; `--ref suite` is for native-resolution spot
   checks only, cross-referenced against `results.csv`'s rating.
4. Our bar (8 levels / 99% of pixels) is far looser than resvg's own
   (effectively 1 level / 100%, i.e. zero tolerated differing pixels).
   Applying resvg's literal bar to our renders vs. live resvg drops our
   resvg-corpus pass rate from 91.8% to 56.5% at width 200 — though that
   comparison itself isn't apples-to-apples (regression-vs-self vs.
   cross-implementation match), which the doc calls out explicitly.
5. No evidence of accidental inflation (sampling is seeded and reported,
   every status counts toward `pass% (all)`'s denominator, the 99%/tol-8
   choice is stated in the tool's own output). One real, previously
   under-surfaced gap: 96 of 1679 resvg-corpus files are
   `results.csv`-rated "resvg known wrong", and matching resvg on those
   counts as an ordinary pass in `run_corpora.py`'s default summary —
   `tests/score_known.py` already splits this out but isn't folded into
   `summary.md`, so the headline "N% pass" figure doesn't carry its
   correct/known-wrong/unrated breakdown by default.

**Verification:** `lake build` clean; `python3 tests/run_tests.py` baseline
unchanged (46/50, pre-existing, this task didn't touch `LeanSvg/*` or
`run_tests.py`); `python3 -m py_compile tests/run_corpora.py` clean; ran
`run_corpora.py` with both `--ref resvg` (unchanged output) and `--ref
suite` at widths 100/200, full resvg corpus (1679 files), both routes, to
produce the tables above.

**Could not do / left open:** did not fold `score_known.py`'s breakdown
into `run_corpora.py`'s `summary.md` — that's a real code change beyond
this audit's brief, flagged for a follow-up task. A 3-file discrepancy
between `results.csv`'s rating counts (1522/96/61) and what the native-res
measurement could actually score (1520/95/61) wasn't root-caused (likely a
title/path mismatch or one unreadable PNG); too small to affect any
conclusion.

