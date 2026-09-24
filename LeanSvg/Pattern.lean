import LeanSvg.Shader

/-!
# `pattern` paint servers — geometry and definitions table

Mirrors `LeanSvg/Shader.lean`'s split for gradients: this module holds the
*data* (the pre-pass's raw attributes, `href` inheritance, and the pure
geometry a fill needs) with no dependency on `Svg.Node`, so `Svg.lean` can
import it for `Paint.pattern` and the defs table.  What a `<pattern>` element
actually *draws* — its content, which needs the style cascade and therefore
`Svg.Node`/`Svg.Style` — cannot live here without a dependency cycle
(`Svg.lean` would have to import back), so it is collected by `Svg.lean`
itself (`patternContentShapes`, alongside `defsScan`) into a plain
`Array (Array Svg.Node)` keyed by this module's raw index, and the actual
tile rasterisation (`LeanSvg/PatternRender.lean`) is a separate module
imported only by `Render.lean`.

## What is matched

usvg (`crates/usvg/src/parser/paint_server.rs`, `convert_pattern` /
`to_user_coordinates`) decides the semantics: `patternUnits` (default
`objectBoundingBox`), `patternContentUnits` (default `userSpaceOnUse`),
`viewBox` + `preserveAspectRatio`, `x/y/width/height`, `href` inheritance
(every attribute here; usvg does *not* inherit `patternTransform` —
`SvgNode::resolve_transform` never walks the `href` chain — but SVG and
Chromium do, and so do we since T104), a bounded href chain with cycles rejected as usvg's `HrefIter`
does (self- or origin-reference stops it), and zero-size → invalid.  The
*content* an element paints with is the first link in the chain (self first)
that has any own children (`find_pattern_with_children`); a chain that finds
none is invalid, and the fill falls back to its `url()` fallback colour.

resvg (`crates/resvg/src/path.rs::render_pattern_pixmap`) decides the
rasterisation: the tile pixmap's resolution follows the *current* CTM's scale
(`Transform::get_scale` of `ctm · patternTransform`) so a zoomed pattern stays
sharp, and the shader samples it with `tiny_skia::FilterQuality::Bicubic` —
which downgrades to nearest-neighbour whenever that combined transform is a
pure (positive, unrotated) scale-then-translate, `Transform::is_translate`,
which is the common case (`PatternRender.useBicubic` decides it the same way,
from the matrix's own coefficients rather than a float scale/inverse
round-trip). -/

namespace LeanSvg
namespace Pat

/-! ## Caps -/

/-- Largest number of `<pattern>` elements kept.  Far tighter than
`Grad.maxDefs`: unlike a gradient, a pattern's *content* needs its own bounded
walk over the event stream (`patternContentShapes`), so the pre-pass cost is
`O(events × maxDefs)` rather than `O(events)` — this still bounds it, just
at a smaller constant a hostile file cannot multiply up. -/
def maxDefs : Nat := 256
/-- Longest `id` (and longest `url(#…)` reference) that can match. -/
def maxIdLen : Nat := Grad.maxIdLen
/-- Fuel for the `href` chain, exactly as `Grad.hrefFuel`. -/
def hrefFuel : Nat := Grad.hrefFuel
/-- Hash buckets over the ids. -/
def bucketCount : Nat := 1024

/-- One `<pattern>` element exactly as written.  `none` on a field (other
than `transform`, which is never inherited) means the attribute was absent,
so `resolve` looks along the `href` chain. -/
structure RawDef where
  id : String := ""
  href : String := ""
  /-- `some true` = `objectBoundingBox`, `some false` = `userSpaceOnUse`
  (`patternUnits`, default `objectBoundingBox`). -/
  oBB : Option Bool := none
  /-- `patternContentUnits`, default `userSpaceOnUse`. -/
  contentOBB : Option Bool := none
  /-- `patternTransform` as written (identity when absent). -/
  transform : Mat := Mat.identity
  /-- T104: whether `patternTransform` was present, so `resolve` can inherit
  it along the `href` chain. -/
  hasTransform : Bool := false
  x : Option Grad.LenPct := none
  y : Option Grad.LenPct := none
  width : Option Grad.LenPct := none
  height : Option Grad.LenPct := none
  /-- `minx miny w h`, 16.16, clamped the way `Render.canvasSetup`'s root
  `viewBox` is; `none` when absent or unparseable. -/
  viewBox : Option (Int × Int × Int × Int) := none
  /-- `preserveAspectRatio`: `align x`, `align y` (0/1/2 = min/mid/max),
  `slice`, and whether `align` was the `none` keyword (only meaningful
  alongside a `viewBox`).  `none` when the attribute is absent. -/
  aspect : Option (Nat × Nat × Bool × Bool) := none
  /-- Whether the pre-pass saw at least one child *element* directly inside
  this `<pattern>` (usvg's `has_children`, checked before any validity
  filtering — a `display:none` child still counts). -/
  hadChildren : Bool := false
  /-- The event index this element opened at, so `Svg.lean`'s main walk can
  find where to collect its content (`Svg.patternContentShapes`). -/
  eventIdx : Nat := 0
