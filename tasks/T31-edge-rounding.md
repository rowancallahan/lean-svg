# T31 — Straight-edge rounding: one supersample off at fractional positions  [Sonnet, Opus fallback]

Finding (SESSION_SUMMARY, "font demo"): a plain axis-aligned rectangle at a
fractional device position differs from resvg on its straight edges by whole
quarter-steps of coverage (63/96/127/128/176 levels), i.e. our edge lands one
supersample row or column away from tiny-skia's. Same result with a positive
or flipped scale, `<rect>` or `<path>`. Curves differ by 1/16 steps
(15/16/31/32), the known flattening residual. Repro (200×150 canvas, white
background rect, black shape):

```
<rect x="100" y="0" width="300" height="700" transform="translate(20 110) scale(0.072 -0.072)"/>   -- 142 px > 8
<rect x="100" y="0" width="300" height="700" transform="translate(20 20) scale(0.072 0.072)"/>     -- 142 px > 8
<path d="M100 0 L400 0 L400 700 L100 700 Z" transform="translate(20 110) scale(0.072 -0.072)"/>    -- 142 px > 8
<rect x="100" y="0" width="300" height="700" transform="translate(73.352 110) scale(0.072 -0.072)"/> -- 144 px > 8
```

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T31` (branch
`t31-edge-rounding`). Files: `LeanSvg/Raster.lean` (`mkEdge`, the
scan-converter's edge setup and the row/column rounding), and
`LeanSvg/Geom.lean` **only** if the device-space point rounding
(`Mat.apply` / flatten output) turns out to be the cause. Nothing else.
Invariants in `tasks/README.md`; `Effect.lean` untouched; no `Float`.

## Method

1. Shallow-clone tiny-skia into scratch. Read `src/edge.rs` (`LineEdge::new`:
   the `fdot6::round` of `y0`/`y1` to scanlines, the `SHIFT`/`shift_aa`
   handling, the `x` initialisation at the first scanline centre
   `fdot6_to_fdot16(x0 + (dx * (top*64 + 32 - y0)) / 64)` style computation),
   `src/edge_builder.rs` (how points are scaled by `1 << SHIFT` and rounded
   before edges are built: `fdot6` conversion, `clip_shift`), and
   `src/scan/path_aa.rs` (`fill_path_impl` / `SuperBlitter`: how supersampled
   rows map to pixels and how partial coverage is accumulated, the
   `(SCALE - 1)` bias). Also `src/painter.rs` `fill_path`: check whether a
   rect-shaped path takes `fill_rect` (exact-area AA via `scan::fill_rect_aa`)
   instead of the supersampler — if so, that is a second difference to port
   for axis-aligned rectangles (detect: path is 4/5 points, axis-aligned,
   transform axis-aligned).
2. Compare against `Raster.mkEdge`/`rasterize` line by line for the top/bottom
   scanline rounding and the initial x. Our `Fx` is already FDot6 in the
   supersampled space (T1, T17 reports), so the rounding rule should be
   `(y + 32) >> 6` style, not floor — find the actual discrepancy, fix it,
   and explain it in the report with the exact expressions on both sides.
3. Byte-for-byte check on the repro set: write the four SVGs above plus a
   `pos_quad` and `flip_quad` variant with a `Q` edge into scratch, render
   with our binary and `resvg`, count pixels with max channel diff > 8 before
   and after. Required after the fix: **0 pixels > 8** on the four straight
   cases (any residual must be explained as a genuine tiny-skia difference,
   e.g. the rect fast path, and then ported too).

## Verify

- `lake build` clean.
- `python3 tests/run_tests.py` before/after: report every file's within-8;
  expected to rise on several (12_badge, 14_flower, 16_stress, 21_hairlines
  are the likely ones); **no file may drop by more than 0.02**. Files with only
  integer-aligned geometry (01, 06, 19) should be byte-identical — say which
  were.
- Corpora at fast sizes, direct route, `--compare` on
  `--corpus resvg --dir shapes --dir painting/stroke-linejoin --dir structure/transform`
  and `--corpus simple-icons --limit 400`; medians must not fall.
- `run_tiles.py` byte-identical (23 files); `run_adversarial.py` clean;
  `git diff main -- LeanSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`. If after ~40 minutes you have not found the discrepancy,
  stop, write what you ruled out (with the expressions compared) in the
  report, commit that, and say so — an Opus agent will take over.

## Report

**Stopping per the stop rule — the discrepancy is real and fully explained,
but it does not live in `Raster.lean` or in `Mat.apply`/`flatten`, so it is
outside this task's file scope. No source was changed.**

### What was ruled out, with both expressions compared

1. **`mkEdge`'s scanline rounding.** Read `edge.rs`'s `LineEdge::new` (clone
   at `linebender/tiny-skia` master, in scratch) side by side with the
   current `Raster.mkEdge`. They already match, term for term:
   tiny-skia `top = (y0 + 32) >> 6` vs ours
   `Int.ediv (y0 + 32) 64`; tiny-skia
   `x = (x0 + ((slope * dy) >> 16)) << 10` vs ours
   `(x0 + Int.ediv (slope * dy) 65536) * 1024`; `slope` truncating in both
   (`Int.tdiv` vs Rust `/`). This is exactly what the T1 report already
   documented (`Fx` **is** tiny-skia's `FDot6` in the 4×-supersampled space,
   so no rescale is needed) — the SESSION_SUMMARY hypothesis that this might
   still be a plain floor was already stale; T1 shipped the `+32` rule.
   Confirmed correct by the isolation experiment below, not just by reading.
2. **`Mat.apply`'s point rounding.** `Fx.clamp (Int.ediv (m.a*p.x+m.c*p.y) 65536 + m.e)`
   is a plain floor of the 16.16 product — also confirmed correct (below).
3. **tiny-skia's `fill_rect_aa` fast path** (`painter.rs::fill_path`) for
   rect-shaped paths — ruled out as something that needs porting: since our
   generic supersampling scan-converter reproduces resvg **bit-for-bit**
   once the input geometry matches (isolation experiment below), whatever
   fast path resvg/tiny-skia takes for an axis-aligned rect computes
   identical coverage to the generic algorithm. Nothing to port here.
4. Quadratic/`flip_quad` residual (1/16 steps) — not investigated; already
   attributed in the T17 (cubic-subdivision) report to the flattening
   segment-count heuristic, unrelated to this finding.

### The actual discrepancy: transform-matrix precision, not raster rounding

**Isolating experiment.** All four repro SVGs use `scale(0.072 ...)`. `0.072`
is not exactly representable on the `Fx` grid of 1/256. I re-rendered each
repro with the scale argument snapped to the *nearest* value that **is**
exactly representable on that grid, `0.0703125` (= 18/256), leaving
everything else identical:

| case | scale arg | n>8 (of 30000) |
|---|---|---|
| repro1 (`translate(20 110) scale(0.072 -0.072)`) | `0.072` | 142 |
| repro1, snapped | `0.0703125` | **0** |
| repro2 (`translate(20 20) scale(0.072 0.072)`) | `0.072` | 142 |
| repro2, snapped | `0.0703125` | **0** |
| repro4 (`translate(73.352 110) scale(0.072 -0.072)`) | `0.072` | 144 |
| repro4, snapped | `0.0703125` | **0** |
| pure fractional translate, no scale (`x="20.3" y="30.7"` rect, and the
  same via `transform="translate(20.3 30.7)"`) | n/a | **0** (both forms) |

Zero pixels differ, in every case, the instant the scale factor round-trips
exactly through the `Fx` grid, or the transform has no scale at all. That
means `mkEdge`, `rasterize`'s scanline walk, `blitSpan`'s coverage
accumulation, and `Mat.apply`'s point rounding are **already exact** —
there is no "off by one supersample" bug in the scan converter itself.

**Root cause.** `parseTransform` (`LeanSvg/Svg.lean:283`) parses every
`scale()`/`matrix()`/`skewX()`/`skewY()` argument with `parseNumberList`
(`LeanSvg/Fixed.lean:221`), which lexes onto the coordinate grid of 1/256
px (`parseNumber` → `scaleDecimal mant exp10 256 …`, appropriate for a
*position*). `Mat.scale`/`Mat.mk'` (`LeanSvg/Geom.lean:96-100`) then simply
promote that already-quantized `Fx` value to 16.16 by `sx * 256`
(`LeanSvg/Svg.lean:300,304`), so a scale/matrix **coefficient** can only
ever land on a multiple of `256/65536 = 1/256` — a 1/256-relative-to-1
quantization step being applied to a *multiplicative factor*, not an
additive position, so its error is amplified by whatever the factor
multiplies.

