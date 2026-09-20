import MicroSvg.Xml
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
  opacity : Nat := opacityOne
  visible : Bool := true
  /-- The CSS `color` property: inherited, defaults to black, and is what
  `fill`/`stroke: currentColor` resolve to (`applyAttrs` applies `color`
  before any other property so the resolution sees the element's own
  value). -/
  color : Rgba := ⟨0, 0, 0, 255⟩
  ctm : Mat := Mat.identity
deriving Repr, Inhabited

structure Shape where
  cmds : Array PathCmd
  style : Style
deriving Inhabited

structure RootInfo where
  width : Option Fx := none
  height : Option Fx := none
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
    let args := parseNumberList (bs.extract (j + 1) close)
    let g := fun k => args.getD k 0
    let t : Option Mat :=
      if eqAscii name "matrix" && args.size == 6 then
        some (Mat.mk' (g 0 * 256) (g 1 * 256) (g 2 * 256) (g 3 * 256) (g 4) (g 5))
      else if eqAscii name "translate" && (args.size == 1 || args.size == 2) then
        some (Mat.translate (g 0) (if args.size == 2 then g 1 else 0))
      else if eqAscii name "scale" && (args.size == 1 || args.size == 2) then
        some (Mat.scale (g 0) (if args.size == 2 then g 1 else g 0))
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
    -- read up to six numbers as needed
    let need : Nat :=
      if up == 109 || up == 108 || up == 116 then 2
      else if up == 104 || up == 118 then 1
      else if up == 99 then 6
      else if up == 115 || up == 113 then 4
      else 0
    if need == 0 then break
    let mut nums : Array Fx := #[]
    let mut j := i
    let mut okNums := true
    for _ in [0:need] do
      j := skipWsComma bs j
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
      -- exact degree elevation: c1 = cur + 2/3 (qc − cur), c2 = q + 2/3 (qc − q)
      let c1 : Pt := ⟨cur.x + Int.ediv (2 * (qc.x - cur.x)) 3, cur.y + Int.ediv (2 * (qc.y - cur.y)) 3⟩
      let c2 : Pt := ⟨q.x + Int.ediv (2 * (qc.x - q.x)) 3, q.y + Int.ediv (2 * (qc.y - q.y)) 3⟩
      out := out.push (.cubicTo c1 c2 q)
      lastQ := qc
      prevWasQ := true
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
  | "transform" => { st with ctm := st.ctm.mul (parseTransform v) }
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

/-- Presentation attributes first, then the `style` attribute (CSS wins);
`color` is resolved before anything else, from whichever of the two sources
would normally win, so `fill`/`stroke: currentcolor` on the same element
always sees the element's own final `color` and never a stale inherited one
(usvg: "resolves currentColor with the element's own color, inherited if
absent" — the SVG-wide rule that `color` applies before paints even if it is
written after `fill`/`stroke` in the markup). -/
def applyAttrs (parent : Style) (attrs : Array Xml.Attr) : Style :=
  let styleDecls := match attr attrs "style" with
    | some v => parseStyleDecls v
    | none => #[]
  let colorVal : Option ByteArray :=
    match styleDecls.findSome? (fun (n, val) => if n == "color" then some val else none) with
    | some v => some v
    | none => attr attrs "color"
  let base := match colorVal with
    | some v => applyProp parent "color" v
    | none => parent
  let skip (n : String) := n == "style" || n == "color"
  let st := attrs.foldl (fun st a => if skip a.name then st else applyProp st a.name a.value) base
  styleDecls.foldl (fun st (n, val) => if n == "color" then st else applyProp st n val) st

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

def parseRoot (attrs : Array Xml.Attr) : RootInfo :=
  let vb := match attr attrs "viewBox" with
    | some v =>
      let ns := parseNumberList v
      if ns.size == 4 then some (ns.getD 0 0, ns.getD 1 0, ns.getD 2 0, ns.getD 3 0) else none
    | none => none
  { width := (attr attrs "width").bind parseLengthAll,
    height := (attr attrs "height").bind parseLengthAll,
    viewBox := vb }

/-- Walk the event stream with a style stack. -/
def interpret (events : Array Xml.Event) : Except String Doc := do
  let mut stack : Array Style := #[]
  let mut skip : Nat := 0
  let mut shapes : Array Shape := #[]
  let mut root : Option RootInfo := none
  for ev in events do
    match ev with
    | .close =>
      if skip > 0 then skip := skip - 1 else stack := stack.pop
    | .open_ name attrs =>
      if skip > 0 then
        skip := skip + 1
      else
        let parent := stack.back?.getD default
        match root with
        | none =>
          if name != "svg" then throw s!"root element must be <svg>, found <{name}>"
          root := some (parseRoot attrs)
          stack := stack.push (applyAttrs default attrs)
        | some _ =>
          if name == "g" then
            if isDisplayNone attrs then skip := 1
            else stack := stack.push (applyAttrs parent attrs)
          else if isShape name then
            if isDisplayNone attrs then skip := 1
            else
              let st := applyAttrs parent attrs
              match shapeCmds name attrs with
              | some cmds => if st.visible && cmds.size > 0 then shapes := shapes.push ⟨cmds, st⟩
              | none => pure ()
              stack := stack.push st
          else
            skip := 1
  match root with
  | none => throw "no <svg> root element"
  | some r => return ⟨r, shapes⟩

end Svg
end MicroSvg
