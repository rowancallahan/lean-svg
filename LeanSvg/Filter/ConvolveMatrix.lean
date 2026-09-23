import LeanSvg.Filter

/-!
# `feConvolveMatrix` (T68): the pixel algorithm

A port of resvg 0.48.1's `filter/convolve_matrix.rs::apply`, kept in its own
file per `tasks/T68-feconvolve.md` (other agents are adding other primitives
to `LeanSvg/Filter.lean`/`LeanSvg/FilterApply.lean` concurrently, so this
primitive's bulk stays out of those two shared files).

resvg's `apply_convolve_matrix` first converts the input into the primitive's
colour space and, only when `preserveAlpha`, demultiplies it (comment: "Input
image pixels should have a premultiplied alpha when `preserve_alpha=false`").
The per-pixel formula below then produces an already-premultiplied result
regardless of `preserveAlpha` (the colour channels are scaled by the output
alpha at the end), which is why resvg never re-premultiplies afterwards — this
file matches that, so `FilterApply.runPrim`'s case is a straight call.
-/

namespace LeanSvg
namespace ConvolveMatrix

open Filter

@[inline] def cR (p : Nat) : Nat := p >>> 24
@[inline] def cG (p : Nat) : Nat := (p >>> 16) &&& 255
@[inline] def cB (p : Nat) : Nat := (p >>> 8) &&& 255
@[inline] def cA (p : Nat) : Nat := p &&& 255

/-- `demultiply_alpha`: per pixel, non-premultiplied colour channels, alpha
unchanged (the `a == 0` pixel is already `0`). -/
def demultiply (cv : Canvas) : Canvas :=
  { cv with px := cv.px.map (fun p =>
      let a := cA p
      if a == 0 then p
      else Canvas.pack (Canvas.unpremul (cR p) a) (Canvas.unpremul (cG p) a)
        (Canvas.unpremul (cB p) a) a) }

/-- `f32_bound(min, val, max)`: `val > max → max`, `val ≥ min → val`, else
`min`. -/
def f32Bound (lo v hi : F32) : F32 := if F32.gt v hi then hi else if F32.ge v lo then v else lo

/-- `(v * 255.0 + 0.5) as u8`: resvg's rounding cast in `convolve_matrix::apply`
(a round, unlike `Filter.f32TruncU8`'s plain truncation elsewhere).  `v` is
always in `[0, 1]` here (`f32Bound`'s result). -/
def f32Round255 (v : F32) : Nat :=
  Nat.min 255 (f32Floor (F32.add (F32.mul v F32.c255) (ofRatBig 1 2)))

/-- resvg's `convolve_matrix::apply`, on a canvas already converted to the
primitive's colour space and, when `preserveAlpha`, demultiplied by the
caller's `.into lin` + this file's `demultiply`.  `order = (columns, rows)`,
`kernel` row-major (`order.1 * order.2` cells, already validated by
`Filter.convertConvolveMatrix`), `target = (targetX, targetY)`. -/
def run (order : Nat × Nat) (kernel : Array F32) (divisor bias : F32) (target : Nat × Nat)
    (edge : Nat) (preserveAlpha : Bool) (cv : Canvas) : Canvas := Id.run do
  let (cols, rows) := order
  let (tx, ty) := target
  let w := cv.w
  let h := cv.h
  let src := if preserveAlpha then demultiply cv else cv
  let widthMax : Int := (w : Int) - 1
  let heightMax : Int := (h : Int) - 1
  let mut out : Array Nat := Array.replicate (w * h) 0
  for y in [0:h] do
    for x in [0:w] do
      let mut newR : F32 := 0
      let mut newG : F32 := 0
      let mut newB : F32 := 0
      let mut newA : F32 := 0
      for ky in [0:rows] do
        for kx in [0:cols] do
          let tx0 : Int := (x : Int) - (tx : Int) + (kx : Int)
          let ty0 : Int := (y : Int) - (ty : Int) + (ky : Int)
          let coord? : Option (Nat × Nat) :=
            match edge with
            | 2 =>
              if tx0 < 0 || tx0 > widthMax || ty0 < 0 || ty0 > heightMax then none
              else some (tx0.toNat, ty0.toNat)
            | 1 => some ((Int.emod tx0 (w : Int)).toNat, (Int.emod ty0 (h : Int)).toNat)
            | _ =>
              let cx := if tx0 < 0 then 0 else if tx0 > widthMax then widthMax else tx0
              let cy := if ty0 < 0 then 0 else if ty0 > heightMax then heightMax else ty0
              some (cx.toNat, cy.toNat)
          match coord? with
          | none => pure ()
          | some (px, py) =>
            -- `matrix.get(columns - ox - 1, rows - oy - 1)`, kernel flipped.
            let k := kernel.getD ((rows - ky - 1) * cols + (cols - kx - 1)) 0
            let p := src.px.getD (py * w + px) 0
            newR := F32.add newR (F32.mul (byteNorm.getD (cR p) 0) k)
            newG := F32.add newG (F32.mul (byteNorm.getD (cG p) 0) k)
            newB := F32.add newB (F32.mul (byteNorm.getD (cB p) 0) k)
            if !preserveAlpha then
              newA := F32.add newA (F32.mul (byteNorm.getD (cA p) 0) k)
      let finalA : F32 :=
        if preserveAlpha then byteNorm.getD (cA (src.px.getD (y * w + x) 0)) 0
        else F32.add (F32.div newA divisor) bias
      let boundedA := f32Bound 0 finalA F32.one
      let chan := fun (v : F32) =>
        let v := F32.add (F32.div v divisor) (F32.mul bias finalA)
        f32Round255 (if preserveAlpha then F32.mul (f32Bound 0 v F32.one) boundedA
                     else f32Bound 0 v boundedA)
      out := out.setIfInBounds (y * w + x)
        (Canvas.pack (chan newR) (chan newG) (chan newB) (f32Round255 boundedA))
  return { cv with px := out }

end ConvolveMatrix
end LeanSvg
