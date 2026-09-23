import LeanSvg.Svg

/-!
# `<marker>` (T52)

Turns `marker-start`/`marker-mid`/`marker-end` references on `path`/`line`/
`polyline`/`polygon` shapes into copies of the referenced `<marker>`'s
content, one per vertex, matching usvg 0.48.1
(`crates/usvg/src/parser/marker.rs`).  Runs once, after `Svg.interpret` has
built the whole `Doc` (`Svg.Doc.markers` already holds every `<marker>`'s
own geometry and its content, in its own local space; see the comment above
`Svg.MarkerEntry`), so it needs no cascade or event-stream state of its own:
everything here is a pure `Doc → Doc` transform plus the handful of small
geometry helpers `viewBoxTransform` and `calcVertexAngle` factor out.

## What is ported, and what is not

Ported closely: the vertex/angle algorithm (`calcVertexAngle` and its
helpers), `viewBoxTransform` (align + meet/slice, standalone per the task so
whatever T47/T48 land with later can share it), `orient` (`auto`,
`auto-start-reverse`, an angle in any of `deg`/`grad`/`rad`/`turn`),
`markerUnits`, overflow clipping (default hidden), the `stroke-width = 0`
suppression, recursive/self-referential markers (a cycle is skipped, not
followed forever, `recursive-1.svg`..`recursive-5.svg`), and a hard budget on
total instantiated content so a pathological input cannot blow up.

Not supported, and degrading the way an unsupported feature does everywhere
else in this renderer -- silently, never an error: `<text>`/`<image>` inside
a marker's own content (skipped, like everywhere `<image>` is skipped and
like `<text>` already is inside `<clipPath>`; `with-a-text-child.svg`,
`with-an-image-child.svg`), and a `clip-path` set on an element *inside*
marker content (dropped -- the element still renders, just unclipped; the
marker's own `overflow` clip, the one every corpus file actually exercises,
is unaffected and fully supported).  Neither gap is reachable by an attacker
looking for cost, since both make less work happen, not more.
-/

namespace LeanSvg
namespace Marker

open Svg

/-! ## `viewBoxTransform`: standalone `viewBox` → viewport transform

`align` is the three primitives usvg's `Align` enum reduces to instead of the
enum itself, so this function depends on nothing beyond `Mat`/`Fx`: `alignX`,
`alignY` ∈ `{0, 1, 2}` for min/mid/max, ignored when `alignNone` (the `"none"`
keyword, independent per-axis scaling) is set. -/
def viewBoxTransform (vx vy vw vh dw dh : Fx) (alignNone : Bool) (alignX alignY : Nat)
    (slice : Bool) : Mat :=
  if vw ≤ 0 || vh ≤ 0 || dw ≤ 0 || dh ≤ 0 then Mat.identity else
  let sx0 := Int.ediv (dw * 65536) vw
  let sy0 := Int.ediv (dh * 65536) vh
  let (sx, sy) :=
    if alignNone then (sx0, sy0)
    else
      let s := if slice then (if sx0 < sy0 then sy0 else sx0) else (if sx0 > sy0 then sy0 else sx0)
      (s, s)
  let x := Int.ediv (-vx * sx) 65536
  let y := Int.ediv (-vy * sy) 65536
  let w := dw - Int.ediv (vw * sx) 65536
  let h := dh - Int.ediv (vh * sy) 65536
  let tx := match alignX with | 0 => x | 2 => x + w | _ => x + Int.ediv w 2
  let ty := match alignY with | 0 => y | 2 => y + h | _ => y + Int.ediv h 2
  Mat.mk' sx 0 0 sy tx ty

/-! ## Vertex angles

