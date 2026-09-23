import LeanSvg.Geom

/-!
# Text on a path (`<textPath>`)

The arc-length machinery behind usvg 0.48.1's text-on-path layout
(`crates/usvg/src/text/layout.rs`, `collect_normals` and
`resolve_clusters_positions_path`).  `Svg.lean` resolves the referenced
shape to `PathCmd`s, `build` turns them into an arc-length table, and
`Text.layout` asks `normals` where each glyph cluster of a path chunk lands.

usvg walks the path segment by segment: `MoveTo` contributes no length,
`Close` is a line back to the subpath start, a line becomes the cubic with
control points at `0.33` and `0.66` of the chord, a quadratic is raised to a
cubic.  It measures each cubic with kurbo's `arclen`, and for a cluster whose
midpoint offset falls in a segment it finds the curve parameter with kurbo's
`inv_arclen` — an ITP root search stopped once the parameter bracket is
`accuracy / length` wide, `accuracy` being `0.5` px over the text's scale —
and evaluates the curve and its derivative there.  That stopping rule leaves
the reference up to about half a pixel off the exact point, so it is
reproduced step for step rather than solved exactly:

* each cubic (16.16 px control points) is cut into `n` equal-parameter
  pieces whose chord lengths make a cumulative table, which stands in for
  kurbo's Gauss–Legendre `arclen` (both are far below a 1/256 px apart);
* `invArclen` runs kurbo's `solve_itp` on that length function with the
  parameter in units of `2^-24`, and returns the midpoint of the final
  bracket, as kurbo does;
* the tangent angle is never formed: the derivative is normalised into a
  16.16 `(cos, sin)` pair, which is all a rotation matrix needs.

Bounds: `n ≤ 64` pieces per segment, so the table is linear in the path; a
lookup is a binary search plus an ITP search of at most 64 steps.
-/

namespace LeanSvg
namespace TextPath

/-- A cubic with 16.16 px control points. -/
structure Cub where
  p0 : Int × Int
  p1 : Int × Int
  p2 : Int × Int
  p3 : Int × Int
deriving Inhabited

/-- Parameter scale: `t = m / tOne`. -/
def tOne : Nat := 16777216

/-- Round `num / den` to nearest (`den > 0`). -/
def rdiv (num den : Int) : Int := if den ≤ 0 then 0 else Int.ediv (2 * num + den) (2 * den)

/-- Point at parameter `m / tOne`, rounded once. -/
def Cub.eval (c : Cub) (m : Nat) : Int × Int :=
  let u : Int := (tOne : Int) - m
  let m : Int := m
  let w0 := u * u * u
  let w1 := 3 * u * u * m
  let w2 := 3 * u * m * m
  let w3 := m * m * m
  let d : Int := (tOne : Int) * tOne * tOne
  (rdiv (w0 * c.p0.1 + w1 * c.p1.1 + w2 * c.p2.1 + w3 * c.p3.1) d,
   rdiv (w0 * c.p0.2 + w1 * c.p1.2 + w2 * c.p2.2 + w3 * c.p3.2) d)

/-- A vector along the derivative at `m / tOne` (unscaled: only its direction
is used). -/
def Cub.deriv (c : Cub) (m : Nat) : Int × Int :=
  let u : Int := (tOne : Int) - m
  let m : Int := m
  (u * u * (c.p1.1 - c.p0.1) + 2 * u * m * (c.p2.1 - c.p1.1) + m * m * (c.p3.1 - c.p2.1),
   u * u * (c.p1.2 - c.p0.2) + 2 * u * m * (c.p2.2 - c.p1.2) + m * m * (c.p3.2 - c.p2.2))

/-- usvg's `create_curve_from_line`: `kurbo::Line::eval(0.33)` and `(0.66)`. -/
def Cub.ofLine (a b : Int × Int) : Cub :=
  ⟨a, (a.1 + rdiv (33 * (b.1 - a.1)) 100, a.2 + rdiv (33 * (b.2 - a.2)) 100),
      (a.1 + rdiv (66 * (b.1 - a.1)) 100, a.2 + rdiv (66 * (b.2 - a.2)) 100), b⟩

/-- `QuadBez::raise`. -/
def Cub.ofQuad (a c b : Int × Int) : Cub :=
  ⟨a, (a.1 + rdiv (2 * (c.1 - a.1)) 3, a.2 + rdiv (2 * (c.2 - a.2)) 3),
      (b.1 + rdiv (2 * (c.1 - b.1)) 3, b.2 + rdiv (2 * (c.2 - b.2)) 3), b⟩

