# T5 — Quantise opacity the way resvg does

## Goal

T2 made the blend bit-identical, but `Svg.parseOpacity` stores opacity on a
1/256 grid (`0..256`) and resvg stores `round(f32(value) * 255)` as a `u8`.
Converting between the grids is lossy: for `0.7`, `0.9`, `0.35` the recovered
alpha is one level off, which costs `12_badge` about 3 percentage points of
exact match and `18_rose_lissajous` about 6. Fix the representation so the
alpha we hand to `Canvas.fillMask` is exactly resvg's `u8`.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T5` (branch `t5-opacity`).

## What to change

`MicroSvg/Svg.lean` (and the one line in `MicroSvg/Render.lean` /
`MicroSvg/Canvas.lean` that consumes the value, if the scale changes):

- Parse opacity to a value with enough precision that rounding to 255ths is
  exact for any decimal input with up to 18 significant digits. Suggested:
  keep the parsed `Fx`-style integer but with 16 fractional bits
  (`parseNumber` gives 8; add a variant or multiply the mantissa path), or
  carry `(numerator, denominator)` as `Nat` and quantise once.
- Combine `fill-opacity` (or `stroke-opacity`) with inherited group `opacity`
  the way usvg does (`opacity = sub_opacity * fill_opacity` in f32, then
  `.to_u8()` = `round(x * 255)`), and only then quantise. Document in the
  report how ties are broken and check against resvg on the three known
  values (`0.7 → 179`, `0.9 → 230`, `0.35 → 89`) plus `0.5`, `0.25`, `0.125`,
  `0.8`, `0.85`, `0.15`, `0.6`, `0.4`, `0.55` by rendering a flat rect with
  each and reading the pixel.
- `Style` fields become `fillOpacity stroke Opacity opacity : Nat` in whatever
  scale you choose; `Canvas.fillMask` must receive a final `a8 ∈ [0,255]`
  (adjust its signature from `opacity256` if that is cleanest, keeping the
  arithmetic otherwise identical to T2's).
- Everything must satisfy `tasks/README.md`.

## Measure

Before/after `python3 tests/run_tests.py`: `exact%` for `07`, `12`, `14`,
`15`, `16`, `18`. Adversarial must stay clean.

## Done when

All twelve probe values match resvg's pixel exactly and `12_badge` /
`18_rose_lissajous` exact% improve. Append `## Report`. Do not commit.
