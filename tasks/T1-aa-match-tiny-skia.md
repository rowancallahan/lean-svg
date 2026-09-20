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
