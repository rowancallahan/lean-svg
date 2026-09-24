import LeanSvg.Canvas
import LeanSvg.Xml
import LeanSvg.Geom

/-!
# Lighting filters (T66): `feDiffuseLighting` and `feSpecularLighting`

A port of usvg 0.48.1's `convert_diffuse_lighting`/`convert_specular_lighting`/
`convert_light_source` and resvg's `filter/lighting.rs` with
`transform_light_source`.

Every per-pixel quantity in resvg is `f32` and ends in a truncating `as u8`
after `+ 0.5`, so the whole computation runs on the exact binary32 emulation
`F32` (`Canvas.lean`), operation for operation in resvg's order.  The three
functions `f32` has and `F32` has not are handled as follows: `sqrt` is
`sqrtF` below (exact, like `F32.sqrt` but scalar); `sin`/`cos` are `Filter.sinCosF32`, handed in by the caller
because this file is imported by `Filter.lean`; `powf` is `powF` below, computed
on a 2^-80 fixed-point grid and rounded once (libm's `powf` is correctly rounded
except on inputs within ~2^-60 of a tie).

The surface normal is the spec's Sobel kernels with resvg's nine edge/interior
cases, written as one formula: rows (columns) outside the image drop out and
the horizontal (vertical) difference is taken between the clamped neighbours;
the factor is 2/3 at a corner, 1/3 and 1/2 on an edge, 1/4 inside.

Cost: one pass over the input image with a constant amount of work per pixel
(nine alpha reads, ~40 `F32` operations, at most two `powF`s, each a fixed
number of 80-bit multiplications), so the work is bounded by the layer area.
-/

namespace LeanSvg
namespace Lighting

/-- usvg's `LightSource`, coordinates in the element's user space, all `f32`. -/
inductive Light where
  | distant (azimuth elevation : F32)
  | point (x y z : F32)
  | spot (x y z px py pz se : F32) (cone : Option F32)
deriving Inhabited

/-- One lighting primitive.  `k` is `diffuseConstant` or `specularConstant`;
`se` is `specularExponent` (in `[1, 128]`, unused for diffuse). -/
structure Params where
  specular : Bool
  ss : F32
  k : F32
  se : F32
  r : Nat
  g : Nat
  b : Nat
  light : Light
deriving Inhabited

/-! ## Parsing -/

/-- `PositiveF32::new`: strictly positive (and finite, which every `F32` is). -/
def isPos (v : F32) : Bool := v != 0 && !F32.isNeg v

/-- `std::f32::consts::SQRT_2`, bit-exact. -/
def sqrt2F : F32 := F32.ofRat 11863283 8388608

/-- `⌊√n⌋` for `n < 2^63` by Newton's method from `2^⌈bits/2⌉` (an upper
bound), which decreases to the floor root in at most eight steps for these
sizes; the loop is bounded at twelve. -/
def isqrt (n : Nat) : Nat := Id.run do
  if n < 2 then return n
  let mut x := F32.p2 ((F32.bitLen n + 1) / 2)
  for _ in [0:12] do
    let y := (x + n / x) / 2
    if y ≥ x then break
    x := y
  return x

/-- `f32::sqrt`, correctly rounded: `F32.sqrt` with a 51-bit radicand instead
of a 76-bit one, so it stays in scalar arithmetic.  The root has 25 or 26 bits,
enough for `F32.norm` to round from, with the remainder as the sticky bit. -/
def sqrtF (a : F32) : F32 :=
  if a == 0 || F32.isNeg a then 0
  else
    let pRaw := F32.expo a + (F32.pbias - F32.bias)
    let odd := pRaw % 2 == 1
    let m := if odd then F32.mant a * 2 else F32.mant a
    let p0 := if odd then pRaw - 1 else pRaw
    let big := m * 67108864
    let r := isqrt big
    F32.norm false r ((p0 + F32.pbias - 26) / 2) (r * r != big)

/-- `bbox_transform` for a light source coordinate under
`primitiveUnits="objectBoundingBox"`: `x`/`y` scale per axis and shift by the
bbox origin, `z` (not axis-specific) scales by the bbox diagonal,
`sqrt((w² + h²) / 2)` (SVG 2 "normalized diagonal"). Usvg 0.48.1 does not
apply this at all (`convert_light_source` reads `x`/`y`/`z` raw), which is a
confirmed upstream bug still present on `main`; identity when
`bbx = bby = 0, scx = scy = 1`, i.e. `userSpaceOnUse`. -/
def obbXY (b o : F32) (sc : F32) : F32 := F32.add b (F32.mul o sc)
def obbZ (o diag : F32) : F32 := F32.mul o diag

