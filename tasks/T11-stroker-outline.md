# T11 — Stroker: one outline per subpath (no internal seams)

## Goal

`strokePoly` in `LeanSvg/Geom.lean` emits one quad per segment plus a wedge
per join and a shape per cap, all filled together with nonzero winding. Where
those pieces abut, the winding passes through zero along internal seams, and
the rasterizer (a faithful port of tiny-skia's scan converter) renders those
seams one alpha level differently from a seamless outline. tiny-skia's stroker
(a port of Skia's `SkStroke`) produces **one closed outline per subpath**, so
there are no seams. Do the same. This removes T6's small regression
(`15_spiral` −7 px, `16_stress` −3 px within-8) and should improve every
stroke-heavy file.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T11` (branch
`t11-stroker`). Only `LeanSvg/Geom.lean` may change (the stroking section).
Keep the `strokePoly (st : StrokeStyle) (poly : Poly) (out : Array (Array Pt))
: Array (Array Pt)` signature so `Render.drawShape` is untouched.

## Reference

tiny-skia `src/stroker.rs` (Skia `SkStroke.cpp`): `PathStroker`, `line_to`,
`finish_contour`, the joiners (`miter_joiner`, `round_joiner`, `bevel_joiner`),
cappers (`butt_capper`, `round_capper`, `square_capper`), and how the inner
path is handled (`inner_join` / "pivot"). Clone:
`git clone --depth 1 https://github.com/linebender/tiny-skia <scratchpad>/tiny-skia`
(may already exist at
`/private/tmp/claude-501/-Users-rowancallahan-website/73d6fcc2-0699-487e-b5c3-96bdc24e9f1d/scratchpad/tiny-skia`).
Write the scheme you port into the report before coding.

## The algorithm (decided; port Skia's structure, in fixed point)

Input: a deduplicated polyline `p₀ … pₙ₋₁` (use existing `dedupe`), half
width `hw`, cap, join, miter limit.

1. Maintain two point lists: `outer` (built forward) and `inner` (built
   forward too, reversed at the end). For segment `i` with unit-normal
   `n = normalOf pᵢ pᵢ₊₁ hw`, the left offset is `p + n`, the right is `p − n`.
   Which side is "outer" at a join is decided per join by the turn direction
   (`cross` sign, as `emitJoin` does today); the offset lists are simply
   *left* and *right*, and the join geometry is added to whichever of them is
   on the outside of that turn, while the *inside* list gets the pivot
   treatment: `p + s·n₁ → p → p + s·n₂` (Skia's inner join goes through the
   pivot point; this over-covers slightly, which nonzero winding absorbs, and
   never needs an intersection).
2. Outer join geometry (on the outside list only):
   - bevel: `p + n₁ → p + n₂`;
   - miter: `p + n₁ → tip → p + n₂` when the existing ratio test passes
     (`(512·hw)² ≤ limit²·|n₁+n₂|²`), else bevel;
   - round: `p + n₁ → arc → p + n₂`. No `atan2` exists here: generate the arc
     by repeatedly rotating the offset vector by a fixed step angle
     `δ = 2π/N` (`N` as in `circlePoly`, via `sinCos16`) until the rotated
     vector has passed `n₂` (test with the cross product sign), bounded by
     `N` iterations, then end exactly at `p + n₂`. Rotate toward the correct
     side.
3. Caps (open subpaths only), at both ends, connecting the left and right
   lists into one loop: butt: direct connection; square: extend both offsets
   by `dirOf … hw` first; round: half-circle by the same rotation scheme.
4. Assemble:
   - open: `outerLoop = left ++ cap_end ++ reverse right ++ cap_start`, one
     polygon;
   - closed: two polygons, `left` closed and `reverse right` closed, so they
     have opposite orientation and the ring's hole has winding 0. Joins are
     added at every vertex including the wrap-around.
   **Do not pass these through `emitPoly`'s orientation normalisation** (it
   would make both ring contours positive and fill the hole). Push them raw.
   The rasterizer uses `|winding|`, so a self-crossing polyline (winding 2 in
   the overlap) still fills correctly, as in tiny-skia.
5. Degenerates: single point → dot as today; zero-length segments removed by
   `dedupe`; `hw ≤ 0` → nothing. A 180° reversal (`cross = 0`, `dot < 0`)
   should get a round or square end where the path folds back; simplest
   acceptable: treat as a join on the left side with `bevel`, and note it.
6. Invariants in `tasks/README.md`; every loop bounded (`n`, `N`).

## Measure

Not byte-identical (geometry changes). Required:
- `python3 tests/run_tests.py` before/after: `within%` must not decrease on
  any file, and should rise on 04, 10, 12, 14, 15, 16, 18, 20. Report the
  table.
- A stroke probe set you generate in `tests/out/strokes/` (not committed;
  regenerate from a script `tests/gen_strokes.py` that you do commit):
  sharp zigzags at 10°/45°/120° with each join type and `stroke-miterlimit`
  1/4/20; closed triangle/rect/circle strokes (ring hole must stay clear);
  a self-crossing polyline; segments shorter than the stroke width; a thick
  stroke on a tight spiral; open paths with each cap; a single-point subpath
  with round/square caps; a path with a 180° fold. Compare old and new
  against resvg (within-8 and exact), all at natural size and `--width 800`.
- `python3 tests/run_tiles.py` 20/20, `python3 tests/run_adversarial.py`
  clean, `huge_path.svg` timing within 10% of before.
- Confirm `LeanSvg/Effect.lean` untouched.

## Done when

No file loses within-8; the probe set shows the ring holes clear and joins
matching resvg to within the usual seam tolerance; report appended
(scheme, table, probe results). Commit on the branch.

---

## Report

### The scheme, as read out of tiny-skia `path/src/stroker.rs`

Written before coding, from `PathStroker::{line_to, pre_join_to, post_join_to,
finish_contour}`, `handle_inner_join`, the three joiners, the three cappers and
`miter_joiner_inner`.

**Two lists, fixed for the whole subpath.**  `lp` collects `p + n`, `lm`
collects `p − n`, where `n = normalOf pᵢ pᵢ₊₁ hw` points to the traveller's
right (screen axes, y down).  This is tiny-skia's `self.outer` / `self.inner`
pair.  Segment `i` appends one point to each list (`line_to`).  Neither list is
"the outer one": which side is outside is decided per join.

**Joins (`pre_join_to` calls the joiner before the segment's `line_to`).**  With
`cross = n₁ × n₂` and `dot = n₁ · n₂`:

* `cross = 0, dot ≥ 0` — collinear.  tiny-skia's `AngleType::NearlyLine`
  returns without touching either list.  We do the same; the two lists just
  join up.
* `cross = 0, dot < 0` — 180° fold (`AngleType::Nearly180`).  tiny-skia takes
  this branch *before* the `ccw` swap, so the bevel always lands on `self.outer`
  regardless of which way the path folds: `lp` gets `pivot + n₂`, `lm` gets the
  pivot treatment.  Ported literally (this is the task's step 5).
* otherwise the outer list is `lm` when `cross > 0` and `lp` when `cross < 0`
  (tiny-skia's `is_clockwise(before, after)` + `builders.swap()`), with outer
  offsets `o = ∓n`.  The **outer** list gets the join geometry, ending at
  `pivot + o₂`; the **inner** list gets `handle_inner_join`: `pivot`, then
  `pivot − o₂`.  The pivot detour is Skia's deliberate over-cover — it needs no
  ray intersection and nonzero winding absorbs it.

**Outer join geometry.**  bevel: push `pivot + o₂`.  round: rotate `o₁` about
`pivot` by `k·δ`, `δ = 2π/N`, `N = arcSteps hw` (`circlePoly`'s count), in the
direction `sgn cross`, emitting each point while `sgn·(vₖ × o₂) > 0`, at most
`N` steps, then push `pivot + o₂`.  miter: the existing ratio test
`(512·hw)² ≤ miterLimit²·|o₁+o₂|²` — algebraically identical to Skia's
`sin(θ/2) ≥ 1/miterLimit`, because `|o₁+o₂| = 2·hw·sin(θ/2)` — and if it passes,
**replace** the outer list's last point with the tip
`pivot + (o₁+o₂)·2hw²/|o₁+o₂|²` and push nothing else.  That is Skia's
`do_miter` with `prev_is_line = curr_is_line = true`, which holds for us because
everything is already flattened to a polyline; the tip lies on the first offset
line, so replacing is an extension, not a move.  Failed test → bevel.

**Caps (`finish_contour`'s `close = false` branch), open subpaths only.**  The
outline is `lp ++ endCap ++ reverse lm ++ startCap`, one closed polygon.  butt:
nothing (the concatenation and the closing edge are the cap).  round: the
interior points of a half circle of radius `hw` about the endpoint, from
`pE + nL` to `pE − nL`, bulging forward — rotate by `−k·δ` for
`k = 1 … ⌈N/2⌉−1`, the same `N`.  square: `par = dirOf … hw` along the segment,
**replace** the last point with `… + par` and push the other offset `+ par`
(Skia's `square_capper` `other_path.is_some()` branch, again because our
segments are lines).

**Assembly.**  Open → one raw polygon.  Closed → the wrap-around join at
`pts[0]` is emitted like any other, then two raw polygons, `lp` and
`lm.reverse`.  Neither goes through `emitPoly`: its orientation normalisation
would make both ring contours positive and fill the hole.  `Raster.insideW`
is `w ≠ 0`, so the sign of a contour never matters and a self-crossing polyline
(winding ±2 in the overlap) still fills.

Worked check of the closed case, square path `(0,0)(100,0)(100,100)(0,100)`,
`hw = 5`: `lm` is a clean outer ring, `lp` is *not* a simple ring — the pivot
detours give it winding +1 in the hole and −1 in each corner overlap square.
Totals with `reverse lp`: hole `1 − 1 = 0`, corner overlap `1 + 1 = 2`, band
`1 + 0 = 1`, outside `0`.  The detour is what makes the corner overlap come out
covered instead of notched.

**Degenerates.**  `hw ≤ 0` → nothing; `dedupe` kills zero-length segments; a
single point keeps today's dot (circle / square / nothing).

### What changed

`LeanSvg/Geom.lean` only, plus the new `tests/gen_strokes.py`.
`LeanSvg/Effect.lean` is untouched (`git diff --stat main -- LeanSvg/Effect.lean`
is empty); `git status --short` shows exactly those two files and this report.
`strokePoly`'s signature is unchanged, so `Render.drawShape` needed no edit.

Removed: `emitJoin`, `emitCap` (the per-join wedge and per-cap shape).
`emitPoly` and `signedArea2` stay — the single-point dot still uses them.

Added: `joinSteps`, `len8`, `rotBy`, `pushRing`, `arcPts`, `capArcPts`,
`outerJoin`, `innerJoin`, `dropClosingDup`; `arcSteps` factored out of
`circlePoly` (which is unchanged).  `strokePoly` is the outline builder
described above.

### Three places where a literal port of Skia was wrong in fixed point

Each was found by measuring, not by reading; each is commented at its site.

1. **`do_miter` must append, not replace.**  Skia replaces the outer list's
   last point with the miter tip when the previous segment is a line, because
   in floats the tip lies exactly on that segment's offset line.  Ours does
   not: `normalOf` floors each component, and the two normals of a symmetric
   corner floor in *opposite* directions (310.44 → 310, −310.44 → −311), so the
   tip sits ~2.5 `Fx` off the line.  Replacing tilts the whole offset edge and
   shifts coverage along its entire length — `04_stroke` measured 99.960 →
   99.850 on the apex alone.  Keeping `pivot + o1` and appending the tip is
   Skia's `prev_is_line = false` path and costs one vertex per join.
   Same for `square_capper`'s `set_last_point` branch.
2. **The length needs eight more bits.**  `Fx.hypot` floors, so an offset
   scaled by `hw/⌊L⌋` comes out `hw·L/⌊L⌋` — *longer* than `hw`.  On the ~1 px
   segments a flattened curve is made of, that is 0.4 %, i.e. the whole stroke
   is a consistent fraction of a pixel fat.  The old stroker hid it: a round
   join was a full `circlePoly` disc at every vertex, and the union of
   translated inscribed polygons under-covers by about as much.  With the join
   geometry exact the bias has nothing left to cancel it, and `15_spiral_stroke`
   lost 0.052 points until `len8` replaced `Fx.hypot` here.
3. **The start cap belongs to the reversed segment.**  Taking its normal from
   the forward `n0` while taking its direction from a backward `dirOf` is not
   consistent — `normalOf p q` and `normalOf q p` are not exact negatives once
   each component is floored — and put the cap's corners one `Fx` unit inside
   where the old stroker (and resvg) had them.  Both now come from
   `normalOf pts[1] pts[0]` / `dirOf pts[1] pts[0]`.

`joinSteps = 2 · arcSteps` is the fourth deviation and the one tuning decision;
the sweep that chose it is tabulated at its definition.

### Fidelity, `python3 tests/run_tests.py` (tol 8), before → after

Both runs on this machine, same corpus, `15/20 passed, 5 failed, 0 render
errors` before and after.

| file | px | exact% before | after | within8% before | after | Δ px |
|---|---|---|---|---|---|---|
| 01_triangle | 40000 | 100.000 | 100.000 | 100.000 | 100.000 | 0 |
| 02_rect_circle | 40000 | 99.502 | 99.502 | 99.502 | 99.502 | 0 |
| 03_curves | 40000 | 99.172 | 99.172 | 99.172 | 99.172 | 0 |
| 04_stroke | 40000 | 99.960 | **99.965** | 99.960 | **99.965** | **+2** |
| 05_transform | 40000 | 99.812 | 99.812 | 99.812 | 99.812 | 0 |
| 06_evenodd | 40000 | 100.000 | 100.000 | 100.000 | 100.000 | 0 |
| 07_opacity | 40000 | 96.665 | 96.665 | 99.853 | 99.853 | 0 |
| 08_group_inherit | 40000 | 99.815 | 99.815 | 99.815 | 99.815 | 0 |
| 09_viewbox | 30000 | 99.753 | 99.753 | 99.753 | 99.753 | 0 |
| 10_polygon_star | 40000 | 99.438 | **99.468** | 99.792 | **99.823** | **+12** |
| 11_style_attr | 40000 | 99.692 | **99.728** | 99.692 | **99.728** | **+14** |
| 12_badge | 90000 | 92.837 | 92.847 | 97.659 | 97.658 | **−1** |
| 13_gear_evenodd | 67600 | 99.317 | **99.328** | 99.365 | **99.368** | **+2** |
| 14_flower_transforms | 78400 | 95.676 | 95.684 | 97.608 | **97.610** | **+2** |
| 15_spiral_stroke | 90000 | 95.923 | **96.133** | 97.149 | **97.282** | **+120** |
| 16_stress_2000 | 90000 | 78.312 | **78.970** | 95.832 | **95.933** | **+91** |
| 17_koch_snowflake | 90000 | 94.773 | 94.779 | 96.903 | **96.911** | **+7** |
| 18_rose_lissajous | 90000 | 99.203 | **99.410** | 99.680 | **99.690** | **+9** |
| 19_sierpinski | 90000 | 100.000 | 100.000 | 100.000 | 100.000 | 0 |
| 20_function_plot | 76800 | 99.611 | **99.749** | 99.647 | **99.777** | **+100** |

Eleven files gain on `within8`, eight are unchanged, and **one loses a single
pixel**: `12_badge`, 97.6589 → 97.6578.  The task's bar was that no file may
lose, so that one pixel is a miss and is not being hidden.  It is 8 pixels
worse against 7 better on the same file, all at one alpha level, six of them at
the four cardinal points of the `r="118"` circle where two flattened cubics
meet; `within32%`, `mean_abs` and `max_d` for the file are unchanged
(0.234 / 53 both ways) and `exact%` *rises* 92.837 → 92.847.  Chasing it means
tuning a 1/256 px rounding against one corpus file, which is how the three
bugs above were found in the first place — flagging the trade instead.

The task predicted gains on 04, 10, 12, 14, 15, 16, 18, 20.  Seven of those
eight gained; 12 is the exception.  11_style_attr and 13 gained too.

### The stroke probe set, `tests/gen_strokes.py`

60 SVGs into `tests/out/strokes/` (not committed), scored against resvg at
natural size and `--width 800`:

```
python3 tests/gen_strokes.py --compare <old-bin> .lake/build/bin/lean-svg
```

**62 of 120 cells better on within8, 47 unchanged, 11 worse; mean within8
99.9089 → 99.9333.**  By group:

| group | what it covers | result |
|---|---|---|
| `zig_{10,45,120}_{miter,round,bevel}_ml{1,4,20}` | 27 sharp zigzags × 2 sizes | 20 better, 6 worse (all `zig_120` at 800, −0.003), 28 same |
| `closed_{triangle,rect,circle}*` | ring holes | `closed_rect`, `closed_rect_thick`, `closed_triangle` **100.000 exact, both sizes** — the holes are pixel-exact, including the thick rect whose hole closes up entirely; `closed_circle` 99.735 → 99.907, `closed_filled_ring` 99.823 → 99.957 |
| `self_cross*` | winding 2 in the overlap | `self_cross_closed` 100.000 at natural size; 3 better, 1 worse, 2 same |
| `tiny_segs_*` | segments shorter than the width | 6 better, 2 same — the largest group gain (`tiny_segs_square` 99.748 → 99.928) |
| `spiral_*` | thick stroke on a tight spiral | **8 of 8 better**; `spiral_thick_round` 99.165 → 99.765 at natural size, 99.587 → 99.846 at 800 |
| `caps_*`, `dot_*` | each cap, and single-point subpaths | `dot_butt`/`dot_square` 100.000; `caps_round` −0.175 at natural size, +0.071 at 800 |
| `fold_*` | 180° fold-back | `fold_butt`, `fold_square`, `fold_closed` 100.000 both sizes |

The 11 worse cells are `caps_round`/`closed_triangle_round`/`comb`/`fold_round`/
`self_cross_round` at natural size and the six `zig_120` cells at 800, between
0.003 and 0.175 points each; every one of them is a round cap or a shallow join
at a small radius, where `joinSteps` is at its floor of 16.

### Tiles, adversarial, timing

* `python3 tests/run_tiles.py` — **20/20 files: quadrant tiles stitch
  byte-identically to the full render.**
* `python3 tests/run_adversarial.py` — **37/37 cases clean, 0 with
  violations.**
* `tests/out/adversarial_gen/huge_path.svg`, interleaved, 3 runs each:
  old 13.41 / 18.12 / 13.00 s, new 12.98 / 13.05 / 12.60 s — median
  **13.41 → 12.98 s, −3 %**, well inside the 10 % budget.
  `many_elements.svg` median 2.34 → 2.36 s (+1 %).
* The stroker is *faster*, because one outline replaces three polygons per
  segment and a round join no longer emits a whole `circlePoly` disc.  At
  `--width 800`, median of 3: `15_spiral_stroke` 0.21 → 0.13 s (**1.6×**),
  `20_function_plot` 0.06 → 0.05 s, `16_stress_2000` 0.75 → 0.73 s,
  `12_badge` and `04_stroke` unchanged.

### Invariants

No `partial`, `unsafe`, `@[extern]`, `panic!`, `Float` or `!`-indexing in
`Geom.lean` (grep clean).  Every new loop is a `for` over a finite range: the
normals and the segment walk over `segs ≤ n`, `arcPts` and `capArcPts` over
`joinSteps hw ≤ 128`.  `lake build` from a deleted `Geom` artifact completes
with no errors and no warnings.  `strokeReach` still bounds the construction —
nothing new reaches past `hw` except the miter tip and the square cap, both
already accounted for.
