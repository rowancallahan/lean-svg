import MicroSvg.Svg
import MicroSvg.Png

/-!
# The pure renderer

`render : Options → ByteArray → Except String ByteArray`.

No I/O, no `partial`, no `unsafe`, no FFI, no floats.  Output dimensions are
capped so memory is bounded by a constant times `maxPixels`.
-/

namespace MicroSvg

structure Options where
  /-- Output width in pixels (height follows the aspect ratio). -/
  width : Option Nat := none
  /-- Zoom factor as `Fx` (256 = 1.0). -/
  zoom : Option Fx := none
  /-- Background colour; default transparent. -/
  background : Option Rgba := none
  /-- Render only the window `(x, y, w, h)` of the zoomed image, in output
  pixels: the result is `w × h` pixels showing that rectangle.  `x` and `y` may
  be negative or past the edge of the image; what falls outside the document is
  transparent (or the background colour).  The zoom is still the one `width`
  or `zoom` asks for, so the caller can tile a large virtual image. -/
  viewport : Option (Int × Int × Nat × Nat) := none
deriving Inhabited

/-- Largest output edge, in pixels. -/
def maxDim : Nat := 16384
/-- Largest output area, in pixels (16 Mpx → 128 MB of canvas). -/
def maxPixels : Nat := 16777216

namespace Render

open Svg

/-- The half-open rectangle of the canvas that the document covers, in canvas
pixels.  It is the whole canvas for an ordinary render; for a `--viewport` tile
that hangs off the edge of the document it is smaller, because the SVG viewport
clips and a tile must not show what lies outside it. -/
structure Clip where
  x0 : Nat
  y0 : Nat
  x1 : Nat
  y1 : Nat
deriving Inhabited

/-- Restrict a coverage mask to the document window.  A no-op (the mask itself)
unless a tile hangs off the document, since `rasterize` already clips to the
canvas. -/
def clipMask (c : Clip) (m : Raster.Mask) : Option Raster.Mask :=
  if c.x0 ≤ m.x0 && c.y0 ≤ m.y0 && m.x0 + m.w ≤ c.x1 && m.y0 + m.h ≤ c.y1 then some m
  else
    let x0 := Nat.max m.x0 c.x0
    let y0 := Nat.max m.y0 c.y0
    let x1 := Nat.min (m.x0 + m.w) c.x1
    let y1 := Nat.min (m.y0 + m.h) c.y1
    if x1 ≤ x0 || y1 ≤ y0 then none
    else Id.run do
      let w := x1 - x0
      let h := y1 - y0
      let mut cov : Array Nat := Array.replicate (w * h) 0
      for j in [0:h] do
        let src := (y0 - m.y0 + j) * m.w + (x0 - m.x0)
        let dst := j * w
        for i in [0:w] do
          cov := cov.setIfInBounds (dst + i) (m.cov.getD (src + i) 0)
      return some ⟨x0, y0, w, h, cov⟩

/-- Decide the output size, the root transform and the document window.

With `opts.viewport` the size is the tile's, not the whole image's, and the
tile's offset is applied *after* the zoom, so document geometry lands directly
in tile coordinates.  `maxDim` and `maxPixels` then bound the tile; the virtual
image it is a window of may be far larger.  The zoom itself is bounded by the
16.16 matrix: `Mat.linMax` clamps the linear part at 4096×.

