# T1 — Match tiny-skia's anti-aliasing in the rasterizer

## Goal

Raise the `within` (≤ 8 levels) agreement with resvg on every corpus file by
making `MicroSvg/Raster.lean` produce the same coverage values tiny-skia does.
Today we compute exact signed area per pixel; tiny-skia (resvg's rasterizer)
uses Skia's supersampling scan converter. The seams along every edge differ
by a few levels, and on stroke-heavy files that costs 3–9% of pixels.

Baseline (`python3 tests/run_tests.py`, tol 8): 10/20 pass. Worst:
`18_rose_lissajous` 91.1%, `16_stress_2000` 95.0%, `15_spiral_stroke` 95.7%,
`20_function_plot` 96.6%, `17_koch_snowflake` 96.8%.

## Reference source

```bash
git clone --depth 1 https://github.com/linebender/tiny-skia /private/tmp/claude-501/-Users-rowancallahan-website/73d6fcc2-0699-487e-b5c3-96bdc24e9f1d/scratchpad/tiny-skia
```

Read, in this order:
- `src/scan/path_aa.rs` — `SuperBlitter`, `SHIFT = 2`, `SCALE = 4`, `MASK = 3`,
  `blit_h`, `coverage_to_partial_alpha`, `fill_path` / `fill_path_impl`.
- `src/scan/path.rs` — `walk_edges` (nonzero / even-odd span walking).
- `src/edge.rs` — `LineEdge::new` (`SkEdge::setLine`): how `first_y`,
  `last_y`, `x`, `dx` are computed in 16.16 from 26.6 (`FDot6`) inputs, the
  rounding used, and the initial `x` at the first scanline center.
- `src/edge_builder.rs` — how paths are converted to edges (in the
  supersampled coordinate space: y and x are multiplied by `SCALE`).
- `src/alpha_runs.rs` — how partial alphas accumulate and saturate at 255.

Write down the exact scheme before coding (put it in the report):
sub-scanline sample position, x rounding at each sub-scanline, per-sub-scanline
max alpha (`64,64,64,63` pattern), partial alpha for span ends, and how
fully-covered interior pixels are handled.

## What to change

`MicroSvg/Raster.lean` only (you may add a helper module if it is cleaner).
Replace the accumulation scheme with a port of the supersampling scheme:

- 4 sub-scanlines per pixel row, edges walked in supersampled space
  (coordinates ×4), x carried in 16.16 fixed point as `Nat`/`Int` exactly as
  tiny-skia does, same rounding of the span endpoints to supersampled pixel
  columns, same partial-alpha quantisation (quarter-pixel horizontal).
- Nonzero and even-odd winding by sorting the active edges' x per
  sub-scanline, exactly as `walk_edges` does. Bound the sort: insertion sort
  over the active list is fine; the number of active edges is ≤ number of
  edges, and every loop must be a `for` over a finite range.
- Keep the `Mask` interface (`x0 y0 w h cov` with `cov ∈ [0, 65536]`); map
  tiny-skia's 0..255 alpha to `cov = alpha * 257` so `255 ↦ 65535` (or
  document a different mapping and update `Canvas.fillMask` accordingly; the
  blend must remain in `Nat`).
- Keep clipping semantics: parts of edges left of the mask still count for
  winding; parts above/below are discarded.

Everything must satisfy `tasks/README.md`. Input edge coordinates are `Fx`
(1/256 px, `Int`, clamped to ±2^30); convert to tiny-skia's 26.6 (`FDot6`)
by dividing by 4 with the same rounding tiny-skia uses when it converts f32
to FDot6 (`fdot6::from_f32` rounds; note the rounding direction).

## Measure

Before and after, run `python3 tests/run_tests.py` and paste both tables.
Also run `python3 tests/run_adversarial.py` after (must remain clean) and
report the `huge_path.svg` and `many_elements.svg` times before/after.

## Done when

Every corpus file is ≥ 99% within 8, or you have a precise explanation of
what still differs for the ones that are not (with a zoomed crop of the diff
described in words). Do not tune thresholds. Append your `## Report`.

---