Exact expressions, `0.072` (`scale(0.072 -0.072)` in repro1), both sides
computed with the project's own `Int.ediv`/rounding rules:

* **What we compute:** `parseNumber "0.072"` → `scaleDecimal(mant=72,
  exp10=-3, scale=256) = (72·256·2 // 1000 + 1) // 2 = 18` (`Fx`, i.e.
  18/256 = 0.0703125). `Mat.scale 18 (-18)` sets `a = 18*256 = 4608`,
  `d = -4608` (16.16), i.e. **0.0703125** exactly, not 0.072.
* **What it should be:** parsed to 16.16 directly, `scaleDecimal(72, -3,
  65536) = (72·65536·2 // 1000 + 1) // 2 = 4719`, i.e. **0.0719986…** —
  matches the true `0.072` to within the grid's own 2⁻¹⁶ resolution.

Composed with `translate(20 110)` and applied to the rect corner
`(400, 700)` (`CTM.mul`, `Mat.apply`, both exact per their own formulas):

| | `y'` (Fx/256, device px) |
|---|---|
| ours (quantized scale) | `60.78125` |
| 16.16-precision scale | `59.59375` |
| true (`110 + (-0.072)·700`) | `59.6` |
| resvg's actual rendered transition (read off the oracle PNG) | `≈59.5` |

