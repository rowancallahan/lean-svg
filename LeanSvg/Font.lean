import LeanSvg.Bytes
import LeanSvg.Fixed
import LeanSvg.Geom

/-!
# TrueType font parser: a pure, total function of bytes

A font is bytes; `Font.parse` is a **pure total function** from those bytes to
a `Font` record of resolved table offsets, plus accessors that read glyph
outlines, advances and kerning straight out of the original `ByteArray`. There
is no `IO` anywhere in this module and no way to introduce any: it imports
only `LeanSvg.Bytes`, `LeanSvg.Fixed` and `LeanSvg.Geom`.

Every offset the parser trusts is validated against `bs.size` (via
`Bytes.at'`, which reads `0` past the end instead of panicking), every loop
runs over a range bounded by a table's own declared count or a fixed cap, and
composite-glyph recursion is bounded by an explicit fuel parameter. A
corrupt, truncated or adversarial byte string therefore cannot crash the
parser or loop forever: `parse` returns `none`, or the accessors return `0`
/ empty arrays for whatever they cannot make sense of. Fonts ship as
constants embedded in the binary (see `LeanSvg/Fonts/*.lean`), so this
module adds no new effect: no system font is ever read.

Tables read: `head`, `maxp`, `cmap` (formats 4 and 12, platform 3/encoding
1 or 10, or platform 0), `loca`, `glyf` (simple and composite glyphs), `hhea`
and `hmtx`, plus kerning from either the legacy `kern` table (format 0,
horizontal) or `GPOS` pair adjustment (lookup type 2, formats 1 and 2, under
a `kern`-tagged feature — horizontal advance of the first glyph only). Other
tables (`GSUB`, `GDEF`, `CFF `, bitmap/colour tables, …) are ignored.
-/

namespace LeanSvg

/-! ## The font record

Declared at the `LeanSvg` level (not inside `namespace Font` below), the
same way `Pt`/`Mat`/`Box` are in `LeanSvg/Geom.lean`: this makes the type
`LeanSvg.Font`, so that `open LeanSvg` gives both the type `Font` and its
functions `Font.parse`, `Font.glyphId`, … without a spurious extra
`LeanSvg.Font.Font` nesting. -/

