# R2-filters — resvg-wrong research: filter region/primitive cases

Branch `claude/research-r2-filters`. Renders at 200 px wide unless noted;
pixel diffs computed at 500 px (matches the suite PNG's native resolution) to
avoid missing sub-pixel effects. Comparison sheet: `R2-filters.png` (resvg |
suite | chrome | ours, one row per file).

**Harness fix made along the way:** `tests/render_chrome.py` named its output
files by `src.stem` alone. Several of these tests share a basename across
different filter directories (`complex-transform.svg` appears five times), so
the script was silently overwriting one file's Chrome render with another's.
All five `complex-transform.svg` renders were byte-identical and were
actually `feTurbulence/complex-transform`'s noise leaking into the other
four, because it happened to be rendered last. Fixed in a separate commit
before any of the analysis below (Chrome renders here are from the fixed
script). Every conclusion that cites "chrome" below is from the corrected
renders.

**Method note:** for every file below, our render and resvg's render are
**pixel-identical** at 500 px except where stated otherwise (`feImage/with-subregion-5`
is the one exception). That is expected — `LeanSvg/FilterApply.lean` is an
intentional byte-for-byte port of resvg 0.48.1's `filter/mod.rs` (`DESIGN.md`
§3.11) — but it means each file's question is really "is resvg's own
architecture wrong here, and if so is fixing it in scope for a pixel-exact
port." resvg 0.48.1 was cloned to a scratch dir
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`)
to check primary source where the port's own doc comments weren't enough.

## Root cause A: filter region is an axis-aligned device-space box

Both resvg and this renderer compute a group's filter region as: take the
filter region in user space, transform its corners by the full device matrix
(including any rotate/skew on the element or its ancestors), then take the
**axis-aligned bounding box** of the transformed corners as the filter
layer's pixel canvas.

- resvg: `crates/resvg/src/render.rs::render_group`, `bbox.transform(transform)`
  where `bbox` is a `tiny_skia::Rect` — axis-aligned by construction — then
  floor/ceil to an `IntRect`.
- ours: `LeanSvg/Render.lean:367` `filterBox`, `Box.transformed dev u` then
  `Fx.floor`/`Fx.ceil` — same shape, cited in DESIGN.md §3.11 as an
  intentional port ("resvg's `filters_bounding_box`... transformed by `dev`
  into device space and made an integer rect").

The *shape* being filtered still rotates correctly inside that canvas (the
root matrix carried into the layer keeps the rotation), but every filter
**primitive's own geometry** — a `feGaussianBlur` axis, `feOffset`'s `dx/dy`,
`feFlood`/`feTurbulence`'s coordinate system, a primitive subregion under
`objectBoundingBox` — is computed against the canvas's device axes, not the
rotated/skewed local axes the spec requires (the user coordinate system
established by the referencing element, *before* its own `transform`).  The
practical effect: an anisotropic or offset effect that should rotate/skew
with the element instead stays screen-aligned, and a subregion clip computed
in local (pre-transform) space is misplaced once the shape is rotated back
into place.

This is resvg's own architecture, not something introduced by the port, and
`results.csv` is unanimous that resvg gets it wrong wherever the transform
isn't a pure translate/uniform-scale (chrome, firefox and safari agree with
the suite reference on 5 of these 6 files; see per-file notes for the sixth).
Fixing it means giving the filter subsystem a real affine coordinate frame
instead of an axis-aligned pixel canvas — primitive geometry, blur kernels,
subregion clipping and the `max_filter_bbox`/tile-invariance bookkeeping in
`Render.lean` would all need to carry a general 2×3 matrix instead of an
integer rect. That is real, cross-cutting feature work, not a shallow fix,
and it means deliberately diverging from resvg's own (also wrong) behavior —
which needs a decision, since this renderer's whole filter pipeline is
pixel-matched to resvg today and undoing that for rotated/skewed cases only
changes the target for an unknown number of currently-passing files too.

Six files below trace to this one root cause: `feFlood/complex-transform`,
`feGaussianBlur/complex-transform`, `feImage/link-on-an-element-with-complex-transform`,
`feMerge/complex-transform`, `feOffset/complex-transform`,
`feTurbulence/complex-transform`, and `transform-on-shape-with-filter-region`
(seven, not six — see table).

## Root cause B: whole-pixel filter grid (box blur, integer offset)

A second, narrower and much smaller-magnitude family: resvg (and this port)
run `feGaussianBlur` as an integer box-blur approximation of the true
Gaussian (DESIGN.md §3.11, "the box blur is exact integer arithmetic"), and
`feOffset` shifts the whole layer by a device-pixel amount rather than
resampling ("every image is anchored at the layer's pixel (0, 0)",
`FilterApply.lean` module doc). Both are intentional, documented
approximations chosen to match resvg's own pixels exactly. Where the true
(fractional/anisotropic) result differs from the box/whole-pixel
approximation, the diffs are small (mean pixel diff 0.4–10.7 out of 255,
concentrated in a thin band of the anti-aliased edge) rather than a wrong
shape or position. Four files below trace to this: `feOffset/fractional-offset`,
`filter/on-a-thin-rect`, `filter/subregion-and-primitiveUnits=objectBoundingBox-1`,
`filter/subregion-and-primitiveUnits=objectBoundingBox-2`.

---

## Per-file notes

### `filters/feFlood/complex-transform.svg`
Root cause A. `rect1` has `transform="skewX(30) rotate(-30) translate(-80 40) scale(2)"`;
`filter1` is `primitiveUnits="objectBoundingBox"` with `height="0.5"` and an
`feFlood` of `width="0.5"`. Suite and chrome both show the flood as a rotated
parallelogram (the filter region rotates with the element, as spec requires:
the filter region for `objectBoundingBox` primitiveUnits is defined in the
bounding-box-relative frame *before* `transform` is applied, then the whole
filtered result is transformed as a unit). resvg and ours both show an
axis-aligned rectangle — the flood was painted into the axis-aligned device
box, so its own straight edges never got skewed back.
**Correct reference:** suite PNG and chrome agree; matches spec reasoning
above. **Confidence: high.** **Class: (b)**, part of root cause A.

### `filters/feFlood/partial-subregion.svg`
Not a transform case — `rect1` has no `transform`. `filter1` has an `feFlood`
with an explicit subregion (`x=-50 y=-50 width=150 height=150`) followed by
`feOffset dx=50 dy=50`. Suite and chrome show a small square; resvg and ours
show a much larger one. Traced this to resvg's own subregion-clip code
(`crates/resvg/src/filter/mod.rs:457-481`): every primitive's result is
clipped to its subregion by clearing pixels outside it, **except** when the
primitive is `feOffset` — the code has a literal `// TODO: explain` /
`// We do not support clipping on feOffset` comment above that special case.
`feFlood` itself does get clipped correctly to its own subregion; the
mismatch is that clipping isn't re-applied to the final result after the
`feOffset` shifts a flood that was only clipped in its pre-offset position,
so the offset re-exposes flooded pixels that should stay outside the visible
filter region. This is resvg's own acknowledged (if unexplained) special
case, ported faithfully — not a bug we introduced.
**Correct reference:** suite PNG and chrome agree (small square).
**Confidence: high** on what's wrong, **medium** on the fix (the "no clip on
feOffset" rule is deliberate upstream and an unknown number of passing tests
may depend on it; removing or narrowing it is not "a few lines, clear
evidence").
**Class: (d)** — needs a decision: keep the resvg-exact quirk (this file and
any siblings stay wrong vs. spec), or re-clip after `feOffset` too and run
the full corpus gate to see what it costs.

