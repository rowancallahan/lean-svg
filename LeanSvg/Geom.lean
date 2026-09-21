import LeanSvg.Fixed

/-!
# Geometry: points, affine transforms, paths, flattening, stroking

Everything is integer fixed point.  Curves are flattened with a fixed,
bounded subdivision count so every loop here is a `for` over a finite range.
-/

namespace LeanSvg

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
  | quadTo (c p : Pt)
  | close
deriving Repr, Inhabited

/-- A flattened subpath. -/
structure Poly where
  pts : Array Pt
  closed : Bool
deriving Repr, Inhabited

/-- How far the two off-curve control points sit from the curve itself, along
one axis: `f(1/3) - b` and `f(2/3) - c` for the cubic `a b c d`, with `19/512`
standing in for `1/27`.  Skia's `SkCubicDeltaFromLine`, which tiny-skia keeps
verbatim in `edge.rs`.

The centre of the curve is not a usable probe (it can coincide with the centre
of the chord on an S-shape), which is why both thirds are taken.  The shifts
are floor divisions and the absolute value is taken *after* them, exactly as
Rust's arithmetic `>>` on a negative `i32` does. -/
def cubicDeltaFromLine (a b c d : Fx) : Fx :=
  let oneThird := Fx.abs (Int.ediv ((a * 8 - b * 15 + c * 6 + d) * 19) 512)
  let twoThird := Fx.abs (Int.ediv ((a + b * 6 - c * 15 + d * 8) * 19) 512)
  Fx.max oneThird twoThird

/-- `max + min/2`, Skia's octagonal stand-in for `√(dx² + dy²)`. -/
def cheapDistance (dx dy : Fx) : Fx :=
  let dx := Fx.abs dx
  let dy := Fx.abs dy
  if dx > dy then dx + Int.ediv dy 2 else dy + Int.ediv dx 2

/-- Bit length of `n`, i.e. `32 - n.leading_zeros()` for a non-negative `i32`.
The loop is a `for` over a constant range; 64 steps cover every `Nat` a
coordinate bounded by `Fx.maxVal` can reach here. -/
def bitLength (n : Nat) : Nat := Id.run do
  let mut v := n
  let mut bits : Nat := 0
  for _ in [0:64] do
    if v != 0 then
      v := v / 2
      bits := bits + 1
  return bits

/-- tiny-skia's `diff_to_shift(dx, dy, shift_aa)` with `shift_aa = 2`, the
value `CubicEdge::new2` passes literally (it does *not* forward the builder's
`clip_shift`, though for us the two coincide).

`dist` starts in supersampled FDot6 — our `Fx` — and is rounded down to eighths
of a supersampled pixel by `(dist + 16) >> 5`; each further subdivision cuts
the chord error by 4, so half the bit length is the number of subdivisions
needed. -/
def diffToShift (dx dy : Fx) : Nat :=
  let dist := (Int.ediv (cheapDistance dx dy + 16) 32).toNat
  bitLength dist / 2

/-- Largest `shift` tiny-skia will use: `MAX_COEFF_SHIFT`, which exists because
Skia stores `curve_count` in an `i8`. -/
def maxCoeffShift : Nat := 6

/-- Number of line segments used for a cubic: tiny-skia's
`CubicEdge::new2`, which takes `2 ^ (diff_to_shift(dx, dy, 2) + 1)` steps with
the exponent clamped to `MAX_COEFF_SHIFT`.  `dx`/`dy` are measured on the
*device-space* control points, which in our units are already the FDot6 values
tiny-skia computes (`Fx` is FDot6 in the 4× supersampled space).

The result is a power of two in `[2, 64]`, so flattening cost stays linear in
the path with a constant a little over twice the old `√(2·L_px) + 1` rule — the
rule that inscribed an 83-gon in an `r = 80` circle where tiny-skia inscribes a
128-gon. -/
def segCount (ctm : Mat) (p0 p1 p2 p3 : Pt) : Nat :=
  let q0 := ctm.apply p0
  let q1 := ctm.apply p1
  let q2 := ctm.apply p2
  let q3 := ctm.apply p3
  let dx := cubicDeltaFromLine q0.x q1.x q2.x q3.x
  let dy := cubicDeltaFromLine q0.y q1.y q2.y q3.y
  2 ^ Nat.min maxCoeffShift (diffToShift dx dy + 1)

