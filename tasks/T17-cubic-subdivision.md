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
