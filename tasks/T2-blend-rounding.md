# T2 — Match tiny-skia's blend arithmetic for solid fills

## Goal

`07_opacity` is 62.6% exact / 99.8% within 8, and every file with translucent
fills shows a uniform 1–3 level offset in flat areas. That is rounding in
`LeanSvg/Canvas.lean` (`div255`, premultiply, source-over, unpremultiply on
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

`LeanSvg/Canvas.lean` only: `div255`, `blend`, `new` (background
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

## Report

### What resvg actually runs for a solid fill

resvg 0.48.1 / tiny-skia (clone reused at
`/private/tmp/claude-501/-Users-rowancallahan-website/73d6fcc2-0699-487e-b5c3-96bdc24e9f1d/scratchpad/tiny-skia`,
plus a shallow `resvg` clone next to it for `crates/resvg/src/path.rs`).

`crates/resvg/src/path.rs::fill_path` builds the paint with
`paint.set_color_rgba8(c.red, c.green, c.blue, fill.opacity().to_u8())` — the
paint colour's own alpha and the fill/stroke opacity are collapsed by usvg
(`parser/style.rs`: `opacity: sub_opacity * fill_opacity`) into **one u8**
*before* anything is premultiplied. `push_uniform_color` then premultiplies in
f32 and quantises to `[0,255]` u16 lanes. So the source is premultiplied
**once, up front**, and the rasteriser's coverage is applied to the already
premultiplied colour — the opposite order from what `Canvas.fillMask` was doing.

`pipeline/blitter.rs::RasterPipelineBlitter::new` picks one of two anti-aliased
pipelines, and this turned out to matter as much as the rounding:

* **shader opaque** (alpha == 255) **and no clip mask** → `SourceOver` is
  strength-reduced to `Source` (line 59). `Source` is not in
  `BlendMode::should_pre_scale_coverage`, so `blit_anti_h_rp` becomes
  `[UniformColor, LoadDestination, Lerp1Float, Store]` — a **lerp**, i.e. a
  *single* `div255` over `d*inv(cov) + s*cov`.
* **shader translucent** → `should_pre_scale_coverage(SourceOver)` is true, so
  `[UniformColor, Scale1Float, LoadDestination, SourceOver, Store]` — scale the
  source by coverage, then `s + div255(d * inv(sa))`, two separate `div255`s.

Fully-covered runs go through `blit_h`/`SourceOverRgba` instead, but since
`div255(x * 255) = x` exactly for `x ≤ 255`, applying the coverage stage
unconditionally is bit-identical, so only one code path is needed.

`Pixmap::encode_png` → `take_demultiplied` → `PremultipliedColorU8::demultiply`.

### Exact integer formulas

```
div255(v)        = (v + 255) >>> 8              -- pipeline/lowp.rs::div255
                                                -- NOT round(v/255); Skia's cheap form
premul(c, a)     = (c * a + 127) / 255          -- = round(c*a/255)
unpremul(c, a)   = min 255 ((c * 510 + a) / (2*a))   -- = round(c*255/a), a > 0
cov8             = (cov * 255 + 32768) >>> 16   -- our 0..65536 mask -> tiny-skia's 0..255
a8               = min 255 ((c.a * opacity256 + 128) >>> 8)   -- our 0..256 -> resvg's 0..255
sr,sg,sb         = premul c.{r,g,b} a8          -- premultiplied ONCE, before coverage

a8 == 255  (lerp_1_float, Source):
  n_ch = div255 (d_ch * (255 - cov8) + s_ch * cov8)      -- alpha uses s = 255

a8 <  255  (scale_1_float + source_over):
  s'_ch = div255 (s_ch * cov8)      sa' = div255 (a8 * cov8)
  n_ch  = s'_ch + div255 (d_ch * (255 - sa'))
```

`premul` was verified exhaustively against the f32 path
(`f32(c/255) * f32(a/255) * 255 + 0.5` truncated) over all 256×256 pairs: 0
mismatches. `unpremul` matches `demultiply`'s f64 form everywhere except 38 of
the 615 exact half-way `(c,a)` pairs, where the f64 quotient lands a hair below
the tie and truncates down; that is 0.12 % of the value space and is documented
in the source.

Empirically confirmed against resvg before coding, on a probe with an opaque
and a `fill-opacity="0.5"` rect placed at `x=10.5` so the edge column has
coverage 128: every sampled pixel — opaque interior, opaque AA edge,
translucent interior, translucent AA edge — is now bit-identical.

### Files changed

* `LeanSvg/Canvas.lean` — only file changed. `div255` redefined to tiny-skia's
  `(v+255)>>>8`; new `premul` / `unpremul`; `blend` split into `blendLerp`
  (opaque) and `blendOver` (translucent); `fillMask` now quantises the opacity
  to `a8` and premultiplies the paint once outside the loop, then scales by a
  0..255 coverage; `new` uses `premul`; `toRgbaBytes` uses `unpremul`.
* `LeanSvg/Render.lean` — **not changed**. The order-of-operations fix
  (quantise opacity to u8 → premultiply → then apply coverage) lives entirely
  inside `fillMask`; `drawShape` still just hands over
  `fillOpacity * opacity / 256`, so no edit there was needed.

Invariants hold: no `partial`/`unsafe`/`@[extern]`/`panic!`/`!`-indexing, no
`Float`, all arithmetic in `Nat`, every loop a `for` over a finite range.
`lake build` clean, no new warnings.

### Numbers

`python3 tests/run_tests.py`, `exact%` (tol 8, threshold 0.99):

| file | before | after |
|---|---|---|
| 07_opacity | 62.642 | **96.490** |
| 12_badge | 86.306 | 86.456 |
| 14_flower_transforms | 75.935 | **92.659** |
| 15_spiral_stroke | 51.254 | **90.432** |
| 16_stress_2000 | 24.568 | **52.778** |

Whole corpus, `exact%` before → after: 01 99.000→100.000, 02 98.578→98.610,
03 98.360→98.382, 04 96.770→96.793, 05 98.043→98.093, 06 97.905→97.945,
07 62.642→96.490, 08 96.520→98.677, 09 99.027→99.470, 10 92.407→92.715,
11 97.545→98.775, 12 86.306→86.456, 13 95.695→96.025, 14 75.935→92.659,
15 51.254→90.432, 16 24.568→52.778, 17 84.869→94.120, 18 80.414→80.231,
19 88.470→90.227, 20 86.878→93.773. Pass/fail is unchanged at 10/20 because
the threshold is on `within%` (AA-dominated, T1's task), not `exact%`.

`python3 tests/run_adversarial.py`: **37/37 cases clean, 0 violations**. (The
task text says 28/28; the generated suite is now 37 cases. It was clean before
and after.) Runtimes are within noise of the baseline
(16_stress_2000 216 ms → 229 ms, 15_spiral_stroke 67 ms → 70 ms).

### What still differs, and why

**07_opacity, the remaining 3.5 %.** Every flat interior is now bit-exact:
`rect1` interior, `rect2` over `rect1`, `rect2` over transparent, the black
rect and the translucent stroke band all have max channel diff 0. The 1404
differing pixels are AA edges plus one flat region: the 816 pixels where the
`opacity="0.4"` circle overlaps the `fill-opacity="0.5"` rect, which read
`(54,142,150,179)` in resvg and `(54,144,150,179)` here.

That is **not** rounding — it is `opacity` (group opacity) vs `fill-opacity`.
usvg turns any element with `opacity != 1` into a real group
(`parser/converter.rs`: `required = opacity.approx_ne_ulps(&1.0, 4) || ...`),
and `crates/resvg/src/render.rs` renders it into a sub-pixmap and composites it
with `draw_pixmap(..., PixmapPaint { opacity })`. That goes through a `Pattern`
shader, which has no lowp stage, so the **whole layer composite runs in f32**:
`n = round(op*s + d*(1 - op))`. For this pixel f32 gives `0.4*157 + 62*0.6 =
100.0` where our folded lowp path gives 101, and demultiplying by 179 turns
that into 142 vs 144. Folding a group opacity into the paint alpha is only
exact where the group sits on transparent pixels (which is why the rest of the
circle is bit-exact). Matching it properly needs layer rendering, which is out
of scope here. Verified on a dedicated probe: `fill-opacity="0.85"` is exact,
`opacity="0.85"` on the same colour over the same background is off by one.

**12_badge and 18_rose_lissajous: `parseOpacity`'s 1/256 grid.**
`Svg.lean::parseOpacity` (out of scope for this task) quantises the opacity to
`round(op * 256)`, and resvg quantises to `round(f32(op) * 255)`. Converting
between the two grids is lossy, and for three of the twelve opacity values in
the corpus the recovered `a8` is one off: `0.7` (we get 178, resvg 179 — the
true product 178.5 is an exact tie that f32 breaks upward), `0.9` (229 vs 230,
also a tie), `0.35` (90 vs 89). No rounding rule on the 1/256 value can fix all
three; the information is gone before `Canvas` sees it. Measured cost, by
re-rendering the same files with the opacity nudged off the tie so both
renderers agree on `a8`:

* `12_badge` 86.456 → 89.636 (+3.18 pp) from `0.7` alone; dropping the
  `opacity="0.85"` layer as well gives 93.613 (+3.98 pp more, the group-opacity
  issue above). The last ~6.4 pp is AA coverage.
* `18_rose_lissajous` 80.231 → 86.231 (+6.00 pp) from `0.35` and `0.9`. This is
  the only file that got slightly *worse* (80.414 → 80.231) and that is the
  whole reason.

A follow-up in `Svg.lean` should keep the opacity at higher precision (or carry
the parsed value and quantise to 255ths once, at the same point resvg does).

**Everything else** is anti-aliasing coverage, i.e. T1's task: `within%` barely
moved (e.g. 15_spiral_stroke 95.720 → 95.712) while `exact%` nearly doubled,
which is the signature of the blend being right and the edge coverage still
being ours rather than tiny-skia's supersampler.
