/-!
# JPEG inverse DCT and colour conversion (T62)

`idct` is `zune-jpeg` 0.5.15's scalar integer IDCT (`idct/scalar.rs`,
`idct_int`, the stb_image/jidctint-style 12-bit fixed-point transform with the
+128 level shift folded into the final rounding constant), in `Int32` so its
wrapping arithmetic is reproduced exactly. zune's 4x4 and 1x1 variants and its
AVX2 path compute the same values (the 4x4 one is the same polynomial with
zero inputs dropped; the AVX2 one is checked equal by
`tests/check_jpeg_decode.py`), so one function covers them.

`ycc` is zune's BT.601 full-range YCbCr → RGB with 14-bit coefficients and
the rounding constant `2^13 - 1` (`color_convert/scalar.rs`).
-/

namespace LeanSvg.Jpeg

@[inline] private def clampByte (v : Int32) : UInt8 :=
  if v < 0 then 0 else if v > 255 then 255 else v.toInt.toNat.toUInt8

/-- 8x8 IDCT of dequantized coefficients `c` (natural order, 64 entries) to
64 samples, row-major, each clamped to `0..255`. -/
def idct (c : Array Int32) : Array UInt8 := Id.run do
  let g (i : Nat) (a : Array Int32) : Int32 := a.getD i 0
  let mut allZero := true
  for i in [1:64] do
    if g i c != 0 then allZero := false
  if allZero then
    let v := clampByte ((g 0 c + 4 + 1024) >>> 3)
    return Array.replicate 64 v
  let mut v := c
  -- vertical pass (columns), results scaled by 2^2 and kept in `v`
  for p in [0:8] do
    let p2 := g (p + 16) v
    let p3 := g (p + 48) v
    let p1 := (p2 + p3) * 2217
    let t2 := p1 + p3 * (-7567)
    let t3 := p1 + p2 * 3135
    let q2 := g p v
    let q3 := g (32 + p) v
    let t0 := (q2 + q3) <<< 12
    let t1 := (q2 - q3) <<< 12
    let x0 := t0 + t3 + 512
    let x3 := t0 - t3 + 512
    let x1 := t1 + t2 + 512
    let x2 := t1 - t2 + 512
    let mut o0 := g (p + 56) v
    let mut o1 := g (p + 40) v
    let mut o2 := g (p + 24) v
    let mut o3 := g (p + 8) v
    let r3 := o0 + o2
    let r4 := o1 + o3
    let r1 := o0 + o3
    let r2 := o1 + o2
    let r5 := (r3 + r4) * 4816
    o0 := o0 * 1223
    o1 := o1 * 8410
    o2 := o2 * 12586
    o3 := o3 * 6149
    let s1 := r5 + r1 * (-3685)
    let s2 := r5 + r2 * (-10497)
    let s3 := r3 * (-8034)
    let s4 := r4 * (-1597)
    o3 := o3 + (s1 + s4)
    o2 := o2 + (s2 + s3)
    o1 := o1 + (s2 + s4)
    o0 := o0 + (s1 + s3)
    v := v.setIfInBounds p ((x0 + o3) >>> 10)
    v := v.setIfInBounds (p + 8) ((x1 + o2) >>> 10)
    v := v.setIfInBounds (p + 16) ((x2 + o1) >>> 10)
    v := v.setIfInBounds (p + 24) ((x3 + o0) >>> 10)
    v := v.setIfInBounds (p + 32) ((x3 - o0) >>> 10)
    v := v.setIfInBounds (p + 40) ((x2 - o1) >>> 10)
    v := v.setIfInBounds (p + 48) ((x1 - o2) >>> 10)
    v := v.setIfInBounds (p + 56) ((x0 - o3) >>> 10)
  -- horizontal pass (rows); `scale` holds the rounding and the +128 shift
  let scale : Int32 := 16843264  -- 512 + 65536 + (128 << 17)
  let mut out : Array UInt8 := Array.replicate 64 0
  for row in [0:8] do
    let i := row * 8
    let p2 := g (i + 2) v
    let p3 := g (i + 6) v
    let p1 := (p2 + p3) * 2217
    let t2 := p1 + p3 * (-7567)
    let t3 := p1 + p2 * 3135
    let q2 := g i v
    let q3 := g (i + 4) v
    let t0 := (q2 + q3) <<< 12
    let t1 := (q2 - q3) <<< 12
    let x0 := t0 + t3 + scale
    let x3 := t0 - t3 + scale
    let x1 := t1 + t2 + scale
    let x2 := t1 - t2 + scale
    let mut o0 := g (i + 7) v
    let mut o1 := g (i + 5) v
    let mut o2 := g (i + 3) v
    let mut o3 := g (i + 1) v
    let r3 := o0 + o2
    let r4 := o1 + o3
    let r1 := o0 + o3
    let r2 := o1 + o2
    let r5 := (r3 + r4) * 4816
    o0 := o0 * 1223
    o1 := o1 * 8410
    o2 := o2 * 12586
    o3 := o3 * 6149
    let s1 := r5 + r1 * (-3685)
    let s2 := r5 + r2 * (-10497)
    let s3 := r3 * (-8034)
    let s4 := r4 * (-1597)
    o3 := o3 + (s1 + s4)
    o2 := o2 + (s2 + s3)
    o1 := o1 + (s2 + s4)
    o0 := o0 + (s1 + s3)
    out := out.setIfInBounds i (clampByte ((x0 + o3) >>> 17))
    out := out.setIfInBounds (i + 1) (clampByte ((x1 + o2) >>> 17))
    out := out.setIfInBounds (i + 2) (clampByte ((x2 + o1) >>> 17))
    out := out.setIfInBounds (i + 3) (clampByte ((x3 + o0) >>> 17))
    out := out.setIfInBounds (i + 4) (clampByte ((x3 - o0) >>> 17))
    out := out.setIfInBounds (i + 5) (clampByte ((x2 - o1) >>> 17))
    out := out.setIfInBounds (i + 6) (clampByte ((x1 - o2) >>> 17))
    out := out.setIfInBounds (i + 7) (clampByte ((x0 - o3) >>> 17))
  return out

@[inline] private def clampNat (v : Int) : UInt8 :=
  if v < 0 then 0 else if v > 255 then 255 else v.toNat.toUInt8

/-- YCbCr (each `0..255`) to RGB. -/
@[inline] def ycc (y cb cr : Nat) : UInt8 × UInt8 × UInt8 :=
  let cr : Int := (cr : Int) - 128
  let cb : Int := (cb : Int) - 128
  let y0 : Int := (y : Int) * 16384 + 8191
  (clampNat ((y0 + cr * 22970) >>> 14),
   clampNat ((y0 + cr * (-11700) + cb * (-5638)) >>> 14),
   clampNat ((y0 + cb * 29032) >>> 14))

end LeanSvg.Jpeg
