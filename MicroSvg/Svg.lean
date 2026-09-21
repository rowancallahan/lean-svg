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

def namedColors : List (String × Nat) :=
  [("black", 0x000000), ("white", 0xffffff), ("red", 0xff0000), ("green", 0x008000),
   ("blue", 0x0000ff), ("yellow", 0xffff00), ("cyan", 0x00ffff), ("aqua", 0x00ffff),
   ("magenta", 0xff00ff), ("fuchsia", 0xff00ff), ("gray", 0x808080), ("grey", 0x808080),
   ("silver", 0xc0c0c0), ("maroon", 0x800000), ("olive", 0x808000), ("lime", 0x00ff00),
   ("navy", 0x000080), ("teal", 0x008080), ("purple", 0x800080), ("orange", 0xffa500),
   ("pink", 0xffc0cb), ("brown", 0xa52a2a), ("gold", 0xffd700), ("darkgray", 0xa9a9a9),
   ("darkgrey", 0xa9a9a9), ("lightgray", 0xd3d3d3), ("lightgrey", 0xd3d3d3),
   ("darkgreen", 0x006400), ("darkblue", 0x00008b), ("darkred", 0x8b0000),
   ("orangered", 0xff4500), ("tomato", 0xff6347), ("coral", 0xff7f50), ("salmon", 0xfa8072),
   ("crimson", 0xdc143c), ("indigo", 0x4b0082), ("violet", 0xee82ee), ("khaki", 0xf0e68c),
   ("tan", 0xd2b48c), ("beige", 0xf5f5dc), ("ivory", 0xfffff0), ("skyblue", 0x87ceeb),
   ("steelblue", 0x4682b4), ("royalblue", 0x4169e1), ("dodgerblue", 0x1e90ff),
   ("deepskyblue", 0x00bfff), ("turquoise", 0x40e0d0), ("seagreen", 0x2e8b57),
   ("forestgreen", 0x228b22), ("limegreen", 0x32cd32), ("yellowgreen", 0x9acd32),
   ("chocolate", 0xd2691e), ("sienna", 0xa0522d), ("slategray", 0x708090),
   ("slategrey", 0x708090), ("dimgray", 0x696969), ("dimgrey", 0x696969),
   ("whitesmoke", 0xf5f5f5), ("lightblue", 0xadd8e6), ("lightgreen", 0x90ee90),
   ("darkorange", 0xff8c00), ("hotpink", 0xff69b4), ("deeppink", 0xff1493),
   ("lavender", 0xe6e6fa), ("plum", 0xdda0dd), ("orchid", 0xda70d6), ("peru", 0xcd853f),
   ("wheat", 0xf5deb3), ("linen", 0xfaf0e6), ("snow", 0xfffafa), ("mintcream", 0xf5fffa)]

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

/-- Parse a paint value.  Unsupported paint servers (`url(...)`) render as none. -/
def parsePaint (bs : ByteArray) : Option Paint :=
  let t := lower (trim bs)
  if eqAscii t "none" then some .none
  else if eqAscii t "transparent" then some (.solid ⟨0, 0, 0, 0⟩)
  else if eqAscii t "currentcolor" then some (.solid ⟨0, 0, 0, 255⟩)
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

def applyProp (st : Style) (name : String) (v : ByteArray) : Style :=
  match name with
  | "fill" => match parsePaint v with | some p => { st with fill := p } | none => st
  | "stroke" => match parsePaint v with | some p => { st with stroke := p } | none => st
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

/-- Presentation attributes first, then the `style` attribute (CSS wins). -/
def applyAttrs (parent : Style) (attrs : Array Xml.Attr) : Style :=
  let st := attrs.foldl (fun st a => if a.name == "style" then st else applyProp st a.name a.value) parent
  match attr attrs "style" with
  | some v => (parseStyleDecls v).foldl (fun st (n, val) => applyProp st n val) st
  | none => st

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

Each currently-open frame also carries, in `switchSel` (kept the same size as
`stack`, pushed and popped together), what a `<switch>` ancestor demands of
its direct children: `none` when the nearest open frame is not a `switch`
(children are unfiltered), `some none` when it is a `switch` with no passing
child (every child is skipped), and `some (some j)` when only the direct
child whose `.open_` event is at index `j` may render — every other direct
child, whether it would itself pass or not, is skipped along with its
subtree, matching usvg's `switch::convert`, which commits to the first
`is_condition_passed` child and never backtracks even if that child then
turns out to be unrenderable (`display:none`, or a tag we don't support). -/
def interpret (events : Array Xml.Event) : Except String Doc := do
  let mut stack : Array Style := #[]
  let mut switchSel : Array (Option (Option Nat)) := #[]
  let mut skip : Nat := 0
  let mut shapes : Array Shape := #[]
  let mut root : Option RootInfo := none
  for idx in [0:events.size] do
    match events.getD idx default with
    | .close =>
      if skip > 0 then skip := skip - 1
      else
        stack := stack.pop
        switchSel := switchSel.pop
    | .open_ name attrs =>
      if skip > 0 then
        skip := skip + 1
      else
        let parent := stack.back?.getD default
        match root with
        | none =>
          if name != "svg" then throw s!"root element must be <svg>, found <{name}>"
          root := some (parseRoot attrs)
          -- usvg checks `is_visible_element` (display, transform, conditional
          -- processing) on the root `<svg>` too (`converter::convert_doc`):
          -- if it fails, the whole document renders as an empty (but
          -- correctly sized) tree, not an error.
          if isDisplayNone attrs || !passesConditions attrs then
            skip := 1
          else
            stack := stack.push (applyAttrs default attrs)
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
              stack := stack.push (applyAttrs parent attrs)
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
                return none
              stack := stack.push (applyAttrs parent attrs)
              switchSel := switchSel.push (some target)
          else if isShape name then
            if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              let st := applyAttrs parent attrs
              match shapeCmds name attrs with
              | some cmds => if st.visible && cmds.size > 0 then shapes := shapes.push ⟨cmds, st⟩
              | none => pure ()
              stack := stack.push st
              switchSel := switchSel.push none
          else
            skip := 1
  match root with
  | none => throw "no <svg> root element"
  | some r => return ⟨r, shapes⟩

end Svg
end MicroSvg
