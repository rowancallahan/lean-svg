# T49 — masks  (branch `claude/feat-masks`)

Implement `<mask>` as resvg 0.48.1 does (`crates/usvg/src/parser/mask.rs`,
`crates/resvg/src/mask.rs`). Target: `masking/mask` (37/39 failing).
Scope: `mask="url(#id)"` on shapes and groups; `maskUnits`
(objectBoundingBox default, userSpaceOnUse) with x/y/width/height region
(default -10%/-10%/120%/120%); `maskContentUnits`; `mask-type` luminance
(default) and alpha; luminance coefficients exactly as resvg (check its
integer/float formula and match within the harness tolerance using fixed
point only); masks on elements inside masks (nested/recursive: usvg's rules
for self-reference → element not rendered); mask + clip-path + opacity
together; `color-interpolation` if resvg handles it (check).

Reuse the existing group-layer machinery (§3.9/§3.10 in DESIGN.md,
`Render.lean` groupBegin/groupEnd, `Clip.lean`) — a mask is: render the mask
content into its own offscreen layer clipped to the mask region, convert to
coverage, multiply into the masked element's layer before compositing. Keep
offscreen surfaces bounded (clip to the region ∩ canvas) and respect the
existing layer-depth cap. Put the new code in `LeanSvg/Mask.lean` where
possible.

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

## Spec implemented

Reference: usvg 0.48.1 `parser/mask.rs`, `converter.rs::convert_group`,
`svgtree/parse.rs::fix_recursive_links`; resvg `mask.rs`, `render.rs::render_group`;
tiny-skia 0.12 `Mask::from_pixmap`, `Pixmap::apply_mask`.

* **Parsing (`Svg.lean`).** `mask` elements get pre-pass slots like `clipPath`
  (`DefsScan.masks`, `MaskEntry`). While the walk is inside a `mask`, rendered
  nodes go to that mask's own `nodes` stream (the enclosing stream and its
  `layerDepth` wait on `maskSaved`). Content lives in the referencing element's
  user space: the `mask` element's `transform` and its ancestors' transforms,
  clips and folded opacity are dropped. `maskUnits` (default
  `objectBoundingBox`), `maskContentUnits` (default `userSpaceOnUse`),
  `x/y/width/height` (default −10%/−10%/120%/120%, 16.16 via `parseCoord16`),
  `mask-type` (attribute or CSS; anything but `alpha` is luminance) and the
  mask's own `mask` link are recorded. `mask` on the root `svg`, `g`, `switch`,
  `text` and shapes records a `MaskUse` (ctm + object bounding box, the same
  mechanism as `ClipUse`) and makes the element a layer (`should_isolate`),
  `GroupInfo.mask`. Ignored inside `clipPath` / `defs`, as in usvg.
* **Cycles.** `fixRecursiveMaskLinks` is usvg's `fix_recursive_links`
  (self link, or link to a mask whose subtree links back → first such link set
  to `none`, repeat). Longer cycles, which make resvg overflow its stack, are
  bounded by `Mask.maxDepth` (8, chain of `mask`-on-`mask` links → not
  rendered) and `Render.maskFuel` (8 levels of masks inside mask content; past
  it, content renders nothing).