/-- `(2·b − a − c) >> 2`, un-abs'd (as tiny-skia leaves it — `cheap_distance`,
called through `diffToShift`, takes the absolute value itself).  The deviation
of a quadratic's single off-curve point from the midpoint of its chord, along
one axis.  `QuadraticEdge::new2`'s inline `(SkLeftShift(x1,1) - x0 - x2) >> 2`;
there is no named function for it in tiny-skia, unlike the cubic's
`cubic_delta_from_line`. -/
def quadDeltaFromLine (a b c : Fx) : Fx :=
  Int.ediv (2 * b - a - c) 4

/-- Number of line segments used for a quadratic: tiny-skia's
`QuadraticEdge::new2`, which takes `2 ^ diff_to_shift(dx, dy, 2)` steps — the
same `diffToShift` the cubic rule uses, since `QuadraticEdge::new` is called
with the builder's `clip_shift = 2` and threads it straight through as
`shift_aa` (unlike the cubic path, which passes the literal `2`; the two
coincide here as they do for cubics).  Two differences from `segCount`:

* **No `+1`.**  The cubic rule adds one shift of headroom because it has to
  fold two off-curve points' deviation into one number; a quadratic has only
  one off-curve point, so `diff_to_shift` already sees the full deviation.
* **Bumped up to at least `2^1`, not down to `2^0`.**  `QuadraticEdge::new2`:
  `if shift == 0 { shift = 1 }` — the comment reads "need at least 1
  subdivision for our bias trick", which is about tiny-skia's forward-difference
  walker (`curve_shift = shift - 1` would underflow its `u8` at `shift = 0`),
  not about visual fidelity.  We evaluate the quadratic exactly at `k/n`
  instead of forward-differencing, so nothing here would break at `shift = 0`,
  but resvg's actual pixels are produced by the bumped path, and matching them
  is the point of this task — so the bump is ported as literally as the cap. -/
def segCountQuad (ctm : Mat) (p0 p1 p2 : Pt) : Nat :=
  let q0 := ctm.apply p0
  let q1 := ctm.apply p1
  let q2 := ctm.apply p2
  let dx := quadDeltaFromLine q0.x q1.x q2.x
  let dy := quadDeltaFromLine q0.y q1.y q2.y
  let s := diffToShift dx dy
  2 ^ (if s == 0 then 1 else Nat.min maxCoeffShift s)

/-- Point `k/n` along a quadratic Bézier, evaluated exactly in integers. -/
def quadAt (p0 p1 p2 : Pt) (k n : Nat) : Pt :=
  let a := n - k
  let b := k
  let w0 : Int := a * a
  let w1 : Int := 2 * a * b
  let w2 : Int := b * b
  let n2 : Int := n * n
  if n2 == 0 then p2 else
  ⟨Fx.clamp (Int.ediv (w0 * p0.x + w1 * p1.x + w2 * p2.x) n2),
   Fx.clamp (Int.ediv (w0 * p0.y + w1 * p1.y + w2 * p2.y) n2)⟩

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
    | .quadTo c p =>
      if cur.isEmpty then cur := #[pt]
      let n := segCountQuad ctm pt c p
      for k in [1:n + 1] do
        cur := cur.push (quadAt pt c p k n)
      pt := p
    | .close =>
      if cur.size ≥ 1 then polys := polys.push ⟨cur, true⟩
      cur := #[]
      pt := start
  if cur.size ≥ 1 then polys := polys.push ⟨cur, false⟩
  return polys

/-! ## Bounding boxes

Used to skip a shape whose pixels cannot land on the canvas.  A box is closed:
it contains its own bounds. -/

structure Box where
  x0 : Fx
  y0 : Fx
  x1 : Fx
  y1 : Fx
deriving Repr, Inhabited

namespace Box

/-- Grow a box (or start one) so that it contains `p`. -/
def cover (b : Option Box) (p : Pt) : Option Box :=
  match b with
  | none => some ⟨p.x, p.y, p.x, p.y⟩
  | some b => some ⟨Fx.min b.x0 p.x, Fx.min b.y0 p.y, Fx.max b.x1 p.x, Fx.max b.y1 p.y⟩

/-- Does this closed box meet the half-open rectangle
`[lox, hix) × [loy, hiy)`? -/
def meets (b : Box) (lox loy hix hiy : Fx) : Bool :=
  b.x1 ≥ lox && b.y1 ≥ loy && b.x0 < hix && b.y0 < hiy

end Box

/-- Does the device-space bounding box of `cmds`' control points meet the
half-open rectangle `[lox, hix) × [loy, hiy)`?

