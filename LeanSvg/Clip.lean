import LeanSvg.Svg

/-!
# `clipPath` masks (T20)

Turns a `Svg.ClipEntry` into a chain of device-space clip masks, and multiplies
a shape's coverage mask by such a chain.  Everything is integer, bounded and
pure; `Effect.lean` and `render`'s type are untouched.

## What resvg does (`crates/resvg/src/clip.rs`, tiny-skia `Mask`)

An element with `clip-path` is rendered into its own layer.  The clip is then a
full-canvas pixmap filled opaque black, into which every child of the
`clipPath` is *filled* (its own `clip-rule`, its own transform, black, no
stroke, no opacity) with `BlendMode::Clear`; with anti-aliasing that lerps the
destination towards transparent by the coverage, so the pixmap's alpha ends up
as `a = Π (255 − cᵢ)` over the children, evaluated pairwise with tiny-skia's
`div255` (`(x + 255) >> 8`).  A child that carries its own `clip-path` is
drawn on a fresh transparent pixmap instead, clipped there, and composited with
`BlendMode::Xor` — the symmetric difference, `div255 (c·(255 − a) + a·(255 −
c))`, which is the same as `Clear` where nothing else has been drawn yet.  The
pixmap's alpha becomes a `Mask` and is inverted, `m = 255 − a`, so `m` is the
coverage of the union of the children.  If the `clipPath` element has a
`clip-path` of its own, that clip is applied to the layer first
(recursively, deepest first), then this one: `layer ← div255 (layer · m)` per
channel (`apply_mask`, the `DestinationIn` stage).  Finally the layer is
composited onto the canvas.

## What this module does

Two routes, and `Svg.interpret` decides which one an element takes.

**The layer** (`applyToCanvas`) is resvg's, and is what a *container* — the
root `svg`, a `g`, a `switch`, a `text` — gets, now that T22 has layers: the
`clip-path` makes the element a layer, the use is kept off the inherited chain
(`GroupInfo.clips` rather than `Style.clips`), and the mask multiplies the
finished layer once, just before the opacity/blend composite.  This is the
only route that gets the anti-aliased boundary right where two clipped
children overlap, because the coverage is applied to the composite rather than
to each of them.