## Report

### The tiny-skia scheme, written out

Read from `tiny-skia` @ `linebender/tiny-skia` master (`src/scan/path_aa.rs`,
`src/scan/path.rs`, `src/edge.rs`, `src/edge_builder.rs`, `src/alpha_runs.rs`,
`src/fixed_point.rs`, and `src/painter.rs` for the dispatch).

**Coordinate space.** `SHIFT = 2`, `SCALE = 4`, `MASK = 3`. Edges are built with
`shift = 2`, so `LineEdge::new` multiplies the f32 coordinate by
`1 << (shift + 6) = 256` and truncates toward zero. That is *exactly* our `Fx`
unit (1/256 px): `Fx` is already `FDot6` in the 4×-supersampled space, so no
division by 4 and no extra rounding step is needed — the only residual
difference is that `fdot6::from_f32` truncates where our parser rounds to
nearest (see "what still differs", item 4).

**Edge setup** (`LineEdge::new`, `compute_dy`, `fdot6`, `fdot16`):

```
swap so y0 <= y1 (winding = -1 if swapped, else +1)
top    = (y0 + 32) >> 6                    # arithmetic shift = floor
bottom = (y1 + 32) >> 6
if top == bottom: drop the edge
slope  = ((x1 - x0) << 16) / (y1 - y0)     # Rust '/' truncates toward zero
dy     = (top << 6) + 32 - y0              # FDot6, in (-32, 32]
x      = (x0 + ((slope * dy) >> 16)) << 10 # floor to FDot6, then widen to 16.16
first_y = top ;  last_y = bottom - 1
per sub-scanline:  x += slope
```

So **sub-scanline sample position** is supersampled `y = t` exactly for
sub-scanline index `t`, i.e. device `y = t/4`: samples sit at the *top* of each
quarter row (`r`, `r+.25`, `r+.5`, `r+.75`), not at quarter-row centres. The
stored `x` is floored to `FDot6` before being widened, so the initial x carries
only 1/64-of-a-supersampled-pixel precision.

**x rounding at each sub-scanline** (`walk_edges`):
`x_col = fdot16::round_to_i32(edge.x) = (edge.x + 0x8000) >> 16`, a rounded
supersampled column. Active edges are taken in increasing `x`; `w` accumulates
the windings; the span `[left, x_col)` of sub-columns is emitted whenever
`(w & winding_mask) == 0` (`winding_mask` is `-1` for nonzero, `1` for
even-odd). If `w` is still inside after the last edge, the span runs to the
right clip.

**Per-sub-scanline max alpha** (`SuperBlitter::blit_h`):
`max_value = (1 << (8 - SHIFT)) - (((y & MASK) + 1) >> SHIFT)`
= `64, 64, 64, 63` for `y & 3 = 0, 1, 2, 3`. Four sub-scanlines sum to 255.

**Partial alpha for span ends** (`blit_h` + `coverage_to_partial_alpha` +
`AlphaRuns::add`). With `start = s`, `stop = e`, `p0 = s >> 2`, `p1 = e >> 2`,
`fb = s & 3`, `fe = e & 3`, `n = p1 - p0 - 1`:

* `n < 0` (span inside one pixel): `fb = fe - fb`, `n = 0`, `fe = 0` — that one
  pixel gets `(e - s) * 16`.
* `fb == 0`: `n += 1`; pixels `p0 .. p1-1` are the middle run.
* `fb != 0`: `fb = 4 - fb`; pixel `p0` gets `(4 - fb_orig) * 16` and the middle
  run is `p0+1 .. p1-1`.
* If `fe != 0`, pixel `p1` gets `fe * 16`.

`coverage_to_partial_alpha(q) = q << (8 - 2*SHIFT) = q * 16`, i.e. 16 per
covered quarter-pixel column.

**Fully-covered interior pixels** get `max_value` from the middle run, *not*
`4 * 16 = 64`: that is the whole point of the `64,64,64,63` pattern, and it is
why a solid interior lands on exactly 255 rather than 256.

