import MicroSvg.Canvas

/-!
# Gradient paint servers

A local *defs table* and the per-pixel evaluation of `linearGradient` /
`radialGradient`.  Everything here is pure integer fixed point; `Nat.sqrt` is
the only root.

## The table

`Svg.interpret` runs one bounded pre-pass over the event array and hands this
module an `Array RawDef`: one entry per `linearGradient`/`radialGradient`
element, wherever it appears (not only under `defs`), with its `id`, its own
attributes as `Option`s (absent means "inherit through `href`") and its direct
`<stop>` children.  `Defs.build` then

* indexes the ids into `bucketCount` hash buckets, so a `url(#id)` lookup is
  O(bucket) rather than O(defs), and
* resolves every entry once (`resolve`), following `href`/`xlink:href` with
  `hrefFuel` of fuel and stopping at a self- or back-reference exactly as
  usvg's `HrefIter` does.

`Defs` is carried in `Svg.Style` so that `Svg.resolvePaint` can turn
`url(#id)` into a `Svg.Paint.gradient i` at parse time, and `Render.drawShape`
can turn that index into a device-space `Rt` shader.  The shape of the table
— an id-indexed array of resolved definitions plus a bucket index — is meant
to grow: T19 (`use`/`symbol`) and T20/T21 (`clipPath`/`mask`) can add their
own entry kinds beside `RawDef` and reuse `hashId`/`lookup` unchanged, since
nothing below is specific to gradients except `resolve` itself.

## What is matched

usvg (`crates/usvg/src/parser/paint_server.rs`) decides the *semantics*:
attribute defaults, `href` inheritance (coordinates only from a gradient of
the same type, `gradientUnits`/`spreadMethod`/`gradientTransform` from
either), stop normalisation, and which degenerate cases collapse to a single
colour.  tiny-skia (`src/shaders/{gradient,linear_gradient,radial_gradient}.rs`
and `src/pipeline/lowp.rs`) decides the *numbers*:

* The colour ramp interpolates **unpremultiplied** 8-bit channels linearly in
  `t` and premultiplies afterwards, with `div255 x = (x + 255) >>> 8` — the
  `Premultiply` stage of the `lowp` pipeline, *not* `Canvas.premul`, which is
  the `f32` premultiply resvg uses for a solid colour.  The stage is skipped
  entirely when every stop is opaque, where it is the identity anyway.
* A channel is `round(c * 255)` of the interpolated `[0, 1]` value
  (`round_f32_to_u16`: `normalize() * 255.0 + 0.5`, truncated).  We compute the
  same quantity in exact rationals, halves up.
* `t` is looked up with a `>=` search, so at a stop boundary the *later* stop
  wins and a hard stop (two stops at one offset) shows the second colour.
* A linear gradient whose stops are all opaque is an opaque shader, and
  tiny-skia's blitter strength-reduces `SourceOver` to `Source` for it — the
  `blendLerp` path.  A radial gradient is *never* opaque (`Shader::is_opaque`
  returns `false` for it unconditionally), so it always takes `blendOver`.

Deviations, all deliberate and bounded:

* A focal (two-point conical) radial forces tiny-skia's `highp` pipeline,
  which carries `f32` through the ramp and premultiplies differently.  We use
  the one `lowp` model everywhere; the difference is at most one level.
* Coordinates are clamped (see `paramMax` / `conicMax`): past ~16384 gradient
  units from the origin for a plain radial, or ~64 radii for a conical one,
  the parameter saturates.  With `pad` that is already the ramp's end; with
  `repeat`/`reflect` it turns sub-pixel banding into a flat band.
* usvg nudges equal stop offsets apart by `f32::EPSILON` (1.2e-7).  Our offset
  grid is 1/65536, so those nudges vanish; the `>=` search reproduces the same
  hard-stop behaviour without them.

## Evaluation

Everything is composed into *one* affine map from the **absolute** device
pixel index to the gradient's own parameter space, whose origin and unit are
chosen per kind so the numbers are O(1) there:

* linear: `(0, 0) ↦ (x1, y1)`, `(1, 0) ↦ (x2, y2)`, so the parameter's own
  `x` *is* `t`;
* radial: `(0, 0) ↦ (fx, fy)` and the unit circle is the gradient's `r`.

The map is `(ctm · bboxTransform · gradientTransform · frame)⁻¹`, inverted
once per draw at 32 fractional bits (`Aff.invert`).  Because the input is the
absolute device pixel index — the one `rootMat` already carries the tile
offset for — a tile evaluates the very same parameter at the very same pixel
as the full render, so tiles stay byte-identical (DESIGN §3.8).
-/

namespace MicroSvg
namespace Grad

/-! ## Caps

All of these bound work on hostile input; none of them is reachable by a
document a human wrote. -/

/-- Largest number of gradient elements kept. -/
def maxDefs : Nat := 4096
/-- Largest number of `<stop>` children kept per gradient. -/
def maxStops : Nat := 256
/-- Longest `id` (and longest `url(#…)` reference) that can match. -/
def maxIdLen : Nat := 256
/-- Fuel for the `href` chain; usvg's own iterator is unbounded but stops at a
self- or origin-reference, which we also do. -/
def hrefFuel : Nat := 8
/-- Hash buckets over the ids. -/
def bucketCount : Nat := 1024

/-- `1.0` on the opacity grid.  The same constant as `Svg.opacityOne`, which
cannot be referenced here because `Svg` imports this module. -/
def opacityOne : Nat := 1000000000000000000

/-! ## Fixed-point helpers