**The coverage** (`applyChain`) is what a leaf shape with no other reason for
a layer keeps: `cov8 ← div255 (cov8 · m)` for every mask of the chain, in
resvg's order, on tiny-skia's 8-bit grid (`Clip.cov8`, the same map
`Canvas.fillMask` uses), and back to the mask's 0..65536 convention with the
rasterizer's own `⌈a·65536/255⌉`.  The map is a bijection on the values the
rasterizer produces, so a chain that is fully inside leaves the mask
byte-identical, and the alpha channel of an opaque shape over a transparent
canvas is exactly resvg's.  A single shape has nothing to overlap with, so all
that differs from resvg is the colour rounding on the clip's anti-aliased edge
(resvg rounds the layer's premultiplied colour first, then multiplies) — at
most one level, on edge pixels only — and it saves a canvas and a composite
per clipped shape.  A group degraded past `Svg.maxLayerDepth` falls back to
this route too, so it still clips.

Every mask is built in absolute device space with the ordinary rasterizer, so
the tile invariance of §3.5 carries over: a `--viewport` tile's clip masks are
the whole image's, shifted by whole pixels, and the per-pixel arithmetic above
does not care where a pixel sits.

Validity (usvg `clippath.rs`, `converter.rs`): a `clipPath` with a zero-scale
`transform`, with `objectBoundingBox` units on an element whose box has no
area, with no valid child (a child whose own clip is invalid is dropped), or
whose own `clip-path` is invalid, is invalid, and an element referencing it is
not rendered.  A reference to an id that does not exist is not an error: usvg
ignores the attribute.  A reference back to a `clipPath` that is being built
(a self reference, or a cycle) is treated as `none`, which is what usvg's
`fix_recursive_links` does to the innermost such link.  Chains are limited to
`maxDepth` nested clips; deeper ones are invalid.

Cost: one mask per distinct (clip, device transform, bounding box), cached for
the duration of a canvas, over the union of the children's device control
boxes ∩ canvas; folding a child costs its own mask's area.  Applying a chain
to a shape costs the shape's mask area times the chain length.
-/

namespace LeanSvg
namespace Clip

open Svg

/-- A clip mask in device space: `m` holds `w * h` values in `[0, 255]`, in
tiny-skia's `Mask` convention (255 = inside), over the canvas box
`[x0, x0 + w) × [y0, y0 + h)`.  Every pixel outside the box is outside the
clip; an empty box (`w = h = 0`) is a clip that hides everything. -/
structure Mask where
  x0 : Nat
  y0 : Nat
  w : Nat
  h : Nat
  m : Array Nat
deriving Inhabited

/-- tiny-skia `lowp::div255`. -/
@[inline] def div255 (x : Nat) : Nat := (x + 255) >>> 8

/-- The mask's value at canvas pixel `(x, y)`. -/
@[inline] def Mask.at (c : Mask) (x y : Nat) : Nat :=
  if x < c.x0 || y < c.y0 || x ≥ c.x0 + c.w || y ≥ c.y0 + c.h then 0
  else c.m.getD ((y - c.y0) * c.w + (x - c.x0)) 0

/-- 0..65536 coverage to tiny-skia's 0..255, exactly as `Canvas.fillMask`. -/
@[inline] def cov8 (cov : Nat) : Nat := (cov * 255 + 32768) >>> 16

/-- 0..255 back to 0..65536, exactly as `Raster.rasterize` (`cov8 ∘ cov16 = id`). -/
@[inline] def cov16 (a : Nat) : Nat := (a * 65536 + 254) / 255

/-- Multiply a coverage mask by a chain of clip masks, in order.  A pixel whose
8-bit coverage the chain leaves alone keeps its exact `cov` (a hairline's
off-grid value included); one the chain changes is re-quantised through
`cov16`, which `fillMask` maps back to the same 8-bit value. -/
def applyChain (chain : Array Mask) (m : Raster.Mask) : Raster.Mask := Id.run do
  if chain.isEmpty then return m
  let mut cov := m.cov
  for y in [0:m.h] do
    let row := y * m.w
    for x in [0:m.w] do
      let i := row + x
      let c := cov.getD i 0
      if c == 0 then continue
      let a0 := cov8 c
      let mut a := a0
      for cm in chain do
        if a == 0 then break
        let v := cm.at (m.x0 + x) (m.y0 + y)
        if v != 255 then a := div255 (a * v)
      if a != a0 then cov := cov.setIfInBounds i (cov16 a)
  return ⟨m.x0, m.y0, m.w, m.h, cov⟩

/-- `Pixmap::apply_mask` — tiny-skia's `DestinationIn` stage, which is
`lowp`-compatible (`LoadDestination`, `mask_u8`, `Store` all have lowp
implementations), so every channel of the premultiplied destination is scaled
by `div255`, the same map `foldChild` and `applyChain` use.

This is the resvg route for a clipped element: `clip::apply` multiplies the
element's *finished layer* by the mask once, where `applyChain` multiplies each
shape's coverage.  The two agree wherever one opaque shape covers a pixel; they
differ where two shapes in the same layer overlap on the clip's anti-aliased
boundary, because the per-shape route applies the coverage to each of them.

`(ox, oy)` is where the canvas' pixel `(0, 0)` sits in the device space the
masks were built in.  The masks are applied one after another, not composed
first: `div255` is not associative through a product, and resvg's nested clips
are nested `apply_mask` calls. -/
def applyToCanvas (chain : Array Mask) (cv : Canvas) (ox oy : Nat) : Canvas := Id.run do
  if chain.isEmpty then return cv
  let w := cv.w
  let h := cv.h
  let mut px := cv.px
  for y in [0:h] do
    let row := y * w
    for x in [0:w] do
      let i := row + x
      let p := px.getD i 0
      if p == 0 then continue
      let mut r := p >>> 24
      let mut g := (p >>> 16) &&& 255
      let mut b := (p >>> 8) &&& 255
      let mut a := p &&& 255
      let mut touched := false
      for cm in chain do
        if a == 0 then break
        let v := cm.at (ox + x) (oy + y)
        if v != 255 then
          touched := true
          r := div255 (r * v)
          g := div255 (g * v)
          b := div255 (b * v)
          a := div255 (a * v)
      if touched then px := px.setIfInBounds i (Canvas.pack r g b a)
  return ⟨w, h, px⟩

/-- The intersection of the chain's mask boxes, as `(x0, y0, x1, y1)`.  Every
mask is zero outside its own box, so a layer that a chain will be applied to
can be allocated over this rectangle alone; `none` is a chain that clips
everything away. -/
def chainBox (chain : Array Mask) : Option (Nat × Nat × Nat × Nat) := Id.run do
  let mut r : Option (Nat × Nat × Nat × Nat) := none
  for cm in chain do
    let b := (cm.x0, cm.y0, cm.x0 + cm.w, cm.y0 + cm.h)
    r := match r with
      | none => some b
      | some (x0, y0, x1, y1) =>
        some (Nat.max x0 b.1, Nat.max y0 b.2.1, Nat.min x1 b.2.2.1, Nat.min y1 b.2.2.2)
  match r with
  | some (x0, y0, x1, y1) => if x1 ≤ x0 || y1 ≤ y0 then return none else return r
  | none => return none

/-- The device-space box of a path's control points under `ctm`: contains the
flattened path (up to the floors in `cubicAt` and `Mat.apply`). -/
def ctrlBox (ctm : Mat) (cmds : Array PathCmd) : Option Box := Id.run do
  let mut b : Option Box := none
  for c in cmds do
    match c with
    | .moveTo p => b := Box.cover b (ctm.apply p)
    | .lineTo p => b := Box.cover b (ctm.apply p)
    | .cubicTo c1 c2 p =>
      b := Box.cover b (ctm.apply c1)
      b := Box.cover b (ctm.apply c2)
      b := Box.cover b (ctm.apply p)
    | .quadTo c p =>
      b := Box.cover b (ctm.apply c)
      b := Box.cover b (ctm.apply p)
    | .close => pure ()
  return b

/-- The accumulator for a `clipPath`'s union, over the given box ∩ canvas
widened by one pixel (a flattened point can floor one `Fx` below its control
box): the clip pixmap's alpha, all 255 (nothing drawn yet). -/
def newAcc (W H : Nat) (b : Option Box) : Mask :=
  match b with
  | none => ⟨0, 0, 0, 0, #[]⟩
  | some b =>
    let x0 := Int.toNat (Fx.floor b.x0 - 1)
    let y0 := Int.toNat (Fx.floor b.y0 - 1)
    let x1 := Nat.min W (Int.toNat (Fx.ceil b.x1 + 1))
    let y1 := Nat.min H (Int.toNat (Fx.ceil b.y1 + 1))
    if x1 ≤ x0 || y1 ≤ y0 then ⟨0, 0, 0, 0, #[]⟩
    else ⟨x0, y0, x1 - x0, y1 - y0, Array.replicate ((x1 - x0) * (y1 - y0)) 255⟩

/-- Draw one child's coverage into the accumulator: `Clear` for a plain child,
`Xor` for one that was clipped on its own layer (see the module comment).
Pixels of the child outside the accumulator are dropped. -/
def foldChild (acc : Mask) (child : Raster.Mask) (xor : Bool) : Mask := Id.run do
  let mut a := acc.m
  for y in [0:child.h] do
    let cy := child.y0 + y
    if cy < acc.y0 || cy ≥ acc.y0 + acc.h then continue
    for x in [0:child.w] do
      let cx := child.x0 + x
      if cx < acc.x0 || cx ≥ acc.x0 + acc.w then continue
      let c := cov8 (child.cov.getD (y * child.w + x) 0)
      if c == 0 then continue
      let i := (cy - acc.y0) * acc.w + (cx - acc.x0)
      let d := a.getD i 0
      let v := if xor then div255 (c * (255 - d) + d * (255 - c)) else div255 (d * (255 - c))
      a := a.setIfInBounds i v
  return { acc with m := a }

/-- `Mask::invert`: the drawn alpha to the clip's coverage. -/
def invert (acc : Mask) : Mask := { acc with m := acc.m.map (255 - ·) }

/-- A resolved clip: invalid (the element is not rendered), or the masks to
apply, in order. -/
inductive Res where
  | invalid
  | chain (ms : Array Mask)

/-- One mask is a function of the clip, its device transform, the referencing
element's box, and which clips are being built above it (a link back to one of
those is `none`, so the same clip can come out differently under a different
stack). -/
structure Key where
  entry : Nat
  a : Int
  b : Int
  c : Int
  d : Int
  e : Int
  f : Int
  bbox : Option (Int × Int × Int × Int)
  visited : Array Nat
