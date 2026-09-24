import LeanSvg.Bytes

/-!
# Render warnings (T98)

A render can succeed and still have drawn something differently from what
the document asked for.  Each such case adds one short message here; the
pure `renderWithWarnings` returns the list next to the PNG, and `Main`
writes it to `<output>.warnings.txt` through the effect layer
(`Prog.writeWarnings`).  The list is deduplicated and bounded, so a document
cannot grow it without limit.

Reported today: a `font-family` that does not resolve to an embedded font
(the text is drawn in Noto Sans instead), and a negative `font-size` (the
text is not drawn, T102).
-/

namespace LeanSvg
namespace Warn

/-- At most this many distinct messages are kept; later ones are dropped. -/
def maxWarnings : Nat := 32

/-- A message's quoted payload is cut to this many bytes. -/
def maxQuoted : Nat := 80

/-- Append `m` unless it is already present or the list is full. -/
def add (ws : Array String) (m : String) : Array String :=
  if ws.contains m || ws.size ≥ maxWarnings then ws else ws.push m

/-- Merge `more` into `ws`, keeping `add`'s dedup and bound. -/
def addAll (ws more : Array String) : Array String :=
  more.foldl add ws

/-- `bs` as printable ASCII, cut to `maxQuoted` bytes: anything outside
0x20–0x7E (and `"`) becomes `?`, so a message is always one plain line. -/
def quote (bs : ByteArray) : String :=
  let n := min bs.size maxQuoted
  let cs := (List.range n).map fun i =>
    let c := Bytes.at' bs i
    if c < 32 || c > 126 || c == 34 then '?' else Char.ofNat c.toNat
  String.ofList cs ++ (if bs.size > maxQuoted then "..." else "")

/-- The message for a `font-family` value that selects no embedded font. -/
def missingFont (family : ByteArray) : String :=
  s!"font-family \"{quote family}\" not available; used Noto Sans"

/-- A text node with a negative `font-size` (T102): it is not drawn. -/
def negativeFontSize : String :=
  "negative font-size; text not drawn"

/-- The warnings file's contents: one message per line. -/
def text (ws : Array String) : ByteArray :=
  (String.join (ws.toList.map (· ++ "\n"))).toUTF8

end Warn
end LeanSvg
