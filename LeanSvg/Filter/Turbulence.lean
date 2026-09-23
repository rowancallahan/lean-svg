import LeanSvg.Canvas
import LeanSvg.Bytes

/-!
# `feTurbulence` (T65)

resvg 0.48.1's `filter/turbulence.rs`, which is the reference code of the SVG
spec (Perlin noise, the Park–Miller `random`, lattice set-up, `fTurbulence`,
`stitchTiles`), computed there in `f64`.  Here:

* the set-up (seed, lattice, the stitch frequencies and wrap points) is exact:
  integers, and every `f64` operation of the stitch set-up is rounded as
  binary64 with `r64`, since the wrap points are discontinuous;
* the per-axis lattice coordinates are exact rationals, cut per column and per
  row to `B = 24` fractional bits (`x · 2^k` is exact in `f64` too, and resvg's
  `t as i32` saturation, wrapping `+ 1` and `f64` loss of the fraction past
  `2^52` are kept);
* the per-pixel noise (dot products and the two lerps) runs in `Int64` at
  `2^-24`, which cannot overflow: every factor is below `2^31` in magnitude.

The error against the `f64` code is a few `2^-24` per octave, far below one
output level, so the only differences are the rare values within `10^-5` of a
rounding boundary.

`numOctaves` is capped at `maxOctaves`: octave `k` adds at most `180 / 2^k`
levels, so the octaves past 16 change the output by less than `0.006` levels
in total, while every one costs a full pass over the region.
-/

namespace LeanSvg
namespace Turbulence

open Bytes

/-- Fractional bits of the per-pixel arithmetic. -/
def B : Nat := 24

def maxOctaves : Nat := 16

/-- usvg's `Turbulence`, frequencies as exact rationals of their `f32`s. -/
structure Params where
  fxN : Nat
  fxD : Nat
  fyN : Nat
  fyD : Nat
  octaves : Nat
  seed : Int
  stitch : Bool
  fractal : Bool
deriving Inhabited

/-- A binary32 as an exact rational `(neg, num, den)`. -/
def ratOf (v : F32) : Bool × Nat × Nat :=
  let m := F32.mant v
  let eb := F32.expo v
  if m == 0 then (false, 0, 1)
  else if eb ≥ F32.bias then (F32.isNeg v, m * 2 ^ (Nat.min 200 (eb - F32.bias)), 1)
  else (F32.isNeg v, m, 2 ^ (Nat.min 200 (F32.bias - eb)))

/-- `as i32`: saturating. -/
def sat32 (v : Int) : Int :=
  if v > 2147483647 then 2147483647 else if v < -2147483648 then -2147483648 else v

/-- `i32` wrapping arithmetic (resvg is built in release mode). -/
def wrap32 (v : Int) : Int := Int.emod (v + 2147483648) 4294967296 - 2147483648

/-- `convert_turbulence` on the parsed attributes: `baseFrequency` as usvg's
`Vec<f32>` (one or two numbers, both non-negative, else `0 0`), `numOctaves`
rounded half away from zero (negative → 0), `seed` truncated to `i32`. -/
def params (freq : Option (Array F32)) (oct seed : F32) (stitch ty : Option ByteArray) :
    Params :=
  let (x, y) := match freq with
    | some #[a] => (a, a)
    | some #[a, b] => (a, b)
    | _ => (0, 0)
  let (_, xp, xd) := ratOf x
  let (_, yp, yd) := ratOf y
  let ok := !F32.isNeg x && !F32.isNeg y
  let (_, on, od) := ratOf oct
  let octaves := if F32.isNeg oct then 0 else Nat.min maxOctaves ((2 * on + od) / (2 * od))
  let (sn, s, sd) := ratOf seed
  let seed : Int := sat32 (if sn then -((s / sd : Nat) : Int) else ((s / sd : Nat) : Int))
  let is := fun (v : Option ByteArray) (s : String) => match v with
    | some t => eqAscii (trim t) s
    | none => false
  { fxN := if ok then xp else 0, fxD := if ok then xd else 1,
    fyN := if ok then yp else 0, fyD := if ok then yd else 1,
    octaves, seed, stitch := is stitch "stitch", fractal := is ty "fractalNoise" }

/-! ## Set-up -/

def randM : Int := 2147483647

