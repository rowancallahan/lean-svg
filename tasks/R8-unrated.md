# R8-unrated — research: the 61 files resvg's results.csv does not rate (branch `claude/research-r8-unrated`)

## Why

resvg's own `results.csv` does not rate resvg at all (0) on the files below. Our
harness scores against live resvg, so we do not know whether matching resvg is right here. Before anyone fixes these, we need a
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

- `docs/resvg-wrong/R8-unrated.md`: one section per file with the above, then a
  summary table (file, class, correct reference, one-line cause), then a
  "Questions for Rowan" list.
- `docs/resvg-wrong/R8-unrated.png`: one comparison sheet, a row per file:
  resvg | suite PNG | Chromium | ours, labelled. Keep it under 2 MB.
- **Shallow fixes (class a) are allowed** only when the suite PNG and
  Chromium agree with each other and with the spec. Put each fix in its own
  commit with the evidence in the message. The fix must keep every file resvg
  renders correctly passing: run the corpus gate below and report zero
  pass→fail on files where `results.csv` says resvg=1. (Those fixed files
  will now "fail" against resvg in our harness; list them in the doc.)

Commit early and often (the doc can be pushed in pieces); push to your branch
only. No pull request.

Additionally classify each file as: resvg correct / resvg wrong / cannot tell, so the harness can move it into the right bucket.

## Files (61)

| file | our status vs resvg (200 px) | other renderers |
|---|---|---|
| `filters/enable-background/with-mask.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/feColorMatrix/type=saturate-with-a-large-coefficient.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/feColorMatrix/type=saturate-with-negative-coefficient.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/feConvolveMatrix/bias=-0.5.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/feConvolveMatrix/bias=0.5.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/feConvolveMatrix/bias=9999.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/feConvolveMatrix/edgeMode=wrap-with-matrix-larger-than-target.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/feTile/complex-transform.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/feTurbulence/stitchTiles=stitch.svg` | pass 0.999975 | chrome=0 firefox=0 safari=0 |
| `filters/filter-functions/two-exact-urls.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/filter/in=FillPaint-on-g-without-children.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/filter/in=FillPaint-with-gradient.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/filter/in=FillPaint-with-pattern.svg` | pass 0.999575 | chrome=0 firefox=0 safari=0 |
| `filters/filter/in=FillPaint-with-target-on-g.svg` | pass 0.999575 | chrome=0 firefox=0 safari=0 |
| `filters/filter/in=FillPaint.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `filters/filter/in=StrokePaint.svg` | pass 0.999000 | chrome=0 firefox=0 safari=0 |
| `filters/filter/on-the-root-svg.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `masking/clipPath/on-the-root-svg-without-size.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `masking/mask/recursive-on-child.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `paint-servers/linearGradient/invalid-gradientTransform.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `paint-servers/pattern/invalid-patternTransform.svg` | pass 0.996425 | chrome=0 firefox=0 safari=0 |
| `paint-servers/pattern/overflow=visible.svg` | pass 0.996425 | chrome=0 firefox=0 safari=0 |
| `paint-servers/radialGradient/fr=-1.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `paint-servers/radialGradient/fr=0.5.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `paint-servers/radialGradient/invalid-gradientTransform.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `paint-servers/radialGradient/invalid-gradientUnits.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `paint-servers/radialGradient/negative-r.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `painting/fill/icc-color.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `painting/fill/rgb-int-int-int.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `painting/marker/target-with-subpaths-2.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `painting/marker/with-viewBox-1.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `painting/stroke-linejoin/arcs.svg` | pass 0.993375 | chrome=0 firefox=0 safari=0 |
| `painting/stroke-width/negative.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `shapes/rect/cap-values.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `shapes/rect/ic-values.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `shapes/rect/lh-values.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `shapes/rect/rlh-values.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `shapes/rect/vi-and-vb-values.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `structure/image/float-size.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `structure/image/no-height-on-svg.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `structure/image/no-width-and-height-on-svg.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `structure/image/no-width-on-svg.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `structure/svg/funcIRI-parsing.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `structure/svg/invalid-id-attribute-1.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `structure/svg/invalid-id-attribute-2.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `text/alignment-baseline/after-edge.svg` | pass 0.999775 | chrome=0 firefox=0 safari=0 |
| `text/alignment-baseline/baseline.svg` | pass 0.999750 | chrome=0 firefox=0 safari=0 |
| `text/alignment-baseline/ideographic.svg` | pass 0.999775 | chrome=0 firefox=0 safari=0 |
| `text/alignment-baseline/text-after-edge.svg` | pass 0.999775 | chrome=0 firefox=0 safari=0 |
| `text/direction/rtl-with-vertical-writing-mode.svg` | pass 0.999750 | chrome=0 firefox=0 safari=0 |
| `text/dominant-baseline/reset-size.svg` | pass 0.999750 | chrome=0 firefox=0 safari=0 |
| `text/dominant-baseline/use-script.svg` | pass 0.991425 | chrome=0 firefox=0 safari=0 |
| `text/font-size/negative-size.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `text/letter-spacing/large-negative.svg` | pass 0.999975 | chrome=0 firefox=0 safari=0 |
| `text/text/complex-grapheme-split-by-tspan.svg` | fail 0.961550 | chrome=0 firefox=0 safari=0 |
| `text/text/rotate-on-Arabic.svg` | fail 0.924925 | chrome=0 firefox=0 safari=0 |
| `text/textPath/complex.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `text/textPath/with-baseline-shift-and-rotate.svg` | fail 0.885025 | chrome=0 firefox=0 safari=0 |
| `text/word-spacing/large-negative.svg` | pass 1.000000 | chrome=0 firefox=0 safari=0 |
| `text/writing-mode/tb-with-rotate-and-underline.svg` | fail 0.972250 | chrome=0 firefox=0 safari=0 |
| `text/writing-mode/tb-with-rotate.svg` | fail 0.978325 | chrome=0 firefox=0 safari=0 |

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