deriving BEq, Hashable

abbrev Cache := Std.HashMap Key Res

/-- Nesting limit for clips on clips (self clips and children's clips). -/
def maxDepth : Nat := 8

/-- Does this clip's mask depend on the referencing element's bounding box?
Only `clipPathUnits="objectBoundingBox"` does, on this entry or on one of the
clips it applies to itself (a child's clip uses the *child's* box, never this
one, so children are not consulted).  `false` lets the cache key drop the box,
which is what makes one clip shared by many differently-placed shapes cost one
mask rather than one per shape.  Out of fuel says `true`, a cache miss at
worst. -/
def needsBBox (doc : Doc) : Nat → Nat → Bool
  | 0, _ => true
  | fuel + 1, ei =>
    let e := doc.clips.getD ei default
    e.objectBBox || (match e.selfClip with
      | some s => needsBBox doc fuel s
      | none => false)

/-- Divides a coordinate by 256: post-multiplied onto a child's matrix when
its `cmds` are on the 16.16 grid rather than `Fx`'s (`ClipChild.fine`, which
is how an `objectBoundingBox` fraction keeps its precision — see
`Svg.shapeCmds16`).  The composition costs at most one 16.16 unit of the
matrix, i.e. 1/256 px on a unit-square coordinate; the quantization it
replaces was half a device pixel. -/
def fineScale : Mat := Mat.mk' 256 0 0 256 0 0

