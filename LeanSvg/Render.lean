import LeanSvg.Mask
import LeanSvg.Clip
import LeanSvg.FilterApply
import LeanSvg.Marker
import LeanSvg.Filter.ImageRender
import LeanSvg.PatternRender
import LeanSvg.Png
import LeanSvg.RootFit

/-!
# The pure renderer

`render : Options → ByteArray → Except String ByteArray`.

No I/O, no `partial`, no `unsafe`, no FFI, no floats.  Output dimensions are
capped so memory is bounded by a constant times `maxPixels`.
-/

namespace LeanSvg

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
  /-- How many threads to render the output on.  `0` or `1` is the serial path,
  unchanged and the reference.  Higher values split the output into bands of
  consecutive rows — several per thread, see `Render.bandsPerThread`, so that
  the task pool can even out bands that are not equal work — render each as a
  `Task`, and concatenate the rows.  A band *is* a `viewport` tile (§3.8), so
  the output is byte-identical whatever this is set to. -/
  threads : Nat := 0
deriving Inhabited

/-- Largest output edge, in pixels. -/
def maxDim : Nat := 16384
/-- Largest output area, in pixels (16 Mpx → 128 MB of canvas). -/
def maxPixels : Nat := 16777216
/-- Largest accepted input file, in bytes (64 MiB). Checked before parsing. -/
def maxInput : Nat := 64 * 1024 * 1024

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
  /-- The `--viewport` origin in output pixels, `(0, 0)` for a full render.
  Adding it to a canvas pixel index gives the pixel's position in the whole
  zoomed image, which is what a paint that varies per pixel has to be a
  function of if a tile is to stay byte-identical (T18, `Grad.build`). -/
  vx : Int := 0
  vy : Int := 0
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
    | some vb => (Viewport.viewBoxTransform vb root.aspect wFx hFx).getD Mat.identity
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
  | none => return (W, H, mat, ⟨0, 0, W, H, 0, 0⟩)
  | some (vx, vy, vw, vh) =>
    let clip : Clip :=
      ⟨Int.toNat (-vx), Int.toNat (-vy),
       Nat.min vw (Int.toNat ((W : Int) - vx)), Nat.min vh (Int.toNat ((H : Int) - vy)),
       vx, vy⟩
    return (vw, vh, (Mat.translate (-(vx * 256)) (-(vy * 256))).mul mat, clip)