deriving Repr, Inhabited

/-- A resolved `<pattern>`: geometry only, in the gradient module's own 16.16
convention (`Grad.LenPct`'s number, already turned into a plain fraction-or-
length by `resolve`'s `conv`).  `contentSlot` is a raw index, not the content
itself — content needs `Svg.Node`, which this module cannot depend on
(`Svg.lean` imports `Pat`, not the other way round) — so `Svg.lean` collects
one content array per *raw* pattern index (`patternContentShapes`, run once
per `RawDef` regardless of whether anything ends up using it) and
`PatternRender.build` reads `doc.patternContent.getD contentSlot #[]`. -/
structure Resolved where
  /-- Usable at all: some link in the chain has content, and the resolved
  `x/y/width/height` (themselves independent of any bounding box) are
  positive — usvg's `NonZeroRect::from_xywh`, checked before
  `objectBoundingBox` ever scales them by one. -/
  valid : Bool := false
  oBB : Bool := true
  contentOBB : Bool := false
  transform : Mat := Mat.identity
  x : Int := 0
  y : Int := 0
  w : Int := 0
  h : Int := 0
  viewBox : Option (Int × Int × Int × Int) := none
  alignX : Nat := 1
  alignY : Nat := 1
  slice : Bool := false
  alignNone : Bool := false
  /-- The raw index (self or an `href` ancestor) whose collected content this
  entry paints with; meaningful only when `valid`. -/
  contentSlot : Nat := 0
deriving Repr, Inhabited

structure Defs where
  defs : Array Resolved := #[]
  buckets : Array (Array Nat) := #[]
  ids : Array String := #[]
deriving Repr, Inhabited

def hashId (s : String) : Nat := (hash s).toNat % bucketCount

/-- Index of the pattern with this id, or `none`.  The first element with a
given id wins, as in usvg's `element_by_id`. -/
def Defs.lookup (d : Defs) (id : String) : Option Nat := Id.run do
  if d.buckets.isEmpty || id.isEmpty || id.length > maxIdLen then return none
  for i in d.buckets.getD (hashId id) #[] do
    if d.ids.getD i "" == id then return some i
  return none

/-- The `href` chain of `i`, `i` itself first — identical in shape to
`Grad.chainOf`: stops after `hrefFuel` links, at an id that names no pattern,
and at a link already on the chain (a self- or origin-reference, matching
usvg's `HrefIter`). -/
def chainOf (raws : Array RawDef) (find : String → Option Nat) (i : Nat) : Array Nat :=
  Id.run do
    let mut out : Array Nat := #[i]
    let mut cur := i
    for _ in [0:hrefFuel] do
      let h := (raws.getD cur default).href
      if h.isEmpty then break
      match find h with
      | none => break
      | some j =>
        if out.contains j then break
        out := out.push j
        cur := j
    return out

/-- The first non-`none` value along the chain: every pattern attribute may
come from any link (`resolve_pattern_attr` only checks
that the link's tag is `pattern`, which every entry in `raws` already is). -/
def pickCommon (raws : Array RawDef) (ch : Array Nat) (get : RawDef → Option α) :
    Option α := Id.run do
  for j in ch do
    match get (raws.getD j default) with
    | some v => return some v
    | none => pure ()
  return none

/-- The first link (self first) with its own children — usvg's
`find_pattern_with_children`. -/
def firstWithChildren (raws : Array RawDef) (ch : Array Nat) : Option Nat := Id.run do
  for j in ch do
    if (raws.getD j default).hadChildren then return some j
  return none

/-- `roundDiv a b`, round-half-away-from-zero: unlike `Int.ediv`'s floor, this
matches `scaleDecimal`'s own rounding, and — see `coordScale`'s doc comment —
is what keeps a plain-number and a percent spelling of the same fraction
resolving to the exact same number. -/
def roundDiv (a b : Int) : Int :=
  if b == 0 then 0
  else if a ≥ 0 then Int.ediv (2 * a + b) (2 * b)
  else -(Int.ediv (2 * (-a) + b) (2 * b))

/-- The scale `x/y/width/height` are parsed at (`Svg.parsePatCoordFine`) when
they still might need multiplying by a bounding box: 2^32 rather than 16.16's
2^16.  `objectBoundingBox`'s fraction is usually small (`0.05`–`0.2` in this
task's own corpus) and gets multiplied by a bounding box that can be large
(hundreds of user units), so 16.16's one part in 65536 of quantisation error
in the *fraction* becomes tens of *user units* of error in the *product* —
`0.05` rounds to `3277/65536 = 0.050003…` at 16.16, 0.0003 user units off,
which sounds negligible until a checkerboard `<pattern>` repeats it every
tile: `patternUnits=objectBoundingBox` (bbox 160×70, tile 32×14) came out with
every tile boundary shifted a whole device pixel from resvg's `f32` (whose own
rounding error is nine orders of magnitude smaller).  16.16 stays the
representation for everything downstream of one multiply-then-round
(`absRect`), which is precise enough there; only the fraction itself, and the
bounding box side it multiplies, need the wider grid, and only until that one
combined division. -/
def coordScale : Int := 4294967296

/-- `convert_length`: a plain number (or one with a unit) is already an
absolute length or an `objectBoundingBox` fraction as written; only a literal
`%` divides by 100 under `objectBoundingBox`, or scales against `ref` under
`userSpaceOnUse`.  `l.1` is `coordScale`-scaled, from `Svg.parsePatCoordFine`;
the result is *also* `coordScale`-scaled when it might still be multiplied by
a bounding box (`objectBoundingBox`, `!l.2`, left as `l.1` untouched) and
16.16 otherwise (`absRect`'s `!r.oBB` branch reads it directly, and
`userSpaceOnUse`'s percentage case has no further multiply ahead of it, so it
rounds down to 16.16 here, same idea as `Grad.resolve`'s own `conv` but with
`roundDiv` where that one floors). -/
def conv (oBB : Bool) (l : Grad.LenPct) (ref : Int) : Int :=
  -- `coordScale` is 16.16's grid squared (`2^32 = 65536 * 65536`), so
  -- rescaling a `coordScale`-scaled value down to 16.16 with nothing else in
  -- the way divides by 65536, not by the whole of `coordScale`.
  if !l.2 then (if oBB then l.1 else roundDiv l.1 65536)
  else if oBB then roundDiv l.1 100
  else roundDiv (l.1 * ref) (coordScale * 100)

/-- Resolve one definition: `href` inheritance for every attribute, defaults,
and the positive-size check.  T104: `patternTransform` is inherited too, as
SVG specifies and Chromium does; usvg reads it from the element itself only
(no resvg suite test depends on the difference).  `find` maps an id
to an index in `raws`. -/
def resolve (raws : Array RawDef) (find : String → Option Nat) (pr : Grad.PctRef) (i : Nat) :
    Resolved :=
  let ch := chainOf raws find i
  let oBB := (pickCommon raws ch (·.oBB)).getD true
  let contentOBB := (pickCommon raws ch (·.contentOBB)).getD false
  let viewBox := pickCommon raws ch (·.viewBox)
  let (alignX, alignY, slice, alignNone) :=
    (pickCommon raws ch (·.aspect)).getD (1, 1, false, false)
  let zero : Grad.LenPct := (0, false)
  let getCoord := fun (f : RawDef → Option Grad.LenPct) (ref : Int) =>
    conv oBB ((pickCommon raws ch f).getD zero) ref
  let x := getCoord (·.x) pr.w
  let y := getCoord (·.y) pr.h
  let w := getCoord (·.width) pr.w
  let h := getCoord (·.height) pr.h
  let contentSlot := firstWithChildren raws ch
  { valid := contentSlot.isSome && w > 0 && h > 0,
    oBB := oBB, contentOBB := contentOBB,
    transform := (pickCommon raws ch fun r => if r.hasTransform then some r.transform else none).getD
      Mat.identity,
    x := x, y := y, w := w, h := h, viewBox := viewBox,
    alignX := alignX, alignY := alignY, slice := slice, alignNone := alignNone,
    contentSlot := contentSlot.getD 0 }

/-- Build the table: bucket the ids, then resolve every entry once
(`Svg.lean` fills in `content` afterwards, keyed by `firstWithChildren`'s
winning raw index — recovered again below since `Resolved` does not carry
it). -/
def Defs.build (raws : Array RawDef) (pr : Grad.PctRef) : Defs := Id.run do
  if raws.isEmpty then return {}
  let ids := raws.map (·.id)
  let mut buckets : Array (Array Nat) := Array.replicate bucketCount #[]
  for i in [0:ids.size] do
    let id := ids.getD i ""
    if !id.isEmpty && id.length ≤ maxIdLen then
      let h := hashId id
      buckets := buckets.setIfInBounds h ((buckets.getD h #[]).push i)
  let find : String → Option Nat := fun id => Id.run do
    if id.isEmpty || id.length > maxIdLen then return none
    for i in buckets.getD (hashId id) #[] do
      if ids.getD i "" == id then return some i
    return none
  let mut out : Array Resolved := Array.emptyWithCapacity raws.size
  for i in [0:raws.size] do
    out := out.push (resolve raws find pr i)
  return { defs := out, buckets := buckets, ids := ids }

/-! ## Geometry at draw time

Everything below is pure math from already-resolved numbers: no `Node`, no
cascade, so it can be shared by `PatternRender.lean`. -/

/-- The absolute rect `(x, y, w, h)` in 16.16 user-space units: the resolved
fractions as they are under `userSpaceOnUse`, or `NonZeroRect::bbox_transform`
against `box` (already in 16.16 user units, i.e. an `Fx` box times 256) under
`objectBoundingBox`.  `none` when an `objectBoundingBox` rect has no box to
scale against (a zero-area shape, usvg's "Pattern on zero-sized shapes is not
allowed"). -/
def absRect (r : Resolved) (box : Option (Int × Int × Int × Int)) :
    Option (Int × Int × Int × Int) :=
  if !r.oBB then some (r.x, r.y, r.w, r.h)
  else match box with
    | none => none
    | some (bx0, by0, bw, bh) =>
      if bw ≤ 0 || bh ≤ 0 then none
      -- `r.x`/`r.y`/`r.w`/`r.h` are `coordScale`-scaled fractions here
      -- (`conv`'s doc comment); one rounded division combines the bounding
      -- box multiply and the return to 16.16, rather than rounding the
      -- fraction to 16.16 first (as `Grad.mul16` on an already-16.16 `r.x`
      -- would) and multiplying second — the same total precision loss as
      -- one 16.16 rounding, not two compounded ones.
      else some (bx0 + roundDiv (r.x * bw) coordScale, by0 + roundDiv (r.y * bh) coordScale,
                 roundDiv (r.w * bw) coordScale, roundDiv (r.h * bh) coordScale)

/-- `ViewBox::to_transform`, generalised over `preserveAspectRatio`'s nine
alignments and `meet`/`slice`, as a `Mat` (all inputs and the linear part are
16.16; the translation is rounded to `Fx`, which is what every other geometry
transform in this renderer carries it at).  `alignX`/`alignY`: 0 = min,
1 = mid, 2 = max. -/
def viewBoxMat (vx vy vw vh : Int) (alignX alignY : Nat) (slice alignNone : Bool)
    (w h : Int) : Mat :=
  if vw ≤ 0 || vh ≤ 0 then Mat.identity
  else
    let sx := Grad.div16 w vw
    let sy := Grad.div16 h vh
    let (sx, sy) :=
      if alignNone then (sx, sy)
      else
        let s := if slice then (if sx < sy then sy else sx) else (if sx > sy then sy else sx)
        (s, s)
    let ox := -(Grad.mul16 vx sx)
    let oy := -(Grad.mul16 vy sy)
    let extraW := w - Grad.mul16 vw sx
    let extraH := h - Grad.mul16 vh sy
    let along := fun (align : Nat) (extra : Int) =>
      match align with | 0 => 0 | 2 => extra | _ => Int.ediv extra 2
    let tx := ox + along alignX extraW
    let ty := oy + along alignY extraH
    Mat.mk' sx 0 0 sy (Int.ediv tx 256) (Int.ediv ty 256)

end Pat
end LeanSvg