The per-pixel loops multiply 16.16 values whose products reach 2^58.  Lean's
unboxed `Int` is 31-bit while unboxed `Nat` is 63-bit (DESIGN §3.1), so every
product below is taken in `Nat` on the magnitudes with the sign carried
separately. -/

/-- 16.16 product, truncated toward zero. -/
@[inline] def mul16 (a b : Int) : Int :=
  let m : Int := Int.ofNat ((a.natAbs * b.natAbs) >>> 16)
  if (a < 0) == (b < 0) then m else -m

/-- `a * 65536 / b`, truncated toward zero; `0` when `b = 0`. -/
@[inline] def div16 (a b : Int) : Int :=
  if b == 0 then 0
  else
    let m : Int := Int.ofNat ((a.natAbs <<< 16) / b.natAbs)
    if (a < 0) == (b < 0) then m else -m

/-- `√a` in 16.16 for a 16.16 `a ≥ 0`. -/
@[inline] def sqrt16 (a : Int) : Int :=
  if a ≤ 0 then 0 else Int.ofNat (Nat.sqrt (a.natAbs <<< 16))

/-- `x² + y²` in 16.16 for 16.16 `x`, `y`. -/
@[inline] def norm2 (x y : Int) : Int :=
  Int.ofNat ((x.natAbs * x.natAbs + y.natAbs * y.natAbs) >>> 16)

@[inline] def clampTo (lim a : Int) : Int := if a > lim then lim else if a < -lim then -lim else a

/-- Largest parameter magnitude fed to the ramp, 16.16: 2^14 gradient units. -/
def paramMax : Int := 1073741824
/-- Largest parameter magnitude fed to the conical quadratic, 16.16: 64 radii.
Tighter than `paramMax` because the quadratic squares it twice. -/
def conicMax : Int := 4194304
/-- Largest magnitude of a composed affine coefficient, 2^32 scale. -/
def affMax : Int := 1099511627776
/-- Largest magnitude of a composed affine translation, 2^32 scale. -/
def affTMax : Int := 4503599627370496

/-! ## A 16.16 affine map

`Geom.Mat` keeps its translation on the `Fx` grid of 1/256 px, which is too
coarse here: an `objectBoundingBox` gradient works in units of the bounding
box, where 1/256 of a unit is several pixels on a large shape.  `Aff` is the
same affine map with the translation in 16.16 as well, used only to compose
the gradient chain and invert it once. -/
structure Aff where
  a : Int := 65536
  b : Int := 0
  c : Int := 0
  d : Int := 65536
  e : Int := 0
  f : Int := 0
deriving Repr, Inhabited

namespace Aff

/-- `m.comp n` applies `n` first. -/
def comp (m n : Aff) : Aff :=
  { a := Int.ediv (m.a * n.a + m.c * n.b) 65536,
    b := Int.ediv (m.b * n.a + m.d * n.b) 65536,
    c := Int.ediv (m.a * n.c + m.c * n.d) 65536,
    d := Int.ediv (m.b * n.c + m.d * n.d) 65536,
    e := Int.ediv (m.a * n.e + m.c * n.f) 65536 + m.e,
    f := Int.ediv (m.b * n.e + m.d * n.f) 65536 + m.f }

/-- A `Geom.Mat` as an `Aff`: the linear part is already 16.16, the
translation moves from `Fx` (1/256) to 16.16. -/
def ofMat (m : Mat) : Aff := ⟨m.a, m.b, m.c, m.d, m.e * 256, m.f * 256⟩

/-- The per-pixel map `parameter = A·x + C·y + E` (32 fractional bits) for the
inverse of `m`, or `none` when `m` is singular.

Derivation: the forward map is `D₁₆ = (a·p₁₆ + c·q₁₆)/2^16 + e₁₆`, so
`p₁₆ = (d·(D₁₆ − e₁₆) − c·(E₁₆ − f₁₆))·2^16/det`, and a device pixel centre is
`D₁₆ = 2^16·x + 2^15`.  Splitting that into the `x`, `y` and constant parts and
scaling by a further `2^16` gives the six coefficients below.  Each is rounded
*once*, so the accumulated error over a whole 16384 px row is under 2^-18 of a
gradient unit. -/
def invert (m : Aff) : Option (Int × Int × Int × Int × Int × Int) :=
  let det := m.a * m.d - m.b * m.c
  if det == 0 then none
  else
    let k : Int := 281474976710656  -- 2^48
    let kt : Int := 4294967296      -- 2^32
    let ox := 32768 - m.e
    let oy := 32768 - m.f
    some (clampTo affMax (Int.ediv (m.d * k) det),
          clampTo affMax (Int.ediv (-m.c * k) det),
          clampTo affTMax (Int.ediv ((m.d * ox - m.c * oy) * kt) det),
          clampTo affMax (Int.ediv (-m.b * k) det),
          clampTo affMax (Int.ediv (m.a * k) det),
          clampTo affTMax (Int.ediv ((-m.b * ox + m.a * oy) * kt) det))

end Aff

/-! ## Tight bounding box

`objectBoundingBox` resolves against usvg's `path.bounding_box`, which is
`tiny_skia_path::Path::compute_tight_bounds` on the path in its *own* user
space: the curve's real extrema, not its control points.  So the extrema are
solved for exactly — the derivative of a cubic is a quadratic — and the curve
is then evaluated there by de Casteljau on a 16.16 parameter.  A root is only
ever a maximum or a minimum, so the quantisation of `t` costs second-order
error in the coordinate. -/