The box is over every `Pt` that appears in `cmds` (cubic and quadratic control
points as well as the endpoint), plus the implicit current point that
`flatten` starts a subpath from, each mapped through `ctm`.  The flattened
path lies inside that box up to rounding: a cubic or quadratic lies inside the
convex hull of its control points, and an affine map takes that hull to the
hull of the mapped points.  `flatten` emits hull points floored to the `Fx`
grid (`cubicAt`/`quadAt` divide with `Int.ediv`) and `Mat.apply` floors again,
so a caller must widen the rectangle by one `Fx` unit of user-space slack
(worth `(|a| + |c|)/65536` in device x) and one of device slack per side —
which is what `Render.shapeOnCanvas` does, along with the stroke's reach.

The state machine mirrors `flatten`'s exactly, so that the implicit start point
of a path that begins with a `lineTo` is accounted for.

The answer is returned as soon as the box built so far already meets the
rectangle, because the box only ever grows and `Box.meets` is monotone under
growth.  That is what keeps the test cheap for the shapes it cannot skip: a
path large enough to straddle the canvas says so within a few commands, and
only a path that really is off-canvas — where the `flatten` and `strokePoly`
this test is about to save dwarf it — is walked to the end. -/
def ctrlBoxMeets (ctm : Mat) (cmds : Array PathCmd) (lox loy hix hiy : Fx) : Bool := Id.run do
  let mut b : Option Box := none
  -- `empty` tracks `flatten`'s `cur.isEmpty`; `pt`/`start` its current points.
  let mut empty := true
  let mut pt : Pt := ⟨0, 0⟩
  let mut start : Pt := ⟨0, 0⟩
  for c in cmds do
    match c with
    | .moveTo p =>
      b := Box.cover b (ctm.apply p)
      pt := p
      start := p
      empty := false
    | .lineTo p =>
      if empty then b := Box.cover b (ctm.apply pt)
      b := Box.cover b (ctm.apply p)
      pt := p
      empty := false
    | .cubicTo c1 c2 p =>
      if empty then b := Box.cover b (ctm.apply pt)
      b := Box.cover b (ctm.apply c1)
      b := Box.cover b (ctm.apply c2)
      b := Box.cover b (ctm.apply p)
      pt := p
      empty := false
    | .quadTo c p =>
      if empty then b := Box.cover b (ctm.apply pt)
      b := Box.cover b (ctm.apply c)
      b := Box.cover b (ctm.apply p)
      pt := p
      empty := false
    | .close =>
      pt := start
      empty := true
    match b with
    | some bb => if bb.meets lox loy hix hiy then return true
    | none => pure ()
  return false

/-- The device-space bounding box of `cmds`' control points: the same box
`ctrlBoxMeets` builds, without the early exit, and `none` for a path that
contributes no point at all.

It is a superset of the flattened path's own box (a Bézier lies inside the hull
of its control points) up to the floors `ctrlBoxMeets` documents, which is what
makes it usable as a layer's allocation rectangle: a layer larger than the ink
inside it only adds transparent pixels, and those composite as a no-op in every
blend mode, while a layer that is too small would clip. -/
def ctrlBox (ctm : Mat) (cmds : Array PathCmd) : Option Box := Id.run do
  let mut b : Option Box := none
  let mut empty := true
  let mut pt : Pt := ⟨0, 0⟩
  let mut start : Pt := ⟨0, 0⟩
  for c in cmds do
    match c with
    | .moveTo p =>
      b := Box.cover b (ctm.apply p)
      pt := p
      start := p
      empty := false
    | .lineTo p =>
      if empty then b := Box.cover b (ctm.apply pt)
      b := Box.cover b (ctm.apply p)
      pt := p
      empty := false
    | .cubicTo c1 c2 p =>
      if empty then b := Box.cover b (ctm.apply pt)
      b := Box.cover b (ctm.apply c1)
      b := Box.cover b (ctm.apply c2)
      b := Box.cover b (ctm.apply p)
      pt := p
      empty := false
    | .quadTo c p =>
      if empty then b := Box.cover b (ctm.apply pt)
      b := Box.cover b (ctm.apply c)
      b := Box.cover b (ctm.apply p)
      pt := p
      empty := false
    | .close =>
      pt := start
      empty := true
  return b

/-! ## Stroking

A stroke is converted to **one closed outline per subpath** and filled with the
nonzero rule, following tiny-skia's `PathStroker` (a port of Skia's
`SkStroke`).  An open subpath gives one polygon; a closed one gives two rings
whose opposite orientations leave the hole at winding 0.

