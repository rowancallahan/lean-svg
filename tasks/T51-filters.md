# T51 — filter foundation and simple primitives  (branch `claude/feat-filters`)

Filters are the biggest failing cluster (~250 files). Build the foundation
and the simple primitives, matching resvg 0.48.1 (`crates/usvg/src/parser/filter.rs`,
`crates/resvg/src/filter/mod.rs` and friends). Everything in fixed point /
integer arithmetic; no floats. Follow resvg's algorithms exactly where it
matters for pixels (e.g. its box-blur vs IIR choice for Gaussian blur and its
rounding), since the harness tolerance is 8 levels.

Foundation: `filter="url(#id)"` on shapes and groups (element becomes a
layer); `filterUnits`/`primitiveUnits` and the filter region (default
-10%/-10%/120%/120%) and per-primitive subregions; the `in`/`in2`/`result`
graph with `SourceGraphic`, `SourceAlpha` (BackgroundImage etc. as usvg
treats them); `color-interpolation-filters` linearRGB (default) vs sRGB with
exact integer LUTs matching resvg's conversion tables; invalid references →
element not rendered (usvg rules); multiple filters in a list
(`filter="url(#a) url(#b)"`); CSS filter functions (`blur()`,
`drop-shadow()`, `grayscale()`, `sepia()`, `saturate()`, `hue-rotate()`,
`invert()`, `opacity()`, `brightness()`, `contrast()`) — see
`filters/filter-functions`.

Primitives in this task: `feFlood` (+flood-color/flood-opacity), `feOffset`,
`feMerge`, `feBlend`, `feComposite` (all operators incl. arithmetic),
`feColorMatrix`, `feGaussianBlur`, `feDropShadow`. Unsupported primitives
(lighting, turbulence, morphology, convolve, componentTransfer, tile, image,
displacement) should behave exactly as usvg does for an unknown primitive
(check — probably transparent black result); a wave-2 agent will add them, so
make adding a primitive a local change: one constructor + one function in
`LeanSvg/Filter.lean` (or `LeanSvg/Filter/*.lean`).

**Resource bounds (hard):** the filter region can be much larger than the
shape; clamp every intermediate surface to region ∩ canvas (or resvg's
equivalent), bound blur radius work, and bound primitive count per filter.
Add adversarial cases (huge stdDeviation, huge region, 1000 primitives) to
`tests/adversarial/`.

