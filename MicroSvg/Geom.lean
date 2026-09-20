import MicroSvg.Fixed

/-!
# Geometry: points, affine transforms, paths, flattening, stroking

Everything is integer fixed point.  Curves are flattened with a fixed,
bounded subdivision count so every loop here is a `for` over a finite range.
-/

namespace MicroSvg

structure Pt where
  x : Fx
  y : Fx
deriving Repr, Inhabited, BEq

namespace Pt
def add (p q : Pt) : Pt := ⟨Fx.clamp (p.x + q.x), Fx.clamp (p.y + q.y)⟩
def sub (p q : Pt) : Pt := ⟨Fx.clamp (p.x - q.x), Fx.clamp (p.y - q.y)⟩
def neg (p : Pt) : Pt := ⟨-p.x, -p.y⟩
def dist (p q : Pt) : Fx := Fx.hypot (p.x - q.x) (p.y - q.y)
end Pt

/-! ## Trigonometry in 16.16 fixed point (for `rotate` and `skew`) -/

/-- π in 16.16. -/
def pi16 : Int := 205887
/-- π/2 in 16.16. -/
def halfPi16 : Int := 102944
/-- π/4 in 16.16. -/
def quarterPi16 : Int := 51472

/-- Degrees (as `Fx`) to radians in 16.16, reduced to [0, 2π). -/
def degToRad16 (deg : Fx) : Int :=
  let d := Int.emod deg (360 * 256)
  Int.ediv (d * 205887) 46080

/-- `(sin θ, cos θ)` in 16.16 for `θ` in 16.16 radians.  Quadrant reduction plus
a short Taylor series on `[-π/4, π/4]`; error is below 2^-16. -/
def sinCos16 (rad : Int) : Int × Int :=
  let q := Int.ediv (rad + quarterPi16) halfPi16
  let r := rad - q * halfPi16
  let r2 := Int.ediv (r * r) 65536
  let t3 := Int.ediv (r * r2) 65536
  let t5 := Int.ediv (t3 * r2) 65536
  let t7 := Int.ediv (t5 * r2) 65536
  let s := r - Int.ediv t3 6 + Int.ediv t5 120 - Int.ediv t7 5040
  let c4 := Int.ediv (r2 * r2) 65536
  let c6 := Int.ediv (c4 * r2) 65536
  let c := 65536 - Int.ediv r2 2 + Int.ediv c4 24 - Int.ediv c6 720
  match Int.emod q 4 with
  | 0 => (s, c)
  | 1 => (c, -s)
  | 2 => (-s, -c)
  | _ => (-c, s)

/-! ## Affine matrices -/

/-- Affine matrix `[a c e; b d f]`.  `a b c d` carry 16 fractional bits,
`e f` are translations in `Fx`. -/
structure Mat where
  a : Int
  b : Int
  c : Int
  d : Int
  e : Fx
  f : Fx
deriving Repr, Inhabited, BEq

namespace Mat

/-- Bound on the linear part: ±2^28 in 16.16, i.e. scale factors up to 4096. -/
def linMax : Int := 268435456
def clampLin (v : Int) : Int := if v > linMax then linMax else if v < -linMax then -linMax else v

def identity : Mat := ⟨65536, 0, 0, 65536, 0, 0⟩

def mk' (a b c d : Int) (e f : Fx) : Mat :=
  ⟨clampLin a, clampLin b, clampLin c, clampLin d, Fx.clamp e, Fx.clamp f⟩

def apply (m : Mat) (p : Pt) : Pt :=
  ⟨Fx.clamp (Int.ediv (m.a * p.x + m.c * p.y) 65536 + m.e),
   Fx.clamp (Int.ediv (m.b * p.x + m.d * p.y) 65536 + m.f)⟩

/-- `m.mul n` applies `n` first, then `m` (matrix product `m · n`). -/
def mul (m n : Mat) : Mat :=
  mk' (Int.ediv (m.a * n.a + m.c * n.b) 65536)
      (Int.ediv (m.b * n.a + m.d * n.b) 65536)
      (Int.ediv (m.a * n.c + m.c * n.d) 65536)
      (Int.ediv (m.b * n.c + m.d * n.d) 65536)
      (Int.ediv (m.a * n.e + m.c * n.f) 65536 + m.e)
      (Int.ediv (m.b * n.e + m.d * n.f) 65536 + m.f)

def translate (tx ty : Fx) : Mat := mk' 65536 0 0 65536 tx ty
/-- Scale by 16.16 factors. -/
def scale16 (sx sy : Int) : Mat := mk' sx 0 0 sy 0 0
/-- Scale by `Fx` factors. -/
def scale (sx sy : Fx) : Mat := mk' (sx * 256) 0 0 (sy * 256) 0 0
def rotate (deg : Fx) : Mat :=
  let (s, c) := sinCos16 (degToRad16 deg)
  mk' c s (-s) c 0 0