The point of building it this way rather than as a quad per segment plus a
wedge per join is that a seam between two abutting pieces takes the winding
back through zero *inside* the ink, and the scan converter — a faithful port of
tiny-skia's, which emits abutting spans separately rather than merging them —
renders such a seam one alpha level differently (see the Report of
`tasks/T6-perf-raster-walk.md`).  A single outline has no internal seam.

Contours are emitted with whatever orientation they come out with:
`Raster.insideW` is `w ≠ 0`, so only the magnitude of the winding matters, and
a self-crossing polyline (winding ±2 in the overlap) still fills. -/

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

/-- How far, in the path's own coordinate space, `strokePoly` can put a point
away from the polyline it strokes, along either axis.

`hw = width/2` is the half width `strokePoly` uses.  Segment offsets, round
caps and round joins (`arcPts`, `capArcPts`, `circlePoly`), bevel joins and the
pivot of an inner join all stay within `hw`; a square cap adds a half width
along the segment *and* across it, so `2·hw` covers it; a miter tip is at
`hw · miterRatio` and `outerJoin` only emits one when
`miterRatio ≤ miterLimit/256`.  So `hw · max(2, ⌈miterLimit/256⌉)` bounds the
exact constructions.

`normalOf`, `dirOf`, `rotBy`, `circlePoly` and the miter tip each divide with
`Int.ediv`, which can lower a component by one `Fx` unit, and a square cap
stacks two such offsets; using `hw + 2` in place of `hw` and adding a final
`2` absorbs every one of those floors. -/
def strokeReach (st : StrokeStyle) : Fx :=
  let hw := Int.ediv st.width 2
  if hw ≤ 0 then 0
  else
    let ml := -(Int.ediv (-st.miterLimit) 256)
    Fx.clamp ((hw + 2) * (if ml < 2 then 2 else ml) + 2)

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

/-- Vertices in a full turn at radius `r`, for `circlePoly`.  In `[8, 64]`. -/
def arcSteps (r : Fx) : Nat :=
  let rpx := (Int.ediv r 256).toNat
  Nat.min 64 (Nat.max 8 (Nat.sqrt (rpx * 8) + 8))

/-- Vertices in a full turn for a round join or cap: twice `arcSteps`, so at
most 128, and every loop over it is still bounded by a constant.

`arcSteps` is tuned for a standalone disc, where a coarse inscribed polygon is
hard to tell from a circle.  A join or cap arc is not standalone: it has to
meet two straight offsets, and the chord it cuts off shows up against them.
Measured on the corpus (`within%` at natural size, the five stroke-heavy files
plus `04` and `11`), doubling is the best of the multipliers tried —

| ×  | 04     | 11     | 15     | 16     | 20     |
|----|--------|--------|--------|--------|--------|
| 1  | 99.955 | 99.692 | 97.154 | 95.826 | 99.763 |
| 2  | 99.965 | 99.728 | 97.282 | 95.933 | 99.777 |
| 3  | 99.950 | 99.713 | 97.294 | 95.933 | 99.777 |
| 4  | 99.945 | 99.705 | 97.292 | 95.929 | 99.777 |
| 6  | 99.938 | 99.703 | 97.274 | 95.926 | 99.777 |

— and it is not monotone past 2, because an inscribed arc under-covers by
`r(1 - cos(δ/2))` while the straight offsets beside it are a fraction of an
`Fx` unit thin (`normalOf` floors).  At ×2 the two very nearly cancel; finer
arcs remove the first without removing the second.  ×2 is also where the cost
is still nothing: on a flattened curve the turn at a vertex is smaller than
`δ`, so the arc emits no interior points at all. -/
def joinSteps (r : Fx) : Nat := 2 * arcSteps r

/-- Regular polygon approximating a circle. -/
def circlePoly (c : Pt) (r : Fx) : Array Pt :=
  let n := arcSteps r
  Array.ofFn (n := n) fun i =>
    let ang := Int.ediv ((i.val : Int) * 2 * pi16) n
    let (s, co) := sinCos16 ang
    ⟨Fx.clamp (c.x + Int.ediv (r * co) 65536), Fx.clamp (c.y + Int.ediv (r * s) 65536)⟩

/-- `256 · |q - p|`, i.e. the segment length with eight extra fractional bits.

