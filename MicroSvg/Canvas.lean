import MicroSvg.Raster

/-!
# Canvas

Premultiplied RGBA, 8 bits per channel, one packed `Nat` per pixel
(`r<<24 | g<<16 | b<<8 | a`).  Source-over compositing only.

The integer arithmetic below is a port of tiny-skia's `lowp` raster pipeline,
which is the pipeline resvg uses for a solid-colour anti-aliased fill or
stroke.  See `tasks/T2-blend-rounding.md` for where each formula comes from.
-/

namespace MicroSvg

structure Rgba where
  r : Nat
  g : Nat
  b : Nat
  a : Nat
deriving Repr, Inhabited, BEq

structure Canvas where
  w : Nat
  h : Nat
  px : Array Nat
deriving Inhabited

namespace Canvas

/-- tiny-skia `pipeline::lowp::div255`: `(v + 255) >> 8`.

This is deliberately *not* `round (v / 255)`.  Skia's lowp pipeline uses this
cheaper approximation and every blend stage (`scale_1_float`, `lerp_1_float`,
`source_over`) is built out of it, so the blend has to use it too to stay
bit-identical.  Note `div255 (x * 255) = x` for `x ≤ 255`, which is why a
coverage of 255 behaves exactly like the no-coverage fast path. -/
@[inline] def div255 (x : Nat) : Nat := (x + 255) >>> 8

/-- Premultiply one channel: `round (c * a / 255)`.

resvg premultiplies the paint colour in `f32` (`Color::premultiply`) and then
quantises with `(x * 255.0 + 0.5) as u16` in `RasterPipelineBuilder::
push_uniform_color`.  `(c * a + 127) / 255` agrees with that for all 256×256
pairs (checked exhaustively), and also matches `color::premultiply_u8`, which
is what `Pixmap::fill` uses for the background. -/
@[inline] def premul (c a : Nat) : Nat := (c * a + 127) / 255

/-- Unpremultiply one channel: `round (c * 255 / a)`.

`PremultipliedColorU8::demultiply` computes `(c as f64 / (a as f64 / 255.0)
+ 0.5) as u8`, which is round-half-up of `c * 255 / a` except at 38 of the
615 exact half-way `(c, a)` pairs, where the `f64` division lands just below
the tie and rounds down instead. -/
@[inline] def unpremul (c a : Nat) : Nat :=
  if a == 0 then 0 else Nat.min 255 ((c * 510 + a) / (2 * a))

@[inline] def pack (r g b a : Nat) : Nat := (r <<< 24) ||| (g <<< 16) ||| (b <<< 8) ||| a

def new (w h : Nat) (bg : Option Rgba) : Canvas :=
  let v := match bg with
    | none => 0
    | some c => pack (premul c.r c.a) (premul c.g c.a) (premul c.b c.a) c.a
  ⟨w, h, Array.replicate (w * h) v⟩

/-- Opaque paint, fractional coverage: tiny-skia `lowp::lerp_1_float`.

`RasterPipelineBlitter::new` strength-reduces `SourceOver` to `Source` when the
shader is opaque and there is no clip mask.  `Source` is not in
`BlendMode::should_pre_scale_coverage`, so the anti-aliased blitter *lerps*
between destination and source by the coverage — one `div255` over the sum —
instead of scaling the source and compositing separately.  `sr sg sb` are the
(already premultiplied, here opaque) source channels. -/
@[inline] def blendLerp (dst sr sg sb cov : Nat) : Nat :=
  let inv := 255 - cov
  let dr := (dst >>> 24) &&& 255
  let dg := (dst >>> 16) &&& 255
  let db := (dst >>> 8) &&& 255
  let da := dst &&& 255
  pack (Nat.min 255 (div255 (dr * inv + sr * cov)))
       (Nat.min 255 (div255 (dg * inv + sg * cov)))
       (Nat.min 255 (div255 (db * inv + sb * cov)))
       (Nat.min 255 (div255 (da * inv + 255 * cov)))

/-- Translucent paint: tiny-skia `lowp::source_over` on a source that
`lowp::scale_1_float` has already multiplied by the coverage.  `sr sg sb sa`
are the premultiplied, coverage-scaled source channels. -/
@[inline] def blendOver (dst sr sg sb sa : Nat) : Nat :=
  let inv := 255 - sa
  let dr := (dst >>> 24) &&& 255
  let dg := (dst >>> 16) &&& 255
  let db := (dst >>> 8) &&& 255
  let da := dst &&& 255
  pack (Nat.min 255 (sr + div255 (dr * inv)))
       (Nat.min 255 (sg + div255 (dg * inv)))
       (Nat.min 255 (sb + div255 (db * inv)))
       (Nat.min 255 (sa + div255 (da * inv)))

/-! ### Coverage thresholds