/-- `convert_light_source`: the first `feDistantLight`/`fePointLight`/
`feSpotLight` child; `none` without one. `num as n` reads attribute `n` of
`as` as an `f32`. `bbx bby scx scy` is the `primitiveUnits` bbox (identity for
`userSpaceOnUse`), applied to `x`/`y`/`z` and `pointsAt*` per `obbXY`/`obbZ`. -/
def lightOf (num : Array Xml.Attr → String → Option F32)
    (children : Array (String × Array Xml.Attr)) (bbx bby scx scy : F32) : Option Light :=
  let isLight := fun (n : String) => n == "feDistantLight" || n == "fePointLight" || n == "feSpotLight"
  match children.find? (fun c => isLight c.1) with
  | none => none
  | some (n, as) =>
    let g := fun (a : String) => (num as a).getD 0
    let diag := F32.div (sqrtF (F32.add (F32.mul scx scx) (F32.mul scy scy))) sqrt2F
    if n == "feDistantLight" then some (.distant (g "azimuth") (g "elevation"))
    else if n == "fePointLight" then
      some (.point (obbXY bbx (g "x") scx) (obbXY bby (g "y") scy) (obbZ (g "z") diag))
    else
      let se := (num as "specularExponent").getD F32.one
      some (.spot (obbXY bbx (g "x") scx) (obbXY bby (g "y") scy) (obbZ (g "z") diag)
        (obbXY bbx (g "pointsAtX") scx) (obbXY bby (g "pointsAtY") scy) (obbZ (g "pointsAtZ") diag)
        (if isPos se then se else F32.one) (num as "limitingConeAngle"))

/-- `convert_diffuse_lighting` / `convert_specular_lighting`.  `none` is usvg's
`create_dummy_primitive` (no light source, or a `specularExponent` outside
`[1, 128]`), which the caller turns into a transparent black flood.

`lightingColor` is the raw `lighting-color` value: `currentColor` takes the
inherited `color` (black when none), an unparsable value is white, as is an
absent one; the colour's alpha is dropped.  `inherit` is read as absent. -/
def convert (specular : Bool) (num : Array Xml.Attr → String → Option F32)
    (attrs : Array Xml.Attr) (lightingColor : Option ByteArray)
    (children : Array (String × Array Xml.Attr)) (color : Rgba)
    (parseColor : ByteArray → Option Rgba) (bbx bby scx scy : F32) : Option Params := do
  let light ← lightOf num children bbx bby scx scy
  let se := (num attrs "specularExponent").getD F32.one
  let c128 := F32.ofNat 128
  if specular && (F32.lt se F32.one || F32.lt c128 se) then none
  let white : Rgba := ⟨255, 255, 255, 255⟩
  let c : Rgba := match lightingColor with
    | none => white
    | some v =>
      let t := Bytes.trim v
      if Bytes.eqAscii t "currentColor" then color
      else if Bytes.eqAscii t "inherit" then white
      else (parseColor t).getD white
  let k := (num attrs (if specular then "specularConstant" else "diffuseConstant")).getD F32.one
  some ⟨specular, (num attrs "surfaceScale").getD F32.one, k, se, c.r, c.g, c.b, light⟩

/-! ## `f32` helpers -/

/-- A signed integer as a binary32. -/
def fInt (v : Int) : F32 := if v < 0 then F32.neg (F32.ofNat (-v).toNat) else F32.ofNat v.toNat

/-- A 16.16 (`den` = 65536) or 24.8 (`den` = 256) value as a binary32. -/
def fFix (v : Int) (den : Nat) : F32 :=
  if v < 0 then F32.neg (F32.ofRat (-v).toNat den) else F32.ofRat v.toNat den

/-- `std::f32::consts::PI`, bit-exact. -/
def piF : F32 := F32.ofRat 13176795 4194304

/-- `f32::to_radians`: `x * (PI / 180.0)`, the constant folded in `f32`. -/
def toRad (deg : F32) : F32 := F32.mul deg (F32.div piF (F32.ofNat 180))