`Fx.hypot` floors, and an offset computed against a *floored* length comes out
systematically **longer** than `hw`: `hw · L / ⌊L⌋`.  On the 1 px segments a
flattened curve is made of that is 0.4 %, so a stroked curve is a consistent
fraction of a pixel fat all the way along — small, but the antialiasing shows
it, and nothing downstream cancels it once the joins are exact.  Eight more
bits put the length error below what a single `Fx` unit of the result can
see. -/
def len8 (dx dy : Fx) : Fx :=
  Int.ofNat (Nat.sqrt (65536 * (dx.natAbs * dx.natAbs + dy.natAbs * dy.natAbs)))

/-- Unit normal of segment `p→q`, scaled to length `hw`.  Points to the
traveller's right in screen axes (x right, y down). -/
def normalOf (p q : Pt) (hw : Fx) : Pt :=
  let dx := q.x - p.x
  let dy := q.y - p.y
  let len := len8 dx dy
  if len == 0 then ⟨0, 0⟩
  else ⟨Int.ediv (-dy * hw * 256) len, Int.ediv (dx * hw * 256) len⟩

/-- Unit direction of `p→q` scaled to length `hw`. -/
def dirOf (p q : Pt) (hw : Fx) : Pt :=
  let dx := q.x - p.x
  let dy := q.y - p.y
  let len := len8 dx dy
  if len == 0 then ⟨0, 0⟩
  else ⟨Int.ediv (dx * hw * 256) len, Int.ediv (dy * hw * 256) len⟩

/-- Rotate `v` by the angle whose 16.16 sine and cosine are `s` and `co`. -/
def rotBy (v : Pt) (s co : Int) : Pt :=
  ⟨Fx.clamp (Int.ediv (v.x * co - v.y * s) 65536),
   Fx.clamp (Int.ediv (v.x * s + v.y * co) 65536)⟩

/-- Append an outline contour as it stands.  Unlike `emitPoly` this does **not**
normalise the orientation: the two contours of a closed stroke must keep their
opposite orientations, or the ring's hole would fill.  `Raster.insideW` is
`w ≠ 0`, so the sign of a single contour never matters. -/
def pushRing (out : Array (Array Pt)) (poly : Array Pt) : Array (Array Pt) :=
  if poly.size < 3 then out else out.push poly

/-- Interior points of the arc about `pivot` from `pivot + o1` to `pivot + o2`,
turning in the direction of `sgn` (the sign of `o1 × o2`).  Each point is `o1`
rotated by `k · 2π/N`, so rounding never accumulates; the walk stops as soon as
the rotated vector has reached or passed `o2`, and after at most `N` steps. -/
def arcPts (pivot o1 o2 : Pt) (hw : Fx) (sgn : Int) (acc : Array Pt) : Array Pt := Id.run do
  let n := joinSteps hw
  let step := Int.ediv (2 * pi16) n
  let mut acc := acc
  for k in [1:n] do
    let (s, co) := sinCos16 (sgn * (k : Int) * step)
    let v := rotBy o1 s co
    if sgn * (v.x * o2.y - v.y * o2.x) ≤ 0 then break
    acc := acc.push (pivot.add v)
  return acc

/-- Interior points of the half circle of radius `hw` about `pivot` running from
`pivot + v` to `pivot - v`.  `v` is the offset normal, which points to the
traveller's right, so turning the negative way bulges the cap forward, away
from the path — the same half circle `round_capper` builds from two conics. -/
def capArcPts (pivot v : Pt) (hw : Fx) (acc : Array Pt) : Array Pt := Id.run do
  let n := joinSteps hw
  let step := Int.ediv (2 * pi16) n
  let mut acc := acc
  for k in [1:(n + 1) / 2] do
    let (s, co) := sinCos16 (-((k : Int) * step))
    acc := acc.push (pivot.add (rotBy v s co))
  return acc

