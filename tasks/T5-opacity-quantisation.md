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

`LeanSvg/Svg.lean` (and the one line in `LeanSvg/Render.lean` /
`LeanSvg/Canvas.lean` that consumes the value, if the scale changes):

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

## Report

### Representation

Opacities are now `Nat` numerators over **10^18** (`Svg.opacityOne`); the paint
alpha handed to `Canvas.fillMask` is a plain `u8`.

A power-of-ten denominator is the point. resvg keeps opacity as `f32` and
quantises once at the end with `Opacity::to_u8` = `round(x * 255)`. Our old
1/256 grid had to round twice onto grids that do not nest: `0.7` becomes
179/256, and `round(179/256 * 255) = 178` where resvg says 179. A 16-bit
binary grid does not fix it either — `round(0.7 * 65536) = 45875` and
`round(45875 * 255 / 65536) = 178` — because the half-way points of the 255ths
grid are the odd multiples of 1/510, which no binary grid represents.

There are only five of those half-way points in `[0, 1]`: a tie needs
`510 | (2j+1) * 10^k`, i.e. `51 | 2j+1`, and `51 * 11 / 510 > 1`, so the ties
are exactly **0.1, 0.3, 0.5, 0.7, 0.9** — all one-digit decimals. A decimal
denominator therefore represents every tie *exactly*, and the tie is then
decided by our own rule instead of by accumulated rounding noise. 10^18 is
also the widest mantissa `parseDecimal` can return, so every decimal literal
the lexer accepts is exact in its own right, as the task asked.

**Ties round up** (half away from zero), as `(2*n*255 / D + 1) / 2` in `Nat`.
That is provably right rather than tuned: the five tie values are the only
ones that can occur, and resvg renders all five up (`0.1→26`, `0.3→77`,
`0.5→128`, `0.7→179`, `0.9→230`, all probed). `f32` gets there slightly
differently — `f32(0.7) = 0.69999998...` is *below* 0.7, but `f32(0.7) * 255`
rounds back to exactly `178.5`, which `round()` then takes to 179 — so the
exact-decimal rule and the `f32` rule agree on everything the corpus contains.
They could only diverge past ~8 significant digits, where `f32` cannot tell
the input from a tie; the task's criterion (exactness for the decimal) is what
is implemented.

The whole chain is collapsed and quantised **once**, in
`Svg.opacityToU8 alpha fillOp groupOp`:

```
a8 = round(alpha/255 * fillOp * groupOp * 255) = round(alpha * fillOp * groupOp)
```

which is what usvg builds: `convert_paint` folds the colour's own alpha into
`sub_opacity` via `Color::split_alpha` (`a / 255`), `resolve_fill` returns
`sub_opacity * fill_opacity`, and `crates/resvg/src/path.rs` calls
`set_color_rgba8(r, g, b, fill.opacity().to_u8())`. Nested `opacity`
attributes still multiply as they did, now on the 10^18 grid (`mulOpacity`);
that is the only place a product is rounded early, and a product of two short
decimals is exact there anyway.

`rgba()`'s alpha needed the same treatment (`alphaOf`): svgtypes stores it as
`round(a * 255)` and usvg immediately unpacks it as an opacity again, so
`rgba(48,128,192,0.7)` must give 179, not the 178 the 1/256 grid produced.

### Twelve probes

Flat 100×100 rect, `fill="#3080c0"`, one `fill-opacity` each, alpha read at
(50, 50). `exact` is the exact rational `v * 255`.

| value | exact | resvg | ours before | ours after |
|---|---|---|---|---|
| 0.7 | 178.5 | 179 | 178 | **179** |
| 0.9 | 229.5 | 230 | 229 | **230** |
| 0.35 | 89.25 | 89 | 90 | **89** |
| 0.5 | 127.5 | 128 | 128 | 128 |
| 0.25 | 63.75 | 64 | 64 | 64 |
| 0.125 | 31.875 | 32 | 32 | 32 |
| 0.8 | 204 | 204 | 204 | 204 |
| 0.85 | 216.75 | 217 | 217 | 217 |
| 0.15 | 38.25 | 38 | 38 | 38 |
| 0.6 | 153 | 153 | 153 | 153 |
| 0.4 | 102 | 102 | 102 | 102 |
| 0.55 | 140.25 | 140 | 140 | 140 |

12/12. A wider sweep of **257** cases against resvg — all 101 hundredths, 120
random thousandths, `.5`/`7e-1`/`70e-2`/`50%`/`12.5%`/`0.123456789012345678`,
`rgba()` and `#rrggbbaa` alphas alone and crossed with `fill-opacity`, and
nested groups — gives **253 exact**. The four misses are all group opacity
(below), not quantisation.

### Files changed

