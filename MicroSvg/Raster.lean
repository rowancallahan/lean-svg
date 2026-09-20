import MicroSvg.Geom

/-!
# Rasterizer

A port of tiny-skia's (that is, Skia's) supersampling scan converter, done
entirely in `Int`/`Nat` arithmetic.  resvg rasterizes with tiny-skia, so
matching its coverage values is what makes our output agree with the oracle.

The scheme (`tiny-skia/src/scan/path_aa.rs`, `scan/path.rs`, `edge.rs`):

* Coordinates are scaled up by `SCALE = 4` in both axes.  A device pixel row is
  four *sub-scanlines* and a device pixel column is four *sub-columns*.  Our
  `Fx` unit (1/256 px) is exactly Skia's `FDot6` in that supersampled space
  (1/64 of a supersampled pixel), so no conversion is needed.
* Each segment becomes a `LineEdge` (`Fx` in, 16.16 out):
  `top = (y0+32) >> 6`, `bottom = (y1+32) >> 6`, dropped when `top = bottom`;
  `slope = ((x1-x0) << 16) / (y1-y0)` (truncating, as Rust's `/`);
  `dy = (top << 6) + 32 - y0`; `x = (x0 + ((slope*dy) >> 16)) << 10`.
  So sub-scanline `t` samples the edge at supersampled `y = t` exactly, and the
  stored `x` is floored to `FDot6` before being widened to 16.16.  Per
  sub-scanline `x += slope`.
* On each sub-scanline the active edges are taken in increasing `x`, the
  winding number is accumulated and a span `[left, x)` of sub-columns is
  emitted whenever the winding returns to "outside" (`w = 0` for nonzero,
  `w` even for even-odd).  Instead of keeping the active list x-sorted (an
  insertion sort that degrades badly on paths with hundreds of thousands of
  edges) we bin each edge's rounded sub-column `(x + 0x8000) >> 16` into a
  winding-delta array and prefix-sum it, which yields exactly the same set of
  covered sub-columns.  See `blitRow` for the one-level consequence.
* A span contributes, per sub-scanline, `16` per covered quarter of a partly
  covered pixel and `maxValue = 64, 64, 64, 63` (by sub-scanline index) for a
  fully covered interior pixel, accumulated per destination row and saturated
  at 255.  Four sub-scanlines therefore add up to exactly 255.

The 0..255 alpha is finally mapped to the `Mask` convention `cov ∈ [0, 65536]`
by `cov = ⌈alpha·65536/255⌉`, which is the exact inverse of `Canvas.fillMask`'s
`alpha = a·cov·opacity/2^24` for an opaque paint, so alpha 255 stays 255.

Clipping: the mask is the shape's bounding box intersected with the canvas.
Parts of an edge left of the mask still count for winding (their sub-column
clamps to 0); parts above or below it are discarded.
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

/-- `AlphaRuns::add`: accumulate into one pixel of the current destination row,
saturating at 255 (Skia's `alpha - (alpha >> 8)` for the 256 case). -/
@[inline] def addAlpha (alpha : Array Nat) (p v : Nat) : Array Nat :=
  let a := alpha.getD p 0 + v
  alpha.setIfInBounds p (if a > 255 then 255 else a)

/-- `SuperBlitter::blit_h`: add one sub-scanline's span of sub-columns `[s, e)`
to the destination row's alpha accumulator.  `maxV` is 64 on the first three
sub-scanlines of the row and 63 on the last. -/
def blitSpan (alpha : Array Nat) (s e maxV : Nat) : Array Nat := Id.run do
  if e ≤ s then return alpha
  let p0 := s >>> 2
  let p1 := e >>> 2
  let fb := s &&& 3
  let fe := e &&& 3
  if p1 == p0 then
    -- whole span inside one pixel: `fb = fe - fb` in tiny-skia
    return addAlpha alpha p0 ((e - s) * 16)
  let mut alpha := alpha
  let mut mid := p0
  if fb != 0 then
    alpha := addAlpha alpha p0 ((4 - fb) * 16)
    mid := p0 + 1
  for p in [mid:p1] do
    alpha := addAlpha alpha p maxV
  if fe != 0 then
    alpha := addAlpha alpha p1 (fe * 16)
  return alpha

/-- `LineEdge::new` with `shift = 2`, for a segment given in mask-relative `Fx`
(which is `FDot6` in the supersampled space), restricted to sub-scanlines
`[0, nScan)`.  Returns `(x, dx, firstY, lastY, winding)` with `x`/`dx` in 16.16.

An edge whose rounded sub-column is clamped to the same mask boundary for its
whole life is pinned there with `dx = 0`, so that a shape reaching far outside
the canvas cannot put huge numbers in the per-sub-scanline loop. -/
def mkEdge (nScan nSuper : Nat) (ax ay bx by_ : Int) :
    Option (Int × Int × Nat × Nat × Int) :=
  let (x0, y0, x1, y1, wd) :=
    if ay > by_ then (bx, by_, ax, ay, (-1 : Int)) else (ax, ay, bx, by_, (1 : Int))
  let top := Int.ediv (y0 + 32) 64
  let bot := Int.ediv (y1 + 32) 64
  if top == bot then none
  else if bot ≤ 0 || top ≥ (nScan : Int) then none
  else
    let firstY := if top < 0 then (0 : Int) else top
    let lastY := if bot - 1 < (nScan : Int) - 1 then bot - 1 else (nScan : Int) - 1
    let slope := Int.tdiv ((x1 - x0) * 65536) (y1 - y0)
    let dy := top * 64 + 32 - y0
    let x0f := (x0 + Int.ediv (slope * dy) 65536) * 1024
    let xa := x0f + slope * (firstY - top)
    let xb := x0f + slope * (lastY - top)
    let loPin : Int := 32768
    let hiPin : Int := (nSuper : Int) * 65536 - 32768
    if xa < loPin && xb < loPin then some (0, 0, firstY.toNat, lastY.toNat, wd)
    else if xa ≥ hiPin && xb ≥ hiPin then
      some ((nSuper : Int) * 65536, 0, firstY.toNat, lastY.toNat, wd)
    else some (xa, slope, firstY.toNat, lastY.toNat, wd)

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
  let nSuper := bw * 4
  let nScan := bh * 4
  let ox : Int := x0i * 256
  let oy : Int := y0i * 256
  -- build the edge list
  let mut ex : Array Int := #[]
  let mut edx : Array Int := #[]
  let mut efy : Array Nat := #[]
  let mut ely : Array Nat := #[]
  let mut ewd : Array Int := #[]
  for poly in polys do
    let n := poly.size
    if n < 3 then continue
    for i in [0:n] do
      let p := poly.getD i default
      let q := poly.getD ((i + 1) % n) default
      match mkEdge nScan nSuper (p.x - ox) (p.y - oy) (q.x - ox) (q.y - oy) with
      | none => pure ()
      | some (x, dx, fy, ly, wd) =>
        ex := ex.push x
        edx := edx.push dx
        efy := efy.push fy
        ely := ely.push ly
        ewd := ewd.push wd
  let m := ex.size
  if m == 0 then return none
  -- counting sort of the edge indices by first sub-scanline
  let mut bstart : Array Nat := Array.replicate (nScan + 2) 0
  for i in [0:m] do
    let y := efy.getD i 0 + 1
    bstart := bstart.setIfInBounds y (bstart.getD y 0 + 1)
  for y in [1:nScan + 2] do
    bstart := bstart.setIfInBounds y (bstart.getD y 0 + bstart.getD (y - 1) 0)
  let mut fill := bstart
  let mut order : Array Nat := Array.replicate m 0
  for i in [0:m] do
    let y := efy.getD i 0
    let k := fill.getD y 0
    order := order.setIfInBounds k i
    fill := fill.setIfInBounds y (k + 1)
  -- walk the sub-scanlines
  let mut act : Array Nat := Array.emptyWithCapacity 64
  let mut wacc : Array Int := Array.replicate (nSuper + 1) 0
  let mut alpha : Array Nat := Array.replicate bw 0
  let mut cov : Array Nat := Array.replicate (bw * bh) 0
  for y in [0:nScan] do
    for k in [bstart.getD y 0 : bstart.getD (y + 1) 0] do
      act := act.push (order.getD k 0)
    -- bin the winding deltas, advance x, drop finished edges
    let mut lo : Nat := nSuper
    let mut hi : Nat := 0
    let mut live : Nat := 0
    for i in [0:act.size] do
      let ei := act.getD i 0
      let xf := ex.getD ei 0
      let xr := Int.ediv (xf + 32768) 65536
      let c : Nat := if xr ≤ 0 then 0 else if xr ≥ (nSuper : Int) then nSuper else xr.toNat
      wacc := wacc.setIfInBounds c (wacc.getD c 0 + ewd.getD ei 0)
      if c < lo then lo := c
      if c > hi then hi := c
      if ely.getD ei 0 > y then
        ex := ex.setIfInBounds ei (xf + edx.getD ei 0)
        act := act.setIfInBounds live ei
        live := live + 1
    act := act.shrink live
    -- prefix-sum the deltas into spans and blit them
    if lo ≤ hi then
      let maxV : Nat := if y &&& 3 == 3 then 63 else 64
      let mut w : Int := 0
      let mut runStart : Nat := 0
      let mut inRun := false
      for c in [lo:hi + 1] do
        w := w + wacc.getD c 0
        wacc := wacc.setIfInBounds c 0
        if c < nSuper then
          let ins := if evenOdd then Int.emod w 2 != 0 else w != 0
          if ins then
            if !inRun then
              runStart := c
              inRun := true
          else if inRun then
            alpha := blitSpan alpha runStart c maxV
            inRun := false
      if inRun then
        alpha := blitSpan alpha runStart nSuper maxV
    -- end of a destination row: flush the alphas
    if y &&& 3 == 3 then
      let row := (y >>> 2) * bw
      for p in [0:bw] do
        let a := alpha.getD p 0
        if a != 0 then
          cov := cov.setIfInBounds (row + p) ((a * 65536 + 254) / 255)
          alpha := alpha.setIfInBounds p 0
  return some ⟨x0i, y0i, bw, bh, cov⟩

end Raster
end MicroSvg