/-- The join geometry for the **outside** of a turn, appended to that side's
list, which currently ends at `pivot + o1` and must end at `pivot + o2`.
`o1`/`o2` are the two segment normals signed onto the outer side. -/
def outerJoin (st : StrokeStyle) (hw : Fx) (outer : Array Pt) (pivot o1 o2 : Pt) (sgn : Int) :
    Array Pt :=
  match st.join with
  | .bevel => outer.push (pivot.add o2)
  | .round => (arcPts pivot o1 o2 hw sgn outer).push (pivot.add o2)
  | .miter =>
    let sx := o1.x + o2.x
    let sy := o1.y + o2.y
    let l2 := sx * sx + sy * sy
    -- miter ratio = 2·hw/|o1+o2| must not exceed the limit; this is Skia's
    -- `sin(θ/2) ≥ 1/miterLimit`, since |o1+o2| = 2·hw·sin(θ/2).
    let ok := l2 > 0 && (512 * hw) * (512 * hw) ≤ st.miterLimit * st.miterLimit * l2
    if ok then
      -- Skia's `do_miter` *replaces* the list's last point with the tip when
      -- the previous segment is a line, because in exact arithmetic the tip
      -- lies on that segment's offset line.  Ours does not: `normalOf` floors
      -- each component, and the two normals of a symmetric corner floor in
      -- opposite directions, so the tip can sit a couple of `Fx` units off the
      -- line.  Replacing would tilt the whole offset edge and move coverage
      -- along its entire length, which measurably costs `04_stroke`.  So keep
      -- `pivot + o1` and append the tip — Skia's `prev_is_line = false` path.
      let tip : Pt := ⟨Fx.clamp (pivot.x + Int.ediv (sx * 2 * hw * hw) l2),
                       Fx.clamp (pivot.y + Int.ediv (sy * 2 * hw * hw) l2)⟩
      (outer.push tip).push (pivot.add o2)
    else outer.push (pivot.add o2)

/-- Skia's `handle_inner_join`: the inside of a turn goes through the pivot and
on to its own offset for the next segment.  This over-covers the corner
slightly, which nonzero winding absorbs, and needs no ray intersection.  `o2` is
the next segment's normal signed onto the *outer* side. -/
def innerJoin (inner : Array Pt) (pivot o2 : Pt) : Array Pt :=
  (inner.push pivot).push (pivot.sub o2)

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

/-- Drop a contour's last point when it repeats the first, so the ring has no
zero-length closing edge. -/
def dropClosingDup (a : Array Pt) : Array Pt :=
  if a.size ≥ 2 && a.getD 0 default == a.getD (a.size - 1) default then a.pop else a

/-- Stroke one polyline into **one closed outline per subpath**, appended to
`out`: a single polygon for an open subpath, and for a closed one the two rings
`lp` and `reverse lm`, whose opposite orientations leave the hole at winding 0.

`lp` collects `p + n` and `lm` collects `p - n`, where `n` is the segment
normal, pointing to the traveller's right.  Neither list is "the outer one":
each join decides which side is outside from the sign of `n₁ × n₂`, gives that
side the join geometry and the other side the pivot treatment.  That is
tiny-skia's `PathStroker` (Skia's `SkStroke`), and it is why there is no
internal seam for the scan converter to render a level differently. -/
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
    -- one normal per segment
    let mut nrm : Array Pt := Array.emptyWithCapacity segs
    for i in [0:segs] do
      nrm := nrm.push (normalOf (pts.getD i default) (pts.getD ((i + 1) % n) default) hw)
    let p0 := pts.getD 0 default
    let n0 := nrm.getD 0 default
    let mut lp : Array Pt := #[p0.add n0]
    let mut lm : Array Pt := #[p0.sub n0]
    for i in [0:segs] do
      let ni := nrm.getD i default
      let q := pts.getD ((i + 1) % n) default
      lp := lp.push (q.add ni)
      lm := lm.push (q.sub ni)
      -- join at `q`, for a closed subpath at the wrap-around too
      if i + 1 < segs || poly.closed then
        let nj := nrm.getD ((i + 1) % segs) default
        let cross := ni.x * nj.y - ni.y * nj.x
        if cross > 0 then
          -- turning right on screen: the outside is the `-n` side
          lm := outerJoin st hw lm q ni.neg nj.neg 1
          lp := innerJoin lp q nj.neg
        else if cross < 0 then
          lp := outerJoin st hw lp q ni nj (-1)
          lm := innerJoin lm q nj
        else if ni.x * nj.x + ni.y * nj.y < 0 then
          -- 180° fold: Skia bevels on the `+n` side whichever way it folds
          lp := lp.push (q.add nj)
          lm := innerJoin lm q nj
        -- else collinear: `AngleType::NearlyLine`, no join at all
    if poly.closed then
      out := pushRing out (dropClosingDup lp)
      out := pushRing out (dropClosingDup lm).reverse
      return out
    -- open: one loop — `lp`, the end cap, `lm` reversed, the start cap
    let pe := pts.getD (n - 1) default
    let nL := nrm.getD (segs - 1) default
    match st.cap with
    | .butt => pure ()
    | .round => lp := capArcPts pe nL hw lp
    | .square =>
      -- `dirOf` floors too, so the extended corner is not exactly on the
      -- offset line either: append rather than replace, as for the miter tip.
      let par := dirOf (pts.getD (n - 2) default) pe hw
      lp := lp.push ((pe.add nL).add par)
      lp := lp.push ((pe.sub nL).add par)
    lp := lp ++ lm.reverse
    match st.cap with
    | .butt => pure ()
    | .round => lp := capArcPts p0 n0.neg hw lp
    | .square =>
      -- The start cap belongs to the segment travelled *backwards*, so take
      -- both its direction and its normal from the reversed segment.  Mixing
      -- a backwards `dirOf` with the forward `n0` would not be consistent:
      -- `normalOf p q` and `normalOf q p` are not exact negatives, since each
      -- component is floored, and the resulting corner is the one the end cap
      -- (which is genuinely forward) would not have produced.
      let par := dirOf (pts.getD 1 default) p0 hw
      let nS := normalOf (pts.getD 1 default) p0 hw
      lp := lp.push ((p0.add nS).add par)
      lp := lp.push ((p0.sub nS).add par)
    return pushRing out lp