/-- `⌊v⌋` of a non-negative binary32 below `2^16` (`as u8` of `bound + 0.5`). -/
def floorF (v : F32) : Nat :=
  if v == 0 || F32.isNeg v then 0
  else
    let m := F32.mant v
    let eb := F32.expo v
    if eb ≥ F32.bias then m * F32.p2 (Nat.min 16 (eb - F32.bias))
    else
      let s := F32.bias - eb
      if s > 30 then 0 else m >>> s

/-- `c as f32` for a byte, and `0.5`. -/
def byteF : Array F32 := (Array.range 256).map F32.ofNat
def halfF : F32 := F32.ofRat 1 2

/-- `(f32_bound(0.0, c as f32 * factor, 255.0) + 0.5) as u8`; a `none` factor
is a NaN, which `f32_bound` sends to `0`. -/
def compute (c : Nat) (factor : Option F32) : Nat :=
  match factor with
  | none => 0
  | some f =>
    let v := F32.mul (byteF.getD c 0) f
    let v := if F32.lt F32.c255 v then F32.c255 else if F32.isNeg v then 0 else v
    Nat.min 255 (floorF (F32.add v halfF))

/-- `approx_eq_ulps(&1.0, 4)`. -/
def nearOne (v : F32) : Bool :=
  F32.le (F32.ofRat 16777212 16777216) v && F32.le v (F32.ofRat 8388612 8388608)

structure V3 where
  x : F32
  y : F32
  z : F32
deriving Inhabited

def V3.sub (a b : V3) : V3 := ⟨F32.sub a.x b.x, F32.sub a.y b.y, F32.sub a.z b.z⟩
def V3.dot (a b : V3) : F32 := F32.add (F32.add (F32.mul a.x b.x) (F32.mul a.y b.y)) (F32.mul a.z b.z)
def V3.len (a : V3) : F32 := sqrtF (V3.dot a a)
/-- `normalized().unwrap_or(v)`; `approx_zero_ulps(4)` of a length is `0`, since
denormals flush to zero. -/
def V3.norm (a : V3) : V3 :=
  let l := a.len
  if l == 0 then a else ⟨F32.div a.x l, F32.div a.y l, F32.div a.z l⟩

/-! ## `powf` -/

/-- The fixed-point grid of `powF`. -/
def S : Nat := 2 ^ 80

/-- `2·atanh(n/d)·S` for `0 ≤ n/d ≤ 1/3`: `Σ 2 z^(2i+1)/(2i+1)`, 28 terms
(`(1/9)^28 < 2^-88`).  Grid products are shifted, not divided, back to `S`. -/
def atanh2 (n d : Nat) : Nat := Id.run do
  let z := n * S / d
  let z2 := (z * z) >>> 80
  let mut t := z
  let mut acc := 0
  for i in [0:28] do
    acc := acc + t / (2 * i + 1)
    t := (t * z2) >>> 80
  return 2 * acc

/-- `ln 2 · S`. -/
def ln2S : Nat := atanh2 1 3

/-- `e^f · S` for `0 ≤ f < ln 2` (`f` on the grid), 28 Taylor terms
(`0.7^28/28! < 2^-100`). -/
def expS (f : Nat) : Nat := Id.run do
  let mut t := S
  let mut acc := 0
  for i in [0:28] do
    acc := acc + t
    t := ((t * f) >>> 80) / (i + 1)
  return acc

/-- `x.powf(y)` for `x > 0`, `y > 0`: `e^(y · ln x)` on the 2^-80 grid, rounded
once to a binary32.  `ln x = ln(m/2^23) + (e + 23)·ln 2` with the mantissa part
from `atanh`; the result `2^k · e^f` is handed to `F32.norm` at 56 bits with a
sticky bit.  Below `e^-110` the result is `0` (f32 would give a denormal or
zero, and either is `0` after `· 255 + 0.5`); above `e^110` it is `2^170`,
which every caller clamps (f32 would give `∞`). -/
def powExact (x y : F32) : F32 :=
  if x == 0 || F32.isNeg x then 0
  else if y == F32.one then x
  else
    let mx := F32.mant x
    let ex : Int := (F32.expo x : Int) - F32.bias
    let lnm : Int := atanh2 (mx - 8388608) (mx + 8388608)
    let L : Int := lnm + (ex + 23) * (ln2S : Int)
    let my := F32.mant y
    let ey : Int := (F32.expo y : Int) - F32.bias
    let ey := if ey > 200 then 200 else ey
    let P : Int := if ey ≥ 0 then L * my * (2 ^ ey.toNat : Nat) else Int.fdiv (L * my) (2 ^ (-ey).toNat : Nat)
    let lim : Int := 110 * (S : Int)
    if P < -lim then 0
    else if P > lim then F32.mk false 8388608 (F32.bias + 170)
    else
      let k := Int.fdiv P ln2S
      let f := (P - k * ln2S).toNat
      let E := expS f
      let m := E >>> 24
      -- value = E · 2^(k − 80) = m · 2^(k − 56), working exponent `pbias + k − 56`
      F32.norm false m ((F32.pbias - 56 + k).toNat) (m * 16777216 != E)

