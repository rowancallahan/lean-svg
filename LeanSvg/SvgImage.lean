import LeanSvg.Image
import LeanSvg.Gzip
import LeanSvg.Xml

/-!
# `<image>` of an SVG document (T84)

usvg's `load_sub_svg` + resvg's `render_vector`.  The `href` is a `data:` URI
(`Image.dataUri`) whose MIME type is `image/svg+xml`, or `text/plain` (also
what a missing MIME type becomes) with bytes that are not PNG, JPEG, GIF or
WebP.  Bytes starting `1f 8b` are `svgz` and go through `Gzip.gunzip`; the
result must be UTF-8 (`Tree::from_data`).  Nothing else is ever looked at.

`Svg.interpret` parses the sub-document (`Xml.parse`), reads its size, places
it like a raster image (`place`) and keeps its events in an `Entry`; the
renderer interprets and draws them in a layer (`layerBox`, `composite`), under
the parent's budgets.  Inside a sub-document no image is loaded at all, so an
SVG image never nests.

One deliberate difference from resvg: the drawing is always confined to the
device box of the image's viewport (resvg only clips for `slice`), so an image
never paints outside its box (`spec/SvgImageLocality.lean`).
-/

namespace LeanSvg
namespace SvgImage

open Bytes

/-- Bytes of SVG source all images of one document may hold in all (the
decompressed size for `svgz`), the same as `Render.maxInput`. -/
def maxTotalBytes : Nat := 64 * 1024 * 1024

/-- `imagesize::image_type` for the four raster formats usvg's `text/plain`
branch recognises; anything else is tried as SVG. -/
def isRaster (d : ByteArray) : Bool :=
  Image.sniff d != .other ||
  (at' d 0 == 0x47 && at' d 1 == 0x49 && at' d 2 == 0x46 && at' d 3 == 0x38) ||
  (at' d 0 == 0x52 && at' d 1 == 0x49 && at' d 2 == 0x46 && at' d 3 == 0x46 &&
   at' d 8 == 0x57 && at' d 9 == 0x45 && at' d 10 == 0x42 && at' d 11 == 0x50)

/-- The SVG source an `href` embeds, at most `budget` bytes, and how much of
the budget that spends: its size, or all of it when an `svgz` fails to
inflate (like a raster image over `Image.maxTotalPixels`, so a zip bomb is
decompressed at most once however often it is used). -/
def load (href : ByteArray) (budget : Nat) : Option ByteArray × Nat :=
  match Image.dataUri href with
  | none => (none, 0)
  | some (mime, d) =>
    if !(mime == "image/svg+xml" || (mime == "text/plain" && !isRaster d)) then (none, 0)
    else if at' d 0 == 0x1f && at' d 1 == 0x8b then
      match Gzip.gunzip d budget with
      | none => (none, budget)
      | some s => (if s.validateUTF8 then some s else none, s.size)
    else if d.size ≤ budget && d.validateUTF8 then (some d, d.size)
    else (none, 0)

/-- Element count and deepest nesting of an event stream. -/
def stats (evs : Array Xml.Event) : Nat × Nat := Id.run do
  let mut n := 0
  let mut d := 0
  let mut dmax := 0
  for e in evs do
    match e with
    | .open_ _ _ =>
      n := n + 1
      d := d + 1
      if d > dmax then dmax := d
    | .close => d := d - 1
    | .text _ => pure ()
  return (n, dmax)

/-- A sub-document ready to render. -/
structure Entry where
  events : Array Xml.Event
  /-- `Svg.maxLayerDepth` already spent where the image sits (its own layer
  included). -/
  layerDepth : Nat
  /-- The image element's viewport, user space. -/
  x : Fx
  y : Fx
  w : Fx
  h : Fx
  /-- The image element's user space to the sub-document's. -/
  inner : Mat
deriving Inhabited

/-- `image::convert` for a sub-document of size `(sw, sh)` whose root maps its
user space to `[0, sw] × [0, sh]` by `rootMat`: the viewport (`w?`/`h?`
missing is auto-sized as for a raster image), the view box
(`Image.viewBox`), and `image_ts · rootMat`.  `none` for an empty size. -/
def place (sw sh : Fx) (rootMat : Mat) (x y : Fx) (w? h? : Option Fx)
    (ar : Viewport.AspectRatio) : Option (Fx × Fx × Fx × Fx × Mat) :=
  if sw ≤ 0 || sh ≤ 0 then none else
  let (w, h) : Fx × Fx := match w?, h? with
    | some w, some h => (w, h)
    | some w, none => (w, Int.ediv (w * sh) sw)
    | none, some h => (Int.ediv (h * sw) sh, h)
    | none, none => (sw, sh)
  if w ≤ 0 || h ≤ 0 then none else
  let (vx, vy, vw, vh) := Image.viewBox sw.toNat sh.toNat x y w h ar
  if vw ≤ 0 || vh ≤ 0 then none else
  let imageTs := Mat.mk' (Int.ediv (vw * 65536) sw) 0 0 (Int.ediv (vh * 65536) sh) vx vy
  some (x, y, w, h, imageTs.mul rootMat)

/-- The device box `(x0, y0, x1, y1)`, whole pixels rounded outwards, of the
viewport `(x, y, w, h)` under `ctm`. -/
def devBox (ctm : Mat) (x y w h : Fx) : Int × Int × Int × Int :=
  let p0 := ctm.apply ⟨x, y⟩
  let p1 := ctm.apply ⟨x + w, y⟩
  let p2 := ctm.apply ⟨x, y + h⟩
  let p3 := ctm.apply ⟨x + w, y + h⟩
  (Fx.floor (min (min p0.x p1.x) (min p2.x p3.x)),
   Fx.floor (min (min p0.y p1.y) (min p2.y p3.y)),
   Fx.ceil (max (max p0.x p1.x) (max p2.x p3.x)),
   Fx.ceil (max (max p0.y p1.y) (max p2.y p3.y)))

/-- The layer an image renders into: its device box cut to the window
`[cx0, cx1) × [cy0, cy1)`; `none` when that is empty. -/
def layerBox (b : Int × Int × Int × Int) (cx0 cy0 cx1 cy1 : Nat) :
    Option (Nat × Nat × Nat × Nat) :=
  let (bx0, by0, bx1, by1) := b
  let x0 := max bx0 (cx0 : Int)
  let y0 := max by0 (cy0 : Int)
  let x1 := min bx1 (cx1 : Int)
  let y1 := min by1 (cy1 : Int)
  if x1 ≤ x0 || y1 ≤ y0 then none else some (x0.toNat, y0.toNat, x1.toNat, y1.toNat)

/-- resvg's `draw_pixmap` of the finished sub-pixmap: a plain source-over at
full opacity, `layer` placed at `(ox, oy)` of `cv`. -/
def composite (cv layer : Canvas) (ox oy : Nat) : Canvas :=
  cv.compositeNormal layer ox oy Canvas.opGrid

/-- `composite` of a layer rendered for `box` (band pixels) onto a canvas
sitting at `(ox, oy)`; a layer of another size, or a box left of or above the
canvas, draws nothing, so what reaches `composite` is always inside `box`
(`spec/SvgImageLocality.lean`). -/
def draw (cv layer : Canvas) (box : Nat × Nat × Nat × Nat) (ox oy : Nat) : Canvas :=
  let (x0, y0, x1, y1) := box
  if layer.w == x1 - x0 && layer.h == y1 - y0 && ox ≤ x0 && oy ≤ y0 then
    composite cv layer (x0 - ox) (y0 - oy)
  else cv

end SvgImage
end LeanSvg
