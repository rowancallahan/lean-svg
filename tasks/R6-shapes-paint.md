# R6-shapes-paint — resvg-wrong research: shapes and paint  (branch `claude/research-r6-shapes-paint`)

## Why

resvg's own `results.csv` marks resvg as **wrong** on the files below. Our
harness scores against live resvg, so where we "pass" we are copying resvg's
mistake. Rowan does not want that. Before anyone fixes these, we need a
written, per-file understanding of what the correct output is, so later fix
work (Opus agents, and decisions with Rowan) goes quickly.

This task is mainly **information gathering and review**. It is not a
feature task.

## What to do, per file

1. Render four ways at 200 px wide: ours (`.lake/build/bin/lean-svg f out
   --width 200`), resvg (`resvg --skip-system-fonts --use-fonts-dir
   tests/corpora/resvg-test-suite/fonts -w 200`), the suite's own PNG next to
   the SVG (resize to 200 wide if needed), and Chromium
   (`python3 tests/render_chrome.py OUT 200 file.svg`).
2. Read the SVG: its `<title>`, comments and structure say what it tests.
   Read the relevant spec section (SVG 1.1/2, Filter Effects, CSS). Search
   the resvg GitHub issues/changelog for the test or feature
   (`https://github.com/linebender/resvg`); note links.
3. Decide what the **correct** output is and why, and which reference(s) show
   it (suite PNG, Chromium, spec reasoning). Say how confident you are.
   Browsers can be wrong too; the `results.csv` columns for other renderers
   are hints (1 = passes, 2 = fails, 0 = untested, 3 = crash).
4. Classify it: **(a)** shallow fix (a few lines, clear evidence), **(b)**
   needs a feature or real work (estimate size), **(c)** deliberately not
   supported (deprecated, or conflicts with Rowan's safety rules: no external
   resources, pure total functions, bounded work), **(d)** needs a decision
   from Rowan (write the question and the options).

## Deliverables

- `docs/resvg-wrong/R6-shapes-paint.md`: one section per file with the above, then a
  summary table (file, class, correct reference, one-line cause), then a
  "Questions for Rowan" list.
- `docs/resvg-wrong/R6-shapes-paint.png`: one comparison sheet, a row per file:
  resvg | suite PNG | Chromium | ours, labelled. Keep it under 2 MB.
- **Shallow fixes (class a) are allowed** only when the suite PNG and
  Chromium agree with each other and with the spec. Put each fix in its own
  commit with the evidence in the message. The fix must keep every file resvg
  renders correctly passing: run the corpus gate below and report zero
  pass→fail on files where `results.csv` says resvg=1. (Those fixed files
  will now "fail" against resvg in our harness; list them in the doc.)

Commit early and often (the doc can be pushed in pieces); push to your branch
only. No pull request.

## Files (11)

| file | our status vs resvg (200 px) | other renderers |
|---|---|---|
| `paint-servers/radialGradient/fr=0.2.svg` | pass 1.000000 | chrome=1 firefox=1 safari=1 |
| `paint-servers/radialGradient/fr=0.7.svg` | pass 1.000000 | chrome=1 firefox=1 safari=1 |
| `painting/fill/rgba-0-127-0-50percent.svg` | pass 1.000000 | chrome=1 firefox=1 safari=1 |
| `painting/fill/valid-FuncIRI-with-a-fallback-ICC-color.svg` | pass 1.000000 | chrome=2 firefox=2 safari=2 |
| `painting/marker/on-ArcTo.svg` | pass 0.999800 | chrome=1 firefox=1 safari=2 |
| `painting/stroke-dasharray/n-0.svg` | pass 0.997500 | chrome=2 firefox=2 safari=1 |
| `shapes/rect/ch-values.svg` | pass 1.000000 | chrome=1 firefox=2 safari=1 |
| `shapes/rect/q-values.svg` | pass 1.000000 | chrome=1 firefox=1 safari=1 |
| `shapes/rect/rem-values.svg` | pass 1.000000 | chrome=1 firefox=1 safari=1 |
| `shapes/rect/vmin-and-vmax-values.svg` | pass 1.000000 | chrome=1 firefox=1 safari=2 |
| `shapes/rect/vw-and-vh-values.svg` | pass 1.000000 | chrome=1 firefox=1 safari=2 |

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