/-- de Casteljau at `t` (16.16) on one axis of a cubic. -/
def cubicAt16 (p0 p1 p2 p3 t : Int) : Fx :=
  let u := 65536 - t
  let a1 := Int.ediv (p0 * u + p1 * t) 65536
  let b1 := Int.ediv (p1 * u + p2 * t) 65536
  let c1 := Int.ediv (p2 * u + p3 * t) 65536
  let a2 := Int.ediv (a1 * u + b1 * t) 65536
  let b2 := Int.ediv (b1 * u + c1 * t) 65536
  Int.ediv (a2 * u + b2 * t) 65536

/-- The parameters in `(0, 1)`, as 16.16, where one axis of the cubic
`p0 p1 p2 p3` is stationary: the roots of `A·t² + B·t + C` with
`A = d₀ − 2d₁ + d₂`, `B = 2(d₁ − d₀)`, `C = d₀` for `dᵢ` the control
differences. -/
def cubicRoots (p0 p1 p2 p3 : Fx) : Array Int := Id.run do
  let d0 := p1 - p0
  let d1 := p2 - p1
  let d2 := p3 - p2
  let a := d0 - 2 * d1 + d2
  let b := 2 * (d1 - d0)
  let c := d0
  let mut out : Array Int := #[]
  let keep := fun (out : Array Int) (t : Int) => if 0 < t && t < 65536 then out.push t else out
  if a == 0 then
    if b != 0 then out := keep out (div16 (-c) b)
  else
    let disc := b * b - 4 * a * c
    if disc ≥ 0 then
      let s := Int.ofNat (Nat.sqrt disc.natAbs)
      out := keep out (div16 (-b + s) (2 * a))
      out := keep out (div16 (-b - s) (2 * a))
  return out

/-- The tight bounding box of `cmds` in its own user space, or `none` for an
empty path.  Quadratics are handled in their own right (`x'(t)` is linear) so
they are not degree-elevated, which would round their control points. -/
def tightBox (cmds : Array PathCmd) : Option Box := Id.run do
  let mut b : Option Box := none
  let mut pt : Pt := ⟨0, 0⟩
  let mut start : Pt := ⟨0, 0⟩
  let mut empty := true
  for cmd in cmds do
    match cmd with
    | .moveTo p =>
      b := Box.cover b p
      pt := p; start := p; empty := false
    | .lineTo p =>
      if empty then b := Box.cover b pt
      b := Box.cover b p
      pt := p; empty := false
    | .cubicTo c1 c2 p =>
      if empty then b := Box.cover b pt
      b := Box.cover b p
      for t in cubicRoots pt.x c1.x c2.x p.x do
        b := Box.cover b ⟨cubicAt16 pt.x c1.x c2.x p.x t, pt.y⟩
      for t in cubicRoots pt.y c1.y c2.y p.y do
        b := Box.cover b ⟨pt.x, cubicAt16 pt.y c1.y c2.y p.y t⟩
      pt := p; empty := false
    | .quadTo q p =>
      if empty then b := Box.cover b pt
      b := Box.cover b p
      let den := fun (a0 a1 a2 : Fx) => a0 - 2 * a1 + a2
      let dx := den pt.x q.x p.x
      if dx != 0 then
        let t := div16 (pt.x - q.x) dx
        if 0 < t && t < 65536 then
          let u := 65536 - t
          let a1 := Int.ediv (pt.x * u + q.x * t) 65536
          let b1 := Int.ediv (q.x * u + p.x * t) 65536
          b := Box.cover b ⟨Int.ediv (a1 * u + b1 * t) 65536, pt.y⟩
      let dy := den pt.y q.y p.y
      if dy != 0 then
        let t := div16 (pt.y - q.y) dy
        if 0 < t && t < 65536 then
          let u := 65536 - t
          let a1 := Int.ediv (pt.y * u + q.y * t) 65536
          let b1 := Int.ediv (q.y * u + p.y * t) 65536
          b := Box.cover b ⟨pt.x, Int.ediv (a1 * u + b1 * t) 65536⟩
      pt := p; empty := false
    | .close =>
      pt := start
  return b

/-! ## Raw definitions, as `Svg.interpret`'s pre-pass parses them -/

inductive Spread where
  | pad
  | reflect
  | rep
deriving Repr, Inhabited, BEq

inductive Kind where
  | linear
  | radial
deriving Repr, Inhabited, BEq

/-- A `<stop>`: the offset in 16.16 clamped to `[0, 65536]`, the `stop-color`
with its own alpha, and `stop-opacity` on the `opacityOne` grid. -/
structure RawStop where
  off : Int := 0
  col : Rgba := ⟨0, 0, 0, 255⟩
  op : Nat := opacityOne
deriving Repr, Inhabited

/-- A length or percentage as written: the number in 16.16 and whether it
carried a `%`.  16.16 rather than `Fx` because an `objectBoundingBox`
coordinate is a *fraction* of the box, where 1/256 is coarse. -/
abbrev LenPct := Int × Bool

/-- One gradient element exactly as it was written.  `none` on a field means
the attribute was absent, so `resolve` looks for it along the `href` chain. -/
structure RawDef where
  id : String := ""
  kind : Kind := .linear
  href : String := ""
  /-- `some true` = `objectBoundingBox`, `some false` = `userSpaceOnUse`. -/
  oBB : Option Bool := none
  transform : Option Mat := none
  spread : Option Spread := none
  x1 : Option LenPct := none
  y1 : Option LenPct := none
  x2 : Option LenPct := none
  y2 : Option LenPct := none
  cx : Option LenPct := none
  cy : Option LenPct := none
  r : Option LenPct := none
  fx : Option LenPct := none
  fy : Option LenPct := none
  fr : Option LenPct := none
  /-- Direct `<stop>` children, in order.  Empty means this element has none
  of its own, so `resolve` looks along the `href` chain (usvg's
  `find_gradient_with_stops`). -/
  stops : Array RawStop := #[]
