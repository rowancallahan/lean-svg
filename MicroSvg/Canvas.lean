import MicroSvg.Raster

/-!
# Canvas

Premultiplied RGBA, 8 bits per channel, one packed `Nat` per pixel
(`r<<24 | g<<16 | b<<8 | a`).  Source-over compositing only.
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

@[inline] def div255 (x : Nat) : Nat := (x + 127) / 255

@[inline] def pack (r g b a : Nat) : Nat := (r <<< 24) ||| (g <<< 16) ||| (b <<< 8) ||| a

def new (w h : Nat) (bg : Option Rgba) : Canvas :=
  let v := match bg with
    | none => 0
    | some c => pack (div255 (c.r * c.a)) (div255 (c.g * c.a)) (div255 (c.b * c.a)) c.a
  ⟨w, h, Array.replicate (w * h) v⟩

/-- Source-over of straight colour `(r,g,b)` with effective alpha `alpha ∈ [0,255]`
onto a packed premultiplied destination pixel. -/
@[inline] def blend (dst : Nat) (r g b alpha : Nat) : Nat :=
  let inv := 255 - alpha
  let dr := (dst >>> 24) &&& 255
  let dg := (dst >>> 16) &&& 255
  let db := (dst >>> 8) &&& 255
  let da := dst &&& 255
  let nr := Nat.min 255 (div255 (r * alpha) + div255 (dr * inv))
  let ng := Nat.min 255 (div255 (g * alpha) + div255 (dg * inv))
  let nb := Nat.min 255 (div255 (b * alpha) + div255 (db * inv))
  let na := Nat.min 255 (alpha + div255 (da * inv))
  pack nr ng nb na

/-- Fill the mask with a solid colour.  `opacity256` is an extra multiplier in `[0,256]`. -/
def fillMask (cv : Canvas) (m : Raster.Mask) (c : Rgba) (opacity256 : Nat) : Canvas := Id.run do
  let w := cv.w
  let h := cv.h
  let mut px := cv.px
  for y in [0:m.h] do
    let row := (m.y0 + y) * w
    for x in [0:m.w] do
      let cov := m.cov.getD (y * m.w + x) 0
      if cov == 0 then continue
      let alpha := c.a * cov * opacity256 / 16777216
      if alpha == 0 then continue
      let idx := row + m.x0 + x
      px := px.setIfInBounds idx (blend (px.getD idx 0) c.r c.g c.b alpha)
  return ⟨w, h, px⟩

/-- Straight-alpha RGBA bytes, row-major, 4 bytes per pixel. -/
def toRgbaBytes (cv : Canvas) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity (cv.w * cv.h * 4)
  for v in cv.px do
    let a := v &&& 255
    if a == 0 then
      out := (((out.push 0).push 0).push 0).push 0
    else
      let un (c : Nat) : UInt8 := (Nat.min 255 ((c * 255 + a / 2) / a)).toUInt8
      out := (((out.push (un ((v >>> 24) &&& 255))).push (un ((v >>> 16) &&& 255))).push
        (un ((v >>> 8) &&& 255))).push a.toUInt8
  return out

end Canvas
end MicroSvg