/-! ## Dashing

`stroke-dasharray` / `stroke-dashoffset` (SVG 1.1 §11.4).  A dashed stroke is
the stroke of the "on" runs of the path, so dashing happens between `flatten`
and `strokePoly`: each flattened subpath is cut into shorter **open** polylines
and every one of those is then stroked normally, which is what puts a cap on
each end of each dash (`Render.drawShape` does the same for the hairline path,
where `Raster.hairline` caps each dash instead).

Lengths are measured along the *flattened* polyline, in the path's own
coordinate space, with `Fx.hypot`.  tiny-skia measures along the curve itself
(`ContourMeasure`), so on a flattened curve our dash phase drifts by the
difference between the chords and the arcs they cut — below a tenth of a pixel
on a circle, since `segCount` keeps the chords near a pixel long. -/

/-- The most dashes one subpath may be cut into.  A pattern whose sum is tiny
next to the subpath — `stroke-dasharray="0.0001"` on a long path — would
otherwise cost a dash per fraction of a pixel; past this many the subpath is
drawn **solid** instead.  The bound is what makes every loop below finite. -/
def maxDashes : Nat := 100000

/-- Normalise a `stroke-dasharray` value into an even-length pattern and its
sum, or `none` for "draw solid".

Following SVG 1.1 §11.4 and usvg's `conv_dasharray`: a negative entry makes the
whole list an error, a sum of zero means no dashing, and an odd-length list is
repeated once so that entries alternate on/off forever.  The first entry is
"on". -/
def dashPattern (pat : Array Fx) : Option (Array Fx × Fx) := Id.run do
  if pat.isEmpty then return none
  let mut s : Fx := 0
  for d in pat do
    if d < 0 then return none
    s := s + d
  if s ≤ 0 then return none
  if pat.size % 2 == 1 then return some (pat ++ pat, 2 * s) else return some (pat, s)

/-- Cut one flattened subpath into its "on" runs, appending each as an open
`Poly` to `out`.  `pat` is the raw `stroke-dasharray` list and `off` the
`stroke-dashoffset`.

The pattern starts afresh at each subpath, which is what resvg does (and what
`painting/stroke-dasharray/multiple-subpaths.svg` checks).  `off` is reduced
`mod S` euclidean-ly, so a negative offset walks backwards through the pattern
and an offset larger than the sum wraps; the pattern is then walked to find the
entry the subpath starts inside and how much of it is left, exactly as
tiny-skia's `StrokeDash::new` does.

A **closed** subpath is dashed as an open path that starts at its first point —
the pattern runs on across the closing segment — with one twist taken from
Skia's `SkDashPath::InternalFilter` (which tiny-skia ports): when the walk
starts inside an "on" entry with a positive length left, that initial dash is
*deferred* and re-emitted at the end, joined onto the final dash if the subpath
ends "on".  The start point of a closed dashed path is then an ordinary join
rather than two dash ends, which is what resvg draws: without this, a dashed
`<rect>` whose first dash runs through its top-left corner is missing the outer
quadrant of that corner (8×8 px of a 16 px stroke — `max_d` 255 over 64 px).
A zero-length initial dash is *not* deferred, matching Skia's
`initialDashLength > 0`, so the dots of `0-n-with-*-caps.svg` stay put.

A zero-length "on" entry yields a single-point `Poly`, which `strokePoly`
renders as a dot for round and square caps and as nothing for butt caps —
`painting/stroke-dasharray/0-n-with-*-caps.svg`.