deriving Repr, Inhabited

/-! ## Resolved definitions -/

/-- What a `url(#id)` turned out to be, decided once per definition.

The degeneracies are tested in the gradient's *own* parameter units, which is
where tiny-skia tests them too: `to_user_coordinates` folds the bounding box
into the shader's `transform` and leaves `x1 … fr` as the raw
`objectBoundingBox` fractions. -/
inductive Shape where
  /-- No usable stops, or an `href` that does not lead to a gradient: the
  paint falls back (usvg's `convert_linear` returning `None`). -/
  | invalid
  /-- One stop, or a degenerate shape that usvg collapses to the first stop's
  colour (a concentric radial with `fr = r` under `pad`). -/
  | solidFirst
  /-- A degenerate shape that collapses to the last stop's colour: `r ≤ 0`
  (SVG 1.1 §13.2.3) and a zero-length linear vector under `pad`. -/
  | solidLast
  /-- A zero-length linear vector under `reflect`/`repeat`: the border
  colours are never visible, so tiny-skia uses the stops' average
  (`average_gradient_color`). -/
  | average
  /-- `x1 y1 x2 y2`, 16.16, in the gradient's own units. -/
  | linear (x1 y1 x2 y2 : Int)
  /-- `cx cy r fx fy fr`, 16.16, in the gradient's own units. -/
  | radial (cx cy r fx fy fr : Int)
deriving Repr, Inhabited

structure Resolved where
  shape : Shape := .invalid
  oBB : Bool := true
  transform : Mat := Mat.identity
  spread : Spread := .pad
  stops : Array RawStop := #[]
deriving Repr, Inhabited

/-! ## The table -/

structure Defs where
  defs : Array Resolved := #[]
  /-- `bucketCount` buckets of indices into `defs`, by `hashId` of the id.
  Empty when there are no gradients at all, which is the common case and the
  one `lookup` answers without touching anything. -/
  buckets : Array (Array Nat) := #[]
  /-- The ids, parallel to `defs`, for the bucket scan. -/
  ids : Array String := #[]
deriving Repr, Inhabited

/-- Bucket for an id. -/
def hashId (s : String) : Nat := (hash s).toNat % bucketCount

/-- Index of the gradient with this id, or `none`.  The first element with a
given id wins, as in usvg's `element_by_id`. -/
def Defs.lookup (d : Defs) (id : String) : Option Nat := Id.run do
  if d.buckets.isEmpty || id.isEmpty || id.length > maxIdLen then return none
  for i in d.buckets.getD (hashId id) #[] do
    if d.ids.getD i "" == id then return some i
  return none

/-! ## `href` resolution

usvg reaches an inherited attribute with `resolve_attr`, which walks the
`href` chain and returns the first element that *has* the attribute — but only
while the link's tag is one the attribute may come from: `x1 y1 x2 y2` and
`cx cy r fx fy fr` only from a gradient of the same type, and
`gradientUnits` / `spreadMethod` / `gradientTransform` from either type.  The
first mismatch breaks the walk.  Stops come from `find_gradient_with_stops`,
which is the first element in the chain that has `<stop>` children; if a link
in that chain is not a gradient at all, the whole gradient is dropped. -/

/-- The `href` chain of `i`, `i` itself first.  Stops after `hrefFuel` links,
at an id that names no gradient, and at a link already on the chain — usvg
stops at a self- or origin-reference, and revisiting a node can only happen
inside a cycle, so the two agree on where a cycle ends. -/
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

/-- `resolve_attr` for a coordinate: only a gradient of `kind` may supply it. -/
def pickCoord (raws : Array RawDef) (ch : Array Nat) (kind : Kind)
    (get : RawDef → Option LenPct) : Option LenPct := Id.run do
  for j in ch do
    let g := raws.getD j default
    if g.kind != kind then break
    match get g with
    | some v => return some v
    | none => pure ()
  return none

/-- `resolve_attr` for `gradientUnits` / `spreadMethod` / `gradientTransform`:
either gradient type may supply it, so the walk never breaks early. -/
def pickCommon (raws : Array RawDef) (ch : Array Nat) (get : RawDef → Option α) :
    Option α := Id.run do
  for j in ch do
    match get (raws.getD j default) with
    | some v => return some v
    | none => pure ()
  return none

/-- usvg's `convert_stops` tail, on our grid: offsets are already clamped to
`[0, 1]` by the parser, and are made monotone here.  usvg additionally nudges
equal offsets apart by `f32::EPSILON`; that is far below 1/65536, and the
ramp's `≥` search reproduces the hard stop it is there to protect. -/
def monotone (ss : Array RawStop) : Array RawStop := Id.run do
  let mut out : Array RawStop := Array.emptyWithCapacity ss.size
  let mut prev : Int := 0
  for s in ss do
    let o := if s.off < prev then prev else s.off
    out := out.push { s with off := o }
    prev := o
  return out

/-- The reference lengths a `userSpaceOnUse` percentage resolves against:
usvg's `state.view_box`, which in a document without nested `<svg>` is one
constant rect.  `w` and `h` in 16.16; `diag` is `√((w² + h²)/2)`, which
`convert_length` uses for every attribute that is neither horizontal nor
vertical (`r`, `fr`). -/
structure PctRef where
  w : Int := 6553600
  h : Int := 6553600
deriving Repr, Inhabited

def PctRef.diag (p : PctRef) : Int := sqrt16 (Int.ediv (norm2 p.w p.h) 2)

/-- Resolve one definition: `href` inheritance, then the defaults and the
degenerate cases.  `find` maps an id to an index in `raws`. -/
def resolve (raws : Array RawDef) (find : String → Option Nat) (pr : PctRef) (i : Nat) :
    Resolved :=
  let me := raws.getD i default
  let ch := chainOf raws find i
  -- `find_gradient_with_stops`: the first link with `<stop>` children.
  let stops : Array RawStop := Id.run do
    for j in ch do
      let g := raws.getD j default
      if g.stops.size > 0 then return monotone g.stops
    return #[]
  let oBB := (pickCommon raws ch (·.oBB)).getD true
  let transform := (pickCommon raws ch (·.transform)).getD Mat.identity
  let spread := (pickCommon raws ch (·.spread)).getD .pad
  -- `convert_length`: under `objectBoundingBox` a percentage is just the
  -- number over 100 (and a plain number is already a fraction of the box);
  -- under `userSpaceOnUse` it is `number · reference / 100`, where the
  -- reference is the viewport's width, height or diagonal depending on the
  -- attribute.
  let conv := fun (l : LenPct) (ref : Int) =>
    if !l.2 then l.1
    else if oBB then Int.ediv l.1 100
    else Int.ediv (l.1 * ref) 6553600
  -- The defaults are `Length`s too, so `x2 = 100%` is the whole viewport
  -- width under `userSpaceOnUse` and exactly `1` under `objectBoundingBox`.
  let get := fun (f : RawDef → Option LenPct) (ref : Int) (dflt : LenPct) =>
    conv ((pickCoord raws ch me.kind f).getD dflt) ref
  let pct100 : LenPct := (6553600, true)
  let pct50 : LenPct := (3276800, true)
  let zero : LenPct := (0, false)
  if stops.size == 0 then { shape := .invalid, stops := stops }
  else
    let base : Resolved :=
      { shape := .invalid, oBB := oBB, transform := transform, spread := spread, stops := stops }
    if stops.size == 1 then { base with shape := .solidFirst }
    else match me.kind with
    | .linear =>
      let x1 := get (·.x1) pr.w zero
      let y1 := get (·.y1) pr.h zero
      let x2 := get (·.x2) pr.w pct100
      let y2 := get (·.y2) pr.h zero
      -- `DEGENERATE_THRESHOLD` is 1/32768, i.e. 2 on the 16.16 grid.
      if sqrt16 (norm2 (x2 - x1) (y2 - y1)) < 2 then
        { base with shape := if spread == .pad then .solidLast else .average }
      else { base with shape := .linear x1 y1 x2 y2 }
    | .radial =>
      let cx := get (·.cx) pr.w pct50
      let cy := get (·.cy) pr.h pct50
      let r := get (·.r) pr.diag pct50
      let fr0 := get (·.fr) pr.diag zero
      let fr := if fr0 < 0 then 0 else fr0
      -- 'A value of zero will cause the area to be painted as a single colour
      -- using the colour and opacity of the last gradient stop.'
      if r ≤ 0 then { base with shape := .solidLast }
      else
        let fx := get (·.fx) pr.w (cx, false)
        let fy := get (·.fy) pr.h (cy, false)
        if fx == cx && fy == cy && fr == r then
          -- The interpolation region is an infinitely thin ring.  Under `pad`
          -- tiny-skia rebuilds it as a plain radial of radius `r` over the
          -- three stops `(0, first) (1, first) (1, last)` — the first colour
          -- inside the circle and the last outside it; otherwise the gradient
          -- is dropped entirely.
          if spread != .pad then { base with shape := .invalid }
          else
            let f := stops.getD 0 default
            let l := stops.getD (stops.size - 1) default
            { base with
              shape := Shape.radial cx cy r cx cy 0,
              stops := #[{ f with off := 0 }, { f with off := 65536 },
                         { l with off := 65536 }] }
        else { base with shape := .radial cx cy r fx fy fr }