**Saturation** (`AlphaRuns`): each add is clamped with `a - (a >> 8)`, which
maps 256 to 255. Alphas accumulate across the four sub-scanlines of a
destination row and are flushed when the row changes.

**Dispatch** (`painter.rs::treat_as_hairline`): important for interpreting the
remaining error — tiny-skia only uses this supersampling converter for *fills*
and for strokes whose device-space width is `> 1`. A stroke that maps to
`width <= 1` in both axes is drawn by `scan::hairline_aa` instead, a completely
different (Skia `AntiHairLineRgn`) converter.

### What changed

Only `MicroSvg/Raster.lean` (175 insertions, 93 deletions); `DESIGN.md` §3.5
rewritten to describe the new scheme. `r2`, `accumPiece` and `accumEdge` are
gone, replaced by `addAlpha`, `blitSpan`, `mkEdge` and a rewritten `rasterize`.
`Mask` and the `rasterize` signature are unchanged, so `Canvas.fillMask` and
`Render.drawShape` are untouched.

* `mkEdge` is `LineEdge::new` with `shift = 2` in exact integer arithmetic
  (`Int.ediv` for the arithmetic shifts, `Int.tdiv` for the truncating divide),
  clipped to sub-scanlines `[0, 4·bh)` by advancing `x` by `slope · (0 - top)`.
* `rasterize` counting-sorts the edges by first sub-scanline (buckets bounded
  by `4·bh`), then walks `4·bh` sub-scanlines with a compacted active array.
* **One deliberate deviation.** `walk_edges` keeps the active list x-sorted
  with a backward-ripple insertion; on `huge_path.svg` (≈2·10^6 long edges, all
  active on every scanline, x-order churning by ±1/180 px per row) that sort
  costs ~7 inversions per edge per sub-scanline ≈ 5·10^9 shifts, which does not
  fit the 120 s adversarial budget. Instead each active edge's rounded
  sub-column is binned into a winding-delta array which is prefix-summed. This
  produces **the identical set of covered sub-columns** (the sorted walk emits
  exactly the columns whose prefix winding is "inside"), and the only
  observable difference is that two spans abutting at one sub-column are
  blitted as one run: a pixel that becomes "interior" in the merged run gets
  `max_value` 63 instead of four partial adds of 16 on the fourth sub-scanline.
  That is **at most 1 level out of 255**, on a pixel that needs two edges
  rounding to the same sub-column with the winding passing through zero there.
* **Mask mapping.** The task suggested `cov = alpha * 257`, but
  `Canvas.fillMask` computes `alpha_out = a · cov · opacity / 2^24`, which
  floors: `cov = 255·257` gives `alpha_out = 254`, losing a level on every
  pixel. Instead `cov = ⌈alpha·65536/255⌉ = (alpha*65536 + 254) / 255`, which
  is the exact inverse of that formula for an opaque paint (255 ↦ 65536 ↦ 255,
  254 ↦ 65279 ↦ 254). `cov ∈ [0, 65536]` and the `Nat` blend are unchanged, so
  `Canvas.lean` needed no edit (and does not collide with T2).
* Invariants: no `partial`/`unsafe`/`@[extern]`/`panic!`/`!`-indexing, no
  `Float`, every loop a `for` over a finite range (sub-scanlines ≤ `4·bh`,
  inner loops ≤ `|active|` or `bw`), hot per-pixel work in `Nat`.
  `lake build` is clean with no new warnings.

### Fidelity, before / after (`python3 tests/run_tests.py`, tol 8)

Before (10/20):

