import LeanSvg.Canvas
import LeanSvg.Bytes
import LeanSvg.Fixed

/-!
# `feMorphology` (T69)

A port of usvg's `convert_morphology` (`parser/filter.rs`) and resvg's
`filter::morphology::apply` (`filter/morphology.rs`), matched exactly:
resvg's structuring element is a rectangle, so its direct 2-D window (an
`O(area · r²)` scan) is separable into two 1-D passes (`O(area · r)`) — the
same min/max, since `min`/`max` over a rectangle `[x0,x1] × [y0,y1]` is
`min`/`max` over `y ∈ [y0,y1]` of (`min`/`max` over `x ∈ [x0,x1]`), the window
clipping to the image applying independently on each axis either way.

This file only needs `Bytes`/`Fixed` (to parse `radius`) and `Canvas` (to run
the two passes); it does not import `LeanSvg.Filter` or `LeanSvg.FilterApply`,
since both of those import it (`Kind.morphology` and `FilterApply.runPrim`'s
case are the one-line hooks left in place there), so importing either back
here would cycle. Its declarations join their namespaces directly instead of
nesting under a `Morphology` namespace of their own, matching how every other
primitive's helpers (`stdDevOf`, `boxBlur`, …) sit directly in `Filter`/
`FilterApply`.
-/

namespace LeanSvg
namespace Filter

open Bytes

/-- `usvg::filter::MorphologyOperator`. -/
inductive MorphOp where
  | erode
  | dilate
deriving Inhabited, Repr, BEq

/-- `round(±mant · 10^e · sc)` on the 16.16 grid for a decimal literal times an
`Fx` (8.8) `primitiveUnits` scale.  The same construction as `Filter.decTimes`
(duplicated rather than shared, see the module docstring). -/
def morphScaled (neg : Bool) (mant : Nat) (e : Int) (sc : Fx) : Int :=
  let e := if e > 60 then 60 else if e < -60 then -60 else e
  let num : Int := (mant : Int) * sc * 256
  let v : Int := if e ≥ 0 then num * (10 ^ e.toNat : Nat)
    else Int.ediv (2 * num + (10 ^ (-e).toNat : Nat)) (2 * (10 ^ (-e).toNat : Nat))
  let lim := Fx.maxVal * 256
  let v := if v > lim then lim else if v < -lim then -lim else v
  if neg then -v else v