/-- The user-space reach `shapeOnCanvas` widens a shape's control box by, in
device x and y: the stroke's own reach mapped through the CTM, plus the slack
the floors in `cubicAt` / `Mat.apply` can introduce.  Factored out of
`shapeOnCanvas` so that a layer's allocation rectangle (`Render.nodeBox`) is
widened by exactly the same amount as the culling test, and therefore cannot
be smaller than the region the shape may paint. -/
def shapeSlack (ctm : Mat) (s : Shape) : Fx × Fx :=
  let st := s.style
  -- Any paint that inks, not just a solid one: a gradient stroke reaches
  -- just as far (main's `shapeOnCanvas` before this was factored out).
  let reach : Fx := match st.stroke with
    | .none => 0
    | _ => strokeReach ⟨st.strokeWidth, st.cap, st.join, st.miterLimit⟩
  let ax := Fx.abs ctm.a + Fx.abs ctm.c
  let ay := Fx.abs ctm.b + Fx.abs ctm.d
  (Fx.clamp (Int.ediv ((reach + 4) * ax) 65536 + 258),
   Fx.clamp (Int.ediv ((reach + 4) * ay) 65536 + 258))

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
  let (dx, dy) := shapeSlack ctm s
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

/-- Where one shape is rasterised *to*.

`w`/`h` are the band's canvas — the size all device geometry is built and
clipped against, so that a shape's coverage never depends on which layer it
lands in.  `clip` is the destination window in those same canvas coordinates
(the document window of §3.8, intersected with the enclosing layer's
rectangle), and `ox`/`oy` is where the destination canvas' pixel `(0, 0)` sits
in them: `(0, 0)` for the band itself, the layer's top-left corner for a layer.

So a layer changes exactly two things about drawing a shape: the mask is
clipped to the layer's rectangle, and it is then shifted into the layer's own
coordinates.  Everything upstream — culling, flattening, stroking, rasterising
— is bit for bit what it was, which is what keeps a document with no layers
byte-identical. -/
structure Target where
  w : Nat
  h : Nat
  clip : Clip
  ox : Nat := 0
  oy : Nat := 0
deriving Inhabited

/-- Move a mask from canvas coordinates into the destination canvas'.  A no-op
for the band itself (`ox = oy = 0`); the mask has already been clipped to the
layer, so the subtraction cannot underflow. -/
@[inline] def shiftMask (t : Target) (m : Raster.Mask) : Raster.Mask :=
  if t.ox == 0 && t.oy == 0 then m
  else { m with x0 := m.x0 - t.ox, y0 := m.y0 - t.oy }

/-- Draw one shape (fill, then stroke) onto the canvas.

A shape that `shapeOnCanvas` rules out is skipped before `flatten`, which is
what makes a small tile of a large image cheap: the flattening, stroking and
transforming of every off-tile shape goes away.  The output does not change.
`Raster.rasterize` begins by taking the bounding box of the very device points
the culling box contains and returns `none` — leaving the canvas alone — as
soon as that box misses `[0, W) × [0, H)` in whole pixels, so every shape
culled here is one that `rasterize` would have thrown away anyway. -/
def drawShape (rootMat : Mat) (tgt : Target) (doc : Svg.Doc) (cv : Canvas) (cache : Clip.Cache)
    (s : Shape) : Canvas × Clip.Cache :=
  let st := s.style
  let ctm := rootMat.mul st.ctm
  let clip := tgt.clip
  let W := tgt.w
  let H := tgt.h
  if !(shapeOnCanvas ctm s W H) then (cv, cache) else
  -- T20: the shape's `clip-path` chain — its own, and those of the ancestors
  -- that did *not* get a layer of their own — built in the band's device space
  -- and cached; an invalid clip drops the shape, as usvg does.  With no clips
  -- `chain` is empty and `Clip.applyChain` is the identity.
  let (chain?, cache) := Clip.resolve doc W H rootMat cache st.clips
  match chain? with
  | none => (cv, cache)
  | some chain =>
  let polys := flatten ctm s.cmds
  -- T18: a `Paint` is a colour, a gradient, or nothing.  A gradient is turned
  -- into a device-space shader here, against this shape's own bounding box and
  -- its own `ctm`; `Grad.build` hands back a solid colour for the degenerate
  -- cases usvg collapses, which then take the ordinary `fillMask` path.
  -- T22: the mask is rasterised in canvas coordinates and `shiftMask` moves it
  -- into the destination canvas, which is the band itself (a no-op) or a layer.
  --
  -- A gradient has to survive that shift. `fillMaskShader` reads `m.x0 + x`
  -- both as a destination index and as the coordinate it evaluates the paint
  -- at, so a shifted mask would sample the gradient in the wrong place. It is
  -- the same problem `--viewport` already solved: `Grad.build` takes the origin
  -- that turns a sample coordinate into a whole-image one and folds it into the
  -- constant term, leaving the coefficients bit for bit the full render's. A
  -- layer just adds its own origin to that pair, and `gctm` maps user space to
  -- the layer instead of the canvas so the two agree — `Mat.translate` has an
  -- identity linear part, so that composition is exact and a layer's gradient
  -- pixels equal the full render's.
  let gctm := if tgt.ox == 0 && tgt.oy == 0 then ctm
    else (Mat.translate (-((tgt.ox : Int) * 256)) (-((tgt.oy : Int) * 256))).mul ctm
  let paintMask := fun (cv : Canvas) (p : Svg.Paint) (m0 : Raster.Mask) (op : Nat) =>
    let m := shiftMask tgt m0
    -- T63: an `<image>` paints its own sampler through the same mask.
    match s.image with
    | some im =>
      match Image.build im gctm (clip.vx + tgt.ox) (clip.vy + tgt.oy) with
      | some sh => cv.fillMaskImage m sh
      | none => cv
    | none =>
    match p with
    | .none => cv
    | .solid c => cv.fillMask m c (opacityToU8 c.a op st.opacity)
    | .gradient i _ =>
      match Grad.build st.defs i s.cmds gctm (clip.vx + tgt.ox) (clip.vy + tgt.oy)
              op st.opacity with
      | .skip => cv
      | .solid c a8 => cv.fillMask m c a8
      | .grad sh => cv.fillMaskShader m sh
    | .pattern i =>
      match Pat.build doc Pat.patternFuel i s.cmds gctm (clip.vx + tgt.ox) (clip.vy + tgt.oy)
              op st.opacity with
      | .skip => cv
      | .tile sh => cv.fillMaskPattern m sh
  -- `shape-rendering: crispEdges`/`optimizeSpeed` swaps in the non-antialiased
  -- rasterizer for both fill and stroke (`use_shape_antialiasing` in DESIGN.md
  -- §3.5's non-AA note); every other rendering mode keeps the default path.
  let raster := if st.crisp then Raster.rasterizeCrisp else Raster.rasterize
  let drawFill := fun (cv : Canvas) => match st.fill with
    | .none => cv
    | _ =>
      let dev := polys.map fun p => p.pts.map ctm.apply
      match ((raster W H dev st.evenOdd).bind (clipMask clip)).map
          (Clip.applyChain chain) with
      | some m => paintMask cv st.fill m st.fillOpacity
      | none => cv
  let drawStroke := fun (cv : Canvas) => match st.stroke with
    | .none => cv
    | _ =>
      if st.strokeWidth ≤ 0 then cv
      else
        -- `stroke-dasharray` cuts the flattened subpaths into the runs that are
        -- actually inked, before stroking, so every dash end gets a cap.  The
        -- fill above uses the undashed polylines; dashes are a stroke property.
        let polys := if st.dashes.isEmpty then polys else dashPolys st.dashes st.dashOffset polys
        -- `treat_as_hairline` refuses whenever `!paint.anti_alias`, so a crisp
        -- stroke never takes the hairline shortcut, however thin.
        match (if st.crisp then none else hairCoverage ctm st.strokeWidth) with
        | some cov16 =>
          -- `scale = ⌊coverage·256⌋`, `new_alpha = (255·scale) >> 8`; folded into
          -- the coverage rather than the paint alpha (see `Raster.hairline`).
          -- The hairline blitter needs the paint's alpha up front, which a
          -- gradient does not have one of; its stops' alphas are already in the
          -- shader, so it passes 255 and lets the shader carry them.
          let a8 := match st.stroke with
            | .solid c => opacityToU8 c.a st.strokeOpacity st.opacity
            | _ => 255
          let scale := Int.ediv cov16 256
          let covScale := (Int.ediv (255 * scale) 256).toNat
          let dev := polys.map fun p => ({ p with pts := p.pts.map ctm.apply } : Poly)
          -- `clip.vx`/`clip.vy` put the canvas in the whole zoomed image, which
          -- is where `hairline`'s edge clamps belong: without them a band or a
          -- tile pins a sample to its own first row instead of the image's.
          match ((Raster.hairline W H dev st.cap a8 covScale clip.vx clip.vy).bind
              (clipMask clip)).map
              (Clip.applyChain chain) with
          | some m => paintMask cv st.stroke m st.strokeOpacity
          | none => cv
        | none =>
          let ss : StrokeStyle := ⟨st.strokeWidth, st.cap, st.join, st.miterLimit⟩
          let outline := polys.foldl (fun out p => strokePoly ss p out) #[]
          let dev := outline.map fun p => p.map ctm.apply
          match ((raster W H dev false).bind (clipMask clip)).map
              (Clip.applyChain chain) with
          | some m => paintMask cv st.stroke m st.strokeOpacity
          | none => cv
  -- `paint-order`: normally fill then stroke; `st.strokeFirst` (set when
  -- `stroke` precedes `fill` in the property's resolved order) swaps them.
  -- T20's clip multiplies each coverage mask above, so it applies to whichever
  -- order they are painted in.
  ((if st.strokeFirst then drawFill (drawStroke cv) else drawStroke (drawFill cv)), cache)

/-- Total layer pixels that may be live at once, as a multiple of `maxPixels`.

Nesting is already bounded by `Svg.maxLayerDepth`, but each of those ten levels
could in principle ask for a full canvas, so the *area* needs its own bound.
Four canvases of layers on top of the canvas itself is far more than any real
document uses (the whole resvg suite peaks at one), and a document that asks
for more is rejected rather than allocating. -/
def maxLayerPixels : Nat := 4 * maxPixels

/-- T51: the layer rectangle of a filter group, resvg's `render_group` for a
group with filters: the union of the filters' regions (`filters_bounding_box`,
user space), transformed by `dev` into device space and made an integer rect
as `x.floor()`, `y.floor()`, `width.ceil().max(1)`, `height.ceil().max(1)` —
note the width is the ceiling of the *width*, not of the right edge.  Returned
as `(x0, y0, x1, y1)`; `none` for no filters. -/
def filterBox (dev : Mat) (fs : Array Filter.Resolved) : Option (Int × Int × Int × Int) := Id.run do
  let mut b : Option Box := none
  for f in fs do
    let r := f.region
    b := Box.union b (some ⟨r.x, r.y, r.x + r.w, r.y + r.h⟩)
  match b with
  | none => return none
  | some u =>
    match Box.transformed dev u with
    | none => return none
    | some d =>
      let x0 := Fx.floor d.x0
      let y0 := Fx.floor d.y0
      return some (x0, y0, x0 + max 1 (Fx.ceil (d.x1 - d.x0)), y0 + max 1 (Fx.ceil (d.y1 - d.y0)))

/-- The layer rectangle for the group that opens at `nodes[i]` (a `groupBegin`):
the union of the device boxes of every shape in its subtree, in whole canvas
pixels, widened like resvg's (`render.rs`: `floor`/`ceil` then two pixels of
margin on each side, so anti-aliased edge pixels are never clipped) and
intersected with `clip`.

`none` means the group paints nothing inside `clip` — an empty subtree, or one
entirely outside the window — and the whole group can then be skipped, which is
what makes an off-canvas layer free rather than merely small.

The scan stops at the matching `groupEnd`, so nested groups are included in
their ancestor's box (usvg's `layer_bounding_box`, which likewise unions the
children's). Cost is the subtree's size, so over a whole document it is at most
`Svg.maxLayerDepth` passes over the node array. -/
def nodeBox (rootMat : Mat) (nodes : Array Svg.Node) (i : Nat) (clip : Clip) : Option Clip :=
  Id.run do
    let mut lo : Option (Int × Int × Int × Int) := none
    let mut depth : Nat := 0
    for j in [i + 1 : nodes.size] do
      match nodes.getD j default with
      | .groupBegin g =>
        depth := depth + 1
        -- T51: a nested filter paints its whole region, not just its shapes.
        match filterBox (rootMat.mul g.filterCtm) g.filters with
        | some (x0, y0, x1, y1) =>
          lo := match lo with
            | none => some (x0 - 2, y0 - 2, x1 + 2, y1 + 2)
            | some (a0, b0, a1, b1) =>
              some (min a0 (x0 - 2), min b0 (y0 - 2), max a1 (x1 + 2), max b1 (y1 + 2))
        | none => pure ()
      | .groupEnd => if depth == 0 then break else depth := depth - 1
      | .shape s =>
        let ctm := rootMat.mul s.style.ctm
        match ctrlBox ctm s.cmds with
        | none => pure ()
        | some b =>
          let (dx, dy) := shapeSlack ctm s
          let x0 := Int.ediv (b.x0 - dx) 256 - 2
          let y0 := Int.ediv (b.y0 - dy) 256 - 2
          let x1 := -(Int.ediv (-(b.x1 + dx)) 256) + 2
          let y1 := -(Int.ediv (-(b.y1 + dy)) 256) + 2
          lo := match lo with
            | none => some (x0, y0, x1, y1)
            | some (a0, b0, a1, b1) =>
              some (min a0 x0, min b0 y0, max a1 x1, max b1 y1)
    match lo with
    | none => return none
    | some (x0, y0, x1, y1) =>
      let cx0 := Nat.max clip.x0 x0.toNat
      let cy0 := Nat.max clip.y0 y0.toNat
      let cx1 := Nat.min clip.x1 x1.toNat
      let cy1 := Nat.min clip.y1 y1.toNat
      -- `vx`/`vy` are carried through unchanged: they say where this canvas
      -- sits in the whole zoomed image, which a layer does not change.
      if cx1 ≤ cx0 || cy1 ≤ cy0 then return none
      else return some { clip with x0 := cx0, y0 := cy0, x1 := cx1, y1 := cy1 }

/-- `Svg.opacityOne`-grid opacity as the binary32 resvg hands to tiny-skia.

usvg stores it as an `f32` parsed from the file and `PixmapPaint::opacity` is
that same `f32`, so the value to emulate is "the binary32 nearest the decimal
in the file".  The grid is `10^18`ths and every literal `parseOpacity` can
return is exact on it, so `F32.ofRat` on those two integers is exactly that
nearest binary32 — no double rounding. -/
def opacityF32 (o : Nat) : F32 :=
  if o ≥ Svg.opacityOne then F32.one else F32.ofRat o Svg.opacityOne

/-- The same opacity on `Canvas.opGrid`, for `Canvas.compositeLayer`'s integer
`normal` path: round-half-up of `opGrid · o` off the `opacityOne` grid.

Rounding the file's decimal rather than `opacityF32`'s binary32 avoids a second
rounding, and `opGrid` is 256 times finer than the `u8` a fill's alpha is
quantised to — which is what keeps the composite within one level of the f32
pipeline (`Canvas.blendOverScaled`). -/
def opacityQ (o : Nat) : Nat :=
  if o ≥ Svg.opacityOne then Canvas.opGrid
  else (o * Canvas.opGrid * 2 / Svg.opacityOne + 1) / 2

/-- One frame of the layer stack: the canvas being painted, where it sits in
band coordinates, the clip its children use, and how it composites back. -/
structure Layer where
  cv : Canvas
  ox : Nat
  oy : Nat
  clip : Clip
  opacity : F32
  /-- `opacity` on `Canvas.opGrid`, quantised once per layer (`opacityQ`). -/
  opacityQ : Nat
  blend : BlendMode
  /-- T20: the group's own `clip-path` masks, in device space, multiplied into
  the layer just before it composites (resvg's `clip::apply` on the
  sub-pixmap).  Empty for a layer that only carries opacity or a blend mode. -/
  clips : Array Clip.Mask := #[]
  /-- T49: the group's resolved `mask` chain, applied after `clips`, and the
  device matrix of the masked element's user space. -/
  masks : Array Mask.Step := #[]
  maskMat : Mat := Mat.identity
  /-- T51: set for a *filter* layer.  Its canvas is the filter region, in a
  coordinate frame of its own (`root`/`fw`/`fh`/`cache` save the enclosing
  frame's), sitting at `(lx, ly)` of the enclosing frame — possibly off it,
  since resvg's filter region reaches past the canvas. -/
  filters : Array Filter.Resolved := #[]
  /-- The filters' user space to the filter layer's pixels. -/
  fts : Mat := Mat.identity
  root : Mat := Mat.identity
  fw : Nat := 0
  fh : Nat := 0
  cache : Clip.Cache := {}
  lx : Int := 0
  ly : Int := 0
deriving Inhabited

/-- Largest filter layer, in pixels.  resvg lets the region reach 2× the canvas
past each edge (`max_filter_bbox`); past this area the region is cut to the
enclosing canvas instead. -/
def maxFilterPixels : Nat := maxPixels

/-- Bound on `primitives × filter-layer pixels` for one filter group: each
primitive keeps a result the size of the layer. -/
def maxFilterWork : Nat := 33554432

/-- Bound on the same product summed over every filter group of a render:
nesting could otherwise multiply `maxFilterWork` by `Svg.maxLayerDepth`.  A
primitive costs at most a few dozen passes over its layer (a blur is ten), so
this caps filter time at tens of seconds whatever the input. -/
def maxFilterTotal : Nat := 67108864

/-- Crop `c`, placed at `(dx, dy)`, to `[0, w) × [0, h)`: the part that lands
there and its (now non-negative) position; `none` if nothing does. -/
def cropTo (c : Canvas) (dx dy : Int) (w h : Nat) : Option (Canvas × Nat × Nat) := Id.run do
  let x0 := max dx 0
  let y0 := max dy 0
  let x1 := min (dx + c.w) w
  let y1 := min (dy + c.h) h
  if x1 ≤ x0 || y1 ≤ y0 then return none
  if x0 == dx && y0 == dy && x1 == dx + c.w && y1 == dy + c.h then
    return some (c, x0.toNat, y0.toNat)
  let cw := (x1 - x0).toNat
  let ch := (y1 - y0).toNat
  let sx := (x0 - dx).toNat
  let sy := (y0 - dy).toNat
  let mut px : Array Nat := Array.replicate (cw * ch) 0
  for j in [0:ch] do
    for i in [0:cw] do
      px := px.setIfInBounds (j * cw + i) (c.px.getD ((sy + j) * c.w + sx + i) 0)
  return some (⟨cw, ch, px⟩, x0.toNat, y0.toNat)


/-- How deeply mask content may itself use masks (T49): each level renders the
content of the masks one level up.  Past it, a mask's content renders nothing. -/
def maskFuel : Nat := 8

/-- How many mask contents one canvas may render in all (T49).  Masks inside
mask content multiply — `k` masked elements per level cost `k^depth` renders —
so the total is capped, and a document past it is rejected like one past
`maxLayerPixels`, never silently truncated. -/
def maxMaskRenders : Nat := 1024

/-- The node walk: paint `nodes` onto `cv0`, a canvas whose pixel `(0, 0)` sits
at `(ox0, oy0)` in the band and whose children are clipped to `clip0`, with
`rootMat` mapping the nodes' user space to the band.  `live0` is the layer area
already allocated by the callers, which counts against `maxLayerPixels`.

`cur` is the canvas being painted and `stack` the enclosing layers; with no
`groupBegin` in the document the loop is the old `shapes.foldl (drawShape ...)`
with one `match` in front of it.

`skipDepth > 0` swallows the subtree of a group whose rectangle missed the
window entirely (nothing it contains can be visible), counting nested
`groupBegin`s so the right `groupEnd` ends the skip.  T20 adds a second reason
to swallow one: an invalid `clip-path` on the group, which usvg turns into "the
element is not rendered"; T49 a third, an invalid `mask`.

T20's clip-mask cache lives for one canvas, so a clip shared by many shapes —
or by a group's layer and its descendants — is rasterized once.

T51: a group with a `filter` is a layer in a frame of its own (`Layer.filters`).

T49: a group with a `mask` renders each mask's content by calling this function
again, on `fuel - 1`, over the mask's own node stream (`Mask` module comment). -/
def renderNodes (doc : Svg.Doc) (w h fullW fullH : Nat) : (fuel : Nat) → (rootMat : Mat) →
    (nodes : Array Svg.Node) → (cv0 : Canvas) → (clip0 : Clip) → (ox0 oy0 : Nat) →
    Clip.Cache → (live0 : Nat) → (renders0 : Nat) → (fwork0 : Nat) →
    Except String (Canvas × Clip.Cache × Nat × Nat)
  | 0, _, _, cv0, _, _, _, cache, _, renders, fwork => .ok (cv0, cache, renders, fwork)
  | fuel + 1, rootMat, nodes, cv0, clip0, ox0, oy0, cache0, live0, renders0, fwork0 => Id.run do
  let mut cur : Canvas := cv0
  let mut stack : Array Layer := #[]
  let mut cache : Clip.Cache := cache0
  let mut curClip := clip0
  let mut curOx : Nat := ox0
  let mut curOy : Nat := oy0
  let mut livePixels : Nat := live0
  let mut renders : Nat := renders0
  let mut skipDepth : Nat := 0
  let mut err : Option String := none
  -- T51: the coordinate frame shapes are rasterised in.  It is the band
  -- (`rootMat`, `w × h`) except inside a filter layer, which is a frame of its
  -- own: its canvas is the filter region, placed in whole-image pixels, so a
  -- blur or an offset sees what lies outside the band and a tile stays
  -- byte-identical to the full render.
  let mut curRoot := rootMat
  let mut curW := w
  let mut curH := h
  -- T51: one entry per open, unskipped `groupBegin`: `true` when it opened no
  -- layer (a filter that resolved to nothing), so its `groupEnd` pops nothing.
  let mut passStack : Array Bool := #[]
  let mut filterWork : Nat := fwork0
  for i in [0:nodes.size] do
    match nodes.getD i default with
    | .shape s =>
      if skipDepth == 0 then
        let (cv', cache') := drawShape curRoot ⟨curW, curH, curClip, curOx, curOy⟩ doc cur cache s
        cur := cv'
        cache := cache'
    | .groupBegin g =>
      if skipDepth > 0 then skipDepth := skipDepth + 1
      else if g.dropped then skipDepth := 1
      else if g.passthrough then passStack := passStack.push true
      else
        -- The group's own `clip-path`, resolved once here rather than once per
        -- descendant shape, and applied to the finished layer at `groupEnd`.
        let (chain?, cache') := Clip.resolve doc curW curH curRoot cache g.clips
        cache := cache'
        -- T49: the group's `mask` chain; `none` is "not rendered".
        let mu := doc.maskUses.getD (g.mask.getD 0) default
        let maskMat := curRoot.mul mu.ctm
        let steps? : Option (Array Mask.Step) := match g.mask with
          | none => some #[]
          | some _ => match Mask.resolve doc mu with
            | .skip => none
            | .chain st => some st
        match chain?, steps? with
        | none, _ => skipDepth := 1
        | _, none => skipDepth := 1
        | some chain, some steps =>
        if !g.filters.isEmpty then
          -- T51: a filter layer.  Its rectangle is the filter region, not the
          -- ink, cut to resvg's `max_filter_bbox` (the canvas and twice its
          -- size past every edge) — and, past `maxFilterPixels`, to the canvas
          -- being painted, which bounds it by what already exists.
          let dev := curRoot.mul g.filterCtm
          match filterBox dev g.filters with
          | none => skipDepth := 1
          | some (fx0, fy0, fx1, fy1) =>
            let mx0 : Int := -(2 * (fullW : Int)) - curClip.vx
            let my0 : Int := -(2 * (fullH : Int)) - curClip.vy
            let mut bx0 := max fx0 mx0
            let mut by0 := max fy0 my0
            let mut bx1 := min fx1 (mx0 + 5 * (fullW : Int))
            let mut by1 := min fy1 (my0 + 5 * (fullH : Int))
            if bx1 > bx0 && by1 > by0 && (bx1 - bx0) * (by1 - by0) > (maxFilterPixels : Int) then
              bx0 := max bx0 curOx
              by0 := max by0 curOy
              bx1 := min bx1 (curOx + cur.w)
              by1 := min by1 (curOy + cur.h)
            if bx1 ≤ bx0 || by1 ≤ by0 then skipDepth := 1
            else
              let lw := (bx1 - bx0).toNat
              let lh := (by1 - by0).toNat
              let nprims := g.filters.foldl (fun n f => f.prims.foldl (· + ·.cost) n) 0
              filterWork := filterWork + nprims * lw * lh
              if nprims * lw * lh > maxFilterWork || filterWork > maxFilterTotal then
                err := some "filter budget"
                break
              if livePixels + lw * lh > maxLayerPixels then
                err := some "layer budget"
                break
              livePixels := livePixels + lw * lh
              let shift := Mat.translate (-(bx0 * 256)) (-(by0 * 256))
              stack := stack.push
                { cv := cur, ox := curOx, oy := curOy, clip := curClip,
                  opacity := opacityF32 g.opacity, opacityQ := opacityQ g.opacity,
                  blend := g.blend, clips := chain, masks := steps, maskMat,
                  filters := g.filters, fts := shift.mul dev, root := curRoot,
                  fw := curW, fh := curH, cache, lx := bx0, ly := by0 }
              passStack := passStack.push false
              cur := Canvas.new lw lh none
              curRoot := shift.mul curRoot
              curW := lw
              curH := lh
              curClip := { curClip with x0 := 0, y0 := 0, x1 := lw, y1 := lh,
                                        vx := curClip.vx + bx0, vy := curClip.vy + by0 }
              curOx := 0
              curOy := 0
              cache := {}
        else
        -- Nothing of the layer outside the clip survives, so the allocation
        -- shrinks to the clip's own box; an empty intersection skips the group.
        -- The same holds for every mask region.
        match nodeBox curRoot nodes i curClip with
        | none => skipDepth := 1
        | some r0 =>
          let r? : Option Clip := match Clip.chainBox chain with
            | none => if chain.isEmpty then some r0 else none
            | some (bx0, by0, bx1, by1) =>
              let x0 := Nat.max r0.x0 bx0
              let y0 := Nat.max r0.y0 by0
              let x1 := Nat.min r0.x1 bx1
              let y1 := Nat.min r0.y1 by1
              if x1 ≤ x0 || y1 ≤ y0 then none
              else some { r0 with x0, y0, x1, y1 }
          let r? := steps.foldl (fun r? st => r?.bind fun r =>
              let (bx0, by0, bx1, by1) := Mask.regionPx maskMat st.region
              let x0 := Nat.max r.x0 bx0.toNat
              let y0 := Nat.max r.y0 by0.toNat
              let x1 := Nat.min r.x1 bx1.toNat
              let y1 := Nat.min r.y1 by1.toNat
              if x1 ≤ x0 || y1 ≤ y0 then none
              else some { r with x0, y0, x1, y1 }) r?
          match r? with
          | none => skipDepth := 1
          | some r =>
          let lw := r.x1 - r.x0
          let lh := r.y1 - r.y0
          if livePixels + lw * lh > maxLayerPixels then
            err := some "layer budget"
            break
          livePixels := livePixels + lw * lh
          stack := stack.push
            { cv := cur, ox := curOx, oy := curOy, clip := curClip,
              opacity := opacityF32 g.opacity, opacityQ := opacityQ g.opacity,
              blend := g.blend, clips := chain, masks := steps, maskMat,
              root := curRoot, fw := curW, fh := curH }
          passStack := passStack.push false
          cur := Canvas.new lw lh none
          curClip := r
          curOx := r.x0
          curOy := r.y0
    | .groupEnd =>
      if skipDepth > 0 then skipDepth := skipDepth - 1
      else if passStack.back?.getD false then passStack := passStack.pop
      else
        passStack := passStack.pop
        match stack.back? with
        | none => pure ()
        | some parent =>
          livePixels := livePixels - cur.w * cur.h
          -- T67: an `feImage` renders its image or linked element first, the
          -- link through this function again on `fuel - 1` (`FeImage`).
          let mut fs := parent.filters
          for fi in [0:fs.size] do
            for j in FeImage.jobs (fs.getD fi default) parent.fts cur.w cur.h do
              match j.spec.href with
              | .data uri =>
                match FeImage.dataCanvas uri j.spec.aspect j.rw j.rh j.sx j.sy j.sw j.sh with
                | some cv => fs := FeImage.setPre fs fi j.prim cv
                | none => pure ()
              | .other => pure ()
              | .elem id =>
                renders := renders + FeImage.cost doc.events
                if renders > maxMaskRenders then
                  err := some "feImage budget"
                  break
                if livePixels + cur.w * cur.h + j.rw * j.rh > maxLayerPixels then
                  err := some "layer budget"
                  break
                match FeImage.subDoc doc.events id with
                | .error msg =>
                  err := some msg
                  break
                | .ok none => pure ()
                | .ok (some sd) =>
                  match renderNodes sd j.rw j.rh j.rw j.rh fuel (j.mat parent.fts) sd.nodes
                      (Canvas.new j.rw j.rh none) { curClip with x0 := 0, y0 := 0, x1 := j.rw, y1 := j.rh }
                      0 0 {} (livePixels + cur.w * cur.h + j.rw * j.rh) renders filterWork with
                  | .error msg =>
                    err := some msg
                    break
                  | .ok (icv, _, n, fw') =>
                    renders := n
                    filterWork := fw'
                    fs := FeImage.setPre fs fi j.prim icv
            if err.isSome then break
          if err.isSome then break
          -- resvg's order (`render_group`): the filter, then the clip, then the
          -- mask, then the opacity and blend mode composite.  A filter layer is
          -- filtered in its own frame and cropped back into the parent's.
          let placed : Option (Canvas × Nat × Nat × Clip) :=
            if parent.filters.isEmpty then some (cur, curOx, curOy, curClip)
            else
              let out := fs.foldl (fun c f => FilterApply.run f parent.fts c) cur
              (cropTo out (parent.lx - parent.ox) (parent.ly - parent.oy)
                  parent.cv.w parent.cv.h).map fun (c, nx, ny) =>
                let ax := nx + parent.ox
                let ay := ny + parent.oy
                (c, ax, ay, { parent.clip with x0 := ax, y0 := ay, x1 := ax + c.w, y1 := ay + c.h })
          if !parent.filters.isEmpty then
            curRoot := parent.root
            curW := parent.fw
            curH := parent.fh
            cache := parent.cache
          match placed with
          | none =>
            stack := stack.pop
            cur := parent.cv
          | some (lay, lox, loy, lclip) =>
            let mut done := Clip.applyToCanvas parent.clips lay lox loy
            -- T49: each mask's content, rendered over the layer's rectangle and
            -- multiplied by its region, becomes a coverage mask; they multiply
            -- the layer deepest link first (`mask::apply` recurses before it
            -- multiplies).
            let mut covs : Array Clip.Mask := #[]
            for st in parent.masks do
              let e := doc.masks.getD st.entry default
              renders := renders + 1
              if renders > maxMaskRenders then
                err := some "mask budget"
                break
              match renderNodes doc parent.fw parent.fh fullW fullH fuel
                  (parent.maskMat.mul st.content) e.nodes
                  (Canvas.new lay.w lay.h none) lclip lox loy cache
                  (livePixels + lay.w * lay.h) renders filterWork with
              | .error msg =>
                err := some msg
                break
              | .ok (mcv, c', n, fw') =>
                cache := c'
                renders := n
                filterWork := fw'
                let mcv := Clip.applyToCanvas
                  #[Mask.regionMask parent.fw parent.fh parent.maskMat st.region] mcv lox loy
                covs := covs.push (Mask.toClipMask mcv lox loy e.alpha)
            if err.isSome then break
            done := Clip.applyToCanvas covs.reverse done lox loy
            -- Popped *before* the composite so that the parent's pixel array is
            -- uniquely referenced and `compositeLayer` can update it in place.
            stack := stack.pop
            cur := parent.cv.compositeLayer done (lox - parent.ox) (loy - parent.oy)
              parent.opacity parent.opacityQ parent.blend
          curOx := parent.ox
          curOy := parent.oy
          curClip := parent.clip
  match err with
  | some e => return .error e
  | none => pure ()
  -- A `groupEnd` is emitted for every `groupBegin` (`Svg.interpret` pushes both
  -- from one place), so the stack is empty here; composite anything left over
  -- rather than dropping it if that ever stops being true (filters and masks
  -- of such a layer are not applied).
  for _ in [0:stack.size] do
    match stack.back? with
    | none => pure ()
    | some parent =>
      stack := stack.pop
      if parent.filters.isEmpty then
        let done := Clip.applyToCanvas parent.clips cur curOx curOy
        cur := parent.cv.compositeLayer done (curOx - parent.ox) (curOy - parent.oy)
          parent.opacity parent.opacityQ parent.blend
      else cur := parent.cv
      curOx := parent.ox
      curOy := parent.oy
  return .ok (cur, cache, renders, filterWork)

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
  -- The whole image's size, for resvg's `max_filter_bbox` (T51).
  let (fullW, fullH, _, _) ← canvasSetup doc.root { opts with viewport := none }
  let (cv, _, _, _) ← renderNodes doc w h fullW fullH (maskFuel + 1) rootMat doc.nodes
    (Canvas.new w h opts.background) clip 0 0 {} 0 0 0
  return (w, h, cv.toRgbaBytes)

/-- Bands per worker thread.

One band per thread is what a row split costs least, and it is also what makes
the slowest band the whole render: rows are not equal work, so a band that
lands on the busy part of the image finishes long after the others and every
other thread waits for it.  Measured at `--width 2000` on four cores (median of
15 interleaved runs), cutting *more* bands than threads and letting the task
pool hand them out as workers free up is worth 10-30 %:

| file | k = threads | k = 2·threads | k = 3·threads | k = 4·threads | k = 6·threads |
|---|---|---|---|---|---|
| `confetti` | 288 ms | 331 ms | 291 ms | **259 ms** | 266 ms |
| `16_stress_2000` | 566 ms | 486 ms | **480 ms** | 489 ms | 519 ms |
| `24_gradients` | 302 ms | 241 ms | **218 ms** | 220 ms | 224 ms |
| `26_layers` | 475 ms | 448 ms | 445 ms | 411 ms | **362 ms** |
| `icons` | 102 ms | 99 ms | 93 ms | **86 ms** | 87 ms |

Past that the per-band fixed cost — one `Canvas`, and one culling pass over
every shape in the document — starts to outweigh what better balance buys
(`16_stress_2000` has 2 001 shapes and pays about 13 ms per band for the
culling alone).  Four is where the two curves cross. -/
def bandsPerThread : Nat := 4

/-- How many bands to cut `h` output rows into for `threads` threads.

`1` means "render serially", which is what happens unless the caller asked for
at least two threads and the canvas is tall enough to be worth splitting: at
least `2·threads` rows, and never a band shorter than 32 rows, so the per-band
overhead stays small next to the work a band does. -/
def bandCount (threads h : Nat) : Nat :=
  if threads < 2 || h < 2 * threads then 1
  else Nat.max 1 (Nat.min (bandsPerThread * threads) (h / 32))

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
  if input.size > maxInput then throw s!"input {input.size} bytes exceeds the {maxInput} byte limit"
  let events ← Xml.parse input
  let doc ← Svg.interpret events
  -- T52: marker instancing happens once here, after `interpret` has resolved
  -- every element's style and every `<marker>`'s own content, and before
  -- anything below (size checks, band splitting, `drawShape`) sees `doc` --
  -- so a marker instance is culled, tiled and banded exactly like any other
  -- shape, with no changes to any of that machinery.
  let doc := Marker.expand doc
  -- T86: usvg's bounding-box refit of a root without a usable size, on the
  -- finished nodes; the size it picks is checked below like any other.
  let doc := RootFit.apply doc
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

end LeanSvg