```
name                             size    exact%   within%   within32%   mean_abs   max_d    ms ours   ms resvg  result
01_triangle                   200x200    99.000   100.000     100.000      0.009       3      350.9        8.3  PASS
02_rect_circle                200x200    98.578    99.250      99.922      0.113     255       15.0        5.9  PASS
03_curves                     200x200    98.360    99.047      99.882      0.144     255       14.5        4.7  PASS
04_stroke                     200x200    96.770    99.280      99.552      0.432     255        9.2        4.9  PASS
05_transform                  200x200    98.043    99.100      99.875      0.161     255        8.8        4.7  PASS
06_evenodd                    200x200    97.905    99.243      99.910      0.136     255       12.2        5.9  PASS
07_opacity                    200x200    62.642    99.810      99.915      0.427     255       14.0        4.7  PASS
08_group_inherit              200x200    96.520    99.642      99.960      0.057     255       10.5        4.1  PASS
09_viewbox                    200x150    99.027    99.707     100.000      0.017      28       13.8        3.8  PASS
10_polygon_star               200x200    92.407    98.195      99.752      0.385     255       12.3        4.1  FAIL
11_style_attr                 200x200    97.545    99.492      99.913      0.119     255       11.3        5.2  PASS
12_badge                      300x300    86.306    97.546      99.864      0.295      86       62.9        5.6  FAIL
13_gear_evenodd               260x260    95.695    98.620      99.704      0.492     255       19.3        4.7  FAIL
14_flower_transforms          280x280    75.935    97.603      99.776      0.350      59       44.7        6.1  FAIL
15_spiral_stroke              300x300    51.254    95.720      98.258      1.230     118       67.5        6.9  FAIL
16_stress_2000                300x300    24.568    94.989      99.670      1.072     205      215.6       30.5  FAIL
17_koch_snowflake             300x300    84.869    96.819      99.378      0.617     102       52.8        6.4  FAIL
18_rose_lissajous             300x300    80.414    91.138      95.878      1.964     143       98.7        9.3  FAIL
19_sierpinski                 300x300    88.470    98.933     100.000      0.187      21       43.7        6.6  FAIL
20_function_plot              320x240    86.878    96.589      98.828      0.562     112       45.1        6.5  FAIL

10/20 passed, 10 failed, 0 render errors  (tol=8, threshold=0.990)
```

After (15/20):

```
name                             size    exact%   within%   within32%   mean_abs   max_d    ms ours   ms resvg  result
01_triangle                   200x200    99.200   100.000     100.000      0.006       4      244.9        3.9  PASS
02_rect_circle                200x200    99.082    99.462      99.970      0.070     255       16.1        3.8  PASS
03_curves                     200x200    98.795    99.140      99.880      0.147     255       18.4        4.0  PASS
04_stroke                     200x200    99.195    99.960      99.985      0.012      64       13.8        3.8  PASS
05_transform                  200x200    98.805    99.718      99.975      0.032     159       10.9        4.0  PASS
06_evenodd                    200x200    98.630    99.860     100.000      0.025      16       18.3        4.0  PASS
07_opacity                    200x200    62.695    99.873      99.940      0.386     170       22.6        3.9  PASS
08_group_inherit              200x200    98.922    99.815     100.000      0.014      32       16.0        3.7  PASS
09_viewbox                    200x150    99.157    99.753      99.990      0.015      38       21.5        3.7  PASS
10_polygon_star               200x200    95.233    99.477      99.985      0.067     255       22.9        4.2  PASS
11_style_attr                 200x200    98.585    99.692      99.960      0.057     159       20.8        3.9  PASS
12_badge                      300x300    88.069    97.682      99.779      0.246      52      125.4        6.1  FAIL
13_gear_evenodd               260x260    97.435    99.228      99.991      0.052     223       40.5        5.1  PASS
14_flower_transforms          280x280    76.812    97.626      99.798      0.333      62       92.5        5.8  FAIL
15_spiral_stroke              300x300    52.296    97.210      99.930      0.648      44      125.7        6.5  FAIL
16_stress_2000                300x300    27.800    95.712      99.794      0.866     205      325.9       31.8  FAIL
17_koch_snowflake             300x300    85.200    96.907      99.631      0.516     101       91.3        5.9  FAIL
18_rose_lissajous             300x300    82.802    99.681      99.997      0.127      43      161.4        8.9  PASS
19_sierpinski                 300x300    92.820   100.000     100.000      0.027       2       76.9        6.2  PASS
20_function_plot              320x240    89.142    99.654     100.000      0.087      25       87.2        6.4  PASS

15/20 passed, 5 failed, 0 render errors  (tol=8, threshold=0.990)
```

