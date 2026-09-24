import LeanSvg.Bytes
import LeanSvg.Fixed
import LeanSvg.Font
import LeanSvg.Fonts.NotoSans

/-!
# CSS Values 4 length units (T92)

The units usvg 0.48.1 does not know, resolved the way Chromium resolves them
(`tests/render_chrome.py`, which embeds the file in an `<img>`; see
`DESIGN.md`, "CSS Values 4 units"):

* viewport units `vw vh vmin vmax vi vb` and their `sv*`/`lv*`/`dv*`
  variants (all the same thing for a static image): a percentage of the
  *output canvas* in px, taken as user units with no `viewBox` scaling --
  Chromium's `<img>` viewport is the image's own box on the page;
* font units `ch ic cap lh` against the element's own `font-size`, and
  `rch ric rcap rlh rex` against the root's, using the embedded Noto Sans
  regular face's metrics (the only family drawn; every weight and style uses
  the regular face's numbers).  `ex`/`rem` keep their usvg/T-R6 meaning in
  `Svg.parseTextLen`; `rex` follows Chromium's x-height, since no usvg
  reading of it exists.
-/

namespace LeanSvg
namespace Units

open Bytes

/-- What root- and viewport-relative units resolve against: the root
element's resolved `font-size` and the output canvas size (both in px as
`Fx`).  Set once for the root element and inherited unchanged. -/
structure RootLen where
  size : Fx := Fx.ofNat 12
  vpW : Fx := Fx.ofNat 100
  vpH : Fx := Fx.ofNat 100
deriving Inhabited, Repr

/-- Font-unit metrics of one face, in font units. -/
structure Metrics where
  upem : Nat
  /-- Advance of `0` (U+0030); `upem / 2` when unmapped (CSS's `0.5em`
  fallback, which is also what Chromium uses). -/
  zero : Nat
  /-- Advance of `水` (U+6C34); `upem` when unmapped (CSS's `1em`). -/
  ideo : Nat
  /-- `OS/2.sCapHeight`, or the ascent when absent (CSS's fallback). -/
  cap : Int
  xHeight : Int
  ascent : Int
  /-- Positive: font units below the baseline. -/
  descent : Int
  lineGap : Int
deriving Inhabited

/-- `Metrics` of a parsed face. -/
def metricsOf (f : Font) : Metrics :=
  let z := Font.advance f (Font.glyphId f 0x30)
  let w := Font.advance f (Font.glyphId f 0x6C34)
  let g0 := Font.glyphId f 0x30
  let gw := Font.glyphId f 0x6C34
  { upem := f.unitsPerEm,
    zero := if g0 == 0 || z == 0 then f.unitsPerEm / 2 else z,
    ideo := if gw == 0 || w == 0 then f.unitsPerEm else w,
    cap := if f.capHeight > 0 then f.capHeight else f.ascent,
    xHeight := f.xHeight, ascent := f.ascent, descent := -f.descent, lineGap := f.lineGap }

/-- The regular Noto Sans face's metrics, or the CSS fallbacks for a 1000-unit
em (`0.5em`, `1em`, cap = ascent = 0.8em, x-height `0.5em`) if it does not
parse -- it always does; `tests/UnitsTests.lean` asserts the real values. -/
def noto : Metrics :=
  match Font.parse (Fonts.NotoSans.bytes ()) with
  | some f => metricsOf f
  | none => ⟨1000, 500, 1000, 800, 500, 800, 200, 0⟩

/-- `n` font units at font size `fs`, as `Fx`. -/
def scaleUnits (m : Metrics) (n : Int) (fs : Fx) : Fx :=
  if m.upem == 0 then 0 else Int.ediv (n * fs) m.upem

/-- `line-height: normal` in px (as `Fx`): Chromium's `FontMetrics::
LineSpacing`, the ascent, descent and line gap each rounded to whole px
first, then summed. -/
def lineHeight (m : Metrics) (fs : Fx) : Fx :=
  let r := fun (n : Int) => Fx.round (scaleUnits m n fs) * 256
  r m.ascent + r m.descent + r m.lineGap

/-- One font-metric length: `v` of `unit` at font size `fs`. -/
def fontLen (m : Metrics) (v fs : Fx) (unit : String) : Fx :=
  let n : Int :=
    if unit == "ch" then m.zero
    else if unit == "ic" then m.ideo
    else if unit == "cap" then m.cap
    else m.xHeight
  if unit == "lh" then Fx.clamp (Int.ediv (v * lineHeight m fs) 256)
  else if m.upem == 0 then 0
  else Fx.clamp (Int.ediv (v * n * fs) (256 * m.upem))

/-- The viewport units, longest spelling first within a shared prefix;
`(name, axis)` with axis 0 = width, 1 = height, 2 = min, 3 = max. -/
def vpUnits : Array (String × Nat) :=
  #[("vmin", 2), ("vmax", 3), ("vw", 0), ("vh", 1), ("vi", 0), ("vb", 1)]

/-- A CSS Values 4 unit at byte offset `j` right after the number `v`:
`some (value, end)`, or `none` if no unit here is one of these. -/
def parseAt (bs : ByteArray) (j : Nat) (v fontSize : Fx) (ctx : RootLen) : Option (Fx × Nat) := Id.run do
  -- `sv*`/`lv*`/`dv*`: the small/large/dynamic viewport, one and the same
  -- canvas for a static image.
  let c := at' bs j
  let k := if (c == 115 || c == 108 || c == 100) && at' bs (j + 1) == 118 then j + 1 else j
  for (name, axis) in vpUnits do
    if startsWith bs k name then
      let ref := if axis == 0 then ctx.vpW else if axis == 1 then ctx.vpH
        else if axis == 2 then Fx.min ctx.vpW ctx.vpH else Fx.max ctx.vpW ctx.vpH
      return some (Fx.clamp (Int.ediv (v * ref) 25600), k + name.length)
  for name in #["rcap", "rch", "ric", "rlh", "rex"] do
    if startsWith bs j name then
      return some (fontLen noto v ctx.size (name.drop 1).toString, j + name.length)
  for name in #["cap", "ch", "ic", "lh"] do
    if startsWith bs j name then
      return some (fontLen noto v fontSize name, j + name.length)
  return none

end Units
end LeanSvg
