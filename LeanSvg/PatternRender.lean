import LeanSvg.Svg

/-!
# `pattern` tile rasterisation and sampling

`LeanSvg/Pattern.lean` (`Pat`) holds the geometry; this module holds the part
that needs `Svg.Node` — rendering a pattern's content onto its own small
canvas and sampling that canvas per device pixel — which is why it cannot
live in `Pattern.lean` (that would make `Svg.lean` depend on itself: `Pat`
is imported *by* `Svg.lean`, but rendering content needs `Svg.Node`, which
`Svg.lean` defines).  `Render.lean` imports this module and calls `Pat.build`
from `drawShape`'s paint dispatch, exactly where it calls `Grad.build` for a
gradient.

## Recursion

A pattern's content can itself paint with another pattern (`pattern-on-child`,
and — bounded, not followed forever — a cycle, `self-recursive`).
`Pat.build` therefore recurses into itself, fuelled by a plain `Nat` that
drops by one every time content asks for *another* tile: matched as
`0 | n + 1` and passed down as `n`, which is ordinary structural recursion on
`fuel`, no `partial` and no manual termination proof, even though the
recursive call sits inside a local closure several `let`s deep (drawing one
content shape, itself inside the loop that draws a whole content array).
`0` paints that one fill or stroke as nothing, never an error — the same
outcome usvg's own cycle-breaking reaches for a pattern that (directly or
through content) references itself (a pattern being resolved is not yet in
its id cache, so the inner reference resolves as unresolvable, and an
unresolvable pattern is never rendered, only its `url()` fallback is — which
`resolvePaint` has already substituted *before* `Paint.pattern` is even built,
so nothing is exactly the fallback here too).  Reached by a bound rather than
a visited set, this does not reproduce usvg's first-reference-wins asymmetry
on a mutual cycle (`recursive-on-child`) but does reject it, boundedly.

## What is *not* reproduced

Pattern content has no `clip-path` support (a `clip-path` on a content
element or group is silently ignored) and no dashed strokes; both are
accepted gaps, not floors under real documents this task's scope needs.  The
sixteen-tap bicubic filter (`sampleBicubic`) is computed in the same `F32`
IEEE emulation `Canvas.compositeBlend` already carries for layers, but the
*outcome* is rounded to 8 bits and then composited with the ordinary integer
`Canvas.blendOver`/`div255` pipeline `Canvas.fillMaskShader` already uses,
rather than carrying the whole coverage-and-opacity composite through `F32`
as resvg's own highp pipeline does (every pattern fill is highp there, since
`SpreadMode::Repeat`'s `Stage::Repeat` has no lowp implementation either).
That is at most the one level of rounding `Canvas.compositeNormal`'s own
doc comment already accepts for a cheaper integer composite, and it keeps a
pattern fill on the same, already-verified per-pixel path as a gradient. -/

namespace LeanSvg
namespace Pat

/-- Fuel for a pattern whose content itself paints with a pattern: how many
tiles deep a fill may nest before a further reference falls back to its own
`url()` fallback (`.none` with no explicit one). -/
def patternFuel : Nat := 6

/-- Largest tile edge, in device pixels. -/
def maxTileDim : Nat := 2048
/-- Largest tile area, in device pixels (2048² would already hit this). -/
def maxTilePixels : Nat := 1048576