**Corpus gate for any code change:** `python3 tests/run_corpora.py --corpus resvg --route direct --out /tmp/after --no-worst --compare <baseline csv>` (make the baseline first without your change) and `python3 tests/score_known.py /tmp/after/resvg_direct.csv`; plus `lake build`, `bash scripts/check-theorems.sh`, `tests/run_tests.py`, `tests/run_adversarial.py`, `tests/run_tiles.py`.

## Report

**Deliverables:** `docs/resvg-wrong/R6-shapes-paint.md` (per-file writeup,
summary table, questions for Rowan) and `docs/resvg-wrong/R6-shapes-paint.png`
(comparison sheet, resvg | suite PNG | Chromium | ours, 83 KB).

**Classified:** 2 files (a, fixed), 2 files (c, not fixing — negligible/
already-correct), 2 files (b, not fixed — real work, narrow payoff), 3 files
(d, not fixed — needs Rowan's call), 1 file (b+d, not fixed — needs both a
feature and a reference decision). Full reasoning per file in the doc.

**Fixed (2 commits):**
- `54b9aad` — `Q` (120/127 px) and `rem` (root element's own `font-size`,
  new `Style.rootFontSize`) length units on shape geometry
  (`shapes/rect/q-values.svg`, `shapes/rect/rem-values.svg`).
- `7464e3b` — percentage alpha in `rgba()`/`hsla()`, CSS Color 4
  (`painting/fill/rgba-0-127-0-50percent.svg`); reverses a previously
  deliberate match to a confirmed resvg 0.48.1/svgtypes 0.16.1 bug, now that
  this task calls for it. `grep` confirmed this is the only corpus file
  using a percentage alpha, so the change cannot touch resvg parity
  anywhere else.

**Not fixed, with why (see doc for full detail):** the two `fr` gradient
files (≤1-level tiny-skia rounding noise, inherent to resvg's own
dependency, only when `fr≠0`); the ICC-color-fallback file (we already
match resvg *and* every real browser — the suite's own PNG is the stale
outlier); the arc marker-orientation file (Chromium measurably closer to
the suite PNG than resvg, but the fix needs the exact arc-tangent formula,
not isolated); the zero-gap dasharray file (our dash deferral is a faithful
port of Skia's actual `SkDashPath::InternalFilter`, wrong only in one
coincidental edge case — perimeter an exact multiple of the dash cycle and
a zero-length gap); `ch` (font-metric-dependent, and the three references
disagree with each other, not just with resvg); `vw`/`vh`/`vmin`/`vmax`
(Chromium + spec + Firefox all agree on 60 px, but the suite's own PNG shows
~150 px — fails the task's "suite PNG and Chromium must agree" auto-fix
gate despite Chromium clearly being right, so left for Rowan's decision).

**Before/after (corpus gate, `tests/run_corpora.py --corpus resvg --route
direct`, 200 px, pre-fix baseline vs. both fixes applied):** exactly 3 files
move pass→fail against resvg — `rgba-0-127-0-50percent.svg`, `q-values.svg`,
`rem-values.svg` (all three intentional, all three listed above). 0 newly
passing, 1676/1679 corpus files byte-for-byte unchanged, resvg-correct
bucket unchanged at 1400/1522 (`tests/score_known.py`). `lake build`,
`scripts/check-theorems.sh`, `tests/run_tests.py` (46/50 both before and
after — same 4 pre-existing, unrelated failures, confirmed with `git
stash`), `tests/run_adversarial.py` (116/116) and `tests/run_tiles.py`
(50/50) all pass.

**Could not do:** the 9 unfixed files above, and 4 open questions for Rowan
in the doc (`vw`/`vh`/`vmin`/`vmax` vs. the suite's apparently-wrong PNG;
whether `ch` is worth building given no trustworthy reference; whether the
`n-0` dasharray edge case and the `on-ArcTo` marker-angle gap are worth
dedicated follow-up tasks).