Ported from `marker.rs`'s `calc_vertex_angle` and its callees.  usvg computes
each vertex's tangent(s) as float angles via `atan2` and averages two of them
with a correction for wraparound; done in exact fixed point instead by
summing *unit* direction vectors, which is the same computation without ever
forming an angle: for unit vectors `u₁ = (cos θ₁, sin θ₁)`, `u₂ = (cos θ₂, sin
θ₂)`, `u₁ + u₂ = 2 cos((θ₂ − θ₁)/2) · (cos θm, sin θm)` where `θm = (θ₁ +
θ₂)/2` -- exactly usvg's `calc_angle` before its correction, and the
correction (subtract π when `|d| > π/2`) is exactly the sign flip that
factor `2 cos(d)` already applies to the sum when the two vectors are more
than 90° apart.  The one case that formula cannot see through is `u₁ + u₂ =
0` exactly, i.e. the two vectors exactly antiparallel (`cos d = 0`); there
`calc_angle` still has a well-defined, non-symmetric answer (it depends on
which half-plane the first vector's angle falls in, an artifact of usvg's
`atan2` normalisation into `[0, 2π)`), reproduced directly with the exact
integer sign test `cross = 0 ∧ dot < 0` standing in for "exactly
antiparallel". -/

/-- Direction of `(x, y)` as a 16.16 unit-ish vector `(cos θ, sin θ)` where `θ
= atan2(y, x)`.  The zero vector maps to `(1, 0)`, matching Rust's
`0f32.atan2(0f32) == 0.0`. -/
def dirUnit16 (x y : Int) : Int × Int :=
  if x == 0 && y == 0 then (65536, 0)
  else
    let len : Nat := Nat.sqrt (x.natAbs * x.natAbs + y.natAbs * y.natAbs)
    if len == 0 then (65536, 0) else (Int.ediv (x * 65536) len, Int.ediv (y * 65536) len)

/-- `calc_angle`: the vertex angle between an incoming direction `(v1x, v1y)`
and an outgoing direction `(v2x, v2y)`, as a 16.16 `(cos, sin)` pair. -/
def bisector16 (v1x v1y v2x v2y : Int) : Int × Int :=
  let cross := v1x * v2y - v1y * v2x
  let dot := v1x * v2x + v1y * v2y
  if cross == 0 && dot < 0 then
    -- Exactly antiparallel: `calc_angle` reduces to a ±90° turn from the
    -- incoming vector, the side chosen by which half of `[0, 2π)` its own
    -- angle falls in (`in_a < π ⟺ v1y > 0 ∨ (v1y = 0 ∧ v1x ≥ 0)`).
    if v1y > 0 || (v1y == 0 && v1x ≥ 0) then dirUnit16 (-v1y) v1x else dirUnit16 v1y (-v1x)
  else
    let (u1x, u1y) := dirUnit16 v1x v1y
    let (u2x, u2y) := dirUnit16 v2x v2y
    dirUnit16 (u1x + u2x) (u1y + u2y)

