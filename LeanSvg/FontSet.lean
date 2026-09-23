import LeanSvg.Font
import LeanSvg.Fonts.NotoSans
import LeanSvg.Fonts.NotoSansBold
import LeanSvg.Fonts.NotoSansItalic
import LeanSvg.Fonts.Mplus1p
import LeanSvg.Fonts.NotoSansSC
import LeanSvg.Fonts.NotoSansKR
import LeanSvg.Fonts.NotoSansThai
import LeanSvg.Fonts.NotoSansArmenian
import LeanSvg.Fonts.NotoSansGeorgian
import LeanSvg.Fonts.NotoSansEthiopic
import LeanSvg.Fonts.Amiri
import LeanSvg.Fonts.NotoSansHebrew
import LeanSvg.Fonts.NotoSansDevanagari

/-!
# The embedded font set (T91)

Every font the renderer can draw with, in one fixed order.  The order is the
font-fallback order: usvg's `default_fallback_selector` walks `fontdb.faces()`
and takes the first face (not yet tried) that maps the missing character, and
this array plays the role of that face list.  Indices 0–2 are the Noto Sans
regular/bold/italic faces `Text.pickFace` chooses among; the rest are
single-face families, chosen for script reach (`LeanSvg/Fonts/README.md`).

"Mplus 1p" comes before "Noto Sans SC" so Japanese text falls back to the
same face the resvg test suite's font directory supplies, and a Chinese chunk
that Mplus 1p only partly covers still ends up wholly in Noto Sans SC (usvg's
"a fallback font that covers the whole chunk replaces every glyph" rule,
`Text.assignFonts`).

usvg skips a fallback face only when its style, weight *and* stretch all
differ from the base face's.  Every face here has normal stretch and the base
face always does too (`font-stretch` selects nothing), so no face is ever
skipped on that ground.
-/

namespace LeanSvg
namespace FontSet

/-- One embedded font: the `font-family` name that selects it (the three Noto
Sans faces share one), the font (`Font.parseEmbedded`: parsed on first use,
glyphs decoded as they are drawn, T94), and its packed cmap coverage. -/
structure Entry where
  family : String
  font : Unit → Option Font
  coverage : String

def entries : Array Entry := #[
  ⟨"Noto Sans", Fonts.NotoSans.font, Fonts.NotoSans.coverage⟩,
  ⟨"Noto Sans", Fonts.NotoSansBold.font, Fonts.NotoSansBold.coverage⟩,
  ⟨"Noto Sans", Fonts.NotoSansItalic.font, Fonts.NotoSansItalic.coverage⟩,
  ⟨"Mplus 1p", Fonts.Mplus1p.font, Fonts.Mplus1p.coverage⟩,
  ⟨"Noto Sans SC", Fonts.NotoSansSC.font, Fonts.NotoSansSC.coverage⟩,
  ⟨"Noto Sans KR", Fonts.NotoSansKR.font, Fonts.NotoSansKR.coverage⟩,
  ⟨"Noto Sans Thai", Fonts.NotoSansThai.font, Fonts.NotoSansThai.coverage⟩,
  ⟨"Noto Sans Armenian", Fonts.NotoSansArmenian.font, Fonts.NotoSansArmenian.coverage⟩,
  ⟨"Noto Sans Georgian", Fonts.NotoSansGeorgian.font, Fonts.NotoSansGeorgian.coverage⟩,
  ⟨"Noto Sans Ethiopic", Fonts.NotoSansEthiopic.font, Fonts.NotoSansEthiopic.coverage⟩,
  -- T93: the shaped scripts (GSUB/GPOS kept; `LeanSvg/Shape.lean`)
  ⟨"Amiri", Fonts.Amiri.font, Fonts.Amiri.coverage⟩,
  ⟨"Noto Sans Hebrew", Fonts.NotoSansHebrew.font, Fonts.NotoSansHebrew.coverage⟩,
  ⟨"Noto Sans Devanagari", Fonts.NotoSansDevanagari.font, Fonts.NotoSansDevanagari.coverage⟩
]

/-- The number of embedded fonts. -/
def count : Nat := entries.size

/-- The index of the first font whose family is exactly `name` (0 for "Noto
Sans", whose bold/italic faces `Text` picks by weight/style). -/
def familyIndex (name : ByteArray) : Option Nat := Id.run do
  for i in [0:entries.size] do
    match entries[i]? with
    | some e => if name == e.family.toUTF8 then return some i
    | none => pure ()
  return none

/-- The embedded font whose `LeanSvg.Fonts` module name is `name`, exactly as
the renderer loads it (for `fontdump --embedded`). -/
def byModule (name : String) : Option Font :=
  let names := #["NotoSans", "NotoSansBold", "NotoSansItalic", "Mplus1p", "NotoSansSC",
    "NotoSansKR", "NotoSansThai", "NotoSansArmenian", "NotoSansGeorgian", "NotoSansEthiopic",
    "Amiri", "NotoSansHebrew", "NotoSansDevanagari"]
  match names.findIdx? (· == name) with
  | some i => (entries[i]?).bind (fun e => e.font ())
  | none => none

end FontSet
end LeanSvg
