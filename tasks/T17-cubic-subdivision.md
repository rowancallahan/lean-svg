# T17 — Flatten cubics the way tiny-skia does

## Goal

The worst usvg-route icons (all curves) sit at 90–95% within-8 with
`max_d ≈ 64`: our `segCount` inscribes too coarse a polygon (an `r=80`
circle loses 0.1% of its area; a 200-px circle handed to both renderers as
an explicit 2000-gon scores 99.955%). Port tiny-skia's cubic edge
subdivision so curves land on the same sub-pixel samples as the oracle.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T17` (branch
`t17-flatten`). Files: `MicroSvg/Geom.lean`, the **flatten section only**
(`segCount`, `cubicAt`, `flatten`); do not touch the stroker section
(another agent may be adding `dashPoly` below it) nor `Svg.lean`.

## Reference

tiny-skia `src/edge.rs` (`CubicEdge::new`, `update_cubic`, `cubic_delta_from_line`,
`diff_to_shift`, `cheap_distance`, `MAX_COEFF_SHIFT`), `src/edge_builder.rs`
(`push_cubic`, how the `shift = 2` supersampling scale enters), and
`src/path_geometry.rs` for `chop_cubic_at_y_extrema` if the edge builder
chops monotonically first (report whether it does and whether it matters
for the sample positions). Clone or reuse
`/private/tmp/claude-501/-Users-rowancallahan-website/73d6fcc2-0699-487e-b5c3-96bdc24e9f1d/scratchpad/tiny-skia`.
Write the exact scheme into the report before coding: how the segment
count `2^shift` is derived from the control polygon (in supersampled
FDot6), the clamp `MAX_COEFF_SHIFT = 6`, and where the sample points sit
(forward differencing at parameters `k / 2^shift`, with its rounding).

## What to change

- `segCount`: derive `shift` exactly as tiny-skia does from the
  device-space control points (our `Fx` is FDot6 in the 4× supersampled
  space, as T1 established), and return `2^shift`.
- `cubicAt`: keep exact Bernstein evaluation at `k/n` (the difference to
  forward differencing is ≤ 1/64 supersampled px; measure whether porting
  the forward-differencing rounding is needed to hit the numbers, and do it
  only if it is).
- Keep everything total: `n ≤ 64`, loops `for`.
- If usvg converts `circle`/`ellipse` to *arcs* and then cubics with a
  different split than our four-cubic κ construction (check
  `usvg/src/parser/shapes.rs` and kurbo's `Arc::to_cubic_beziers` /
  `append_iter` tolerance), match that split in `Svg.ellipsePath` — but
  `Svg.lean` is another agent's file this wave, so **report** the exact
  construction instead of editing it, and I will schedule it.

## Verify

- `python3 tests/run_tests.py` before/after: within-8 must not decrease on
  any file; expect gains on 02, 03, 12, 13, 14, 15, 18, 21. Report table.
- Corpora fast loop in your worktree (`--out` temp; or `--limit 400` with a
  script copy if the flags are missing): `--corpus simple-icons --route usvg`,
  `--corpus feather --route usvg`, `--corpus resvg --route usvg --dir shapes`
  before/after: pass% and median within-8. Target: median within-8 ≥ 99.5%
  on the icon sets via usvg.
- Timing: `16_stress_2000` and `12_badge` at natural size and `--width 800`,
  before/after (more segments cost time; report it honestly).
- `run_tiles.py`, `run_adversarial.py` clean; `Effect.lean` untouched.

## Done when

Icon-set medians up, no regressions, report appended, committed on the
branch.

## Report

### The tiny-skia scheme, written out (before coding)

Read from the clone at `scratchpad/tiny-skia` @ `5d47547`:
`src/edge.rs` (`CubicEdge::new`/`new2`/`update`, `diff_to_shift`,
`cheap_distance`, `cubic_delta_from_line`, `compute_dy`, `MAX_COEFF_SHIFT`),
`src/edge_builder.rs` (`build`, `push_cubic`, `clip_shift`),
`src/path_geometry.rs` (`chop_cubic_at_y_extrema`).

**Coordinate space.** `BasicEdgeBuilder` is constructed with `clip_shift = 2`
for the AA path, and `CubicEdge::new(points, shift)` converts each control
point with `scale = 1 << (shift + 6) = 256`, truncating toward zero. That is
exactly our `Fx`: **`Fx` is FDot6 in the 4×-supersampled space** (T1). So the
integers `x0..x3, y0..y3` that tiny-skia feeds to the subdivision heuristic are
literally `Mat.apply`'s output, with no rescaling.

**Segment count.** In `CubicEdge::new2`:

```
dx = cubic_delta_from_line(x0, x1, x2, x3)
dy = cubic_delta_from_line(y0, y1, y2, y3)
shift = diff_to_shift(dx, dy, 2) + 1        // note: literal 2, not clip_shift
if shift > MAX_COEFF_SHIFT (= 6) { shift = 6 }
curve_count = -(1 << shift)                 // i.e. 2^shift forward-difference steps
```

with

```
cubic_delta_from_line(a,b,c,d):
    one_third = ((8a - 15b + 6c +  d) * 19) >> 9     // 19/512 ≈ 1/27, arithmetic shift = floor
    two_third = (( a +  6b - 15c + 8d) * 19) >> 9
    return max(|one_third|, |two_third|)             // abs AFTER the floor