/-- Build the table: bucket the ids, then resolve every entry once. -/
def Defs.build (raws : Array RawDef) (pr : PctRef) : Defs := Id.run do
  if raws.isEmpty then return {}
  let ids := raws.map (·.id)
  let mut buckets : Array (Array Nat) := Array.replicate bucketCount #[]
  -- Later duplicates are appended after earlier ones, so a bucket scan finds
  -- the first element with a given id, as `element_by_id` does.
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

/-! ## The runtime shader

What `Render.drawShape` builds per fill or stroke and `fillMaskShader` walks.
`stops` are unpremultiplied 8-bit colours with the paint's opacities already
folded into their alphas, exactly as resvg hands them to
`tiny_skia::GradientStop`. -/

structure RtStop where
  off : Int
  r : Nat
  g : Nat
  b : Nat
  a : Nat
deriving Inhabited

inductive Geom where
  /-- The parameter's own `x` is `t`. -/
  | linear
  /-- `t = |q|`: focal point at the centre, `fr = 0`. -/
  | radial
  /-- Two-point conical.  `ex ey` is `(centre − focal)/r`, `rho0` is `fr/r` and
  `delta = 1 − rho0`, all 16.16; `a2 = |e|² − δ²` is the quadratic's leading
  coefficient. -/
  | conical (ex ey rho0 delta a2 : Int)
deriving Inhabited

/-- One coordinate of the device-pixel-to-parameter map, split so the hot loop
stays in Lean's unboxed range (invariant 4).

`Aff.invert` produces `p = a·x + c·y + e` at 32 fractional bits, where `a·x`
alone reaches 2^54.  Writing each coefficient as `65536·H + L` with
`0 ≤ L < 65536` splits that into

    p₁₆ = ⌊p/2^16⌋ = (aH·x + cH·y + eH) + ⌊(aL·x + cL·y + eL)/2^16⌋

