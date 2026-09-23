import LeanSvg.Filter

/-!
# `feComponentTransfer`'s `gamma` function (T70): a fixed-point `powf`

resvg's `gamma` transfer is `amplitude * c.powf(exponent) + offset` in `f32`
(`crates/resvg/src/filter/component_transfer.rs`), `c` a channel byte
normalised to `[0, 1]`.  `powF32` below is exact for the exponents that occur
in practice — an integer of small magnitude, which is a repeated `F32.mul` or
its reciprocal — and otherwise falls back to `exp(exponent · ln(base))`,
computed once per call in a `2^128`-scaled fixed point (the same style as
`Filter.sinCosF32`), rounded to a binary32 only at the end.  Every base here
is a byte-normalised channel in `(0, 1]`, so `ln` is always finite; the
fallback path has no test coverage in the resvg suite (every corpus `gamma`
uses `exponent="1"`, handled exactly), so it is a best-effort match rather
than a verified one.
-/

namespace LeanSvg
namespace Filter

/-- Bits of fixed-point precision `lnBig`/`expSmall` carry: ample for a
binary32 result (24 bits of mantissa). -/
def lnScale : Nat := 2 ^ 128

/-- `ln 2` to 50 decimal digits, `2^128`-scaled once. -/
def ln2Num : Nat := 69314718055994530941723212145817656807550013436026
def ln2Den : Nat := 10 ^ 50
def ln2Scaled : Int := (ln2Num * lnScale / ln2Den : Nat)

/-- `ln c` for `c > 0`, as a `lnScale`-scaled `Int`.  `c = M · 2^K` exactly
(`M` the 24-bit mantissa, `K = eb - bias`); writing `M = 2^23·(1+x)` reduces
this to `K·ln2 + ln(1+x)`, and `ln(1+x)` is the atanh series `2·atanh(u)` at
`u = x/(x+2) = f/(f+2^24) ∈ [0, 1/3)` (`f = M - 2^23`), which converges in a
few dozen terms across that whole range. -/
def lnBig (c : F32) : Int := Id.run do
  let M := F32.mant c
  let eb := F32.expo c
  let K : Int := (eb : Int) - (F32.bias : Int)
  let f := M - 8388608
  let S := lnScale
  let U : Nat := f * S / (f + 16777216)
  let U2 : Nat := U * U / S
  let mut term := U
  let mut sum := U
  for k in [1:40] do
    term := term * U2 / S
    sum := sum + term / (2 * k + 1)
  return (K + 23) * ln2Scaled + 2 * (sum : Int)

/-- `exp(r)` for `|r| ≤ ln2Scaled/2` (`lnScale`-scaled in, `lnScale`-scaled
out, as a plain Taylor sum: this range is small enough that ~30 terms are far
more than a binary32 needs). -/
def expSmall (r : Int) : Nat := Id.run do
  let S : Int := (lnScale : Int)
  let mut term := S
  let mut sum := S
  for k in [1:30] do
    term := Int.ediv (term * r) (S * (k : Int))
    sum := sum + term
  return sum.toNat

/-- `base ^ exponent` for `base, exponent` real via `exp(exponent · ln base)`:
range-reduce `exponent · ln base = n·ln2 + r` and combine `2^n` (exact) with
`exp(r)` (`expSmall`).  `n` is clamped to ±300, far past where the result
would saturate a binary32 either way. -/
def powGeneral (base exp : F32) : F32 :=
  let lnC := lnBig base
  let (negE, numE, denE) := f32Rat exp
  let eScaledN : Nat := numE * lnScale / denE
  let eScaled : Int := if negE then -(eScaledN : Int) else (eScaledN : Int)
  let y : Int := Int.ediv (eScaled * lnC) (lnScale : Int)
  let n : Int := if y ≥ 0 then Int.ediv (2 * y + ln2Scaled) (2 * ln2Scaled)
                 else -(Int.ediv (2 * (-y) + ln2Scaled) (2 * ln2Scaled))
  let r : Int := y - n * ln2Scaled
  if n > 300 then ofRatBig (10 ^ 40) 1
  else if n < -300 then 0
  else
    let E := expSmall r
    if n ≥ 0 then ofRatBig (E * 2 ^ n.toNat) lnScale
    else ofRatBig E (lnScale * 2 ^ (-n).toNat)

/-- `base.powf(exp)` (resvg's `f32::powf`).  `0^0 = 1` and `0^negative`
saturates rather than models an actual infinity, matching what the
`amplitude · c^e + offset` formula would clamp to after `f32_bound` anyway.
An exponent that is exactly a small integer (the common case: `gamma` is
almost always used with a whole-number exponent) is computed exactly by
repeated multiplication instead of the transcendental fallback. -/
def powF32 (base exp : F32) : F32 :=
  if exp == 0 then F32.one
  else if base == 0 then (if F32.isNeg exp then ofRatBig (10 ^ 40) 1 else 0)
  else if base == F32.one then F32.one
  else
    let negE := F32.isNeg exp
    let ea := if negE then F32.neg exp else exp
    let n := f32Floor ea
    if n ≤ 64 && F32.ofNat n == ea then
      let r := Id.run do
        let mut r := F32.one
        for _ in [0:n] do r := F32.mul r base
        return r
      if negE then F32.div F32.one r else r
    else powGeneral base exp

end Filter
end LeanSvg