`fillMask` reduces the mask's `cov ∈ [0, 65536]` to tiny-skia's 0..255 coverage
with `cov8 = (cov · 255 + 32768) >>> 16`.  Two values of `cov8` make the blend
degenerate, and both are worth branching on before doing any arithmetic:

* `cov8 = 0` — nothing is written.  `cov · 255 + 32768 < 65536 ↔ cov · 255 <
  32768 ↔ cov ≤ ⌊32767/255⌋ = 128`.
* `cov8 = 255` — full coverage.  `cov · 255 + 32768 ≥ 255 · 65536 ↔ cov ≥
  ⌈16678912/255⌉ = 65408`; the upper end cannot overflow because `cov ≤ 65536`
  gives `cov8 ≤ 255`.

Both equivalences were checked over all 65537 values of `cov`.  Testing `cov`
against these constants is exactly `cov8 == 0` / `cov8 == 255`, so the fast
paths below are entered on precisely the pixels whose general-path result they
reproduce, and `cov8` itself is only computed on the remaining pixels. -/

/-- Largest `cov` whose `cov8` is `0`. -/
@[inline] def covNone : Nat := 128

/-- Smallest `cov` whose `cov8` is `255`. -/
@[inline] def covFull : Nat := 65408

/-- Fill the mask with a solid colour.  `alpha8` is the final paint alpha in
`[0, 255]`: the colour's own alpha, the fill/stroke opacity and the inherited
group opacity already collapsed into one `u8` by `Svg.opacityToU8`, exactly as
resvg does with `set_color_rgba8(r, g, b, fill.opacity().to_u8())`.

The colour is premultiplied by it *before* the rasteriser's coverage is
applied, so `c.a` plays no part below — only `alpha8` does.

The mask is walked row by row.  Per row, the destination index of its first
pixel is computed once; per pixel, the coverage decides between three cases:

* `cov ≤ covNone`: skip, without reading or writing the canvas.
* `cov ≥ covFull`: full coverage.  For an opaque paint `blendLerp`'s `inv` is
  `0`, so the destination drops out and the result is the constant `solid`,
  written with no read and no arithmetic.  For a translucent paint the
  coverage-scaled source is the loop-invariant `fr fg fb fa`, so only the
  `source_over` step remains.
* otherwise: the general blend, unchanged.

`solid` and `fr fg fb fa` are *defined* as the corresponding general-path
expressions at `cov8 = 255`, so the fast paths cannot drift from it. -/
def fillMask (cv : Canvas) (m : Raster.Mask) (c : Rgba) (alpha8 : Nat) : Canvas := Id.run do
  let w := cv.w
  let h := cv.h
  let a8 := Nat.min 255 alpha8
  if a8 == 0 then return cv
  let sr := premul c.r a8
  let sg := premul c.g a8
  let sb := premul c.b a8
  let isOpaque := a8 == 255
  -- `cov8 = 255`, opaque: `inv = 0`, so this is independent of the destination.
  let solid := blendLerp 0 sr sg sb 255
  -- `cov8 = 255`, translucent: the `scale_1_float` stage is loop-invariant.
  let fr := div255 (sr * 255)
  let fg := div255 (sg * 255)
  let fb := div255 (sb * 255)
  let fa := div255 (a8 * 255)
  let mw := m.w
  let mut px := cv.px
  for y in [0:m.h] do
    let mrow := y * mw
    let prow := (m.y0 + y) * w + m.x0
    for x in [0:mw] do
      let cov := m.cov.getD (mrow + x) 0
      if cov ≤ covNone then continue
      let idx := prow + x
      if cov ≥ covFull then
        if isOpaque then
          px := px.setIfInBounds idx solid
        else
          px := px.setIfInBounds idx (blendOver (px.getD idx 0) fr fg fb fa)
      else
        -- tiny-skia's blitter works on 0..255 coverage; ours is 0..65536.
        let cov8 := (cov * 255 + 32768) >>> 16
        let dst := px.getD idx 0
        let nv :=
          if isOpaque then blendLerp dst sr sg sb cov8
          else blendOver dst (div255 (sr * cov8)) (div255 (sg * cov8)) (div255 (sb * cov8))
                 (div255 (a8 * cov8))
        px := px.setIfInBounds idx nv
  return ⟨w, h, px⟩

/-- Straight-alpha RGBA bytes, row-major, 4 bytes per pixel.  This is what
`Pixmap::encode_png` writes: it demultiplies every pixel first. -/
def toRgbaBytes (cv : Canvas) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity (cv.w * cv.h * 4)
  for v in cv.px do
    let a := v &&& 255
    if a == 0 then
      out := (((out.push 0).push 0).push 0).push 0
    else
      let un (c : Nat) : UInt8 := (unpremul c a).toUInt8
      out := (((out.push (un ((v >>> 24) &&& 255))).push (un ((v >>> 16) &&& 255))).push
        (un ((v >>> 8) &&& 255))).push a.toUInt8
  return out

end Canvas
end MicroSvg