The subpath is appended unchanged (i.e. drawn solid) when the pattern says so
and when the dash count would exceed `maxDashes`; a zero-length subpath is
dropped instead. -/
def dashPoly (pat : Array Fx) (off : Fx) (poly : Poly) (out : Array Poly) : Array Poly :=
  Id.run do
    let some (pat, S) := dashPattern pat | return out.push poly
    let m := pat.size
    let pts := dedupe poly
    let n := pts.size
    -- a subpath of zero length has nothing to dash: tiny-skia's
    -- `ContourMeasureIter` drops it, so resvg draws no dot for it either, even
    -- with round caps.  (Undashed, `strokePoly` still draws that dot.)
    if n < 2 then return out
    let segs := if poly.closed then n else n - 1
    -- total length first: it decides whether this subpath is dashable at all
    let mut total : Nat := 0
    for i in [0:segs] do
      total := total + ((pts.getD i default).dist (pts.getD ((i + 1) % n) default)).toNat
    if total * m > maxDashes * S.toNat then return out.push poly
    -- the entry the subpath starts in, and how much of it is left
    let mut idx : Nat := 0
    let mut rem : Fx := pat.getD 0 0
    let mut o : Fx := Int.emod off S
    for k in [0:m] do
      let d := pat.getD k 0
      -- Skia's `phase > gap || (phase == gap && gap)` (`SkDashPath::
      -- CalcDashParameters`).  The second half is what makes a *zero* entry
      -- different from an entry the offset happens to land on the end of: an
      -- offset of 0 stops inside a leading `0` and dots it, while an offset of
      -- exactly `intervals[0]` steps over that entry into the gap.  resvg
      -- draws both that way (`stroke-dasharray="0 26"` dots the start point;
      -- `"10 20"` with offset 10 does not).
      if o > d || (o == d && d > 0) then
        o := o - d
      else
        idx := k
        rem := d - o
        break
    let mut on := idx % 2 == 0
    -- a closed subpath that starts inside a dash defers that dash to the end
    let mut deferring := poly.closed && on && rem > 0
    let mut first : Array Pt := #[]
    let mut cur : Array Pt := if on then #[pts.getD 0 default] else #[]
    let mut out := out
    for i in [0:segs] do
      let p := pts.getD i default
      let q := pts.getD ((i + 1) % n) default
      let dx := q.x - p.x
      let dy := q.y - p.y
      let L := Fx.hypot dx dy
      if L ≤ 0 then continue
      -- every pass either ends the segment or moves on to the next entry, and
      -- the entries crossed by one segment are bounded by its own length
      let fuel := (L.toNat * m) / S.toNat + m + 2
      let mut pos : Fx := 0
      for _ in [0:fuel] do
        if rem > L - pos then
          -- the rest of the segment lies inside the current entry
          rem := rem - (L - pos)
          if on then cur := cur.push q
          break
        -- a dash boundary falls on this segment, `pos` along it from `p`
        pos := pos + rem
        let bp : Pt :=
          ⟨Fx.clamp (p.x + Int.ediv (dx * pos) L), Fx.clamp (p.y + Int.ediv (dy * pos) L)⟩
        if on then
          if deferring then
            first := cur.push bp
            deferring := false
          else
            out := out.push ⟨cur.push bp, false⟩
          cur := #[]
        else
          cur := #[bp]
        on := !on
        idx := (idx + 1) % m
        rem := pat.getD idx 0
        -- Skia walks `while distance < length`, so a boundary that falls
        -- exactly on the subpath's last point closes the run before it but
        -- starts nothing after it: no dot there, and for a closed subpath the
        -- deferred dash below is emitted on its own rather than joined.
        if i + 1 == segs && pos == L then
          cur := #[]
          break
    -- the run the subpath ends in, and the deferred initial dash behind it: one
    -- polyline when the subpath ends "on" (a join at the start point), two
    -- separate dashes otherwise.  `first` is empty unless a dash was deferred
    -- *and* completed, so an open subpath and a too-short closed one fall
    -- through to the plain case.
    if on && cur.size ≥ 1 then
      out := out.push ⟨if first.isEmpty then cur else cur ++ first, false⟩
    else if !first.isEmpty then
      out := out.push ⟨first, false⟩
    return out

/-- Dash every subpath of a flattened path.  `Render.drawShape`'s entry point. -/
def dashPolys (pat : Array Fx) (off : Fx) (polys : Array Poly) : Array Poly :=
  polys.foldl (fun out p => dashPoly pat off p out) (Array.emptyWithCapacity polys.size)

end LeanSvg
