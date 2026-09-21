import MicroSvg.Xml
import MicroSvg.Css
import MicroSvg.Canvas

/-!
# SVG interpretation

Turns the XML event stream into a flat list of shapes with fully resolved
style and transform.  Supported: `svg g path rect circle ellipse line polygon
polyline`, solid paints, opacity, fill rule, stroke width/cap/join/miter,
`transform`, and the `style` attribute.  Everything else is skipped along with
its subtree.  There is no code that follows a reference of any kind (`url()`,
`href`, `use`, `image`, CSS), so the renderer cannot be made to look outside the
input bytes.
-/

namespace MicroSvg
namespace Svg

open Bytes

inductive Paint where
  | none
  | solid (c : Rgba)
deriving Repr, Inhabited

/-- `1.0` on the opacity grid: opacities are `Nat` numerators over 10^18.

resvg keeps an opacity as an `f32` in `[0, 1]` and only turns it into a `u8`
at the very end, with `Opacity::to_u8` = `round (x * 255)`.  Any coarser grid
of ours would have to round twice, and the two grids do not line up: on the
1/256 grid `0.7` becomes 179/256, and `round (179/256 * 255) = 178`, where
resvg says 179.

A decimal denominator fixes that.  The half-way points of the 255ths grid are
the odd multiples of 1/510, and the only ones in `[0, 1]` are `0.1`, `0.3`,
`0.5`, `0.7` and `0.9` (a tie needs `51 ∣ 2j+1`, and `51 * 11 / 510 > 1`).
They are one-digit decimals, so a power-of-ten grid represents every tie
*exactly* and the tie is then decided by our own rule rather than by rounding
noise.  10^18 also makes every decimal literal `parseDecimal` can return
(18 significant digits) exact in its own right. -/
def opacityOne : Nat := 1000000000000000000

