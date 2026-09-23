# T90 — fix the class (b) files resvg gets wrong  (branch `claude/feat-classb`)

Research (`docs/resvg-wrong/R2…R7`) classified these as real work with a
clear correct answer. They cluster into a few root causes; fix causes, not
files. Suggested order (largest first):

1. **Filter regions under rotation/skew** (11 files, `complex-transform` and
   friends): resvg computes the filter region as an axis-aligned device box;
   the spec's region follows the element's transform. See R2 "root cause A"
   and R3. Keep every filter budget and the tile byte-identity.
2. **Layers on `tspan`/`textPath`** (5 files): `opacity`, `clip-path`,
   `mask`, `filter` on a text span must make that span a compositing layer.
3. **`textPath`**: `path=` attribute (SVG 2), `side="right"`, `method=
   stretch`, `spacing=auto`. Follow the SVG 2 spec and the suite PNG
   (Firefox agrees); Chromium does not implement these, so it is not a
   reference here.
4. The rest, one by one: `font-size-adjust`, the `font` shorthand,
   `text-decoration` style resolving, marker on an arc, dasharray `n 0`,
   mask `color-interpolation=linearRGB`.

## Scoring: these are files resvg gets WRONG

Do not match resvg here. The reference is the suite's own expected PNG next
to each SVG, and Chromium where `results.csv` rates Chrome correct. Read the
file's section in the research doc named below first; it names the correct
reference and root cause for each.

- Check a file against the suite PNG at its native 500 px:
  `python3 tests/run_corpora.py --corpus resvg --route direct --ref suite --dir <dir> --out /tmp/s --no-worst`
  (a file is right when it passes there; this mode compares at the PNG's own width).
- Against Chromium: `--ref chrome`.
- Guard rail: **zero pass→fail on files resvg renders correctly**
  (`results.csv` resvg=1) at both 100 and 200 px against live resvg (the
  normal gate). Files resvg gets wrong that you fix will move from "pass vs
  resvg" to "fail vs resvg"; list each one in your report with its suite-PNG
  and Chromium scores before/after.

Rowan's image/text safety rules still hold (pure, total, bounded; no
external resources). Commit per root cause.

## Files (28)