* **Validity (`Mask.resolve`).** Non-positive region size, an invalid linked
  mask, `maskContentUnits=objectBoundingBox` without a box → element not
  rendered; `maskUnits=objectBoundingBox` without a non-empty box (e.g. a
  horizontal line) → masked away entirely. A dangling id is ignored.
  Empty/invisible content → fully transparent (same pixels as usvg's "invalid").
* **Rendering (`Render.renderNodes`, `Mask.lean`).** The old node loop of
  `renderRgba` became `renderNodes` (fuel-indexed, calls itself for mask
  content). At `groupEnd`, after the clip: each mask of the chain renders its
  content over the layer's rectangle with the layer's device geometry
  (`maskMat · content`, content = bbox unit map for obb content), is multiplied
  by the anti-aliased region coverage (rasterized rect, `cov8`,
  `DestinationIn`), converted to an 8-bit mask, and the masks multiply the
  layer deepest link first (`Clip.applyToCanvas`, `div255`), then the normal
  opacity/blend composite runs. The layer rectangle is also intersected with
  every region's device box, so offscreen surfaces are bounded by
  region ∩ clip ∩ canvas; mask canvases count against `maxLayerPixels`.
* **Luminance.** tiny-skia: `ceil(clamp(luma(demul(p)) · a · 255))` in f32 with
  0.2126/0.7152/0.0722. Exactly this equals `n/10000`,
  `n = 2126r + 7152g + 722b` on the premultiplied bytes; the f32 path is within
  ~1e-4 of it, so `ceil` is decided by `n` unless `n mod 10000` is within 100 of
  0, where `Mask.lumaF32` replays the f32 operations with `LeanSvg.F32`
  (bit-exact binary32). Alpha type = the alpha byte.
* **obb content precision.** In `maskContentUnits=objectBoundingBox` content, a
  fill-only shape whose paint is solid or an `objectBoundingBox` gradient is
  lexed on 16.16 (`shapeCmds16`) with `ctm · scale(1/256)`, as T20 does for
  `clipPath` children (`on-a-small-object`: 98.7% → pass).
* **`color-interpolation`** on `mask`: usvg ignores it; so do we
  (`color-interpolation=linearRGB` passes).
* **Budget.** `Render.maxMaskRenders = 1024` mask-content renders per canvas;
  past it the render fails with `mask budget` (k masked elements per level ×
  8 levels is k^8 renders otherwise; a 10^8 case now fails in ~1 s).

## Skipped

* `<image>` inside masks (`with-image`, `with-grayscale-image`): no image support.
* A `mask` id that resolves to a non-`mask` element should hide the element
  (usvg); here it is ignored like a dangling id. No suite file exercises it.
* Masks in unfilled slots (inside `display:none`, a losing `switch` branch) are
  unreferenceable, same as T20's clips.
* `mask` elements' `x/y/width/height` in absolute units under
  `objectBoundingBox` go through `parseLengthAll` (user units), as usvg does.

## Report

Files: `LeanSvg/Mask.lean` (new), `LeanSvg/Render.lean` (loop factored into
`renderNodes`, mask application in `groupEnd`), `LeanSvg/Svg.lean` (types,
`mask`/`mask-type` properties, walk, `fixRecursiveMaskLinks`), `LeanSvg.lean`
(import), `tests/svg/32_masks.svg` (new).

`python3 tests/run_corpora.py --fast --corpus resvg --route direct` (width 100):

| | before | after |
|---|---|---|
| `masking/mask` pass | 2 / 39 | 35 / 39 |
| whole suite pass | 835 / 1679 | 869 / 1679 |
| newly passing / newly failing | | 34 / 0 |
| files whose within-8 dropped | | 0 |

Also improved: `filters/enable-background/with-mask` 91.0 → 100 (pass),
`filters/filter/with-clip-path-and-mask` 78.5 → 97.3, `with-mask-on-parent`
63.2 → 83.2, `with-mask` 54.0 → 84.1 (filters themselves unsupported).

Still failing in `masking/mask`: the two `<image>` files, and `with-opacity-1`
(95.2) / `with-opacity-3` (88.8). The last two are **not** mask errors: every
differing pixel is alpha ±1 at alpha ≈ 6–30, amplified by un-premultiplying.
The cause is the pre-existing T44 integer `normal` composite at opacity 0.5 on
tie values (`x.5`): a mask-free repro — `<g opacity="0.5"><rect
fill-opacity="0.098"/></g>` — gives alpha 12 vs resvg 13 on every pixel.

Other checks: `lake build` clean, no warnings; `scripts/check-theorems.sh` →
`theorems ok`; `tests/run_tests.py` scores unchanged for 01–27, 32_masks 99.993%
within 8 (PASS); `run_adversarial.py` 62/62 clean; `run_tiles.py` 28/28
byte-identical; all `tests/svg/*.svg` byte-identical to the pre-change binary at
natural size and `--width 800`; `--threads 4` byte-identical on 32_masks;
`--width 1600` timings of 26_layers / 16_stress_2000 / 27_clip within run-to-run
noise of the pre-change binary.
