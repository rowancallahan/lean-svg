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
Sans faces share one), its bytes, and its packed cmap coverage. -/
structure Entry where
  family : String
  bytes : Unit → ByteArray
  coverage : String

def entries : Array Entry := #[
  ⟨"Noto Sans", Fonts.NotoSans.bytes, Fonts.NotoSans.coverage⟩,
  ⟨"Noto Sans", Fonts.NotoSansBold.bytes, Fonts.NotoSansBold.coverage⟩,
  ⟨"Noto Sans", Fonts.NotoSansItalic.bytes, Fonts.NotoSansItalic.coverage⟩,
  ⟨"Mplus 1p", Fonts.Mplus1p.bytes, Fonts.Mplus1p.coverage⟩,
  ⟨"Noto Sans SC", Fonts.NotoSansSC.bytes, Fonts.NotoSansSC.coverage⟩,
  ⟨"Noto Sans KR", Fonts.NotoSansKR.bytes, Fonts.NotoSansKR.coverage⟩,
  ⟨"Noto Sans Thai", Fonts.NotoSansThai.bytes, Fonts.NotoSansThai.coverage⟩,
  ⟨"Noto Sans Armenian", Fonts.NotoSansArmenian.bytes, Fonts.NotoSansArmenian.coverage⟩,
  ⟨"Noto Sans Georgian", Fonts.NotoSansGeorgian.bytes, Fonts.NotoSansGeorgian.coverage⟩,
  ⟨"Noto Sans Ethiopic", Fonts.NotoSansEthiopic.bytes, Fonts.NotoSansEthiopic.coverage⟩
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

/-- The embedded font whose `LeanSvg.Fonts` module name is `name` (for `fontdump
--embedded`). -/
def byModule (name : String) : Option ByteArray :=
  let names := #["NotoSans", "NotoSansBold", "NotoSansItalic", "Mplus1p", "NotoSansSC",
    "NotoSansKR", "NotoSansThai", "NotoSansArmenian", "NotoSansGeorgian", "NotoSansEthiopic"]
  match names.findIdx? (· == name) with
  | some i => (entries[i]?).map (fun e => e.bytes ())
  | none => none

end FontSet
end LeanSvg
