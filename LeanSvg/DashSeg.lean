import LeanSvg.Geom

/-!
# Dash segments with curve tangents (T107)

`flatten` keeps only points, so a dash end's direction would have to come
from the chord it falls on.  tiny-skia dashes the curve itself and caps each
dash along the curve's tangent, so every dash end on a curve was rotated by up
to half a chord's angle against resvg.  `flattenSegs` flattens exactly as
`flatten` does (same `segCount`, same points) but also records the curve's
derivative at both ends of every chord, for `Geom.dashSegs`.
-/

namespace LeanSvg

/-- Derivative direction of the cubic at `k/n`, scaled by `n²/3`. -/
def cubicDerivAt (p0 p1 p2 p3 : Pt) (k n : Nat) : Pt :=
  let a : Int := n - k
  let b : Int := k
  ⟨a * a * (p1.x - p0.x) + 2 * a * b * (p2.x - p1.x) + b * b * (p3.x - p2.x),
   a * a * (p1.y - p0.y) + 2 * a * b * (p2.y - p1.y) + b * b * (p3.y - p2.y)⟩

/-- Derivative direction of the quadratic at `k/n`, scaled by `n/2`. -/
def quadDerivAt (p0 p1 p2 : Pt) (k n : Nat) : Pt :=
  let a : Int := n - k
  let b : Int := k
  ⟨a * (p1.x - p0.x) + b * (p2.x - p1.x), a * (p1.y - p0.y) + b * (p2.y - p1.y)⟩

/-- Append `p→q` unless it has zero length.  A zero derivative at either end
(a control point on its end point) leaves the segment to its chord. -/
def pushSeg (sg : Array DSeg) (p q tp tq : Pt) : Array DSeg :=
  if p == q then sg
  else if (tp.x == 0 && tp.y == 0) || (tq.x == 0 && tq.y == 0) then
    sg.push ⟨p, q, ⟨0, 0⟩, ⟨0, 0⟩⟩
  else sg.push ⟨p, q, tp, tq⟩

/-- `flatten`, subpath for subpath and point for point, as `DSeg`s: each result
is the subpath's `Poly` and its positive-length segments, the closing one
included. -/
def flattenSegs (ctm : Mat) (cmds : Array PathCmd) : Array (Poly × Array DSeg) := Id.run do
  let z : Pt := ⟨0, 0⟩
  let mut res : Array (Poly × Array DSeg) := #[]
  let mut cur : Array Pt := #[]
  let mut sg : Array DSeg := #[]
  let mut pt : Pt := ⟨0, 0⟩
  let mut start : Pt := ⟨0, 0⟩
  for c in cmds do
    match c with
    | .moveTo p =>
      if cur.size ≥ 1 then res := res.push (⟨cur, false⟩, sg)
      cur := #[p]
      sg := #[]
      pt := p
      start := p
    | .lineTo p =>
      if cur.isEmpty then cur := #[pt]
      sg := pushSeg sg pt p z z
      cur := cur.push p
      pt := p
    | .cubicTo c1 c2 p =>
      if cur.isEmpty then cur := #[pt]
      let n := segCount ctm pt c1 c2 p
      let mut prev := pt
      for k in [1:n + 1] do
        let q := cubicAt pt c1 c2 p k n
        sg := pushSeg sg prev q (cubicDerivAt pt c1 c2 p (k - 1) n) (cubicDerivAt pt c1 c2 p k n)
        cur := cur.push q
        prev := q
      pt := p
    | .quadTo c p =>
      if cur.isEmpty then cur := #[pt]
      let n := segCountQuad ctm pt c p
      let mut prev := pt
      for k in [1:n + 1] do
        let q := quadAt pt c p k n
        sg := pushSeg sg prev q (quadDerivAt pt c p (k - 1) n) (quadDerivAt pt c p k n)
        cur := cur.push q
        prev := q
      pt := p
    | .close =>
      if cur.size ≥ 1 then
        let last := cur.getD (cur.size - 1) default
        res := res.push (⟨cur, true⟩, pushSeg sg last (cur.getD 0 default) z z)
      cur := #[]
      sg := #[]
      pt := start
  if cur.size ≥ 1 then res := res.push (⟨cur, false⟩, sg)
  return res

/-- Dash every subpath of a path, curve tangents included.  `Render.drawShape`'s
entry point. -/
def dashPath (pat : Array Fx) (off : Fx) (ctm : Mat) (cmds : Array PathCmd) : Array Poly :=
  (flattenSegs ctm cmds).foldl (fun out (poly, sg) => dashSegs pat off poly sg out) #[]

end LeanSvg