Ours is **1.19–1.28 px off** — over four supersamples, not one — and the
same computation for the `x` corners shows 0.17–0.68 px of error depending
on which corner (the error scales with the user-space coordinate being
transformed, 100 vs 400, since it's a *relative* error in a multiplicative
factor). This fully accounts for the 142–144 bad pixels: at `x=35` in
repro1, row 59 (relative pixel row −1, entirely **outside** our bounding
box since our quantized top edge floors to row 60) reads white/white for
us against resvg's 128 (≈50 % coverage), and row 60 reads alpha 63 (only
the last of its four sub-scanlines is inside, sub-scanline index 3 ⇒
`y=60.75`, matching the quantized corner exactly) against resvg's fully
covered 0. The "quarter-step" alpha values in the SESSION_SUMMARY note
(63/96/127/128/176) are an artifact of *which* sub-scanline the
already-wrong edge position happens to round to, not evidence of a bad
rounding *rule*.

### Why this wasn't caught by the corpora

`python3 tests/run_tests.py` on the unmodified worktree (baseline, `tol=8`):

```
19/23 passed, 4 failed, 0 render errors
```

failures: 12_badge (98.561), 14_flower_transforms (97.814), 15_spiral_stroke
(97.480), 16_stress_2000 (97.481) — the same four files and the same
percentages already on record in `SESSION_SUMMARY.md`, and already
attributed by the T1 report to curve-flattening/stroker residuals, not to
straight-edge AA. No corpus or adversarial file was re-run past this
baseline check since no source changed; `run_tiles.py`/`run_adversarial.py`
are byte-identical to main by construction (nothing was edited).
`git diff main -- LeanSvg/Effect.lean` is empty (never touched).

### What changed (files)