exactly, because the `L` part is non-negative.  The `H` sum is the answer's
own magnitude (a few thousand for any real gradient) and the `L` sum is a
`Nat` under 2^31, so neither leaves the unboxed path — while the result is
still the exact floor, which is what keeps a tile's pixels identical to the
full render's. -/
structure Axis where
  aH : Int
  cH : Int
  eH : Int
  aL : Nat
  cL : Nat
  eL : Nat
deriving Inhabited

@[inline] def Axis.split (v : Int) : Int × Nat :=
  (Int.ediv v 65536, (Int.emod v 65536).toNat)

def Axis.mk3 (a c e : Int) : Axis :=
  let (aH, aL) := Axis.split a
  let (cH, cL) := Axis.split c
  let (eH, eL) := Axis.split e
  ⟨aH, cH, eH, aL, cL, eL⟩

/-- The parameter coordinate at absolute device pixel `(x, y)`, 16.16. -/
@[inline] def Axis.at (s : Axis) (x y : Nat) : Int :=
  s.aH * x + s.cH * y + s.eH + Int.ofNat ((s.aL * x + s.cL * y + s.eL) >>> 16)

structure Rt where
  geom : Geom
  spread : Spread
  /-- The two rows of the inverse map, over the *absolute* device pixel index. -/
  px : Axis
  py : Axis
  stops : Array RtStop
  /-- Whether tiny-skia would call this shader opaque, and so reduce
  `SourceOver` to `Source`: true only for a linear gradient whose every stop
  is opaque (`Shader::is_opaque` is unconditionally `false` for a radial). -/
  isOpaque : Bool
deriving Inhabited

/-! ### The colour ramp -/

/-- The stop index whose segment contains `u`: the largest `j` with
`off j ≤ u`, or `0` at or below the first offset.  Bounded binary search;
`maxStops` is 256, so nine halvings settle it.

Taking the *largest* such `j` is what makes a hard stop — two stops at one
offset — show the later colour, which is tiny-skia's `t >= t_values[i]`
search.  Taking `0` at `u = off 0` rather than the largest is what usvg's
"remove zeros" pass buys with its `f32::EPSILON` nudge: with two stops at
offset 0 the flat region to the left of the gradient keeps the *first*
colour, and only strictly inside does the second take over. -/
@[inline] def findStop (ss : Array RtStop) (u : Int) : Nat := Id.run do
  let n := ss.size
  if n ≤ 1 then return 0
  if u ≤ (ss.getD 0 default).off then return 0
  let mut lo : Nat := 0
  let mut hi : Nat := n - 1
  -- Invariant: `off lo ≤ u`.  `hi` is the largest candidate.
  for _ in [0:10] do
    if lo ≥ hi then break
    let mid := (lo + hi + 1) / 2
    if (ss.getD mid default).off ≤ u then lo := mid else hi := mid - 1
  return lo

/-- One channel of the ramp at `u`, as tiny-skia's `lowp` pipeline computes it:
the unpremultiplied channel is linear in `t` and then rounded to 8 bits with
`round(c·255)`.  Written as one exact rational, halves up. -/
@[inline] def lerpCh (cl cr : Nat) (num den : Int) : Nat :=
  if cl == cr then cl
  else
    let v := 2 * ((cl : Int) * den + ((cr : Int) - (cl : Int)) * num) + den
    let q := Int.ediv v (2 * den)
    if q < 0 then 0 else if q > 255 then 255 else q.toNat

/-- The premultiplied colour at parameter `u ∈ [0, 65536]`. -/
@[inline] def rampAt (sh : Rt) (u : Int) : Nat × Nat × Nat × Nat :=
  let ss := sh.stops
  let j := findStop ss u
  let l := ss.getD j default
  let nxt := ss.getD (j + 1) l
  let den := nxt.off - l.off
  let (r, g, b, a) :=
    if j + 1 ≥ ss.size || den ≤ 0 then (l.r, l.g, l.b, l.a)
    else
      let num := u - l.off
      (lerpCh l.r nxt.r num den, lerpCh l.g nxt.g num den,
       lerpCh l.b nxt.b num den, lerpCh l.a nxt.a num den)
  if a == 255 then (r, g, b, a)
  else -- `lowp::premultiply`, which is `div255 (c * a)`, not `Canvas.premul`.
    (Canvas.div255 (r * a), Canvas.div255 (g * a), Canvas.div255 (b * a), a)

/-- `PadX1` / `ReflectX1` / `RepeatX1` on a 16.16 parameter, giving `[0, 65536]`.
`pad` may clamp unconditionally because the ramp is already flat outside the
stops. -/
@[inline] def spreadT : Spread → Int → Int
  | .pad, t => if t ≤ 0 then 0 else if t ≥ 65536 then 65536 else t
  | .rep, t => Int.emod t 65536
  | .reflect, t =>
    let v := Int.emod t 131072
    if v ≤ 65536 then v else 131072 - v

