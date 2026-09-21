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
  /-- How many horizontal bands of the output to render in parallel.  `0` or `1`
  is the serial path, unchanged and the reference.  Higher values split the
  output into at most that many bands of consecutive rows, render each as a
  `Task`, and concatenate the rows.  A band *is* a `viewport` tile (§3.8), so
  the output is byte-identical whatever this is set to. -/
  threads : Nat := 0
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
  -- `resolveRootSize` (Svg.lean) resolves `width`/`height` against the
  -- `viewBox` when present (percentages included) or the 100×100 default
  -- otherwise (usvg `resolve_svg_size`; no width/height/viewBox at all also
  -- falls back to that default rather than failing).  A negative/zero size
  -- still fails below.
  let (wFx, hFx) ← match resolveRootSize root with
    | some sz => pure sz
    | none => throw "cannot determine image size: need width and height, or a viewBox"
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

/-- Can any pixel this shape paints land on the `W × H` canvas?

The device-space box of the path's control points contains the flattened path
up to the floors in `cubicAt` and `Mat.apply`, so it is compared not against
the canvas `[0, W·256) × [0, H·256)` itself but against a rectangle widened by
everything that can put a painted point outside that box:

* A stroke is built in the path's own space and only then transformed, so
  `strokeReach`'s `r` of user-space reach is worth `r·(|a| + |c|)/65536` in
  device x and `r·(|b| + |d|)/65536` in device y.
* `r + 4` buys four more `Fx` of user-space room, which covers `cubicAt`'s
  floor on the fill side (one `Fx` per axis would do).
* `258` is the two `Fx` that `Mat.apply` can floor away on each side of the
  box, plus a whole device pixel of margin on top.

Widening the rectangle is exactly equivalent to inflating the box by the same
amounts, and it keeps the growing box the only thing the scan has to touch. -/
def shapeOnCanvas (ctm : Mat) (s : Shape) (W H : Nat) : Bool :=
  let st := s.style
  let reach : Fx := match st.stroke with
    | .solid _ => strokeReach ⟨st.strokeWidth, st.cap, st.join, st.miterLimit⟩
    | .none => 0
  let ax := Fx.abs ctm.a + Fx.abs ctm.c
  let ay := Fx.abs ctm.b + Fx.abs ctm.d
  let dx := Fx.clamp (Int.ediv ((reach + 4) * ax) 65536 + 258)
  let dy := Fx.clamp (Int.ediv ((reach + 4) * ay) 65536 + 258)
  ctrlBoxMeets ctm s.cmds (-dx) (-dy) ((W : Int) * 256 + dx) ((H : Int) * 256 + dy)

/-- `painter.rs::treat_as_hairline`.  The translation is dropped from the CTM,
the two vectors `(w, 0)` and `(0, w)` are mapped through what is left, and each
is measured with the octagonal norm `max(|x|, |y|) + min(|x|, |y|)/2`.  When
*both* come out at `≤ 1` device pixel the stroke is a hairline and the coverage
is their average; otherwise the stroke is outlined and filled as usual.

Returned in 16.16, which is `w`'s own precision (`Fx`) times 256. -/
def hairCoverage (ctm : Mat) (w : Fx) : Option Int :=
  let fastLen := fun (x y : Int) =>
    let a := Fx.abs x
    let b := Fx.abs y
    if a < b then b + Int.ediv a 2 else a + Int.ediv b 2
  let len0 := fastLen (Int.ediv (ctm.a * w) 256) (Int.ediv (ctm.b * w) 256)
  let len1 := fastLen (Int.ediv (ctm.c * w) 256) (Int.ediv (ctm.d * w) 256)
  if len0 ≤ 65536 && len1 ≤ 65536 then some (Int.ediv (len0 + len1) 2) else none

/-- Draw one shape (fill, then stroke) onto the canvas.

A shape that `shapeOnCanvas` rules out is skipped before `flatten`, which is
what makes a small tile of a large image cheap: the flattening, stroking and
transforming of every off-tile shape goes away.  The output does not change.
`Raster.rasterize` begins by taking the bounding box of the very device points
the culling box contains and returns `none` — leaving the canvas alone — as
soon as that box misses `[0, W) × [0, H)` in whole pixels, so every shape
culled here is one that `rasterize` would have thrown away anyway. -/
def drawShape (rootMat : Mat) (clip : Clip) (cv : Canvas) (s : Shape) : Canvas :=
  let st := s.style
  let ctm := rootMat.mul st.ctm
  let W := cv.w
  let H := cv.h
  if !(shapeOnCanvas ctm s W H) then cv else
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
      let a8 := opacityToU8 c.a st.strokeOpacity st.opacity
      -- `stroke-dasharray` cuts the flattened subpaths into the runs that are
      -- actually inked, before stroking, so every dash end gets a cap.  The
      -- fill above uses the undashed polylines; dashes are a stroke property.
      let polys := if st.dashes.isEmpty then polys else dashPolys st.dashes st.dashOffset polys
      match hairCoverage ctm st.strokeWidth with
      | some cov16 =>
        -- `scale = ⌊coverage·256⌋`, `new_alpha = (255·scale) >> 8`; folded into
        -- the coverage rather than the paint alpha (see `Raster.hairline`).
        let scale := Int.ediv cov16 256
        let covScale := (Int.ediv (255 * scale) 256).toNat
        let dev := polys.map fun p => ({ p with pts := p.pts.map ctm.apply } : Poly)
        match (Raster.hairline W H dev st.cap a8 covScale).bind (clipMask clip) with
        | some m => cv.fillMask m c a8
        | none => cv
      | none =>
        let ss : StrokeStyle := ⟨st.strokeWidth, st.cap, st.join, st.miterLimit⟩
        let outline := polys.foldl (fun out p => strokePoly ss p out) #[]
        let dev := outline.map fun p => p.map ctm.apply
        match (Raster.rasterize W H dev false).bind (clipMask clip) with
        | some m => cv.fillMask m c a8
        | none => cv
  | .none => cv