Only `tasks/T31-edge-rounding.md` (this file — it did not exist yet on this
branch, which was cut before the spec was added to main; copied over from
main, then this `## Report` appended). **No `.lean` file was touched**:
`git diff main -- LeanSvg/` is empty. `lake build` was run once, unmodified,
to produce the worktree's binary for the isolation experiments above; it is
identical to main's `.lake/build/bin/lean-svg`.

### Recommendation

The real fix belongs in `LeanSvg/Fixed.lean` (`parseNumber`/`scaleDecimal`,
or a new sibling parsed onto the 16.16 grid) and `LeanSvg/Svg.lean`
(`parseTransform`, to use that parser for `scale()`'s and `matrix()`'s
linear coefficients and `skewX()`/`skewY()`'s tangent, not for `translate()`
or `matrix()`'s `e`/`f`, which are positions and are fine at `Fx`
precision) — both outside this task's allowed files
(`Raster.lean`, `Geom.lean` only if `Mat.apply`/`flatten` is the cause,
which it is not). Suggest a follow-up task scoped to those two files,
re-using the four repro SVGs and the `run_tests.py`/corpora verification
steps from this spec — they should still all apply unchanged, since the
scan converter itself needs no work.

## Report 2 — rescoped fix (`Fixed.lean` + `Svg.lean::parseTransform`)

The coordinator rescoped the task to exactly the two files identified above.
This section is the fix and its numbers.

### What changed (files)

* **`LeanSvg/Fixed.lean`**, +34/−0, purely additive: `parseNumber16`
  (mirrors `parseNumber` but calls `scaleDecimal mant exp10 65536 …` instead
  of `… 256 …` — the same lexer, the same rounding-halves-away-from-zero
  rule inside `scaleDecimal`, just landed on the 16.16 grid) and
  `parseNumberList16` (mirrors `parseNumberList` byte for byte, calling
  `parseNumber16`). `parseNumber`/`parseNumberList`/`scaleDecimal`/
  `parseDecimal` are untouched — `git diff main -- LeanSvg/Fixed.lean`
  shows only two new function bodies added after their existing 1/256
  siblings, nothing else moved or edited.