/-! ### The scalar fast path

`powExact` spends its time in GMP (a hundred-odd multiplications of 160-bit
numbers per call), which on a 16 Mpx layer would be minutes.  `powFast`
computes the same value on a 2^-44 grid (`Q`) with every product below 2^63,
so it never leaves unboxed `Nat` arithmetic, and it carries a bound on its own
error: when the result lies within that bound of a binary32 rounding tie it
says so and `powF` asks `powExact` (within `exactBudget`), so `powF` is
`powExact`, only faster. -/

@[noinline] def Q : Nat := 2 ^ 44

/-- `ln(1 + j/256) · Q`, `j < 256`, and `e^(-i/128) · Q`, `i < 90`, rounded;
built on first use from the 2^-80 series. -/
def lnTab : Thunk (Array Nat) :=
  Thunk.mk fun _ => (Array.range 256).map fun j => (atanh2 j (512 + j) + 2 ^ 35) >>> 36
def expTab : Thunk (Array Nat) :=
  Thunk.mk fun _ => (Array.range 90).map fun i => (S * S / expS (i * S / 128) + 2 ^ 35) >>> 36

def ln2Q : Nat := (ln2S + 2 ^ 35) >>> 36

/-! Constants above 2^32 are `@[noinline]` top-level definitions, built once: a
literal that size in a function body (which is what an inlined constant
becomes) is re-parsed into a bignum on every evaluation. -/
@[noinline] def c2p37 : Nat := 2 ^ 37
@[noinline] def c2p42 : Nat := 2 ^ 42
@[noinline] def c2p50 : Nat := 2 ^ 50
@[noinline] def npMax : Nat := 110 * Q

/-- `a · b / Q` for `a, b < 2^44`, by 22-bit halves (every product < 2^44);
at most two units low. -/
def mulQ (a b : Nat) : Nat :=
  let ah := a >>> 22
  let al := a &&& 4194303
  let bh := b >>> 22
  let bl := b &&& 4194303
  ah * bh + ((ah * bl + al * bh) >>> 22) + ((al * bl) >>> 44)

/-- `v² / Q` and `v³ / Q²` for `v < 2^36` on the `Q` grid, from `v` cut to
28 bits (the loss is below 2^-43 absolute for `v/Q < 2^-7`). -/
def sq (v : Nat) : Nat := let t := v >>> 8; (t * t) >>> 28
def cube (v : Nat) : Nat := ((sq v >>> 8) * (v >>> 8)) >>> 28

