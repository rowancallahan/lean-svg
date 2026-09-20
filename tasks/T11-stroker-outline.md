# T11 — Stroker: one outline per subpath (no internal seams)

## Goal

`strokePoly` in `MicroSvg/Geom.lean` emits one quad per segment plus a wedge
per join and a shape per cap, all filled together with nonzero winding. Where
those pieces abut, the winding passes through zero along internal seams, and
the rasterizer (a faithful port of tiny-skia's scan converter) renders those
seams one alpha level differently from a seamless outline. tiny-skia's stroker
(a port of Skia's `SkStroke`) produces **one closed outline per subpath**, so
there are no seams. Do the same. This removes T6's small regression
(`15_spiral` −7 px, `16_stress` −3 px within-8) and should improve every
stroke-heavy file.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T11` (branch
`t11-stroker`). Only `MicroSvg/Geom.lean` may change (the stroking section).
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
- Confirm `MicroSvg/Effect.lean` untouched.

## Done when

No file loses within-8; the probe set shows the ring holes clear and joins
matching resvg to within the usual seam tolerance; report appended
(scheme, table, probe results). Commit on the branch.
