import LeanSvg.Geom

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
  `w` even for even-odd).  Two converters do this, chosen per sub-scanline by
  the number of active edges (`walkLimit`):
  - **sorted walk** (`≤ walkLimit` active edges): the active array is
    insertion-sorted by rounded sub-column `(x + 0x8000) >> 16` and walked
    edge by edge, exactly as `walk_edges` does.  Cost `O(active + inversions)`
    per sub-scanline; the array is kept in sub-column order from one
    sub-scanline to the next, so the sort is usually a single linear scan.
  - **binned prefix sum** (more than `walkLimit`): each edge's rounded
    sub-column is binned into a winding-delta array, which is prefix-summed
    over `[min sub-column, max sub-column]`.  Cost `O(active + columns)`, but
    with no sort — `huge_path.svg` keeps ~2·10^6 edges simultaneously active
    and an insertion sort there costs billions of shifts.
  The two agree on the set of covered sub-columns.  They differ only when two
  spans abut *inside* a pixel: the sorted walk emits them separately (as
  tiny-skia does), the binned one emits a single merged run, and the shared
  pixel then reads `4·16 = 64` instead of `maxValue`.  That is a one-level
  difference, and only on the fourth sub-scanline of a row, where
  `maxValue = 63`.
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

`hairline` below is the *other* converter: tiny-skia never sends a thin stroke
here at all.  See its own comment.
-/

namespace LeanSvg
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

/-- Active-edge count up to which a sub-scanline is converted by the x-sorted
walk rather than by the binned prefix sum (see the module comment).

Tuned by paired A/B runs over the corpus at natural size and at width 1600:
0 (always binned) is 1.5-1.8× slower; 128 beats 64 by 2-4% in every paired
round; 256 shows no further gain and doubles the worst case of the insertion
sort, which is `walkLimit²` shifts per sub-scanline. -/
@[inline] def walkLimit : Nat := 128