/-- The gradient's parameter at a device pixel, or `none` where the two-point
conical is undefined (tiny-skia's `Mask2PtConicalDegenerates`, which makes the
pixel fully transparent). -/
@[inline] def paramAt (sh : Rt) (px16 py16 : Int) : Option Int :=
  match sh.geom with
  | .linear => some (clampTo paramMax px16)
  | .radial =>
    let x := clampTo paramMax px16
    let y := clampTo paramMax py16
    some (sqrt16 (norm2 x y))
  | .conical ex ey rho0 delta a2 =>
    -- `P` lies on the circle of centre `f + t·(c − f)` and radius
    -- `r0 + t·(r1 − r0)`, i.e. `a2·t² − 2·b2·t + c2 = 0` with every length
    -- divided by `r`.  Skia's focal / strip / greater / smaller stages are
    -- changes of variable on this one quadratic, and what they agree on is
    -- the *largest* root whose interpolated radius `r0 + t·(r1 − r0)` is not
    -- negative; where no root qualifies the pixel is one of
    -- `Mask2PtConicalDegenerates`' and stays transparent.
    let x := clampTo conicMax px16
    let y := clampTo conicMax py16
    let b2 := mul16 x ex + mul16 y ey + mul16 rho0 delta
    let c2 := norm2 x y - mul16 rho0 rho0
    let ok := fun (t : Int) => rho0 + mul16 t delta ≥ 0
    if a2 == 0 then
      if b2 == 0 then none
      else
        let t := clampTo paramMax (div16 c2 (2 * b2))
        if ok t then some t else none
    else
      let disc := mul16 b2 b2 - mul16 a2 c2
      if disc < 0 then none
      else
        let s := sqrt16 disc
        let r1 := clampTo paramMax (div16 (b2 + s) a2)
        let r2 := clampTo paramMax (div16 (b2 - s) a2)
        let hi := if r1 ≥ r2 then r1 else r2
        let lo := if r1 ≥ r2 then r2 else r1
        if ok hi then some hi else if ok lo then some lo else none

/-! ### Building one -/

/-- What a gradient paint turned into for one shape. -/
inductive Built where
  /-- Nothing is painted: a degenerate bounding box under
  `objectBoundingBox`, or a singular transform. -/
  | skip
  /-- The gradient collapsed to a solid colour, which goes down the existing
  `Canvas.fillMask` path unchanged. -/
  | solid (c : Rgba) (a8 : Nat)
  | grad (sh : Rt)
deriving Inhabited

/-- `opacityOne ^ 3`, the denominator of a stop's alpha. -/
def opacityCube : Nat := opacityOne * opacityOne * opacityOne

/-- The 8-bit alpha resvg hands `tiny_skia::GradientStop`:
`(stop.opacity() * fill.opacity()).to_u8()`, where usvg has already folded the
stop colour's own alpha into `stop.opacity()` and the group opacity into
`fill.opacity()`.  One `f32` product, quantised once with `round(x · 255)`;
here one exact integer product, halves away from zero. -/
def stopAlpha8 (alpha stopOp fillOp groupOp : Nat) : Nat :=
  Nat.min 255 ((alpha * stopOp * fillOp * groupOp * 2 / opacityCube + 1) / 2)

/-- tiny-skia's `average_gradient_color`: the integral of the piecewise-linear
ramp over `[0, 1]`, including the flat runs before the first and after the last
stop.  Weights are 16.16 and sum to exactly 65536. -/
def averageColor (ss : Array RtStop) : Rgba := Id.run do
  if ss.isEmpty then return ⟨0, 0, 0, 0⟩
  let n := ss.size
  let mut acc : Int × Int × Int × Int := (0, 0, 0, 0)
  let add := fun (acc : Int × Int × Int × Int) (s : RtStop) (w : Int) =>
    (acc.1 + (s.r : Int) * w, acc.2.1 + (s.g : Int) * w,
     acc.2.2.1 + (s.b : Int) * w, acc.2.2.2 + (s.a : Int) * w)
  for i in [0:n - 1] do
    let c0 := ss.getD i default
    let c1 := ss.getD (i + 1) default
    let w := (c1.off - c0.off) / 2
    acc := add acc c0 w
    acc := add acc c1 w
  let first := ss.getD 0 default
  if first.off > 0 then acc := add acc first first.off
  let last := ss.getD (n - 1) default
  if last.off < 65536 then acc := add acc last (65536 - last.off)
  let q := fun (v : Int) =>
    let r := Int.ediv (2 * v + 65536) 131072
    if r < 0 then 0 else if r > 255 then 255 else r.toNat
  return ⟨q acc.1, q acc.2.1, q acc.2.2.1, q acc.2.2.2⟩

/-- Turn a resolved definition into something `drawShape` can paint with.

`cmds` are the shape's path commands in its own user space, for the
`objectBoundingBox` frame; `ctm` maps that space to device `Fx`.  `fillOp` and
`groupOp` are the fill (or stroke) opacity and the inherited group opacity on
the `opacityOne` grid.