/-- `calc_line_angle`: a single direction, as `bisector16` of that vector with
itself (`d = 0` always, so no correction ever applies -- including for the
zero vector, which lands on `dirUnit16`'s own `(1, 0)` convention). -/
def calcLineAngle (x1 y1 x2 y2 : Int) : Int × Int := bisector16 (x2 - x1) (y2 - y1) (x2 - x1) (y2 - y1)

def calcAngle4 (x1 y1 x2 y2 x3 y3 x4 y4 : Int) : Int × Int := bisector16 (x2 - x1) (y2 - y1) (x4 - x3) (y4 - y3)

/-- `calc_curves_angle`: picks the non-degenerate control point on each side
(exact equality suffices here, unlike usvg's `approx_eq_ulps` -- there is no
rounding noise to allow for in fixed point). -/
def calcCurvesAngle (px py cx1 cy1 x y cx2 cy2 nx ny : Int) : Int × Int :=
  if cx1 == x && cy1 == y then calcAngle4 px py x y x y cx2 cy2
  else if x == cx2 && y == cy2 then calcAngle4 cx1 cy1 x y x y nx ny
  else calcAngle4 cx1 cy1 x y x y cx2 cy2

/-- Like `tiny_skia_path::PathSegment`, but with quadratics already elevated
to cubics (`quad_to_curve`, exact) since that is what `marker.rs` itself
does before ever looking at a path's segments. -/
inductive Seg where
  | moveTo (p : Pt)
  | lineTo (p : Pt)
  | cubicTo (c1 c2 p : Pt)
  | close
deriving Inhabited

/-- `quad_to_curve`: exact degree elevation of a quadratic (`p0`, `c`, `p`)
into a cubic's two control points. -/
def elevateQuad (p0 c p : Pt) : Pt × Pt :=
  (⟨Int.ediv (p0.x + 2 * c.x) 3, Int.ediv (p0.y + 2 * c.y) 3⟩,
   ⟨Int.ediv (p.x + 2 * c.x) 3, Int.ediv (p.y + 2 * c.y) 3⟩)

def toSegments (cmds : Array PathCmd) : Array Seg := Id.run do
  let mut out : Array Seg := #[]
  let mut pt : Pt := ⟨0, 0⟩
  for c in cmds do
    match c with
    | .moveTo p => out := out.push (.moveTo p); pt := p
    | .lineTo p => out := out.push (.lineTo p); pt := p
    | .cubicTo c1 c2 p => out := out.push (.cubicTo c1 c2 p); pt := p
    | .quadTo c p =>
      let (c1, c2) := elevateQuad pt c p
      out := out.push (.cubicTo c1 c2 p)
      pt := p
    | .close => out := out.push .close
  return out

/-- `get_subpath_start`: scans backward from just before `idx` for the last
`MoveTo`, `(0, 0)` if there is none (unreachable on a well-formed path, since
every subpath starts with one). -/
def getSubpathStart (segs : Array Seg) (idx : Nat) : Pt := Id.run do
  let mut i := idx
  while i > 0 do
    i := i - 1
    match segs.getD i default with
    | .moveTo p => return p
    | _ => pure ()
  return ⟨0, 0⟩

/-- `get_prev_vertex`. -/
def getPrevVertex (segs : Array Seg) (idx : Nat) : Pt :=
  match segs.getD (idx - 1) default with
  | .moveTo p => p
  | .lineTo p => p
  | .cubicTo _ _ p => p
  | .close => getSubpathStart segs idx

/-- `calc_vertex_angle`, as a 16.16 `(cos, sin)` pair (never itself converted
to degrees, since every caller only ever wants a rotation matrix from it). -/
def calcVertexAngle (segs : Array Seg) (idx : Nat) : Int × Int :=
  let n := segs.size
  if idx == 0 then
    match segs.getD 0 default, segs.getD 1 default with
    | .moveTo pm, .lineTo p => calcLineAngle pm.x pm.y p.x p.y
    | .moveTo pm, .cubicTo p1 _ p =>
      if pm.x == p1.x && pm.y == p1.y then calcLineAngle pm.x pm.y p.x p.y
      else calcLineAngle pm.x pm.y p1.x p1.y
    | _, _ => (65536, 0)
  else if idx == n - 1 then
    match segs.getD (idx - 1) default, segs.getD idx default with
    | _, .moveTo _ => (65536, 0)
    | _, .lineTo p =>
      let prev := getPrevVertex segs idx
      calcLineAngle prev.x prev.y p.x p.y
    | _, .cubicTo p1 p2 p =>
      if p2.x == p.x && p2.y == p.y then calcLineAngle p1.x p1.y p.x p.y
      else calcLineAngle p2.x p2.y p.x p.y
    | .lineTo p, .close =>
      let next := getSubpathStart segs idx
      calcLineAngle p.x p.y next.x next.y
    | .cubicTo _ p2 p, .close =>
      let prev := getPrevVertex segs idx
      let next := getSubpathStart segs idx
      calcCurvesAngle prev.x prev.y p2.x p2.y p.x p.y next.x next.y next.x next.y
    | _, .close => (65536, 0)
  else
    match segs.getD idx default, segs.getD (idx + 1) default with
    | .moveTo pm, .lineTo p => calcLineAngle pm.x pm.y p.x p.y
    | .moveTo pm, .cubicTo p1 _ _ => calcLineAngle pm.x pm.y p1.x p1.y
    | .lineTo p1, .lineTo p2 =>
      let prev := getPrevVertex segs idx
      calcAngle4 prev.x prev.y p1.x p1.y p1.x p1.y p2.x p2.y
    | .cubicTo _ c1p2 c1p, .cubicTo c2p1 _ c2p =>
      let prev := getPrevVertex segs idx
      calcCurvesAngle prev.x prev.y c1p2.x c1p2.y c1p.x c1p.y c2p1.x c2p1.y c2p.x c2p.y
    | .lineTo pl, .cubicTo p1 _ p =>
      let prev := getPrevVertex segs idx
      calcCurvesAngle prev.x prev.y prev.x prev.y pl.x pl.y p1.x p1.y p.x p.y
    | .cubicTo _ p2 p, .lineTo pl =>
      let prev := getPrevVertex segs idx
      calcCurvesAngle prev.x prev.y p2.x p2.y p.x p.y pl.x pl.y pl.x pl.y
    | .lineTo p, .moveTo _ =>
      let prev := getPrevVertex segs idx
      calcLineAngle prev.x prev.y p.x p.y
    | .cubicTo _ p2 p, .moveTo _ =>
      if p.x == p2.x && p.y == p2.y then
        let prev := getPrevVertex segs idx
        calcLineAngle prev.x prev.y p.x p.y
      else calcLineAngle p2.x p2.y p.x p.y
    | .lineTo p, .close =>
      let prev := getPrevVertex segs idx
      let next := getSubpathStart segs idx
      calcAngle4 prev.x prev.y p.x p.y p.x p.y next.x next.y
    | _, .close =>
      let prev := getPrevVertex segs idx
      let next := getSubpathStart segs idx
      calcLineAngle prev.x prev.y next.x next.y
    | _, .moveTo _ => (65536, 0)
    | .close, _ => (65536, 0)

/-! ## `draw_markers`: which vertices get a marker -/

def startVertex (segs : Array Seg) : Option Pt :=
  match segs.getD 0 default with
  | .moveTo p => some p
  | _ => none

def midVertices (segs : Array Seg) : Array (Pt × Nat) := Id.run do
  let n := segs.size
  if n == 0 then return #[]
  let mut out : Array (Pt × Nat) := #[]
  for i in [1:n - 1] do
    match segs.getD i default with
    | .moveTo p => out := out.push (p, i)
    | .lineTo p => out := out.push (p, i)
    | .cubicTo _ _ p => out := out.push (p, i)
    | .close => pure ()
  return out

def endVertex (segs : Array Seg) : Option (Pt × Nat) :=
  if segs.size == 0 then none else
  let idx := segs.size - 1
  match segs.getD idx default with
  | .lineTo p => some (p, idx)
  | .cubicTo _ _ p => some (p, idx)
  | .close => some (getSubpathStart segs idx, idx)
  | _ => none

/-- The rotation `Mat` for one vertex: `auto`/`auto-start-reverse` from
`calcVertexAngle` (with the start vertex's angle flipped 180° for
`auto-start-reverse`, `MarkerOrientation::AutoStartReverse if idx == 0`), a
fixed angle otherwise. -/
def orientMat (segs : Array Seg) (idx : Nat) (isStart : Bool) (orient : MarkerOrient) : Mat :=
  match orient with
  | .fixed deg => Mat.rotate deg
  | .auto => let (c, s) := calcVertexAngle segs idx; Mat.mk' c s (-s) c 0 0
  | .autoStartReverse =>
    let (c, s) := calcVertexAngle segs idx
    if isStart then Mat.mk' (-c) (-s) s (-c) 0 0 else Mat.mk' c s (-s) c 0 0

/-! ## Instancing -/

/-- `resolve`'s `ts`: `translate(p) · rotate(angle) · scale · translate(−refX,
−refY)`, where `scale` is `(strokeScale, strokeScale)` with no `viewBox`, or
-- with one -- just the *scale* usvg's own `vbox_ts.get_scale()` keeps,
discarding that transform's translation (this is usvg's own behaviour, not a
simplification of it: `with-viewBox-1.svg`/`with-viewBox-2.svg` are titled
"(UB)" in the corpus for exactly this reason). -/
def instanceTransform (entry : MarkerEntry) (strokeScale : Fx) (p : Pt) (rotMat : Mat) : Mat :=
  let scaleMat := match entry.viewBox with
    | some (vx, vy, vw, vh) =>
      let dw := Int.ediv (entry.width * strokeScale) 256
      let dh := Int.ediv (entry.height * strokeScale) 256
      let vb := viewBoxTransform vx vy vw vh dw dh entry.alignNone entry.alignX entry.alignY entry.slice
      Mat.mk' vb.a 0 0 vb.d 0 0
    | none => Mat.scale strokeScale strokeScale
  (((Mat.translate p.x p.y).mul rotMat).mul scaleMat).mul (Mat.translate (-entry.refX) (-entry.refY))

/-- How many nested/`markerUnits`-scaled marker levels an id may open onto
another; `maxDepth` in `Clip.lean` is the same idea for `clipPath`. -/
def maxMarkerDepth : Nat := 8

/-- The total number of `Node`s marker instancing may add to the document.
`vertices × markers-per-vertex(≤ 3) × content-size`, uncapped, is the "10^6
vertices with a heavy marker" attack the task calls out; this is the number
that bounds it, independent of `maxMarkerDepth` (a wide, shallow fan-out is
just as bounded as a deep, narrow one).  Past it, further instances are
silently dropped -- degrading exactly like every other budget in this
renderer (`Svg.maxLayerDepth`, `Render.maxLayerPixels`, `Clip.maxDepth`),
never an error. -/
def maxMarkerNodes : Nat := 200000

def buildIdMap (markers : Array MarkerEntry) : Std.HashMap String Nat := Id.run do
  let mut m : Std.HashMap String Nat := {}
  for i in [0:markers.size] do
    let e := markers.getD i default
    if e.filled then m := m.insert e.id i
  return m

/-- Expand one flat `Node` list -- `Doc.nodes` itself at the top call, or a
`MarkerEntry.content` template on every recursive one -- into its final
form: every `Shape`/`GroupInfo` copied with `extraCtm` composed onto its own
`ctm` (a no-op at the top call, where `extraCtm` is the identity and every
`Shape.style.ctm` is already absolute), and every eligible shape's own
marker references expanded right after it, exactly where resvg's
`parent.children.push` for the shape and then its markers puts them: as
later siblings, not descendants.

`active` is empty only at the top call; a non-empty `active` is what makes
this "inside marker content" (`insideMarker`), which is the one difference
in how a `Node` is copied: a `clip-path` on it is dropped rather than
remapped (see the module doc), which top-level content -- never touched
here at all -- does not need. `fuel` bounds nesting (decremented once per
recursive call, i.e. once per marker level, regardless of how many
instances that level has), `budget` bounds total size and is threaded
through and decremented once per `Node` emitted while `insideMarker`; a
top-level `Node` is never budget-gated, so an ordinary document without
markers is untouched by this function irrespective of its size. -/
def expandContentList (doc : Doc) (idMap : Std.HashMap String Nat) :
    (fuel : Nat) → (active : Array Nat) → (extraCtm : Mat) → (nodesIn : Array Node) →
    (usesAcc : Array ClipUse) → (budget : Nat) → Array Node × Array ClipUse × Nat
  | 0, _, _, _, usesAcc, budget => (#[], usesAcc, budget)
  | fuel + 1, active, extraCtm, nodesIn, usesAcc, budget => Id.run do
    let insideMarker := !active.isEmpty
    let mut outNodes : Array Node := #[]
    let mut usesAcc := usesAcc
    let mut budget := budget
    for node in nodesIn do
      if insideMarker && budget == 0 then
        pure ()
      else
      match node with
      | .groupBegin g =>
        outNodes := outNodes.push (.groupBegin (if insideMarker then { g with clips := #[] } else g))
        if insideMarker then budget := budget - 1
      | .groupEnd =>
        outNodes := outNodes.push .groupEnd
        if insideMarker then budget := budget - 1
      | .shape s =>
        let s' : Shape :=
          if insideMarker then
            { s with style := { s.style with ctm := extraCtm.mul s.style.ctm, clips := #[] } }
          else s
        outNodes := outNodes.push (.shape s')
        if insideMarker then budget := budget - 1
        let hasMarkerRef :=
          s'.style.markerStartId.isSome || s'.style.markerMidId.isSome || s'.style.markerEndId.isSome
        if s'.markerable && hasMarkerRef && (!insideMarker || budget > 0) then
          let segs := toSegments s'.cmds
          let targets : Array (Bool × Option String × Array (Pt × Nat)) :=
            #[(true, s'.style.markerStartId, match startVertex segs with | some p => #[(p, 0)] | none => #[]),
              (false, s'.style.markerMidId, midVertices segs),
              (false, s'.style.markerEndId, match endVertex segs with | some pi => #[pi] | none => #[])]
          for (isStart, idOpt, verts) in targets do
            match idOpt with
            | none => pure ()
            | some mid =>
              match idMap.get? mid with
              | none => pure ()
              | some mIdx =>
                let entry := doc.markers.getD mIdx default
                -- `stroke_scale`: `NonZeroPositiveF32` requires > 0, so
                -- `markerUnits = strokeWidth` (the default) with a resolved
                -- `stroke-width ≤ 0` suppresses every instance of this
                -- reference (`zero-sized-stroke.svg`).
                let strokeOk := entry.unitsUser || s'.style.strokeWidth > 0
                if entry.valid && !entry.content.isEmpty && !active.contains mIdx && strokeOk then
                  let strokeScale := if entry.unitsUser then Fx.ofNat 1 else s'.style.strokeWidth
                  for (p, idx) in verts do
                    if !insideMarker || budget > 0 then
                      let rotMat := orientMat segs idx isStart entry.orient
                      let ts := instanceTransform entry strokeScale p rotMat
                      let instanceCtm := s'.style.ctm.mul ts
                      let (inner, usesAcc', budget') :=
                        expandContentList doc idMap fuel (active.push mIdx) instanceCtm entry.content
                          usesAcc budget
                      usesAcc := usesAcc'
                      budget := budget'
                      match entry.clipEntryIdx with
                      | some ceIdx =>
                        usesAcc := usesAcc.push ⟨"", some ceIdx, instanceCtm, none⟩
                        let useIdx := usesAcc.size - 1
                        outNodes := outNodes.push (.groupBegin { opacity := opacityOne, blend := .normal, isolate := false, clips := #[useIdx] })
                        outNodes := outNodes ++ inner
                        outNodes := outNodes.push .groupEnd
                      | none => outNodes := outNodes ++ inner
    return (outNodes, usesAcc, budget)

/-- Resolve every `marker-start`/`marker-mid`/`marker-end` reference in
`doc.nodes` and splice in the referenced marker's content, once per vertex.
The whole document if it has no `<marker>` (`doc.markers.isEmpty`) or no
`Shape` carries a marker reference is returned with `nodes`/`uses` untouched
by identity-equal-in-spirit reconstruction (every `Node` is copied with
`extraCtm = Mat.identity`, a no-op `Mat.mul`, and `insideMarker` is false for
all of it, so no shape or group is otherwise modified either). -/
def expand (doc : Doc) : Doc :=
  if doc.markers.isEmpty then doc else
  let idMap := buildIdMap doc.markers
  let (nodes, uses, _) :=
    expandContentList doc idMap maxMarkerDepth #[] Mat.identity doc.nodes doc.uses maxMarkerNodes
  { doc with nodes := nodes, uses := uses }

end Marker
end LeanSvg
