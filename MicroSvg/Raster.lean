import MicroSvg.Geom

/-!
# Rasterizer

A signed-area accumulation rasterizer (the scheme used by font-rs and
stb_truetype), done entirely in `Nat` arithmetic.

For each edge and each pixel row it crosses, the edge's contribution to every
column is the exact area of the row-band that lies to the right of the edge.
Contributions are stored as differences so that a prefix sum along the row
yields the signed winding-weighted coverage of every pixel.  Coverage is then
`min(|sum|, 1)` for the nonzero rule or a triangle-wave fold for even-odd.

Edges are clipped to the shape's bounding box intersected with the canvas, so
all coordinates inside the hot loop are non-negative and fit in Lean's unboxed
63-bit `Nat`.  Full coverage of a pixel is `65536`.
-/

namespace MicroSvg
namespace Raster

/-- Coverage mask for a rectangular region of the canvas. -/
structure Mask where
  x0 : Nat
  y0 : Nat
  w : Nat
  h : Nat
  /-- `w * h` entries, each in `[0, 65536]`. -/
  cov : Array Nat
deriving Inhabited

/-- `512 · ∫₀¹ max(0, k − x(t)) dt` for `x(t)` linear from `xl` to `xr` (`xl ≤ xr`). -/
@[inline] def r2 (xl xr k : Nat) : Nat :=
  if k ≤ xl then 0
  else if k ≥ xr then 512 * k - 256 * (xl + xr)
  else 256 * (k - xl) * (k - xl) / (xr - xl)

/-- Accumulate one edge piece with `0 ≤ xa, xb ≤ bwFx` and `ya < yb`, all in `Fx`
relative to the mask origin. -/
def accumPiece (acc : Array Int) (stride : Nat) (dir : Int) (xa ya xb yb : Nat) :
    Array Int := Id.run do
  let mut acc := acc
  if yb ≤ ya then return acc
  let dyTotal := yb - ya
  let rowStart := ya / 256
  let rowEnd := (yb - 1) / 256
  for r in [rowStart:rowEnd + 1] do
    let yt := Nat.max ya (r * 256)
    let yb' := Nat.min yb ((r + 1) * 256)
    let dy := yb' - yt
    let xt := if xb ≥ xa then xa + (xb - xa) * (yt - ya) / dyTotal
              else xa - (xa - xb) * (yt - ya) / dyTotal
    let xu := if xb ≥ xa then xa + (xb - xa) * (yb' - ya) / dyTotal
              else xa - (xa - xb) * (yb' - ya) / dyTotal
    let xl := Nat.min xt xu
    let xr := Nat.max xt xu
    let colStart := xl / 256
    let colEnd := if xr ≤ xl then colStart else (xr - 1) / 256
    let base := r * stride
    let full := dy * 256
    let mut prev : Nat := 0
    for c in [colStart:colEnd + 1] do
      let cov := dy * (r2 xl xr ((c + 1) * 256) - r2 xl xr (c * 256)) / 512
      let idx := base + c
      acc := acc.setIfInBounds idx (acc.getD idx 0 + dir * ((cov : Int) - (prev : Int)))
      prev := cov
    let idx := base + colEnd + 1
    acc := acc.setIfInBounds idx (acc.getD idx 0 + dir * ((full : Int) - (prev : Int)))
  return acc

/-- Accumulate an edge given in mask-relative `Fx` coordinates, clipping it to
`[0, bwFx] × [0, bhFx]`.  Parts left of the mask are projected onto its left
edge (which preserves winding for every visible pixel); parts above or below
are discarded. -/
def accumEdge (acc : Array Int) (stride bwFx bhFx : Nat) (p q : Pt) : Array Int := Id.run do
  if p.y == q.y then return acc
  let dir : Int := if p.y < q.y then 1 else -1
  let (x0, y0, x1, y1) := if p.y < q.y then (p.x, p.y, q.x, q.y) else (q.x, q.y, p.x, p.y)
  let bh : Int := bhFx
  let bw : Int := bwFx
  if y1 ≤ 0 || y0 ≥ bh then return acc
  let xAt (y : Int) : Int := x0 + Int.ediv ((x1 - x0) * (y - y0)) (y1 - y0)
  let (x0, y0) := if y0 < 0 then (xAt 0, (0 : Int)) else (x0, y0)
  let (x1, y1) := if y1 > bh then (xAt bh, bh) else (x1, y1)
  -- split at x = 0 and x = bw so each piece is entirely inside or outside
  let mut pieces : Array (Int × Int × Int × Int) := #[(x0, y0, x1, y1)]
  for k in [0:2] do
    let xc : Int := if k == 0 then 0 else bw
    let mut next : Array (Int × Int × Int × Int) := #[]
    for (a, b, c, d) in pieces do
      if (a < xc && c > xc) || (a > xc && c < xc) then
        let yc := b + Int.ediv ((d - b) * (xc - a)) (c - a)
        next := (next.push (a, b, xc, yc)).push (xc, yc, c, d)
      else
        next := next.push (a, b, c, d)
    pieces := next
  let mut acc := acc
  for (a, b, c, d) in pieces do
    let cl (x : Int) : Nat := Int.toNat (if x < 0 then 0 else if x > bw then bw else x)
    acc := accumPiece acc stride dir (cl a) b.toNat (cl c) d.toNat
  return acc

/-- Rasterize closed polygons (device-space `Fx` coordinates) into a coverage mask
clipped to a `W × H` canvas.  Returns `none` if nothing is visible. -/
def rasterize (W H : Nat) (polys : Array (Array Pt)) (evenOdd : Bool) : Option Mask := Id.run do
  -- bounding box
  let mut any := false
  let mut minx : Int := 0
  let mut miny : Int := 0
  let mut maxx : Int := 0
  let mut maxy : Int := 0
  for poly in polys do
    if poly.size < 3 then continue
    for p in poly do
      if !any then
        any := true
        minx := p.x
        maxx := p.x
        miny := p.y
        maxy := p.y
      else
        minx := Fx.min minx p.x
        maxx := Fx.max maxx p.x
        miny := Fx.min miny p.y
        maxy := Fx.max maxy p.y
  if !any then return none
  let x0i := Int.toNat (Fx.floor minx)
  let y0i := Int.toNat (Fx.floor miny)
  let x1i := Nat.min W (Int.toNat (Fx.ceil maxx))
  let y1i := Nat.min H (Int.toNat (Fx.ceil maxy))
  if x1i ≤ x0i || y1i ≤ y0i then return none
  let bw := x1i - x0i
  let bh := y1i - y0i
  let stride := bw + 2
  let mut acc : Array Int := Array.replicate (stride * bh) 0
  let ox : Int := x0i * 256
  let oy : Int := y0i * 256
  for poly in polys do
    let n := poly.size
    if n < 3 then continue
    for i in [0:n] do
      let p := poly.getD i default
      let q := poly.getD ((i + 1) % n) default
      acc := accumEdge acc stride (bw * 256) (bh * 256) ⟨p.x - ox, p.y - oy⟩ ⟨q.x - ox, q.y - oy⟩
  -- prefix sums → coverage
  let mut cov : Array Nat := Array.replicate (bw * bh) 0
  for r in [0:bh] do
    let mut s : Int := 0
    for c in [0:bw] do
      s := s + acc.getD (r * stride + c) 0
      let a := s.natAbs
      let v :=
        if evenOdd then
          let t := a % 131072
          if t > 65536 then 131072 - t else t
        else Nat.min a 65536
      cov := cov.setIfInBounds (r * bw + c) v
  return some ⟨x0i, y0i, bw, bh, cov⟩

end Raster
end MicroSvg
