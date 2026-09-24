import LeanSvg.Bytes
import LeanSvg.FontSet

/-!
# `font-family` matching (T106)

Resolves a `font-family` list to an embedded font the way Chromium does on
Linux, as far as the embedded fonts go.  Each name of the list, in order:

1. an embedded family by its exact name, case-insensitively (quoted or not);
2. an alias (`aliases`): the metric-compatible or look-alike family fontconfig
   substitutes (Times/Times New Roman → Tinos, Arial/Helvetica → Arimo,
   Courier → Cousine; Arimo, Tinos and Cousine are the fonts Liberation
   Sans/Serif/Mono 2.x are built from, with the same metrics), matplotlib's
   names (Bitstream Vera, `cmr10`/`cmmi10`/… Computer Modern, STIX);
3. an unquoted CSS generic (`generic`): Chromium's Linux defaults — `serif`,
   `cursive` and `fantasy` → Times New Roman (Tinos), `monospace` → DejaVu
   Sans Mono.  `sans-serif` and `system-ui` stay Noto Sans (T98b): the resvg
   test suite's references draw them in Noto Sans, where Chromium uses
   Liberation Sans (Arimo) and DejaVu Sans.

A name that matches nothing is skipped; a list that matches nothing is
`none` (Noto Sans with a warning, T98).  The suite-only families and the
digit rule stay in `Svg.resolveFontFamily`, which calls `lookup` per name.

`pick` then chooses the face of the family by style and weight, and
`fallbackOrder` is the fallback chain for characters the face lacks.
-/

namespace LeanSvg
namespace FamilyMatch

open Bytes

/-- `FontSet.entries` indices of the T106 fonts. -/
def dejaVuSans : Nat := 16
def dejaVuSansMono : Nat := 19
def dejaVuSerif : Nat := 20
def arimo : Nat := 21
def tinos : Nat := 23
def cousine : Nat := 26
def stixTwoMath : Nat := 27
def stixTwoText : Nat := 28
def cmuSerif : Nat := 30
def cmuSerifItalic : Nat := 31
def cmuSans : Nat := 32
def cmuTypewriter : Nat := 33
/-- The first T106 font: every font before it is the resvg suite's set. -/
def first : Nat := 16

/-- Lowercase alias → `FontSet` index.  An index that is not the first face
of its family (`cmuSerifItalic`) locks that face: `pick` keeps it. -/
def aliases : Array (String × Nat) := #[
  ("times", tinos), ("times new roman", tinos), ("liberation serif", tinos),
  ("arial", arimo), ("helvetica", arimo), ("liberation sans", arimo),
  ("courier", cousine), ("courier new", cousine), ("liberation mono", cousine),
  ("bitstream vera sans", dejaVuSans), ("dejavu sans display", dejaVuSans),
  ("bitstream vera serif", dejaVuSerif), ("bitstream vera sans mono", dejaVuSansMono),
  ("stix", stixTwoText), ("stixgeneral", stixTwoText),
  ("stixnonunicode", stixTwoMath), ("stixsizeonesym", stixTwoMath),
  ("stixsizetwosym", stixTwoMath), ("stixsizethreesym", stixTwoMath),
  ("stixsizefoursym", stixTwoMath), ("stixsizefivesym", stixTwoMath),
  ("msam10", stixTwoMath), ("msbm10", stixTwoMath),
  ("computer modern", cmuSerif), ("computer modern roman", cmuSerif),
  ("latin modern roman", cmuSerif), ("computer modern serif", cmuSerif),
  ("computer modern sans serif", cmuSans), ("latin modern sans", cmuSans),
  ("computer modern typewriter", cmuTypewriter), ("latin modern mono", cmuTypewriter),
  ("cmu typewriter", cmuTypewriter)]