/-- The spec's `random`, with Rust's truncating `/` and `%`. -/
def random (s : Int) : Int :=
  let r := 16807 * Int.tmod s 127773 - 2836 * Int.tdiv s 127773
  if r ≤ 0 then r + randM else r

/-- `init`: the 514-entry lattice selector, and per channel and lattice point
the unit gradient `(g0, g1)` at `B` bits (index `2 · (256c + i)`), `none`
where resvg divides `0 / 0` (both raw components zero) and gets NaN. -/
def init (seed0 : Int) : Array Nat × Array Int64 × Array Bool := Id.run do
  let mut seed := seed0
  if seed ≤ 0 then seed := Int.tmod (wrap32 (-seed)) (randM - 1) + 1
  if seed > randM - 1 then seed := randM - 1
  let mut grad : Array Int64 := Array.replicate 2048 0
  let mut nan : Array Bool := Array.replicate 1024 false
  for c in [0:4] do
    for i in [0:256] do
      seed := random seed
      let a := Int.tmod seed 512 - 256
      seed := random seed
      let b := Int.tmod seed 512 - 256
      let q := (a * a + b * b).toNat
      let idx := 256 * c + i
      if q == 0 then
        nan := nan.setIfInBounds idx true
      else
        -- `g / √(a² + b²)`, rounded to `B` bits
        let unit := fun (g : Int) =>
          let m := Nat.sqrt (g.natAbs * g.natAbs * 2 ^ (2 * B + 2) / q)
          let r : Int := ((m + 1) / 2 : Nat)
          Int64.ofInt (if g < 0 then -r else r)
        grad := grad.setIfInBounds (2 * idx) (unit a)
        grad := grad.setIfInBounds (2 * idx + 1) (unit b)
  let mut ls : Array Nat := Array.range 256
  for k in [0:255] do
    let i := 255 - k
    let t := ls.getD i 0
    seed := random seed
    let j := (Int.tmod seed 256).toNat
    ls := ls.setIfInBounds i (ls.getD j 0)
    ls := ls.setIfInBounds j t
  ls := ls ++ ls ++ #[ls.getD 0 0, ls.getD 1 0]
  return (ls, grad, nan)

/-! ## Binary64 for the stitch set-up -/

/-- The binary64 nearest `num / den` (ties to even), as an exact rational. -/
def r64 (num : Int) (den : Nat) : Int × Nat :=
  let n := num.natAbs
  if n == 0 || den == 0 then (0, 1)
  else
    let s : Int := 54 + (Nat.log2 den : Int) - (Nat.log2 n : Int)
    let (nn, dd) := if s ≥ 0 then (n * 2 ^ s.toNat, den) else (n, den * 2 ^ (-s).toNat)
    let q := nn / dd
    let extra := Nat.log2 q + 1 - 53
    let m := q >>> extra
    let rem := q - (m <<< extra)
    let half := 2 ^ extra / 2
    let up := rem > half || (rem == half && (q * dd != nn || m % 2 == 1))
    let m := if up then m + 1 else m
    let e : Int := (extra : Int) - s
    let v : Int := if num < 0 then -(m : Int) else m
    if e ≥ 0 then (v * 2 ^ e.toNat, 1) else (v, 2 ^ (-e).toNat)

/-- `f64 as i32` of a rational. -/
def trunc32 (q : Int × Nat) : Int := sat32 (Int.tdiv q.1 q.2)

/-- The stitch set-up along one axis (`tile` = region width or height):
the adjusted frequency, and `(width, wrap)` per pixel index. -/
def stitchAxis (fn fd tile : Nat) : (Nat × Nat) × Int × Array Int := Id.run do
  let mut f : Nat × Nat := (fn, fd)
  if fn != 0 then
    let p := r64 (tile * fn : Nat) fd
    let fl := Int.ediv p.1 p.2
    let ce := -Int.ediv (-p.1) p.2
    let lo := r64 fl tile
    let hi := r64 ce tile
    -- `base / lo < hi / base`; `base / 0` is +∞
    let pick := if lo.1 == 0 then false
      else
        let c1 := r64 (fn * lo.2 : Nat) (fd * lo.1.toNat)
        let c2 := r64 (hi.1.toNat * fd : Nat) (hi.2 * fn)
        c1.1 * c2.2 < c2.1 * c1.2
    let r := if pick then lo else hi
    f := (r.1.toNat, r.2)
  let wv := r64 (tile * f.1 : Nat) f.2
  let width := trunc32 (r64 (2 * wv.1 + wv.2) (2 * wv.2))
  let wraps := (Array.range tile).map fun t =>
    let a := r64 (t * f.1 : Nat) f.2
    let b := r64 (a.1 + 4096 * a.2) a.2
    trunc32 (r64 (b.1 + width * b.2) b.2)
  return (f, width, wraps)

