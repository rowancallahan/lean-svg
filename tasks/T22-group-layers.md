# T22 — Group opacity as a compositing layer; `mix-blend-mode`; `isolation`  [Opus]

PLAN C12, C29. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T22`
(branch `t22-layers`). Files: `LeanSvg/Svg.lean` (`Doc` gains group
begin/end nodes carrying opacity, blend mode and isolation instead of folding
group `opacity` into children — `interpret` emits them), `LeanSvg/Render.lean`
(`renderRgba`/`renderBands`: a bounded layer stack), `LeanSvg/Canvas.lean`
(layer allocation, composite-with-opacity, blend modes). Invariants in
`tasks/README.md`; `Effect.lean` untouched; `render`'s type unchanged.

## Behaviour (usvg `crates/usvg/src/parser/converter.rs` group conversion
and resvg `crates/resvg/src/render.rs`; tiny-skia `src/blend_mode.rs` and the
pipeline blend stages)

- A `g` (or any container) with `opacity < 1`, or a `mix-blend-mode` other
  than normal, or `isolation: isolate`, becomes a layer: children render
  into a fresh transparent canvas covering the group's device bounding box
  (∩ canvas/band), then the layer is composited onto the parent with the
  group opacity and the blend mode. usvg also creates a layer for
  `clip-path`/`mask`/`filter` on a group — leave hooks for T20/T21 (a layer
  with a post-multiply mask) but do not implement clip/mask here. Shapes
  keep the existing per-shape opacity path (byte-identical when no layer is
  involved).
- Blend modes: all 16 CSS modes as tiny-skia implements them on
  premultiplied u8 (separable: multiply, screen, overlay, darken, lighten,
  color-dodge, color-burn, hard-light, soft-light, difference, exclusion;
  non-separable: hue, saturation, color, luminosity). Match tiny-skia's
  lowp/highp choice for each: report which path resvg actually takes for
  8-bit canvases and port that one exactly (integer only). `isolation`
  affects only whether a new backdrop starts.
- **Bounds**: nesting depth ≤ 10 (deeper groups: opacity/blend applied as a
  plain group without a layer, i.e. degraded, and counted in a stats field
  if one exists; do not error); total live layer pixels ≤ 4 × `maxPixels`
  else `.error "layer budget"` (safe rejection). Layers are per band under
  `--threads N`, so bands stay independent and byte-identical to the
  single-thread result (compositing is per pixel).

## Verify

- `lake build` clean; `git diff main -- LeanSvg/Effect.lean` empty.
- New `tests/svg/26_layers.svg` (overlapping shapes under group opacity,
  nested groups, each blend mode on a coloured backdrop, isolation) ≥ 99%
  within 8 vs resvg.
- Corpora at fast sizes, direct route, `--compare`: `--dir painting/opacity
  --dir painting/mix-blend-mode --dir painting/isolation --dir structure/g`.
  Targets: opacity ≥ 8/9, mix-blend-mode ≥ 16/20, isolation 2/2.
- `run_tests.py`: 07_opacity and 08_group_inherit may change (report the
  before/after); all others byte-identical. `run_tiles.py` byte-identical
  incl. the new file; `--threads 4` byte-identical to `--threads 1` on the
  new file at 800 px; `run_adversarial.py` clean plus: 100 000 nested groups
  with opacity, a group opacity on a 16384×16384 canvas (must hit the budget
  cleanly), 10 000 sibling layers.
- Timing: 16_stress unchanged; report 26_layers at natural and 800 px.
- Commit (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.

## Report

Branch `t22-layers`, rebased onto `main` at `ff06548` (the merge that brought in
T18 gradients and T36 text). The rebase touched `interpret`, `drawShape` and
`Style`, and both behaviours are kept — see *Merging with T18 and T36*.

### Files changed

| file | change |
|---|---|
| `LeanSvg/Canvas.lean` | `F32` (integer binary32), `BlendMode`, the 16 blend stages, `compositeLayer` |
| `LeanSvg/Svg.lean` | `Node`/`GroupInfo`/`Doc.nodes`, `maxLayerDepth`, `ownOpacity`/`blend`/`isolate` on `Style`, `mix-blend-mode`/`isolation` parsing, layer emission in `interpret`, `parseOpacity` unit rejection |
| `LeanSvg/Render.lean` | `Target`, `shapeSlack`, `nodeBox`, `Layer`, `maxLayerPixels`, `opacityF32`, the layer stack in `renderRgba`, the gradient's layer frame |
| `LeanSvg/Geom.lean` | `ctrlBox` (the device control-point box, for layer rectangles) |
| `tests/svg/26_layers.svg` | new, 480×420 |
| `tests/run_adversarial.py` | four generated layer cases |
| `DESIGN.md` | new §3.9, pipeline diagram, deviations, file map, `07_opacity` note |

`git diff main -- LeanSvg/Effect.lean` is empty. `render`'s type is unchanged.
`lake build` finishes with no errors and no warnings. No `partial`, `unsafe`,
`@[extern]`, `panic!`, `!`-indexing or `Float` was added; every new loop is a
`for` over a range bounded by the input or a constant.

### Which tiny-skia pipeline resvg actually takes

**highp, for every blend mode, on 8-bit canvases.** `render_group` composites a
layer with `Pixmap::draw_pixmap`, which builds a `Paint` whose shader is a
`Pattern` (`painter.rs:472`). `Pattern::push_stages` pushes `Stage::Gather`, and
`pipeline/lowp.rs`'s `STAGES` table has `null_fn` for `Gather`, so
`RasterPipelineBuilder::compile`'s `is_lowp_compatible` test fails and the f32
pipeline is selected. The blend mode never enters that decision. So a layer
composite is f32 even for `multiply`, while an ordinary solid fill stays lowp —
which is why `fillMask` is untouched and `F32` is new code rather than a change
to the existing blend.

`LeanSvg.F32` emulates IEEE binary32 exactly in `Nat`: a 24-bit mantissa, a
biased exponent and a sign bit in one word, every result rounded once to
nearest-even with an exact sticky bit. The ported stages are `load_8888`
(`c8 · f32(1/255)`), `scale_1_float` (the group opacity), `source_over_rgba` or
`LoadDestination` + the mode's stage, and `store_8888`
(`round_to_nearest_even(clamp(c,0,1) · 255)`).

### Verification

**`lake build`** clean, no warnings. **`tests/CssTests.lean`** still elaborates.

**The blend modes, directly.** 289 generated 256×256 strip images put **all
65 536 `(source byte, backdrop byte)` pairs** through each mode at six
source/backdrop alpha combinations and three group opacities (1, 0.5, 0.7):

| result | count |
|---|---|
| bit-identical to resvg 0.48.1 | 259 / 289 |
| differing, and only in `color-dodge` / `color-burn` | 30 / 289, max channel delta **2** |

14 of the 16 modes are bit-exact. The other two cannot be: tiny-skia evaluates
their one division with `recip_fast` (`_mm_rcp_ps`), a 12-bit hardware
approximation whose exact result is not portably specified and differs between
microarchitectures. A correctly rounded reciprocal is used instead, costing at
most 2 of 255 on those two modes. Matching the hardware would tie our output to
one CPU model, so it was not attempted.

**`tests/svg/26_layers.svg`** (group opacity over overlapping children, nested
layers, element opacity, isolation with and without, the attribute form of
`mix-blend-mode`, an invalid mode, and all 16 modes on a two-colour backdrop):

| exact | within 8 | within 32 | max d |
|---|---|---|---|
| 99.983% | **99.996%** | 100.000% | 9 |

Target was ≥ 99% within 8. The residual is the dodge/burn cells above.

**`run_tests.py`** — 22/26 pass (main: 21/25; the four pre-existing failures are
unchanged). Exactly two files changed, both of which carry an element `opacity`:

| file | exact before | exact after | within-8 before | within-8 after | max d |
|---|---|---|---|---|---|
| `07_opacity` | 96.728% | **99.997%** | 99.885% | **100.000%** | 30 → 7 |
| `12_badge` | 93.907% | **98.477%** | 98.611% | 98.609% | 51 → 51 |

The other 23 existing files — including T18's `24_gradients` and T36's
`25_text` — are **byte-identical** to `main`'s binary, compared PNG by PNG.

`12_badge` changing is a deviation from this task's expectation of "only 07 and
08": its `<g opacity="0.85">` is a layer now, by the same rule as `07_opacity`.
`08_group_inherit` has no opacity anywhere and did not change. `12_badge` still
fails the 99% gate, on the unrelated stroke and curve differences it already
had.

**Corpora**, `--fast --route direct --compare` against `main`. All three targets
met:

| directory | main | this branch | target |
|---|---|---|---|
| `painting/opacity` | 5/9 | **8/9** | ≥ 8/9 ✓ |
| `painting/mix-blend-mode` | 4/20 | **20/20** | ≥ 16/20 ✓ |
| `painting/isolation` | 1/2 | **2/2** | 2/2 ✓ |
| `structure/g` | 2/2 | 2/2 | — |
| overall | 12/33 | **32/33** | — |

20 files newly passing, **0 newly failing**, 12 unchanged. Every newly passing
file lands at 100.000% within 8. The one remaining failure is
`painting/opacity/bBox-impact.svg` at 97.96% within 8, which needs `clip-path`
(T20).

Reaching 8/9 on opacity took one parsing fix beyond the layer work: usvg reads
an opacity as an `svgtypes::Length` and accepts it only with no unit or `%`
(`FromValue for Opacity`), so `opacity="0.1mm"` leaves the element **opaque**
rather than at 10%. `parseOpacity` now rejects any trailing unit, which is what
`invalid-value-2.svg` tests (36.0% → 100.0%).

**`run_tiles.py`** — 26/26 files, including `26_layers`: quadrant tiles stitch
byte-identically to the full render, the off-document tile is clear, the partial
tile matches its crop.

**`--threads`** — `26_layers` at `--width 800` is byte-identical for
`--threads 1`, `2`, `4` and `8`. Sweeping all 26 corpus files at `--width 800`,
serial vs `--threads 4`, one file differs: `21_hairlines`, **which differs
identically on `main`** (1 867 pixels, max delta 174; both renders are
byte-identical to `main`'s). That is a pre-existing band-invariance bug in the
hairline path, not something this task touched. It also explains the only other
tile mismatch seen while verifying: the corpus fixtures' 1 px `<rect stroke>`
frame, which is a hairline, makes `opacity-on-group.svg` fail a quadrant stitch
on `main` and on this branch by the same 198 pixels. Worth its own task.

**`run_adversarial.py`** — 60/60 clean, including the four new generated cases:

| case | outcome |
|---|---|
| `layers_nested_100k` (100 000 nested groups with opacity) | rejected: `elements nested too deeply` — the XML depth cap of 64 is hit long before a layer is sized |
| `layers_huge_canvas` (group opacity on 16384×16384) | rejected: `canvas 16384x16384 exceeds the 16777216 px limit` — the canvas is 268 Mpx, so the *area* cap fires before the layer budget can |
| `layers_budget` (6 full-canvas nested layers on 4096×4096) | rejected: **`layer budget`** — this is the case that actually reaches `maxLayerPixels` |
| `layers_siblings_10k` (10 000 sibling layers) | renders, 2.4 s; only one layer is ever live |

As specified, the second case cannot reach the layer budget, because that canvas
is itself over `maxPixels`. `layers_budget` was added so the budget path is
exercised and its message covered.

**Timing** (median of 3, wall clock including process start):

| render | main | this branch |
|---|---|---|
| `16_stress_2000` natural | 279.1 ms | 258.8 ms |
| `16_stress_2000 --width 1600` | 2868.6 ms | 2766.3 ms |
| `24_gradients` natural | 48.8 ms | 49.8 ms |
| `25_text` natural | 37.3 ms | 36.1 ms |
| `12_badge` natural | 27.7 ms | 31.0 ms |
| `07_opacity` natural | 12.2 ms | 14.1 ms |

`16_stress` is unchanged (no layers, so it takes the untouched path). The two
files that gained a layer cost 2–3 ms more. `26_layers`: **118.9 ms** at its
natural 480×420, **278.9 ms** at `--width 800`, 114.8 ms at `--width 800
--threads 4`.

### Merging with T18 and T36

Both behaviours are kept, and the interesting part is the gradient.

`fillMaskShader` reads `m.x0 + x` twice over: as a destination index *and* as
the coordinate it evaluates the paint at. A layer shifts the mask into its own
coordinates, so a gradient inside a layer would otherwise be sampled in the
wrong place. This is the problem `--viewport` already solved: `Grad.build` takes
the origin that turns a sample coordinate into a whole-image one and folds it
into the constant term, leaving the coefficients bit for bit the full render's.
A layer adds its own origin to that pair, and `gctm` maps user space to the
layer instead of the canvas so the two agree; `Mat.translate` has an identity
linear part, so the composition is exact. Checked directly: linear and radial
gradients inside nested layers with a blend mode stitch byte-identically from
quadrant tiles, are byte-identical under `--threads 4`, and land at 100.000%
within 8 of resvg (max delta 3).

T36's `text` branch is the one element that cannot go through the shared push,
because `textShapes` walks the whole subtree itself and the main loop then skips
it. Its layer is therefore opened and closed around the shapes it returns, in
place, by the same rule as every other element.

Also folded together: `Style` keeps T34's `strokeFirst` beside the three new
fields; `applyEffective` resets the three per element alongside
`transform-origin`; `skipName` drops `mix-blend-mode` and `isolation` from the
presentation-attribute layer next to T36's `font-kerning`, which usvg excludes
for exactly the same reason; and `shapeSlack`, factored out of `shapeOnCanvas`,
picked up T18's "any paint that inks, not just a solid one" stroke test.

### Bounds, and what was left out

Nesting past `Svg.maxLayerDepth` (10) degrades to the pre-T22 fold rather than
erroring, and the blend mode is dropped. The task allows counting those "in a
stats field if one exists"; `Doc` has none and adding one would mean plumbing it
through `render` and `Main`, so the degradation is silent. Quantified, so the
trade-off is on record: 11 nested opacity layers whose innermost group has two
overlapping circles differ from resvg by max delta 70 over 4 229 of 40 000
pixels (89.7% within 8). With one child per level, degraded output still matches
resvg exactly (checked at depths 10, 11, 12 and 20).

`clip-path` and `mask` are not implemented, as specified. `GroupInfo` is where
their reference belongs: usvg's `should_isolate` already creates a layer for
either, and resvg applies both to the finished layer *before* the opacity/blend
composite, so `renderRgba`'s `groupEnd` arm is the single place that would
post-multiply a mask into `cur` before calling `compositeLayer`.

### Two Lean runtime findings, together worth 4× on a composite

Recorded because they will bite any future integer-heavy hot loop here:

1. A `Nat` literal that does not fit in 32 bits compiles to
   `lean_cstr_to_nat("…")`, which **parses a decimal string into a GMP bignum on
   every evaluation**. A `1 <<< 34` in the float sign-bit handling made GMP
   `set_str` 9% of a whole render.
2. `Nat.shiftLeft` is the one bitwise operation with no scalar fast path in the
   runtime (`lean_nat_shiftr`, `lean_nat_land` and friends are inlined in
   `lean.h`; `lean_nat_shiftl` is an out-of-line call that goes through GMP and
   allocates). Every `<<<` on the hot path cost an `mpz` round trip.

Fixing both — sign bit at the bottom of the word so no constant exceeds `2^32`,
and multiplication by a tabulated power of two instead of `<<<` — took
`26_layers` from 564 ms to 119 ms and the callgrind instruction count for one
strip render from 11.1 G to 2.6 G, with byte-identical output. GMP no longer
appears in the profile at all.