/-- Is the accumulated winding "inside"?  `w ≠ 0` for the nonzero rule, `w` odd
for even-odd (Skia's `w & windingMask`). -/
@[inline] def insideW (evenOdd : Bool) (w : Int) : Bool :=
  if evenOdd then Int.emod w 2 != 0 else w != 0

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
  -- sort keys for the walk; `act.size ≤ m`, so `min walkLimit m` always fits
  -- (a path of four edges must not pay for a `walkLimit`-sized allocation)
  let mut kc : Array Nat := Array.replicate (Nat.min walkLimit m) 0
  let mut wacc : Array Int := Array.replicate (nSuper + 1) 0
  let mut alpha : Array Nat := Array.replicate bw 0
  let mut cov : Array Nat := Array.replicate (bw * bh) 0
  for y in [0:nScan] do
    for k in [bstart.getD y 0 : bstart.getD (y + 1) 0] do
      act := act.push (order.getD k 0)
    let n := act.size
    if n ≤ walkLimit then
      -- sorted walk: rounded sub-column of every active edge ...
      for i in [0:n] do
        let xr := Int.ediv (ex.getD (act.getD i 0) 0 + 32768) 65536
        kc := kc.setIfInBounds i
          (if xr ≤ 0 then 0 else if xr ≥ (nSuper : Int) then nSuper else xr.toNat)
      -- ... insertion-sorted (stable, at most `n` shifts per element) ...
      for i in [1:n] do
        let ki := kc.getD i 0
        let ei := act.getD i 0
        let mut j := i
        for _ in [0:i] do
          let kp := kc.getD (j - 1) 0
          if kp ≤ ki then break
          kc := kc.setIfInBounds j kp
          act := act.setIfInBounds j (act.getD (j - 1) 0)
          j := j - 1
        kc := kc.setIfInBounds j ki
        act := act.setIfInBounds j ei
      -- ... and walked in edge order, emitting `[left, c)` on each return to
      -- "outside", exactly as `walk_edges` does.
      let maxV : Nat := if y &&& 3 == 3 then 63 else 64
      let mut w : Int := 0
      let mut left : Nat := 0
      for i in [0:n] do
        let c := kc.getD i 0
        if !insideW evenOdd w then left := c
        w := w + ewd.getD (act.getD i 0) 0
        if !insideW evenOdd w then
          alpha := blitSpan alpha left c maxV
      if insideW evenOdd w then
        alpha := blitSpan alpha left nSuper maxV
      -- advance x, drop finished edges (sub-column order is preserved)
      let mut live : Nat := 0
      for i in [0:n] do
        let ei := act.getD i 0
        if ely.getD ei 0 > y then
          ex := ex.setIfInBounds ei (ex.getD ei 0 + edx.getD ei 0)
          act := act.setIfInBounds live ei
          live := live + 1
      act := act.shrink live
    else
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

/-! ## Non-antialiased fill (`shape-rendering: crispEdges` / `optimizeSpeed`)

resvg turns off `tiny-skia`'s antialiasing for these (`path.rs`'s
`paint.anti_alias = path.rendering_mode().use_shape_antialiasing()`), which
sends the fill to `scan::path::fill_path` instead of `scan::path_aa::fill_path`
above.  That converter sits at native pixel resolution (`shift = 0`, i.e. no
4× supersampling in either axis) and asks one question per pixel: is the
row's centre inside the shape?  A LineEdge is the same construction as
`mkEdge` with the sub-scanline unit widened from a quarter pixel (`64` `Fx`,
`shift = 2`) to a whole one (`256` `Fx`, `shift = 0`), so `top`/`bot` round to
the nearest *row* instead of the nearest quarter-row, and `x` lands in 16.16
*pixel columns* instead of 16.16 sub-columns.  Coverage is then binary: `w`'s
winding at the row decides the whole pixel, blitted with `blit_h` rather than
`AlphaRuns::add`, so every covered pixel gets the full `65536` and every other
one `0`. This is deliberately a separate function from `rasterize`/`mkEdge`
above rather than a shared one parameterised on the unit, so that this mode
cannot perturb the default antialiased path (DESIGN.md §3.5). -/

/-- `mkEdge`'s formulas at `shift = 0` instead of `shift = 2`: the rounding
unit is one whole pixel (`256` `Fx`, half `128`) rather than a quarter
(`64` `Fx`, half `32`), and `x` is stored in 16.16 pixel columns (`× 256`)
rather than 16.16 sub-columns (`× 1024`). -/
def mkEdgeCrisp (nScan nSuper : Nat) (ax ay bx by_ : Int) :
    Option (Int × Int × Nat × Nat × Int) :=
  let (x0, y0, x1, y1, wd) :=
    if ay > by_ then (bx, by_, ax, ay, (-1 : Int)) else (ax, ay, bx, by_, (1 : Int))
  let top := Int.ediv (y0 + 128) 256
  let bot := Int.ediv (y1 + 128) 256
  if top == bot then none
  else if bot ≤ 0 || top ≥ (nScan : Int) then none
  else
    let firstY := if top < 0 then (0 : Int) else top
    let lastY := if bot - 1 < (nScan : Int) - 1 then bot - 1 else (nScan : Int) - 1
    let slope := Int.tdiv ((x1 - x0) * 65536) (y1 - y0)
    let dy := top * 256 + 128 - y0
    let x0f := (x0 + Int.ediv (slope * dy) 65536) * 256
    let xa := x0f + slope * (firstY - top)
    let xb := x0f + slope * (lastY - top)
    let loPin : Int := 32768
    let hiPin : Int := (nSuper : Int) * 65536 - 32768
    if xa < loPin && xb < loPin then some (0, 0, firstY.toNat, lastY.toNat, wd)
    else if xa ≥ hiPin && xb ≥ hiPin then
      some ((nSuper : Int) * 65536, 0, firstY.toNat, lastY.toNat, wd)
    else some (xa, slope, firstY.toNat, lastY.toNat, wd)

