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

Edges are clipped to the *document* rectangle, which is the same rectangle for
the whole image and for a tile of it.  They are **not** clipped to the mask,
which is the shape's bounding box intersected with the canvas and so differs
between a tile and the full image: instead only the rows and columns the mask
holds are visited, and the area function supplies "nothing yet" for a column
left of an edge and "all of it" for one to its right.  Coverage of a pixel
therefore does not depend on where the mask boundary falls, which is what makes
a tile agree bit for bit with the same window of the full render.  The loops
stay in `Nat` (Lean's unboxed 63-bit integer): an edge piece reaching outside
the mask is shifted by whole pixels until it is non-negative, which only moves
the row and column indices by a constant.  Full coverage of a pixel is `65536`.
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

/-- The document rectangle in canvas pixels: `(0, 0, W, H)` for a whole image,
and the window's complement for a tile, where it is the same rectangle of the
document seen from the tile's origin. -/
structure Rect where
  x0 : Int
  y0 : Int
  x1 : Int
  y1 : Int
deriving Inhabited, Repr

/-- Accumulate one edge piece with `ya < yb`, in `Fx` relative to the origin of
a `bw × bh` pixel mask.  The piece may lie outside the mask.

Only rows `[0, bh)` and columns `[0, bw]` of the difference buffer are touched,
but the x position at each row boundary is always interpolated from the piece's
*own* endpoints, never from a copy cut down to the mask.  Together with the area
function `r2` — which already gives no coverage for a column left of the piece
and full coverage for one right of it — that makes what a pixel accumulates
independent of where the mask boundary falls: a piece crossing it contributes
exactly what it would if the mask were larger.  This is what lets a tile match
the same window of the full image bit for bit.

The loops themselves run in `Nat`: the piece is first shifted right and down by
a whole number of pixels, enough to make every coordinate non-negative.  A shift
by whole pixels moves row and column indices by a constant, which is subtracted
back when indexing, and leaves the arithmetic alone — `r2` and the interpolation
of `x` along the piece are both invariant under a common shift. -/
def accumPiece (acc : Array Int) (stride bw bh : Nat) (dir : Int) (xa ya xb yb : Int) :
    Array Int := Id.run do
  if yb ≤ ya || bh == 0 then return acc
  if yb ≤ 0 || ya ≥ (bh : Int) * 256 then return acc
  -- shift into `Nat`, by whole pixels so that only the index origin moves
  let sx : Nat := if xa ≤ xb then
      (if xa < 0 then ((-xa).toNat + 255) / 256 else 0)
    else (if xb < 0 then ((-xb).toNat + 255) / 256 else 0)
  let sy : Nat := if ya < 0 then ((-ya).toNat + 255) / 256 else 0
  let xA : Nat := (xa + sx * 256).toNat
  let xB : Nat := (xb + sx * 256).toNat
  let yA : Nat := (ya + sy * 256).toNat
  let yB : Nat := (yb + sy * 256).toNat
  -- rows of the mask the piece meets, in the shifted frame
  let rowFirst : Nat := Nat.max sy (yA / 256)
  let rowLast : Nat := Nat.min (sy + bh - 1) ((yB - 1) / 256)
  let dyTotal : Nat := yB - yA
  let rising : Bool := xB ≥ xA
  let dxAbs : Nat := if rising then xB - xA else xA - xB
  let mut acc := acc
  for r in [rowFirst:rowLast + 1] do
    let yt : Nat := Nat.max yA (r * 256)
    let yu : Nat := Nat.min yB ((r + 1) * 256)
    if yu ≤ yt then continue
    let dy := yu - yt
    -- x where the piece meets this row band, from the piece's own endpoints
    let xt := if rising then xA + dxAbs * (yt - yA) / dyTotal else xA - dxAbs * (yt - yA) / dyTotal
    let xu := if rising then xA + dxAbs * (yu - yA) / dyTotal else xA - dxAbs * (yu - yA) / dyTotal
    let xl := Nat.min xt xu
    let xr := Nat.max xt xu
    -- first column that is not empty, last one that is not yet full
    let colLo := xl / 256
    let colHi := if xr ≤ xl then colLo else (xr - 1) / 256
    let colStart := Nat.max sx colLo
    let colEnd := Nat.min (sx + bw) colHi
    let base := (r - sy) * stride
    let full := dy * 256
    let mut prev : Nat := 0
    for c in [colStart:colEnd + 1] do
      let cov := dy * (r2 xl xr ((c + 1) * 256) - r2 xl xr (c * 256)) / 512
      let idx := base + c - sx
      acc := acc.setIfInBounds idx (acc.getD idx 0 + dir * ((cov : Int) - (prev : Int)))
      prev := cov
    -- every column further right gets the piece's whole winding step
    let last := if colStart ≤ colEnd then colEnd + 1 - sx else colStart - sx
    if last < stride then
      let idx := base + last
      acc := acc.setIfInBounds idx (acc.getD idx 0 + dir * ((full : Int) - (prev : Int)))
  return acc

/-- Accumulate an edge given in mask-relative `Fx` coordinates, clipping it to
the *document* rectangle `doc` (also mask-relative, in `Fx`).  Parts left of the
document are projected onto its left edge (which preserves winding for every
pixel); parts above or below it are discarded.

The document rectangle is the same rectangle whether the whole image or one
tile of it is being rasterized, so this clipping — unlike clipping to the mask,
which `accumPiece` does exactly — cannot make a tile disagree with the full
image. -/
def accumEdge (acc : Array Int) (stride bw bh : Nat) (doc : Rect) (p q : Pt) :
    Array Int := Id.run do
  if p.y == q.y then return acc
  let dir : Int := if p.y < q.y then 1 else -1
  let (x0, y0, x1, y1) := if p.y < q.y then (p.x, p.y, q.x, q.y) else (q.x, q.y, p.x, p.y)
  if y1 ≤ doc.y0 || y0 ≥ doc.y1 then return acc
  let xAt (y : Int) : Int := x0 + Int.ediv ((x1 - x0) * (y - y0)) (y1 - y0)
  let (x0, y0) := if y0 < doc.y0 then (xAt doc.y0, doc.y0) else (x0, y0)
  let (x1, y1) := if y1 > doc.y1 then (xAt doc.y1, doc.y1) else (x1, y1)
  if doc.x0 ≤ x0 && x0 ≤ doc.x1 && doc.x0 ≤ x1 && x1 ≤ doc.x1 then
    -- wholly inside: no split needed
    return accumPiece acc stride bw bh dir x0 y0 x1 y1
  -- split at the document's left and right edge so each piece is entirely
  -- inside or outside
  let mut pieces : Array (Int × Int × Int × Int) := #[(x0, y0, x1, y1)]
  for k in [0:2] do
    let xc : Int := if k == 0 then doc.x0 else doc.x1
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
    let cl (x : Int) : Int := if x < doc.x0 then doc.x0 else if x > doc.x1 then doc.x1 else x
    acc := accumPiece acc stride bw bh dir (cl a) b (cl c) d
  return acc

/-- Rasterize closed polygons (device-space `Fx` coordinates) into a coverage mask
clipped to a `W × H` canvas.  `doc` is the document rectangle in canvas pixels —
`(0, 0, W, H)` for a whole image, and the same document rectangle seen from the
tile's origin for a tile.  Returns `none` if nothing is visible. -/
def rasterize (W H : Nat) (doc : Rect) (polys : Array (Array Pt)) (evenOdd : Bool) :
    Option Mask := Id.run do
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
  let docFx : Rect :=
    ⟨doc.x0 * 256 - ox, doc.y0 * 256 - oy, doc.x1 * 256 - ox, doc.y1 * 256 - oy⟩
  for poly in polys do
    let n := poly.size
    if n < 3 then continue
    for i in [0:n] do
      let p := poly.getD i default
      let q := poly.getD ((i + 1) % n) default
      acc := accumEdge acc stride bw bh docFx ⟨p.x - ox, p.y - oy⟩ ⟨q.x - ox, q.y - oy⟩
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