### `filters/feGaussianBlur/complex-transform.svg`
Root cause A. `stdDeviation="12 0"` (X-only blur) on a rect rotated 45°.
Per spec the blur axis rotates with the element, so the correct halo is
elongated along one diagonal (suite and chrome both show this). resvg and
ours both show a uniform, isotropic halo — the blur ran on the axis-aligned
device canvas, so "X-only" became "screen-X-only" pre-rotation, and since the
canvas itself is square-ish relative to the diamond the visual result looks
nearly symmetric.
**Correct reference:** suite + chrome agree, matches spec. **Confidence:
high.** **Class: (b)**, root cause A.

### `filters/feImage/link-on-an-element-with-complex-transform.svg`
Root cause A. `feImage xlink:href="#rect3"` inside a filter on `rect1`, which
has `transform="skewX(50) translate(-90)"`. Suite and chrome (chrome=1 in
`results.csv`) show a diagonal band; resvg and ours show two untransformed
vertical bars. firefox/safari disagree with chrome here (both =2), but their
rendering isn't in our four references to compare directly; chrome's output
matches the suite reference exactly, and matches the same coordinate-frame
reasoning as the other root-cause-A files, so I weight chrome+suite+spec
over firefox/safari's unexplained disagreement.
**Correct reference:** suite + chrome, medium-high confidence (two of three
browsers disagree, but the one that's checkable against the suite reference
agrees with it and with the spec argument). **Class: (b)**, root cause A.