/-- TeX's Computer Modern font names (`cmr10`, `cmmi7`, …): the prefix
decides the CMU family; math italic (`cmmi`) and text italic (`cmti`) lock
CMU Serif Italic.  `cmsy`/`cmex` (TeX-encoded symbols) get CMU Serif, which
draws their code points as Chromium does with its default serif font. -/
def texName (lname : ByteArray) : Option Nat :=
  let digitsFrom := fun (k : Nat) => lname.size > k &&
    (List.range (lname.size - k)).all (fun j => let c := at' lname (k + j); 48 ≤ c && c ≤ 57)
  let pre := fun (s : String) => startsWith lname 0 s && digitsFrom s.utf8ByteSize
  if pre "cmmi" || pre "cmti" || pre "cmmib" then some cmuSerifItalic
  else if pre "cmss" then some cmuSans
  else if pre "cmtt" then some cmuTypewriter
  else if pre "cmr" || pre "cmbx" || pre "cmsy" || pre "cmex" || pre "cmb" || pre "cmbsy" then
    some cmuSerif
  else none

/-- An unquoted CSS generic family → Chromium's Linux default (see above);
`some 0` is Noto Sans. -/
def generic (lname : ByteArray) : Option Nat :=
  if lname == "sans-serif".toUTF8 || lname == "system-ui".toUTF8 then some 0
  else if lname == "serif".toUTF8 || lname == "cursive".toUTF8 || lname == "fantasy".toUTF8 then
    some tinos
  else if lname == "monospace".toUTF8 then some dejaVuSansMono
  else none

/-- One name of a `font-family` list (quotes already stripped): an embedded
family (the first face of it), an alias, or, unquoted, a generic. -/
def lookup (name : ByteArray) (quoted : Bool) : Option Nat := Id.run do
  let l := lower name
  for i in [0:FontSet.entries.size] do
    match FontSet.entries[i]? with
    | some e => if l == (lower e.family.toUTF8) then return some i
    | none => pure ()
  for (a, k) in aliases do
    if l == a.toUTF8 then return some k
  match texName l with
  | some k => return some k
  | none => pure ()
  if quoted then return none
  return generic l

/-- The face of the family `head` names for `weight` and `italic`, as
fontdb's `find_best_match` (and Chromium) choose: style first (an italic
face when one exists, else upright; nothing is synthesised), then
`matchWeight` among that style's weights.  `head` itself when it is a locked
face (not its family's first entry). -/
def pick (head weight : Nat) (italic : Bool) (matchWeight : List Nat → Nat → Nat) : Nat :=
  let fam := ((FontSet.entries[head]?).map (·.family)).getD ""
  let prevFam := if head == 0 then "" else ((FontSet.entries[head - 1]?).map (·.family)).getD ""
  if prevFam == fam then head
  else
    let faces := (List.range FontSet.entries.size).filter (fun k =>
      ((FontSet.entries[k]?).map (·.family)).getD "" == fam)
    let styleOf := fun (k : Nat) => (FontSet.styles.getD k (400, false))
    let slanted := faces.filter (fun k => (styleOf k).2)
    let cands := if italic && !slanted.isEmpty then slanted else faces.filter (fun k => !(styleOf k).2)
    let w := matchWeight (cands.map (fun k => (styleOf k).1)) weight
    (cands.find? (fun k => (styleOf k).1 == w)).getD head

/-- The fallback order for a character the base font `base` lacks: the
suite's fonts keep `FontSet` order (usvg's); a T106 base tries DejaVu Sans
then STIX Two Math first (fontconfig's usual first fallbacks on Linux, and
the widest symbol coverage embedded). -/
def fallbackOrder (base count : Nat) : List Nat :=
  if base < first then List.range count
  else dejaVuSans :: stixTwoMath :: List.range count

end FamilyMatch
end LeanSvg

namespace LeanSvg
namespace FamilyMatch

-- The index constants and the style table must agree with `FontSet`.
example : FontSet.styles.size = FontSet.entries.size := by rfl
example : [dejaVuSans, dejaVuSansMono, dejaVuSerif, arimo, tinos, cousine, stixTwoMath,
    stixTwoText, cmuSerif, cmuSerifItalic, cmuSans, cmuTypewriter].map
    (fun k => (FontSet.entries[k]?).map (·.family)) =
    ["DejaVu Sans", "DejaVu Sans Mono", "DejaVu Serif", "Arimo", "Tinos", "Cousine",
     "STIX Two Math", "STIX Two Text", "CMU Serif", "CMU Serif", "CMU Sans Serif",
     "CMU Typewriter Text"].map some := by rfl

end FamilyMatch
end LeanSvg
