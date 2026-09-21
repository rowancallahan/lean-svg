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
`t31-edge-rounding`). Files: `MicroSvg/Raster.lean` (`mkEdge`, the
scan-converter's edge setup and the row/column rounding), and
`MicroSvg/Geom.lean` **only** if the device-space point rounding
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
  `git diff main -- MicroSvg/Effect.lean` empty.
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

**Root cause.** `parseTransform` (`MicroSvg/Svg.lean:283`) parses every
`scale()`/`matrix()`/`skewX()`/`skewY()` argument with `parseNumberList`
(`MicroSvg/Fixed.lean:221`), which lexes onto the coordinate grid of 1/256
px (`parseNumber` → `scaleDecimal mant exp10 256 …`, appropriate for a
*position*). `Mat.scale`/`Mat.mk'` (`MicroSvg/Geom.lean:96-100`) then simply
promote that already-quantized `Fx` value to 16.16 by `sx * 256`
(`MicroSvg/Svg.lean:300,304`), so a scale/matrix **coefficient** can only
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
`git diff main -- MicroSvg/Effect.lean` is empty (never touched).

### What changed (files)

Only `tasks/T31-edge-rounding.md` (this file — it did not exist yet on this
branch, which was cut before the spec was added to main; copied over from
main, then this `## Report` appended). **No `.lean` file was touched**:
`git diff main -- MicroSvg/` is empty. `lake build` was run once, unmodified,
to produce the worktree's binary for the isolation experiments above; it is
identical to main's `.lake/build/bin/microsvg`.

### Recommendation

The real fix belongs in `MicroSvg/Fixed.lean` (`parseNumber`/`scaleDecimal`,
or a new sibling parsed onto the 16.16 grid) and `MicroSvg/Svg.lean`
(`parseTransform`, to use that parser for `scale()`'s and `matrix()`'s
linear coefficients and `skewX()`/`skewY()`'s tangent, not for `translate()`
or `matrix()`'s `e`/`f`, which are positions and are fine at `Fx`
precision) — both outside this task's allowed files
(`Raster.lean`, `Geom.lean` only if `Mat.apply`/`flatten` is the cause,
which it is not). Suggest a follow-up task scoped to those two files,
re-using the four repro SVGs and the `run_tests.py`/corpora verification
steps from this spec — they should still all apply unchanged, since the
scan converter itself needs no work.
