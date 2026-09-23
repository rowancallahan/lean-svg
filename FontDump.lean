import LeanSvg.Font
import LeanSvg.FontSet

/-!
# `fontdump`: a debug/oracle tool over `LeanSvg.Font`

Prints, as JSON, per character of `<text>`: the Unicode codepoint, the glyph
id (`Font.glyphId`), the advance width (`Font.advance`), the raw quadratic
contours (`Font.rawContours`: points with on/off-curve flags, in font
units), the number of `PathCmd`s the cubic outline (`Font.outline`) comes to
(exercising that code path without needing to print the whole thing), and
the kerning to the next character (`Font.kern`, `null` for the last one).

`--metrics` instead prints the font-level metrics T54 added
(`ascent`/`descent`/`xHeight`/`capHeight`/`subscriptOffset`/
`superscriptOffset`), for `tests/check_font.py`'s oracle to check against
fontTools' own decompiled `OS/2`/`hhea` tables.

This is the **only** file in the project that performs `IO` besides
`LeanSvg.Prog.execIO` and `Main.lean`: it reads the font path given on the
command line (or uses one of the fonts embedded in `LeanSvg.Fonts.*`).
Everything downstream of that read — `Font.parse` and every accessor — is
the pure, total parser in `LeanSvg/Font.lean`. `fontdump` is its own
executable (see `lakefile.toml`); `lean-svg` does not link it or the
embedded font data.
-/

open LeanSvg

def usage : String :=
  "usage: fontdump <font.ttf> <text>\n" ++
  "       fontdump --embedded <module in LeanSvg/Fonts> <text>\n" ++
  "       fontdump --metrics <font.ttf>\n" ++
  "       fontdump --metrics --embedded <module in LeanSvg/Fonts>\n"

def embeddedBytes (name : String) : Option ByteArray := LeanSvg.FontSet.byModule name

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
  let gid := LeanSvg.Font.glyphId f cp
  let adv := LeanSvg.Font.advance f gid
  let contours := LeanSvg.Font.rawContours f gid
  let cubicCmdCount := (LeanSvg.Font.outline f gid).size
  let kernStr :=
    match next? with
    | some nc => toString (LeanSvg.Font.kern f gid (LeanSvg.Font.glyphId f nc.toNat))
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
  match LeanSvg.Font.parse bytes with
  | some f =>
    IO.println (dumpChars f text)
    return 0
  | none =>
    IO.eprintln "fontdump: could not parse font"
    return 1

/-! ## Font-level metrics (T54) -/

def metricsObj (f : Font) : String :=
  "{" ++
    "\"unitsPerEm\":" ++ toString f.unitsPerEm ++ "," ++
    "\"ascent\":" ++ toString f.ascent ++ "," ++
    "\"descent\":" ++ toString f.descent ++ "," ++
    "\"xHeight\":" ++ toString f.xHeight ++ "," ++
    "\"capHeight\":" ++ toString f.capHeight ++ "," ++
    "\"subscriptOffset\":" ++ toString f.subscriptOffset ++ "," ++
    "\"superscriptOffset\":" ++ toString f.superscriptOffset ++
  "}"

def runMetricsOn (bytes : ByteArray) : IO UInt32 := do
  match LeanSvg.Font.parse bytes with
  | some f =>
    IO.println (metricsObj f)
    return 0
  | none =>
    IO.eprintln "fontdump: could not parse font"
    return 1

def main (args : List String) : IO UInt32 := do
  match args with
  | ["--metrics", "--embedded", name] =>
    match embeddedBytes name with
    | some bytes => runMetricsOn bytes
    | none =>
      IO.eprintln s!"fontdump: unknown embedded font {name}"
      return 2
  | ["--metrics", path] =>
    let bytes ← IO.FS.readBinFile path
    runMetricsOn bytes
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
