# T70 — feTile, feDisplacementMap, gamma, filter tail  (branch `claude/feat-filter-tail`)

The filter foundation (T51, read `tasks/T51-filters.md` and `DESIGN.md`
§3.11 first) has landed. Adding a primitive is: a `Kind` constructor, a clause
in `Filter.convertPrim`, a case in `FilterApply.runPrim`, and removing its name
from `Filter.isKnownUnsupported`. **Other agents are adding other primitives
concurrently**, so: put all of your primitive's code in a new file
`LeanSvg/Filter/<Name>.lean` (imported where needed), and keep your edits to
`Filter.lean`/`FilterApply.lean` to those few one-line-ish additions. Match
resvg 0.48.1's `crates/resvg/src/filter/*.rs` exactly where pixels depend on
it (its f32 maths must be reproduced in fixed point/integers to within the
8-level tolerance; exact is better — T51's report shows how it matched
colour-space LUTs and f32 sin/cos). Respect T51's work budgets: every
per-pixel loop is bounded by the layer area times a constant or a bounded
kernel size; cap kernel sizes/octaves/etc. as resvg does, and add an
adversarial case for the expensive parameter.

Target: the filter long tail: `filters/feTile` (7), `feDisplacementMap` (1),
`feComponentTransfer` (3 left: probably the `gamma` function, which T51
skipped — needs a fixed-point pow), and `filters/filter` (6 left; T51's
report lists why: filters on `<text>` need the text layout bbox, mask
interplay, etc. — fix what is within reach now that masks and text have
landed). resvg `filter/mod.rs` for tile and displacement map.

## What was implemented

Files: `LeanSvg/Filter/Tile.lean` (`feTile`), `LeanSvg/Filter/DisplacementMap.lean`
(`feDisplacementMap`), `LeanSvg/Filter/Gamma.lean` (`gamma`'s fixed-point `powf`),
with the one-line-ish `Kind`/`TF` constructors, `convertPrim`/`transferOf`
clauses and `runPrim`/`tfTable` cases in `Filter.lean`/`FilterApply.lean`
the docstring above describes, plus a backward-compatible optional-parameter
extension to `runPrim` (`ox oy : Int := 0`, defaulted so every other call
site and every other wave-2 agent's own new `runPrim` arm is unaffected) so
`.tile` can turn an input's absolute recorded region into region-local pixel
coordinates without needing the filter region's own origin threaded through
another way.

* **`feTile`** (resvg `filter/mod.rs::apply_tile`). Crops the referenced
  input to its own recorded region (the *declared* sub-region of whichever
  primitive produced it — `feOffset` carries its input's region forward
  unchanged, per the existing `isOffset` handling in `FilterApply.run`) and
  repeats it periodically across the whole filter-region canvas. resvg
  samples this with a `tiny_skia::Pattern` in `Repeat` spread mode and
  `Bicubic` filtering, which is *not* an interpolating kernel in general —
  but every coordinate a filter primitive ever sees here is a whole device
  pixel (`devRect` floors/ceils), and checking against resvg 0.48.1 on
  `feTile/simple-case` (sharp internal transparent/opaque structure) and
  `feTile/complex-transform` (the same, under a skew+rotate) shows only
  `{0, 255}` alpha values — no resampling blur — so the exact-alignment case
  reduces to plain periodic pixel indexing, which is what is implemented.
  The crop itself is an *intersection* with the canvas, not a containment
  requirement (`tiny_skia::Pixmap::clone_rect` intersects; only a wholly
  disjoint crop is `Error::InvalidRegion`), which matters even when the
  declared sub-region is a geometric subset of the filter region in user
  space: each is rounded to whole device pixels independently
  (`to_int_rect`), so a skewed/rotated transform's rounding can make the
  sub-region's `IntRect` poke a pixel outside the region's own `IntRect`
  even though the real-valued rectangles nest — `feTile/complex-transform`'s
  own title flags this as "(UB)" for exactly this reason.
* **`feDisplacementMap`** (resvg `filter/displacement_map.rs`). Each output
  pixel copies `in` from an offset read off `in2`'s (colour-space-converted,
  *still premultiplied* — resvg's own doc comment on `displacement_map::apply`
  asks for unpremultiplied, but its caller never demultiplies, so this
  matches the caller, not the comment) channel bytes at that pixel:
  `offset = (channel/255 − 0.5) · deviceScale · scale`, rounded to the
  nearest pixel (`f32::round`, ties away from zero). The `scale` resvg
  actually applies is **`fe.scale()` squared**, not `fe.scale()` once:
  `apply_displacement_map` turns the attribute into a device-scaled
  `sx' = fe.scale() · deviceScale` via `scale_coordinates`, and then
  `displacement_map::apply` multiplies by `fe.scale()` *again*
  (`dx * sx * fe.scale()`) — an apparent double-count bug in resvg 0.48.1,
  reproduced here since matching resvg's actual pixels is the point (found
  by comparing an own-authored displacement test against real `resvg`
  output: the observed offset grew quadratically, not linearly, with the
  `scale` attribute).