/-- An interpreted document and one set of options to straight-alpha RGBA bytes,
together with the canvas size they were produced at.

This is the whole of the old body of `render` between `Svg.interpret` and
`Png.encode`, and it is the only place a canvas is built: the serial path calls
it once with the user's options, the parallel path calls it once per band with
the band's `viewport`.  Everything a band does — the size checks, the culling in
`drawShape`, `clipMask` — is therefore literally the tile path of §3.8. -/
def renderRgba (opts : Options) (doc : Svg.Doc) :
    Except String (Nat × Nat × ByteArray) := do
  let (w, h, rootMat, clip) ← canvasSetup doc.root opts
  if w == 0 || h == 0 then throw "empty canvas"
  if w > maxDim || h > maxDim then throw s!"canvas {w}x{h} exceeds the {maxDim} px limit"
  if w * h > maxPixels then throw s!"canvas {w}x{h} exceeds the {maxPixels} px limit"
  let canvas := doc.shapes.foldl (drawShape rootMat clip) (Canvas.new w h opts.background)
  return (w, h, canvas.toRgbaBytes)

/-- How many bands to cut `h` output rows into for `threads` threads.

`1` means "render serially", which is what happens unless the caller asked for
at least two threads and the canvas is tall enough to be worth splitting: at
least `2·threads` rows, and never a band shorter than 32 rows, so the per-band
overhead (one `Canvas`, one culling pass over the shapes) stays small next to
the work a band does. -/
def bandCount (threads h : Nat) : Nat :=
  if threads < 2 || h < 2 * threads then 1
  else Nat.max 1 (Nat.min threads (h / 32))

/-- Split a `w × h` output into `k` bands of rows, render them in parallel and
concatenate their RGBA bytes.

Band `i` covers output rows `[y0, y1)` and is rendered as the tile
`viewport := (vx, vy + y0, w, y1 - y0)`, where `(vx, vy)` is the user's viewport
origin (or `(0, 0)`).  `canvasSetup` composes `translate(-vx, -(vy + y0))` after
the zoom, so a band's device geometry is the full render's shifted up by a whole
number of pixels, which is exactly the shift the rasterizer is invariant under
(§3.5) — the band's pixels are the full render's rows `[y0, y1)`, bit for bit.
The document window `clipMask` restricts to is shifted by the same `y0`, so a
band of a tile that hangs off the document clips like that part of the tile.

`Task.spawn`/`Task.get` are pure (`Task.get (Task.spawn f) = f ()` holds by
`rfl`), so this is a pure function and nothing about `render`'s type, its
totality or `Effect.lean` changes.  Bands are collected in order and the first
error wins, so the message does not depend on which task finished first. -/
def renderBands (opts : Options) (doc : Svg.Doc) (w h k : Nat) :
    Except String ByteArray := do
  let (vx, vy) : Int × Int := match opts.viewport with
    | some (x, y, _, _) => (x, y)
    | none => (0, 0)
  let bh := h / k
  let tasks : Array (Task (Except String (Nat × Nat × ByteArray))) := Id.run do
    let mut ts : Array (Task (Except String (Nat × Nat × ByteArray))) :=
      Array.emptyWithCapacity k
    for i in [0:k] do
      let y0 := i * bh
      let y1 := if i + 1 == k then h else y0 + bh
      let bandOpts : Options :=
        { opts with viewport := some (vx, vy + (y0 : Int), w, y1 - y0), threads := 0 }
      ts := ts.push (Task.spawn fun _ => renderRgba bandOpts doc)
    return ts
  let mut out := ByteArray.emptyWithCapacity (w * h * 4)
  for t in tasks do
    match t.get with
    | .error e => throw e
    | .ok (_, _, b) => out := out ++ b
  return out

end Render

/-- Render SVG bytes to PNG bytes, or fail with a message.

With `opts.threads ≥ 2` the canvas is cut into bands of rows that are rendered
in parallel and concatenated; the bytes are the same either way (see
`Render.renderBands`).  The PNG encoding stays serial: Adler-32 is sequential. -/
def render (opts : Options) (input : ByteArray) : Except String ByteArray := do
  let events ← Xml.parse input
  let doc ← Svg.interpret events
  let (w, h, _, _) ← Render.canvasSetup doc.root opts
  if w == 0 || h == 0 then throw "empty canvas"
  if w > maxDim || h > maxDim then throw s!"canvas {w}x{h} exceeds the {maxDim} px limit"
  if w * h > maxPixels then throw s!"canvas {w}x{h} exceeds the {maxPixels} px limit"
  let k := Render.bandCount opts.threads h
  let rgba ← if k < 2 then
      (·.2.2) <$> Render.renderRgba opts doc
    else
      Render.renderBands opts doc w h k
  return Png.encode w h rgba

end MicroSvg
