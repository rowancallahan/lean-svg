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
deriving Inhabited

/-- Largest output edge, in pixels. -/
def maxDim : Nat := 16384
/-- Largest output area, in pixels (16 Mpx → 128 MB of canvas). -/
def maxPixels : Nat := 16777216

namespace Render

open Svg

/-- Decide the output size and the root transform. -/
def canvasSetup (root : RootInfo) (opts : Options) : Except String (Nat × Nat × Mat) := do
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
  return (W, H, (Mat.scale16 zoom16 zoom16).mul vbMat)

/-- Draw one shape (fill, then stroke) onto the canvas. -/
def drawShape (rootMat : Mat) (cv : Canvas) (s : Shape) : Canvas :=
  let st := s.style
  let ctm := rootMat.mul st.ctm
  let W := cv.w
  let H := cv.h
  let polys := flatten ctm s.cmds
  let cv := match st.fill with
    | .solid c =>
      let dev := polys.map fun p => p.pts.map ctm.apply
      match Raster.rasterize W H dev st.evenOdd with
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
      match Raster.rasterize W H dev false with
      | some m => cv.fillMask m c (opacityToU8 c.a st.strokeOpacity st.opacity)
      | none => cv
  | .none => cv

end Render

/-- Render SVG bytes to PNG bytes, or fail with a message. -/
def render (opts : Options) (input : ByteArray) : Except String ByteArray := do
  let events ← Xml.parse input
  let doc ← Svg.interpret events
  let (w, h, rootMat) ← Render.canvasSetup doc.root opts
  if w == 0 || h == 0 then throw "empty canvas"
  if w > maxDim || h > maxDim then throw s!"canvas {w}x{h} exceeds the {maxDim} px limit"
  if w * h > maxPixels then throw s!"canvas {w}x{h} exceeds the {maxPixels} px limit"
  let canvas := doc.shapes.foldl (Render.drawShape rootMat) (Canvas.new w h opts.background)
  return Png.encode w h canvas.toRgbaBytes

end MicroSvg