* **`gamma`** (resvg `component_transfer.rs`'s `TransferFunction::Gamma`,
  `amplitude · c.powf(exponent) + offset`). `Filter.Gamma.powF32` is exact
  for the case that matters in practice — an exponent that is a small
  integer, computed by repeated `F32.mul` or its reciprocal (this covers
  every corpus use: all four `gamma` files in `resvg-test-suite` use
  `exponent="1"`) — and falls back to `exp(exponent · ln(base))` in a
  `2^128`-scaled fixed point (same style as `Filter.sinCosF32`: an exact
  atanh series for `ln`, a plain Taylor sum for the `exp` remainder after
  range-reducing by `ln 2`) for a general real exponent, which has no test
  coverage in the resvg suite and is a best-effort match rather than a
  verified one.
* **`filters/filter`'s remaining 6**: re-verified individually rather than
  assumed fixable. `in=FillPaint-with-pattern.svg` and
  `in=FillPaint-with-target-on-g.svg` need patterns (T53, not landed on this
  branch). `on-group-with-child-outside-of-canvas.svg` and
  `with-transform-outside-of-canvas.svg` use `feImage` (T67, not landed on
  this branch). `with-multiple-transforms-1.svg` is T51's documented f32
  rounding quirk (resvg's f32 scale of a rotated CTM lands at 0.49999997
  where the 16.16 matrix gives exactly 0.5, picking IIR vs box blur) —
  unfixable without emulating that specific f32 rounding, and already
  documented as a T51 skip. `in=StrokePaint.svg`: not actually about
  `StrokePaint` (usvg maps it to `SourceGraphic`, already correct) — a
  plain stroked circle with *no* filter at all already differs from resvg
  by up to 27 of 10 000 pixels at `--width 100` (verified with a
  filter-free reduction of the same SVG), i.e. pre-existing stroke
  antialiasing/geometry imprecision that a `feGaussianBlur` spreads
  visibly; out of scope for a filter-primitives task. None of the 6 needed
  masks or `<text>` (T51's own report's stated reasons for the original
  74→65 gap); those were fixed by other, already-merged work.

## Skipped, and why

* **`powF32`'s non-integer-exponent fallback** is unverified against resvg:
  no file in `resvg-test-suite`, `simple-icons` or `feather` uses a `gamma`
  with a non-integer `exponent`, so there is nothing to check it against.
  The integer fast path (the one real-world case) is exact.
* **The other 5 of `filters/filter`'s remaining 6** need patterns (T53),
  `feImage` (T67), or are pre-existing/documented imprecision unrelated to
  filters (see above); only re-verification was in scope here, not
  implementing those other tasks' primitives.

## Report

Baseline commit `1ba4c27`. `run_corpora.py --fast --corpus resvg --route direct`
(width 100), before → after:

| dir | files | pass before | pass after |
|---|---|---|---|
| filters/feTile | 7 | 0 | 7 |
| filters/feDisplacementMap | 1 | 1 | 1 |
| filters/feComponentTransfer | 22 | 19 | 22 |
| filters/filter | 74 | 68 | 68 (unchanged; see above) |

Whole suite (`resvg`, `direct`, width 100): **1224 → 1234 of 1679; newly
passing 10, newly failing 0.**

Other checks, all on the final commit:

* `lake build`: no errors, no new warnings.
* `scripts/check-theorems.sh`: `theorems ok`.
* `tests/run_tests.py`: every pre-existing file's score unchanged (same 4
  pre-existing failures, unrelated to filters); new `50_filter_tail`
  100.000% exact (feTile + feDisplacementMap + two gamma directions).
* `tests/run_adversarial.py`: 84/84 clean. New input:
  `filter_tile_displacement_gamma.svg` (a 1e9-sized declared feTile
  sub-region that must clip to the canvas rather than blow up, a `scale=1e30`
  `feDisplacementMap`, and a `gamma` with `exponent=1e9`/`amplitude=1e30`),
  37 ms.
* `tests/run_tiles.py`: 36/36 byte-identical, including the new
  `50_filter_tail` and its off-document/partial-tile transparency checks
  (which an early version of the test file failed — a mis-aligned `feFlood`
  sub-region touching the document edge, fixed by moving it, not a renderer
  bug).
* Timing: the new adversarial file 37 ms; `50_filter_tail` typical local
  render ~80 ms at natural size.

No known regressions. The `runPrim`/`convertPrim` edits are additive
(`ox oy` are optional/defaulted); nothing existing was renamed or
restructured.
