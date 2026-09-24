import LeanSvg.Bytes
import LeanSvg.Css
import LeanSvg.Font
import LeanSvg.Woff
import LeanSvg.Text

/-!
# Fonts embedded in the document: CSS `@font-face` with `data:` URLs (T105)

`scan css` collects the document's `@font-face` rules (from every `<style>`
element, `Svg.interpretWith`'s `combinedCss`) into `Face`s: family name,
`font-weight`, `font-style`, and the font itself, taken from the first `src`
entry that is a `data:` URL holding a font `Woff.parseFont` can read
(TrueType `glyf` outlines as sfnt, WOFF 1.0 or WOFF 2.0).

Rowan's rule: **nothing outside the one input file is ever loaded.**  A `src`
entry that is not a `data:` URL (`url(font.woff)`, `local(...)`) is ignored,
exactly as if it were absent.  So is an entry whose `format()` hint names a
format that is not a font file (`svg`, `embedded-opentype`), an entry that
does not decode, and a font with CFF outlines (`OTTO`), which `Font.parse`
rejects.

This is Chromium's behaviour, not resvg's: usvg 0.48.1 ignores `@font-face`
altogether.  Chromium's font matching is followed where the corpus needs it:
a `font-family` list is resolved in order, each name against the document's
faces first, then the embedded fonts (`Svg.resolveFontFamily`); among a
family's faces, style first, then `Text.matchWeight` (`select`).  A character
a document font does not map falls back to the embedded fonts
(`Text.assignFonts`), never to another document font; no bold or oblique is
synthesized.

Bounded: at most `maxFaces` faces, each font at most 16 MB decoded
(`Woff.maxFontBytes`), and at most `maxTotalBytes` of declared decoded size
over every font tried, loaded or not (so a thousand copies of a decompression
bomb cost what four do); every scan below runs over a range bounded by the
stylesheet's size.
-/

namespace LeanSvg.FontFace

open Bytes

/-- One `@font-face` face that loaded. `family` is ASCII-lowercased, without
quotes; `coverage` is the codepoints its `cmap` maps, as sorted ranges
(`Font.inRanges`). -/
structure Face where
  family : ByteArray
  weight : Nat
  italic : Bool
  font : Font
  coverage : Array (Nat × Nat)

instance : Repr Face := ⟨fun f _ => Std.Format.text s!"FontFace({toStr f.family}, {f.weight}, {f.italic})"⟩

def maxFaces : Nat := 256
def maxTotalBytes : Nat := 64 * 1024 * 1024

/-- Strip one matching layer of straight quotes (as `Svg.stripQuotes`). -/
def stripQuotes (bs : ByteArray) : ByteArray :=
  if bs.size ≥ 2 &&
     ((at' bs 0 == 34 && at' bs (bs.size - 1) == 34) ||
      (at' bs 0 == 39 && at' bs (bs.size - 1) == 39)) then
    bs.extract 1 (bs.size - 1)
  else bs

/-! ## A font's `cmap` coverage -/

/-- Append `cp` to sorted ranges, merging with the last one when adjacent. -/
def addCp (rs : Array (Nat × Nat)) (cp : Nat) : Array (Nat × Nat) :=
  match rs.back? with
  | some (a, b) => if cp == b + 1 then rs.setIfInBounds (rs.size - 1) (a, cp)
                   else if cp ≤ b then rs else rs.push (cp, cp)
  | none => #[(cp, cp)]

/-- The codepoints `f`'s `cmap` maps to a glyph other than 0.  Format 4: every
codepoint of every segment is looked up (at most the 65536 of the BMP);
format 12: the groups as they are (only a group starting at glyph 0 can map a
codepoint to 0, and only its first). -/
def coverageOf (f : Font) : Array (Nat × Nat) := Id.run do
  let bs := f.data
  let so := f.cmapOff
  let mut rs : Array (Nat × Nat) := #[]
  if f.cmapFormat == 4 then
    let segCount := Font.u16 bs (so + 6) / 2
    let mut segs : Array (Nat × Nat) := #[]
    for i in [0:segCount] do
      let e := Font.u16 bs (so + 14 + 2 * i)
      let s := Font.u16 bs (so + 16 + 2 * segCount + 2 * i)
      if s ≤ e then segs := segs.push (s, e)
    segs := segs.qsort (fun a b => a.1 < b.1)
    let mut budget := 65536
    for (s, e) in segs do
      for cp in [s:e + 1] do
        if budget == 0 then break
        budget := budget - 1
        if Font.glyphId f cp != 0 then rs := addCp rs cp
  else if f.cmapFormat == 12 then
    let mut groups : Array (Nat × Nat) := #[]
    for k in [0:Font.format12Cap bs so] do
      let g := so + 16 + 12 * k
      let s := Font.u32 bs g
      let e := Font.u32 bs (g + 4)
      let s' := if Font.u32 bs (g + 8) == 0 then s + 1 else s
      if s' ≤ e && e ≤ 0x10FFFF then groups := groups.push (s', e)
    groups := groups.qsort (fun a b => a.1 < b.1)
    for (s, e) in groups do
      match rs.back? with
      | some (a, b) =>
        if s ≤ b + 1 then rs := rs.setIfInBounds (rs.size - 1) (a, Nat.max b e)
        else rs := rs.push (s, e)
      | none => rs := rs.push (s, e)
  return rs