structure Style where
  fill : Paint := .solid ⟨0, 0, 0, 255⟩
  fillOpacity : Nat := opacityOne
  evenOdd : Bool := false
  stroke : Paint := .none
  strokeOpacity : Nat := opacityOne
  strokeWidth : Fx := 256
  cap : Cap := .butt
  join : Join := .miter
  miterLimit : Fx := 1024
  /-- `stroke-dasharray`, raw: `Geom.dashPattern` normalises it.  Empty = solid. -/
  dashes : Array Fx := #[]
  dashOffset : Fx := 0
  opacity : Nat := opacityOne
  visible : Bool := true
  /-- The CSS `color` property: inherited, defaults to black, and is what
  `fill`/`stroke: currentColor` resolve to (`interpret`'s `applyEffective`
  applies `color` before any other property so the resolution sees the
  element's own value). -/
  color : Rgba := ⟨0, 0, 0, 255⟩
  /-- Whether `pctRefW`/`pctRefH` have been established yet.  False only for
  the literal `default : Style` that `interpret` passes as the parent of the
  root `<svg>` element itself; every other `Style` inherits `true` and the
  values below unchanged, since this renderer has no nested `<svg>`/`<symbol>`
  to rescope them. -/
  pctRefSet : Bool := false
  /-- The rect `transform-origin` percentages resolve against: usvg's
  per-element `state.view_box`, which is the same constant rect (the root's
  `viewBox`, or else its own resolved size) for every element in a document
  with no nested `<svg>`. Set once in `applyEffective`, from the root's own
  attrs. -/
  pctRefW : Fx := 0
  pctRefH : Fx := 0
  /-- `transform-origin`'s resolved offset, *not* inherited: every element
  gets its own, reset to `(0, 0)` (a no-op) unless this element itself has the
  property.  `applyProp`'s `"transform"` case wraps its matrix with
  `translate(originDx, originDy) · _ · translate(-originDx, -originDy)`. -/
  originDx : Fx := 0
  originDy : Fx := 0
  ctm : Mat := Mat.identity
deriving Repr, Inhabited

structure Shape where
  cmds : Array PathCmd
  style : Style
deriving Inhabited

structure RootInfo where
  /-- The raw parsed number and whether it was a percentage (`resolveRootSize`
  resolves it against the `viewBox` or the 100×100 default). -/
  width : Option (Fx × Bool) := none
  height : Option (Fx × Bool) := none
  viewBox : Option (Fx × Fx × Fx × Fx) := none
deriving Inhabited

structure Doc where
  root : RootInfo
  shapes : Array Shape
deriving Inhabited

/-! ## Colours -/

/-- The 148 CSS Color Level 4 named colours (extended colour keywords plus
`rebeccapurple`), lower-cased.  `transparent` is not in this list; it stays a
special case in `parsePaint` since it is not itself an RGB colour name. -/
def namedColors : List (String × Nat) :=
  [("aliceblue", 0xf0f8ff), ("antiquewhite", 0xfaebd7), ("aqua", 0x00ffff),
   ("aquamarine", 0x7fffd4), ("azure", 0xf0ffff), ("beige", 0xf5f5dc), ("bisque", 0xffe4c4),
   ("black", 0x000000), ("blanchedalmond", 0xffebcd), ("blue", 0x0000ff),
   ("blueviolet", 0x8a2be2), ("brown", 0xa52a2a), ("burlywood", 0xdeb887),
   ("cadetblue", 0x5f9ea0), ("chartreuse", 0x7fff00), ("chocolate", 0xd2691e),
   ("coral", 0xff7f50), ("cornflowerblue", 0x6495ed), ("cornsilk", 0xfff8dc),
   ("crimson", 0xdc143c), ("cyan", 0x00ffff), ("darkblue", 0x00008b), ("darkcyan", 0x008b8b),
   ("darkgoldenrod", 0xb8860b), ("darkgray", 0xa9a9a9), ("darkgreen", 0x006400),
   ("darkgrey", 0xa9a9a9), ("darkkhaki", 0xbdb76b), ("darkmagenta", 0x8b008b),
   ("darkolivegreen", 0x556b2f), ("darkorange", 0xff8c00), ("darkorchid", 0x9932cc),
   ("darkred", 0x8b0000), ("darksalmon", 0xe9967a), ("darkseagreen", 0x8fbc8f),
   ("darkslateblue", 0x483d8b), ("darkslategray", 0x2f4f4f), ("darkslategrey", 0x2f4f4f),
   ("darkturquoise", 0x00ced1), ("darkviolet", 0x9400d3), ("deeppink", 0xff1493),
   ("deepskyblue", 0x00bfff), ("dimgray", 0x696969), ("dimgrey", 0x696969),
   ("dodgerblue", 0x1e90ff), ("firebrick", 0xb22222), ("floralwhite", 0xfffaf0),
   ("forestgreen", 0x228b22), ("fuchsia", 0xff00ff), ("gainsboro", 0xdcdcdc),
   ("ghostwhite", 0xf8f8ff), ("gold", 0xffd700), ("goldenrod", 0xdaa520), ("gray", 0x808080),
   ("green", 0x008000), ("greenyellow", 0xadff2f), ("grey", 0x808080), ("honeydew", 0xf0fff0),
   ("hotpink", 0xff69b4), ("indianred", 0xcd5c5c), ("indigo", 0x4b0082), ("ivory", 0xfffff0),
   ("khaki", 0xf0e68c), ("lavender", 0xe6e6fa), ("lavenderblush", 0xfff0f5),
   ("lawngreen", 0x7cfc00), ("lemonchiffon", 0xfffacd), ("lightblue", 0xadd8e6),
   ("lightcoral", 0xf08080), ("lightcyan", 0xe0ffff), ("lightgoldenrodyellow", 0xfafad2),
   ("lightgray", 0xd3d3d3), ("lightgreen", 0x90ee90), ("lightgrey", 0xd3d3d3),
   ("lightpink", 0xffb6c1), ("lightsalmon", 0xffa07a), ("lightseagreen", 0x20b2aa),
   ("lightskyblue", 0x87cefa), ("lightslategray", 0x778899), ("lightslategrey", 0x778899),
   ("lightsteelblue", 0xb0c4de), ("lightyellow", 0xffffe0), ("lime", 0x00ff00),
   ("limegreen", 0x32cd32), ("linen", 0xfaf0e6), ("magenta", 0xff00ff), ("maroon", 0x800000),
   ("mediumaquamarine", 0x66cdaa), ("mediumblue", 0x0000cd), ("mediumorchid", 0xba55d3),
   ("mediumpurple", 0x9370db), ("mediumseagreen", 0x3cb371), ("mediumslateblue", 0x7b68ee),
   ("mediumspringgreen", 0x00fa9a), ("mediumturquoise", 0x48d1cc),
   ("mediumvioletred", 0xc71585), ("midnightblue", 0x191970), ("mintcream", 0xf5fffa),
   ("mistyrose", 0xffe4e1), ("moccasin", 0xffe4b5), ("navajowhite", 0xffdead),
   ("navy", 0x000080), ("oldlace", 0xfdf5e6), ("olive", 0x808000), ("olivedrab", 0x6b8e23),
   ("orange", 0xffa500), ("orangered", 0xff4500), ("orchid", 0xda70d6),
   ("palegoldenrod", 0xeee8aa), ("palegreen", 0x98fb98), ("paleturquoise", 0xafeeee),
   ("palevioletred", 0xdb7093), ("papayawhip", 0xffefd5), ("peachpuff", 0xffdab9),
   ("peru", 0xcd853f), ("pink", 0xffc0cb), ("plum", 0xdda0dd), ("powderblue", 0xb0e0e6),
   ("purple", 0x800080), ("rebeccapurple", 0x663399), ("red", 0xff0000),
   ("rosybrown", 0xbc8f8f), ("royalblue", 0x4169e1), ("saddlebrown", 0x8b4513),
   ("salmon", 0xfa8072), ("sandybrown", 0xf4a460), ("seagreen", 0x2e8b57),
   ("seashell", 0xfff5ee), ("sienna", 0xa0522d), ("silver", 0xc0c0c0), ("skyblue", 0x87ceeb),
   ("slateblue", 0x6a5acd), ("slategray", 0x708090), ("slategrey", 0x708090),
   ("snow", 0xfffafa), ("springgreen", 0x00ff7f), ("steelblue", 0x4682b4), ("tan", 0xd2b48c),
   ("teal", 0x008080), ("thistle", 0xd8bfd8), ("tomato", 0xff6347), ("turquoise", 0x40e0d0),
   ("violet", 0xee82ee), ("wheat", 0xf5deb3), ("white", 0xffffff), ("whitesmoke", 0xf5f5f5),
   ("yellow", 0xffff00), ("yellowgreen", 0x9acd32)]

def hexVal (c : UInt8) : Option Nat :=
  if isDigit c then some (c.toNat - 48)
  else if 97 ≤ c && c ≤ 102 then some (c.toNat - 87)
  else if 65 ≤ c && c ≤ 70 then some (c.toNat - 55)
  else none

def parseHexColor (bs : ByteArray) : Option Rgba := Id.run do
  let n := bs.size - 1
  if n != 3 && n != 4 && n != 6 && n != 8 then return none
  let mut ds : Array Nat := #[]
  for k in [1:bs.size] do
    match hexVal (at' bs k) with
    | some d => ds := ds.push d
    | none => return none
  let g := fun i => ds.getD i 0
  if n == 3 || n == 4 then
    let a := if n == 4 then g 3 * 17 else 255
    return some ⟨g 0 * 17, g 1 * 17, g 2 * 17, a⟩
  else
    let a := if n == 8 then g 6 * 16 + g 7 else 255
    return some ⟨g 0 * 16 + g 1, g 2 * 16 + g 3, g 4 * 16 + g 5, a⟩

/-- A colour component: integer 0..255 or percentage. -/
def compOf (bs : ByteArray) : Option Nat :=
  let t := trim bs
  match parseNumber t 0 with
  | none => none
  | some (v, j) =>
    if at' t j == 37 then some (Nat.min 255 ((Int.ediv (v * 255) 256).toNat / 100))
    else some (Nat.min 255 (Fx.round v).toNat)

/-- Alpha component of `rgba()`: a number in 0..1, or a percentage.

svgtypes stores it as a `u8` with `round (a * 255)`, and usvg then unpacks it
again as an opacity (`Color::split_alpha` → `a / 255`), so this has to land on
exactly the same 255ths grid as `parseOpacity`; going through the 1/256 grid
loses `0.7` and `0.35` the same way `fill-opacity` used to. -/
def alphaOf (bs : ByteArray) : Option Nat :=
  let t := trim bs
  match parseDecimal t 0 with
  | none => none
  | some (neg, mant, exp10, j) =>
    let exp10 := if at' t j == 37 then exp10 - 2 else exp10
    some (if neg then 0 else scaleDecimal mant exp10 255 255)

def parseRgbFunc (bs : ByteArray) (start : Nat) : Option Rgba :=
  let close := findByte bs start 41
  if close ≥ bs.size then none
  else
    let inner := bs.extract start close
    let parts := splitTrim inner 44
    let parts := if parts.size == 1 then splitTrim inner 32 else parts
    if parts.size == 3 || parts.size == 4 then
      match compOf (parts.getD 0 default), compOf (parts.getD 1 default), compOf (parts.getD 2 default) with
      | some r, some g, some b =>
        if parts.size == 4 then
          match alphaOf (parts.getD 3 default) with
          | some a => some ⟨r, g, b, a⟩
          | none => none
        else some ⟨r, g, b, 255⟩
      | _, _, _ => none
    else none

/-- The result of parsing a paint value: a resolved paint, or a marker for
`currentcolor` that the caller (`applyProp` on `fill`/`stroke`) resolves
against the element's own `color` at apply time. -/
inductive PaintSpec where
  | none
  | solid (c : Rgba)
  | currentColor
deriving Repr, Inhabited

/-- Parse a paint value.  Unsupported paint servers (`url(...)`) render as none. -/
def parsePaint (bs : ByteArray) : Option PaintSpec :=
  let t := lower (trim bs)
  if eqAscii t "none" then some .none
  else if eqAscii t "transparent" then some (.solid ⟨0, 0, 0, 0⟩)
  else if eqAscii t "currentcolor" then some .currentColor
  else if at' t 0 == 35 then (parseHexColor t).map .solid
  else if startsWith t 0 "rgba(" then (parseRgbFunc t 5).map .solid
  else if startsWith t 0 "rgb(" then (parseRgbFunc t 4).map .solid
  else if startsWith t 0 "url(" then some .none
  else
    let s := toStr t
    match namedColors.find? (fun (n, _) => n == s) with
    | some (_, v) => some (.solid ⟨(v >>> 16) &&& 255, (v >>> 8) &&& 255, v &&& 255, 255⟩)
    | none => none

/-- Opacity in `[0, opacityOne]`, i.e. usvg's `Opacity::new_clamped`.

The decimal is taken straight from `parseDecimal`, so no precision is lost on
the way in: a percentage is just an exponent shift, and the only rounding is
onto the 1/10^18 grid, which is exact for everything the lexer can produce. -/
def parseOpacity (bs : ByteArray) : Option Nat :=
  let t := trim bs
  match parseDecimal t 0 with
  | none => none
  | some (neg, mant, exp10, j) =>
    let exp10 := if at' t j == 37 then exp10 - 2 else exp10
    some (if neg then 0 else scaleDecimal mant exp10 opacityOne opacityOne)

/-- Multiply two opacities, staying on the 1/10^18 grid (halves up).

usvg folds an element's opacities together as one `f32` product
(`parser/style.rs`: `opacity: sub_opacity * fill_opacity`) and quantises only
afterwards; nesting groups is the one place we have to round early, and a
product of two short decimals is exact on this grid anyway. -/
def mulOpacity (a b : Nat) : Nat := (a * b * 2 / opacityOne + 1) / 2

/-- Collapse a paint alpha and the fill/stroke and group opacities into the
single `u8` that resvg hands to tiny-skia.

`crates/resvg/src/path.rs` builds the paint with
`set_color_rgba8(r, g, b, fill.opacity().to_u8())`, and usvg has already folded
the colour's own alpha into that opacity (`convert_paint` does
`*opacity = alpha` from `Color::split_alpha`, i.e. `a / 255`, and `resolve_fill`
returns `sub_opacity * fill_opacity`).  So the whole chain is one product,
quantised once with `round (x * 255)`:

  `a8 = round (alpha/255 * fillOp * groupOp * 255) = round (alpha * fillOp * groupOp)`

computed here in exact integer arithmetic, halves away from zero. -/
def opacityToU8 (alpha fillOp groupOp : Nat) : Nat :=
  Nat.min 255 ((alpha * fillOp * groupOp * 2 / (opacityOne * opacityOne) + 1) / 2)

/-! ## Transforms -/

def parseTransform (bs : ByteArray) : Mat := Id.run do
  let mut m := Mat.identity
  let mut i := 0
  for _ in [0:bs.size + 1] do
    i := skipWsComma bs i
    if i ≥ bs.size then break
    let ne := skipWhile bs i isAlpha
    if ne == i then break
    let name := lower (bs.extract i ne)
    let j := skipWs bs ne
    if at' bs j != 40 then break
    let close := findByte bs (j + 1) 41
    if close ≥ bs.size then break
    let argBytes := bs.extract (j + 1) close
    let args := parseNumberList argBytes
    -- `scale`'s factors and `matrix`'s `a b c d` are multiplicative
    -- coefficients, not positions: parsed on the coarser `Fx` (1/256) grid
    -- and then promoted, their quantization is amplified by whatever they
    -- multiply (T31).  `args16` lexes the same tokens directly onto the
    -- 16.16 grid the matrix stores them on, so they reach `Mat` exactly,
    -- with no `* 256` promotion.  `translate`'s offsets and `matrix`'s `e f`
    -- stay positions, read from `args` (`Fx`) as before.
    let args16 := parseNumberList16 argBytes
    let g := fun k => args.getD k 0
    let g16 := fun k => args16.getD k 0
    let t : Option Mat :=
      if eqAscii name "matrix" && args.size == 6 then
        some (Mat.mk' (g16 0) (g16 1) (g16 2) (g16 3) (g 4) (g 5))
      else if eqAscii name "translate" && (args.size == 1 || args.size == 2) then
        some (Mat.translate (g 0) (if args.size == 2 then g 1 else 0))
      else if eqAscii name "scale" && (args.size == 1 || args.size == 2) then
        some (Mat.scale16 (g16 0) (if args.size == 2 then g16 1 else g16 0))
      else if eqAscii name "rotate" && args.size == 1 then
        some (Mat.rotate (g 0))
      else if eqAscii name "rotate" && args.size == 3 then
        some (((Mat.translate (g 1) (g 2)).mul (Mat.rotate (g 0))).mul (Mat.translate (-(g 1)) (-(g 2))))
      else if eqAscii name "skewx" && args.size == 1 then some (Mat.skewX (g 0))
      else if eqAscii name "skewy" && args.size == 1 then some (Mat.skewY (g 0))
      else none
    match t with
    | some t => m := m.mul t
    | none => break
    i := close + 1
  return m

/-! ## Elliptical arcs

`A`/`a` path commands, converted to at most four cubic Béziers by the
endpoint-to-centre parameterisation of SVG 1.1 §F.6.5.  Everything is integer
fixed point: `Fx` coordinates in 1/256 px, direction vectors in 16.16, and
`Nat.sqrt` for every square root.  No `atan2` appears anywhere.  The sweep is
walked one quarter turn at a time and the decision to stop comes from the sign
of a cross product; the Bézier constant for a segment spanning θ ≤ 90° comes
from the half- and quarter-angle tangent identities

    tan (θ/2) = s / (1 + c),    tan (θ/4) = tan (θ/2) / (1 + √(1 + tan² (θ/2)))

evaluated on `c = a · b` and `s = |a × b|` for the segment's unit endpoints,
and `k = 4/3 · tan (θ/4)`.  At θ = 90° that evaluates to exactly `kappa16`
(36195), so a quarter drawn as an arc and the same quarter drawn by
`ellipsePath` produce identical control points, and a circle written as four
`A` commands rasterises to the same pixels as a `<circle>`.  That is also what
usvg does: it splits a sweep at quarter-turn boundaries with κ controls rather
than choosing a segment count from a flatness tolerance.
-/

/-- Round-to-nearest division by a positive `d`, halves away from zero.  Plain
`Int.ediv` floors, which would bias every negative coordinate down by up to one
unit and make an arc quarter disagree with the same quarter from `ellipsePath`. -/
def divRound (n d : Int) : Int :=
  if d ≤ 0 then 0
  else if n ≥ 0 then Int.ediv (2 * n + d) (2 * d)
  else -(Int.ediv (2 * (-n) + d) (2 * d))

/-- A direction in the ellipse's own parameter space, 16.16 per component. -/
abbrev ArcDir := Int × Int

/-- A quarter turn in the sweep direction (`pos` is `sweep-flag = 1`, i.e. the
direction of increasing parameter angle).  A coordinate swap and one sign flip. -/
def rot90 (pos : Bool) (v : ArcDir) : ArcDir := if pos then (-v.2, v.1) else (v.2, -v.1)

/-- Rescale a 16.16 vector back to unit length, so that accumulated rounding
cannot present the quarter-turn test with a vector that is not a unit vector. -/
def unit16 (v : ArcDir) : ArcDir :=
  let h := Fx.hypot v.1 v.2
  if h ≤ 0 then (65536, 0)
  else (divRound (v.1 * 65536) h, divRound (v.2 * 65536) h)

/-- Largest magnitude of a centre coordinate on the refined grid. -/
def arcHiMax : Int := Fx.maxVal * 65536

def clampHi (a : Int) : Int :=
  if a > arcHiMax then arcHiMax else if a < -arcHiMax then -arcHiMax else a

/-- One arc segment as a cubic in user space: from unit direction `a` to unit
direction `b`, no more than a quarter turn apart.  `cx`, `cy` are the centre on
the refined 16-extra-bit grid (`Fx · 2^16`), and `rx`, `ry` with the 16.16
`(sn, cs)` of φ map parameter space to user space as
`c + R(φ)·(rx·v.x, ry·v.y)`; keeping the centre unrounded means a control point
is quantised once, at the end, exactly like a control point read from a file.
`fin`, when given, replaces the mapped endpoint: the last segment of an arc
must land *exactly* on the command's endpoint, otherwise a closed path stops
being closed. -/
def arcSegment (cx cy : Int) (rx ry sn cs : Int) (pos : Bool) (a b : ArcDir)
    (fin : Option Pt) : PathCmd :=
  let dotv := divRound (a.1 * b.1 + a.2 * b.2) 65536
  let crs := a.1 * b.2 - a.2 * b.1
  let sinv := divRound (if crs < 0 then -crs else crs) 65536
  let den := 65536 + dotv
  let t2 := if den ≤ 0 then 65536 else divRound (sinv * 65536) den
  let q := 65536 + divRound (t2 * t2) 65536
  let r := Int.ofNat (Nat.sqrt (q * 65536).toNat)
  let t4 := divRound (t2 * 65536) (65536 + r)
  let k := divRound (4 * t4) 3
  let ap := rot90 pos a
  let bp := rot90 pos b
  let c1v : ArcDir := (a.1 + divRound (k * ap.1) 65536, a.2 + divRound (k * ap.2) 65536)
  let c2v : ArcDir := (b.1 - divRound (k * bp.1) 65536, b.2 - divRound (k * bp.2) 65536)
  let toUser := fun (v : ArcDir) =>
    (⟨Fx.clamp (divRound (cx * 65536 + cs * rx * v.1 - sn * ry * v.2) 4294967296),
      Fx.clamp (divRound (cy * 65536 + sn * rx * v.1 + cs * ry * v.2) 4294967296)⟩ : Pt)
  .cubicTo (toUser c1v) (toUser c2v) (fin.getD (toUser b))

/-- Expand one `A`/`a` command into path commands.  `p1` is the current point,
`p2` the command's (already resolved) endpoint, `phi` the x-axis rotation in
degrees, `fA`/`fS` the large-arc and sweep flags. -/
def arcPath (p1 : Pt) (rxIn ryIn phi : Fx) (fA fS : Bool) (p2 : Pt) : Array PathCmd := Id.run do
  -- §F.6.2 out-of-range handling: a zero-length arc is dropped entirely, a
  -- zero radius degenerates to a straight line, and the radii are taken as
  -- absolute values.
  if p1.x == p2.x && p1.y == p2.y then return #[]
  let rx0 := rxIn.natAbs
  let ry0 := ryIn.natAbs
  if rx0 == 0 || ry0 == 0 then return #[.lineTo p2]
  let (sn, cs) := sinCos16 (degToRad16 phi)
  -- §F.6.5.1: half of `p1 − p2`, rotated by −φ.  The halving is folded into
  -- the 16.16 divisor so no bit is lost before the rounding.
  let dx := p1.x - p2.x
  let dy := p1.y - p2.y
  let x1 : Fx := divRound (cs * dx + sn * dy) 131072
  let y1 : Fx := divRound (cs * dy - sn * dx) 131072
  let xa := x1.natAbs
  let ya := y1.natAbs
  -- §F.6.6: if the endpoints do not fit on the ellipse, scale both radii by
  -- `√Λ`, i.e. `rx := √(x1'²ry² + y1'²rx²)/ry` and `ry := √(…)/rx` with the
  -- *original* radii on the right.
  --
  -- Both square root and division round *down*, deliberately.  A corrected
  -- ellipse is one the endpoints lie on, so `num` below is zero and the centre
  -- is the midpoint of the chord.  Rounding a radius up by even one 1/256 px
  -- makes `num` positive instead, and the centre then moves by
  -- `√(r'² − (chord/2)²)` — a square root of a tiny number, so a quarter of a
  -- pixel of slop in the radius throws the centre a third of a unit off the
  -- chord.  Rounding down keeps `num` at zero (`Nat` subtraction truncates)
  -- and lands on exactly the degenerate half-turn the geometry asks for.
  let fit := xa * xa * (ry0 * ry0) + ya * ya * (rx0 * rx0)
  let cap := rx0 * rx0 * (ry0 * ry0)
  let (rxN, ryN) :=
    if fit ≤ cap then (rx0, ry0)
    else
      let s := Nat.sqrt fit
      (Nat.max 1 (s / ry0), Nat.max 1 (s / rx0))
  let rx2 := rxN * rxN
  let ry2 := ryN * ryN
  let den := rx2 * (ya * ya) + ry2 * (xa * xa)
  if den == 0 then return #[.lineTo p2]
  -- §F.6.5.2: the centre in the rotated frame.  `Nat` subtraction truncates at
  -- zero, which is exactly the clamp the spec asks for when rounding has made
  -- the numerator slightly negative.  `coef` is `√(num/den)` in 16.16.
  let coef := Int.ofNat (Nat.sqrt ((rx2 * ry2 - den) * 4294967296 / den))
  let rx : Int := Int.ofNat rxN
  let ry : Int := Int.ofNat ryN
  let sgn : Int := if fA != fS then 1 else -1
  -- The centre stays on the refined `Fx · 2^16` grid all the way to the
  -- control points, so the only quantisation to 1/256 px is the final one.
  let cxp := clampHi (divRound (sgn * coef * rx * y1) ry)
  let cyp := clampHi (divRound (-(sgn * coef * ry * x1)) rx)
  -- §F.6.5.3: back to user space, `c = R(φ)·(cx', cy') + (p1 + p2)/2`.
  let cx := clampHi (divRound (2 * (cs * cxp - sn * cyp) + 4294967296 * (p1.x + p2.x)) 131072)
  let cy := clampHi (divRound (2 * (sn * cxp + cs * cyp) + 4294967296 * (p1.y + p2.y)) 131072)
  -- §F.6.5.5, without the angles: the two endpoints as unit directions.
  let u1 := unit16 (divRound (x1 * 65536 - cxp) rx, divRound (y1 * 65536 - cyp) ry)
  let u2 := unit16 (divRound (-(x1 * 65536) - cxp) rx, divRound (-(y1 * 65536) - cyp) ry)
  -- Walk the sweep.  A sweep is under a full turn, so at most four segments.
  let mut out : Array PathCmd := #[]
  let mut u := u1
  let mut done := false
  for step in [0:4] do
    let crs := u.1 * u2.2 - u.2 * u2.1
    let dotv := u.1 * u2.1 + u.2 * u2.2
    -- `u2` is inside the next quarter turn when the cross product carries the
    -- sweep's sign (or is zero) and the angle is at most 90°.  The exception
    -- is a full turn: rounding has collapsed `u2` onto `u1` while `fA` says
    -- the sweep is more than half a turn, which needs all four quarters.
    let full := step == 0 && fA && u.1 == u2.1 && u.2 == u2.2
    if (if fS then crs ≥ 0 else crs ≤ 0) && dotv ≥ 0 && !full then
      out := out.push (arcSegment cx cy rx ry sn cs fS u u2 (some p2))
      done := true
      break
    let v := rot90 fS u
    out := out.push (arcSegment cx cy rx ry sn cs fS u v none)
    u := v
  if !done then out := out.push (.lineTo p2)
  return out

/-! ## Path data -/

/-- Parse `d` path data.  On a syntax error the commands parsed so far are
returned, as the SVG spec requires ("render up to the error"). -/
def parsePathData (bs : ByteArray) : Array PathCmd := Id.run do
  let mut out : Array PathCmd := #[]
  let mut i := 0
  let mut cmd : UInt8 := 0
  let mut cur : Pt := ⟨0, 0⟩
  let mut start : Pt := ⟨0, 0⟩
  let mut lastC : Pt := ⟨0, 0⟩
  let mut lastQ : Pt := ⟨0, 0⟩
  let mut prevWasC := false
  let mut prevWasQ := false
  let mut haveMove := false
  for _ in [0:bs.size + 1] do
    i := skipWsComma bs i
    if i ≥ bs.size then break
    let c := at' bs i
    if isAlpha c then
      cmd := c
      i := i + 1
      if c == 90 || c == 122 then
        out := out.push .close
        cur := start
        prevWasC := false
        prevWasQ := false
      continue
    if cmd == 0 then break
    let rel := 97 ≤ cmd && cmd ≤ 122
    let base := if rel then cur else ⟨0, 0⟩
    let up := toLower cmd
    -- read up to seven numbers as needed
    let need : Nat :=
      if up == 109 || up == 108 || up == 116 then 2
      else if up == 104 || up == 118 then 1
      else if up == 99 then 6
      else if up == 115 || up == 113 then 4
      else if up == 97 then 7
      else 0
    if need == 0 then break
    let mut nums : Array Fx := #[]
    let mut j := i
    let mut okNums := true
    for t in [0:need] do
      j := skipWsComma bs j
      if up == 97 && (t == 3 || t == 4) then
        -- The two arc flags are single characters, and the grammar lets them
        -- run together with no separator and with the endpoint that follows
        -- (`a1 1 0 0110 5`), so exactly one byte is consumed for each.  They
        -- ride along in `nums` as `0` or `1` on the `Fx` grid.
        let fc := at' bs j
        if fc == 48 then
          nums := nums.push 0
          j := j + 1
        else if fc == 49 then
          nums := nums.push Fx.one
          j := j + 1
        else
          okNums := false
          break
      else
        match parseNumber bs j with
        | some (v, k) =>
          nums := nums.push v
          j := k
        | none =>
          okNums := false
          break
    if !okNums then break
    if !haveMove && up != 109 then break
    i := j
    let g := fun k => nums.getD k 0
    let p := fun k => (⟨base.x + g k, base.y + g (k + 1)⟩ : Pt)
    let nextC := fun (_ : Unit) => prevWasC
    let nextQ := fun (_ : Unit) => prevWasQ
    prevWasC := false
    prevWasQ := false
    if up == 109 then
      let q := p 0
      out := out.push (.moveTo q)
      cur := q
      start := q
      haveMove := true
      cmd := if rel then 108 else 76
    else if up == 108 then
      let q := p 0
      out := out.push (.lineTo q)
      cur := q
    else if up == 104 then
      let q : Pt := ⟨base.x + g 0, cur.y⟩
      out := out.push (.lineTo q)
      cur := q
    else if up == 118 then
      let q : Pt := ⟨cur.x, base.y + g 0⟩
      out := out.push (.lineTo q)
      cur := q
    else if up == 99 then
      let c1 := p 0
      let c2 := p 2
      let q := p 4
      out := out.push (.cubicTo c1 c2 q)
      lastC := c2
      prevWasC := true
      cur := q
    else if up == 115 then
      let c1 := if nextC () then ⟨2 * cur.x - lastC.x, 2 * cur.y - lastC.y⟩ else cur
      let c2 := p 0
      let q := p 2
      out := out.push (.cubicTo c1 c2 q)
      lastC := c2
      prevWasC := true
      cur := q
    else if up == 113 || up == 116 then
      let qc : Pt :=
        if up == 113 then p 0
        else if nextQ () then ⟨2 * cur.x - lastQ.x, 2 * cur.y - lastQ.y⟩ else cur
      let q := if up == 113 then p 2 else p 0
      out := out.push (.quadTo qc q)
      lastQ := qc
      prevWasQ := true
      cur := q
    else if up == 97 then
      -- rx ry φ are never relative; only the endpoint is.
      let q := p 5
      out := out.append (arcPath cur (g 0) (g 1) (g 2) (g 3 != 0) (g 4 != 0) q)
      cur := q
  return out

/-! ## Basic shapes as paths -/

/-- κ = 4(√2 − 1)/3 ≈ 0.5523 in 16.16. -/
def kappa16 : Int := 36195

def ellipsePath (cx cy rx ry : Fx) : Array PathCmd :=
  let kx := Int.ediv (rx * kappa16) 65536
  let ky := Int.ediv (ry * kappa16) 65536
  #[.moveTo ⟨cx + rx, cy⟩,
    .cubicTo ⟨cx + rx, cy + ky⟩ ⟨cx + kx, cy + ry⟩ ⟨cx, cy + ry⟩,
    .cubicTo ⟨cx - kx, cy + ry⟩ ⟨cx - rx, cy + ky⟩ ⟨cx - rx, cy⟩,
    .cubicTo ⟨cx - rx, cy - ky⟩ ⟨cx - kx, cy - ry⟩ ⟨cx, cy - ry⟩,
    .cubicTo ⟨cx + kx, cy - ry⟩ ⟨cx + rx, cy - ky⟩ ⟨cx + rx, cy⟩,
    .close]

def rectPath (x y w h rx ry : Fx) : Array PathCmd :=
  if rx ≤ 0 || ry ≤ 0 then
    #[.moveTo ⟨x, y⟩, .lineTo ⟨x + w, y⟩, .lineTo ⟨x + w, y + h⟩, .lineTo ⟨x, y + h⟩, .close]
  else
    let rx := Fx.min rx (Int.ediv w 2)
    let ry := Fx.min ry (Int.ediv h 2)
    let kx := Int.ediv (rx * kappa16) 65536
    let ky := Int.ediv (ry * kappa16) 65536
    #[.moveTo ⟨x + rx, y⟩,
      .lineTo ⟨x + w - rx, y⟩,
      .cubicTo ⟨x + w - rx + kx, y⟩ ⟨x + w, y + ry - ky⟩ ⟨x + w, y + ry⟩,
      .lineTo ⟨x + w, y + h - ry⟩,
      .cubicTo ⟨x + w, y + h - ry + ky⟩ ⟨x + w - rx + kx, y + h⟩ ⟨x + w - rx, y + h⟩,
      .lineTo ⟨x + rx, y + h⟩,
      .cubicTo ⟨x + rx - kx, y + h⟩ ⟨x, y + h - ry + ky⟩ ⟨x, y + h - ry⟩,
      .lineTo ⟨x, y + ry⟩,
      .cubicTo ⟨x, y + ry - ky⟩ ⟨x + rx - kx, y⟩ ⟨x + rx, y⟩,
      .close]