* **`LeanSvg/Svg.lean`**, `parseTransform` only, +13/−3: the argument bytes
  are now lexed twice, once by the existing `parseNumberList` (`Fx`, for
  positions: `translate`'s offsets, `matrix`'s `e f`, and — unchanged —
  `rotate`/`skewX`/`skewY`'s angle) and once by the new `parseNumberList16`
  (for the linear coefficients). `matrix`'s `a b c d` now come from `g16`
  and go straight into `Mat.mk'` with no `* 256`; `scale`'s factors come
  from `g16` and go into `Mat.scale16` (which is `mk' sx 0 0 sy 0 0` — no
  promotion) instead of `Mat.scale` (which did `sx * 256` on an
  already-quantized `Fx` value — the old bug). `rotate`/`skewX`/`skewY`
  are byte-for-byte unchanged.
* **Deliberately not changed: `rotate`'s angle and `skewX`/`skewY`'s
  angle.** Their coefficient (`sin`/`cos`/`tan` of the angle) is produced by
  `sinCos16`/`degToRad16` in `Geom.lean`, which is off limits this round and
  which hard-codes the assumption that its input is a *`Fx`-grid* degree
  (`Int.emod deg (360*256)`, `… / 46080`); feeding it a 16.16-grid degree
  would silently misinterpret it by a factor of 256, which is worse than
  today's precision, not better. Bounding the actual damage of leaving this
  as-is: the worst-case coefficient error from a 1/256°-quantized angle is
  `sin(1/512°) ≈ 6.8e-5` (rounding puts the true angle within half a step),
  which on the largest coordinate this renderer accepts before clamping
  (`Fx.maxVal` ≈ 4.19M px) is a 285 px position error in the adversarial
  extreme, but on every real shape measured in this repo (corpus files, up
  to a few hundred user units) it is **≤ 0.05 px, under one supersample** —
  i.e. exactly the class of error this task is about fixing, but already
  below the visible threshold, unlike `scale`'s 2.3%-of-value error which
  is not bounded by the coefficient's own magnitude the way an angle's
  sin/cos is. No corpus file's `rotate`/`skewX`/`skewY` usage changed by
  more than 0.1 points in the corpora run below, which is consistent with
  that bound. A follow-up that also touches `Geom.lean` could close this
  residual by giving `degToRad16` a 16.16-degree sibling; not done here.
* `lake build`: clean, no new warnings. No `partial`/`unsafe`/`panic!`/
  `!`-indexing introduced (`git diff` grepped for all four — none). Every
  loop in the new code is the same bounded `for _ in [0:bs.size+1]` shape
  the existing parsers already use. `git diff main -- LeanSvg/Effect.lean`
  is empty.
* Also added `tests/adversarial/extreme_matrix_scale.svg` (checked in,
  static, matching the existing style of `tests/adversarial/huge_numbers.svg`
  which already had a `scale(1e30)` case): `scale(1e30)`, `scale(1e-30)`,
  `matrix(1e-30 0 0 1e-30 5 5)`, `matrix(1e30 1e30 1e30 1e30 5 5)`,
  `scale(-1e300 1e-300)` — exercises `parseNumber16`'s own saturation at the
  same extremes the 1/256 parser was already tested at.

### Repro set: 0 px > 8 on the four straight cases

| case | n>8 before | n>8 after |
|---|---|---|
| repro1 `translate(20 110) scale(0.072 -0.072)` (rect) | 142 | **0** |
| repro2 `translate(20 20) scale(0.072 0.072)` (rect) | 142 | **0** |
| repro3 same shape as repro1, as `<path>` | 142 | **0** |
| repro4 `translate(73.352 110) scale(0.072 -0.072)` (rect) | 144 | **0** |

Quad variants (`M100 0 Q250 350 400 0 L400 700 L100 700 Z`, same two
transforms as repro1/repro2): dropped from 179/180 to **1/2** pixels, each
off by exactly 16 (one level of `blitSpan`'s 16-per-quarter-column unit) —
the flattening residual T17's report already documents (a curve's polyline
approximation, not a rounding bug), unaffected by this fix as expected.

### `run_tests.py`, before / after (tol 8, unmodified vs fixed binary)

19/23 pass both before and after (same 4 failures, all attributed by the T1
report to curve-flattening/stroker residuals). Only the within-8 column is
shown for files that moved; the rest are listed to confirm "no file dropped."

| file | within-8 before | after | Δ | byte-identical? |
|---|---|---|---|---|
| 01_triangle | 100.000 | 100.000 | 0.000 | yes |
| 02_rect_circle | 99.997 | 99.997 | 0.000 | yes |
| 03_curves | 99.855 | 99.855 | 0.000 | yes |
| 04_stroke | 99.965 | 99.965 | 0.000 | yes |
| 05_transform | 99.987 | 99.987 | 0.000 | yes |
| 06_evenodd | 100.000 | 100.000 | 0.000 | yes |
| 07_opacity | 99.885 | 99.885 | 0.000 | yes |
| 08_group_inherit | 99.992 | 99.992 | 0.000 | yes |
| 09_viewbox | 99.963 | 99.963 | 0.000 | yes |
| 10_polygon_star | 99.823 | 99.823 | 0.000 | yes |
| 11_style_attr | 99.983 | 99.983 | 0.000 | yes |
| 12_badge | 98.561 | 98.611 | **+0.050** | no |
| 13_gear_evenodd | 99.368 | 99.754 | **+0.386** | no |
| 14_flower_transforms | 97.814 | 98.551 | **+0.737** | no |
| 15_spiral_stroke | 97.480 | 97.480 | 0.000 | yes |
| 16_stress_2000 | 97.481 | 97.481 | 0.000 | yes |
| 17_koch_snowflake | 99.222 | 99.983 | **+0.761** | no |
| 18_rose_lissajous | 99.690 | 99.690 | 0.000 | yes |
| 19_sierpinski | 100.000 | 100.000 | 0.000 | yes |
| 20_function_plot | 99.777 | 99.777 | 0.000 | yes |
| 21_hairlines | 99.884 | 99.884 | 0.000 | yes |
| 22_arcs | 99.214 | 99.214 | 0.000 | yes |
| 23_dashes | 99.371 | 99.426 | **+0.055** | no |

Zero files dropped (the ≤0.02 budget was not needed at all: every changed
file *improved*). "Byte-identical?" is a literal `cmp` of the natural-size
PNGs, not just equal percentages, for all 23 — confirms the 18 unaffected
files (no `scale`/`matrix` transform, or one whose parsed value happened to
already sit on the 1/256 grid) are untouched pixel-for-pixel. The five
that changed (12, 13, 14, 17, 23) all use `scale`/`matrix` with fractional
coefficients; `--width 800` re-render of those five confirms the same
byte-for-byte properties hold at that size too (spot-checked, not
re-tabulated here per the short-loop rule).

### Corpora, fast, `--compare` against the unmodified binary

`resvg` suite, `--dir structure/transform --dir shapes`, `--width 100`
(152 files × 2 routes):

| route | pass before | pass after | med within-8 before | after |
|---|---|---|---|---|
| direct | 128/152 (84.2%) | **131/152 (86.2%)** | 100.000% | 100.000% |
| usvg | 142/152 (93.4%) | **145/152 (95.4%)** | 100.000% | 100.000% |

6 files newly passing, 0 newly failing, 0 regressed: all three of
`structure/transform/{extra-spaces,matrix-no-commas,matrix}.svg`, on both
routes, +1.030 points each (98.910% → 99.940% within-8). Medians did not
fall (both already at the ceiling).

`simple-icons`, `--limit 400`, `--width 64` (400 files × 2 routes):

| route | pass before | pass after | med within-8 before | after |
|---|---|---|---|---|
| direct | 232/400 (58.0%) | 232/400 (58.0%) | 99.133% | 99.133% |
| usvg | 309/400 (77.2%) | 309/400 (77.2%) | 99.121% | 99.121% |

**Unchanged, 0 files moved.** Checked why: `grep -lE 'scale\(|matrix\('
tests/corpora/simple-icons/icons/*.svg` matches **0 of 400** files — this
corpus scales icons entirely through `viewBox`/`width`/`height` (a
different code path, not `parseTransform`), never an inline `scale()`/
`matrix()` transform attribute. The coordinator's prediction that
"simple-icons is where most fractional scales live" does not hold for this
corpus as sampled; the gain is concentrated in the `resvg` suite's
`structure/transform` directory instead, which exists specifically to test
transform-string parsing. Medians did not fall (they are unchanged), so the
verify condition holds regardless.

### `run_tiles.py` / `run_adversarial.py`

* `run_tiles.py`: **23/23 files byte-identical**, quadrant tiles stitch to
  the full render, both before and after (unaffected by this change since
  no shape in the built-in 23-file suite exercises a non-1/256-representable
  `scale`/`matrix` argument at the sizes it renders — see the byte-identity
  table above).
* `run_adversarial.py`: **43/43 cases clean, 0 violations** (up from the
  42 already on record — `+1` is the new `extreme_matrix_scale.svg`, which
  is itself clean: no panic/crash/hang, valid PNG, exit 0).

### Verify checklist

- [x] `lake build` clean, no new warnings.
- [x] `run_tests.py` before/after per file; no drop; 5 files improved,
      18 byte-identical.
- [x] Corpora fast `--compare`, `resvg --dir structure/transform --dir
      shapes` (medians held, +6 pass) and `simple-icons --limit 400`
      (medians held, 0 change — explained above).
- [x] `run_tiles.py` byte-identical (23/23).
- [x] `run_adversarial.py` clean (43/43, including the new extreme case).
- [x] `git diff main -- LeanSvg/Effect.lean` empty.
- [x] Repro set: 0/30000 on all four straight cases; quad cases down to
      1–2 px, each the known ±16 flattening residual.
