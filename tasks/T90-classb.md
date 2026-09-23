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

## Report

Branch `claude/feat-classb`, five commits (one per root cause, the last
bundles four small ones).

### What changed

1. **Filter regions under rotation/skew** — new `LeanSvg/FilterFrame.lean`,
   wired into `Render.lean`'s filter layer (`Layer.back`).  When the device
   matrix of the filter's user space has `b ≠ 0 || c ≠ 0`, the layer is a
   local frame `S · user − (x0, y0)` with `S` the matrix's column lengths;
   the filters run there unchanged (`fts` is an axis-aligned scale, their
   ordinary case) and the result is resampled bilinearly (transparent
   outside) back through `D · S⁻¹`.  `D` is taken in whole-frame coordinates
   (the parent's `vx/vy` added back), so tiles and bands stay byte-identical
   (`run_tiles.py` 60/60, `--threads 4` identical on the new test).
   *Gated*: the local frame is used only when the result depends on
   orientation (`FilterFrame.sensitive`: an anisotropic blur/morphology, a
   non-zero offset/drop-shadow, anything that fills its region — flood,
   turbulence, image, tile, lighting, displacement, convolve — or an explicit
   subregion) or when the filter region cuts the content (`nodeBox` of the
   content in the local frame reaches past the region).  An isotropic blur on a
   rotated shape keeps resvg's path: resampling there only adds low-alpha
   colour noise that the straight-RGBA metric punishes
   (`filter/transform-on-shape.svg`, `with-multiple-transforms-1.svg`, both
   resvg=1, went pass→fail without the gate).  Budgets: the local layer is
   charged to `maxFilterWork`/`maxLayerPixels` like the ordinary one; past
   `maxFilterPixels` it falls back to the ordinary (resvg) layer.
   Also: `feFlood` with `primitiveUnits="objectBoundingBox"` defaults a
   missing `x/y/width/height` to the filter region (spec, suite, Chromium),
   not usvg's `0 0 1 1` of the bbox (`Filter.primRegion`).
2. **Layers on `tspan`/`textPath`** — `Svg.textShapes` records which spans
   carry `opacity`/blend/isolation/`clip-path`/`mask`/`filter`
   (`SpanLayers`), `Text.layout` returns a font-metric box per run style, and
   the `<text>` branch brackets each span's runs in `groupBegin`/`groupEnd`
   with its own clip use, mask use and resolved filter (object bounding box =
   the span's metric box).  Nesting is bounded by `maxLayerDepth` (past it the
   span renders without its layer).  Pattern content ignores span layers.
3. **`textPath`** — SVG 2 `path` attribute (inline path in the `<text>`'s user
   space, wins over `href`, falls back to it when it does not parse);
   `side="right"` (`TextPath.Table.reverse`: the path traversed backwards); a
   `href` without `#` is taken as an id (only textPath; only
   `with-invalid-path-and-xlink-href.svg` in the corpus has one).
4. **The rest**
   - `font-size-adjust` (number form): used size × adjust / (xHeight/upem) of
     the chosen face, applied in `Text.layout` once faces are loaded.
   - `font` shorthand, both as attribute and in `style`/CSS (usvg: CSS only),
     resetting style/weight/kerning/size-adjust like usvg's CSS expansion.
     Bold-italic still renders bold (no bold-italic face; T91's scope).
   - text-decoration offset/thickness use the font size of the declaring
     element (`SpanProps.underlineSize` etc.).
   - `marker-mid` is not placed at the joins where `arcPath` splits an arc into
     cubics (`Style.arcJoins`, set on `path` shapes only).  This was the real
     difference in `on-ArcTo.svg`: the suite/Chromium draw 2 markers, we and
     resvg drew 3.
   - `mask` with `color-interpolation="linearRGB"`: luminance on the
     demultiplied colour through resvg's sRGB→linear table
     (`Mask.maskValueLinear`).
   - `stroke-dasharray/n-0.svg`: nothing to do — already matches the suite PNG
     exactly (within-8 1.000 at 500 px) before this task.

### Skipped

- `textPath method="stretch"` / `spacing="auto"`: the suite PNG is the
  default layout (no visible stretch), which we already produce (0.983 vs
  suite, same as plain textPath files — font AA).  No change.
- feTurbulence under skew (0.864 vs suite): at parity with the *upright*
  turbulence files (0.82–0.92 vs suite), so the remainder is noise sampling,
  not the frame.
- Remaining filter gaps are root cause B (box blur vs Gaussian) and
  spot-light cone anti-aliasing, both also present on upright files.

### Metric artefacts (not fixable in the renderer)

Several suite PNGs store transparent pixels as `(255,255,255,0)` or have an
opaque white background, so the raw straight-RGBA within-8 cannot pass even
when the picture matches.  Composited over white at the PNG's own 500 px, ours
now scores: feImage/with-subregion-5 0.965, textPath/with-path (and the two
siblings) 0.988, side=right 0.991, font-size-adjust 0.988, marker/on-ArcTo
0.997, mask linearRGB 1.000.

### Target files: within-8, before → after

| file | suite | chrome |
|---|---|---|
| feFlood/complex-transform | 0.760 → **0.997 pass** | 0.755 → **0.991 pass** |
| feGaussianBlur/complex-transform | 0.773 → 0.964 | 0.765 → 0.961 |
| feImage/link-on-an-element-with-complex-transform | 0.709 → **0.997 pass** | 0.704 → **0.992 pass** |
| feImage/with-subregion-5 | 0.062 → 0.171 (0.965 over white) | 0.783 → **0.994 pass** |
| feMerge/complex-transform | 0.894 → 0.976 | 0.889 → 0.961 |
| feOffset/complex-transform | 0.945 → **0.997 pass** | 0.939 → 0.989 |
| feTurbulence/complex-transform | 0.546 → 0.864 | 0.539 → 0.761 |
| filter/transform-on-shape-with-filter-region | 0.837 → 0.958 | 0.867 → 0.940 |
| feDiffuseLighting/complex-transform | 0.747 → **0.997 pass** | 0.732 → 0.901 |
| fePointLight/complex-transform | 0.696 → **0.994 pass** | 0.695 → 0.981 |
| feSpotLight/complex-transform | 0.570 → 0.968 | 0.580 → 0.954 |
| tspan/with-opacity | 0.985 → 0.989 | 0.971 → 0.971 |
| tspan/with-clip-path | 0.971 → **0.992 pass** | 0.948 → 0.970 |
| tspan/with-mask | 0.952 → 0.989 | 0.935 → 0.946 |
| tspan/with-filter | 0.852 → 0.976 | 0.867 → 0.869 |
| textPath/with-filter | 0.879 → 0.957 | 0.870 → 0.885 |
| textPath/with-path | 0.010 → 0.026 (0.988 over white) | 0.999 → 0.970 (Chromium has no `path`) |
| textPath/with-path-and-xlink-href | 0.010 → 0.026 (0.988 over white) | 0.999 → 0.970 (same) |
| textPath/with-invalid-path-and-xlink-href | 0.010 → 0.026 (0.988 over white) | 0.999 → 0.970 (same) |
| textPath/side=right | 0.906 → 0.933 (0.991 over white) | 0.959 → 0.948 (Chromium has no `side`) |
| textPath/method=stretch | 0.983 → 0.983 | 0.959 → 0.959 |
| textPath/spacing=auto | 0.983 → 0.983 | 0.959 → 0.959 |
| font-size-adjust/simple-case | 0.012 → 0.016 (0.988 over white) | 0.946 → 0.956 |
| font/simple-case | 0.912 → 0.945 | 0.996 → 0.925 (Chromium used a substitute font, R5) |
| text-decoration/style-resolving-4 | 0.955 → 0.984 | 0.921 → 0.895 |
| marker/on-ArcTo | 0.033 → 0.033 (0.997 over white) | 0.987 → **0.991 pass** |
| stroke-dasharray/n-0 | 1.000 → 1.000 | 1.000 → 1.000 |
| mask/color-interpolation=linearRGB | 0.458 → 0.879 (1.000 over white) | 0.458 → 0.878 |

### Whole suite

- vs suite PNG: 1190 → **1197** pass; 0 pass→fail; fail→pass: the five
  filter files above, tspan/with-clip-path, and `text/font/font-shorthand.svg`.
- vs Chromium: 1011 → 1011 pass; fail→pass feFlood, feImage ×2,
  marker/on-ArcTo; pass→fail the three `textPath path=` files and
  font/simple-case, all features Chromium does not implement / renders with a
  substitute font (R4, R5).
- vs resvg (gate): 100 px 1553 → 1530, 200 px 1578 → 1555.  Every pass→fail
  is a file resvg renders wrong (`results.csv` resvg=2), i.e. the target list
  (23 files), plus `filters/feTile/complex-transform.svg`, which no renderer
  is rated on (all 0) and which moved towards the suite (0.796 → 0.820).
  One fail→pass: `text/font/font-shorthand.svg` (resvg=1).  **Zero pass→fail
  on resvg=1 files at 100 and 200 px.**
- `run_tests.py`: 55/59 → 53/60.  `40_feimage` (99.80 → 97.36) and
  `44_turbulence` (98.21 → 73.15) drop because each contains a rotated
  feImage/feTurbulence, which now follows the element as the spec requires
  and no longer matches resvg; the new `90_filter_rotate.svg` fails vs resvg
  by design.  No other file moved.
- `run_adversarial.py` 136/136 clean; `run_tiles.py` 60/60 byte-identical;
  `check-theorems.sh` theorems ok; `lake build` no warnings.