/-! ## `data:` URLs -/

/-- Padded base64, whitespace skipped; `none` on any other invalid
character. -/
def base64 (s : ByteArray) : Option ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity (s.size / 4 * 3)
  let mut acc : Nat := 0
  let mut n := 0
  for c in s do
    if isWs c then continue
    if c == 61 then break                                   -- '='
    let v := Font.b64Digit c
    if v ≥ 64 then return none
    acc := acc * 64 + v.toNat
    n := n + 1
    if n == 4 then
      out := ((out.push (acc / 65536 % 256).toUInt8).push (acc / 256 % 256).toUInt8).push (acc % 256).toUInt8
      acc := 0
      n := 0
  if n == 2 then out := out.push (acc / 16 % 256).toUInt8
  else if n == 3 then out := (out.push (acc / 1024 % 256).toUInt8).push (acc / 4 % 256).toUInt8
  else if n == 1 then return none
  return some out

def hexVal (c : UInt8) : Option Nat :=
  if 48 ≤ c && c ≤ 57 then some (c.toNat - 48)
  else if 97 ≤ c && c ≤ 102 then some (c.toNat - 87)
  else if 65 ≤ c && c ≤ 70 then some (c.toNat - 55)
  else none

/-- `%XX` escapes decoded; a malformed escape stays as it is. -/
def percentDecode (s : ByteArray) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity s.size
  let mut i := 0
  for _ in [0:s.size] do
    if i ≥ s.size then break
    let c := at' s i
    match c == 37, hexVal (at' s (i + 1)), hexVal (at' s (i + 2)) with
    | true, some h, some l =>
      out := out.push (h * 16 + l).toUInt8
      i := i + 3
    | _, _, _ =>
      out := out.push c
      i := i + 1
  return out

/-- The bytes of a `data:` URL; `none` for any other URL or a malformed one.
Payloads that would decode to more than `Woff.maxFontBytes` are refused
before decoding. -/
def dataUrl (u : ByteArray) : Option ByteArray :=
  if !(u.size ≥ 5 && eqAsciiCI (u.extract 0 5) "data:") then none
  else
    let comma := findByte u 5 44
    if comma ≥ u.size then none
    else
      let mediaType := trim (u.extract 5 comma)
      let body := u.extract (comma + 1) u.size
      let isB64 := mediaType.size ≥ 7 && eqAsciiCI (mediaType.extract (mediaType.size - 7) mediaType.size) ";base64"
      if body.size / 4 * 3 > Woff.maxFontBytes + 3 then none
      else if isB64 then base64 body
      else some (percentDecode body)

/-! ## Splitting `@font-face` blocks -/

/-- Split `s` at `sep` outside quotes and parentheses (depth capped at 32). -/
def splitTop (s : ByteArray) (sep : UInt8) : Array ByteArray := Id.run do
  let mut out : Array ByteArray := #[]
  let mut start := 0
  let mut depth := 0
  let mut quote : UInt8 := 0
  for i in [0:s.size] do
    let c := at' s i
    if quote != 0 then
      if c == quote then quote := 0
    else if c == 34 || c == 39 then quote := c
    else if c == 40 then depth := Nat.min 32 (depth + 1)
    else if c == 41 then depth := depth - 1
    else if c == sep && depth == 0 then
      out := out.push (s.extract start i)
      start := i + 1
  out := out.push (s.extract start s.size)
  return out

/-- The argument of the first `fn(...)` in `s` (`fn` lowercase), unquoted and
trimmed; `none` if `s` has no such call.  A quoted argument ends at its
closing quote, an unquoted one at the first `)`. -/
def callArg (s : ByteArray) (fn : String) : Option ByteArray :=
  let open_ := findSeq (lower s) 0 (fn ++ "(")
  if open_ ≥ s.size then none
  else
    let a := skipWs s (open_ + fn.utf8ByteSize + 1)
    let q := at' s a
    if q == 34 || q == 39 then
      let e := findByte s (a + 1) q
      if e ≥ s.size then none else some (s.extract (a + 1) e)
    else
      let e := findByte s a 41
      if e ≥ s.size then none else some (trim (s.extract a e))