/-! ## Per-axis lattice coordinates -/

/-- Per octave and pixel index along one axis: the two lattice indices after
stitching and `& 0xff`, `r0` and `s_curve(r0)` at `B` bits.  The coordinate
is `((i + o) / sc) · f` with `o = org - e/256` and `sc` the 16.16 scale. -/
structure Axis where
  b0 : Array Nat
  b1 : Array Nat
  r0 : Array Int64
  s : Array Int64

def axis (n : Nat) (org e : Int) (sc : Nat) (fn fd : Nat) (oct : Nat)
    (st : Option (Int × Array Int)) : Axis := Id.run do
  let D : Nat := sc * fd
  let mut ax : Axis := ⟨#[], #[], #[], #[]⟩
  let mut width : Int := match st with | some (w, _) => w | none => 0
  let mut wraps : Array Int := match st with | some (_, ws) => ws | none => #[]
  for k in [0:oct] do
    for i in [0:n] do
      let N : Int := (((i : Int) + org) * 256 - e) * 256 * fn * 2 ^ k + 4096 * (D : Int)
      let bx := Int.tdiv N D
      -- `t - t as i64`: the fraction, gone once `f64` has no fractional bits
      let fr : Int := if bx.natAbs ≥ 2 ^ 52 then 0 else N - bx * D
      let mut b0 := sat32 bx
      let mut b1 := wrap32 (b0 + 1)
      if st.isSome then
        let w := wraps.getD i 0
        if b0 ≥ w then b0 := wrap32 (b0 - width)
        if b1 ≥ w then b1 := wrap32 (b1 - width)
      let r0 := Int.ediv (fr * 2 ^ B) D
      let s := Int.ediv (fr * fr * (3 * D - 2 * fr) * 2 ^ B) (D * D * D)
      ax := { b0 := ax.b0.push (Int.emod b0 256).toNat, b1 := ax.b1.push (Int.emod b1 256).toNat,
              r0 := ax.r0.push (Int64.ofInt r0), s := ax.s.push (Int64.ofInt s) }
    if st.isSome then
      width := wrap32 (2 * width)
      wraps := wraps.map fun w => wrap32 (2 * w - 4096)
  return ax

/-! ## Rendering -/

/-- `noise2` for channel `c` (`g` = gradient base `512 c`), given the four
lattice points and the per-axis values, all at `B` bits. -/
@[inline] def noise (grad : Array Int64) (g b00 b10 b01 b11 : Nat) (rx0 ry0 sx sy : Int64) :
    Int64 :=
  let one : Int64 := 16777216  -- 2^B
  let rx1 := rx0 - one
  let ry1 := ry0 - one
  let i00 := g + 2 * b00
  let i10 := g + 2 * b10
  let i01 := g + 2 * b01
  let i11 := g + 2 * b11
  let u := (rx0 * grad.getD i00 0 + ry0 * grad.getD (i00 + 1) 0) >>> 24
  let v := (rx1 * grad.getD i10 0 + ry0 * grad.getD (i10 + 1) 0) >>> 24
  let a := u + ((sx * (v - u)) >>> 24)
  let u := (rx0 * grad.getD i01 0 + ry1 * grad.getD (i01 + 1) 0) >>> 24
  let v := (rx1 * grad.getD i11 0 + ry1 * grad.getD (i11 + 1) 0) >>> 24
  let bb := u + ((sx * (v - u)) >>> 24)
  a + ((sy * (bb - a)) >>> 24)

