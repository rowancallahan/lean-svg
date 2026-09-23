import LeanSvg.Geom

/-!
# Viewports: `viewBox` + `preserveAspectRatio` (T48)

The one piece of math a new viewport needs: the map from a `viewBox` rect into
a `width × height` viewport under a `preserveAspectRatio`.  Used by the root
`<svg>` (`Render.canvasSetup`) and nested `<svg>` (`Svg.interpret`); `<symbol>`
(T47) needs exactly the same map.  Mirrors usvg's `ViewBox::to_transform`
(`crates/usvg/src/tree/geom.rs`) and svgtypes' `AspectRatio` parser.
-/

namespace LeanSvg
namespace Viewport

open Bytes

/-- Where the scaled `viewBox` sits along one axis. -/
inductive Pos where
  | min | mid | max
deriving Repr, Inhabited, BEq

/-- A parsed `preserveAspectRatio`.  `align = none` is the `none` keyword
(non-uniform scaling); otherwise the x and y positions.  The default is
`xMidYMid meet`, which is also what an unparseable value becomes (usvg's
`unwrap_or_default`). -/
structure AspectRatio where
  align : Option (Pos × Pos) := some (.mid, .mid)
  slice : Bool := false
deriving Repr, Inhabited, BEq

def posOf (c0 c1 c2 : UInt8) : Option Pos :=
  if c0 == 77 && c1 == 105 && c2 == 110 then some .min      -- "Min"
  else if c0 == 77 && c1 == 105 && c2 == 100 then some .mid -- "Mid"
  else if c0 == 77 && c1 == 97 && c2 == 120 then some .max  -- "Max"
  else none

/-- `xMinYMid` etc. (case-sensitive, as in svgtypes). -/
def parseAlign (t : ByteArray) : Option (Option (Pos × Pos)) :=
  if eqAscii t "none" then some none
  else if t.size == 8 && at' t 0 == 120 && at' t 4 == 89 then
    match posOf (at' t 1) (at' t 2) (at' t 3), posOf (at' t 5) (at' t 6) (at' t 7) with
    | some px, some py => some (some (px, py))
    | _, _ => none
  else none

/-- svgtypes' grammar: `[defer] <align> [meet | slice]`, whitespace separated.
Anything else is the default. -/
def parseAspectRatio (bs : ByteArray) : AspectRatio := Id.run do
  let mut ws := ByteArray.emptyWithCapacity bs.size
  for c in bs do
    ws := ws.push (if isWs c then 32 else c)
  let toks := splitTrim ws 32
  let toks := if toks.size > 0 && eqAscii (toks.getD 0 .empty) "defer" then toks.extract 1 toks.size else toks
  if toks.size == 0 || toks.size > 2 then return {}
  match parseAlign (toks.getD 0 .empty) with
  | none => return {}
  | some al =>
    if toks.size == 1 then return { align := al }
    let m := toks.getD 1 .empty
    if eqAscii m "meet" then return { align := al }
    if eqAscii m "slice" then return { align := al, slice := true }
    return {}

/-- Offset of the leftover `rem` for a position. -/
def posOff (p : Pos) (rem : Fx) : Fx :=
  match p with
  | .min => 0
  | .mid => Int.ediv rem 2
  | .max => rem

/-- `ViewBox::to_transform`: map the `viewBox` `(vx, vy, vw, vh)` into a
`w × h` viewport.  Scales are 16.16, like `Mat`'s linear part.  `none` when
the `viewBox` or the viewport has a non-positive side (usvg: no transform).

For `xMidYMid meet` this is, operation for operation, the formula the root
used before T48, so every existing document keeps its bytes. -/
def viewBoxTransform (vb : Fx × Fx × Fx × Fx) (ar : AspectRatio) (w h : Fx) : Option Mat :=
  let (vx, vy, vw, vh) := vb
  if vw ≤ 0 || vh ≤ 0 || w ≤ 0 || h ≤ 0 then none
  else
    let sx := Int.ediv (w * 65536) vw
    let sy := Int.ediv (h * 65536) vh
    match ar.align with
    | none =>
      some (Mat.mk' sx 0 0 sy (-Int.ediv (vx * sx) 65536) (-Int.ediv (vy * sy) 65536))
    | some (px, py) =>
      let s := if ar.slice then (if sx < sy then sy else sx) else (if sx ≤ sy then sx else sy)
      let tx := posOff px (w - Int.ediv (vw * s) 65536) - Int.ediv (vx * s) 65536
      let ty := posOff py (h - Int.ediv (vh * s) 65536) - Int.ediv (vy * s) 65536
      some (Mat.mk' s 0 0 s tx ty)

end Viewport
end LeanSvg