/-- A built pattern shader: the rendered tile and the affine map from an
absolute device pixel to a coordinate in the tile's own pixel grid (16.16,
exactly `Grad.Rt`'s `px`/`py` convention, so the two share `Grad.Axis`,
`Grad.Aff` and the viewport-origin folding that keeps a tile byte-identical
under `--viewport`, DESIGN §3.8). -/
structure Rt where
  tileW : Nat
  tileH : Nat
  cv : Canvas
  px : Grad.Axis
  py : Grad.Axis
  /-- `Transform::is_translate` on the combined `ctm · patternTransform`:
  false (nearest) for the common axis-aligned case, true (bicubic) only when
  that matrix carries a rotation or skew (`PatternRender`'s doc comment). -/
  bicubic : Bool
  /-- The fill/stroke opacity and the inherited group opacity, combined once
  on the `0..255` grid (`Svg.opacityToU8`), multiplied into every sample. -/
  alpha8 : Nat
deriving Inhabited

inductive Built where
  | skip
  | tile (sh : Rt)
deriving Inhabited

/-! ## Sampling -/

/-- Unpack one packed premultiplied pixel (`Canvas.pack`'s own layout). -/
@[inline] def unpack (v : Nat) : Nat × Nat × Nat × Nat :=
  ((v >>> 24) &&& 255, (v >>> 16) &&& 255, (v >>> 8) &&& 255, v &&& 255)

/-- The tile pixel at `(ix, iy)`, `SpreadMode::Repeat`-wrapped (`Int.emod`
against a positive modulus is already the Euclidean wrap tiny-skia's
`exclusive_repeat` computes, DESIGN-style derivation in `Pattern.lean`'s
header). -/
@[inline] def texelAt (sh : Rt) (ix iy : Int) : Nat :=
  let x := (Int.emod ix (sh.tileW : Int)).toNat
  let y := (Int.emod iy (sh.tileH : Int)).toNat
  sh.cv.px.getD (y * sh.tileW + x) 0

/-- `bicubic_near`/`bicubic_far`, tiny-skia's non-uniform cubic filter
weights, in the same `F32` IEEE emulation `Canvas.compositeBlend` uses. -/
def bicubicNear (t : F32) : F32 :=
  let m := fun a b c => F32.add (F32.mul a b) c
  m t (m t (m (F32.neg (F32.ofRat 21 18)) t (F32.ofRat 27 18)) (F32.ofRat 9 18)) (F32.ofRat 1 18)

def bicubicFar (t : F32) : F32 :=
  F32.mul (F32.mul t t) (F32.add (F32.mul (F32.ofRat 7 18) t) (F32.neg (F32.ofRat 6 18)))

/-- The premultiplied 8-bit colour at tile-space `(x16, y16)` (16.16), by the
sixteen-tap bicubic filter (`sampler_4x4`/`bicubic` in tiny-skia's `highp`
pipeline): four consecutive integer taps per axis around the pixel centre,
weighted separably and rounded once (`F32.toU8`, which is exactly tiny-skia's
`Clamp0`+`ClampA`+`unnorm` composed). -/
def sampleBicubic (sh : Rt) (x16 y16 : Int) : Nat × Nat × Nat × Nat :=
  -- `c = round(x)`, `fx = (x + 0.5) - c`, both in 16.16; `fx ∈ [0, 65536)`.
  let cx := Int.ediv (x16 + 32768) 65536
  let fx := x16 + 32768 - cx * 65536
  let cy := Int.ediv (y16 + 32768) 65536
  let fy := y16 + 32768 - cy * 65536
  let fxF := F32.ofRat fx.toNat 65536
  let fyF := F32.ofRat fy.toNat 65536
  let oneF := F32.one
  let wx : Array F32 :=
    #[bicubicFar (F32.sub oneF fxF), bicubicNear (F32.sub oneF fxF), bicubicNear fxF, bicubicFar fxF]
  let wy : Array F32 :=
    #[bicubicFar (F32.sub oneF fyF), bicubicNear (F32.sub oneF fyF), bicubicNear fyF, bicubicFar fyF]
  Id.run do
    let mut r : F32 := 0
    let mut g : F32 := 0
    let mut b : F32 := 0
    let mut a : F32 := 0
    for j in [0:4] do
      let wyj := wy.getD j 0
      for i in [0:4] do
        let w := F32.mul (wx.getD i 0) wyj
        let (tr, tg, tb, ta) := unpack (texelAt sh (cx - 2 + i) (cy - 2 + j))
        r := F32.add r (F32.mul w (F32.ofRat tr 255))
        g := F32.add g (F32.mul w (F32.ofRat tg 255))
        b := F32.add b (F32.mul w (F32.ofRat tb 255))
        a := F32.add a (F32.mul w (F32.ofRat ta 255))
    return (F32.toU8 r, F32.toU8 g, F32.toU8 b, F32.toU8 a)

/-- The premultiplied 8-bit colour a device pixel samples from the tile:
nearest for the common (unrotated, unskewed) case, which is also exactly what
one full-weight bicubic tap would give (`x/255` and back round-trips exactly
for every `x ∈ [0, 255]` at `f32`'s precision), so this is not an
approximation of that path, only a cheaper way to compute the same answer. -/
def sampleAt (sh : Rt) (x16 y16 : Int) : Nat × Nat × Nat × Nat :=
  if sh.bicubic then sampleBicubic sh x16 y16
  else unpack (texelAt sh (Int.ediv x16 65536) (Int.ediv y16 65536))

end Pat

namespace Canvas

/-- `fillMask` with the pattern shader as the per-pixel paint source: the
pattern equivalent of `fillMaskShader`, on the same coverage/opacity pipeline
(`Canvas.blendOver`, `div255`), reading the source colour from the tile
instead of a gradient ramp. -/
def fillMaskPattern (cv : Canvas) (m : Raster.Mask) (sh : Pat.Rt) : Canvas := Id.run do
  let w := cv.w
  let mw := m.w
  let mut px := cv.px
  for y in [0:m.h] do
    let mrow := y * mw
    let prow := (m.y0 + y) * w + m.x0
    let ay := m.y0 + y
    let hiX := sh.px.cH * ay + sh.px.eH
    let loX := sh.px.cL * ay + sh.px.eL
    let hiY := sh.py.cH * ay + sh.py.eH
    let loY := sh.py.cL * ay + sh.py.eL
    for x in [0:mw] do
      let cov := m.cov.getD (mrow + x) 0
      if cov ≤ covNone then continue
      let ax := m.x0 + x
      let px16 := sh.px.aH * ax + hiX + Int.ofNat ((sh.px.aL * ax + loX) >>> 16)
      let py16 := sh.py.aH * ax + hiY + Int.ofNat ((sh.py.aL * ax + loY) >>> 16)
      let (sr, sg, sb, sa) := Pat.sampleAt sh px16 py16
      if sa == 0 then pure ()
      else
        let idx := prow + x
        let cov8 := if cov ≥ covFull then 255 else (cov * 255 + 32768) >>> 16
        let covA8 := div255 (cov8 * sh.alpha8)
        let dst := px.getD idx 0
        let nv := blendOver dst (div255 (sr * covA8)) (div255 (sg * covA8))
                    (div255 (sb * covA8)) (div255 (sa * covA8))
        px := px.setIfInBounds idx nv
  return ⟨w, cv.h, px⟩

end Canvas

namespace Pat

/-! ## Content rendering -/

/-- The opacity a layer composites with, on `Canvas.opGrid` (256 times
`Svg.opacityOne`'s own grid finer than the `u8` a fill's alpha is quantised
to) — `Render.opacityQ`'s own formula, copied here because `Render.lean`
imports this module, not the other way round. -/
def opacityQ (o : Nat) : Nat :=
  if o ≥ Svg.opacityOne then Canvas.opGrid
  else (o * Canvas.opGrid * 2 / Svg.opacityOne + 1) / 2

/-- `Render.opacityF32`, copied for the same reason. -/
def opacityF32 (o : Nat) : F32 :=
  if o ≥ Svg.opacityOne then F32.one else F32.ofRat o Svg.opacityOne

/-- Turn a resolved `<pattern>` into a tile shader for one shape's fill or
stroke — `Grad.build`'s pattern counterpart, including its viewport-origin
trick: `(ox, oy)` is the `--viewport` origin in output pixels, folded into the
map's constant term rather than into `ctm` itself, so a tile's coefficients
are the full render's, evaluated at the same absolute pixel (DESIGN §3.8).

`cmds`/`ctm0` are the *referencing* shape's own path and CTM, exactly as
`Grad.build` takes them (needed only for `objectBoundingBox`'s tight bounding
box, `Grad.tightBox`).

Drawing the tile's own content (`walkNodes`/`drawOneShape` below) is nested
*inside* `build` itself, as local closures, rather than split into their own
top-level definitions: `drawOneShape`'s only recursive case — another
`Paint.pattern` — calls `build doc n j …` where `n` comes from matching
*this* call's own `fuel` as `n + 1` a few lines up, so the whole thing is one
function's ordinary structural recursion on `fuel`, however many local `let`s
the recursive call sits under. Splitting it into `build`/`walkNodes`/
`drawOneShape` as three top-level definitions instead would make every one of
them call one defined *after* it in the file, which Lean rejects outright —
and reordering does not help, since the cycle is real; only folding the
recursive one into a single `def` does. -/
def build (doc : Svg.Doc) (fuel : Nat) (idx : Nat) (cmds : Array PathCmd) (ctm0 : Mat)
    (ox oy : Int) (fillOp groupOp : Nat) : Built :=
  let res := doc.patterns.defs.getD idx default
  if !res.valid then .skip else
  let needBox := res.oBB || (res.contentOBB && res.viewBox.isNone)
  let boxOpt : Option (Int × Int × Int × Int) :=
    if !needBox then some (0, 0, 0, 0)
    else match Grad.tightBox cmds with
      | none => none
      | some b =>
        let bw := b.x1 - b.x0
        let bh := b.y1 - b.y0
        if bw ≤ 0 || bh ≤ 0 then none else some (b.x0 * 256, b.y0 * 256, bw * 256, bh * 256)
  match boxOpt with
  | none => .skip
  | some box =>
  match absRect res (if res.oBB then some box else none) with
  | none => .skip
  | some (xAbs, yAbs, wAbs, hAbs) =>
  let ctm := if ox == 0 && oy == 0 then ctm0
             else (Mat.translate (ox * 256) (oy * 256)).mul ctm0
  let m := ctm.mul res.transform
  let sx16 := Grad.sqrt16 (Grad.norm2 m.a m.b)
  let sy16 := Grad.sqrt16 (Grad.norm2 m.c m.d)
  if sx16 == 0 || sy16 == 0 then .skip else
  let round16 := fun (v : Int) => Int.ediv (v + 32768) 65536
  let pxW := (round16 (Grad.mul16 wAbs sx16)).toNat
  let pxH := (round16 (Grad.mul16 hAbs sy16)).toNat
  if pxW == 0 || pxH == 0 || pxW > maxTileDim || pxH > maxTileDim || pxW * pxH > maxTilePixels then
    .skip
  else
  let bicubic := !(m.b == 0 && m.c == 0 && m.a > 0 && m.d > 0)
  let contentMat : Mat := match res.viewBox with
    | some (vx, vy, vw, vh) => viewBoxMat vx vy vw vh res.alignX res.alignY res.slice res.alignNone
        wAbs hAbs
    | none =>
      if res.contentOBB then
        let (_, _, bw, bh) := box
        if bw > 0 && bh > 0 then Mat.scale16 bw bh else Mat.identity
      else Mat.identity
  let tileRootMat := (Mat.scale16 sx16 sy16).mul contentMat
  -- One content shape (fill, then stroke); no `clip-path`, no dashes (module
  -- doc's accepted gaps for pattern content).  The `Paint.pattern` case is
  -- `build`'s only recursive call site.
  let drawOneShape := fun (cur : Canvas) (s : Svg.Shape) =>
    let st := s.style
    let sctm := tileRootMat.mul st.ctm
    let polys := flatten sctm s.cmds
    let paintWith := fun (cv : Canvas) (p : Svg.Paint) (msk : Raster.Mask) (op : Nat) =>
      match p with
      | .none => cv
      | .solid c => cv.fillMask msk c (Svg.opacityToU8 c.a op st.opacity)
      | .gradient i =>
        match Grad.build st.defs i s.cmds sctm 0 0 op st.opacity with
        | .skip => cv
        | .solid c a8 => cv.fillMask msk c a8
        | .grad sh => cv.fillMaskShader msk sh
      -- `resolvePaint` has already turned an unresolvable or invalid
      -- reference into its `url()` fallback (exactly as it does for a
      -- gradient), so what reaches here is always at least geometrically
      -- valid; the one remaining way to paint nothing is the same one a
      -- gradient has, a bounding box `build` cannot get (a zero-area shape
      -- under `objectBoundingBox`) — usvg's rule for that case is "not
      -- rendered", not "use the fallback", so `.skip` here matches `.skip`
      -- on `Grad.build` above: leave `cv` unchanged.
      | .pattern j =>
        match fuel with
        | 0 => cv
        | n + 1 =>
          match build doc n j s.cmds sctm 0 0 op st.opacity with
          | .skip => cv
          | .tile sh => cv.fillMaskPattern msk sh
    let drawFill := fun (cv : Canvas) => match st.fill with
      | .none => cv
      | _ =>
        let dev := polys.map fun p => p.pts.map sctm.apply
        match Raster.rasterize pxW pxH dev st.evenOdd with
        | some msk => paintWith cv st.fill msk st.fillOpacity
        | none => cv
    let drawStroke := fun (cv : Canvas) => match st.stroke with
      | .none => cv
      | _ =>
        if st.strokeWidth ≤ 0 then cv
        else
          let ss : StrokeStyle := ⟨st.strokeWidth, st.cap, st.join, st.miterLimit⟩
          let outline := polys.foldl (fun out p => strokePoly ss p out) #[]
          let dev := outline.map fun p => p.map sctm.apply
          match Raster.rasterize pxW pxH dev false with
          | some msk => paintWith cv st.stroke msk st.strokeOpacity
          | none => cv
    (if st.strokeFirst then drawFill (drawStroke cur) else drawStroke (drawFill cur))
  -- The content array itself: shapes through `drawOneShape`, `groupBegin`/
  -- `groupEnd` composited with `Canvas.compositeLayer` exactly as
  -- `Render.renderRgba` does, except the layer canvas is always the tile's
  -- own full size (patterns are small; the box-shrinking optimisation
  -- `Render.nodeBox` buys for a big document is not worth its own code path
  -- here).
  let cv := Id.run do
    let mut cur := Canvas.new pxW pxH none
    let mut stack : Array (Canvas × F32 × Nat × BlendMode) := #[]
    for node in doc.patternContent.getD res.contentSlot #[] do
      match node with
      | .shape s => cur := drawOneShape cur s
      | .groupBegin g =>
        stack := stack.push (cur, opacityF32 g.opacity, opacityQ g.opacity, g.blend)
        cur := Canvas.new pxW pxH none
      | .groupEnd =>
        match stack.back? with
        | none => pure ()
        | some (parent, opF32, opQ, blend) =>
          stack := stack.pop
          cur := parent.compositeLayer cur 0 0 opF32 opQ blend
    return cur
  let invSx := Grad.div16 65536 sx16
  let invSy := Grad.div16 65536 sy16
  let scaleInv : Grad.Aff := { a := invSx, b := 0, c := 0, d := invSy, e := 0, f := 0 }
  let transl : Grad.Aff := { a := 65536, b := 0, c := 0, d := 65536, e := xAbs, f := yAbs }
  let patT : Grad.Aff := Grad.Aff.ofMat res.transform
  let frame := patT.comp (transl.comp scaleInv)
  match (Grad.Aff.ofMat ctm).comp frame |>.invert with
  | none => .skip
  | some (ax, cx, ex, ay, cy, ey) =>
    .tile { tileW := pxW, tileH := pxH, cv := cv,
            px := Grad.Axis.mk3 ax cx (ex + ax * ox + cx * oy),
            py := Grad.Axis.mk3 ay cy (ey + ay * ox + cy * oy),
            bicubic := bicubic, alpha8 := Svg.opacityToU8 255 fillOp groupOp }

end Pat
end LeanSvg
