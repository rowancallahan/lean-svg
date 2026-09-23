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