| file | within% before | after | Δ |
|---|---|---|---|
| 01_triangle | 100.000 | 100.000 | 0.000 |
| 02_rect_circle | 99.250 | 99.462 | +0.212 |
| 03_curves | 99.047 | 99.140 | +0.093 |
| 04_stroke | 99.280 | 99.960 | +0.680 |
| 05_transform | 99.100 | 99.718 | +0.618 |
| 06_evenodd | 99.243 | 99.860 | +0.617 |
| 07_opacity | 99.810 | 99.873 | +0.063 |
| 08_group_inherit | 99.642 | 99.815 | +0.173 |
| 09_viewbox | 99.707 | 99.753 | +0.046 |
| 10_polygon_star | 98.195 | 99.477 | +1.282 |
| 11_style_attr | 99.492 | 99.692 | +0.200 |
| 12_badge | 97.546 | 97.682 | +0.136 |
| 13_gear_evenodd | 98.620 | 99.228 | +0.608 |
| 14_flower_transforms | 97.603 | 97.626 | +0.023 |
| 15_spiral_stroke | 95.720 | 97.210 | +1.490 |
| 16_stress_2000 | 94.989 | 95.712 | +0.723 |
| 17_koch_snowflake | 96.819 | 96.907 | +0.088 |
| 18_rose_lissajous | 91.138 | 99.681 | +8.543 |
| 19_sierpinski | 98.933 | 100.000 | +1.067 |
| 20_function_plot | 96.589 | 99.654 | +3.065 |

`within32%` improves everywhere and the `max_d = 255` seam pixels largely
disappear (04, 05, 06, 08, 09, 12, 14, 15, 16, 17, 18, 19, 20 all drop below
255; the four that keep 255 — 02, 03, 10, 11 — do so on single pixels of a
*curve*, not of a straight edge).

### Adversarial (`python3 tests/run_adversarial.py`)

`37/37 cases clean, 0 with violations` both before and after (the task file's
"28/28" predates the generated cases; the suite now runs 37).

| case | before | after |
|---|---|---|
| `gen/huge_path.svg` | 9124.7 ms | 13118.7 ms (×1.44) |
| `gen/many_elements.svg` | 1817.7 ms | 2156.9 ms (×1.19) |

The 1.44× on `huge_path` is the inherent 4× in scanline count partly offset by
dropping the per-column area integral; both stay far inside the 120 s timeout.
Corpus render times roughly double (e.g. 16_stress_2000 215 → 326 ms).

### What still differs, and why (measured, not guessed)

Isolating probes were rendered with both renderers at 200×200 over an opaque
background (`n>8` = pixels whose worst channel differs by more than 8 out of
40 000):

| probe | within8% | n>8 | what it isolates |
|---|---|---|---|
| `evenodd` (rect with a rect hole, even-odd) | 100.000 | 0 | even-odd walk + AA |
| 12 axis-aligned rects at fractional offsets | 100.000 | 0 | vertical/horizontal AA |
| 4-point polygon, fractional coords | 99.968 | 13 | general straight-edge AA |
| thin triangle, fractional coords | 99.977 | 9 | ditto |
| 4-segment polyline, `stroke-width=7`, miter | 100.000 | 0 | thick stroke AA |
| 2000-gon of radius 80 (explicit points) | 99.955 | 18 | AA on a dense convex outline |
| `<circle r=80>` | 99.340 | 264 | **cubic flattening** |
| `<path>` with two cubics | 99.330 | 268 | **cubic flattening** |
| `<path stroke-width=1>` straight diagonal | 98.995 | 402 | **resvg hairline path** |

So the supersampling port itself is essentially exact — a straight-edge fill
agrees with resvg on 99.96–100 % of pixels. What is left, in order of size:

1. **Thin strokes go down a different converter in resvg.**
   `painter.rs::treat_as_hairline` sends any stroke whose device width maps to
   `<= 1` in both axes to `scan::hairline_aa` (Skia's `AntiHairLineRgn`), not
   to the supersampling scan converter at all. Evidence: a single straight
   `stroke-width="1"` diagonal from (20,40) to (180,160) — length 200 px, so
   the true stroke area is 200 px² — is rendered by resvg with a total ink of
   exactly **160.00 px²** (= max(|dx|,|dy|), the hairline walker's one unit of
   ink per major-axis step) while we produce **200.31 px²**, the true area.
   For the same path at `stroke-width="4"` both renderers agree to the last
   level (`within8 = 100.000`, `max_d = 0`).
   This is the whole of 17_koch_snowflake: its fill alone scores
   **99.948 % within 8** (47 bad pixels), its `stroke-width="1"` outline alone
   scores **96.610 %** (3051 bad pixels). At `stroke-width="4"` the same
   outline scores **99.811 %**. Visually, the diff is a one-pixel halo hugging
   every one of the ~3000 Koch segments — in a zoomed crop of the spike at
   (149,39) resvg leaves the row above the tip empty (coverage 0) where we put
   64/255, and the tip row reads 212/255 for resvg against 223/255 for us: our
   hairline is a true 1 px-wide quad, theirs is a modulated one-sample-per-step
   run. It is also most of 16_stress_2000 (many `stroke-width` 0.7/0.8 paths):
   fills only → **98.411 %**, thin strokes only → **97.957 %**, together
   95.712 %.
2. **Curve flattening is coarser than tiny-skia's.** `Geom.segCount` uses
   `√(2·L_px) + 1` segments; tiny-skia forward-differences `CubicEdge`s with
   `diff_to_shift` and effectively never shows the chord error. Measured on
   `<circle r=80>`: true area 20106.193 px², resvg 20105.876, ours
   **20086.648** — we are 19.2 px² light, i.e. our circle is an inscribed
   ~83-gon. With the same geometry given as an explicit 2000-gon to both
   renderers the score jumps from 99.340 % to **99.955 %**, so this is purely
   flattening, not rasterization. It is the top contributor in 12_badge: an
   element-by-element ablation adds 450 bad pixels for `<circle r=130>`, 853
   for `<circle r=118 stroke-width=6>`, 308 for the cubic-bordered path and
   265 for the two quadratic strokes, i.e. every curve.
   Raising `segCount` to `√(8·L_px)+1` (2× finer) moves 12_badge to 97.790,
   14_flower to 97.798 and 16_stress to 96.291 but costs 15_spiral 0.48 points
   (sub-pixel segments make `normalOf`'s integer-sqrt normals noisy), and
   raising it to `4·L_px` makes 12_badge and 03_curves *worse*. So the fix is
   a better flattening *and* a stroker that is robust on short segments — a
   separate task, outside `Raster.lean`.
3. **Stroker geometry on short segments / sharp joins.** 15_spiral_stroke
   (widths 9 and 2.5, so not hairlines) is at 97.210 with `max_d` down from 118
   to 44 and `within32` up from 98.258 to 99.930: the remaining error is a band
   along the outline, i.e. our quad+wedge union differs from usvg/kurbo's
   stroke outline by a fraction of a pixel. Same story for 14_flower
   (`stroke-width=1.5`).
4. **Input rounding, ±1/256 px.** `fdot6::from_f32` truncates toward zero;
   our `parseNumber` rounds to nearest, so `x="20.3"` is 5196 for resvg and
   5197 for us. A 1-`Fx` offset flips the rounded sub-column about 1 time in
   16, which is exactly the residue in the straight-edge probes (13 and 9
   pixels out of 40 000, every one of them off by 16/255 = one quarter-column
   on one sub-scanline). Fixing it means changing the parser/transform
   rounding, not the rasterizer.
5. **Blend rounding** keeps `exact%` low on translucent files (07_opacity
   62.7 %, 16_stress 27.8 %) while `within8` is 99.87 % / 95.7 % — that is T2's
   subject, not this one.

### Not done

Every corpus file is **not** ≥ 99 % within 8: 12_badge (97.68), 14_flower
(97.63), 15_spiral (97.21), 16_stress (95.71), 17_koch (96.91) remain, for the
reasons measured above — none of them a property of the anti-aliasing. No
thresholds were tuned. Nothing was committed.