/-- `font-weight` descriptor: a keyword or the first number of a range. -/
def weightOf (v : ByteArray) : Nat :=
  let t := trim v
  if eqAsciiCI t "bold" then 700
  else match (splitTrim t 32)[0]? with
    | some w =>
      let n := w.foldl (fun acc c => if isDigit c then some ((acc.getD 0) * 10 + (c - 48).toNat) else none) (some 0)
      match n with
      | some k => if 1 ≤ k && k ≤ 1000 then k else 400
      | none => 400
    | none => 400

/-- The first loadable font of a `src` descriptor, and the work budget left:
each `data:` payload tried is charged its declared decoded size
(`Woff.declaredSize`) before it is decoded, and none is tried once
`budget` would run out. -/
def loadSrc (v : ByteArray) (budget : Nat) : Option Font × Nat := Id.run do
  let mut budget := budget
  for item in splitTop v 44 do
    match callArg item "format" with
    | some f =>
      let f := lower f
      if !(eqAscii f "woff2" || eqAscii f "woff" || eqAscii f "truetype" || eqAscii f "opentype") then
        continue
    | none => pure ()
    match callArg item "url" with
    | none => continue
    | some u =>
      match dataUrl u with
      | none => continue
      | some bs =>
        let cost := Woff.declaredSize bs
        if cost > budget then return (none, 0)
        budget := budget - cost
        match Woff.parseFont bs with
        | some f => return (some f, budget)
        | none => continue
  return (none, budget)

/-- The document's `@font-face` faces, in source order. -/
def scan (css0 : ByteArray) : Array Face := Id.run do
  let css := Css.stripComments css0
  let lc := lower css
  let mut faces : Array Face := #[]
  let mut budget := maxTotalBytes
  let mut i := 0
  for _ in [0:css.size] do
    let at_ := findSeq lc i "@font-face"
    if at_ ≥ css.size || faces.size ≥ maxFaces then break
    let ob := findByte css (at_ + 10) 123
    if ob ≥ css.size then break
    -- the block's end: the next `}` outside quotes and parentheses
    let mut cb := css.size
    let mut depth := 0
    let mut quote : UInt8 := 0
    for k in [ob + 1:css.size] do
      let c := at' css k
      if quote != 0 then
        if c == quote then quote := 0
      else if c == 34 || c == 39 then quote := c
      else if c == 40 then depth := Nat.min 32 (depth + 1)
      else if c == 41 then depth := depth - 1
      else if c == 125 && depth == 0 then
        cb := k
        break
    i := cb + 1
    let mut family : Option ByteArray := none
    let mut weight := 400
    let mut italic := false
    let mut src : Option ByteArray := none
    for d in splitTop (css.extract (ob + 1) cb) 59 do
      let colon := findByte d 0 58
      if colon ≥ d.size then continue
      let name := lower (trim (d.extract 0 colon))
      let value := trim (d.extract (colon + 1) d.size)
      if eqAscii name "font-family" then family := some (lower (stripQuotes value))
      else if eqAscii name "font-weight" then weight := weightOf value
      else if eqAscii name "font-style" then
        italic := (splitTrim value 32).any (fun w => eqAsciiCI w "italic" || eqAsciiCI w "oblique")
      else if eqAscii name "src" then src := some value
    match family, src with
    | some fam, some s =>
      if fam.size > 0 then
        let (f?, left) := loadSrc s budget
        budget := left
        match f? with
        | some f => faces := faces.push ⟨fam, weight, italic, f, coverageOf f⟩
        | none => pure ()
    | _, _ => pure ()
  return faces

/-- Among the faces of `faces[first]`'s family, the one CSS font matching
picks for `weight`/`italic`: the requested style if the family has it, then
`Text.matchWeight`. -/
def select (faces : Array Face) (first weight : Nat) (italic : Bool) : Nat := Id.run do
  let fam := faces[first]?.map (·.family)
  let cands := (List.range faces.size).filter (fun k => faces[k]?.map (·.family) == fam)
  let styled := cands.filter (fun k => faces[k]?.map (·.italic) == some italic)
  let pool := if styled.isEmpty then cands else styled
  let w := Text.matchWeight (pool.map (fun k => (faces[k]?.map (·.weight)).getD 400)) weight
  return (pool.find? (fun k => faces[k]?.map (·.weight) == some w)).getD first

end LeanSvg.FontFace