* `LeanSvg/Fixed.lean` — `parseNumber` split into `parseDecimal` (lexes to the
  exact `±mant * 10^exp10`, loop bodies unchanged) and `scaleDecimal` (lands a
  decimal on any grid, halves away from zero, saturating). `parseNumber` is
  `scaleDecimal ... 256 Fx.maxVal`, bit-identical to before — every corpus file
  without opacity renders byte-identically, and the old and new binaries agree
  on `1e999999999`, `1e60`, `1e-60`, `-`, `abc` and friends.
* `LeanSvg/Svg.lean` — `opacityOne`, `Style.{fillOpacity,strokeOpacity,opacity}`
  on the 10^18 grid, `parseOpacity` / `alphaOf` off `parseDecimal`,
  `mulOpacity`, `opacityToU8`.
* `LeanSvg/Render.lean` — two call sites pass `opacityToU8 c.a ...`.
* `LeanSvg/Canvas.lean` — `fillMask`'s `opacity256` becomes `alpha8 : Nat` in
  `[0,255]`; the blend arithmetic from T2 is untouched.

Invariants hold: no `partial` / `unsafe` / `@[extern]` / `panic!` / `!`-indexing,
no `Float`, no new loops, `lake build` clean with no new warnings. Runtime is
unchanged (best of 7, old → new: 12_badge 63.8 → 63.0 ms, 16_stress_2000
222.1 → 219.3 ms, 18_rose_lissajous 98.7 → 97.8 ms) — the 10^18 products are a
handful of bignum ops per shape, invisible next to rasterising.

### Numbers

`python3 tests/run_tests.py`, `exact%`, before = T2's merged state:

| file | before | after |
|---|---|---|
| 07_opacity | 96.490 | 96.490 |
| 12_badge | 86.456 | **89.636** |
| 14_flower_transforms | 92.659 | 92.659 |
| 15_spiral_stroke | 90.432 | 90.432 |
| 16_stress_2000 | 52.778 | 52.778 |
| 18_rose_lissajous | 80.231 | **86.231** |

The other fourteen files are unchanged to three decimals — they have no
opacity below 1 — and pass/fail stays 10/20 (the threshold is on `within%`,
which is AA-bound). The two gains land exactly on T2's predictions (+3.18 and
+6.00 pp), so the `0.7`, `0.9` and `0.35` levels were the whole of that gap.
`within%` moves a hair the other way on those two (12: 97.532 → 97.526,
18: 91.058 → 90.976) while `mean_abs` improves (0.294 → 0.286, 1.984 → 1.963):
some pixels that were off by one in the friendly direction are now off by one
the other way at AA edges, which is T1's territory.

`python3 tests/run_adversarial.py`: **37/37 cases clean, 0 violations**
(unchanged; the suite is 37 cases now, not the 28 the older task text names).
Hand-fuzzing the new parse path — `1e999999999`, `-1e999999999`, `1e±60`,
400-digit mantissas, `0.123456789012345678901234567890`, `50.5%`, `-`, `.`,
`e5`, `%`, `abc`, empty — is bounded and matches the old binary everywhere.
Three of those disagree with resvg (`-1e999999999`, `1e60`, `0.5%%`), but the
old binary disagrees identically: they are *validation* differences, where
svgtypes rejects the attribute and falls back to 1.0 while we tolerate the
junk. Out of scope here.

### What still differs: group opacity is a layer, not a factor

The four sweep misses are all `<g opacity="G">` over a `fill-opacity="F"`
child. usvg turns `opacity != 1` into a real group and resvg renders it into a
sub-pixmap, so it quantises **twice**: the paint alpha becomes
`p8 = round(F * 255)`, and the layer composite then applies `G` to that `u8`.
We fold instead, as the task directs, and quantise once.

Measured on a 90-point `(G, F)` grid over a transparent background:

| model | matches |
|---|---|
| fold, one product (implemented) | 76/90 |
| two-step, `round_half_up(round(F*255) * G)` | 85/90 |
| two-step, `round_half_even(round(F*255) * G)` | 89/90 |

So the second quantisation is real, and it is close to ties-to-even but not
exactly — `G=0.75, F=0.9` gives 173 where ties-to-even says 172, because the
layer composite is genuine `f32` on `230/255`, which is not exactly `230/255`.
Reproducing it needs the `f32` layer pipeline, i.e. actual layer rendering,
which T2 already ruled out of scope; and it would only fix the alpha, since a
folded group over a non-transparent background gets the colour channels wrong
regardless (T2's `07_opacity` circle-over-rect case). `DESIGN.md` already lists
this as a known deviation. A follow-up that renders isolated groups into a
sub-canvas would close it; nothing in the opacity *representation* stands in
the way any more.