/-- `x.powf(y)` for `0 < x < 1`: `(value, certified)`, or `none` outside the
domain (`x < e^-64`, `y < 2^-36`).  Certified means the value is `powExact`'s;
otherwise it is within one binary32 step of it. -/
def powFast (x y : F32) : Option (F32 × Bool) := do
  let mx := F32.mant x
  let eb := F32.expo x
  let my := F32.mant y
  let eby := F32.expo y
  guard (eb + 23 < F32.bias && eby + 60 ≥ F32.bias)
  -- `x = t · 2^-k`, `t = mx / 2^23 ∈ [1, 2)`, `k ≥ 1`
  let k := F32.bias - 23 - eb
  let c := mx >>> 15
  let d := mx - c * 32768
  -- `ln t = ln(c/256) + ln(1 + u)`, `u = d / (c · 2^15) < 2^-8`
  let U := d * 536870912 / c
  let U2 := sq U
  let U3 := cube U
  let U4 := sq U2
  let lnu := (U + U3 / 3) - (U2 / 2 + U4 / 4)
  let lnt := (lnTab.get).getD (c - 256) 0 + lnu
  -- `-ln x = k · ln 2 − ln t`; error below `k/2 + 12` units (`ln 2`'s rounding
  -- `k` times, the table, the truncated squares, the omitted `u^5/5` ≤ 4).
  -- For an `f32` below 1 it is at least `2^-24`, i.e. `2^20` units.
  let NL := k * ln2Q - lnt
  guard (NL < c2p50)
  -- `-y ln x` with `y = my · 2^(eby − bias)`, `my` in 12-bit halves (each
  -- product below 2^62); a shift left only while the result can stay ≤ 2·npMax
  let hi := (my >>> 12) * NL
  let lo := (my &&& 4095) * NL
  let NP : Nat :=
    if eby + 12 ≤ F32.bias then
      let sh := F32.bias - eby
      (hi >>> (sh - 12)) + (lo >>> sh)
    else
      let e1 := eby + 12 - F32.bias
      if e1 ≥ 40 || hi > (npMax * 2) >>> e1 then npMax * 4
      else hi * F32.p2 e1 + (if e1 ≥ 12 then lo * F32.p2 (e1 - 12) else lo >>> (12 - e1))
  -- `y` rounded up, for the error bound
  let yc := if eby ≥ F32.bias then my * F32.p2 (Nat.min 40 (eby - F32.bias)) + 1
    else (my >>> (F32.bias - eby)) + 1
  let err := yc * (k / 2 + 12) + 4
  -- Past `e^-110` the value is `0`; certain when the error cannot bring it back
  -- (the error is below 2^-16 of `NP`, as `NL ≥ 2^20` units).
  if NP > npMax then return (0, NP > npMax + npMax / 1024)
  -- `e^-NP = 2^-n · e^-(i/128) · e^-s`, `s < 2^-7`
  let n := NP / ln2Q
  let r := NP - n * ln2Q
  let i := r >>> 37
  let s := r - i * c2p37
  let es := (Q + sq s / 2 + sq (sq s) / 24) - (s + cube s / 6)
  let R := mulQ ((expTab.get).getD i 0) es
  guard (R ≥ c2p42)
  -- `R · 2^(-n-44)` to 24 bits; certified unless within `err + n/2 + 24`
  -- units of a tie (`NP`'s error, `ln 2`'s `n` times, the table, the omitted
  -- `s^5/120` ≤ 5, the truncated squares and `mulQ`)
  let b := F32.bitLen R
  let drop := b - 24
  let low := R &&& (F32.p2 drop - 1)
  let half := F32.p2 (drop - 1)
  let dist := if low ≥ half then low - half else half - low
  let q := (R >>> drop) + (if low > half then 1 else 0)
  return (F32.norm false q (F32.pbias + drop - 44 - n) false, dist > err + n / 2 + 24)

/-- How many `powExact` calls one primitive may make (about half a second);
past it an uncertified `powFast` value stands, at most one binary32 step
away.  Only an adversarial input gets there: `powFast` certifies all but about
one call in five hundred, and refuses only `x ≥ 1` (a rounding excess over 1)
and bases below `e^-64`. -/
def exactBudget : Nat := 16384

/-- `x.powf(y)` for `x > 0`, `y > 0`, and the budget left. -/
def powF (x y : F32) (budget : Nat) : F32 × Nat :=
  if x == 0 || F32.isNeg x then (0, budget)
  else if y == F32.one then (x, budget)
  else if x == F32.one then (F32.one, budget)
  else
    match powFast x y with
    | some (v, true) => (v, budget)
    | some (v, false) => if budget > 0 then (powExact x y, budget - 1) else (v, 0)
    | none =>
      if budget > 0 then (powExact x y, budget - 1)
      -- `x > 1`: through `1/x`; a tiny `x` or `y`: its limit
      else if F32.lt F32.one x then
        match powFast (F32.div F32.one x) y with
        | some (v, _) => (F32.div F32.one v, 0)
        | none => (F32.one, 0)
      else if F32.lt x F32.one && F32.lt F32.one y then (0, 0) else (F32.one, 0)