/-- Chord length in 16.16 px between two 16.16 points. -/
def chord (p q : Int × Int) : Int :=
  let dx := (q.1 - p.1).natAbs
  let dy := (q.2 - p.2).natAbs
  Int.ofNat (Nat.sqrt (dx * dx + dy * dy))

/-- One segment and its arc-length table: `cum[k]` is the length from the
segment start to parameter `k / n` (16.16 px), `pts[k]` the point there. -/
structure Seg where
  c : Cub
  n : Nat
  pts : Array (Int × Int)
  cum : Array Int
  /-- Where the segment starts along the whole path. -/
  s0 : Int
deriving Inhabited

def Seg.len (s : Seg) : Int := s.cum.getD s.n 0

structure Table where
  segs : Array Seg := #[]
  /-- Total length, 16.16 px. -/
  total : Int := 0
deriving Inhabited

/-- Pieces for one cubic: four times the count `Geom.flatten` would use at
1:1 (itself a power of two), capped at 64, so it always divides `tOne`. -/
def pieceCount (c : Cub) : Nat :=
  let f := fun (p : Int × Int) => (⟨Int.ediv p.1 256, Int.ediv p.2 256⟩ : Pt)
  Nat.min 64 (4 * segCount Mat.identity (f c.p0) (f c.p1) (f c.p2) (f c.p3))

def Seg.mk' (c : Cub) (s0 : Int) : Seg := Id.run do
  let n := pieceCount c
  let mut pts : Array (Int × Int) := #[c.p0]
  let mut cum : Array Int := #[0]
  let mut prev := c.p0
  let mut s : Int := 0
  for k in [0:n] do
    let nxt := c.eval ((k + 1) * (tOne / n))
    s := s + chord prev nxt
    pts := pts.push nxt
    cum := cum.push s
    prev := nxt
  return { c := c, n := n, pts := pts, cum := cum, s0 := s0 }

/-- Length from the segment start to parameter `m / tOne`. -/
def Seg.arclenTo (s : Seg) (m : Nat) : Int :=
  let step := tOne / s.n
  let k := Nat.min (s.n - 1) (m / step)
  s.cum.getD k 0 + chord (s.pts.getD k (0, 0)) (s.c.eval m)

/-- The arc-length table of `cmds` mapped through `m`, or `none` when the path
draws nothing (tiny-skia's `PathBuilder::finish` refuses a lone `MoveTo`, and
usvg then treats the `textPath` as invalid). -/
def build (cmds : Array PathCmd) (m : Mat) : Option Table := Id.run do
  let p16 := fun (p : Pt) => let q := m.apply p; (q.x * 256, q.y * 256)
  let mut cubs : Array Cub := #[]
  let mut cur : Int × Int := (0, 0)
  let mut start : Int × Int := (0, 0)
  for c in cmds do
    match c with
    | .moveTo p =>
      cur := p16 p
      start := cur
    | .lineTo p =>
      let q := p16 p
      cubs := cubs.push (Cub.ofLine cur q)
      cur := q
    | .quadTo c p =>
      let q := p16 p
      cubs := cubs.push (Cub.ofQuad cur (p16 c) q)
      cur := q
    | .cubicTo c1 c2 p =>
      let q := p16 p
      cubs := cubs.push ⟨cur, p16 c1, p16 c2, q⟩
      cur := q
    | .close =>
      cubs := cubs.push (Cub.ofLine cur start)
      cur := start
  if cubs.isEmpty then return none
  let mut segs : Array Seg := Array.emptyWithCapacity cubs.size
  let mut s : Int := 0
  for c in cubs do
    let sg := Seg.mk' c s
    segs := segs.push sg
    s := s + sg.len
  return some { segs := segs, total := s }

/-- T90: the same path traversed backwards, for SVG 2's `side="right"`, which
puts the text on the other side of the path by reversing its direction. -/
def Table.reverse (t : Table) : Table := Id.run do
  let mut segs : Array Seg := Array.emptyWithCapacity t.segs.size
  let mut s : Int := 0
  for k in [0:t.segs.size] do
    let c := (t.segs.getD (t.segs.size - 1 - k) default).c
    let sg := Seg.mk' ⟨c.p3, c.p2, c.p1, c.p0⟩ s
    segs := segs.push sg
    s := s + sg.len
  return { segs := segs, total := s }