def skewX (deg : Fx) : Mat :=
  let (s, c) := sinCos16 (degToRad16 deg)
  let t := if c == 0 then linMax else Int.ediv (s * 65536) c
  mk' 65536 0 t 65536 0 0
def skewY (deg : Fx) : Mat :=
  let (s, c) := sinCos16 (degToRad16 deg)
  let t := if c == 0 then linMax else Int.ediv (s * 65536) c
  mk' 65536 t 0 65536 0 0

end Mat

/-! ## Paths -/

inductive PathCmd where
  | moveTo (p : Pt)
  | lineTo (p : Pt)
  | cubicTo (c1 c2 p : Pt)
  | close
deriving Repr, Inhabited

/-- A flattened subpath. -/
structure Poly where
  pts : Array Pt
  closed : Bool
deriving Repr, Inhabited

/-- Number of line segments used for a cubic, from its control-polygon length in
device space.  Bounded in `[1, 100]`, so flattening cost is linear in the path. -/
def segCount (ctm : Mat) (p0 p1 p2 p3 : Pt) : Nat :=
  let q0 := ctm.apply p0
  let q1 := ctm.apply p1
  let q2 := ctm.apply p2
  let q3 := ctm.apply p3
  let l := q0.dist q1 + q1.dist q2 + q2.dist q3
  let lpx := (Int.ediv l 256).toNat
  Nat.min 100 (Nat.max 1 (Nat.sqrt (2 * lpx) + 1))

/-- Point `k/n` along a cubic Bézier, evaluated exactly in integers. -/
def cubicAt (p0 p1 p2 p3 : Pt) (k n : Nat) : Pt :=
  let a := n - k
  let b := k
  let w0 : Int := a * a * a
  let w1 : Int := 3 * a * a * b
  let w2 : Int := 3 * a * b * b
  let w3 : Int := b * b * b
  let n3 : Int := n * n * n
  if n3 == 0 then p3 else
  ⟨Fx.clamp (Int.ediv (w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x) n3),
   Fx.clamp (Int.ediv (w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y) n3)⟩