Target dirs: `filters/filter`, `filters/filter-functions`, `filters/feFlood`,
`flood-color`, `flood-opacity`, `feOffset`, `feMerge`, `feBlend`,
`feComposite`, `feColorMatrix`, `feGaussianBlur`, `feDropShadow`,
`enable-background` (usvg behaviour only).

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
3. Full corpus with delta table:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/NN_<feature>.svg` exercising the feature
   if it fits the local corpus style (pick an unused number; collisions with
   other agents are resolved by the integrator).

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.

---

## What was implemented

Files: `LeanSvg/Filter.lean` (model, pre-pass, resolution), `LeanSvg/FilterApply.lean`
(pixels), hooks in `LeanSvg/Svg.lean` (`Style.filterRaw`, `GroupInfo.filters`/
`passthrough`/`dropped`, patch on close) and `LeanSvg/Render.lean` (filter
layers, `closeLayer`, budgets), `DESIGN.md` §3.11.

* **Resolution (usvg `parser/filter.rs`).** `filter="url(#a) url(#b)"` lists and
  the ten CSS functions (`blur`, `drop-shadow`, `grayscale`, `sepia`,
  `saturate`, `hue-rotate`, `invert`, `opacity`, `brightness`, `contrast`) with
  svgtypes' grammar (a parse error drops the whole list; an invalid URL with no
  valid filter drops the element; a function on an element with no bbox is
  skipped). `filterUnits`/`primitiveUnits`, the -10%/-10%/120%/120% default,
  `x/y/width/height` and `filterUnits`/`primitiveUnits` through `xlink:href`
  chains, primitives from the first element of the chain with children,
  `resolve_primitive_region` (including its `objectBoundingBox` quirk and
  `feFlood`'s special case), `in`/`in2`/`result` with usvg's fallback rules and
  generated `resultN` names, `BackgroundImage`/`BackgroundAlpha`/`FillPaint`/
  `StrokePaint` → `SourceGraphic`, inherited `color-interpolation-filters`,
  `flood-color` (`currentColor`, `inherit` from the `<filter>`) × `flood-opacity`.
* **Rendering (resvg `filter/mod.rs`).** The element becomes a layer covering
  the filter region (resvg's `render_group` rect, cut to `max_filter_bbox`);
  filters run in list order, then clip, then opacity/blend composite.
  Primitives: `feFlood`, `feOffset` (incl. subregion inheritance), `feMerge`,
  `feBlend` (16 modes via `Canvas.compositeLayer`), `feComposite` (over, in,
  out, atop, xor on highp F32; arithmetic on F32), `feColorMatrix` (matrix,
  saturate, hueRotate with correctly-rounded f32 sin/cos, luminanceToAlpha),
  `feGaussianBlur` (resvg's box/IIR choice, `create_box_gauss`, zero-padded
  sliding window — exact; IIR in fixed point), `feDropShadow` (including resvg's
  unconditional shadow colour-space conversion), and `feComponentTransfer`
  without `gamma` (needed by the CSS functions anyway).
* **Unsupported primitives.** usvg-known but unimplemented primitives
  (`feTile`, `feImage`, `feConvolveMatrix`, `feMorphology`,
  `feDisplacementMap`, `feTurbulence`, the lighting pair) and a `gamma` transfer
  function make the whole `filter` value resolve to "no filter", i.e. the
  element renders exactly as before this task (usvg's behaviour for them is to
  render them, so "transparent black" would have regressed the ~20 files that
  pass today by ignoring the filter). Adding one: a `Kind` constructor, a
  clause in `Filter.convertPrim`, a case in `FilterApply.runPrim`, and removing
  its name from `Filter.isKnownUnsupported`. A truly unknown element inside a
  `<filter>` is skipped, as usvg does.
* **Bounds.** Filter layer ≤ `maxFilterPixels` (= `maxPixels`; past it the
  region is cut to the enclosing canvas), counted in the existing
  `maxLayerPixels` budget; `primitives × layer area` ≤ 2^25 per group and ≤ 2^26
  per render (else `error: filter budget`); ≤ 256 primitives per `<filter>`
  (more → unsupported), ≤ 32 filters per list, ≤ 4096 `<filter>` elements. Blur
  cost is O(area) per pass whatever `stdDeviation` is.

## Skipped, and why

* **Filters on `<text>`**: usvg uses the text's layout bounding box, not the
  glyph outlines' (`text/text/filter-bbox`); that box belongs to the text
  tasks. A `filter` on `<text>` is ignored as before.
* **`mask` interplay** (`with-mask*`, `enable-background/with-mask`): masks are
  T49's.
* **`in=FillPaint` with a pattern**: patterns are T53's; usvg maps it to
  `SourceGraphic` anyway.
* **`filter/with-multiple-transforms-1` at `--width 100`**: resvg's f32 scale of
  the rotated CTM is 0.49999997, putting σ at 1.9999999 (IIR), where the
  16.16 matrix gives exactly 2.0 (box). Passes at natural size.
* `enable-background`: nothing to do beyond usvg's behaviour (the `Background*`
  inputs are `SourceGraphic`), which passes 20/21.

## Report

Baseline commit `faa24d0`. `run_corpora.py --fast --corpus resvg --route direct`
(width 100), before → after:

| dir | files | pass before | pass after | mean within-8 before | after |
|---|---|---|---|---|---|
| filters/filter | 74 | 6 | 65 | 70.89% | 96.39% |
| filters/filter-functions | 43 | 15 | 43 | 76.01% | 99.98% |
| filters/feFlood | 8 | 0 | 8 | 28.47% | 100.00% |
| filters/flood-color | 7 | 0 | 7 | 7.84% | 100.00% |
| filters/flood-opacity | 2 | 0 | 2 | 7.84% | 100.00% |
| filters/feOffset | 9 | 2 | 9 | 80.36% | 100.00% |
| filters/feMerge | 3 | 0 | 3 | 87.49% | 99.86% |
| filters/feBlend | 10 | 1 | 10 | 36.89% | 100.00% |
| filters/feComposite | 18 | 3 | 18 | 38.31% | 100.00% |
| filters/feColorMatrix | 16 | 8 | 16 | 68.35% | 100.00% |
| filters/feGaussianBlur | 13 | 5 | 13 | 85.22% | 100.00% |
| filters/feDropShadow | 8 | 0 | 8 | 86.27% | 99.99% |
| filters/enable-background | 21 | 17 | 20 | 97.44% | 99.57% |
| filters/feComponentTransfer (bonus) | 22 | 9 | 19 | 62.53% | 89.99% |

Target directories: 66 → 241 of 254 passing. All of `filters/`: 78 → 253 of 397.
Whole suite: **835 → 1010 of 1679; newly passing 175, newly failing 0.**
At natural size the target directories fail only on the skipped items above
(9 files: masks, FillPaint+pattern, feImage-based `…outside-of-canvas`).

Other checks, all on the final commit:

* `lake build`: no errors, no warnings.
* `scripts/check-theorems.sh`: `theorems ok` (`proofs/SizeBound.lean` unchanged
  and still elaborates against the new `render`).
* `tests/run_tests.py`: every file's score unchanged; new `34_filters` 99.997%
  within 8 (PASS); 24/28 pass (the same four fail as before).
* `tests/run_adversarial.py`: 66/66 clean. New inputs: `filter_huge_stddev`
  (σ = 1e9…1e30, 0.6 s), `filter_huge_region` (4e9-unit region, nested filters,
  2.2 s, matches resvg), `filter_1000_primitives` (unsupported → unfiltered,
  0.01 s), `filter_budget` (250 primitives on a 9 Mpx layer → `filter budget`,
  0.06 s).
* `tests/run_tiles.py`: 28/28 byte-identical, including `34_filters` (a blur
  straddling the quadrant seam). `--threads 4` byte-identical on it too.
* Timing: slowest filter file `filter/huge-region` 0.86 s at natural size
  (resvg 0.13 s); typical 30–100 ms.
