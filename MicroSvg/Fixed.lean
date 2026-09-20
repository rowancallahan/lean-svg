import MicroSvg.Bytes

/-!
# Fixed-point arithmetic

There are no floating-point numbers anywhere in the renderer.  Coordinates are
`Fx`: integers in units of 1/256 of a pixel.  Transform matrices use 16
fractional bits.  Every parsed number is clamped to `Fx.maxVal`, so a file
cannot inject `NaN`, infinity, or a value large enough to make later products
expensive.  Lean's `Int` is arbitrary precision, so overflow is impossible by
construction; the clamp is purely a cost bound.
-/

namespace MicroSvg

/-- Fixed-point number with 8 fractional bits. -/
abbrev Fx := Int

namespace Fx

def one : Fx := 256

/-- Largest magnitude any coordinate can have: 2^30 (about 4 million pixels).
Chosen so values stay in Lean's unboxed `Int` range and products stay small. -/
def maxVal : Fx := 1073741824

def clamp (a : Fx) : Fx :=
  if a > maxVal then maxVal else if a < -maxVal then -maxVal else a

def ofNat (n : Nat) : Fx := clamp ((n : Int) * 256)
def ofInt (n : Int) : Fx := clamp (n * 256)

/-- Floor division, so results are consistent for negative values. -/
def mul (a b : Fx) : Fx := clamp (Int.ediv (a * b) 256)
def div (a b : Fx) : Fx := if b = 0 then 0 else clamp (Int.ediv (a * 256) b)
def floor (a : Fx) : Int := Int.ediv a 256
def ceil (a : Fx) : Int := -(Int.ediv (-a) 256)
def round (a : Fx) : Int := Int.ediv (a + 128) 256
def abs (a : Fx) : Fx := if a < 0 then -a else a
def min (a b : Fx) : Fx := if a ≤ b then a else b
def max (a b : Fx) : Fx := if a ≤ b then b else a

/-- √(x² + y²) via integer square root. -/
def hypot (x y : Fx) : Fx :=
  Int.ofNat (Nat.sqrt (x.natAbs * x.natAbs + y.natAbs * y.natAbs))

/-- Multiply by a 16.16 fixed-point factor. -/
def scale16 (a : Fx) (s : Int) : Fx := clamp (Int.ediv (a * s) 65536)

end Fx

/-- `round (mant * 10 ^ exp10 * scale)`, rounding halves away from zero and
saturating at `cap`.  Used to land a parsed decimal on whatever fixed-point
grid the caller wants: 1/256 for coordinates, 1/10^18 for opacity.

Because the grid is exact integer arithmetic, a decimal that sits exactly on a
half-way point of the target grid is detected as such and rounded up; no
intermediate value is ever lost.  Exponents past ±60 saturate, which is what
bounds the cost of `10 ^ exp10` for adversarial inputs. -/
def scaleDecimal (mant : Nat) (exp10 : Int) (scale cap : Nat) : Nat :=
  if mant == 0 then 0
  else if exp10 > 60 then cap
  else if exp10 < -60 then 0
  else if exp10 ≥ 0 then Nat.min cap (mant * scale * 10 ^ exp10.toNat)
  else Nat.min cap ((mant * scale * 2 / 10 ^ (-exp10).toNat + 1) / 2)

open Bytes in
/-- Lex a decimal number in SVG/CSS syntax starting at byte `i`.  Returns the
sign, the mantissa, the base-10 exponent and the index just past the number —
i.e. the *exact* value `±mant * 10 ^ exp10`, with no grid chosen yet.

