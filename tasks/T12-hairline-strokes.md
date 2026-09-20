# T12 — Hairline strokes (device width ≤ 1 px)

## Goal

T1 found that resvg does not use the supersampling scan converter for thin
strokes: `painter.rs::treat_as_hairline` routes any stroke whose device-space
width is ≤ 1 to `scan::hairline_aa` (Skia's anti-aliased hairline, a
Wu-style line rasterizer), with the coverage scaled by the width when it is
below 1. A 1 px diagonal of length 200 gets ~160 px² of ink from resvg versus
our geometrically correct ~200 px², and that is most of `17_koch_snowflake`'s
miss and part of `16_stress_2000`'s. Port the hairline path.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T12` (branch
`t12-hairline`). Files: `MicroSvg/Raster.lean` (add a `hairline` function
producing a `Mask`; do not change `rasterize`), `MicroSvg/Render.lean`
(`drawShape`: route strokes to it). Do not touch `Geom.lean` (T11 owns the
stroker).

## Reference

tiny-skia `src/scan/hairline_aa.rs` (and `hairline.rs` for the non-AA
structure it shares), plus `painter.rs::treat_as_hairline` for the exact
condition and the coverage scaling (`stroke_path` computes `coverage` for
widths < 1 and multiplies the paint alpha). Clone or reuse
`/private/tmp/claude-501/-Users-rowancallahan-website/73d6fcc2-0699-487e-b5c3-96bdc24e9f1d/scratchpad/tiny-skia`.
Write the exact scheme into the report before coding: the fixed-point
formats (FDot6/FDot16), how the major axis is chosen, the per-step coverage
split between the two pixels, the endpoint handling, and the alpha
modulation for width < 1. Note also what tiny-skia does with caps and joins
for hairlines (it draws each flattened segment independently; overlapping
pixels are blended by `max`/`add`? read `hairline_aa.rs`'s blitter use and
reproduce it).

## What to change

- `Raster.hairline (W H : Nat) (polys : Array (Array Pt)) (closed : Array Bool)
  (alpha256 : Nat) : Option Mask` (or similar): rasterize each polyline
  segment with the ported algorithm into one `Mask` covering the union
  bounding box, accumulating coverage the way tiny-skia's hairline blitter
  does across overlapping segments. Coverage in the existing `[0, 65536]`
  convention, scaled by the width factor.
- `Render.drawShape`: compute the device-space stroke width as tiny-skia does
  (`treat_as_hairline`: transform the width by the matrix's scale; read the
  exact test) and, when ≤ 1 px, skip `strokePoly` and use `hairline` on the
  flattened polylines mapped through `ctm`, with the paint alpha scaled for
  widths < 1. Otherwise unchanged.
- Invariants in `tasks/README.md`: all loops bounded by the segment's
  major-axis length in pixels (≤ canvas size after clipping) and the number
  of segments; no `Float`.

## Measure

Not byte-identical by design. `python3 tests/run_tests.py` before/after:
`within%` must not decrease on any file and should rise on 17_koch and
16_stress; report per-file numbers. Add `tests/svg/21_hairlines.svg` (thin
lines at many angles, widths 0.25/0.5/1.0, a thin polyline with joins, a
thin circle) and report its numbers. Tiles 20/20, adversarial clean,
`Effect.lean` untouched.

## Done when

Koch and stress improve, nothing regresses, `21_hairlines` ≥ 99% within 8 or
a precise account of what differs. Report appended. Commit on the branch.