/-- kurbo's `inv_arclen` (`ParamCurveArclen`, driving `common::solve_itp` with
`n0 = 1`, `k1 = 0.2`, `k2 = 2`): the parameter, in units of `1 / tOne`, at
which the segment has length `target`, found to within `accuracy` (16.16
px). -/
def Seg.invArclen (s : Seg) (target accuracy : Int) : Nat := Id.run do
  let len := s.len
  if target ≤ 0 then return 0
  if target ≥ len then return tOne
  let T : Int := tOne
  let eps : Int := max 1 (Int.ediv (accuracy * T) len)
  -- `n1_2 = ceil(log2(1 / epsilon)) - 1`, clamped at 0
  let mut k : Nat := 0
  for _ in [0:64] do
    if eps * (2 ^ k : Nat) ≥ T then break
    k := k + 1
  let nmax := 1 + (k - 1)
  let mut scaled : Int := eps * (2 ^ nmax : Nat)
  let mut a : Int := 0
  let mut b : Int := T
  let mut ya : Int := -target
  let mut yb : Int := len - target
  for _ in [0:64] do
    if b - a ≤ 2 * eps then break
    let x12 := Int.ediv (a + b) 2
    let r := scaled - Int.ediv (b - a) 2
    let xf := Int.ediv (yb * a - ya * b) (yb - ya)
    let sigma := x12 - xf
    let delta := Int.ediv ((b - a) * (b - a)) (5 * T)
    let xt := if delta ≤ sigma.natAbs then (if sigma ≥ 0 then xf + delta else xf - delta) else x12
    let xitp := if (xt - x12).natAbs ≤ r then xt else (if sigma ≥ 0 then x12 - r else x12 + r)
    let y := s.arclenTo xitp.toNat - target
    if y > 0 then
      b := xitp
      yb := y
    else if y < 0 then
      a := xitp
      ya := y
    else return xitp.toNat
    scaled := Int.ediv scaled 2
  return (Int.ediv (a + b) 2).toNat

/-- Where a cluster lands: the path point (16.16 px) and the unit tangent
`(cos, sin)` in 16.16. -/
structure Normal where
  x : Int
  y : Int
  cos : Int
  sin : Int
deriving Inhabited

/-- The unit vector along `(dx, dy)` in 16.16.  A zero derivative gives the
90° kurbo reports for `atan2` of a negative-zero `x` (`angle = 180° − 90°`). -/
def unit (d : Int × Int) : Int × Int :=
  let l := Nat.sqrt (d.1.natAbs * d.1.natAbs + d.2.natAbs * d.2.natAbs)
  if l == 0 then (0, 65536)
  else
    let l : Int := l
    (rdiv (d.1 * 65536) l, rdiv (d.2 * 65536) l)

/-- The point and tangent at arc length `s` (16.16 px), or `none` off the
path.  As in usvg, the first segment whose `[start, end]` contains `s`
wins. -/
def pointAt (t : Table) (accuracy s : Int) : Option Normal := Id.run do
  if s < 0 || s > t.total then return none
  let mut lo : Nat := 0
  let mut hi : Nat := t.segs.size
  for _ in [0:64] do
    if lo ≥ hi then break
    let mid := (lo + hi) / 2
    let sg := t.segs.getD mid default
    if sg.s0 + sg.len ≥ s then hi := mid else lo := mid + 1
  if lo ≥ t.segs.size then return none
  let sg := t.segs.getD lo default
  let m := sg.invArclen (s - sg.s0) accuracy
  let (x, y) := sg.c.eval m
  let (c, sn) := unit (sg.c.deriv m)
  return some ⟨x, y, c, sn⟩

/-- usvg's arc-length accuracy, `0.5 / max(1, sqrt(sx · sy))` px with
`(sx, sy)` the text's scale, in 16.16 px, from a 16.16 linear part. -/
def accuracyFor (a b c d : Int) : Int :=
  let sx := Nat.sqrt (a.natAbs * a.natAbs + b.natAbs * b.natAbs)
  let sy := Nat.sqrt (c.natAbs * c.natAbs + d.natAbs * d.natAbs)
  let s : Int := Nat.sqrt (sx * sy)
  Int.ediv (32768 * 65536) (max 65536 s)

/-- `collect_normals`: one entry per cluster, given each cluster's arc-length
midpoint offset (16.16 px).  usvg first emits `None` for every negative offset
and then fills the rest in order, which is the identity when the negative
offsets are a prefix — the only case positive advances can produce; with a
negative `dx` or `letter-spacing` breaking monotonicity usvg's lists shift
against each other, which is not reproduced here. -/
def normals (t : Table) (accuracy : Int) (offsets : Array Int) : Array (Option Normal) :=
  offsets.map fun s => if s < 0 then none else pointAt t accuracy s

end TextPath
end LeanSvg