| file | research doc | reference | cause |
|---|---|---|---|
| `filters/feFlood/complex-transform.svg` | `docs/resvg-wrong/R2-filters.md` | suite, chrome | root cause A: filter region loses rotation |
| `filters/feGaussianBlur/complex-transform.svg` | `docs/resvg-wrong/R2-filters.md` | suite, chrome | root cause A: blur axis doesn't rotate |
| `filters/feImage/link-on-an-element-with-complex-transform.svg` | `docs/resvg-wrong/R2-filters.md` | suite, chrome | root cause A |
| `filters/feImage/with-subregion-5.svg` | `docs/resvg-wrong/R2-filters.md` | suite, chrome | `feImage` `data:` URI decode is a stub (`FeImage.dataCanvas`) |
| `filters/feMerge/complex-transform.svg` | `docs/resvg-wrong/R2-filters.md` | suite | root cause A, small magnitude |
| `filters/feOffset/complex-transform.svg` | `docs/resvg-wrong/R2-filters.md` | suite | root cause A, small magnitude |
| `filters/feTurbulence/complex-transform.svg` | `docs/resvg-wrong/R2-filters.md` | suite, chrome | root cause A: turbulence coords don't rotate |
| `filters/filter/transform-on-shape-with-filter-region.svg` | `docs/resvg-wrong/R2-filters.md` | suite, firefox, safari (chrome itself is the outlier) | root cause A |
| `filters/feDiffuseLighting/complex-transform.svg` | `docs/resvg-wrong/R3-lighting.md` | suite PNG, Chromium | filter region computed as an axis-aligned device-pixel bbox instead of following the element's rotate+skew transform (resvg-wide limitation, |
| `filters/fePointLight/complex-transform.svg` | `docs/resvg-wrong/R3-lighting.md` | suite PNG, Chromium | same filter-region-transform bug as the diffuse-lighting entry |
| `filters/feSpotLight/complex-transform.svg` | `docs/resvg-wrong/R3-lighting.md` | suite PNG, Chromium | same filter-region-transform bug |
| `text/tspan/with-opacity.svg` | `docs/resvg-wrong/R4-text-layout.md` | suite + chrome | `opacity` on `tspan` parsed but never promoted to a layer |
| `text/tspan/with-clip-path.svg` | `docs/resvg-wrong/R4-text-layout.md` | suite + chrome | `clip-path` on `tspan` parsed but never promoted to a layer |
| `text/tspan/with-mask.svg` | `docs/resvg-wrong/R4-text-layout.md` | suite + chrome | `mask` on `tspan` parsed but never promoted to a layer |
| `text/tspan/with-filter.svg` | `docs/resvg-wrong/R4-text-layout.md` | suite + chrome | `filter` on `tspan` parsed but never promoted to a layer |
| `text/textPath/with-filter.svg` | `docs/resvg-wrong/R4-text-layout.md` | suite + chrome | `filter` on `textPath` parsed but never promoted to a layer |
| `text/textPath/with-path.svg` | `docs/resvg-wrong/R4-text-layout.md` | suite PNG (Firefox only among renderers) | `path` attribute on `textPath` (SVG 2) not implemented |
| `text/textPath/with-path-and-xlink-href.svg` | `docs/resvg-wrong/R4-text-layout.md` | suite PNG (Firefox only) | `path` not implemented; `href` also fails our (and usvg's) `#`-required rule |
| `text/textPath/with-invalid-path-and-xlink-href.svg` | `docs/resvg-wrong/R4-text-layout.md` | suite PNG (Firefox only) | `path`-invalid→`href`-fallback not implemented; `href` also fails the `#`-required rule |
| `text/textPath/side=right.svg` | `docs/resvg-wrong/R4-text-layout.md` | suite PNG (Firefox only) | `side="right"` parsed but never applied |
| `text/textPath/method=stretch.svg` | `docs/resvg-wrong/R4-text-layout.md` | none cleanly (all renderers marked wrong incl. resvg) | `method="stretch"` not implemented; existing output already close |
| `text/textPath/spacing=auto.svg` | `docs/resvg-wrong/R4-text-layout.md` | none cleanly (all renderers marked wrong incl. resvg) | `spacing="auto"` not implemented; existing output already close |
| `text/font-size-adjust/simple-case.svg` | `docs/resvg-wrong/R5-text-props.md` | firefox/safari/suite/CSS Fonts 4 | property parsed nowhere; metrics already available in `Font.lean` |
| `text/font/simple-case.svg` | `docs/resvg-wrong/R5-text-props.md` | suite (structurally) | `font` shorthand unexpanded for bare presentation attributes (resvg: only one of two delivery forms; ours: neither) |
| `text/text-decoration/style-resolving-4.svg` | `docs/resvg-wrong/R5-text-props.md` | firefox/safari/suite | decoration thickness/offset use the rendered glyph's font-size, not the declaring ancestor's |
| `painting/marker/on-ArcTo.svg` | `docs/resvg-wrong/R6-shapes-paint.md` | Chromium (closest to suite PNG) | arc→cubic flattening's end tangent feeds the marker bisector; ours/resvg's flattening differs slightly from Chrome's analytic tangent |
| `painting/stroke-dasharray/n-0.svg` | `docs/resvg-wrong/R6-shapes-paint.md` | Chromium (exact match to suite PNG) | Skia's (ported) closed-path dash-deferral heuristic wrongly merges a closure that coincidentally lands exactly on a cycle boundary with a ze |
| `masking/mask/color-interpolation=linearRGB.svg` | `docs/resvg-wrong/R7-structure-masking.md` | suite PNG + Chromium (agree) | usvg's `<mask>` never reads `color-interpolation`, always computes luminance in sRGB |

---

## Common rules (every lean-svg agent)


**Branches (Rowan's rule).** Push only to the one branch this task names.
The integrator merges it into `claude/beautiful-brown-nd2o1h` and then
deletes it, so do not create any other branch, tag or pull request. You may
use subagents inside your own session for research or parallel work; they
must not push anywhere; you collect their work into your branch.

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