The tile offset is a whole number of output pixels and is added to the root
matrix's translation exactly (`Mat.translate` has an identity linear part), so
device geometry inside a tile is the device geometry of the whole image shifted
by an integer number of pixels.  The rasterizer's coverage only depends on that
geometry relative to a whole-pixel mask origin, so a tile's pixels are bit for
bit the whole image's pixels. -/
def canvasSetup (root : RootInfo) (opts : Options) :
    Except String (Nat × Nat × Mat × Clip) := do
  let (wFx, hFx) ← match root.width, root.height, root.viewBox with
    | some w, some h, _ => pure (w, h)
    | some w, none, some (_, _, vw, vh) => pure (w, if vw > 0 then Int.ediv (w * vh) vw else w)
    | none, some h, some (_, _, vw, vh) => pure (if vh > 0 then Int.ediv (h * vw) vh else h, h)
    | none, none, some (_, _, vw, vh) => pure (vw, vh)
    | _, _, _ => throw "cannot determine image size: need width and height, or a viewBox"
  if wFx ≤ 0 || hFx ≤ 0 then throw "image size must be positive"
  let vbMat : Mat := match root.viewBox with
    | some (vx, vy, vw, vh) =>
      if vw > 0 && vh > 0 then
        let sx := Int.ediv (wFx * 65536) vw
        let sy := Int.ediv (hFx * 65536) vh
        let s := if sx ≤ sy then sx else sy
        let tx := Int.ediv (wFx - Int.ediv (vw * s) 65536) 2 - Int.ediv (vx * s) 65536
        let ty := Int.ediv (hFx - Int.ediv (vh * s) 65536) 2 - Int.ediv (vy * s) 65536
        Mat.mk' s 0 0 s tx ty
      else Mat.identity
    | none => Mat.identity
  let baseW := Nat.max 1 (Fx.round wFx).toNat
  let baseH := Nat.max 1 (Fx.round hFx).toNat
  let (W, H, zoom16) : Nat × Nat × Int :=
    match opts.width, opts.zoom with
    | some w, _ =>
      let z : Int := Int.ediv ((w : Int) * 65536) baseW
      (w, Nat.max 1 (Int.ediv (hFx * z + 32768 * 256) (65536 * 256)).toNat, z)
    | none, some z =>
      let z16 := z * 256
      (Nat.max 1 (Int.ediv (wFx * z16 + 32768 * 256) (65536 * 256)).toNat,
       Nat.max 1 (Int.ediv (hFx * z16 + 32768 * 256) (65536 * 256)).toNat, z16)
    | none, none => (baseW, baseH, 65536)
  let mat := (Mat.scale16 zoom16 zoom16).mul vbMat
  match opts.viewport with
  | none => return (W, H, mat, ⟨0, 0, W, H⟩)
  | some (vx, vy, vw, vh) =>
    let clip : Clip :=
      ⟨Int.toNat (-vx), Int.toNat (-vy),
       Nat.min vw (Int.toNat ((W : Int) - vx)), Nat.min vh (Int.toNat ((H : Int) - vy))⟩
    return (vw, vh, (Mat.translate (-(vx * 256)) (-(vy * 256))).mul mat, clip)

/-- Draw one shape (fill, then stroke) onto the canvas. -/
def drawShape (rootMat : Mat) (clip : Clip) (cv : Canvas) (s : Shape) : Canvas :=
  let st := s.style
  let ctm := rootMat.mul st.ctm
  let W := cv.w
  let H := cv.h
  let polys := flatten ctm s.cmds
  let cv := match st.fill with
    | .solid c =>
      let dev := polys.map fun p => p.pts.map ctm.apply
      match (Raster.rasterize W H dev st.evenOdd).bind (clipMask clip) with
      | some m => cv.fillMask m c (opacityToU8 c.a st.fillOpacity st.opacity)
      | none => cv
    | .none => cv
  match st.stroke with
  | .solid c =>
    if st.strokeWidth ≤ 0 then cv
    else
      let ss : StrokeStyle := ⟨st.strokeWidth, st.cap, st.join, st.miterLimit⟩
      let outline := polys.foldl (fun out p => strokePoly ss p out) #[]
      let dev := outline.map fun p => p.map ctm.apply
      match (Raster.rasterize W H dev false).bind (clipMask clip) with
      | some m => cv.fillMask m c (opacityToU8 c.a st.strokeOpacity st.opacity)
      | none => cv
  | .none => cv

end Render

/-- Render SVG bytes to PNG bytes, or fail with a message. -/
def render (opts : Options) (input : ByteArray) : Except String ByteArray := do
  let events ← Xml.parse input
  let doc ← Svg.interpret events
  let (w, h, rootMat, clip) ← Render.canvasSetup doc.root opts
  if w == 0 || h == 0 then throw "empty canvas"
  if w > maxDim || h > maxDim then throw s!"canvas {w}x{h} exceeds the {maxDim} px limit"
  if w * h > maxPixels then throw s!"canvas {w}x{h} exceeds the {maxPixels} px limit"
  let canvas := doc.shapes.foldl (Render.drawShape rootMat clip) (Canvas.new w h opts.background)
  return Png.encode w h canvas.toRgbaBytes

end MicroSvg
