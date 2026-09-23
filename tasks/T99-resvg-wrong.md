# T99 — Stop copying resvg where resvg is known wrong  (branch `claude/fix-resvg-wrong`)

Of the 96 suite files `results.csv` rates resvg as failing, we still match
resvg on ~53 (`python3 tests/score_known.py <csv>`). Matching there usually
means we copy resvg's bug. T90 (read `tasks/T90-classb.md`) did a first pass;
`docs/resvg-wrong/*.md` has research per group. Rowan wants us to stop
matching where resvg is wrong and render what is correct.

1. For each of those ~53 files, score ours against the suite's PNG
   (`run_corpora.py --ref suite`) and Chromium (`--ref chrome`, see
   `tests/render_chrome.py`), and note `results.csv`'s chrome rating.
   Classify: (a) we are actually right (rating outdated or the difference is
   invisible), (b) we copy resvg's bug and a fix is within reach, (c) needs a
   decision from Rowan (spec ambiguous, Chromium and the suite disagree).
   Write the table into your task file.
2. Fix class (b), largest visible wins first. Never regress a file where
   resvg is rated correct (`score_known.py` resvg-correct count must not drop).
3. Leave class (c) as a list with one-line questions for Rowan.

Keep fixes small and local. Other agents (T95 markers, T96 text layout, T97
font styles, T98 warnings) are working concurrently: skip files in their
areas.

---

## Common rules (every lean-svg agent)

### Conduct (Rowan's rules for every agent, read first)

- **One app.** The whole job is making lean-svg good. Work only inside this
  repository's checkout. Anything outside it is a red flag: do not read,
  write or delete files elsewhere except the scratch/tool dirs the setup
  script uses (`~/.elan`, `~/toolchains`, cargo/pip caches, `/tmp`).
- **Network: only what the task needs.** Cloning the resvg source/test suite,
  installing the pinned toolchain and packages, and reading documentation or
  GitHub issues is fine. Nothing else: no SSH, no uploading data anywhere, no
  contacting services the task does not need, no account or credential use.
- **Git: your branch only.** Commit often (small commits make rollback easy)
  and push only to the one branch your task names. No force-push, no pushing
  to `main` or any other branch, no deleting branches, no pull requests
  unless your task says so.
- **No drastic actions.** Editing files in this repo that are committed and
  can be rolled back is fine. Big or irreversible commands are not: no
  `rm -rf` outside your own build/output dirs, no system changes, no killing
  processes you did not start, no changing CI or repo settings unless the
  task says so. If something gets really difficult or seems to need a
  drastic step, stop, write down what you would need and why in your task
  file's report, push that, and end: the integrator will ask Rowan.


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

## Report

Branch `claude/fix-resvg-wrong`. One renderer change (`LeanSvg/FilterApply.lean`),
one test (`tests/svg/99_feoffset_subregion.svg`), this report.

### 1. The 53 resvg-wrong files we matched

Scores are within-8 at 200 px (suite PNG and Chromium resized by
`run_corpora.py`); "over white" composites both sides over white, because
some suite PNGs store transparency as white. Chrome rating is
`results.csv`'s (1 pass, 2 fail). Class: (a) we are right or the
difference is invisible, (b) we copy a resvg bug and a fix is within reach,
(c) decision for Rowan. Research doc in brackets.