/-- `operator`: `"dilate"` or anything else (including absent), which is
`"erode"` (usvg's `unwrap_or("erode")` then a wildcard match). -/
def morphOpOf (v : Option ByteArray) : MorphOp :=
  match v with
  | some raw => if eqAscii (trim raw) "dilate" then .dilate else .erode
  | none => .erode

/-- `radius`, all-or-nothing (usvg's generic `Vec<f32>` attribute parse: one
unreadable item drops the whole list, unlike `stdDeviation`'s bespoke
partial-tolerant parser), as raw decimal triples. -/
def morphDecList (bs : ByteArray) : Option (Array (Bool × Nat × Int)) := Id.run do
  let t := trim bs
  let mut out : Array (Bool × Nat × Int) := #[]
  let mut i := 0
  for _ in [0:t.size + 1] do
    i := skipWsComma t i
    if i ≥ t.size then break
    match parseDecimal t i with
    | some (neg, m, e, j) =>
      if out.size < 4096 then out := out.push (neg, m, e)
      i := j
    | none => return none
  return some out

/-- `convert_morphology`'s radius resolution.  Default (attribute absent, an
unreadable list, or a list whose length isn't 1 or 2) is `(1, 1)` scaled by
`primitiveUnits`, i.e. `(scx, scy)`.  A list of one number is `rx = ry`; two
numbers are `rx, ry`.  Then: if both are ~zero, both become `1`; if only one
is ~zero, only that one becomes `1` (not in the spec, matches Chrome/Safari);
finally, if either remaining value is negative, *both* fall back to the outer
default (usvg's `PositiveF32::new(…).unwrap()` on the pre-declared default,
discarding a still-valid other value).  16.16 user-space lengths. -/
def radiusOf (v : Option ByteArray) (scx scy : Fx) : Int × Int :=
  let one : Bool × Nat × Int := (false, 1, 0)
  let dflt := (morphScaled one.1 one.2.1 one.2.2 scx, morphScaled one.1 one.2.1 one.2.2 scy)
  match v with
  | none => dflt
  | some raw =>
    match morphDecList raw with
    | none => dflt
    | some ds =>
      let pair? : Option ((Bool × Nat × Int) × (Bool × Nat × Int)) := match ds with
        | #[a] => some (a, a)
        | #[a, b] => some (a, b)
        | _ => none
      match pair? with
      | none => dflt
      | some (a, b) =>
        let za := a.2.1 == 0
        let zb := b.2.1 == 0
        let a := if za then one else a
        let b := if zb then one else b
        if a.1 || b.1 then dflt
        else (morphScaled a.1 a.2.1 a.2.2 scx, morphScaled b.1 b.2.1 b.2.2 scy)

/-- `ceil((r/65536) · (sc/65536))` in whole device pixels: `r` a 16.16
user-space radius (already `primitiveUnits`-scaled), `sc` the 16.16 device
scale (`FilterApply.scaleOf`). `0` when either is not (strictly) positive —
never truncates a genuinely positive product to `0` (the `+ (den - 1)`
numerator only rounds down when the numerator itself is exactly a multiple of
the denominator or `0`, and here `a > 0` rules that second case out). -/
def morphCeil (r : Int) (sc : Nat) : Nat :=
  if r ≤ 0 || sc == 0 then 0
  else
    let a := r.toNat * sc
    (a + 4294967295) / 4294967296

/-- `resvg::filter::mod::apply_morphology`'s `!(rx > 0.0 && ry > 0.0)` guard,
on the exact (not yet rounded) device values: `none` clears the whole layer
(resvg's `pixmap.clear()`), matching a degenerate transform (`scx`/`scy` zero)
or a radius that only *parsed* to something non-positive (which `radiusOf`
avoids on its own, `convert_morphology`'s own `PositiveF32` guarantees it
never happens from parsing alone) the same way resvg's `f32` check would. -/
def morphDev (rx ry : Int) (scx scy : Nat) : Option (Nat × Nat) :=
  if rx ≤ 0 || ry ≤ 0 || scx == 0 || scy == 0 then none
  else some (morphCeil rx scx, morphCeil ry scy)

end Filter

namespace FilterApply

/-- One min/max pass along rows (`horiz`) or columns.  The window at output
position `i` is source indices `[i - target, i - target + win - 1]`, clipped
to `[0, n)`: resvg's asymmetric `columns`/`target_x` (or `rows`/`target_y`)
window, applied to premultiplied channel bytes directly (as resvg's `RGBA8`
min/max does, no demultiply). -/
def morphPass (cv : Canvas) (target win : Nat) (horiz isMin : Bool) : Canvas := Id.run do
  if win == 0 then return cv
  let w := cv.w
  let h := cv.h
  let (n, lines, step, lstep) := if horiz then (w, h, 1, w) else (h, w, w, 1)
  let src := cv.px
  let mut out := src
  for l in [0:lines] do
    let base := l * lstep
    for i in [0:n] do
      let loZ : Int := (i : Int) - (target : Int)
      let hiZ : Int := loZ + (win : Int) - 1
      let lo := if loZ < 0 then 0 else loZ.toNat
      let hi := Nat.min (n - 1) (if hiZ < 0 then 0 else hiZ.toNat)
      let mut r := if isMin then 255 else 0
      let mut g := if isMin then 255 else 0
      let mut b := if isMin then 255 else 0
      let mut al := if isMin then 255 else 0
      for k in [lo:hi + 1] do
        let p := src.getD (base + k * step) 0
        let cr := p >>> 24
        let cg := (p >>> 16) &&& 255
        let cb := (p >>> 8) &&& 255
        let ca := p &&& 255
        if isMin then
          r := Nat.min r cr; g := Nat.min g cg; b := Nat.min b cb; al := Nat.min al ca
        else
          r := Nat.max r cr; g := Nat.max g cg; b := Nat.max b cb; al := Nat.max al ca
      out := out.setIfInBounds (base + i * step) (Canvas.pack r g b al)
  return { cv with px := out }

/-- `morphology::apply`: `columns`/`rows` capped to the image size (no point
making the matrix larger than the image, and the reason this stays bounded by
the layer area regardless of `radius`), then one separable pass per axis. -/
def morphologyApply (op : Filter.MorphOp) (dx dy : Nat) (cv : Canvas) : Canvas :=
  let isMin := match op with | .erode => true | .dilate => false
  let columns := Nat.min (2 * dx) cv.w
  let rows := Nat.min (2 * dy) cv.h
  let c := morphPass cv (columns / 2) columns true isMin
  morphPass c (rows / 2) rows false isMin

end FilterApply
end LeanSvg
