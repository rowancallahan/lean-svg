import LeanSvg.Canvas

/-!
# `feDisplacementMap` (T70): resvg `filter/displacement_map.rs`

Each output pixel copies `in` from an offset read off `in2`'s own channel
bytes at that pixel: `offset = (channel/255 - 0.5) · deviceScale · scale`,
rounded to the nearest whole pixel (`f32::round`, half away from zero).  Both
inputs are converted into the primitive's colour space first by the caller
(`FilterApply`'s `.into lin`, matching `Image::into_color_space`), but —
resvg's own doc comment on `displacement_map::apply` notwithstanding — its
caller never demultiplies `in2` before reading its channels, so this reads
the same already-premultiplied bytes `apply` does: a faithful copy of the
quirk, not a fix.

Only `Canvas` (not `FilterApply.Img`) so `FilterApply.runPrim` can call this
without a cyclic import. -/

namespace LeanSvg
namespace FilterApply

/-- One of `in2`'s four channels, by resvg's `ColorChannel` (`0`=R, `1`=G,
`2`=B, else A). -/
def dispChan (chan : Nat) (p : Nat) : Nat :=
  if chan == 0 then p >>> 24
  else if chan == 1 then (p >>> 16) &&& 255
  else if chan == 2 then (p >>> 8) &&& 255
  else p &&& 255

/-- `round(n / d)`, ties away from zero (`d > 0`): `f32::round`'s convention,
done exactly on the integer numerator/denominator instead of in `f32`. -/
def roundAwayDiv (n : Int) (d : Nat) : Int :=
  if n ≥ 0 then Int.ediv (2 * n + (d : Int)) (2 * (d : Int))
  else -(Int.ediv (2 * (-n) + (d : Int)) (2 * (d : Int)))

/-- `displacement_map::apply`.  `sx`/`sy` are the device scale (16.16, as
`FilterApply.scaleOf` already gives every other primitive); `scale` is the
attribute already multiplied by the average `primitiveUnits` scale (16.16),
as usvg's own `convert_displacement_map` does.  resvg's `apply_displacement_map`
first turns this into a device-scaled `sx' = scale · deviceScale`
(`scale_coordinates`) and then `displacement_map::apply` multiplies by
`fe.scale()` *again* (`dx · sx' · fe.scale()`) — squaring the attribute,
apparently unintentionally, but faithfully reproduced here since it is what
resvg 0.48.1 actually computes.  Every offset is
`(2c - 255) · deviceScale · scale² / (510 · 2^16 · 2^16 · 2^16)`, rounded
once. -/
def runDisplacementMap (rw rh : Nat) (sx sy : Nat) (scale : Int) (chX chY : Nat)
    (src map : Canvas) : Canvas := Id.run do
  let den : Nat := 510 * 65536 * 65536 * 65536
  let mut px : Array Nat := Array.replicate (rw * rh) 0
  for y in [0:rh] do
    let row := y * rw
    for x in [0:rw] do
      let mp := map.px.getD (row + x) 0
      let numX : Int := (2 * (dispChan chX mp : Int) - 255) * (sx : Int) * scale * scale
      let numY : Int := (2 * (dispChan chY mp : Int) - 255) * (sy : Int) * scale * scale
      let ox := (x : Int) + roundAwayDiv numX den
      let oy := (y : Int) + roundAwayDiv numY den
      if ox ≥ 0 && ox < (rw : Int) && oy ≥ 0 && oy < (rh : Int) then
        px := px.setIfInBounds (row + x) (src.px.getD (oy.toNat * rw + ox.toNat) 0)
  return ⟨rw, rh, px⟩

end FilterApply
end LeanSvg