/-- The device matrix of one `clipPath` child under the clip's own `T`. -/
def childMat (T : Mat) (ch : Svg.ClipChild) : Mat :=
  let m := T.mul ch.ctm
  if ch.fine then m.mul fineScale else m

/-- Build the mask chain of clip `ei` for a referencing element whose user
space maps to the device by `dev` and whose object bounding box (in that user
space) is `bbox`.  `fuel` bounds the nesting, `visited` is the stack of clips
above this one. -/
def build (doc : Doc) (W H : Nat) : (fuel : Nat) → Cache → (visited : Array Nat) →
    (ei : Nat) → (dev : Mat) → (bbox : Option Box) → Res × Cache
  | 0, cache, _, _, _, _ => (.invalid, cache)
  | fuel + 1, cache0, visited, ei, dev, bbox => Id.run do
    let key : Key :=
      ⟨ei, dev.a, dev.b, dev.c, dev.d, dev.e, dev.f,
       if needsBBox doc maxDepth ei then bbox.map (fun b => (b.x0, b.y0, b.x1, b.y1)) else none,
       visited⟩
    match cache0.get? key with
    | some r => return (r, cache0)
    | none => pure ()
    let mut cache := cache0
    let e := doc.clips.getD ei default
    if !e.transformValid then return (.invalid, cache.insert key .invalid)
    let mut T := dev.mul e.transform
    if e.objectBBox then
      match bbox with
      | some b =>
        if Svg.Box.nonZero b then T := T.mul (Svg.Box.unitMat b)
        else return (.invalid, cache.insert key .invalid)
      | none => return (.invalid, cache.insert key .invalid)
    let visited' := visited.push ei
    -- the clipPath's own clip-path: same element space, same box
    let mut selfMasks : Array Mask := #[]
    match e.selfClip with
    | some s =>
      if !(visited'.contains s) then
        let (r, c') := build doc W H fuel cache visited' s dev bbox
        cache := c'
        match r with
        | .invalid => return (.invalid, cache.insert key .invalid)
        | .chain ms => selfMasks := ms
    | none => pure ()
    -- the union's box, then the children one at a time
    let mut box : Option Box := none
    for ch in e.children do
      if ch.visible then box := Box.union box (ctrlBox (childMat T ch) ch.cmds)
    let mut acc := newAcc W H box
    let mut hasChild := false
    for ch in e.children do
      let mut ok := true
      let mut chain : Array Mask := #[]
      for u in ch.clips do
        let use := doc.uses.getD u default
        match use.entry with
        | none => pure ()
        | some ue =>
          -- A link back to a `clipPath` already being built is the cycle
          -- `fix_recursive_links` rewrites to `none`: the link is dropped,
          -- the child stays (`masking/clipPath/self-recursive`,
          -- `recursive-on-child`).
          if !(visited'.contains ue) then
            let (r, c') := build doc W H fuel cache visited' ue (T.mul use.ctm) use.bbox
            cache := c'
            match r with
            | .invalid => ok := false
            | .chain ms => chain := chain ++ ms
      if !ok then continue
      hasChild := true
      if !ch.visible || acc.w == 0 then continue
      let cT := childMat T ch
      let polys := flatten cT ch.cmds
      let pts := polys.map fun p => p.pts.map cT.apply
      match Raster.rasterize W H pts ch.evenOdd with
      | some m => acc := foldChild acc (applyChain chain m) (!ch.clips.isEmpty)
      | none => pure ()
    if !hasChild then return (.invalid, cache.insert key .invalid)
    let res := Res.chain (selfMasks.push (invert acc))
    return (res, cache.insert key res)

/-- The masks to apply to a shape with clip uses `clips` (outermost first, as
`Style.clips` stores them; applied innermost first, as resvg's nested layers
are), or `none` when one of them is invalid and the shape is not rendered.
`base` maps the space the uses' `ctm`s are relative to onto the device. -/
def resolve (doc : Doc) (W H : Nat) (base : Mat) (cache : Cache) (clips : Array Nat) :
    Option (Array Mask) × Cache := Id.run do
  let mut cache := cache
  let mut out : Array Mask := #[]
  for u in clips.reverse do
    let use := doc.uses.getD u default
    match use.entry with
    | none => pure ()
    | some ue =>
      let (r, c') := build doc W H maxDepth cache #[] ue (base.mul use.ctm) use.bbox
      cache := c'
      match r with
      | .invalid => return (none, cache)
      | .chain ms => out := out ++ ms
  return (some out, cache)

end Clip
end LeanSvg