/-- Rasterize closed polygons with binary coverage (`0` or `65536`, no
partial pixels) for `shape-rendering: crispEdges`/`optimizeSpeed`.  One
scanline per destination row, at the row's own resolution rather than 4×
supersampled — see the module note above.  Always the binned-winding walk
(`rasterize`'s sorted alternative exists only to keep the AA path fast on
paths with hundreds of thousands of edges; this mode is for small, deliberately
blocky shapes, so the simpler single algorithm is enough). -/
def rasterizeCrisp (W H : Nat) (polys : Array (Array Pt)) (evenOdd : Bool) : Option Mask := Id.run do
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
  let nScan := bh
  let nSuper := bw
  let ox : Int := x0i * 256
  let oy : Int := y0i * 256
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
      match mkEdgeCrisp nScan nSuper (p.x - ox) (p.y - oy) (q.x - ox) (q.y - oy) with
      | none => pure ()
      | some (x, dx, fy, ly, wd) =>
        ex := ex.push x
        edx := edx.push dx
        efy := efy.push fy
        ely := ely.push ly
        ewd := ewd.push wd
  let m := ex.size
  if m == 0 then return none
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
  let mut act : Array Nat := Array.emptyWithCapacity 64
  let mut wacc : Array Int := Array.replicate (nSuper + 1) 0
  let mut cov : Array Nat := Array.replicate (bw * bh) 0
  for y in [0:nScan] do
    for k in [bstart.getD y 0 : bstart.getD (y + 1) 0] do
      act := act.push (order.getD k 0)
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
    if lo ≤ hi then
      let row := y * bw
      let mut w : Int := 0
      for c in [lo:hi + 1] do
        w := w + wacc.getD c 0
        wacc := wacc.setIfInBounds c 0
        if c < nSuper && insideW evenOdd w then
          cov := cov.setIfInBounds (row + c) 65536
  return some ⟨x0i, y0i, bw, bh, cov⟩

/-! ## Hairline strokes

