# T2 — Match tiny-skia's blend arithmetic for solid fills

## Goal

`07_opacity` is 62.6% exact / 99.8% within 8, and every file with translucent
fills shows a uniform 1–3 level offset in flat areas. That is rounding in
`MicroSvg/Canvas.lean` (`div255`, premultiply, source-over, unpremultiply on
export), not geometry. Make ours bit-identical to tiny-skia's lowp pipeline
for the case "solid colour × coverage mask, source-over".

## Reference source

```bash
git clone --depth 1 https://github.com/linebender/tiny-skia /private/tmp/claude-501/-Users-rowancallahan-website/73d6fcc2-0699-487e-b5c3-96bdc24e9f1d/scratchpad/tiny-skia
```

(If T1's clone already exists at that path, reuse it.) Read:
- `src/pipeline/lowp.rs`: `div255`, `uniform_color`, `scale_u8` / `lerp_u8`
  (coverage application), `source_over`, `load`/`store` of `PremultipliedColorU8`.
- `src/pipeline/mod.rs` or `src/painter.rs`: which stages a solid-colour
  anti-aliased fill runs through, and whether resvg's fill uses lowp or highp
  for a plain solid colour with alpha (`is_lowp` conditions).
- `src/color.rs`: `Color::premultiply` to `PremultipliedColorU8` (how f32 → u8
  rounds), and `PremultipliedColorU8::demultiply` (exact formula).
- resvg's PNG export: `crates/resvg/src/main.rs` or `render.rs` — it calls
  `Pixmap::encode_png` which demultiplies; confirm the formula used.

Write the exact integer formulas in the report before coding.

## What to change

`MicroSvg/Canvas.lean` only: `div255`, `blend`, `new` (background
premultiply), `toRgbaBytes` (demultiply). The mask value `cov ∈ [0, 65536]`
must first be reduced to the 0..255 coverage tiny-skia would have (`cov / 257`
or as coordinated with T1's report if it has landed; if unsure, use
`(cov * 255 + 32768) / 65536`). Then apply the paint's alpha and the group /
fill opacity in the same order tiny-skia does (opacity is folded into the
paint colour's alpha *before* premultiplication in resvg; check
`crates/resvg/src/path.rs`).

Everything must satisfy `tasks/README.md`.

## Measure

Before and after: `python3 tests/run_tests.py --filter 07`, then the full
run. Report the `exact%` column for `07_opacity`, `12_badge`,
`14_flower_transforms`, `15_spiral_stroke`, `16_stress_2000`. Adversarial
must stay 28/28.

## Done when

`07_opacity` exact ≥ 95% (interior translucent pixels identical), or a precise
explanation of the remaining difference. Append your `## Report`.
