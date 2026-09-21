import MicroSvg.Font
import MicroSvg.Fonts.NotoSans
import MicroSvg.Fonts.NotoSansBold
import MicroSvg.Fonts.NotoSansItalic

/-!
# `fontdump`: a debug/oracle tool over `MicroSvg.Font`

Prints, as JSON, per character of `<text>`: the Unicode codepoint, the glyph
id (`Font.glyphId`), the advance width (`Font.advance`), the raw quadratic
contours (`Font.rawContours`: points with on/off-curve flags, in font
units), the number of `PathCmd`s the cubic outline (`Font.outline`) comes to
(exercising that code path without needing to print the whole thing), and
the kerning to the next character (`Font.kern`, `null` for the last one).

This is the **only** file in the project that performs `IO` besides
`MicroSvg.Prog.execIO` and `Main.lean`: it reads the font path given on the
command line (or uses one of the fonts embedded in `MicroSvg.Fonts.*`).
Everything downstream of that read — `Font.parse` and every accessor — is
the pure, total parser in `MicroSvg/Font.lean`. `fontdump` is its own
executable (see `lakefile.toml`); `microsvg` does not link it or the
embedded font data.
-/

open MicroSvg

def usage : String :=
  "usage: fontdump <font.ttf> <text>\n" ++
  "       fontdump --embedded <NotoSans|NotoSansBold|NotoSansItalic> <text>\n"

def embeddedBytes (name : String) : Option ByteArray :=
  if name == "NotoSans" then some MicroSvg.Fonts.NotoSans.bytes
  else if name == "NotoSansBold" then some MicroSvg.Fonts.NotoSansBold.bytes
  else if name == "NotoSansItalic" then some MicroSvg.Fonts.NotoSansItalic.bytes
  else none

/-! ## Minimal JSON writer (no library dependency) -/

def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (48 + n) else Char.ofNat (97 + n - 10)

def hex4 (n : Nat) : String :=
  String.ofList [hexDigit ((n / 4096) % 16), hexDigit ((n / 256) % 16),
                 hexDigit ((n / 16) % 16), hexDigit (n % 16)]

/-- Escape one character for a JSON string. Only `"`, `\`, and control
characters need it; every other Unicode scalar (in particular every
character `fontdump` is ever actually asked to print) is valid, unescaped
UTF-8 inside a JSON string. -/
def jsonEscapeChar (c : Char) : String :=
  if c == '"' then "\\\""
  else if c == '\\' then "\\\\"
  else if c.toNat < 0x20 then
    match c.toNat with
    | 8 => "\\b" | 9 => "\\t" | 10 => "\\n" | 12 => "\\f" | 13 => "\\r"
    | n => "\\u" ++ hex4 n
  else toString c

def jsonString (s : String) : String :=
  "\"" ++ (s.toList.map jsonEscapeChar).foldl (· ++ ·) "" ++ "\""

def jsonPoint (p : Int × Int × Bool) : String :=
  s!"[{p.1},{p.2.1},{if p.2.2 then "true" else "false"}]"

def jsonContour (c : Array (Int × Int × Bool)) : String :=
  "[" ++ String.intercalate "," (c.toList.map jsonPoint) ++ "]"

def jsonContours (cs : Array (Array (Int × Int × Bool))) : String :=
  "[" ++ String.intercalate "," (cs.toList.map jsonContour) ++ "]"

/-! ## Per-character dump -/

def charObj (f : Font) (c : Char) (next? : Option Char) : String :=
  let cp := c.toNat
  let gid := MicroSvg.Font.glyphId f cp
  let adv := MicroSvg.Font.advance f gid
  let contours := MicroSvg.Font.rawContours f gid
  let cubicCmdCount := (MicroSvg.Font.outline f gid).size
  let kernStr :=
    match next? with
    | some nc => toString (MicroSvg.Font.kern f gid (MicroSvg.Font.glyphId f nc.toNat))
    | none => "null"
  "{" ++
    "\"char\":" ++ jsonString (String.ofList [c]) ++ "," ++
    "\"codepoint\":" ++ toString cp ++ "," ++
    "\"glyphId\":" ++ toString gid ++ "," ++
    "\"advance\":" ++ toString adv ++ "," ++
    "\"contours\":" ++ jsonContours contours ++ "," ++
    "\"cubicCmdCount\":" ++ toString cubicCmdCount ++ "," ++
    "\"kernToNext\":" ++ kernStr ++
  "}"

def dumpChars (f : Font) (text : String) : String := Id.run do
  let chars := text.toList.toArray
  let n := chars.size
  let mut parts : Array String := #[]
  for i in [0:n] do
    let c := chars.getD i ' '
    let next? := if i + 1 < n then some (chars.getD (i + 1) ' ') else none
    parts := parts.push (charObj f c next?)
  return "[" ++ String.intercalate "," parts.toList ++ "]"

def runOn (bytes : ByteArray) (text : String) : IO UInt32 := do
  match MicroSvg.Font.parse bytes with
  | some f =>
    IO.println (dumpChars f text)
    return 0
  | none =>
    IO.eprintln "fontdump: could not parse font"
    return 1

def main (args : List String) : IO UInt32 := do
  match args with
  | ["--embedded", name, text] =>
    match embeddedBytes name with
    | some bytes => runOn bytes text
    | none =>
      IO.eprintln s!"fontdump: unknown embedded font {name}"
      return 2
  | [path, text] =>
    let bytes ← IO.FS.readBinFile path
    runOn bytes text
  | _ =>
    IO.eprintln usage
    return 2