def polyPath (pts : Array Fx) (closed : Bool) : Array PathCmd := Id.run do
  let n := pts.size / 2
  if n == 0 then return #[]
  let mut out : Array PathCmd := #[.moveTo ⟨pts.getD 0 0, pts.getD 1 0⟩]
  for k in [1:n] do
    out := out.push (.lineTo ⟨pts.getD (2 * k) 0, pts.getD (2 * k + 1) 0⟩)
  if closed then out := out.push .close
  return out

/-! ## Attributes -/

def attr (attrs : Array Xml.Attr) (name : String) : Option ByteArray :=
  (attrs.find? (fun a => a.name == name)).map (·.value)

def lengthAttr (attrs : Array Xml.Attr) (name : String) (dflt : Fx) : Fx :=
  match attr attrs name with
  | some v => (parseLengthAll v).getD dflt
  | none => dflt

/-- A length or percentage at a byte offset -- like `parseLength` (which this
wraps for every non-percent unit), except it also accepts `%`: there is no
reference to resolve it against here, so the raw `N` of `N%` is returned
alongside the flag, and the caller resolves it against whatever the SVG spec
names for that attribute (`resolvePct`). -/
def parseLenPctAt (bs : ByteArray) (i : Nat) : Option (Fx × Bool × Nat) :=
  match parseNumber bs i with
  | none => none
  | some (v, j) =>
    if at' bs j == 37 then some (v, true, j + 1)
    else match parseLength bs i with
      | some (v', j') => some (v', false, j')
      | none => none