### `filters/feImage/with-subregion-5.svg`
Different bug, and the one file where **our output differs from resvg's**.
`feImage` references a base64-encoded `data:image/png` URI. Suite and chrome
show a rotated (nested green/blue) diamond; resvg shows an unrotated version
of the same image (root cause A again, on resvg's side); **ours renders
nothing** — `rect1` is entirely transparent. Traced to `LeanSvg/Filter/Image.lean:75-77`:
`FeImage.dataCanvas` is a stub that always returns `none`, with a doc comment
"the one `data:` call site (for the integrator, once T63's decoders land)".
`none` is treated as "an image usvg can't decode" → the dummy primitive
(transparent black), matching the module's documented behavior — this is
working as designed for an explicitly unimplemented feature, not a
regression. PNG decoding already exists elsewhere in the codebase (T61/T63,
for `<image>` elements) and isn't yet wired into this call site.
**Correct reference:** suite + chrome agree (rotated diamond); resvg is also
wrong here (root cause A) but at least attempts the image. **Confidence:
high** on both diagnoses. **Class: (b)**, medium — the decoder exists, this
is wiring `dataCanvas` to call it, decode into an `rw×rh` canvas under
`preserveAspectRatio`, and place it at the primitive subregion; not "a few
lines" once you count testing against the corpus, and it doesn't touch root
cause A so it wouldn't fix the rotation on its own.

### `filters/feMerge/complex-transform.svg`
Root cause A, but the *geometric* mismatch is small here because
`filterUnits="userSpaceOnUse"` with an explicit `width="200" height="200"`
makes the filter region cover almost the whole canvas regardless of the
`<g>`'s `skewX(30) translate(-40)` — so the axis-aligned-box approximation
barely clips anything, and the skew is still visible in the shapes (which are
painted with the real rotation matrix). At 500 px, ours and resvg are
pixel-identical to each other and differ from the suite reference by a small
but nonzero amount (mean 10.6/255, 9.8% of pixels differ by >8). Given the
filter mixes `color-interpolation-filters="sRGB"` (first blur) and the
default `linearRGB` (second blur + merge), and root cause A's device-axis
canvas still shifts the *edges* of the two overlapping blurred shapes by a
fraction of a pixel relative to a true rotated frame, I read this as the same
root cause at a much smaller magnitude, not a separate color-space bug — but
I did not isolate the two effects.
**Correct reference:** suite (chrome/firefox/safari all agree with it).
**Confidence: medium** (small diff, plausible but unconfirmed that it's 100%
root cause A rather than a secondary color-space issue). **Class: (b)**, root
cause A (tentative).

### `filters/feOffset/complex-transform.svg`
Same situation as feMerge: `rect1` has `transform="skewX(30) translate(-50)"`;
at 200 px the four renders look visually identical (all show a correctly
skewed parallelogram), but ours/resvg differ from suite by mean 10.05/255,
5.5% of pixels. `feOffset` is exactly the primitive singled out in root cause
A/B's semantics (whole-pixel shift, no subregion clip), so a fractional
misplacement of the shifted edge under a skew is consistent with the same
mechanism as `feFlood/partial-subregion` and root cause A together.
**Correct reference:** suite (chrome/firefox/safari agree). **Confidence:
medium.** **Class: (b)**, root cause A.

### `filters/feOffset/fractional-offset.svg`
Root cause B. `feOffset dx="20.25" dy="40.7"` — no rotation, just a
sub-pixel shift. All four renders look identical at thumbnail size; the
pixel diff (mean 0.38/255, 0.29% of pixels) is confined to the moved
rectangle's anti-aliased edge, consistent with resvg's documented "images
anchored at whole-pixel (0,0)" `feOffset` model rounding away the `.25`/`.7`
instead of resampling. chrome agrees with resvg/ours here (=2 in a sense —
wait, `results.csv` has chrome=1); on inspection chrome's own render also
looks like a plain, non-antialiased-edge square at 200 px, so the real
difference is only visible at native/zoomed resolution.
**Correct reference:** suite PNG, low-magnitude. **Confidence: medium**
(diff is real but tiny; whether it's "wrong" in a way worth chasing is a
judgment call). **Class: (c)** — matches resvg's own documented
whole-pixel-offset design; fixing it means `feOffset` resampling with
fractional coverage, a real (if small) architecture change, for a sub-pixel
cosmetic difference.

### `filters/feTurbulence/complex-transform.svg`
Root cause A, the clearest case. `rect1` has `transform="skewX(30)"` only
(no rotation). Suite and chrome both show the turbulence noise sheared into
a parallelogram matching the element; resvg and ours both show the noise
as an axis-aligned rectangle — the turbulence coordinate function ran on the
device-axis canvas, so the skew never reached the noise's own coordinate
input.
**Correct reference:** suite + chrome agree, matches spec. **Confidence:
high.** **Class: (b)**, root cause A.

### `filters/filter/in=BackgroundAlpha-with-enable-background.svg`
`in="BackgroundAlpha"` reads the alpha channel of everything painted so far
inside an `enable-background="new"` ancestor. Suite shows the offset+blurred
result as a black shape (BackgroundAlpha is "transparent black except where
the background was opaque", so the *color* is always black). resvg's own
`usvg` prints, at parse time, `Warning: BackgroundAlpha filter input isn't
supported and not planed.` [sic] — resvg's own maintainers have explicitly
declined to implement this. chrome, firefox and safari all fail this too
(`results.csv`: 2,2,2) — no current browser implements `enable-background`/
`BackgroundImage`/`BackgroundAlpha`, which SVG2 dropped entirely. Ours
renders the same as resvg/chrome (green square only, no background-alpha
layer) because this feature isn't implemented; this is the same feature
family as task R1 (`tasks/R1-enable-background.md`), which covers the
`enable-background` side of it in more depth.
**Correct reference for "what's spec-correct 1.1 behavior":** suite PNG
(matches an old/authoritative renderer). **Correct reference for "what every
current engine, including the one we're porting, actually does":** resvg,
chrome, firefox, safari all agree on *not* supporting it.
**Class: (c)** — deliberately not supported, consistent with resvg's own
stated policy and every modern browser; overlaps R1's scope.

### `filters/filter/in=BackgroundAlpha.svg`
Same feature, without `enable-background` (relies on `style="isolation:isolate"`
instead, an SVG2-ism that doesn't actually restore `BackgroundAlpha`
semantics). resvg's warning fires here too. `results.csv`: chrome=2,
firefox=2, safari=2, resvg=2, librsvg=0(untested) — i.e. **no** renderer in
the table other than the deprecated ones (batik/inkscape) is marked passing.
**Class: (c)**, same reasoning as above, even stronger consensus that
non-support is the right call.

### `filters/filter/in=BackgroundImage-with-enable-background.svg`
Same feature family, `BackgroundImage` (full RGBA background, not just
alpha) instead of `BackgroundAlpha`. Same resvg "not supported and not
planed" warning, same chrome/firefox/safari=2 unanimous non-support.
**Class: (c)**, same reasoning.

### `filters/filter/on-a-thin-rect.svg`
Root cause B. `rect1` is `width="0.5" height="160"`, `transform="scale(5 1)"`
(uniform per-axis scale, not skew/rotate — so root cause A's rotation issue
doesn't apply; the device box is still axis-aligned-correct here).
`feGaussianBlur stdDeviation="1"` on a post-scale ~2.5-unit-wide line. Pixel
diff is small (mean 0.46/255) and confined to a ~7px-wide vertical strip at
the blurred edges — consistent with the box-blur-vs-true-Gaussian kernel
approximation (root cause B) rather than a shape/position bug.
**Correct reference:** suite (chrome/firefox/safari agree, resvg disagrees
by a small margin). **Confidence: medium.** **Class: (c)** — same
approximation trade-off as the two `objectBoundingBox` files below;
DESIGN.md documents the box-blur choice as intentional.

### `filters/filter/subregion-and-primitiveUnits=objectBoundingBox-1.svg`
Root cause B, and also a check that **ours already matches resvg exactly**
here — including resvg's blur (I misread the 200 px thumbnail on first pass
as resvg producing nothing; a pixel-level scan confirmed resvg's and our
renders are identical at every sampled row). `feGaussianBlur stdDeviation="0.01"`
(objectBoundingBox units) with `width="0.5" height="0.5"` subregion — the
tiny stdDeviation (≈1.6 device px after scale) softens the top edge
slightly. Suite's blur profile is a bit softer/lower-alpha at the same rows
(alpha 208 vs our 251 at the edge, 14 rows in) than ours/resvg — consistent
with the box-blur approximation being a slightly different (narrower) kernel
than a true Gaussian at this small a radius.
**Correct reference:** suite (chrome/firefox/safari agree). **Confidence:
medium.** **Class: (c)**, root cause B.

### `filters/filter/subregion-and-primitiveUnits=objectBoundingBox-2.svg`
Identical situation to -1, with the subregion given as `50%` instead of
`0.5` (same value, different syntax — usvg parses both the same way, and our
renders and diffs are numerically identical to -1's). **Class: (c)**, root
cause B, same evidence as -1.

### `filters/filter/transform-on-shape-with-filter-region.svg`
Root cause A, and the one file in this set where chrome itself disagrees
with the other two browsers (`results.csv`: chrome=2, firefox=1, safari=1).
`rect1` has `transform="skewX(20) translate(-35)"`; `filter1` sets
`width="0.5"` (a narrowed filter region) with `feGaussianBlur stdDeviation="4"`.
Suite shows a narrower, more compact blurred trapezoid; firefox/safari (not
directly renderable here, but recorded as passing against the suite) agree
with the suite reference by definition of "passing"; chrome's own render
(now correctly captured after the render_chrome.py fix) shows a visibly
different, thinner/differently-angled shape from all three. resvg and ours
both show a wider, more symmetric trapezoid, consistent with root cause A
(the narrowed-`width` filter region not rotating with the skew).
**Correct reference:** suite + firefox + safari's three-way agreement,
outweighing chrome's own apparent bug on this one file. **Confidence:
medium-high.** **Class: (b)**, root cause A.

---

## Summary table

| file | class | correct reference | one-line cause |
|---|---|---|---|
| `feFlood/complex-transform.svg` | (b) | suite, chrome | root cause A: filter region loses rotation |
| `feFlood/partial-subregion.svg` | (d) | suite, chrome | resvg's own unexplained "no clip on feOffset" |
| `feGaussianBlur/complex-transform.svg` | (b) | suite, chrome | root cause A: blur axis doesn't rotate |
| `feImage/link-on-an-element-with-complex-transform.svg` | (b) | suite, chrome | root cause A |
| `feImage/with-subregion-5.svg` | (b), medium | suite, chrome | `feImage` `data:` URI decode is a stub (`FeImage.dataCanvas`) |
| `feMerge/complex-transform.svg` | (b), tentative | suite | root cause A, small magnitude |
| `feOffset/complex-transform.svg` | (b), tentative | suite | root cause A, small magnitude |
| `feOffset/fractional-offset.svg` | (c) | suite | root cause B: whole-pixel `feOffset`, no resampling |
| `feTurbulence/complex-transform.svg` | (b) | suite, chrome | root cause A: turbulence coords don't rotate |
| `filter/in=BackgroundAlpha-with-enable-background.svg` | (c) | suite (but no modern engine agrees) | deprecated SVG1.1 feature; resvg itself: "not supported and not planed" |
| `filter/in=BackgroundAlpha.svg` | (c) | suite (but no modern engine agrees) | same |
| `filter/in=BackgroundImage-with-enable-background.svg` | (c) | suite (but no modern engine agrees) | same |
| `filter/on-a-thin-rect.svg` | (c) | suite | root cause B: box-blur kernel approximation |
| `filter/subregion-and-primitiveUnits=objectBoundingBox-1.svg` | (c) | suite | root cause B; ours already matches resvg exactly |
| `filter/subregion-and-primitiveUnits=objectBoundingBox-2.svg` | (c) | suite | root cause B; same as -1 |
| `filter/transform-on-shape-with-filter-region.svg` | (b) | suite, firefox, safari (chrome itself is the outlier) | root cause A |

No class-(a) shallow fixes were found. Every mismatch traces to one of: a
deep architectural limitation shared with resvg (root cause A, 7 files), a
small documented pixel-grid approximation shared with resvg (root cause B, 4
files), an explicitly-unimplemented stub with existing infrastructure to
build on (`feImage` `data:` decode, 1 file), a deliberately-unsupported
deprecated feature matching resvg's own stated policy and every modern
browser (3 files), or an unexplained upstream quirk that would need a
corpus-wide evaluation to touch safely (1 file). None of these are "a few
lines, clear evidence" — pushing any of them past documentation would mean
either large new code (an affine-aware filter frame, a `data:` PNG decode
path) or deliberately un-porting a piece of resvg's own architecture and
re-running the full corpus to see what else moves.

## Questions for Rowan

1. **Root cause A (7 files)** is a real architectural gap versus the spec —
   filter regions and primitive geometry should live in the affine local
   frame of the element referencing the filter, not an axis-aligned
   device-space box. resvg has the same gap and there's no sign it plans to
   fix it. Is this worth a dedicated task (a new coordinate frame threaded
   through `FilterApply.lean`/`Render.lean`'s filter path), given it would
   both diverge from resvg's pixels on rotated/skewed filters and touch the
   tile-invariance/byte-identity guarantees `Render.lean` currently relies on
   for filter layers?
2. **`feFlood/partial-subregion.svg`** (class d): resvg's own source has an
   unexplained special case exempting `feOffset` from subregion clipping.
   Fixing it to match spec/chrome would mean re-clipping the *final* filter
   result to the union of all subregions after an offset, which risks
   changing output on other filter tests that currently pass against resvg.
   Worth a full corpus-gate run to scope, or leave as an accepted quirk?
3. **`feImage` `data:` URI decoding** (`feImage/with-subregion-5.svg`, class
   b): the PNG decoder already exists for `<image>` (T61/T63). Worth a
   follow-up task to wire it into `FeImage.dataCanvas`, or is this low
   enough value (one test file in the whole suite) to leave as a stub?
4. **`BackgroundImage`/`BackgroundAlpha`** (3 files, class c): these overlap
   `tasks/R1-enable-background.md`'s scope. Given resvg's own maintainers
   call it "not planed" and no current browser implements it, I'd suggest
   folding these three files into R1's decision rather than tracking them
   separately here — agree?
5. **Root cause B** (4 files, class c): small (≤11/255 mean, mostly ≤1%)
   pixel differences from resvg's box-blur and whole-pixel-offset
   approximations. These match `DESIGN.md`'s documented, intentional
   trade-offs. Confirming these don't need action — correct?
