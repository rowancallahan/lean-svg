# T72 — text round 3 (branch `claude/feat-text-3`)

You are the only agent touching `LeanSvg/Text.lean`, `Baseline.lean`,
`TextPath.lean` and the text parts of `Svg.lean` in this wave. Read the
reports of T50, T54, T55, T56 first (tasks/). Remaining resvg-correct text
failures are below. Triage by cause and fix the biggest shared causes first.
Fonts: only the embedded Noto Sans subsets exist; if a file needs a glyph or
face we do not embed (e.g. font-stretch condensed, small-caps), check what
resvg does with the suite's own fonts dir and decide whether embedding a
further OFL subset is justified (document size impact; Rowan prefers small).

Remaining resvg-correct failures at 200 px (from `tests/score_known.py` split):

- `text/alignment-baseline/middle-on-textPath.svg` (fail, within-8 0.954750)
- `text/alignment-baseline/two-textPath-with-middle-on-first.svg` (fail, within-8 0.952000)
- `text/font-family/font-list.svg` (fail, within-8 0.982225)
- `text/font-family/source-sans-pro.svg` (fail, within-8 0.982225)
- `text/font-kerning/arabic-script.svg` (fail, within-8 0.981100)
- `text/font-stretch/extra-condensed.svg` (fail, within-8 0.973950)
- `text/font-stretch/inherit.svg` (fail, within-8 0.973950)
- `text/font-stretch/narrower.svg` (fail, within-8 0.973950)
- `text/font-variant/inherit.svg` (fail, within-8 0.961125)
- `text/font-variant/small-caps.svg` (fail, within-8 0.961125)
- `text/font-weight/bolder-with-clamping.svg` (fail, within-8 0.961850)
- `text/font-weight/lighter-with-clamping.svg` (fail, within-8 0.959150)
- `text/font-weight/lighter-without-parent.svg` (fail, within-8 0.959150)
- `text/font/font-shorthand.svg` (fail, within-8 0.969550)
- `text/lengthAdjust/spacingAndGlyphs.svg` (fail, within-8 0.956625)
- `text/lengthAdjust/text-on-path.svg` (fail, within-8 0.964100)
- `text/lengthAdjust/vertical.svg` (fail, within-8 0.957175)
- `text/lengthAdjust/with-underline.svg` (fail, within-8 0.955125)
- `text/letter-spacing/filter-bbox.svg` (fail, within-8 0.839925)
- `text/letter-spacing/mixed-scripts.svg` (fail, within-8 0.986200)
- `text/letter-spacing/on-Arabic.svg` (fail, within-8 0.987150)
- `text/text-anchor/on-tspan-with-arabic.svg` (fail, within-8 0.968850)
- `text/text-decoration/underline-with-rotate-list-4.svg` (fail, within-8 0.986250)
- `text/text-rendering/optimizeSpeed.svg` (fail, within-8 0.989300)
- `text/text-rendering/with-underline.svg` (fail, within-8 0.985125)
- `text/text/bidi-reordering.svg` (fail, within-8 0.982425)
- `text/text/complex-graphemes.svg` (fail, within-8 0.980775)
- `text/text/escaped-text-4.svg` (fail, within-8 0.976650)
- `text/text/fill-rule=evenodd.svg` (fail, within-8 0.971075)
- `text/text/filter-bbox.svg` (fail, within-8 0.763525)
- `text/text/ligatures-handling-in-mixed-fonts-1.svg` (fail, within-8 0.988625)
- `text/text/ligatures-handling-in-mixed-fonts-2.svg` (fail, within-8 0.972775)
- `text/text/real-text-height.svg` (fail, within-8 0.988575)
- `text/text/rotate-with-multiple-values-and-complex-text.svg` (fail, within-8 0.927125)
- `text/text/x-and-y-with-multiple-values-and-arabic-text.svg` (fail, within-8 0.958675)
- `text/text/zalgo.svg` (fail, within-8 0.936875)
- `text/textLength/arabic-with-lengthAdjust.svg` (fail, within-8 0.970700)
- `text/textLength/arabic.svg` (fail, within-8 0.980575)
- `text/textPath/dy-with-tiny-coordinates.svg` (fail, within-8 0.939375)
- `text/textPath/m-L-Z-path.svg` (fail, within-8 0.944800)
- `text/textPath/with-baseline-shift.svg` (fail, within-8 0.894225)
- `text/textPath/with-underline.svg` (fail, within-8 0.979600)
- `text/tspan/bidi-reordering.svg` (fail, within-8 0.977500)
- `text/writing-mode/arabic-with-rl.svg` (fail, within-8 0.980850)
- `text/writing-mode/mixed-languages-with-tb-and-underline.svg` (fail, within-8 0.984475)
- `text/writing-mode/mixed-languages-with-tb.svg` (fail, within-8 0.979775)

Target: every file above passing at both widths, where achievable without breaking the invariants.

---

## Common rules (every lean-svg agent)

You are one of ~15 agents working in parallel on lean-svg, a total, float-free
SVG→PNG renderer in Lean 4 whose output is compared against resvg 0.48.1.
An integrator merges all branches afterwards, so **keep your diff small and
local**: prefer new functions/new modules (`LeanSvg/<Feature>.lean`, imported
from `LeanSvg.lean`) over rewriting shared code in `Svg.lean` / `Render.lean`.
No drive-by refactors, renames or reformatting of code you do not need.

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

**Baseline first, before any edit:**
```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/base --no-worst
python3 tests/run_tests.py
```

**Verification before you push (all must hold):**
1. `lake build` — no errors, no new warnings.
2. `bash scripts/check-theorems.sh` prints `theorems ok`. Note
   `proofs/SizeBound.lean` reasons about `render`; if your change breaks it,
   fix the proof, do not delete or weaken it.
3. Full corpus with delta table (the fast 100 px pass), and ALSO the default
   200 px pass that is the headline number: run the same command without
   `--fast` into `/tmp/base200` before editing and `/tmp/after200` after, and
   compare. Zero pass→fail at either width.
   Fast:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/<task number>_<feature>.svg` (use your
   task number as the file number, e.g. `71_image_gif.svg`, so files never
   collide) exercising the feature
   if it fits the local corpus style 

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.