/-- Parse a whole attribute value as a length or a percentage. -/
def parseLengthOrPercent (bs : ByteArray) : Option (Fx × Bool) :=
  let t := trim bs
  match parseLenPctAt t 0 with
  | some (v, pct, j) => if j == t.size then some (v, pct) else none
  | none => none

/-- Resolve a length-or-percentage pair (as `parseLengthOrPercent`/
`parseLenPctAt` return it) against a reference length: usvg's `convert_length`
for `Units::UserSpaceOnUse` (`crates/usvg/src/parser/units.rs`), i.e. the raw
number times the reference over 100, floor-divided like every other unit
conversion in `parseLength`; unchanged if it was not a percentage. -/
def resolvePct (l : Fx × Bool) (ref : Fx) : Fx :=
  if l.2 then Int.ediv (l.1 * ref) 25600 else l.1

/-- Resolve the root element's natural (pre-`--width`/`--zoom`) size in user
units from `width`, `height` and `viewBox`, matching usvg's `resolve_svg_size`
(`crates/usvg/src/parser/converter.rs`, `get_svg_size`): a percentage on
either axis resolves against the matching `viewBox` dimension when a
`viewBox` is present, or against the 100×100 default otherwise
(`Options::default_size`); when exactly one of `width`/`height` is given and a
`viewBox` is present, the other is derived from the `viewBox`'s aspect ratio,
exactly as before this task. `none` means the size cannot be determined (one
of `width`/`height` given, the other entirely absent, no `viewBox`) -- unlike
usvg we do not fall back to a bounding-box refit here (a separate, bigger
feature; see T24a's `Report` on `no-size.svg`), so the caller keeps failing
exactly as it did before percentages existed. -/
def resolveRootSize (root : RootInfo) : Option (Fx × Fx) :=
  match root.width, root.height, root.viewBox with
  | some w, some h, some (_, _, vw, vh) => some (resolvePct w vw, resolvePct h vh)
  | some w, some h, none => some (resolvePct w (Fx.ofNat 100), resolvePct h (Fx.ofNat 100))
  | some w, none, some (_, _, vw, vh) =>
    let wv := resolvePct w vw
    some (wv, if vw > 0 then Int.ediv (wv * vh) vw else wv)
  | none, some h, some (_, _, vw, vh) =>
    let hv := resolvePct h vh
    some (if vh > 0 then Int.ediv (hv * vw) vh else hv, hv)
  | none, none, some (_, _, vw, vh) => some (vw, vh)
  | none, none, none => some (Fx.ofNat 100, Fx.ofNat 100)
  | _, _, _ => none

def parseRoot (attrs : Array Xml.Attr) : RootInfo :=
  let vb := match attr attrs "viewBox" with
    | some v =>
      let ns := parseNumberList v
      if ns.size == 4 then some (ns.getD 0 0, ns.getD 1 0, ns.getD 2 0, ns.getD 3 0) else none
    | none => none
  { width := (attr attrs "width").bind parseLengthOrPercent,
    height := (attr attrs "height").bind parseLengthOrPercent,
    viewBox := vb }

/-! ## `transform-origin` -/

/-- One `transform-origin` token: a directional keyword or a length/percentage
(the raw number and whether it was a percentage, as `parseLenPctAt` returns
it).  Mirrors svgtypes' `Position`/`DirectionalPosition`
(`transform_origin.rs`, `directional_position.rs`): a length is usable on
either axis, while a keyword is usable only on the axis(es) its name implies
(`center` on both). -/
inductive OriginTok where
  | len (v : Fx) (isPct : Bool)
  | left
  | right
  | top
  | bottom
  | center
deriving Inhabited

def OriginTok.isHoriz : OriginTok → Bool
  | .top => false
  | .bottom => false
  | _ => true

def OriginTok.isVert : OriginTok → Bool
  | .left => false
  | .right => false
  | _ => true

/-- Usable as *either* axis without being a directional keyword: a length, or
`center` (svgtypes' `check`). -/
def OriginTok.isCheck : OriginTok → Bool
  | .len _ _ => true
  | .center => true
  | _ => false

/-- As a length/percentage (`From<Position> for Length` /
`From<DirectionalPosition> for Length` in svgtypes): `left`/`top` are `0%`,
`right`/`bottom` are `100%`, `center` is `50%`. -/
def OriginTok.asLen : OriginTok → Fx × Bool
  | .len v p => (v, p)
  | .left => (0, true)
  | .top => (0, true)
  | .right => (Fx.ofNat 100, true)
  | .bottom => (Fx.ofNat 100, true)
  | .center => (Fx.ofNat 50, true)

def parseOriginTok (bs : ByteArray) (i : Nat) : Option (OriginTok × Nat) :=
  if isAlpha (at' bs i) then
    let ne := skipWhile bs i isAlpha
    let w := bs.extract i ne
    if eqAscii w "left" then some (.left, ne)
    else if eqAscii w "right" then some (.right, ne)
    else if eqAscii w "top" then some (.top, ne)
    else if eqAscii w "bottom" then some (.bottom, ne)
    else if eqAscii w "center" then some (.center, ne)
    else none
  else
    match parseLenPctAt bs i with
    | some (v, pct, j) => some (.len v pct, j)
    | none => none

/-- Parse `transform-origin`: one or two lengths/percentages/keywords
(`left|center|right` for x, `top|center|bottom` for y; one value → the second
is `center`), resolved against `(refW, refH)`.  usvg always resolves
`transform-origin` percentages against the *current viewport*, on every
element, never the object bounding box: `resolve_transform`
(`crates/usvg/src/parser/converter.rs`) hard-codes `Units::UserSpaceOnUse`
regardless of element type, so `convert_length` always takes the `view_box`
branch.  Confirmed against the `structure/transform-origin` corpus -- e.g.
`left`/`right`/`right bottom`/`top left` land at the *viewport*'s edges, not
the rectangle's own bounding box, even though the two coincide for several of
those fixtures (a 200×200 viewBox and a rect centred in it).  A malformed
value, or a three-token one (a z-offset, which this 2-D renderer has no use
for and doesn't validate), yields `(0, 0)`: a no-op wherever it's applied,
identical to `transform-origin` being entirely absent. -/
def parseTransformOrigin (bs : ByteArray) (refW refH : Fx) : Fx × Fx :=
  let t := trim bs
  if t.size == 0 then (0, 0)
  else match parseOriginTok t 0 with
    | none => (0, 0)
    | some (p1, j1) =>
      let j1' := skipWsComma t j1
      if j1' ≥ t.size then
        if p1.isHoriz then (resolvePct p1.asLen refW, resolvePct OriginTok.center.asLen refH)
        else (resolvePct OriginTok.center.asLen refW, resolvePct p1.asLen refH)
      else match parseOriginTok t j1' with
        | none => (0, 0)
        | some (p2, j2) =>
          if skipWsComma t j2 < t.size then (0, 0)
          else if p1.isCheck && p2.isCheck then (resolvePct p1.asLen refW, resolvePct p2.asLen refH)
          else if p1.isHoriz && p2.isVert then (resolvePct p1.asLen refW, resolvePct p2.asLen refH)
          else if p1.isVert && p2.isHoriz then (resolvePct p2.asLen refW, resolvePct p1.asLen refH)
          else (0, 0)

/-- Resolve a parsed paint against the style's own `color` (for
`currentcolor`). -/
def resolvePaint (st : Style) : PaintSpec → Paint
  | .none => .none
  | .solid c => .solid c
  | .currentColor => .solid st.color

/-- Parse the `color` property.  It is an ordinary colour, never `none` or
`url(...)`; reusing `parsePaint` and rejecting anything but `.solid` gets that
for free (`none`/`url()` parse to `PaintSpec.none`, and `currentcolor` to
`PaintSpec.currentColor`, both filtered out here). -/
def parseColor (bs : ByteArray) : Option Rgba :=
  match parsePaint bs with
  | some (.solid c) => some c
  | _ => none

def applyProp (st : Style) (name : String) (v : ByteArray) : Style :=
  match name with
  | "color" => match parseColor v with | some c => { st with color := c } | none => st
  | "fill" => match parsePaint v with | some p => { st with fill := resolvePaint st p } | none => st
  | "stroke" => match parsePaint v with | some p => { st with stroke := resolvePaint st p } | none => st
  | "fill-opacity" => match parseOpacity v with | some o => { st with fillOpacity := o } | none => st
  | "stroke-opacity" => match parseOpacity v with | some o => { st with strokeOpacity := o } | none => st
  | "opacity" => match parseOpacity v with | some o => { st with opacity := mulOpacity st.opacity o } | none => st
  | "fill-rule" =>
    let t := trim v
    if eqAscii t "evenodd" then { st with evenOdd := true }
    else if eqAscii t "nonzero" then { st with evenOdd := false } else st
  | "stroke-width" => match parseLengthAll v with | some w => { st with strokeWidth := Fx.max 0 w } | none => st
  | "stroke-linecap" =>
    let t := trim v
    if eqAscii t "round" then { st with cap := .round }
    else if eqAscii t "square" then { st with cap := .square }
    else if eqAscii t "butt" then { st with cap := .butt } else st
  | "stroke-linejoin" =>
    let t := trim v
    if eqAscii t "round" then { st with join := .round }
    else if eqAscii t "bevel" then { st with join := .bevel }
    else if eqAscii t "miter" then { st with join := .miter } else st
  | "stroke-miterlimit" => match parseNumberAll v with | some m => { st with miterLimit := Fx.max 256 m } | none => st
  -- `none`, a percentage, an `em` and plain junk all mean "not dashed" rather
  -- than "inherit": usvg resolves the dash properties on the nearest ancestor
  -- that *has* the attribute and drops them when that one does not parse.
  | "stroke-dasharray" => { st with dashes := (parseAbsLengthList v).getD #[] }
  | "stroke-dashoffset" => { st with dashOffset := (parseAbsLengthAll v).getD 0 }
  | "transform" =>
    -- `translate(originDx, originDy) · transform · translate(-originDx, -originDy)`
    -- (`applyEffective` sets `originDx`/`originDy` from this element's own
    -- `transform-origin`, before any `transform` value is folded in, so this
    -- sees it regardless of attribute order or which cascade layer supplies
    -- either property); a no-op, exactly the plain `parseTransform v`,
    -- whenever there is none.
    let localM := parseTransform v
    let wrapped :=
      if st.originDx == 0 && st.originDy == 0 then localM
      else ((Mat.translate st.originDx st.originDy).mul localM).mul (Mat.translate (-st.originDx) (-st.originDy))
    { st with ctm := st.ctm.mul wrapped }
  | "visibility" =>
    let t := trim v
    if eqAscii t "hidden" || eqAscii t "collapse" then { st with visible := false }
    else if eqAscii t "visible" then { st with visible := true } else st
  | _ => st

/-- Parse a `style="a:b; c:d"` attribute into (name, value) pairs. -/
def parseStyleDecls (v : ByteArray) : Array (String × ByteArray) :=
  (splitTrim v 59).filterMap fun decl =>
    let k := findByte decl 0 58
    if k ≥ decl.size then none
    else some (toStr (lower (trim (decl.extract 0 k))), trim (decl.extract (k + 1) decl.size))

/-- `display="none"` (attribute or style) hides the element and its subtree. -/
def isDisplayNone (attrs : Array Xml.Attr) : Bool :=
  let a := match attr attrs "display" with
    | some v => eqAscii (trim v) "none"
    | none => false
  let s := match attr attrs "style" with
    | some v => (parseStyleDecls v).any fun (n, val) => n == "display" && eqAscii val "none"
    | none => false
  a || s

def shapeCmds (name : String) (attrs : Array Xml.Attr) : Option (Array PathCmd) :=
  match name with
  | "path" => (attr attrs "d").map parsePathData
  | "rect" =>
    let w := lengthAttr attrs "width" 0
    let h := lengthAttr attrs "height" 0
    if w ≤ 0 || h ≤ 0 then none
    else
      let rxo := attr attrs "rx" |>.bind parseLengthAll
      let ryo := attr attrs "ry" |>.bind parseLengthAll
      let (rx, ry) := match rxo, ryo with
        | some rx, some ry => (rx, ry)
        | some rx, none => (rx, rx)
        | none, some ry => (ry, ry)
        | none, none => (0, 0)
      some (rectPath (lengthAttr attrs "x" 0) (lengthAttr attrs "y" 0) w h rx ry)
  | "circle" =>
    let r := lengthAttr attrs "r" 0
    if r ≤ 0 then none else some (ellipsePath (lengthAttr attrs "cx" 0) (lengthAttr attrs "cy" 0) r r)
  | "ellipse" =>
    let rx := lengthAttr attrs "rx" 0
    let ry := lengthAttr attrs "ry" 0
    if rx ≤ 0 || ry ≤ 0 then none
    else some (ellipsePath (lengthAttr attrs "cx" 0) (lengthAttr attrs "cy" 0) rx ry)
  | "line" =>
    some #[.moveTo ⟨lengthAttr attrs "x1" 0, lengthAttr attrs "y1" 0⟩,
           .lineTo ⟨lengthAttr attrs "x2" 0, lengthAttr attrs "y2" 0⟩]
  | "polygon" => (attr attrs "points").map fun v => polyPath (parseNumberList v) true
  | "polyline" => (attr attrs "points").map fun v => polyPath (parseNumberList v) false
  | _ => none

def isShape (name : String) : Bool :=
  name == "path" || name == "rect" || name == "circle" || name == "ellipse" ||
  name == "line" || name == "polygon" || name == "polyline"

/-- SVG conditional processing on `attrs`: `systemLanguage`, `requiredFeatures`,
`requiredExtensions`.  Matches usvg's `is_condition_passed`
(`crates/usvg/src/parser/switch.rs`).

`requiredExtensions` present at all always fails the element, since we
support none.  `requiredFeatures` is a space-separated list (never trimmed,
never collapsed: an empty value or a stray double space produces an empty
token, same as Rust's `str::split(' ')`); every token must be one of usvg's
own hard-coded SVG 1.1 Feature Strings — what *usvg* claims to implement, not
what *we* happen to — or the element is skipped.  `systemLanguage` is a
comma-separated list; it passes if some entry, after trimming, equals `en` or
starts with `en-` (usvg's default `languages = ["en"]`); an empty value has
no matching entry, so it fails.  Either attribute absent passes that check. -/
def passesConditions (attrs : Array Xml.Attr) : Bool := Id.run do
  if (attr attrs "requiredExtensions").isSome then return false
  match attr attrs "requiredFeatures" with
  | some v =>
    let features : List String :=
      ["http://www.w3.org/TR/SVG11/feature#SVGDOM-static",
       "http://www.w3.org/TR/SVG11/feature#SVG-static",
       "http://www.w3.org/TR/SVG11/feature#CoreAttribute",
       "http://www.w3.org/TR/SVG11/feature#Structure",
       "http://www.w3.org/TR/SVG11/feature#BasicStructure",
       "http://www.w3.org/TR/SVG11/feature#ContainerAttribute",
       "http://www.w3.org/TR/SVG11/feature#ConditionalProcessing",
       "http://www.w3.org/TR/SVG11/feature#Image",
       "http://www.w3.org/TR/SVG11/feature#Style",
       "http://www.w3.org/TR/SVG11/feature#Shape",
       "http://www.w3.org/TR/SVG11/feature#Text",
       "http://www.w3.org/TR/SVG11/feature#BasicText",
       "http://www.w3.org/TR/SVG11/feature#PaintAttribute",
       "http://www.w3.org/TR/SVG11/feature#BasicPaintAttribute",
       "http://www.w3.org/TR/SVG11/feature#OpacityAttribute",
       "http://www.w3.org/TR/SVG11/feature#GraphicsAttribute",
       "http://www.w3.org/TR/SVG11/feature#BasicGraphicsAttribute",
       "http://www.w3.org/TR/SVG11/feature#Marker",
       "http://www.w3.org/TR/SVG11/feature#Gradient",
       "http://www.w3.org/TR/SVG11/feature#Pattern",
       "http://www.w3.org/TR/SVG11/feature#Clip",
       "http://www.w3.org/TR/SVG11/feature#BasicClip",
       "http://www.w3.org/TR/SVG11/feature#Mask",
       "http://www.w3.org/TR/SVG11/feature#Filter",
       "http://www.w3.org/TR/SVG11/feature#BasicFilter",
       "http://www.w3.org/TR/SVG11/feature#XlinkAttribute"]
    let mut i := 0
    for _ in [0:v.size + 1] do
      if i > v.size then break
      let j := findByte v i 32
      let tok := v.extract i j
      if !(features.any fun f => eqAscii tok f) then return false
      i := j + 1
  | none => pure ()
  match attr attrs "systemLanguage" with
  | some v =>
    let mut matched := false
    for e in splitTrim v 44 do
      if eqAscii e "en" || startsWith e 0 "en-" then
        matched := true
        break
    if !matched then return false
  | none => pure ()
  return true

/-- Walk the event stream with a style stack.

T29 adds CSS from `<style>` elements, collected in one pre-pass over `events`
(`combinedCss`) before the main walk.  A second stack, `elemStack`/
`childCounts`, is kept in exact lockstep with the existing `Style` stack
(pushed/popped in the same three places: root, `g`, shape; left alone while
`skip > 0`) to build each element's ancestor `Css.ElemInfo` chain and its
`:first-child` flag.  `applyEffective` is the four-layer cascade at all
three sites: presentation attributes, then non-important CSS, then the
`style=""` attribute, then `!important` CSS, with `color` and
`transform-origin` resolved first from whichever layer wins (and the root's
percentage reference seeded on the root push).

T27 adds a third stack, `switchSel`, kept the same size as `stack` and
pushed/popped together, tracking what a `<switch>` ancestor demands of its
direct children: `none` (unfiltered), `some none` (switch with no passing
child, all children skipped), or `some (some j)` (only the direct child
whose `.open_` event is at index `j` may render).  `g`, `switch`, shape
elements and the root `<svg>` all also check `passesConditions attrs`
alongside `isDisplayNone`.  A `<switch>` that passes its own checks runs a
bounded forward lookahead to find the first direct child whose tag usvg
recognises and whose own `passesConditions` holds; that index becomes its
`switchSel` target.  All three stacks move together at every push/pop site
so CSS resolution and switch selection never drift out of sync. -/
def interpret (events : Array Xml.Event) : Except String Doc := do
  let combinedCss : ByteArray := Id.run do
    let mut out := ByteArray.empty
    let mut curDepth : Nat := 0
    let mut styleDepth : Option Nat := none
    let mut styleOk := false
    for ev in events do
      match ev with
      | .open_ name attrs =>
        if styleDepth.isNone && name == "style" then
          styleOk := match attr attrs "type" with
            | none => true
            | some v => let t := trim v; t.size == 0 || eqAsciiCI t "text/css"
          styleDepth := some curDepth
        curDepth := curDepth + 1
      | .close =>
        curDepth := curDepth - 1
        if styleDepth == some curDepth then styleDepth := none
      | .text bytes =>
        if styleDepth.isSome && styleOk then out := (out ++ bytes).push 32
    return out
  let rules := Css.parseStylesheet combinedCss
  let applyEffective := fun (parent : Style) (attrs : Array Xml.Attr) (chain : Array Css.ElemInfo) =>
    -- `transform-origin` percentages resolve against the same rect for every
    -- element (this renderer has no nested `<svg>`/`<symbol>` to rescope it,
    -- so usvg's per-element `state.view_box` is one constant for the whole
    -- document): the root's `viewBox` if it has one, else the root's own
    -- resolved size (`resolveRootSize`).  Established once, from the root
    -- `<svg>`'s own attrs, and inherited unchanged from then on.
    -- `parent.pctRefSet` is false only for the literal `default : Style`
    -- passed as the parent of the root element itself -- the one call where
    -- `attrs` *are* the root's own `width`/`height`/`viewBox`.
    let parent :=
      if parent.pctRefSet then parent
      else
        let r := parseRoot attrs
        let (rw, rh) := match r.viewBox with
          | some (_, _, vw, vh) => (vw, vh)
          | none => (resolveRootSize r).getD (Fx.ofNat 100, Fx.ofNat 100)
        { parent with pctRefSet := true, pctRefW := rw, pctRefH := rh }
    let styleDecls := match attr attrs "style" with
      | some v => parseStyleDecls v
      | none => #[]
    let (normalCss, importantCss) := Css.matchingDeclsSplit rules chain
    let lastNamed := fun (decls : Array (String × ByteArray)) (n : String) =>
      (decls.filter (fun d => d.1 == n)).back?.map (·.2)
    -- The winning value of a single-valued property across the four layers,
    -- highest precedence first: `!important` CSS, `style=""`, normal CSS,
    -- presentation attribute.  Used for the two properties that must be
    -- resolved *before* the generic folds run, regardless of markup order:
    -- `color` (so `fill`/`stroke: currentcolor` on the same element sees the
    -- element's own final `color`) and `transform-origin` (so `applyProp`'s
    -- `"transform"` case sees `originDx`/`originDy`, whichever layer the
    -- `transform` itself comes from).  usvg lists both `transform` and
    -- `transform-origin` as presentation attributes (`svgtree/mod.rs`,
    -- `is_presentation`), so CSS sets them exactly like any other property.
    let winning := fun (n : String) =>
      match lastNamed importantCss n with
      | some v => some v
      | none =>
        match styleDecls.findSome? (fun (m, val) => if m == n then some val else none) with
        | some v => some v
        | none =>
          match lastNamed normalCss n with
          | some v => some v
          | none => attr attrs n
    let base := match winning "color" with
      | some v => applyProp parent "color" v
      | none => parent
    -- `transform-origin` is *not* inherited (unlike `color`): every element
    -- gets its own, freshly reset to "no adjustment" here rather than carrying
    -- the parent's, so an ancestor's `transform-origin` never leaks onto a
    -- descendant that has no `transform-origin` of its own.
    let (odx, ody) := match winning "transform-origin" with
      | some v => parseTransformOrigin v base.pctRefW base.pctRefH
      | none => (0, 0)
    let base := { base with originDx := odx, originDy := ody }
    let early (n : String) := n == "color" || n == "transform-origin"
    let skipName (n : String) := n == "style" || early n
    let afterAttrs := attrs.foldl (fun st a => if skipName a.name then st else applyProp st a.name a.value) base
    let afterNormalCss := normalCss.foldl (fun st (n, v) => if early n then st else applyProp st n v) afterAttrs
    let afterStyle := styleDecls.foldl (fun st (n, val) => if early n then st else applyProp st n val) afterNormalCss
    importantCss.foldl (fun st (n, v) => if early n then st else applyProp st n v) afterStyle
  let mut stack : Array Style := #[]
  let mut elemStack : Array Css.ElemInfo := #[]
  let mut childCounts : Array Nat := #[]
  let mut switchSel : Array (Option (Option Nat)) := #[]
  let mut skip : Nat := 0
  let mut shapes : Array Shape := #[]
  let mut root : Option RootInfo := none
  for idx in [0:events.size] do
    match events.getD idx default with
    | .text _ => pure ()
    | .close =>
      if skip > 0 then skip := skip - 1
      else
        stack := stack.pop
        elemStack := elemStack.pop
        childCounts := childCounts.pop
        switchSel := switchSel.pop
    | .open_ name attrs =>
      if skip > 0 then
        skip := skip + 1
      else
        let isFirst := childCounts.back?.getD 0 == 0
        childCounts := match childCounts.back? with
          | some c => childCounts.pop.push (c + 1)
          | none => childCounts
        let elemInfo := Css.buildElemInfo name (attrs.map (fun a => (a.name, toStr a.value))) isFirst
        let chain := elemStack.push elemInfo
        let parent := stack.back?.getD default
        match root with
        | none =>
          if name != "svg" then throw s!"root element must be <svg>, found <{name}>"
          root := some (parseRoot attrs)
          if isDisplayNone attrs || !passesConditions attrs then
            skip := 1
          else
            stack := stack.push (applyEffective default attrs chain)
            elemStack := chain
            childCounts := childCounts.push 0
            switchSel := switchSel.push none
        | some _ =>
          let allowed := match switchSel.back?.getD none with
            | none => true
            | some none => false
            | some (some target) => idx == target
          if !allowed then skip := 1
          else if name == "g" then
            if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              stack := stack.push (applyEffective parent attrs chain)
              elemStack := chain
              childCounts := childCounts.push 0
              switchSel := switchSel.push none
          else if name == "switch" then
            if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              -- First direct child (depth 0 relative to this `switch`) whose
              -- own conditional-processing attributes pass; `none` if the
              -- switch closes with no such child.  Tag support and
              -- `display:none` are deliberately not considered here, only
              -- checked once we reach that child below (matching usvg: the
              -- switch commits to this child regardless).
              --
              -- usvg's `svgtree` drops any element with an unrecognised tag
              -- name (and `<style>`, special-cased) while building its tree,
              -- before `switch`'s own child search ever runs, so such a
              -- child is not a candidate at all here either (`non-SVG-
              -- child.svg`: `switch` skips straight past `<random/>` to the
              -- next real child) — every other SVG 1.1 element name usvg
              -- knows still is, whether or not *we* render it.
              let svgTagNames : List String :=
                ["a", "circle", "clipPath", "defs", "ellipse", "feBlend", "feColorMatrix",
                 "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting",
                 "feDisplacementMap", "feDistantLight", "feDropShadow", "feFlood", "feFuncA",
                 "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur", "feImage", "feMerge",
                 "feMergeNode", "feMorphology", "feOffset", "fePointLight", "feSpecularLighting",
                 "feSpotLight", "feTile", "feTurbulence", "filter", "g", "image", "line",
                 "linearGradient", "marker", "mask", "path", "pattern", "polygon", "polyline",
                 "radialGradient", "rect", "stop", "svg", "switch", "symbol", "text", "textPath",
                 "tref", "tspan", "use"]
              let target : Option Nat := Id.run do
                let mut depth : Nat := 0
                for j in [idx + 1 : events.size] do
                  match events.getD j default with
                  | .close =>
                    if depth == 0 then return none else depth := depth - 1
                  | .open_ cname cattrs =>
                    if depth == 0 && svgTagNames.contains cname && passesConditions cattrs then
                      return some j
                    else depth := depth + 1
                  | .text _ => pure ()
                return none
              stack := stack.push (applyEffective parent attrs chain)
              elemStack := chain
              childCounts := childCounts.push 0
              switchSel := switchSel.push (some target)
          else if isShape name then
            if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              let st := applyEffective parent attrs chain
              match shapeCmds name attrs with
              | some cmds => if st.visible && cmds.size > 0 then shapes := shapes.push ⟨cmds, st⟩
              | none => pure ()
              stack := stack.push st
              elemStack := chain
              childCounts := childCounts.push 0
              switchSel := switchSel.push none
          else
            skip := 1
  match root with
  | none => throw "no <svg> root element"
  | some r => return ⟨r, shapes⟩

end Svg
end MicroSvg