/-- Flatten a path into polylines (in the path's own coordinate space).  `ctm` is
only used to decide how finely to subdivide curves. -/
def flatten (ctm : Mat) (cmds : Array PathCmd) : Array Poly := Id.run do
  let mut polys : Array Poly := #[]
  let mut cur : Array Pt := #[]
  let mut pt : Pt := ⟨0, 0⟩
  let mut start : Pt := ⟨0, 0⟩
  for c in cmds do
    match c with
    | .moveTo p =>
      if cur.size ≥ 1 then polys := polys.push ⟨cur, false⟩
      cur := #[p]
      pt := p
      start := p
    | .lineTo p =>
      if cur.isEmpty then cur := #[pt]
      cur := cur.push p
      pt := p
    | .cubicTo c1 c2 p =>
      if cur.isEmpty then cur := #[pt]
      let n := segCount ctm pt c1 c2 p
      for k in [1:n + 1] do
        cur := cur.push (cubicAt pt c1 c2 p k n)
      pt := p
    | .close =>
      if cur.size ≥ 1 then polys := polys.push ⟨cur, true⟩
      cur := #[]
      pt := start
  if cur.size ≥ 1 then polys := polys.push ⟨cur, false⟩
  return polys

/-! ## Stroking

A stroke is converted to a set of polygons (one quad per segment, one wedge per
join, one shape per cap) that are all oriented the same way and then filled with
the nonzero rule, which computes their union. -/

inductive Cap where
  | butt | round | square
deriving Repr, Inhabited, BEq

inductive Join where
  | miter | round | bevel
deriving Repr, Inhabited, BEq

structure StrokeStyle where
  width : Fx
  cap : Cap
  join : Join
  /-- Miter limit as `Fx` (SVG default 4 → 1024). -/
  miterLimit : Fx
deriving Repr, Inhabited

/-- Twice the signed area (shoelace). -/
def signedArea2 (poly : Array Pt) : Int := Id.run do
  let n := poly.size
  let mut s : Int := 0
  for i in [0:n] do
    let p := poly.getD i default
    let q := poly.getD ((i + 1) % n) default
    s := s + (p.x * q.y - q.x * p.y)
  return s

/-- Append a polygon, normalised to non-negative orientation. -/
def emitPoly (out : Array (Array Pt)) (poly : Array Pt) : Array (Array Pt) :=
  if poly.size < 3 then out
  else if signedArea2 poly < 0 then out.push poly.reverse
  else out.push poly

/-- Regular polygon approximating a circle. -/
def circlePoly (c : Pt) (r : Fx) : Array Pt :=
  let rpx := (Int.ediv r 256).toNat
  let n := Nat.min 64 (Nat.max 8 (Nat.sqrt (rpx * 8) + 8))
  Array.ofFn (n := n) fun i =>
    let ang := Int.ediv ((i.val : Int) * 2 * pi16) n
    let (s, co) := sinCos16 ang
    ⟨Fx.clamp (c.x + Int.ediv (r * co) 65536), Fx.clamp (c.y + Int.ediv (r * s) 65536)⟩

/-- Unit normal of segment `p→q`, scaled to length `hw`. -/
def normalOf (p q : Pt) (hw : Fx) : Pt :=
  let dx := q.x - p.x
  let dy := q.y - p.y
  let len := Fx.hypot dx dy
  if len == 0 then ⟨0, 0⟩
  else ⟨Int.ediv (-dy * hw) len, Int.ediv (dx * hw) len⟩

/-- Unit direction of `p→q` scaled to length `hw`. -/
def dirOf (p q : Pt) (hw : Fx) : Pt :=
  let dx := q.x - p.x
  let dy := q.y - p.y
  let len := Fx.hypot dx dy
  if len == 0 then ⟨0, 0⟩
  else ⟨Int.ediv (dx * hw) len, Int.ediv (dy * hw) len⟩

def emitJoin (st : StrokeStyle) (hw : Fx) (out : Array (Array Pt)) (prev cur next : Pt) :
    Array (Array Pt) :=
  let d1 := cur.sub prev
  let d2 := next.sub cur
  let cross := d1.x * d2.y - d1.y * d2.x
  if cross == 0 then out
  else
    let n1 := normalOf prev cur hw
    let n2 := normalOf cur next hw
    -- Outer side of the turn is opposite the turn direction.
    let s : Int := if cross > 0 then -1 else 1
    let o1 : Pt := ⟨s * n1.x, s * n1.y⟩
    let o2 : Pt := ⟨s * n2.x, s * n2.y⟩
    let a := cur.add o1
    let b := cur.add o2
    match st.join with
    | .round => emitPoly out (circlePoly cur hw)
    | .bevel => emitPoly out #[cur, a, b]
    | .miter =>
      let sx := o1.x + o2.x
      let sy := o1.y + o2.y
      let l2 := sx * sx + sy * sy
      -- miter ratio = 2·hw/|o1+o2| must not exceed the limit
      let ok := l2 > 0 && (512 * hw) * (512 * hw) ≤ st.miterLimit * st.miterLimit * l2
      if ok then
        let tip : Pt := ⟨Fx.clamp (cur.x + Int.ediv (sx * 2 * hw * hw) l2),
                         Fx.clamp (cur.y + Int.ediv (sy * 2 * hw * hw) l2)⟩
        emitPoly out #[cur, a, tip, b]
      else emitPoly out #[cur, a, b]

/-- Cap at `to`, for the segment arriving from `from`. -/
def emitCap (st : StrokeStyle) (hw : Fx) (out : Array (Array Pt)) (from_ to : Pt) :
    Array (Array Pt) :=
  match st.cap with
  | .butt => out
  | .round => emitPoly out (circlePoly to hw)
  | .square =>
    let n := normalOf from_ to hw
    let e := dirOf from_ to hw
    emitPoly out #[to.add n, (to.add n).add e, (to.sub n).add e, to.sub n]

/-- Remove consecutive duplicate points (and a closing duplicate for closed polys). -/
def dedupe (poly : Poly) : Array Pt := Id.run do
  let mut out : Array Pt := #[]
  for p in poly.pts do
    match out.back? with
    | some q => if q != p then out := out.push p
    | none => out := out.push p
  if poly.closed && out.size ≥ 2 then
    if out.getD 0 default == out.getD (out.size - 1) default then out := out.pop
  return out

/-- Stroke one polyline into polygons appended to `out`. -/
def strokePoly (st : StrokeStyle) (poly : Poly) (out : Array (Array Pt)) : Array (Array Pt) :=
  Id.run do
    let hw := Int.ediv st.width 2
    if hw ≤ 0 then return out
    let pts := dedupe poly
    let n := pts.size
    if n == 0 then return out
    let mut out := out
    if n == 1 then
      let p := pts.getD 0 default
      match st.cap with
      | .round => return emitPoly out (circlePoly p hw)
      | .square => return emitPoly out #[⟨p.x - hw, p.y - hw⟩, ⟨p.x + hw, p.y - hw⟩,
                                          ⟨p.x + hw, p.y + hw⟩, ⟨p.x - hw, p.y + hw⟩]
      | .butt => return out
    let segs := if poly.closed then n else n - 1
    for i in [0:segs] do
      let p := pts.getD i default
      let q := pts.getD ((i + 1) % n) default
      let nn := normalOf p q hw
      out := emitPoly out #[p.add nn, q.add nn, q.sub nn, p.sub nn]
    let jStart := if poly.closed then 0 else 1
    let jEnd := if poly.closed then n else n - 1
    for i in [jStart:jEnd] do
      let prev := pts.getD ((i + n - 1) % n) default
      let cur := pts.getD i default
      let next := pts.getD ((i + 1) % n) default
      out := emitJoin st hw out prev cur next
    if !poly.closed then
      out := emitCap st hw out (pts.getD 1 default) (pts.getD 0 default)
      out := emitCap st hw out (pts.getD (n - 2) default) (pts.getD (n - 1) default)
    return out

end MicroSvg
