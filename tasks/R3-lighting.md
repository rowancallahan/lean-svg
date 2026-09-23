# R3-lighting — resvg-wrong research: lighting and displacement  (branch `claude/research-r3-lighting`)

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

- `docs/resvg-wrong/R3-lighting.md`: one section per file with the above, then a
  summary table (file, class, correct reference, one-line cause), then a
  "Questions for Rowan" list.
- `docs/resvg-wrong/R3-lighting.png`: one comparison sheet, a row per file:
  resvg | suite PNG | Chromium | ours, labelled. Keep it under 2 MB.
- **Shallow fixes (class a) are allowed** only when the suite PNG and
  Chromium agree with each other and with the spec. Put each fix in its own
  commit with the evidence in the message. The fix must keep every file resvg
  renders correctly passing: run the corpus gate below and report zero
  pass→fail on files where `results.csv` says resvg=1. (Those fixed files
  will now "fail" against resvg in our harness; list them in the doc.)

Commit early and often (the doc can be pushed in pieces); push to your branch
only. No pull request.

## Files (7)

| file | our status vs resvg (200 px) | other renderers |
|---|---|---|
| `filters/feDiffuseLighting/complex-transform.svg` | pass 1.000000 | chrome=2 firefox=1 safari=1 |
| `filters/feDisplacementMap/simple-case.svg` | pass 1.000000 | chrome=2 firefox=2 safari=2 |
| `filters/fePointLight/complex-transform.svg` | pass 1.000000 | chrome=2 firefox=1 safari=1 |
| `filters/fePointLight/primitiveUnits=objectBoundingBox.svg` | pass 1.000000 | chrome=2 firefox=1 safari=1 |
| `filters/feSpotLight/complex-transform.svg` | pass 0.999975 | chrome=2 firefox=2 safari=2 |
| `filters/feSpotLight/limitingConeAngle-anti-aliasing.svg` | pass 1.000000 | chrome=2 firefox=2 safari=1 |
| `filters/feSpotLight/primitiveUnits=objectBoundingBox.svg` | pass 1.000000 | chrome=2 firefox=2 safari=1 |

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

**Deliverables:** `docs/resvg-wrong/R3-lighting.md` (per-file findings,
summary table, questions for Rowan) and `docs/resvg-wrong/R3-lighting.png`
(176 KB, resvg | suite PNG | Chromium | ours, one row per file).

**Classification:** 2 files (a) shallow fix, done; 3 files (b) need the
same large filter-region-under-rotation/skew redesign (not lighting-
specific — a resvg-wide, upstream-acknowledged limitation, see the doc);
1 file (c) nothing to fix (the SVG has no `feDisplacementMap` element at
all — a documentation stub — and we already match the suite's reference
PNG to antialiasing noise); 1 file (d) needs a decision from Rowan
(`limitingConeAngle` anti-aliasing: spec leaves the technique unspecified
and real UAs disagree on it).

**Shallow fixes applied and pushed** (commit `61dd783`,
`LeanSvg/Filter/Lighting.lean` + `LeanSvg/Filter.lean`): `fePointLight`/
`feSpotLight`'s `x/y/z`/`pointsAtX/Y/Z` now scale by
`primitiveUnits="objectBoundingBox"` (axis coordinates by the bbox
origin+size, `z` by the bbox diagonal `sqrt((w²+h²)/2)`, per spec) —
resvg 0.48.1 (and current `main`, confirmed by fetching the file) applies
no such scaling at all. Fixes exactly the two
`primitiveUnits=objectBoundingBox.svg` files; identity for the default
`userSpaceOnUse` case (exact `f32` no-op), and grepping the whole test
corpus confirms no other file combines `objectBoundingBox` with a light
source, so no other output changes.

**Before/after (native 200 px, mean abs diff /255):**

| file | vs suite PNG, before | vs suite PNG, after | vs Chromium, after |
|---|---|---|---|
| `fePointLight/primitiveUnits=objectBoundingBox.svg` | 71.8 | 3.2 | 0.40 |
| `feSpotLight/primitiveUnits=objectBoundingBox.svg` | 49.8 | 2.0 | 0.36 |

**Corpus gate:** `run_corpora.py --compare <pre-fix baseline>`: exactly
the 2 files above move pass→fail (intended — they now diverge from
resvg's own bug), 0 files elsewhere change (1677 unchanged out of 1679).
`score_known.py`: "resvg correct" unchanged 1400/1522 (92.0%); "resvg
known wrong" 86/96 → 84/96 (the two fixed files). `lake build`: clean, no
new warnings. `check-theorems.sh`: all theorems/invariants hold.
`run_tests.py`: 46/50, same 4 failures (`12_badge`,
`14_flower_transforms`, `15_spiral_stroke`, `16_stress_2000`) confirmed
pre-existing and unrelated (re-ran against a stashed pre-fix build,
identical result). `run_adversarial.py`: 116/116 clean.
`run_tiles.py`: 50/50 byte-identical tile stitching.

**Could not do / left for follow-up:** the (b) and (d) items above are
documented but not implemented, per the task's own scope ("this task is
mainly information gathering and review") and the shallow-fix gate
("only when the suite PNG and Chromium agree ... and it's a few lines" —
neither held for the filter-region-transform bug, which is a
multi-primitive architecture change, nor cleanly for the cone
anti-aliasing, which has no single well-evidenced target). See "Questions
for Rowan" in the doc for how to proceed on both.