Cost bounds (all deliberate): only the first 18 significant digits are kept,
further digits only shift the exponent; exponents saturate.  So `1e999999999`
and a megabyte of digits both lex in linear time and produce a bounded
mantissa. -/
def parseDecimal (bs : ByteArray) (i : Nat) : Option (Bool × Nat × Int × Nat) := Id.run do
  let mut j := i
  let mut neg := false
  let c0 := at' bs j
  if c0 == 45 then
    neg := true
    j := j + 1
  else if c0 == 43 then
    j := j + 1
  let mut mant : Nat := 0
  let mut sig : Nat := 0
  let mut exp10 : Int := 0
  let mut any := false
  -- integer part
  for _ in [j:bs.size] do
    let c := at' bs j
    if !isDigit c then break
    any := true
    let d := c.toNat - 48
    if mant == 0 && d == 0 then
      pure ()
    else if sig < 18 then
      mant := mant * 10 + d
      sig := sig + 1
    else
      exp10 := exp10 + 1
    j := j + 1
  -- fractional part
  if at' bs j == 46 && (isDigit (at' bs (j + 1)) || any) then
    j := j + 1
    for _ in [j:bs.size] do
      let c := at' bs j
      if !isDigit c then break
      any := true
      let d := c.toNat - 48
      if sig < 18 then
        mant := mant * 10 + d
        exp10 := exp10 - 1
        if mant != 0 then sig := sig + 1
      j := j + 1
  if !any then return none
  -- exponent
  let ce := at' bs j
  if ce == 101 || ce == 69 then
    let mut k := j + 1
    let mut eneg := false
    if at' bs k == 45 then
      eneg := true
      k := k + 1
    else if at' bs k == 43 then
      k := k + 1
    if isDigit (at' bs k) then
      let mut e : Nat := 0
      for _ in [k:bs.size] do
        let c := at' bs k
        if !isDigit c then break
        if e < 100000 then e := e * 10 + (c.toNat - 48)
        k := k + 1
      exp10 := if eneg then exp10 - e else exp10 + e
      j := k
  return some (neg, mant, exp10, j)

/-- Parse a decimal number in SVG/CSS syntax starting at byte `i`, on the `Fx`
grid of 1/256 px.  Returns the value and the index just past the number. -/
def parseNumber (bs : ByteArray) (i : Nat) : Option (Fx × Nat) :=
  match parseDecimal bs i with
  | none => none
  | some (neg, mant, exp10, j) =>
    let r : Fx := Fx.clamp (Int.ofNat (scaleDecimal mant exp10 256 Fx.maxVal.toNat))
    some (if neg then -r else r, j)

open Bytes in
/-- Parse a length: a number with an optional unit.  Absolute units are converted
to CSS pixels.  Percentages are rejected (no context to resolve them). -/
def parseLength (bs : ByteArray) (i : Nat) : Option (Fx × Nat) :=
  match parseNumber bs i with
  | none => none
  | some (v, j) =>
    if startsWith bs j "px" then some (v, j + 2)
    else if startsWith bs j "pt" then some (Int.ediv (v * 4) 3, j + 2)
    else if startsWith bs j "pc" then some (v * 16, j + 2)
    else if startsWith bs j "mm" then some (Int.ediv (v * 960) 254, j + 2)
    else if startsWith bs j "cm" then some (Int.ediv (v * 9600) 254, j + 2)
    else if startsWith bs j "in" then some (v * 96, j + 2)
    else if startsWith bs j "em" then some (v * 16, j + 2)
    else if startsWith bs j "ex" then some (v * 8, j + 2)
    else if at' bs j == 37 then none
    else some (v, j)

/-- Parse a whole attribute value as a single number (surrounding whitespace allowed). -/
def parseNumberAll (bs : ByteArray) : Option Fx :=
  let t := Bytes.trim bs
  match parseNumber t 0 with
  | some (v, j) => if j == t.size then some v else none
  | none => none

/-- Parse a whole attribute value as a single length. -/
def parseLengthAll (bs : ByteArray) : Option Fx :=
  let t := Bytes.trim bs
  match parseLength t 0 with
  | some (v, j) => if j == t.size then some v else none
  | none => none

/-- Parse a whitespace/comma separated list of numbers. -/
def parseNumberList (bs : ByteArray) : Array Fx := Id.run do
  let mut out : Array Fx := #[]
  let mut i := 0
  for _ in [0:bs.size + 1] do
    i := Bytes.skipWsComma bs i
    if i ≥ bs.size then break
    match parseNumber bs i with
    | some (v, j) =>
      out := out.push v
      i := j
    | none => break
  return out

end MicroSvg