/-- `x.powf(y)` for any `x` and `y ∈ [1, 128]`: a negative base gives a signed
power for an integral `y` and NaN (`none`) otherwise. -/
def powSigned (x y : F32) (budget : Nat) : Option F32 × Nat :=
  if !F32.isNeg x then let (v, b) := powF x y budget; (some v, b)
  else
    let my := F32.mant y
    let ey : Int := (F32.expo y : Int) - F32.bias
    -- `y ≥ 1`, so `ey ≥ -23`; integral iff the fraction bits are zero
    let integral := ey ≥ 0 || my % (2 ^ (-ey).toNat) == 0
    if !integral then (none, budget)
    else
      let n := if ey ≥ 0 then my * 2 ^ ey.toNat else my / 2 ^ (-ey).toNat
      let (v, b) := powF (F32.neg x) y budget
      (some (if n % 2 == 1 then F32.neg v else v), b)

/-! ## Applying -/

/-- `transform_light_source`: a point through `ts` (tiny-skia's `map_points`,
`x·sx + y·kx + tx`) and then relative to the filter region's origin. -/
def mapPt (ts : Mat) (ox oy : Int) (x y : F32) : F32 × F32 :=
  let sx := fFix ts.a 65536
  let ky := fFix ts.b 65536
  let kx := fFix ts.c 65536
  let sy := fFix ts.d 65536
  let px := F32.add (F32.add (F32.mul x sx) (F32.mul y kx)) (fFix ts.e 256)
  let py := F32.add (F32.add (F32.mul x ky) (F32.mul y sy)) (fFix ts.f 256)
  (F32.sub px (fInt ox), F32.sub py (fInt oy))

/-- Skia's `kAntiAliasThreshold` (0.016) and its inverse `fConeScale`. -/
def coneAA : F32 := F32.ofRat 16 1000
def coneScale : F32 := F32.div F32.one coneAA