`painter.rs::treat_as_hairline` keeps every stroke whose device-space width is
`≤ 1` away from the supersampling converter above and draws it with
`scan::hairline_aa` (Skia's `AntiHairLineRgn`) instead, with the paint alpha
scaled by the width.  That converter is a Wu-style walker, not an area
rasterizer: it lays down **one sample per major-axis pixel**, splitting a
constant 255 units of alpha between two adjacent minor-axis pixels.  A 1 px
diagonal of length 200 px therefore receives `max(|dx|, |dy|) = 160` px² of
ink, not the geometric 200 px².

The scheme (`scan/hairline_aa.rs::do_anti_hairline`, `scan/hairline.rs`):

* Coordinates are `FDot6` (1/64 *device* px — note this is not the same unit as
  the supersampled `Fx` above; `toFDot6` divides by 4, truncating toward zero
  as `fdot6::from_f32` does).  The running minor-axis position `fy` and the
  slope are 16.16.
* The major axis is the one with the larger `|Δ|` (ties go to vertical), and
  the segment is oriented along it.  `istart = ⌊u0⌋`, `istop = ⌈u1⌉`,
  `fstart = v0 << 10` plus, when the segment is not axis-parallel,
  `(slope·(32 - (u0 & 63)) + 32) >> 6`, which re-centres the first sample on
  the centre of column `istart`.  `slope = ((v1-v0) << 16) / (u1-u0)`
  truncating, so `|slope| ≤ 1`.
* Each step emits `(a·mod64) >> 6` into the "lower" minor pixel `⌊fy⌋` and
  `((255-a)·mod64) >> 6` into the one above it, where `a = (fy >> 8) & 0xFF`
  and `fy` carries a persistent `+1/2` bias and is clamped at 0; then
  `fy += slope`.
* `mod64` is 64 for interior steps.  The first step uses
  `64 - (u0 & 63)` and the last `u1 & 63` (dropped when that is 0); a segment
  inside a single major pixel uses `u1 - u0` for its one step.
* The four blitter flavours differ only in how they treat an index of `-1`:
  the axis-parallel `HLine` skips that pixel, `VLine` clamps it to 0, and the
  two oblique ones clamp with `max(i,1)-1` and then write the pair at that row
  and the next — so a line grazing the top/left edge is nudged inward by one.
  T104 deviates: the oblique flavours skip the `-1` pixel and `fy` is not
  pinned, as Chromium draws it (the nudge showed as a notch atop circles at the edge).
* There are no joins: `stroke_path_impl` hands every flattened segment to the
  converter *independently* and the blitter composites, so a pixel shared by
  two segments is blended twice.  Caps are the only geometry: `extend_pts`
  pushes the ends of a subpath out along the unit tangent by 1/2 (square) or
  π/8 (round), and a closing segment is drawn back to the *extended* start.

Two src-over blits of one colour at coverages `c₁`, `c₂` and paint alpha `a`
are exactly one blit at `c₁ + c₂ - a·c₁·c₂`, so `hairPx` accumulates with that
rule and `Canvas.fillMask` still sees a single mask.  For the same reason the
width factor is folded into the coverage rather than into the paint alpha: the
colour is premultiplied by the alpha before the coverage is applied, so the two
are interchangeable, and the coverage has 16 bits to spend where the alpha has
8.

Deliberate deviations from tiny-skia, both at the edge of the canvas:
`anti_hair_line_rgn` chops each segment against the clip *before* converting to
`FDot6`, and `do_anti_hairline` halves any segment longer than 511 px.  Both
are float-domain work that loses precision and, worse, is not invariant under
the whole-pixel translation a `--viewport` tile applies, which would break the
tile identity the renderer guarantees.  Here the segment is instead clipped
integrally — exactly as `do_anti_hairline`'s own clip does, by skipping major
columns and advancing `fstart` by `slope·n`, which provably never changes a
pixel inside the clip — and never halved, since `Int` cannot overflow. -/

/-- `fdot6::from_f32` on a device coordinate: `Fx` is 1/256 px and `FDot6` is
1/64 px, and Rust's `as i32` truncates toward zero. -/
@[inline] def toFDot6 (a : Fx) : Int := Int.tdiv a 4

/-- Round-to-nearest division by a positive `d`, halves away from zero. -/
@[inline] def divRound (n d : Int) : Int :=
  if d ≤ 0 then 0
  else if n ≥ 0 then Int.ediv (2 * n + d) (2 * d)
  else -(Int.ediv (2 * (-n) + d) (2 * d))

/-- Blend one hairline sample into the mask.  `al` is tiny-skia's 0..255 pixel
alpha; it is scaled by the width factor `covScale` and mapped to the mask's
`[0, 65536]` convention, then combined with what is already there by the
src-over rule `c₁ + c₂ - a·c₁·c₂`.  A sample outside the mask is dropped, which
is what `RectClipBlitter` does. -/
@[inline] def hairPx (cov : Array Nat) (bw bh a8 covScale : Nat) (px py : Int)
    (al : Nat) : Array Nat :=
  if al == 0 then cov
  else if px < 0 || py < 0 || px ≥ (bw : Int) || py ≥ (bh : Int) then cov
  else
    let c := (al * covScale * 65536 + 65024) / 65025
    let p := py.toNat * bw + px.toNat
    let c1 := cov.getD p 0
    if c1 == 0 then cov.setIfInBounds p c
    else
      let s := c1 + c - (c1 * c * a8) / 16711680
      cov.setIfInBounds p (if s > 65536 then 65536 else s)

/-- `do_anti_hairline` for one device-space segment, with the integral clip set
to the mask rectangle `(mx, my, bw, bh)`.

The single loop runs over the segment's major axis after that clip, so it is
bounded by `bw` or `bh`; everything else is straight-line arithmetic.

`vx`/`vy` say where the canvas' pixel `(0, 0)` sits in the whole zoomed image —
`(0, 0)` for an ordinary render, the tile's origin for a `--viewport` tile or a
parallel band, so that `FDot6` truncation matches the full render. -/
def hairSeg (bw bh a8 covScale : Nat) (mx my : Nat) (vx vy : Int) (cov : Array Nat)
    (p q : Pt) : Array Nat := Id.run do
  -- `toFDot6` truncates *toward zero*, which is what `fdot6::from_f32` does but
  -- is not invariant under the tile's translation: a coordinate that is
  -- negative in this canvas and positive in the whole image rounds the other
  -- way, which moves the segment by up to 1/64 px and with it every sample it
  -- lays down.  Truncating the whole-image coordinate and shifting the result
  -- back by the exact integer `v·64` gives the full render's `FDot6` on the
  -- nose, and is the identity when `vx = vy = 0`.
  let ax := toFDot6 (p.x + vx * 256) - vx * 64
  let ay := toFDot6 (p.y + vy * 256) - vy * 64
  let bx := toFDot6 (q.x + vx * 256) - vx * 64
  let by_ := toFDot6 (q.y + vy * 256) - vy * 64
  let horiz := (bx - ax).natAbs > (by_ - ay).natAbs
  -- orient along the major axis `u`; `v` is the minor one
  let (u0, v0, u1, v1) :=
    if horiz then (if ax > bx then (bx, by_, ax, ay) else (ax, ay, bx, by_))
    else (if ay > by_ then (by_, bx, ay, ax) else (ay, ax, by_, bx))
  if u1 == u0 then return cov          -- zero length: nothing to draw
  let flat := v0 == v1
  let slope : Int := if flat then 0 else Int.tdiv ((v1 - v0) * 65536) (u1 - u0)
  let mut fstart : Int := v0 * 1024
  if !flat then
    fstart := fstart + Int.ediv (slope * (32 - Int.emod u0 64) + 32) 64
  let mut istart := Int.ediv u0 64
  let istop0 := Int.ediv (u1 + 63) 64
  let mut istop := istop0
  let one := istop - istart == 1
  let mut sStart : Int := if one then u1 - u0 else 64 - Int.emod u0 64
  let mut sStop : Int := if one then 0 else Int.emod u1 64
  -- integral clip to the mask's major-axis range
  let cl : Int := if horiz then mx else my
  let cr : Int := cl + (if horiz then bw else bh)
  if istart ≥ cr || istop ≤ cl then return cov
  if istart < cl then
    fstart := fstart + slope * (cl - istart)
    istart := cl
    sStart := 64
    if istop - istart == 1 then
      sStart := Int.emod (u1 - 1) 64 + 1   -- `contribution_64`
      sStop := 0
  if istop > cr then
    istop := cr
    sStop := 0
  if istart ≥ istop then return cov
  let n := (istop - istart).toNat
  -- T104: no oblique clamp at the image's top/left edge.  tiny-skia pins `fy`
  -- at 0 and moves an upper pixel of `-1` into the image (`max(i,1)-1`),
  -- which shifts a hairline grazing the top row down by one pixel: the top of
  -- a circle touching the edge showed a notch.  Chromium draws the geometry;
  -- so do we: an upper pixel outside the image is dropped, as `HLine` does.
  let mut fy : Int := fstart + 32768
  let mut cov := cov
  for k in [0:n] do
    let m64 : Int :=
      if k == 0 then sStart
      else if k + 1 == n && sStop > 0 then sStop
      else 64
    let ly := Int.ediv fy 65536
    let a := Int.emod (Int.ediv fy 256) 256
    let aLo := (Int.ediv (a * m64) 64).toNat
    let aHi := (Int.ediv ((255 - a) * m64) 64).toNat
    -- `VLine` still clamps a `-1` column to the image's first one
    let hiI := if flat && !horiz && ly + vx < 1 then -vx else ly - 1
    let loI := ly
    let i := istart + k
    if horiz then
      cov := hairPx cov bw bh a8 covScale (i - mx) (hiI - my) aHi
      cov := hairPx cov bw bh a8 covScale (i - mx) (loI - my) aLo
    else
      cov := hairPx cov bw bh a8 covScale (hiI - mx) (i - my) aHi
      cov := hairPx cov bw bh a8 covScale (loI - mx) (i - my) aLo
    fy := fy + slope
  return cov

/-- `hairline.rs::extend_pts` for one end: push `p` away from `q` by the cap
outset (1/2 for a square cap, π/8 for a round one) along the unit tangent.
With `p = q` tiny-skia falls back to `(1, 0)` at the start of a subpath and
`(-1, 0)` at its end. -/
def capExtend (cap : Cap) (atStart : Bool) (p q : Pt) : Pt :=
  match cap with
  | .butt => p
  | _ =>
    let o : Int := if cap == Cap.square then 32768 else 25736   -- 16.16 px
    let dx := p.x - q.x
    let dy := p.y - q.y
    let len := Fx.hypot dx dy
    if len == 0 then
      let e := divRound o 256
      ⟨Fx.clamp (if atStart then p.x + e else p.x - e), p.y⟩
    else
      ⟨Fx.clamp (p.x + divRound (dx * o) (len * 256)),
       Fx.clamp (p.y + divRound (dy * o) (len * 256))⟩

/-- Rasterize device-space polylines as anti-aliased hairlines into a coverage
mask clipped to a `W × H` canvas.  `a8` is the final paint alpha the mask will
be filled with (it is what makes the src-over accumulation exact) and
`covScale ∈ [0, 255]` is `treat_as_hairline`'s width factor.  Returns `none` if
nothing is visible. -/
def hairline (W H : Nat) (polys : Array Poly) (cap : Cap) (a8 covScale : Nat)
    (vx vy : Int) : Option Mask := Id.run do
  if a8 == 0 || covScale == 0 then return none
  -- flatten to segments, applying the cap extension where tiny-skia does
  let mut segs : Array (Pt × Pt) := #[]
  for poly in polys do
    let n := poly.pts.size
    if n < 2 then continue
    let e0 := capExtend cap true (poly.pts.getD 0 default) (poly.pts.getD 1 default)
    let eL := capExtend cap false (poly.pts.getD (n - 1) default) (poly.pts.getD (n - 2) default)
    for i in [0:n - 1] do
      let a := if i == 0 then e0 else poly.pts.getD i default
      let b := if i + 2 == n then eL else poly.pts.getD (i + 1) default
      segs := segs.push (a, b)
    -- the closing segment is never extended, but it does close to the
    -- extended start point (`first_pt = last_pt2`)
    if poly.closed then segs := segs.push (poly.pts.getD (n - 1) default, e0)
  if segs.isEmpty then return none
  -- bounding box: a sample can land one whole pixel outside the geometry
  let mut minx : Fx := 0
  let mut miny : Fx := 0
  let mut maxx : Fx := 0
  let mut maxy : Fx := 0
  let mut any := false
  for s in segs do
    for p in [s.1, s.2] do
      if !any then
        any := true
        minx := p.x; maxx := p.x; miny := p.y; maxy := p.y
      else
        minx := Fx.min minx p.x
        maxx := Fx.max maxx p.x
        miny := Fx.min miny p.y
        maxy := Fx.max maxy p.y
  if !any then return none
  let x0i := Int.toNat (Fx.floor minx - 1)
  let y0i := Int.toNat (Fx.floor miny - 1)
  let x1i := Nat.min W (Int.toNat (Fx.ceil maxx + 1))
  let y1i := Nat.min H (Int.toNat (Fx.ceil maxy + 1))
  if x1i ≤ x0i || y1i ≤ y0i then return none
  let bw := x1i - x0i
  let bh := y1i - y0i
  let mut cov : Array Nat := Array.replicate (bw * bh) 0
  for s in segs do
    cov := hairSeg bw bh a8 covScale x0i y0i vx vy cov s.1 s.2
  return some ⟨x0i, y0i, bw, bh, cov⟩

end Raster
end LeanSvg
