import LeanSvg.Bytes
import LeanSvg.Fixed
import LeanSvg.Geom

/-!
# CSS basic shapes for `clip-path` (T92)

`clip-path="circle(40% at 30% 70%) fill-box"` and friends (CSS Shapes 1 and
CSS Masking 1).  usvg 0.48.1 rejects any `clip-path` that is not `url(#id)`,
so the reference is Chromium, whose behaviour (measured through
`tests/render_chrome.py`, see `DESIGN.md`) this follows:

* `circle()`, `ellipse()`, `inset()`, `rect()`, `xywh()` (all with `round`
  radii where CSS allows them), `polygon()` and `path()` (with a fill rule),
  and a reference box keyword alone;
* reference boxes `fill-box` (also `content-box`, `padding-box`),
  `stroke-box` (also `border-box`, `margin-box`, and the default) and
  `view-box` (the nearest viewport's `viewBox` size at user-space `(0, 0)`);
  the box keyword may come before or after the shape, at most once;
* shape coordinates, `path()` included, are offsets from the box's origin;
* lengths take every unit an SVG length does, unitless numbers are px, and
  keywords and function names are ASCII case-insensitive.  Anything invalid
  (a negative radius, a 3-value position, a second box keyword, ...) makes
  the whole value invalid, which means no clipping, as in usvg and Chromium.

Parsing is total and bounded: `maxPolyPoints` polygon vertices and
`maxPathCmds` path commands, beyond which the value is rejected.
-/

namespace LeanSvg
namespace BasicShape

open Bytes

def maxPolyPoints : Nat := 10000
def maxPathCmds : Nat := 100000

/-- A length-percentage `abs + pct% · ref`; `pct` is on the `Fx` grid
(`50%` is `50 * 256`), so an edge measured from the far side (`100% - x`) is
still one value. -/
structure LP where
  abs : Fx := 0
  pct : Fx := 0
deriving Inhabited, Repr

def LP.resolve (l : LP) (ref : Fx) : Fx := Fx.clamp (l.abs + Int.ediv (l.pct * ref) 25600)

/-- `100% - l`. -/
def LP.fromEnd (l : LP) : LP := ⟨-l.abs, 25600 - l.pct⟩

inductive RefBox where
  | fill | stroke | view
deriving Inhabited, Repr, BEq

inductive Radius where
  | lp (l : LP)
  | closest
  | farthest
deriving Inhabited, Repr

inductive Geo where
  | circle (r : Radius) (cx cy : LP)
  | ellipse (rx ry : Radius) (cx cy : LP)
  /-- Edges measured from the box's left/top: `x0 y0 x1 y1`, then the
  radii (`round`) as 8 values: horizontal tl tr br bl, vertical tl tr br bl.
  `inset` stores its edges from the far side as `LP.fromEnd`. -/
  | rect (x0 y0 x1 y1 : LP) (radii : Array LP)
  | polygon (evenOdd : Bool) (pts : Array (LP × LP))
  | path (evenOdd : Bool) (cmds : Array PathCmd)
  /-- A reference box keyword alone: clip to the box. -/
  | box
deriving Inhabited, Repr

structure Spec where
  geo : Geo
  ref : RefBox := .stroke
deriving Inhabited, Repr

/-- What the parser needs from `Svg`: one whole length token (`parseTextLenAll`
with the element's font sizes; `%` never reaches it), and path data. -/
structure Env where
  len : ByteArray → Option Fx
  pathData : ByteArray → Array PathCmd

/-! ## Parsing -/

def boxKeyword (w : ByteArray) : Option RefBox :=
  if eqAsciiCI w "fill-box" || eqAsciiCI w "content-box" || eqAsciiCI w "padding-box" then some .fill
  else if eqAsciiCI w "stroke-box" || eqAsciiCI w "border-box" || eqAsciiCI w "margin-box" then some .stroke
  else if eqAsciiCI w "view-box" then some .view
  else none

/-- Whitespace-separated words, with `/` always its own word. -/
def words (bs : ByteArray) : Array ByteArray := Id.run do
  let mut out : Array ByteArray := #[]
  let mut cur := ByteArray.empty
  for c in bs do
    if isWs c || c == 47 then
      if cur.size > 0 then out := out.push cur
      cur := ByteArray.empty
      if c == 47 then out := out.push (ByteArray.mk #[47])
    else cur := cur.push c
  if cur.size > 0 then out := out.push cur
  return out

/-- One length-percentage word. -/
def lpOf (env : Env) (w : ByteArray) : Option LP :=
  match parseNumber w 0 with
  | none => none
  | some (n, j) =>
    if j + 1 == w.size && at' w j == 37 then some ⟨0, n⟩
    else (env.len w).map fun v => ⟨v, 0⟩

def nonNeg (l : LP) : Bool := l.abs ≥ 0 && l.pct ≥ 0

def radiusOf (env : Env) (w : ByteArray) : Option Radius :=
  if eqAsciiCI w "closest-side" then some .closest
  else if eqAsciiCI w "farthest-side" then some .farthest
  else match lpOf env w with
    | some l => if nonNeg l then some (.lp l) else none
    | none => none

def pct (p : Nat) : LP := ⟨0, (p : Int) * 256⟩

/-- A horizontal (`left`/`right`) or vertical (`top`/`bottom`) keyword, or
`center` (either axis): `(axis, position)` with axis 0 = x, 1 = y, 2 = both. -/
def posKeyword (w : ByteArray) : Option (Nat × LP) :=
  if eqAsciiCI w "left" then some (0, pct 0)
  else if eqAsciiCI w "right" then some (0, pct 100)
  else if eqAsciiCI w "top" then some (1, pct 0)
  else if eqAsciiCI w "bottom" then some (1, pct 100)
  else if eqAsciiCI w "center" then some (2, pct 50)
  else none

/-- `<position>` in its 1-, 2- and 4-value forms (3 values are invalid in a
basic shape, as Chromium has it). -/
def positionOf (env : Env) (ws : Array ByteArray) : Option (LP × LP) :=
  let w0 := ws.getD 0 ByteArray.empty
  let w1 := ws.getD 1 ByteArray.empty
  if ws.size == 1 then
    match posKeyword w0 with
    | some (1, p) => some (pct 50, p)
    | some (_, p) => some (p, pct 50)
    | none => (lpOf env w0).map fun l => (l, pct 50)
  else if ws.size == 2 then
    match posKeyword w0, posKeyword w1 with
    | some (a, p), some (b, q) =>
      if a == 1 && b != 1 then some (q, p)
      else if a != 1 && b != 0 then some (p, q)
      else none
    | some (a, p), none => if a == 1 then none else (lpOf env w1).map fun l => (p, l)
    | none, some (b, q) => if b == 0 then none else (lpOf env w0).map fun l => (l, q)
    | none, none => match lpOf env w0, lpOf env w1 with
      | some a, some b => some (a, b)
      | _, _ => none
  else if ws.size == 4 then
    let w2 := ws.getD 2 ByteArray.empty
    let w3 := ws.getD 3 ByteArray.empty
    match posKeyword w0, lpOf env w1, posKeyword w2, lpOf env w3 with
    | some (a, p), some l1, some (b, q), some l2 =>
      -- `right 10px` is `100% - 10px`; `center` takes no offset.
      let off := fun (k : LP) (l : LP) => if k.pct == 0 then l else l.fromEnd
      if a == 0 && b == 1 then some (off p l1, off q l2)
      else if a == 1 && b == 0 then some (off q l2, off p l1)
      else none
    | _, _, _, _ => none
  else none

/-- `round` radii: 1–4 horizontal values, optionally `/` and 1–4 vertical
ones, expanded like `border-radius` into tl tr br bl. -/
def radiiOf (env : Env) (ws : Array ByteArray) : Option (Array LP) := Id.run do
  let expand := fun (vs : Array LP) =>
    let a := vs.getD 0 {}
    let b := vs.getD 1 a
    let c := vs.getD 2 a
    let d := vs.getD 3 b
    #[a, b, c, d]
  let mut h : Array LP := #[]
  let mut v : Array LP := #[]
  let mut slash := false
  for w in ws do
    if eqAscii w "/" then
      if slash || h.size == 0 then return none
      slash := true
    else match lpOf env w with
      | some l =>
        if !nonNeg l then return none
        if slash then v := v.push l else h := h.push l
      | none => return none
  if h.size == 0 || h.size > 4 || v.size > 4 || (slash && v.size == 0) then return none
  let hs := expand h
  return some (hs ++ (if slash then expand v else hs))

/-- Split `ws` at the first `round` (case-insensitive): before, and the radii. -/
def splitRound (env : Env) (ws : Array ByteArray) : Option (Array ByteArray × Array LP) :=
  match ws.findIdx? (eqAsciiCI · "round") with
  | none => some (ws, Array.replicate 8 {})
  | some k => (radiiOf env (ws.extract (k + 1) ws.size)).map fun r => (ws.extract 0 k, r)

/-- 1–4 edge values, expanded like `margin` into top right bottom left. -/
def edgesOf (env : Env) (ws : Array ByteArray) : Option (Array LP) := Id.run do
  if ws.size == 0 || ws.size > 4 then return none
  let mut vs : Array LP := #[]
  for w in ws do
    match lpOf env w with
    | some l => vs := vs.push l
    | none => return none
  let t := vs.getD 0 {}
  let r := vs.getD 1 t
  let b := vs.getD 2 t
  let l := vs.getD 3 r
  return some #[t, r, b, l]

def circleOf (env : Env) (ws : Array ByteArray) : Option Geo :=
  match ws.findIdx? (eqAsciiCI · "at") with
  | some k =>
    if k > 1 then none
    else
      let r := if k == 0 then some .closest else radiusOf env (ws.getD 0 ByteArray.empty)
      match r, positionOf env (ws.extract (k + 1) ws.size) with
      | some r, some (x, y) => some (.circle r x y)
      | _, _ => none
  | none =>
    if ws.size == 0 then some (.circle .closest (pct 50) (pct 50))
    else if ws.size == 1 then (radiusOf env (ws.getD 0 ByteArray.empty)).map fun r => .circle r (pct 50) (pct 50)
    else none

def ellipseOf (env : Env) (ws : Array ByteArray) : Option Geo :=
  let k := (ws.findIdx? (eqAsciiCI · "at")).getD ws.size
  let pos := if k == ws.size then some (pct 50, pct 50) else positionOf env (ws.extract (k + 1) ws.size)
  let radii : Option (Radius × Radius) :=
    if k == 0 then some (.closest, .closest)
    else if k == 2 then
      match radiusOf env (ws.getD 0 ByteArray.empty), radiusOf env (ws.getD 1 ByteArray.empty) with
      | some a, some b => some (a, b)
      | _, _ => none
    else none
  match radii, pos with
  | some (a, b), some (x, y) => some (.ellipse a b x y)
  | _, _ => none

def insetOf (env : Env) (ws : Array ByteArray) : Option Geo :=
  match splitRound env ws with
  | some (es, radii) =>
    (edgesOf env es).map fun e =>
      .rect (e.getD 3 {}) (e.getD 0 {}) (e.getD 1 {}).fromEnd (e.getD 2 {}).fromEnd radii
  | none => none

/-- `rect(top right bottom left)`: each edge from the box's top or left, `auto`
meaning that side of the box itself. -/
def rectOf (env : Env) (ws : Array ByteArray) : Option Geo :=
  match splitRound env ws with
  | some (es, radii) =>
    if es.size != 4 then none
    else
      let edge := fun (i : Nat) (auto : LP) =>
        let w := es.getD i ByteArray.empty
        if eqAsciiCI w "auto" then some auto else lpOf env w
      match edge 0 (pct 0), edge 1 (pct 100), edge 2 (pct 100), edge 3 (pct 0) with
      | some t, some r, some b, some l => some (.rect l t r b radii)
      | _, _, _, _ => none
  | none => none

def xywhOf (env : Env) (ws : Array ByteArray) : Option Geo :=
  match splitRound env ws with
  | some (es, radii) =>
    if es.size != 4 then none
    else match es.mapM (lpOf env) with
      | some #[x, y, w, h] =>
        if nonNeg w && nonNeg h then
          some (.rect x y ⟨x.abs + w.abs, x.pct + w.pct⟩ ⟨y.abs + h.abs, y.pct + h.pct⟩ radii)
        else none
      | _ => none
  | none => none

/-- A leading `evenodd,`/`nonzero,` of a `polygon()`/`path()` argument list:
the rule and the rest. -/
def fillRule (args : ByteArray) : Bool × ByteArray :=
  let c := findByte args 0 44
  let head := trim (args.extract 0 c)
  if eqAsciiCI head "evenodd" then (true, args.extract (c + 1) args.size)
  else if eqAsciiCI head "nonzero" then (false, args.extract (c + 1) args.size)
  else (false, args)

def polygonOf (env : Env) (args : ByteArray) : Option Geo := Id.run do
  let (eo, rest) := fillRule args
  let items := splitTrim rest 44
  if items.size == 0 || items.size > maxPolyPoints then return none
  let mut pts : Array (LP × LP) := #[]
  for it in items do
    let ws := words it
    if ws.size != 2 then return none
    match lpOf env (ws.getD 0 ByteArray.empty), lpOf env (ws.getD 1 ByteArray.empty) with
    | some x, some y => pts := pts.push (x, y)
    | _, _ => return none
  return some (.polygon eo pts)

def pathOf (env : Env) (args : ByteArray) : Option Geo :=
  let (eo, rest) := fillRule args
  let s := trim rest
  let q := at' s 0
  if s.size < 2 || !(q == 34 || q == 39) || at' s (s.size - 1) != q then none
  else
    let cmds := env.pathData (s.extract 1 (s.size - 1))
    if cmds.size == 0 || cmds.size > maxPathCmds then none else some (.path eo cmds)

/-- The index of the `)` closing the `(` at `i`, skipping quoted strings;
`bs.size` if there is none. -/
def closeParen (bs : ByteArray) (i : Nat) : Nat := Id.run do
  let mut q : UInt8 := 0
  for k in [i + 1:bs.size] do
    let c := at' bs k
    if q != 0 then
      if c == q then q := 0
    else if c == 34 || c == 39 then q := c
    else if c == 41 then return k
  return bs.size

/-- Parse a whole `clip-path` value as a basic shape and/or reference box. -/
def parse (env : Env) (bs : ByteArray) : Option Spec :=
  let t := trim bs
  let o := findByte t 0 40
  if o ≥ t.size then
    (boxKeyword t).map fun b => ⟨.box, b⟩
  else
    let c := closeParen t o
    if c ≥ t.size then none
    else
      let pre := words (t.extract 0 o)
      let post := words (t.extract (c + 1) t.size)
      let name := lower (pre.back?.getD ByteArray.empty)
      let args := t.extract (o + 1) c
      let boxes := (pre.pop ++ post).map boxKeyword
      -- `circle ()` is not a function call.
      if o == 0 || isWs (at' t (o - 1)) || boxes.size > 1 || boxes.any Option.isNone then none
      else
        let ref := (boxes.getD 0 (some .stroke)).getD .stroke
        let geo :=
          if eqAscii name "circle" then circleOf env (words args)
          else if eqAscii name "ellipse" then ellipseOf env (words args)
          else if eqAscii name "inset" then insetOf env (words args)
          else if eqAscii name "rect" then rectOf env (words args)
          else if eqAscii name "xywh" then xywhOf env (words args)
          else if eqAscii name "polygon" then polygonOf env args
          else if eqAscii name "path" then pathOf env args
          else none
        geo.map fun g => ⟨g, ref⟩

/-! ## Geometry -/

/-- κ = 4(√2 − 1)/3 in 16.16, as `Svg.kappa16`. -/
def kappa16 : Int := 36195

def ellipseCmds (cx cy rx ry : Fx) : Array PathCmd :=
  let kx := Int.ediv (rx * kappa16) 65536
  let ky := Int.ediv (ry * kappa16) 65536
  #[.moveTo ⟨cx + rx, cy⟩,
    .cubicTo ⟨cx + rx, cy + ky⟩ ⟨cx + kx, cy + ry⟩ ⟨cx, cy + ry⟩,
    .cubicTo ⟨cx - kx, cy + ry⟩ ⟨cx - rx, cy + ky⟩ ⟨cx - rx, cy⟩,
    .cubicTo ⟨cx - rx, cy - ky⟩ ⟨cx - kx, cy - ry⟩ ⟨cx, cy - ry⟩,
    .cubicTo ⟨cx + kx, cy - ry⟩ ⟨cx + rx, cy - ky⟩ ⟨cx + rx, cy⟩,
    .close]

/-- A rectangle with per-corner elliptical radii `(rx, ry)` for tl tr br bl,
already scaled so adjacent radii never overlap. -/
def roundRectCmds (x0 y0 x1 y1 : Fx) (r : Array (Fx × Fx)) : Array PathCmd :=
  let k := fun (v : Fx) => Int.ediv (v * kappa16) 65536
  let (ax, ay) := r.getD 0 (0, 0)
  let (bx, by_) := r.getD 1 (0, 0)
  let (cx, cy) := r.getD 2 (0, 0)
  let (dx, dy) := r.getD 3 (0, 0)
  #[.moveTo ⟨x0 + ax, y0⟩,
    .lineTo ⟨x1 - bx, y0⟩,
    .cubicTo ⟨x1 - bx + k bx, y0⟩ ⟨x1, y0 + by_ - k by_⟩ ⟨x1, y0 + by_⟩,
    .lineTo ⟨x1, y1 - cy⟩,
    .cubicTo ⟨x1, y1 - cy + k cy⟩ ⟨x1 - cx + k cx, y1⟩ ⟨x1 - cx, y1⟩,
    .lineTo ⟨x0 + dx, y1⟩,
    .cubicTo ⟨x0 + dx - k dx, y1⟩ ⟨x0, y1 - dy + k dy⟩ ⟨x0, y1 - dy⟩,
    .lineTo ⟨x0, y0 + ay⟩,
    .cubicTo ⟨x0, y0 + ay - k ay⟩ ⟨x0 + ax - k ax, y0⟩ ⟨x0 + ax, y0⟩,
    .close]

def PathCmd.shift (dx dy : Fx) : PathCmd → PathCmd
  | .moveTo p => .moveTo ⟨p.x + dx, p.y + dy⟩
  | .lineTo p => .lineTo ⟨p.x + dx, p.y + dy⟩
  | .cubicTo a b p => .cubicTo ⟨a.x + dx, a.y + dy⟩ ⟨b.x + dx, b.y + dy⟩ ⟨p.x + dx, p.y + dy⟩
  | .quadTo a p => .quadTo ⟨a.x + dx, a.y + dy⟩ ⟨p.x + dx, p.y + dy⟩
  | .close => .close

/-- `min`/`max` of the distances from `c` to the two sides `[a, b]`. -/
def sideDist (c a b : Fx) (far : Bool) : Fx :=
  let d1 := (c - a).natAbs
  let d2 := (b - c).natAbs
  (if far then Nat.max d1 d2 else Nat.min d1 d2 : Nat)

/-- The shape's outline in the element's user space, for reference box `b`,
and whether it fills even-odd.  An empty or degenerate shape is no outline at
all, which clips everything away. -/
def build (s : Spec) (b : Box) : Array PathCmd × Bool :=
  let w := b.x1 - b.x0
  let h := b.y1 - b.y0
  match s.geo with
  | .box => (#[.moveTo ⟨b.x0, b.y0⟩, .lineTo ⟨b.x1, b.y0⟩, .lineTo ⟨b.x1, b.y1⟩, .lineTo ⟨b.x0, b.y1⟩, .close], false)
  | .circle r cx cy =>
    let x := b.x0 + cx.resolve w
    let y := b.y0 + cy.resolve h
    let rad := match r with
      | .lp l => l.resolve (Fx.scale16 (Fx.hypot w h) 46341)
      | .closest => Fx.min (sideDist x b.x0 b.x1 false) (sideDist y b.y0 b.y1 false)
      | .farthest => Fx.max (sideDist x b.x0 b.x1 true) (sideDist y b.y0 b.y1 true)
    (if rad > 0 then ellipseCmds x y rad rad else #[], false)
  | .ellipse rx ry cx cy =>
    let x := b.x0 + cx.resolve w
    let y := b.y0 + cy.resolve h
    let rad := fun (r : Radius) (c a e ref : Fx) => match r with
      | .lp l => l.resolve ref
      | .closest => sideDist c a e false
      | .farthest => sideDist c a e true
    let a := rad rx x b.x0 b.x1 w
    let c := rad ry y b.y0 b.y1 h
    (if a > 0 && c > 0 then ellipseCmds x y a c else #[], false)
  | .rect ex0 ey0 ex1 ey1 radii =>
    let x0 := ex0.resolve w
    let y0 := ey0.resolve h
    let x1 := ex1.resolve w
    let y1 := ey1.resolve h
    -- Insets adding up to more than the box shrink proportionally (CSS
    -- Shapes: `inset()`); a far edge before the near one is the near one.
    let fit := fun (lo hi len : Fx) =>
      let a := lo
      let c := len - hi
      if a + c > len && a + c > 0 then
        let a' := Int.ediv (a * len) (a + c)
        (a', a')
      else (lo, Fx.max lo hi)
    let (x0, x1) := fit x0 x1 w
    let (y0, y1) := fit y0 y1 h
    let rw := x1 - x0
    let rh := y1 - y0
    if rw ≤ 0 || rh ≤ 0 then (#[], false)
    else
      let rs : Array (Fx × Fx) := (Array.range 4).map fun i =>
        ((radii.getD i {}).resolve w, (radii.getD (i + 4) {}).resolve h)
      -- CSS Backgrounds' `f = min(Lᵢ / Sᵢ)` over the four sides.
      let side := fun (len s : Fx) => if s > len && s > 0 then some (len, s) else none
      let g := fun (i : Nat) => rs.getD i (0, 0)
      let cands := #[side rw ((g 0).1 + (g 1).1), side rw ((g 3).1 + (g 2).1),
                     side rh ((g 0).2 + (g 3).2), side rh ((g 1).2 + (g 2).2)]
      let f := cands.foldl (fun acc c => match acc, c with
        | none, c => c
        | some a, some c => if c.1 * a.2 < a.1 * c.2 then some c else some a
        | a, none => a) none
      let rs := match f with
        | some (n, d) => rs.map fun (p, q) => (Int.ediv (p * n) d, Int.ediv (q * n) d)
        | none => rs
      let (ox, oy) := (b.x0 + x0, b.y0 + y0)
      (roundRectCmds ox oy (ox + rw) (oy + rh) rs, false)
  | .polygon eo pts =>
    let ps := pts.map fun (px, py) => Pt.mk (b.x0 + px.resolve w) (b.y0 + py.resolve h)
    if ps.size < 3 then (#[], eo)
    else
      let rest := (ps.extract 1 ps.size).map PathCmd.lineTo
      (#[PathCmd.moveTo (ps.getD 0 default)] ++ rest ++ #[.close], eo)
  | .path eo cmds => (cmds.map (PathCmd.shift b.x0 b.y0), eo)

end BasicShape
end LeanSvg