structure Font where
  unitsPerEm : Nat
  numGlyphs : Nat
  /-- Resolved ascender: `OS/2.sTypoAscender` when `OS/2.fsSelection`'s
  `USE_TYPO_METRICS` bit is set, else `hhea.ascender`, else (only when that is
  `0`) the `OS/2` typo or Windows ascent as a last resort — `skrifa`'s
  `Metrics::new` algorithm (itself FreeType's), which is what usvg's
  `ResolvedFont` carries. Positive: font units above the baseline. -/
  ascent : Int
  /-- Resolved descender, same source as `ascent`. Negative: font units below
  the baseline. -/
  descent : Int
  /-- Resolved line gap, same source as `ascent`/`descent`. -/
  lineGap : Int
  /-- `OS/2.sxHeight` if the table has it (version ≥ 2) and it is positive,
  else `round((ascent - descent) * 0.45)` (Firefox's fallback, which usvg
  copies). -/
  xHeight : Int
  /-- `OS/2.sCapHeight` if the table has it (version ≥ 2), else `0` (no
  formula fallback exists in usvg either; unused by the baseline formulas
  this task implements, kept for `tests/check_font.py` and future use). -/
  capHeight : Int
  /-- `OS/2.ySubscriptYOffset`, or `unitsPerEm * 5` if there is no `OS/2`
  table at all (usvg's generic Inkscape/librsvg-derived fallback). -/
  subscriptOffset : Int
  /-- `OS/2.ySuperscriptYOffset`, or `round(unitsPerEm * 2.5)` with no `OS/2`
  table. -/
  superscriptOffset : Int
  /-- 0 = `loca` entries are `u16 * 2`, 1 = `u32` directly. -/
  indexToLocFormat : Nat
  locaOff : Nat
  glyfOff : Nat
  glyfLen : Nat
  /-- Absolute offset of the chosen `cmap` subtable, or `0` if none usable. -/
  cmapOff : Nat
  /-- `4`, `12`, or `0` for "no usable cmap". -/
  cmapFormat : Nat
  numberOfHMetrics : Nat
  hmtxOff : Nat
  /-- Cap on points per glyph: `maxp.maxPoints` if present, else `10000`. -/
  maxPointsCap : Nat
  /-- Legacy `kern` table, format 0 horizontal pairs; `0, 0` if absent. -/
  kernPairsOff : Nat
  kernNPairs : Nat
  /-- Absolute offsets of `GPOS` `PairPos` subtables reachable from a
  `kern`-tagged feature (any script/language). -/
  gposKernSubtables : Array Nat
  /-- `post` table `underlinePosition`, font units (negative is below the
  baseline); usvg's fallback of `-unitsPerEm/9` if the table is absent. -/
  underlinePosition : Int
  /-- `post` table `underlineThickness`, font units; usvg's fallback of
  `unitsPerEm/12` if the table is absent or the field is non-positive. -/
  underlineThickness : Int
  /-- `OS/2` table `yStrikeoutPosition`, font units (positive is above the
  baseline); usvg's fallback of `0.225 * (ascender - descender)` if the table
  is absent, an approximation of Firefox's x-height-based one that is never
  exercised by the three embedded faces (all three carry a real `OS/2`). -/
  strikeoutPosition : Int
  data : ByteArray

namespace Font

open Bytes (at')

/-! ## Big-endian byte access, bounds-checked via `Bytes.at'` -/

@[inline] def u8 (bs : ByteArray) (i : Nat) : Nat := (at' bs i).toNat
@[inline] def u16 (bs : ByteArray) (i : Nat) : Nat := u8 bs i * 256 + u8 bs (i + 1)
@[inline] def u32 (bs : ByteArray) (i : Nat) : Nat := u16 bs i * 65536 + u16 bs (i + 2)

@[inline] def i8 (bs : ByteArray) (i : Nat) : Int :=
  let v := u8 bs i
  if v ≥ 128 then (v : Int) - 256 else (v : Int)

@[inline] def i16 (bs : ByteArray) (i : Nat) : Int :=
  let v := u16 bs i
  if v ≥ 32768 then (v : Int) - 65536 else (v : Int)

/-- Round an F2Dot14 (denominator 16384) product to the nearest font unit,
ties away from zero via `Int.ediv`'s floor after adding half the denominator
— the same idiom as `Fx.round`. -/
@[inline] def roundDiv14 (n : Int) : Int := Int.ediv (n + 8192) 16384

/-- A font-units value (an ascender, an `OS/2` subscript offset, …) scaled by
`sizeFx / unitsPerEm` into 16.16 fixed point (units of 1/65536 px) — the
precision `Text.layout` carries pen positions in, so a baseline offset can be
added to them before the one rounding to `Fx` that happens when a glyph's
control points are finally written out. `sizeFx` is the span's `font-size`
(`Fx`, 1/256 px). Rounds to nearest, ties away from zero, the same idiom as
`roundDiv14`, extended to a possibly-negative numerator (an ascender is
positive, a descender and many baseline offsets are not). -/
def unitsToFx16 (v sizeFx : Int) (upem : Nat) : Int :=
  if upem == 0 then 0
  else
    let num := v * sizeFx * 256
    let d : Int := upem
    if num ≥ 0 then Int.ediv (num + d / 2) d
    else -(Int.ediv (-num + d / 2) d)

/-! ## Table tags, as the big-endian `u32` of their four ASCII bytes -/

def tagHead : Nat := 0x68656164
def tagMaxp : Nat := 0x6D617870
def tagCmap : Nat := 0x636D6170
def tagLoca : Nat := 0x6C6F6361
def tagGlyf : Nat := 0x676C7966
def tagHhea : Nat := 0x68686561
def tagHmtx : Nat := 0x686D7478
def tagKern : Nat := 0x6B65726E
def tagGPOS : Nat := 0x47504F53
def tagPost : Nat := 0x706F7374
def tagOS2 : Nat := 0x4F532F32

/-! ## Table directory -/

structure Tables where
  head : Option (Nat × Nat) := none
  maxp : Option (Nat × Nat) := none
  cmap : Option (Nat × Nat) := none
  loca : Option (Nat × Nat) := none
  glyf : Option (Nat × Nat) := none
  hhea : Option (Nat × Nat) := none
  hmtx : Option (Nat × Nat) := none
  kernT : Option (Nat × Nat) := none
  gpos : Option (Nat × Nat) := none
  post : Option (Nat × Nat) := none
  os2 : Option (Nat × Nat) := none

/-- Scan the `numTables` 16-byte directory records starting at byte 12,
recording `(offset, length)` for the tables this parser needs. A record past
`bs.size`, or a table whose offset is past `bs.size`, is skipped; a length
that overruns `bs.size` is clamped. Bounded by `numTables ≤ 65535` (it is a
`u16`). -/
def scanTables (bs : ByteArray) (numTables : Nat) : Tables := Id.run do
  let mut t : Tables := {}
  for i in [0:numTables] do
    let dirOff := 12 + 16 * i
    if dirOff + 16 ≤ bs.size then
      let tag := u32 bs dirOff
      let off := u32 bs (dirOff + 8)
      let len := u32 bs (dirOff + 12)
      if off ≤ bs.size then
        let clen := Nat.min len (bs.size - off)
        if tag == tagHead then t := { t with head := some (off, clen) }
        else if tag == tagMaxp then t := { t with maxp := some (off, clen) }
        else if tag == tagCmap then t := { t with cmap := some (off, clen) }
        else if tag == tagLoca then t := { t with loca := some (off, clen) }
        else if tag == tagGlyf then t := { t with glyf := some (off, clen) }
        else if tag == tagHhea then t := { t with hhea := some (off, clen) }
        else if tag == tagHmtx then t := { t with hmtx := some (off, clen) }
        else if tag == tagKern then t := { t with kernT := some (off, clen) }
        else if tag == tagGPOS then t := { t with gpos := some (off, clen) }
        else if tag == tagPost then t := { t with post := some (off, clen) }
        else if tag == tagOS2 then t := { t with os2 := some (off, clen) }
  return t

/-! ## `cmap` subtable selection -/

/-- Preference score for a `(platformID, encodingID)` pair: Windows full
Unicode (3, 10) highest, Windows BMP (3, 1) next, any Unicode platform (0)
last, everything else unusable. -/
def cmapScore (platform encoding : Nat) : Nat :=
  if platform == 3 && encoding == 10 then 3
  else if platform == 3 && encoding == 1 then 2
  else if platform == 0 then 1
  else 0

/-- Pick the best-scoring `cmap` subtable whose format is 4 or 12. Returns
`(subtableOffset, format)`, or `(0, 0)` if none qualifies. Bounded by
`numTables ≤ 65535`. -/
def resolveCmap (bs : ByteArray) (cOff cLen : Nat) : Nat × Nat := Id.run do
  if cLen < 4 then return (0, 0)
  let numTables := u16 bs (cOff + 2)
  let mut bestScore := 0
  let mut bestOff := 0
  for i in [0:numTables] do
    let recOff := cOff + 4 + 8 * i
    let platform := u16 bs recOff
    let encoding := u16 bs (recOff + 2)
    let subOff := cOff + u32 bs (recOff + 4)
    let score := cmapScore platform encoding
    if score > bestScore && subOff < bs.size then
      let fmt := u16 bs subOff
      if fmt == 4 || fmt == 12 then
        bestScore := score
        bestOff := subOff
  if bestScore == 0 then return (0, 0)
  return (bestOff, u16 bs bestOff)

/-- Format 4 `cmap` lookup: BMP-only, segmented by `endCode`/`startCode`.
Linear scan over `segCount ≤ 32767` (`segCountX2` is a `u16`). -/
def glyphIdFormat4 (bs : ByteArray) (so : Nat) (codepoint : Nat) : Nat := Id.run do
  if codepoint > 0xFFFF then return 0
  let segCount := u16 bs (so + 6) / 2
  let endCodeOff := so + 14
  let startCodeOff := endCodeOff + segCount * 2 + 2
  let idDeltaOff := startCodeOff + segCount * 2
  let idRangeOff := idDeltaOff + segCount * 2
  for i in [0:segCount] do
    let ec := u16 bs (endCodeOff + 2 * i)
    let sc := u16 bs (startCodeOff + 2 * i)
    if sc ≤ codepoint && codepoint ≤ ec then
      let delta := i16 bs (idDeltaOff + 2 * i)
      let iro := u16 bs (idRangeOff + 2 * i)
      if iro == 0 then
        return (Int.emod ((codepoint : Int) + delta) 65536).toNat
      else
        let addr := idRangeOff + 2 * i + iro + 2 * (codepoint - sc)
        let g := u16 bs addr
        if g == 0 then return 0
        else return (Int.emod ((g : Int) + delta) 65536).toNat
  return 0

/-- Format 12 `cmap` lookup: contiguous `(startChar, endChar, startGlyph)`
groups. `numGroups` is a `u32` and cannot be trusted directly (a malicious
font could claim billions), so the scan is capped at whatever the subtable
could actually hold given `bs.size`, and at a further constant `100000` —
generous for any real font, and cheap even so since this runs once per
character. -/
def glyphIdFormat12 (bs : ByteArray) (so : Nat) (codepoint : Nat) : Nat := Id.run do
  let numGroups := u32 bs (so + 12)
  let groupsOff := so + 16
  let byAvail := if bs.size > groupsOff then (bs.size - groupsOff) / 12 else 0
  let cap := Nat.min numGroups (Nat.min 100000 byAvail)
  for i in [0:cap] do
    let go := groupsOff + 12 * i
    let startChar := u32 bs go
    let endChar := u32 bs (go + 4)
    let startGlyph := u32 bs (go + 8)
    if startChar ≤ codepoint && codepoint ≤ endChar then
      return startGlyph + (codepoint - startChar)
  return 0

/-- Glyph id for a Unicode codepoint via the font's chosen `cmap` subtable.
`0` (`.notdef`) if there is none, or the codepoint is not mapped. -/
def glyphId (f : Font) (codepoint : Nat) : Nat :=
  if f.cmapFormat == 4 then glyphIdFormat4 f.data f.cmapOff codepoint
  else if f.cmapFormat == 12 then glyphIdFormat12 f.data f.cmapOff codepoint
  else 0

/-! ## Legacy `kern` table (format 0, horizontal) -/

/-- Find the first format-0 horizontal subtable in a Windows-style `kern`
table (`version`, `nTables`, then `nTables` subtables each with its own
`version`/`length`/`coverage`/`nPairs` header). Returns
`(pairsOffset, nPairs)`, or `(0, 0)` if none. Bounded by `nTables ≤ 65535`. -/
def resolveKern (bs : ByteArray) (kOff kLen : Nat) : Nat × Nat := Id.run do
  if kLen < 4 then return (0, 0)
  let nTables := u16 bs (kOff + 2)
  let mut off := kOff + 4
  for _ in [0:nTables] do
    let subLength := u16 bs (off + 2)
    let coverage := u16 bs (off + 4)
    let format := coverage / 256
    let horizontal := coverage &&& 0x1 != 0
    if format == 0 && horizontal then
      let nPairs := u16 bs (off + 6)
      return (off + 14, nPairs)
    off := off + (if subLength == 0 then 6 else subLength)
  return (0, 0)

/-! ## `GPOS` pair adjustment (lookup type 2, formats 1 and 2)

Only the `kern`-tagged feature's lookups are consulted, for every
script/language that lists it (a Latin-subset font like the ones embedded
here has at most a handful), and only lookup type 2 (type 9, "extension
positioning", is not unwrapped — not needed for the embedded fonts, see the
Report). Only `XAdvance` of the first glyph is extracted. -/

/-- Coverage table index of `gid`, or `none`. Format 1 is a sorted glyph
list (linear scan, bounded by `glyphCount ≤ 65535`); format 2 is a list of
`(start, end, startIndex)` ranges (bounded by `rangeCount ≤ 65535`). -/
def coverageIndex (bs : ByteArray) (off gid : Nat) : Option Nat := Id.run do
  let fmt := u16 bs off
  if fmt == 1 then
    let count := u16 bs (off + 2)
    for i in [0:count] do
      if u16 bs (off + 4 + 2 * i) == gid then return some i
    return none
  else if fmt == 2 then
    let rangeCount := u16 bs (off + 2)
    for i in [0:rangeCount] do
      let ro := off + 4 + 6 * i
      let startG := u16 bs ro
      let endG := u16 bs (ro + 2)
      if startG ≤ gid && gid ≤ endG then
        return some (u16 bs (ro + 4) + (gid - startG))
    return none
  else none

/-- Class of `gid` under a `ClassDef` table at `off` (`0` if `off == 0`, the
table is absent, or `gid` is not covered by it — `0` is always a valid
"unclassified" bucket). Format 1 is a dense array over one glyph range
(bounded by `glyphCount ≤ 65535`); format 2 is a list of ranges (bounded by
`rangeCount ≤ 65535`). -/
def classOf (bs : ByteArray) (off gid : Nat) : Nat := Id.run do
  if off == 0 then return 0
  let fmt := u16 bs off
  if fmt == 1 then
    let startG := u16 bs (off + 2)
    let glyphCount := u16 bs (off + 4)
    if gid ≥ startG && gid - startG < glyphCount then
      return u16 bs (off + 6 + 2 * (gid - startG))
    return 0
  else if fmt == 2 then
    let rangeCount := u16 bs (off + 2)
    for i in [0:rangeCount] do
      let ro := off + 4 + 6 * i
      let startG := u16 bs ro
      let endG := u16 bs (ro + 2)
      if startG ≤ gid && gid ≤ endG then return u16 bs (ro + 4)
    return 0
  else return 0

/-- Number of bytes a `ValueRecord` of this format occupies: two per set bit
among the eight defined field flags. -/
def valueRecordSize (fmt : Nat) : Nat :=
  let b := fun m => if fmt &&& m != 0 then 1 else 0
  2 * (b 0x0001 + b 0x0002 + b 0x0004 + b 0x0008 + b 0x0010 + b 0x0020 + b 0x0040 + b 0x0080)

/-- Byte offset of the `XAdvance` field within a `ValueRecord` of this
format, or `none` if the format does not include it. -/
def xAdvanceOffset (fmt : Nat) : Option Nat :=
  if fmt &&& 0x0004 == 0 then none
  else
    let b := fun m => if fmt &&& m != 0 then 1 else 0
    some (2 * (b 0x0001 + b 0x0002))

/-- `PairPos` format 1: a `PairSet` (an array of `(secondGlyph, value1,
value2)` records) per glyph covered as the first glyph. Bounded by
`pairValueCount ≤ 65535`. -/
def pairPosFormat1 (bs : ByteArray) (so left right : Nat) : Option Int := Id.run do
  let coverageOff := so + u16 bs (so + 2)
  match coverageIndex bs coverageOff left with
  | none => return none
  | some idx =>
    let valueFormat1 := u16 bs (so + 4)
    let valueFormat2 := u16 bs (so + 6)
    let pairSetCount := u16 bs (so + 8)
    if idx ≥ pairSetCount then return none
    let pairSetOff := so + u16 bs (so + 10 + 2 * idx)
    let pairValueCount := u16 bs pairSetOff
    let recSize := 2 + valueRecordSize valueFormat1 + valueRecordSize valueFormat2
    for i in [0:pairValueCount] do
      let ro := pairSetOff + 2 + recSize * i
      if u16 bs ro == right then
        match xAdvanceOffset valueFormat1 with
        | some xoff => return some (i16 bs (ro + 2 + xoff))
        | none => return some 0
    return none

/-- `PairPos` format 2: first and second glyph are classified by their own
`ClassDef` tables, and the value is looked up in a dense `class1 × class2`
matrix. The first glyph must also be in the subtable's `Coverage` (checked
first; its index is otherwise unused, since the matrix is indexed by
class). -/
def pairPosFormat2 (bs : ByteArray) (so left right : Nat) : Option Int := Id.run do
  let coverageOff := so + u16 bs (so + 2)
  match coverageIndex bs coverageOff left with
  | none => return none
  | some _ =>
    let valueFormat1 := u16 bs (so + 4)
    let valueFormat2 := u16 bs (so + 6)
    let classDef1Off := so + u16 bs (so + 8)
    let classDef2Off := so + u16 bs (so + 10)
    let class1Count := u16 bs (so + 12)
    let class2Count := u16 bs (so + 14)
    let c1 := classOf bs classDef1Off left
    let c2 := classOf bs classDef2Off right
    if c1 ≥ class1Count || c2 ≥ class2Count then return none
    let recSize := valueRecordSize valueFormat1 + valueRecordSize valueFormat2
    let classRecOff := so + 16 + (c1 * class2Count + c2) * recSize
    match xAdvanceOffset valueFormat1 with
    | some xoff => return some (i16 bs (classRecOff + xoff))
    | none => return some 0

/-- Absolute offsets of every `PairPos` (lookup type 2) subtable reachable
from a `kern`-tagged feature, for any script/language. Every count involved
(`featureCount`, `lookupIndexCount`, `lookupCount`, `subTableCount`) is a
`u16`, so each loop is bounded by `65535`; the two accumulators are also
capped at a constant `256`, generous for any real font, so the total work
stays small regardless of how many "kern" feature records a font declares. -/
def findKernSubtables (bs : ByteArray) (gposOff gposLen : Nat) : Array Nat := Id.run do
  if gposLen < 10 then return #[]
  let majorVersion := u16 bs gposOff
  if majorVersion != 1 then return #[]
  let featureListOff := gposOff + u16 bs (gposOff + 6)
  let lookupListOff := gposOff + u16 bs (gposOff + 8)
  let featureCount := u16 bs featureListOff
  let mut lookupIdxs : Array Nat := #[]
  for i in [0:featureCount] do
    let recOff := featureListOff + 2 + 6 * i
    if u32 bs recOff == tagKern then
      let featureOff := featureListOff + u16 bs (recOff + 4)
      let lookupIndexCount := u16 bs (featureOff + 2)
      for j in [0:lookupIndexCount] do
        if lookupIdxs.size < 256 then
          lookupIdxs := lookupIdxs.push (u16 bs (featureOff + 4 + 2 * j))
  let lookupCount := u16 bs lookupListOff
  let mut subOffs : Array Nat := #[]
  for li in lookupIdxs do
    if li < lookupCount && subOffs.size < 256 then
      let lookupOff := lookupListOff + u16 bs (lookupListOff + 2 + 2 * li)
      let lookupType := u16 bs lookupOff
      if lookupType == 2 then
        let subTableCount := u16 bs (lookupOff + 4)
        for k in [0:subTableCount] do
          if subOffs.size < 256 then
            subOffs := subOffs.push (lookupOff + u16 bs (lookupOff + 6 + 2 * k))
  return subOffs

/-- Kerning adjustment in font units between adjacent glyphs `left`/`right`:
the legacy `kern` table if present, else the first matching `GPOS` pair
subtable, else `0`. -/
def kern (f : Font) (left right : Nat) : Int := Id.run do
  if f.kernNPairs > 0 then
    for i in [0:f.kernNPairs] do
      let l := u16 f.data (f.kernPairsOff + 6 * i)
      let r := u16 f.data (f.kernPairsOff + 6 * i + 2)
      if l == left && r == right then
        return i16 f.data (f.kernPairsOff + 6 * i + 4)
  for so in f.gposKernSubtables do
    let fmt := u16 f.data so
    if fmt == 1 then
      match pairPosFormat1 f.data so left right with
      | some v => return v
      | none => pure ()
    else if fmt == 2 then
      match pairPosFormat2 f.data so left right with
      | some v => return v
      | none => pure ()
  return 0

/-! ## `hmtx`: advance widths -/

/-- Advance width in font units. Glyphs at or past `numberOfHMetrics` share
the last recorded width, as the spec requires. `0` for an out-of-range
glyph id or a font with no metrics. -/
def advance (f : Font) (gid : Nat) : Nat :=
  if gid ≥ f.numGlyphs || f.numberOfHMetrics == 0 then 0
  else if gid < f.numberOfHMetrics then u16 f.data (f.hmtxOff + 4 * gid)
  else u16 f.data (f.hmtxOff + 4 * (f.numberOfHMetrics - 1))

/-! ## `loca` / `glyf`: locating a glyph's own bytes -/

def locaOffset (f : Font) (i : Nat) : Nat :=
  if f.indexToLocFormat == 1 then u32 f.data (f.locaOff + 4 * i)
  else 2 * u16 f.data (f.locaOff + 2 * i)

/-- The `(absoluteOffset, length)` of glyph `gid`'s own record in `glyf`,
clamped to the table's own extent and to `f.data.size`. `none` for an
out-of-range glyph id or non-monotonic `loca` entries (corrupt font); `some
(_, 0)` for a glyph with an empty outline (e.g. space), which is a normal,
valid case. -/
def glyphSpan (f : Font) (gid : Nat) : Option (Nat × Nat) :=
  if gid ≥ f.numGlyphs then none
  else
    let o0 := locaOffset f gid
    let o1 := locaOffset f (gid + 1)
    if o1 < o0 then none
    else
      let off := f.glyfOff + o0
      if off > f.data.size then none
      else
        let tableEnd := Nat.min f.data.size (f.glyfOff + f.glyfLen)
        let len := if off > tableEnd then 0 else Nat.min (o1 - o0) (tableEnd - off)
        some (off, len)

/-! ## `glyf`: simple glyph outlines -/

/-- Parse a simple glyph's contours into `(x, y, onCurve)` points, grouped by
contour. Total and defensive throughout: any inconsistency (too few bytes
for the declared contour count, more points than `maxPointsCap` allows)
yields `#[]` rather than reading garbage. Every loop is bounded by
`numberOfContours` (already ≤ 32767, an `i16`) or `numPoints` (checked
against `maxPointsCap` before any of the flag/coordinate loops run). -/
def parseSimpleGlyph (bs : ByteArray) (off len numberOfContours maxPointsCap : Nat) :
    Array (Array (Int × Int × Bool)) := Id.run do
  if numberOfContours == 0 then return #[]
  let endPtsOff := off + 10
  if endPtsOff + 2 * numberOfContours > off + len then return #[]
  let mut endPts : Array Nat := Array.emptyWithCapacity numberOfContours
  for i in [0:numberOfContours] do
    endPts := endPts.push (u16 bs (endPtsOff + 2 * i))
  let numPoints := endPts.getD (numberOfContours - 1) 0 + 1
  if numPoints == 0 || numPoints > maxPointsCap then return #[]
  -- `endPtsOfContours` must increase strictly (the spec requires it).  A
  -- corrupt glyph whose end points go back down would otherwise let every
  -- contour below re-copy up to `numPoints` points: 25 603 contours × 10 000
  -- points in the T91 fuzz run on Noto Sans KR.
  for i in [1:numberOfContours] do
    if endPts.getD i 0 ≤ endPts.getD (i - 1) 0 then return #[]
  let instructionLength := u16 bs (endPtsOff + 2 * numberOfContours)
  let flagsOff := endPtsOff + 2 * numberOfContours + 2 + instructionLength
  -- flags, expanding REPEAT_FLAG (bit 0x08) runs; exactly `numPoints` iterations.
  let mut flags : Array UInt8 := Array.emptyWithCapacity numPoints
  let mut fp := flagsOff
  let mut curFlag : UInt8 := 0
  let mut repeatLeft : Nat := 0
  for _ in [0:numPoints] do
    if repeatLeft > 0 then
      repeatLeft := repeatLeft - 1
    else
      curFlag := at' bs fp
      fp := fp + 1
      if curFlag &&& 0x08 != 0 then
        repeatLeft := (at' bs fp).toNat
        fp := fp + 1
    flags := flags.push curFlag
  -- x deltas: bit 0x02 = short (1 byte, sign from bit 0x10); else same (0) or i16.
  let mut xp := fp
  let mut xs : Array Int := Array.emptyWithCapacity numPoints
  let mut curX : Int := 0
  for i in [0:numPoints] do
    let flag := flags.getD i 0
    let mut dx : Int := 0
    if flag &&& 0x02 != 0 then
      let m := (at' bs xp).toNat
      dx := if flag &&& 0x10 != 0 then (m : Int) else -(m : Int)
      xp := xp + 1
    else if flag &&& 0x10 == 0 then
      dx := i16 bs xp
      xp := xp + 2
    curX := curX + dx
    xs := xs.push curX
  -- y deltas: bit 0x04 = short, sign from bit 0x20; same layout as x.
  let mut yp := xp
  let mut ys : Array Int := Array.emptyWithCapacity numPoints
  let mut curY : Int := 0
  for i in [0:numPoints] do
    let flag := flags.getD i 0
    let mut dy : Int := 0
    if flag &&& 0x04 != 0 then
      let m := (at' bs yp).toNat
      dy := if flag &&& 0x20 != 0 then (m : Int) else -(m : Int)
      yp := yp + 1
    else if flag &&& 0x20 == 0 then
      dy := i16 bs yp
      yp := yp + 2
    curY := curY + dy
    ys := ys.push curY
  -- group into contours by `endPts`.
  let mut out : Array (Array (Int × Int × Bool)) := Array.emptyWithCapacity numberOfContours
  let mut start := 0
  for c in [0:numberOfContours] do
    let e := endPts.getD c 0
    let mut contour : Array (Int × Int × Bool) := #[]
    if e ≥ start then
      for i in [start:e + 1] do
        contour := contour.push (xs.getD i 0, ys.getD i 0, flags.getD i 0 &&& 0x01 != 0)
    out := out.push contour
    start := e + 1
  return out

/-! ## `glyf`: composite glyphs, and the shared resolver -/

/-- Component visits one glyph's composite resolution may make in total (T91).
Real fonts use a handful (the most in any embedded font is 21, in Noto Sans;
Noto Sans KR and SC have no composites); this only has to stop corrupted data. -/
def compositeBudget : Nat := 256

/-- A composite stops taking components once it holds more points than this
(T91): 4× the per-simple-glyph cap. -/
def compositePointCap : Nat := 40000

/-- Resolve glyph `gid`'s contours to `(x, y, onCurve)` points in font units,
following composite references with `fuel` levels of recursion left (each
component uses one). `fuel = 0` stops and yields `#[]` for whatever
composite is left unresolved — a safe, total fallback for a maliciously (or
accidentally) self-referential font, never an infinite loop. The recursive
call always passes the statically smaller `fuel` from the `fuel + 1` match,
so this is ordinary structural recursion.

Fuel alone bounds the depth but not the work: 64 components per level over 8
levels is 64^8 calls, which a corrupted large font reached in the T91 fuzz
run (`tests/fuzz_font.py` on Noto Sans KR timed out).  So the recursion also
threads `budget`, the number of components the whole glyph may still visit
(each one costs 1, and the remainder comes back with the result), and a
composite stops adding components once it holds more than `compositePointCap`
points. -/
def resolvedContours (f : Font) (gid : Nat) :
    Nat → Nat → Array (Array (Int × Int × Bool)) × Nat
  | 0, budget => (#[], budget)
  | fuel + 1, budget =>
    match glyphSpan f gid with
    | none => (#[], budget)
    | some (off, len) =>
      if len < 10 then (#[], budget)
      else
        let numberOfContours := i16 f.data off
        if numberOfContours ≥ 0 then
          (parseSimpleGlyph f.data off len numberOfContours.toNat f.maxPointsCap, budget)
        else Id.run do
          -- composite: a sequence of component records, capped at 64 components.
          let mut out : Array (Array (Int × Int × Bool)) := #[]
          let mut points := 0
          let mut budget := budget
          let mut p := off + 10
          let endOff := off + len
          for _ in [0:64] do
            if budget == 0 || points > compositePointCap then break
            budget := budget - 1
            if p + 4 ≤ endOff then
              let flags := u16 f.data p
              let glyphIndex := u16 f.data (p + 2)
              let wordArgs := flags &&& 0x0001 != 0
              let xyValues := flags &&& 0x0002 != 0
              let mut q := p + 4
              let mut dx : Int := 0
              let mut dy : Int := 0
              if xyValues then
                if wordArgs then
                  dx := i16 f.data q
                  dy := i16 f.data (q + 2)
                else
                  dx := i8 f.data q
                  dy := i8 f.data (q + 1)
              -- else: point-matching args (ARGS_ARE_XY_VALUES clear); treated as
              -- offset (0, 0), noted as a limitation in the task's Report.
              q := q + (if wordArgs then 4 else 2)
              let mut a : Int := 16384
              let mut b : Int := 0
              let mut c : Int := 0
              let mut d : Int := 16384
              if flags &&& 0x0008 != 0 then           -- WE_HAVE_A_SCALE
                a := i16 f.data q
                d := a
                q := q + 2
              else if flags &&& 0x0040 != 0 then       -- WE_HAVE_AN_X_AND_Y_SCALE
                a := i16 f.data q
                d := i16 f.data (q + 2)
                q := q + 4
              else if flags &&& 0x0080 != 0 then       -- WE_HAVE_A_TWO_BY_TWO
                a := i16 f.data q
                b := i16 f.data (q + 2)
                c := i16 f.data (q + 4)
                d := i16 f.data (q + 6)
                q := q + 8
              let (sub, rest) := resolvedContours f glyphIndex fuel budget
              budget := rest
              for contour in sub do
                points := points + contour.size
                let mut tc : Array (Int × Int × Bool) := Array.emptyWithCapacity contour.size
                for pt in contour do
                  let nx := roundDiv14 (a * pt.1 + c * pt.2.1) + dx
                  let ny := roundDiv14 (b * pt.1 + d * pt.2.1) + dy
                  tc := tc.push (nx, ny, pt.2.2)
                out := out.push tc
              p := q
              if flags &&& 0x0020 == 0 then break       -- no MORE_COMPONENTS
            else break
          return (out, budget)

/-- Raw quadratic contours of glyph `gid`, in font units: each contour is an
array of `(x, y, onCurve)` points, exactly as `glyf` encodes them (composite
glyphs are resolved and their components' points transformed and
concatenated, matching what `fontTools`' `Glyph.getCoordinates` returns).
`#[]` for `.notdef`-like/empty glyphs, an out-of-range id, or anything the
parser gave up on. Composite recursion gets fuel `8` and a budget of
`compositeBudget` component visits. -/
def rawContours (f : Font) (gid : Nat) : Array (Array (Int × Int × Bool)) :=
  (resolvedContours f gid 8 compositeBudget).1

/-! ## Quadratic contours → cubic `PathCmd`s -/

/-- Trace one contour's implied-on-curve TrueType outline into `PathCmd`s,
using the same exact degree elevation as `Svg.parsePathData`'s `Q` handling:
`c1 = p0 + 2/3(q − p0)`, `c2 = p1 + 2/3(q − p1))`, both divided with
`Int.ediv`. Every quadratic segment between the two anchors on either side of
a run of off-curve points becomes one cubic; a run of two or more
consecutive off-curve points gets an implied on-curve point at each
midpoint. The contour is always closed. -/
def buildContourPath (pts : Array (Int × Int × Bool)) : Array PathCmd := Id.run do
  let n := pts.size
  if n == 0 then return #[]
  let at1 := fun i => pts.getD (i % n) (0, 0, false)
  let mut startX : Int := 0
  let mut startY : Int := 0
  let mut s : Nat := 0
  if (at1 0).2.2 then
    startX := (at1 0).1; startY := (at1 0).2.1; s := 1
  else if (at1 (n - 1)).2.2 then
    startX := (at1 (n - 1)).1; startY := (at1 (n - 1)).2.1; s := 0
  else
    startX := Int.ediv ((at1 (n - 1)).1 + (at1 0).1) 2
    startY := Int.ediv ((at1 (n - 1)).2.1 + (at1 0).2.1) 2
    s := 0
  let mut out : Array PathCmd := #[.moveTo ⟨startX, startY⟩]
  let mut curX := startX
  let mut curY := startY
  let mut haveCtrl := false
  let mut ctrlX : Int := 0
  let mut ctrlY : Int := 0
  for k in [0:n] do
    let pt := at1 (s + k)
    let x := pt.1
    let y := pt.2.1
    if pt.2.2 then
      if haveCtrl then
        let c1x := curX + Int.ediv (2 * (ctrlX - curX)) 3
        let c1y := curY + Int.ediv (2 * (ctrlY - curY)) 3
        let c2x := x + Int.ediv (2 * (ctrlX - x)) 3
        let c2y := y + Int.ediv (2 * (ctrlY - y)) 3
        out := out.push (.cubicTo ⟨c1x, c1y⟩ ⟨c2x, c2y⟩ ⟨x, y⟩)
        haveCtrl := false
      else
        out := out.push (.lineTo ⟨x, y⟩)
      curX := x; curY := y
    else
      if haveCtrl then
        let midX := Int.ediv (ctrlX + x) 2
        let midY := Int.ediv (ctrlY + y) 2
        let c1x := curX + Int.ediv (2 * (ctrlX - curX)) 3
        let c1y := curY + Int.ediv (2 * (ctrlY - curY)) 3
        let c2x := midX + Int.ediv (2 * (ctrlX - midX)) 3
        let c2y := midY + Int.ediv (2 * (ctrlY - midY)) 3
        out := out.push (.cubicTo ⟨c1x, c1y⟩ ⟨c2x, c2y⟩ ⟨midX, midY⟩)
        curX := midX; curY := midY
      ctrlX := x; ctrlY := y
      haveCtrl := true
  if haveCtrl then
    let c1x := curX + Int.ediv (2 * (ctrlX - curX)) 3
    let c1y := curY + Int.ediv (2 * (ctrlY - curY)) 3
    let c2x := startX + Int.ediv (2 * (ctrlX - startX)) 3
    let c2y := startY + Int.ediv (2 * (ctrlY - startY)) 3
    out := out.push (.cubicTo ⟨c1x, c1y⟩ ⟨c2x, c2y⟩ ⟨startX, startY⟩)
  else if curX != startX || curY != startY then
    out := out.push (.lineTo ⟨startX, startY⟩)
  out := out.push .close
  return out

/-- Glyph outline as `PathCmd`s in font units, `y` up as the font encodes it
(no scaling, no flip — that is the renderer's job once text layout lands).
`#[]` for an empty or out-of-range glyph. -/
def outline (f : Font) (gid : Nat) : Array PathCmd := Id.run do
  let mut out : Array PathCmd := #[]
  for c in rawContours f gid do
    out := out ++ buildContourPath c
  return out

/-! ## Top-level parse -/

/-- Parse a TrueType font. `none` for anything this parser cannot make sense
of: too large (over 16 MiB — T91 raised it from 8 MiB for the embedded
Noto Sans SC, 10.4 MB), too small to hold an offset table, an
unrecognised `sfnt` version (only `0x00010000` and `'true'`, i.e. `glyf`-based
TrueType outlines — not `OTTO`/CFF, not a `ttcf` collection), or missing one
of the tables `outline`/`advance`/`rawContours` need (`head`, `maxp`, `hhea`,
`hmtx`, `loca`, `glyf`). `cmap`/`kern`/`GPOS` are optional: their absence
just makes `glyphId`/`kern` return `0`. -/
def parse (bs : ByteArray) : Option Font :=
  if bs.size > 16 * 1024 * 1024 || bs.size < 12 then none
  else
    let version := u32 bs 0
    if version != 0x00010000 && version != 0x74727565 then none
    else
      let numTables := u16 bs 4
      let t := scanTables bs numTables
      match t.head, t.maxp, t.hhea, t.hmtx, t.loca, t.glyf with
      | some (hOff, hLen), some (mOff, mLen), some (heOff, heLen), some (htOff, _),
        some (lOff, _), some (gOff, gLen) =>
        if hLen < 54 || mLen < 6 || heLen < 36 then none
        else
          let unitsPerEm := u16 bs (hOff + 18)
          let indexToLocFormat := if i16 bs (hOff + 50) == 1 then 1 else 0
          let numGlyphs := u16 bs (mOff + 4)
          let maxpVersion := u32 bs mOff
          let maxPointsField := if maxpVersion == 0x00010000 && mLen ≥ 8 then u16 bs (mOff + 6) else 0
          let maxPointsCap := if maxPointsField > 0 then Nat.min maxPointsField 10000 else 10000
          let (cmapOff, cmapFormat) :=
            match t.cmap with
            | some (cOff, cLen) => resolveCmap bs cOff cLen
            | none => (0, 0)
          let (kernPairsOff, kernNPairs) :=
            match t.kernT with
            | some (kOff, kLen) => resolveKern bs kOff kLen
            | none => (0, 0)
          let gposKernSubtables :=
            match t.gpos with
            | some (gpOff, gpLen) => findKernSubtables bs gpOff gpLen
            | none => #[]
          -- `OS/2`-derived metrics, `skrifa::Metrics::new`'s algorithm
          -- (see the `ascent` field docs): `hhea`'s own ascender/descender/
          -- lineGap first, unless `OS/2.fsSelection`'s `USE_TYPO_METRICS`
          -- bit says to prefer the typo metrics, or `hhea`'s pair is `(0,
          -- 0)` (a broken/degenerate font), in which case a non-zero typo
          -- pair, else the Windows ascent/descent, is the fallback.
          let hheaAsc := i16 bs (heOff + 4)
          let hheaDesc := i16 bs (heOff + 6)
          let hheaGap := i16 bs (heOff + 8)
          let (os2Off, os2Len) := match t.os2 with | some p => p | none => (0, 0)
          let os2Present := t.os2.isSome
          let os2Version := if os2Len ≥ 2 then u16 bs os2Off else 0
          let fsSelection := if os2Len ≥ 64 then u16 bs (os2Off + 62) else 0
          let useTypo := fsSelection &&& 0x0080 != 0
          let haveTypo := os2Present && os2Len ≥ 74
          let typoAsc := if haveTypo then i16 bs (os2Off + 68) else 0
          let typoDesc := if haveTypo then i16 bs (os2Off + 70) else 0
          let typoGap := if haveTypo then i16 bs (os2Off + 72) else 0
          let haveWin := os2Present && os2Len ≥ 78
          let winAsc : Int := if haveWin then (u16 bs (os2Off + 74) : Int) else 0
          let winDesc : Int := if haveWin then (u16 bs (os2Off + 76) : Int) else 0
          let (rAscent, rDescent, rLineGap) :=
            if haveTypo && useTypo then (typoAsc, typoDesc, typoGap)
            else if hheaAsc == 0 && hheaDesc == 0 then
              if haveTypo && (typoAsc != 0 || typoDesc != 0) then (typoAsc, typoDesc, typoGap)
              else if haveWin then (winAsc, -winDesc, hheaGap)
              else (hheaAsc, hheaDesc, hheaGap)
            else (hheaAsc, hheaDesc, hheaGap)
          -- `OS/2.sxHeight`/`sCapHeight`: only in version ≥ 2.
          let haveV2 := os2Present && os2Version ≥ 2 && os2Len ≥ 90
          let sxHeight := if haveV2 then i16 bs (os2Off + 86) else 0
          let sCapHeight := if haveV2 then i16 bs (os2Off + 88) else 0
          let xHeightFallback := Int.ediv ((rAscent - rDescent) * 9 + 10) 20
          let rXHeight := if haveV2 && sxHeight > 0 then sxHeight else xHeightFallback
          let rCapHeight := if haveV2 then sCapHeight else 0
          -- `OS/2.ySubscriptYOffset`/`ySuperscriptYOffset`: present in every
          -- `OS/2` version; the generic `unitsPerEm * 5` / `* 2.5` fallback
          -- is only for a font with no `OS/2` table at all.
          let haveSubSup := os2Present && os2Len ≥ 26
          let rSubOff := if haveSubSup then i16 bs (os2Off + 16) else (unitsPerEm : Int) * 5
          let rSupOff :=
            if haveSubSup then i16 bs (os2Off + 24) else Int.ediv ((unitsPerEm : Int) * 5 + 1) 2
          -- `post`: `underlinePosition`/`underlineThickness` sit at a fixed
          -- offset in every table version. usvg's fallbacks (`skrifa`'s, via
          -- `ResolvedFont::load`): `-unitsPerEm/9` and `unitsPerEm/12` when
          -- the table is absent, the latter also when the table's own
          -- thickness is non-positive.
          let (underlinePosition, underlineThickness) :=
            match t.post with
            | some (pOff, pLen) =>
              if pLen ≥ 12 then
                let th := i16 bs (pOff + 10)
                (i16 bs (pOff + 8), if th ≤ 0 then (unitsPerEm : Int) / 12 else th)
              else (-(unitsPerEm : Int) / 9, (unitsPerEm : Int) / 12)
            | none => (-(unitsPerEm : Int) / 9, (unitsPerEm : Int) / 12)
          -- `OS/2`: `yStrikeoutPosition` is a fixed offset since version 0.
          let strikeoutPosition :=
            match t.os2 with
            | some (oOff, oLen) => if oLen ≥ 30 then i16 bs (oOff + 28) else (rAscent - rDescent) * 9 / 40
            | none => (rAscent - rDescent) * 9 / 40
          some {
            unitsPerEm := unitsPerEm
            numGlyphs := numGlyphs
            ascent := rAscent
            descent := rDescent
            lineGap := rLineGap
            xHeight := rXHeight
            capHeight := rCapHeight
            subscriptOffset := rSubOff
            superscriptOffset := rSupOff
            indexToLocFormat := indexToLocFormat
            locaOff := lOff
            glyfOff := gOff
            glyfLen := gLen
            cmapOff := cmapOff
            cmapFormat := cmapFormat
            numberOfHMetrics := u16 bs (heOff + 34)
            hmtxOff := htOff
            maxPointsCap := maxPointsCap
            kernPairsOff := kernPairsOff
            kernNPairs := kernNPairs
            gposKernSubtables := gposKernSubtables
            underlinePosition := underlinePosition
            underlineThickness := underlineThickness
            strikeoutPosition := strikeoutPosition
            data := bs
          }
      | _, _, _, _, _, _ => none

/-! ## Embedding: hex-decoding constants generated by `tests/gen_font_module.py` -/

/-- Nibble value of an ASCII hex digit, or `none`. -/
def hexNibble (c : UInt8) : Option Nat :=
  if 48 ≤ c && c ≤ 57 then some (c.toNat - 48)
  else if 97 ≤ c && c ≤ 102 then some (c.toNat - 97 + 10)
  else if 65 ≤ c && c ≤ 70 then some (c.toNat - 65 + 10)
  else none

/-- Decode a hex string into bytes, most-significant nibble first. Total:
stops at the first invalid character or unpaired trailing digit, returning
whatever was decoded so far — never called on anything but a generated
constant, but total regardless. -/
def hexDecode (s : String) : ByteArray := Id.run do
  let sb := s.toUTF8
  let mut out := ByteArray.emptyWithCapacity (sb.size / 2)
  let mut i := 0
  for _ in [0:sb.size / 2 + 1] do
    if i + 1 < sb.size then
      match hexNibble (at' sb i), hexNibble (at' sb (i + 1)) with
      | some hi, some lo => out := out.push (UInt8.ofNat (hi * 16 + lo)); i := i + 2
      | _, _ => break
    else break
  return out

/-- Decode many hex-string chunks (each of even length) into one `ByteArray`,
identical to `hexDecode` on their concatenation. A large embedded font is
generated as an array of short chunks rather than one giant string literal,
which keeps `lake build` fast — see the Report in
`tasks/T25-font-parser.md`. -/
def hexDecodeChunks (chunks : Array String) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity 0
  for c in chunks do
    out := out.append (hexDecode c)
  return out

/-- Value of a base64 digit (RFC 4648 standard alphabet), or 64 for any
other byte.  A plain `UInt32` rather than an `Option`: this runs once per
character of ~25 MB of embedded fonts, and an `Option` allocates. -/
@[inline] def b64Digit (c : UInt8) : UInt32 :=
  if 65 ≤ c && c ≤ 90 then c.toUInt32 - 65
  else if 97 ≤ c && c ≤ 122 then c.toUInt32 - 71
  else if 48 ≤ c && c ≤ 57 then c.toUInt32 + 4
  else if c == 43 then 62
  else if c == 47 then 63
  else 64

/-- Decode padded base64 into bytes, four characters (three bytes) at a time.
Total: a quad with an invalid character stops decoding, and `=` padding in the
third/fourth place emits only the bytes that precede it (T91: the embedded
fonts are base64, 4/3 of the binary size instead of hex's 2×). -/
def base64Decode (s : String) : ByteArray := Id.run do
  let sb := s.toUTF8
  let mut out := ByteArray.emptyWithCapacity (sb.size / 4 * 3)
  for q in [0:sb.size / 4] do
    let i := 4 * q
    let a := b64Digit (at' sb i)
    let b := b64Digit (at' sb (i + 1))
    let c := b64Digit (at' sb (i + 2))
    let d := b64Digit (at' sb (i + 3))
    if a ≥ 64 || b ≥ 64 then break
    out := out.push ((a <<< 2 ||| b >>> 4).toUInt8)
    if c ≥ 64 then break
    out := out.push (((b &&& 15) <<< 4 ||| c >>> 2).toUInt8)
    if d ≥ 64 then break
    out := out.push (((c &&& 3) <<< 6 ||| d).toUInt8)
  return out

/-- `base64Decode` over chunks, each a whole number of quads. -/
def base64DecodeChunks (chunks : Array String) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity 0
  for c in chunks do
    out := out.append (base64Decode c)
  return out

/-- A font's codepoint coverage as sorted, disjoint, inclusive ranges, decoded
from the generator's packed form: 6 bytes per range (24-bit big-endian first,
then last codepoint), base64. -/
def decodeRanges (s : String) : Array (Nat × Nat) := Id.run do
  let bs := base64Decode s
  let mut out : Array (Nat × Nat) := Array.emptyWithCapacity (bs.size / 6)
  for k in [0:bs.size / 6] do
    let i := 6 * k
    out := out.push (u16 bs i * 256 + u8 bs (i + 2), u16 bs (i + 3) * 256 + u8 bs (i + 5))
  return out

/-- Whether `cp` lies in one of the sorted ranges: binary search, 32 halvings
cover any array a `ByteArray` can produce. -/
def inRanges (rs : Array (Nat × Nat)) (cp : Nat) : Bool := Id.run do
  let mut lo := 0
  let mut hi := rs.size
  for _ in [0:32] do
    if lo ≥ hi then break
    let mid := (lo + hi) / 2
    let (a, b) := rs.getD mid (0, 0)
    if cp < a then hi := mid
    else if cp > b then lo := mid + 1
    else return true
  return false

end Font
end LeanSvg