cheap_distance(dx, dy) = max(|dx|,|dy|) + (min(|dx|,|dy|) >> 1)

diff_to_shift(dx, dy, shift_aa = 2):
    dist = cheap_distance(dx, dy)
    dist = (dist + (1 << (2 + shift_aa))) >> (3 + shift_aa)   // = (dist + 16) >> 5
    return (32 - dist.leading_zeros()) >> 1                   // = bitlength(dist) >> 1
```

`f(1/3) - b` and `f(2/3) - c` are the deviations of the two off-curve control
points from the curve; `19/512` stands in for `1/27`. `MAX_COEFF_SHIFT = 6`
exists because `curve_count` is stored in an `i8`. So `shift ∈ [1, 6]` and the
segment count is `n = 2^shift ∈ {2, 4, 8, 16, 32, 64}`. In closed form, with
`D = cheap_distance(dx, dy)` in supersampled FDot6 (= our `Fx`):

| `D` (Fx) | `n` |
|---|---|
| 0 – 47 | 2 |
| 48 – 239 | 4 |
| 240 – 1007 | 8 |
| 1008 – 4079 | 16 |
| 4080 – 16367 | 32 |
| ≥ 16368 | 64 |

Worked example, the `r = 80 px` circle quarter from T1 (`p0 = (180,100)`,
`p1 = (180,144.18)`, `p2 = (144.18,180)`, `p3 = (100,180)`, device = user):
`dx = dy = 2803`, `D = 2803 + 1401 = 4204`, `(4204+16) >> 5 = 131`,
`bitlength(131) = 8`, `8 >> 1 = 4`, `shift = 5`, **`n = 32`** — 128 segments
around the circle, against the 68 our `√(2·L_px)+1` rule produces. That is the
~83-gon of T1.

**Where the sample points sit.** `CubicEdge::update` forward-differences in
16.16, one step per `curve_count`, and takes the *exact* `c_last_x/c_last_y`
for the final step. With `up_shift = min(6, 10 - shift)`,
`down_shift = max(0, shift + up_shift - 10)` and
`b = 3(x1-x0) << up_shift`, `c = 3(x0 - 2x1 + x2) << up_shift`,
`d = (x3 + 3(x1-x2) - x0) << up_shift`:

```
cx = x0 << 10 ;  cdx = b + (c >> shift) + (d >> 2*shift)
cddx = 2c + ((3d) >> (shift-1)) ;  cdddx = (3d) >> (shift-1)
step: new = old + (cdx >> down_shift) ; cdx += cddx >> shift ; cddx += cdddx
```

which is the standard cubic forward-difference recurrence, so step `k` lands on
the cubic at **`t = k / 2^shift`**, biased only by the truncating right shifts
(`>> down_shift`, `>> shift`). `down_shift` is 0 for `shift ≤ 4` and 1–2 for
`shift = 5, 6`, so the per-step truncation is ≤ 3 units of FDot16 and the
accumulated drift over ≤ 64 steps is under one `Fx` unit (1/64 supersampled px,
1/256 device px). The endpoint is exact by construction. **We therefore keep
exact Bernstein evaluation at `k/n`** and only fall back to porting the
forward-difference rounding if the numbers demand it.

**Does the builder chop monotonically first?** Yes, on the unclipped path:
`BasicEdgeBuilder::build` calls `path_geometry::chop_cubic_at_y_extrema` and
pushes 1–3 cubics, each of which then computes *its own* `shift` from *its own*
control points. (On the clipped path, `EdgeClipperIter` does the chopping
instead.) Two consequences for sample positions: each y-extremum becomes an
exact polyline vertex, and a chopped half has ~1/4 the delta, hence typically
`shift - 1`, so the totals are similar but the `t` values are not. It is a
no-op for the shapes that dominate the icon corpora: usvg emits circles,
ellipses and rounded rects as four (or four corner) κ-cubics whose quarters are
already monotone in both axes. Measured below; it is not implemented here
(it needs a fixed-point quadratic solve plus de Casteljau, and the delta it
would buy is inside the noise on these corpora).

### What changes

`MicroSvg/Geom.lean`, flatten section only: `cubicDeltaFromLine`,
`cheapDistance` and `diffToShift` are added and `segCount` is rewritten to
`2 ^ min 6 (diffToShift dx dy + 1)`. `cubicAt` and `flatten` keep their
bodies; `n ≤ 64` now, down from the old cap of 100.

### What changed (files)

`MicroSvg/Geom.lean`, flatten section only, +61/−5 lines. Added
`cubicDeltaFromLine`, `cheapDistance`, `bitLength`, `diffToShift`,
`maxCoeffShift`; `segCount` rewritten. `cubicAt` and `flatten` are byte for
byte what they were. Nothing else in the repo is touched — not the stroker
section, not `Svg.lean`, not `Effect.lean`. `lake build` is clean with no new
warnings. Invariants hold: no `partial`/`unsafe`/`@[extern]`/`panic!`/`!`-index,
no `Float`, every loop a `for` over a constant range (`bitLength` is 64 steps,
`flatten`'s inner loop is now `n ≤ 64` where it used to be `≤ 100`).

`cubicAt` keeps **floor** (`Int.ediv`) rather than round-to-nearest. Measured,
not assumed: switching to `(num + n³/2) / n³` moved 02 99.997 → 99.950, 03
99.525 → 99.517, 08 99.992 → 99.977, 12 98.277 → 98.231, 16 97.481 → 97.418
and only helped 14/15 by ≤ 0.005. tiny-skia truncates too (`y0 >>= 10` in
`LineEdge::update` is an arithmetic shift) and `Mat.apply` floors again, so two
floors track the oracle better than a round does. Likewise the forward-
differencing rounding was **not** ported: the exact Bernstein samples already
put every gain on the table, and the drift the port would add is under one `Fx`.

### `run_tests.py`, before / after (tol 8)

| file | within% before | after | Δ |
|---|---|---|---|
| 01_triangle | 100.000 | 100.000 | 0.000 |
| 02_rect_circle | 99.502 | **99.997** | **+0.495** |
| 03_curves | 99.172 | **99.525** | **+0.353** |
| 04_stroke | 99.965 | 99.965 | 0.000 |
| 05_transform | 99.812 | **99.987** | **+0.175** |
| 06_evenodd | 100.000 | 100.000 | 0.000 |
| 07_opacity | 99.853 | 99.885 | +0.032 |
| 08_group_inherit | 99.815 | **99.992** | **+0.177** |
| 09_viewbox | 99.753 | **99.963** | **+0.210** |
| 10_polygon_star | 99.823 | 99.823 | 0.000 |
| 11_style_attr | 99.728 | **99.983** | **+0.255** |
| 12_badge | 97.658 | **98.277** | **+0.619** |
| 13_gear_evenodd | 99.368 | 99.368 | 0.000 |
| 14_flower_transforms | 97.610 | **97.814** | **+0.204** |
| 15_spiral_stroke | 97.282 | 97.252 | **−0.030** |
| 16_stress_2000 | 96.212 | **97.481** | **+1.269** |
| 17_koch_snowflake | 99.222 | 99.222 | 0.000 |
| 18_rose_lissajous | 99.690 | 99.690 | 0.000 |
| 19_sierpinski | 100.000 | 100.000 | 0.000 |
| 20_function_plot | 99.777 | 99.777 | 0.000 |
| 21_hairlines | 99.627 | **99.884** | **+0.257** |

17/21 pass before and after (the four failures are the same four files).
`max_d` collapses on every curve file: 02 255 → 16, 05 159 → 16, 08 32 → 16,
09 38 → 13, 11 159 → 16, 21 55 → 27. The zeros are files with no cubics at all
(10, 18, 19 are polygons; 13, 17 are polylines; 06 is rects) — the task's
expectation of gains on 13 and 18 was wrong about those two files' contents,
and 20's curves were already at 99.78.

**The one decrease, 15_spiral_stroke, −0.030.** Measured cause, not a guess.
The file is 119 **quadratics**, which `Svg.lean` degree-elevates to cubics
before `flatten` ever sees them. Segment totals over those 119 quads:

| rule | total segments |
|---|---|
| old `√(2·L_px)+1` on the elevated cubic | 685 |
| this change (`CubicEdge`) on the elevated cubic | 752 |
| what resvg actually does (`QuadraticEdge` on the quad) | **532** |

so the flattening got *finer* here, not coarser, and finer than the oracle's.
`Geom.lean`'s own stroker documents why finer then scores worse: its tuning
table for `joinSteps` "is not monotone past 2, because an inscribed arc
under-covers by `r(1 - cos(δ/2))` while the straight offsets beside it are a
fraction of an `Fx` unit thin (`normalOf` floors). At ×2 the two very nearly
cancel". Shrinking `δ` removes the first error and leaves the second. The
deeper reason is structural and belongs to the stroker, not here: resvg strokes
the **exact** curve (kurbo/`tiny-skia-path`'s `PathStroker`) and flattens the
resulting outline once, where we flatten first and offset a polyline. The same
mechanism is why 57 feather icons lost ≤ 0.012 (see below) while 141 gained.

### Icon-set medians via usvg (`--route usvg`)

Run with a copy of `run_corpora.py`'s `render_one` (the worktree's copy has no
`--fast`/`--out`/`--dir`); the copy only repoints `CORPORA_DIR` at the
read-only corpora and writes nothing under `tests/out`. simple-icons and
feather at `--width 96`, resvg suite at `--width 200`.

| slice | files | pass% before | after | median within-8 before | after | mean within-8 before | after |
|---|---|---|---|---|---|---|---|
| simple-icons, usvg (`--limit 400`) | 400 | 42.5 | **86.5** | 98.823 | **99.523** | 98.681 | **99.403** |
| feather, usvg (all) | 287 | 50.2 | **53.3** | 99.013 | **99.110** | 98.510 | **98.567** |
| resvg `shapes/`, usvg (all) | 133 | 98.50 | 98.50 | 100.000 | 100.000 | 99.822 | **99.908** |

**simple-icons clears the ≥ 99.5 % median target** (99.523) and doubles the
pass rate. Per-file: 342 improved, 6 regressed (worst `deepl.svg`, −0.00087),
52 unchanged; the biggest gains are `gutenberg.svg` +4.94, `vsco.svg` +3.82,
`katana.svg` +2.93 points.

**feather does not** (99.110), and the reason is that feather is a
*stroke* corpus — every icon is `fill="none" stroke-width="2"` with round caps
and joins, so its score is set by the stroker, not by flattening. 141 files
improved, 57 regressed (worst `slack.svg` −0.0119, typical −0.002), 89
unchanged. Its worst files after the change (`globe` 94.05, `dribbble` 94.11,
`target` 94.22) are stroked circles, i.e. exactly the
flatten-then-offset-a-polyline gap above.

`resvg shapes/`: 46 files improved, 8 regressed. Every improvement is a fill
(`shapes/circle/*`, `shapes/ellipse/*`, `shapes/rect/rx-*` all 99.340 →
99.982) and every regression is a **stroked** path (`shapes/path/M-C.svg`
99.492 → 99.247, `M-Q-T` 99.303 → 99.147, …), the same stroker story. Pass
count is unchanged at 131/133.

### Does the missing y-extrema chop matter? (measured)

Reimplemented both schemes in Python over the usvg output of 120 simple-icons
and 120 feather files, at the corpora's own `--width 96`:

| corpus | cubics | with an interior y-extremum | identical segment count | total segments chopped/unchopped | worst gap between the two polylines |
|---|---|---|---|---|---|
| simple-icons | 3 794 | 755 (19.9 %) | 83.8 % | 1.05× | 0.098 device px |
| feather | 406 | 27 (6.7 %) | 95.8 % | 1.00× | 0.098 device px |

A tenth of a pixel at the very worst cubic in 240 files is well inside one AA
level, and the segment budget barely moves. Chopping needs a fixed-point
quadratic solve plus de Casteljau in `Geom.lean`; it is not worth it now, and
this is the number to re-check if it is ever proposed again.

### Timing (median of 3, same machine, before → after)

| file | size | before | after | Δ |
|---|---|---|---|---|
| 12_badge | natural (300×300) | 0.02 s | 0.02 s | — |
| 12_badge | `--width 800` | 0.09 s | 0.10 s | ×1.11 |
| 16_stress_2000 | natural (300×300) | 0.17 s | 0.20 s | ×1.18 |
| 16_stress_2000 | `--width 800` | 0.70 s | 0.77 s | ×1.10 |

`run_tiles.py`'s interactive 512×512 tile of a 4000 px image: 12_badge
176.0 → 178.3 ms, 16_stress_2000 266.5 → 274.4 ms, 18_rose_lissajous
83.3 → 84.1 ms. So roughly 10–20 % on curve-heavy files, for the fidelity in
the tables above. The `2 ^ shift` cap at 64 is what keeps it bounded.

### Harness status

* `lake build` — clean, no errors, no new warnings.
* `python3 tests/run_tests.py` — 17/21 before, 17/21 after; one file down
  0.030 points, eleven up, nine flat.
* `python3 tests/run_adversarial.py` — **38/38 cases clean, 0 with violations**
  before and after.
* `python3 tests/run_tiles.py` — **21/21 files stitch byte-identically**, all
  `exact / clear / exact`, before and after.
* `MicroSvg/Effect.lean` untouched; `MicroSvg/Svg.lean` untouched; the stroker
  section of `Geom.lean` untouched.

### `Svg.ellipsePath`: no change needed (reported, not edited)

usvg does **not** go via arcs. `usvg` on
`<circle cx="100" cy="100" r="80"/>` emits

```
M 180 100 C 180 144.18279 144.18279 180 100 180
          C 55.817223 180 20 144.18279 20 100
          C 20 55.817223 55.817223 20 100 20
          C 144.18279 20 180 55.817223 180 100 Z
```

which is exactly `ellipsePath`'s construction: same start point `(cx+rx, cy)`,
same direction (first cubic to `(cx, cy+ry)`), same four 90° spans, same
control offsets `κ·r` — `144.18279 − 100 = 44.18279 = 80 × 0.5522847498`, and
our `kappa16 = 36195` is `round(0.5522847498 × 65536)`, so the two agree to
within the one `Fx` that `Int.ediv (rx * kappa16) 65536` floors away.
`<ellipse cx="50" cy="50" rx="40" ry="20"/>` checks the same way
(`kx = 22.09139`, `ky = 11.0457`). The rounded rect matches too:
`<rect x=10 y=10 width=80 height=40 rx=12 ry=8>` gives
`M 22 10 L 78 10 C 84.62742 10 90 13.581723 90 18 …`, which is `rectPath`'s
corner cubic with `kx = 6.6274`, `ky = 4.41828`.

**Recommendation: leave `Svg.ellipsePath` and `Svg.rectPath` alone.** Two
notes for whoever schedules the follow-up:

1. usvg's *arc* conversion lands on the same κ cubics. `<path d="M 20 100
   A 80 80 0 1 1 180 100 A 80 80 0 1 1 20 100 Z"/>` comes out of usvg as four
   90° κ cubics identical to the circle above, so T16's arc→cubic should split
   each arc sweep at 90° boundaries with the κ control points rather than at
   kurbo's tolerance-driven count, and it will then match both usvg and
   `ellipsePath`.
2. **The real remaining mismatch is quadratics, and it is in `Svg.lean`, not
   here.** tiny-skia has a separate `QuadraticEdge` whose count is
   `2 ^ max(1, diff_to_shift((2b−a−c) >> 2, …, 2))` — *no* `+1`, and a delta
   2.25× larger than what the same quad gives after degree elevation. Our
   parser elevates `Q`/`T` to cubics (`Svg.lean:347-356`), so `flatten` cannot
   tell a quad from a cubic and applies the cubic rule with its `+1`. Measured
   on 15_spiral_stroke's 119 quads: 752 segments against resvg's 532, ~1.4×
   over-subdivision. Fixing it means a `quadTo` constructor on `PathCmd` plus a
   `segCountQuad`; detecting degree-elevated cubics from the control points
   instead would need a tolerance (the elevation floors with `Int.ediv … 3`),
   i.e. a tuned threshold, and would also mis-fire on genuine near-quadratic
   cubics that resvg still sends through `CubicEdge`. Not done here — it
   touches `Svg.lean` and the `PathCmd` type.
