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
import LeanSvg.Fonts.NotoSansThin
import LeanSvg.Fonts.NotoSansLight
import LeanSvg.Fonts.NotoSansBlack
import LeanSvg.Fonts.DejaVuSans
import LeanSvg.Fonts.DejaVuSansBold
import LeanSvg.Fonts.DejaVuSansOblique
import LeanSvg.Fonts.DejaVuSansMono
import LeanSvg.Fonts.DejaVuSerif
import LeanSvg.Fonts.Arimo
import LeanSvg.Fonts.ArimoBold
import LeanSvg.Fonts.Tinos
import LeanSvg.Fonts.TinosBold
import LeanSvg.Fonts.TinosItalic
import LeanSvg.Fonts.Cousine
import LeanSvg.Fonts.STIXTwoMath
import LeanSvg.Fonts.STIXTwoText
import LeanSvg.Fonts.STIXTwoTextItalic
import LeanSvg.Fonts.CMUSerif
import LeanSvg.Fonts.CMUSerifItalic
import LeanSvg.Fonts.CMUSansSerif
import LeanSvg.Fonts.CMUTypewriter
import LeanSvg.Fonts.NotoSansExtraCondensed

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
differ from the base face's.  Every face but Noto Sans ExtraCondensed (T118)
has normal stretch, and a condensed base face is upright weight 400, which
nearly every fallback face shares, so no face is skipped on that ground.

T97 appends Noto Sans Thin, Light and Black, the other weights `Text.pickFace`
chooses among.  They sit last so that the fallback order of every other font
is unchanged; they map exactly what Noto Sans Regular maps, so fallback never
reaches them.

T106 appends the families real-world charts name (DejaVu, the Liberation-
metric Arimo/Tinos/Cousine, STIX Two, Computer Modern Unicode), again last so
the resvg suite's fallback order is unchanged.  `FamilyMatch` resolves
`font-family` to them and gives them their own fallback chain.

T118 appends Noto Sans ExtraCondensed (typographic family "Noto Sans", width
class 2), the face `font-stretch` selects; it maps what Noto Sans Regular
maps, so fallback never reaches it.
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
  ⟨"Noto Sans Devanagari", Fonts.NotoSansDevanagari.font, Fonts.NotoSansDevanagari.coverage⟩,
  -- T97: the other Noto Sans weights
  ⟨"Noto Sans", Fonts.NotoSansThin.font, Fonts.NotoSansThin.coverage⟩,
  ⟨"Noto Sans", Fonts.NotoSansLight.font, Fonts.NotoSansLight.coverage⟩,
  ⟨"Noto Sans", Fonts.NotoSansBlack.font, Fonts.NotoSansBlack.coverage⟩,
  -- T106: the families real-world charts ask for (`FamilyMatch`)
  ⟨"DejaVu Sans", Fonts.DejaVuSans.font, Fonts.DejaVuSans.coverage⟩,
  ⟨"DejaVu Sans", Fonts.DejaVuSansBold.font, Fonts.DejaVuSansBold.coverage⟩,
  ⟨"DejaVu Sans", Fonts.DejaVuSansOblique.font, Fonts.DejaVuSansOblique.coverage⟩,
  ⟨"DejaVu Sans Mono", Fonts.DejaVuSansMono.font, Fonts.DejaVuSansMono.coverage⟩,
  ⟨"DejaVu Serif", Fonts.DejaVuSerif.font, Fonts.DejaVuSerif.coverage⟩,
  ⟨"Arimo", Fonts.Arimo.font, Fonts.Arimo.coverage⟩,
  ⟨"Arimo", Fonts.ArimoBold.font, Fonts.ArimoBold.coverage⟩,
  ⟨"Tinos", Fonts.Tinos.font, Fonts.Tinos.coverage⟩,
  ⟨"Tinos", Fonts.TinosBold.font, Fonts.TinosBold.coverage⟩,
  ⟨"Tinos", Fonts.TinosItalic.font, Fonts.TinosItalic.coverage⟩,
  ⟨"Cousine", Fonts.Cousine.font, Fonts.Cousine.coverage⟩,
  ⟨"STIX Two Math", Fonts.STIXTwoMath.font, Fonts.STIXTwoMath.coverage⟩,
  ⟨"STIX Two Text", Fonts.STIXTwoText.font, Fonts.STIXTwoText.coverage⟩,
  ⟨"STIX Two Text", Fonts.STIXTwoTextItalic.font, Fonts.STIXTwoTextItalic.coverage⟩,
  ⟨"CMU Serif", Fonts.CMUSerif.font, Fonts.CMUSerif.coverage⟩,
  ⟨"CMU Serif", Fonts.CMUSerifItalic.font, Fonts.CMUSerifItalic.coverage⟩,
  ⟨"CMU Sans Serif", Fonts.CMUSansSerif.font, Fonts.CMUSansSerif.coverage⟩,
  ⟨"CMU Typewriter Text", Fonts.CMUTypewriter.font, Fonts.CMUTypewriter.coverage⟩,
  -- T118: the face `font-stretch` selects
  ⟨"Noto Sans", Fonts.NotoSansExtraCondensed.font, Fonts.NotoSansExtraCondensed.coverage⟩
]

/-- Each entry's weight, slant (`true` = italic/oblique) and stretch (the
OS/2 width class: 1 ultra-condensed … 5 normal … 9 ultra-expanded, T118), for
`FamilyMatch.pick` among the faces of one family (T106). -/
def styles : Array (Nat × Bool × Nat) := #[
  (400, false, 5), (700, false, 5), (400, true, 5), (400, false, 5), (400, false, 5),
  (400, false, 5), (400, false, 5), (400, false, 5), (400, false, 5), (400, false, 5),
  (400, false, 5), (400, false, 5), (400, false, 5), (100, false, 5), (300, false, 5),
  (900, false, 5),
  (400, false, 5), (700, false, 5), (400, true, 5), (400, false, 5), (400, false, 5),
  (400, false, 5), (700, false, 5), (400, false, 5), (700, false, 5), (400, true, 5),
  (400, false, 5), (400, false, 5), (400, false, 5), (400, true, 5), (400, false, 5),
  (400, true, 5), (400, false, 5), (400, false, 5),
  (400, false, 2)]

/-- The `entries` indices of Noto Sans Thin, Light and Black (T97). -/
def notoSansThin : Nat := 13
def notoSansLight : Nat := 14
def notoSansBlack : Nat := 15

/-- The `entries` indices of the CJK fonts `Text.assignFonts` picks among for
a Han character by language tag (T101). -/
def mplus1p : Nat := 3
def notoSansSC : Nat := 4
def notoSansKR : Nat := 5

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
    "Amiri", "NotoSansHebrew", "NotoSansDevanagari", "NotoSansThin", "NotoSansLight", "NotoSansBlack",
    "DejaVuSans", "DejaVuSansBold", "DejaVuSansOblique", "DejaVuSansMono", "DejaVuSerif",
    "Arimo", "ArimoBold", "Tinos", "TinosBold", "TinosItalic", "Cousine", "STIXTwoMath", "STIXTwoText", "STIXTwoTextItalic", "CMUSerif", "CMUSerifItalic", "CMUSansSerif", "CMUTypewriter",
    "NotoSansExtraCondensed"]
  match names.findIdx? (· == name) with
  | some i => (entries[i]?).bind (fun e => e.font ())
  | none => none

end FontSet
end LeanSvg