/-- T101: the soft `limitingConeAngle` edge of Skia's `SkSpotLight::lightColor`
(Chromium, the suite's reference PNGs), in place of resvg's hard cut.  `c` is
the cone's cosine, `m = -L·S ≥ c` and `f = m^specularExponent`; within
`coneAA` of the edge `f` ramps linearly to zero:
`f · ((m - c) · coneScale)`. -/
def coneFade (c m f : F32) : F32 :=
  if F32.lt m (F32.add c coneAA) then F32.mul f (F32.mul (F32.sub m c) coneScale) else f

/-- Run one lighting primitive on `src` (only its alpha is read).  The result
is `rw × rh`, anchored at the layer origin like every filter image; `(ox, oy)`
is the filter region's origin in layer pixels and `ts` the user-to-layer
matrix.  Less than 3×3 input: transparent black, as resvg. -/
def apply (p : Params) (sinCos : F32 → F32 × F32) (ts : Mat) (ox oy : Int) (rw rh : Nat)
    (src : Canvas) : Canvas := Id.run do
  let w := src.w
  let h := src.h
  let mut px : Array Nat := Array.replicate (rw * rh) 0
  if w < 3 || h < 3 then return ⟨rw, rh, px⟩
  let sz := F32.div (sqrtF (F32.add (F32.mul (fFix ts.a 65536) (fFix ts.a 65536))
    (F32.mul (fFix ts.d 65536) (fFix ts.d 65536)))) sqrt2F
  -- The light in layer pixels; for a distant light, the fixed vector.
  let (fixedL, origin, dir, coneCos, spotSe) : Option V3 × V3 × V3 × Option F32 × F32 :=
    match p.light with
    | .distant az el =>
      let (sa, ca) := sinCos (toRad az)
      let (se, ce) := sinCos (toRad el)
      (some ⟨F32.mul ca ce, F32.mul sa ce, se⟩, default, default, none, F32.one)
    | .point x y z =>
      let (lx, ly) := mapPt ts ox oy x y
      (none, ⟨lx, ly, F32.mul z sz⟩, default, none, F32.one)
    | .spot x y z qx qy qz se cone =>
      let (lx, ly) := mapPt ts ox oy x y
      let (tx, ty) := mapPt ts ox oy qx qy
      let o : V3 := ⟨lx, ly, F32.mul z sz⟩
      let d := (V3.sub ⟨tx, ty, F32.mul qz sz⟩ o).norm
      (none, o, d, cone.map (fun c => (sinCos (toRad c)).2), se)
  let isSpot := match p.light with | .spot .. => true | _ => false
  let ss255 := F32.div p.ss F32.c255
  -- Per-primitive tables of exact `F32` values, so that the pixel loop only
  -- does the operations that depend on more than one small integer:
  -- pixel coordinates; `a / 255 · ss` per alpha; and a normal component
  -- `-n · (ss/255) · f` per `n ∈ [-1020, 1020]` and factor class
  -- (1/4, 1/3, 1/2, 2/3).
  let coord : Array F32 := (Array.range (Nat.max w h)).map F32.ofNat
  let nzTab : Array F32 := (Array.range 256).map fun a =>
    F32.mul (F32.div (F32.ofNat a) F32.c255) p.ss
  let fcls : Array F32 := #[F32.ofRat 1 4, F32.ofRat 1 3, F32.ofRat 1 2, F32.ofRat 2 3]
  let nTab : Array F32 := (Array.range (4 * 2041)).map fun i =>
    F32.mul (F32.mul (fInt (1020 - ((i % 2041 : Nat) : Int))) ss255) (fcls.getD (i / 2041) 0)
  let specOne := nearOne p.se
  let mut budget := exactBudget
  let alpha := fun (x y : Nat) => ((src.px.getD (y * w + x) 0) &&& 255 : Nat)
  for y in [0:h] do
    let y0 := if y == 0 then 0 else y - 1
    let y1 := if y + 1 == h then y else y + 1
    let yEdge := y == 0 || y + 1 == h
    for x in [0:w] do
      let x0 := if x == 0 then 0 else x - 1
      let x1 := if x + 1 == w then x else x + 1
      let xEdge := x == 0 || x + 1 == w
      -- Sobel over the rows/columns that exist, centre weight 2.
      let mut nx : Int := 0
      let mut ny : Int := 0
      for j in [y0:y1 + 1] do
        let wt : Int := if j == y then 2 else 1
        nx := nx + wt * ((alpha x1 j : Int) - alpha x0 j)
      for i in [x0:x1 + 1] do
        let wt : Int := if i == x then 2 else 1
        ny := ny + wt * ((alpha i y1 : Int) - alpha i y0)
      let (cx, cy) : Nat × Nat :=
        if xEdge && yEdge then (3, 3) else if yEdge then (1, 2) else if xEdge then (2, 1) else (0, 0)
      let L : V3 := match fixedL with
        | some l => l
        | none =>
          (V3.sub origin ⟨coord.getD x 0, coord.getD y 0, nzTab.getD (alpha x y) 0⟩).norm
      -- the surface normal `(-nx·ss/255·fx, -ny·ss/255·fy, 1)`, `none` when flat
      let N : Option V3 :=
        if nx == 0 && ny == 0 then none
        else some ⟨nTab.getD (cx * 2041 + (nx + 1020).toNat) 0,
                   nTab.getD (cy * 2041 + (ny + 1020).toNat) 0, F32.one⟩
      let mut kf : Option F32 := none
      if !p.specular then
        kf := some <| F32.mul p.k <| match N with
          | none => L.z
          | some n => F32.div (V3.dot n L) n.len
      else
        let H : V3 := ⟨L.x, L.y, F32.add L.z F32.one⟩
        let hl := H.len
        if hl == 0 then kf := some 0
        else
          let ndh := match N with
            | none => F32.div H.z hl
            | some n => F32.div (F32.div (V3.dot n H) n.len) hl
          if specOne then kf := some (F32.mul p.k ndh)
          else
            let (kk, b) := powSigned ndh p.se budget
            budget := b
            kf := kk.map (F32.mul p.k)
      -- `light_color`
      let mut (cr, cg, cb) := (p.r, p.g, p.b)
      if isSpot then
        let m := F32.neg (V3.dot L dir)
        if F32.le m 0 then (cr, cg, cb) := (0, 0, 0)
        else if (match coneCos with | some c => F32.lt m c | none => false) then
          (cr, cg, cb) := (0, 0, 0)
        else
          let (f0, b) := powF m spotSe budget
          budget := b
          let f := match coneCos with
            | some c => coneFade c m f0
            | none => f0
          (cr, cg, cb) := (compute p.r (some f), compute p.g (some f), compute p.b (some f))
      let r := compute cr kf
      let g := compute cg kf
      let b := compute cb kf
      let a := if p.specular then Nat.max r (Nat.max g b) else 255
      let i := y * rw + x
      px := px.setIfInBounds i (Canvas.pack r g b a)
  return ⟨rw, rh, px⟩

end Lighting
end LeanSvg