`(ox, oy)` is the `--viewport` origin in output pixels, and it is what makes a
tile byte-identical.  `ctm` already carries `translate(−ox, −oy)`, but feeding
that through `Aff.invert` would round the six coefficients around a *different*
point than the full render's and leave the two disagreeing by one 2^-32 here
and there.  So the translation is undone first — exactly, since
`Mat.translate` has an identity linear part — the inverse is taken about the
whole image, and the offset is folded back into the constant term as
`e + a·ox + c·oy`, which is integer arithmetic on the already-rounded
coefficients.  A tile's coefficients are then the full render's, evaluated at
the same absolute pixel. -/
def build (d : Defs) (i : Nat) (cmds : Array PathCmd) (ctm0 : Mat) (ox oy : Int)
    (fillOp groupOp : Nat) : Built :=
  let ctm := if ox == 0 && oy == 0 then ctm0
             else (Mat.translate (ox * 256) (oy * 256)).mul ctm0
  let res := d.defs.getD i default
  let ss : Array RtStop := res.stops.map fun s =>
    { off := s.off, r := s.col.r, g := s.col.g, b := s.col.b,
      a := stopAlpha8 s.col.a s.op fillOp groupOp }
  if ss.isEmpty then .skip else
  let first := ss.getD 0 default
  let last := ss.getD (ss.size - 1) default
  let asSolid := fun (s : RtStop) => Built.solid ⟨s.r, s.g, s.b, 255⟩ s.a
  match res.shape with
  | .invalid => .skip
  | .solidFirst => asSolid first
  | .solidLast => asSolid last
  | .average => let c := averageColor ss; .solid ⟨c.r, c.g, c.b, 255⟩ c.a
  | .linear x1 y1 x2 y2 =>
    mk res ss (.linear) ⟨x2 - x1, y2 - y1, -(y2 - y1), x2 - x1, x1, y1⟩
      (ss.all (·.a == 255)) cmds ctm ox oy
  | .radial cx cy r fx fy fr =>
    let ecx := clampTo conicMax (div16 (cx - fx) r)
    let ecy := clampTo conicMax (div16 (cy - fy) r)
    -- tiny-skia treats a focal offset under `DEGENERATE_THRESHOLD` (1/32768 of
    -- a gradient unit) as concentric, and a concentric gradient with `fr = 0`
    -- as a plain radial about the focal point.
    let conc := sqrt16 (norm2 (cx - fx) (cy - fy)) < 2
    let (ecx, ecy) := if conc then (0, 0) else (ecx, ecy)
    let rho0 := clampTo conicMax (div16 fr r)
    let geom : Geom :=
      if conc && rho0 == 0 then .radial
      else
        let delta := 65536 - rho0
        .conical ecx ecy rho0 delta (norm2 ecx ecy - mul16 delta delta)
    mk res ss geom ⟨r, 0, 0, r, fx, fy⟩ false cmds ctm ox oy
where
  /-- Compose `ctm · bbox · gradientTransform · frame`, invert it, and wrap it
  up.  `frame` maps the gradient's parameter space into its own user space. -/
  mk (res : Resolved) (ss : Array RtStop) (geom : Geom) (frame : Aff)
     (isOpaque : Bool) (cmds : Array PathCmd) (ctm : Mat) (ox oy : Int) : Built :=
    let inner := (Aff.ofMat res.transform).comp frame
    let outer : Option Aff :=
      if !res.oBB then some inner
      else match tightBox cmds with
        | none => none
        | some b =>
          let bw := b.x1 - b.x0
          let bh := b.y1 - b.y0
          -- 'Gradient on zero-sized shapes is not allowed' (usvg).
          if bw ≤ 0 || bh ≤ 0 then none
          else some ((⟨bw * 256, 0, 0, bh * 256, b.x0 * 256, b.y0 * 256⟩ : Aff).comp inner)
    match outer with
    | none => .skip
    | some g =>
      match ((Aff.ofMat ctm).comp g).invert with
      | none => .skip
      | some (ax, cx, ex, ay, cy, ey) =>
        .grad { geom := geom, spread := res.spread,
                px := Axis.mk3 ax cx (ex + ax * ox + cx * oy),
                py := Axis.mk3 ay cy (ey + ay * ox + cy * oy),
                stops := ss, isOpaque := isOpaque }

end Grad

namespace Canvas

/-- `fillMask` with a per-pixel paint source: the gradient equivalent of the
solid-colour path, which is left exactly as it was.

The pipeline is the same one: the rasterizer's coverage reduces to tiny-skia's
0..255, and then either `blendLerp` (an opaque shader, where the blitter
strength-reduces `SourceOver` to `Source`) or `blendOver` on a source the
`scale_1_float` stage has already multiplied by the coverage.  Only the source
colour moves, and it is read from the gradient at the pixel's *absolute*
device position, so a tile paints what the full render paints. -/
def fillMaskShader (cv : Canvas) (m : Raster.Mask) (sh : Grad.Rt) : Canvas := Id.run do
  let w := cv.w
  let h := cv.h
  let mw := m.w
  let mut px := cv.px
  for y in [0:m.h] do
    let mrow := y * mw
    let prow := (m.y0 + y) * w + m.x0
    let ay := m.y0 + y
    -- The row's constant halves, hoisted: what is left per pixel is one
    -- multiply and one add per axis, all inside the unboxed range.
    let hiX := sh.px.cH * ay + sh.px.eH
    let loX := sh.px.cL * ay + sh.px.eL
    let hiY := sh.py.cH * ay + sh.py.eH
    let loY := sh.py.cL * ay + sh.py.eL
    for x in [0:mw] do
      let cov := m.cov.getD (mrow + x) 0
      if cov ≤ covNone then continue
      let ax := m.x0 + x
      match Grad.paramAt sh
              (sh.px.aH * ax + hiX + Int.ofNat ((sh.px.aL * ax + loX) >>> 16))
              (sh.py.aH * ax + hiY + Int.ofNat ((sh.py.aL * ax + loY) >>> 16)) with
      | none => pure ()
      | some t =>
        let (sr, sg, sb, sa) := Grad.rampAt sh (Grad.spreadT sh.spread t)
        if sa == 0 && !sh.isOpaque then pure ()
        else
          let idx := prow + x
          let cov8 := if cov ≥ covFull then 255 else (cov * 255 + 32768) >>> 16
          let dst := px.getD idx 0
          let nv :=
            if sh.isOpaque then blendLerp dst sr sg sb cov8
            else blendOver dst (div255 (sr * cov8)) (div255 (sg * cov8)) (div255 (sb * cov8))
                   (div255 (sa * cov8))
          px := px.setIfInBounds idx nv
  return ⟨w, h, px⟩

end Canvas
end MicroSvg