| file | chrome | vs resvg | vs suite | suite over white | vs chrome | class |
|---|---|---|---|---|---|---|
| filters/enable-background/* (20 files) | 2 | 1.000 | 0.81–1.00 | same | 0.99–1.00 | (c) [R1] |
| filters/filter/in=BackgroundAlpha-with-enable-background | 2 | 1.000 | 0.865 | 0.865 | 1.000 | (c) [R1/R2] |
| filters/filter/in=BackgroundAlpha | 2 | 1.000 | 0.851 | 0.873 | 0.964 | (c) [R1/R2] |
| filters/filter/in=BackgroundImage-with-enable-background | 2 | 1.000 | 0.851 | 0.865 | 1.000 | (c) [R1/R2] |
| filters/feDisplacementMap/simple-case | 2 | 1.000 | 1.000 | 1.000 | 1.000 | (a) |
| **filters/feFlood/partial-subregion** | 1 | 1.000 | 0.823 | 0.823 | 0.822 | **(b) fixed** |
| filters/feOffset/fractional-offset | 1 | 1.000 | 0.997 | 0.997 | 0.993 | (a) invisible (R2 root cause B) |
| filters/feSpotLight/limitingConeAngle-anti-aliasing | 2 | 1.000 | 0.986 | 0.986 | 0.983 | (c), see below |
| filters/filter/on-a-thin-rect | 1 | 1.000 | 0.987 | 0.987 | 0.984 | (a) invisible (box blur) |
| filters/filter/subregion-and-primitiveUnits=objectBoundingBox-1 | 1 | 1.000 | 0.024 | 0.945 | 0.938 | (c) box blur vs Gaussian |
| filters/filter/subregion-and-primitiveUnits=objectBoundingBox-2 | 1 | 1.000 | 0.024 | 0.945 | 0.938 | (c) same |
| masking/clip/simple-case | 2 | 1.000 | 0.641 | 0.655 | 0.968 | (c) [R7] |
| paint-servers/radialGradient/fr=0.2, fr=0.7 | 1 | 1.000 | 1.000 | 1.000 | 1.000 | (a) ≤1-level drift |
| painting/fill/valid-FuncIRI-with-a-fallback-ICC-color | 2 | 1.000 | 0.382 | 0.382 | 1.000 | (c) [R6] |
| painting/marker/on-ArcTo | 1 | 0.996 | 0.033 | 0.997 | 0.991 | (a) (T90 fixed) |
| painting/stroke-dasharray/n-0 | 2 | 0.998 | 1.000 | 1.000 | 1.000 | (a) |
| structure/image/url-to-png | 1 | 1.000 | 0.827 | 0.832 | 1.000 | (c) external file |
| structure/image/url-to-svg | 1 | 1.000 | 0.508 | 0.616 | 1.000 | (c) external file |
| structure/style/external-CSS | 1 | 1.000 | 0.360 | 0.360 | 1.000 | (c) external file |
| structure/style/important | 1 | 1.000 | 1.000 | 1.000 | 1.000 | (a) |
| structure/use/xlink-to-an-external-file | 2 | 1.000 | 0.008 | 0.954 | 1.000 | (c) external file |
| text/glyph-orientation-horizontal/simple-case | 2 | 1.000 | 0.970 | 0.970 | 0.983 | (c) [R5] |
| text/glyph-orientation-vertical/simple-case | 2 | 1.000 | 0.970 | 0.970 | 0.984 | (c) [R5] |
| text/kerning/10percent | 2 | 1.000 | 0.933 | 0.933 | 0.968 | (c) [R5] |
| text/text-anchor/coordinates-list | 1 | 0.992 | 0.012 | 0.991 | 0.992 | (a) |
| text/text-rendering/geometricPrecision | 2 | 1.000 | 0.997 | 0.997 | 0.934 | (a) |
| text/text/complex-graphemes-and-coordinates-list | 2 | 1.000 | 0.985 | 0.987 | 0.989 | (a) near; text layout (T96 area) |
| text/text/xml-lang=ja | 1 | 0.999 | 0.910 | 0.910 | 0.861 | (c) no CJK font (T97/T98 area) |
| text/textPath/method=stretch | 2 | 0.997 | 0.983 | 0.984 | 0.959 | skipped: textPath (T96 area); T90 found suite ≈ default layout |
| text/textPath/spacing=auto | 2 | 0.997 | 0.983 | 0.984 | 0.959 | skipped: same |
| text/tref/link-to-an-external-file-element | 2 | 1.000 | 0.953 | 0.953 | 0.944 | (c) external file |
| text/tspan/with-opacity | 1 | 0.993 | 0.989 | 0.989 | 0.971 | (a) (T90 fixed; font AA) |
| text/writing-mode/tb-and-punctuation | 1 | 1.000 | 0.989 | 0.989 | 0.986 | skipped: writing-mode (T96 area) |

Summary: 1 × (b), fixed; 16 × (a); 33 × (c); 3 skipped as other agents' areas.

### 2. Fix: `feOffset` is clipped to its subregion

resvg's `filter/mod.rs` clears pixels outside each primitive's subregion
except for `feOffset` ("We do not support clipping on feOffset"). The
spec (default subregion = union of input subregions), the suite and Chromium
clip it. `FilterApply.run` now clips `feOffset` like any other primitive;
the subregion choice (the input's region for a `result` input) is unchanged.

| file | vs suite | vs Chromium | vs resvg |
|---|---|---|---|
| filters/feFlood/partial-subregion | 0.823 → **1.000 pass** | 0.822 → **1.000 pass** | 1.000 → 0.823 (by design) |

`tests/svg/99_feoffset_subregion.svg`: matches Chromium 1.000; 0.847 vs
resvg by design (it exercises exactly the resvg bug).

Tried and reverted: Skia's `feSpotLight` cone anti-aliasing (linear fade
over `cos ∈ [c, c+0.016)`). It makes `limitingConeAngle-anti-aliasing`,
`=30`, `=-30` and `complex-transform` pass against the suite (100 %), but
`=30` and `=-30` are rated resvg-correct, so the resvg-correct count would
drop by 2. Question 1 below.

### 3. Class (c): questions for Rowan

1. `feSpotLight` cone AA: `limitingConeAngle=±30` (resvg=1) and
   `limitingConeAngle-anti-aliasing` (resvg=2) render identical pixels, and
   the suite PNG matches Skia's fade exactly. Follow the suite (4 files pass
   vs suite, 2 resvg=1 files fail vs resvg), or keep resvg's hard edge?
2. `enable-background`, `BackgroundImage`, `BackgroundAlpha` (23 files):
   Chromium, Firefox and Safari don't implement them (SVG 2 removed them).
   Keep them unsupported?
3. Box blur vs true Gaussian (`subregion-and-primitiveUnits=objectBoundingBox-1/2`,
   0.945 over white): change the blur algorithm, which moves every resvg=1
   blur file, or keep resvg's?
4. `clip` property, `icc-color` fallback, `glyph-orientation-*`,
   `kerning=<length>`: legacy/removed features Chromium also ignores. Keep
   ignoring them?
5. External files (`url-to-png`, `url-to-svg`, `external-CSS`,
   `xlink-to-an-external-file`, `tref` external): the pure renderer reads one
   file. Keep it that way?
6. `xml-lang=ja`: needs a CJK font. Add one (size), or leave it?

### Whole suite

| gate | before | after |
|---|---|---|
| vs resvg, 100 px | 1543 | 1542 (only partial-subregion, resvg=2) |
| vs resvg, 200 px | 1567 | 1566 (same) |
| `score_known.py` resvg correct (100 / 200 px) | 1438 / 1460 | 1438 / 1460 |
| `score_known.py` resvg known wrong matched (200 px) | 53 | 52 |
| vs suite PNG | 1211 | 1212 |
| vs Chromium (filters/feFlood, feOffset) | — | +1, 0 lost |

Zero pass→fail on resvg-correct files at 100 and 200 px. `lake build` no
warnings; `check-theorems.sh` theorems ok; `run_tests.py` 57/67 (no existing
file moved; the new `99_` fails vs resvg by design); `run_adversarial.py`
143/143 clean; `run_tiles.py` 67/67 byte-identical.
