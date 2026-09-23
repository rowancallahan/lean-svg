# R5-text-props — resvg-wrong research: text properties  (branch `claude/research-r5-text-props`)

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

- `docs/resvg-wrong/R5-text-props.md`: one section per file with the above, then a
  summary table (file, class, correct reference, one-line cause), then a
  "Questions for Rowan" list.
- `docs/resvg-wrong/R5-text-props.png`: one comparison sheet, a row per file:
  resvg | suite PNG | Chromium | ours, labelled. Keep it under 2 MB.
- **Shallow fixes (class a) are allowed** only when the suite PNG and
  Chromium agree with each other and with the spec. Put each fix in its own
  commit with the evidence in the message. The fix must keep every file resvg
  renders correctly passing: run the corpus gate below and report zero
  pass→fail on files where `results.csv` says resvg=1. (Those fixed files
  will now "fail" against resvg in our harness; list them in the doc.)

Commit early and often (the doc can be pushed in pieces); push to your branch
only. No pull request.

## Files (14)

| file | our status vs resvg (200 px) | other renderers |
|---|---|---|
| `text/alignment-baseline/hanging-on-vertical.svg` | fail 0.978300 | chrome=1 firefox=2 safari=1 |
| `text/direction/rtl.svg` | pass 0.995275 | chrome=1 firefox=1 safari=1 |
| `text/font-size-adjust/simple-case.svg` | pass 0.999650 | chrome=2 firefox=1 safari=1 |
| `text/font-weight/650.svg` | pass 0.999850 | chrome=1 firefox=1 safari=1 |
| `text/font/simple-case.svg` | pass 1.000000 | chrome=2 firefox=2 safari=2 |
| `text/glyph-orientation-horizontal/simple-case.svg` | pass 0.999900 | chrome=2 firefox=2 safari=2 |
| `text/glyph-orientation-vertical/simple-case.svg` | pass 0.999775 | chrome=2 firefox=2 safari=1 |
| `text/kerning/10percent.svg` | pass 0.999900 | chrome=2 firefox=2 safari=2 |
| `text/text-anchor/coordinates-list.svg` | pass 0.999900 | chrome=1 firefox=2 safari=1 |
| `text/text-decoration/style-resolving-4.svg` | pass 0.999550 | chrome=2 firefox=1 safari=1 |
| `text/text-rendering/geometricPrecision.svg` | pass 0.999800 | chrome=2 firefox=1 safari=1 |
| `text/tref/link-to-an-external-file-element.svg` | pass 0.999750 | chrome=2 firefox=2 safari=2 |
| `text/unicode-bidi/bidi-override.svg` | fail 0.986100 | chrome=1 firefox=1 safari=1 |
| `text/writing-mode/tb-and-punctuation.svg` | pass 1.000000 | chrome=1 firefox=1 safari=2 |

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

**Files changed:**
- `LeanSvg/Svg.lean` — `parseFontWeight` now falls back to `parseNumberAll`
  (clamped to CSS Fonts 4's `[1, 1000]`) for a numeric weight that isn't one
  of the recognized keywords/decade literals, instead of silently keeping
  the inherited weight. Fixes `text/font-weight/650.svg`.
- `LeanSvg/Text.lean` — `layout` now tracks a second accumulator (`adv`)
  that mirrors the pen's advance but never receives the anchor shift `x0`,
  and uses it for `lastX`/`lastY` (the fallback position handed to a later
  chunk with no explicit `x`/`y`). Fixes `text/text-anchor/coordinates-
  list.svg`.
- `docs/resvg-wrong/R5-text-props.md`, `docs/resvg-wrong/R5-text-props.png`
  — the required deliverables: per-file research/classification for all 14
  files, and the 14-row comparison sheet.

**Research summary (14 files):** 2 classified (a) and fixed (see above); 6
classified (c) deliberately not supported (`alignment-baseline/hanging-on-
vertical`, `glyph-orientation-horizontal/simple-case`, `kerning/10percent`,
`text-rendering/geometricPrecision`, `tref/link-to-an-external-file-
element`, `writing-mode/tb-and-punctuation` — mostly blocked on the
single-embedded-Latin-font policy, the no-second-file safety invariant, or
a documented resvg-parity non-goal already matching every maintained
renderer); 4 classified (b) needing real feature work of varying size
(`font-size-adjust/simple-case`, `font/simple-case`, `text-decoration/
style-resolving-4`, plus `direction/rtl` which is (b)/(d)); 3 need a
decision from Rowan (`glyph-orientation-vertical/simple-case`,
`unicode-bidi/bidi-override` which is (c)/(b)/(d), and `direction/rtl`
shared with the (b) list) — full detail, evidence and the six numbered
questions are in `docs/resvg-wrong/R5-text-props.md`.

**Before/after numbers (corpus gate, `tests/run_corpora.py --corpus resvg
--route direct`, 1679 files):**
- Baseline (before either fix): 1542/1679 pass overall (91.8%);
  `score_known.py`: resvg-correct 1400/1522 (92.0%), resvg-known-wrong
  86/96 (89.6%).
- After both fixes: 1541/1679 pass overall (91.8%); resvg-correct
  **1400/1522 (92.0%, unchanged — 0 regressions)**, resvg-known-wrong
  85/96 (88.5% — the intended -1, from `font-weight/650.svg` now
  correctly diverging from resvg). Only the two fixed files themselves
  moved in the per-file diff; 1677 files unchanged.
- `text-anchor/coordinates-list.svg`'s "ext" ink-box center moved from
  x=106 (matching resvg's bug) to x=112 (matching the suite reference's
  measured 112.2 and Chrome's 113).
- `font-weight/650.svg` line 1 (`font-weight="650"`) now renders bold,
  matching six independent renderers and the suite reference; previously
  matched resvg's non-bold mistake.
- Full verification suite run after both fixes: `lake build` clean, no new
  warnings; `bash scripts/check-theorems.sh` all theorems/invariants hold;
  `tests/run_tests.py` 46/50 (the same 4 pre-existing failures —
  `12_badge`, `14_flower_transforms`, `15_spiral_stroke`, `16_stress_2000`
  — reproduce identically on the commit before these changes, confirmed by
  reverting and re-running); `tests/run_adversarial.py` 116/116 clean;
  `tests/run_tiles.py` 50/50 byte-identical.

**Could not do / left for Rowan:** the two shallow fixes above are the only
code changes made; every other file is blocked on either a real feature, a
resvg-parity-vs-spec policy decision, or the project's no-second-file
safety invariant, per the classifications and six questions in
`docs/resvg-wrong/R5-text-props.md`.