/-- `(f32_bound(0, n, 255) + 0.5) as u8` for the octave sum `s` at `2^-sh`. -/
def toByte (fractal : Bool) (sh : Nat) (s : Int64) : Nat :=
  let s := s.toInt * 255
  let v := if fractal then Int.fdiv (s + 255 * 2 ^ sh + 2 ^ sh) (2 ^ (sh + 1))
    else Int.fdiv (s + 2 ^ sh / 2) (2 ^ sh)
  if v < 0 then 0 else Nat.min 255 v.toNat

/-- `apply_turbulence`: the `w × h` region image whose pixel `(0, 0)` is layer
pixel `(ox, oy)`; `(e, f)` is the layer transform's translation (`Fx`) and
`(scx, scy)` its 16.16 scale.  Premultiplied, as after `multiply_alpha`. -/
def render (p : Params) (e f : Int) (scx scy : Nat) (ox oy : Int) (w h : Nat) : Canvas := Id.run do
  if scx == 0 || scy == 0 then return Canvas.new w h none
  let (ls, grad, nan) := init p.seed
  let hasNan := nan.any id
  let K := p.octaves
  let (fx, stx) := if p.stitch then
      let ((a, b), wd, ws) := stitchAxis p.fxN p.fxD w
      ((a, b), some (wd, ws))
    else ((p.fxN, p.fxD), none)
  let (fy, sty) := if p.stitch then
      let ((a, b), wd, ws) := stitchAxis p.fyN p.fyD h
      ((a, b), some (wd, ws))
    else ((p.fyN, p.fyD), none)
  let X := axis w ox e scx fx.1 fx.2 K stx
  let Y := axis h oy f scy fy.1 fy.2 K sty
  let sh := B + K
  let mut px : Array Nat := Array.mkEmpty (w * h)
  for y in [0:h] do
    for x in [0:w] do
      let mut s0 : Int64 := 0
      let mut s1 : Int64 := 0
      let mut s2 : Int64 := 0
      let mut s3 : Int64 := 0
      let mut bad : Nat := 0
      for k in [0:K] do
        let ix := k * w + x
        let iy := k * h + y
        let rx0 := X.r0.getD ix 0
        let ry0 := Y.r0.getD iy 0
        let sx := X.s.getD ix 0
        let sy := Y.s.getD iy 0
        let by0 := Y.b0.getD iy 0
        let by1 := Y.b1.getD iy 0
        let i := ls.getD (X.b0.getD ix 0) 0
        let j := ls.getD (X.b1.getD ix 0) 0
        let b00 := ls.getD (i + by0) 0
        let b10 := ls.getD (j + by0) 0
        let b01 := ls.getD (i + by1) 0
        let b11 := ls.getD (j + by1) 0
        let n0 := noise grad 0 b00 b10 b01 b11 rx0 ry0 sx sy
        let n1 := noise grad 512 b00 b10 b01 b11 rx0 ry0 sx sy
        let n2 := noise grad 1024 b00 b10 b01 b11 rx0 ry0 sx sy
        let n3 := noise grad 1536 b00 b10 b01 b11 rx0 ry0 sx sy
        let m := Int64.ofNat (K - k)
        if p.fractal then
          s0 := s0 + (n0 <<< m)
          s1 := s1 + (n1 <<< m)
          s2 := s2 + (n2 <<< m)
          s3 := s3 + (n3 <<< m)
        else
          s0 := s0 + ((if n0 < 0 then -n0 else n0) <<< m)
          s1 := s1 + ((if n1 < 0 then -n1 else n1) <<< m)
          s2 := s2 + ((if n2 < 0 then -n2 else n2) <<< m)
          s3 := s3 + ((if n3 < 0 then -n3 else n3) <<< m)
        if hasNan then
          -- NaN through `f32_bound` is 0: flag the channels that met one
          for c in [0:4] do
            if nan.getD (256 * c + b00) false || nan.getD (256 * c + b10) false ||
                nan.getD (256 * c + b01) false || nan.getD (256 * c + b11) false then
              bad := bad ||| (1 <<< c)
      let out := fun (c : Nat) (v : Int64) =>
        if (bad >>> c) &&& 1 == 1 then 0 else toByte p.fractal sh v
      let a := out 3 s3
      px := px.push (Canvas.pack (Canvas.premul (out 0 s0) a) (Canvas.premul (out 1 s1) a)
        (Canvas.premul (out 2 s2) a) a)
  return ⟨w, h, px⟩

end Turbulence
end LeanSvg
