import LeanSvg.Bytes
import LeanSvg.Inflate
import LeanSvg.Brotli
import LeanSvg.Font

/-!
# WOFF 1.0 and WOFF 2.0 to sfnt (T105)

`Woff.toSfnt bs` turns a font file into the plain sfnt (TrueType/OpenType
table directory + tables) that `Font.parse` reads:

- an sfnt (`0x00010000`, `true`, `OTTO`) is returned as is;
- WOFF 1.0 (`wOFF`): each table is stored or zlib-compressed
  (`Inflate.zlib`, to exactly its declared `origLength`);
- WOFF 2.0 (`wOF2`): one Brotli stream (`Brotli.decompress`, to exactly the
  sum of the table lengths the directory declares) holding every table, with
  the `glyf`/`loca` transform (version 0) and the `hmtx` transform (version
  1) undone (`reconstructGlyf`, `reconstructHmtx`).  Font collections
  (`ttcf`) are rejected.

The result is rebuilt as a fresh sfnt with a long (`u32`) `loca` whenever
`loca` was reconstructed (and `head.indexToLocFormat` patched to match).
Table checksums are computed but never checked on input, as browsers do.

Bounded: every declared size is checked against `maxFontBytes` (16 MB)
before anything is allocated or decompressed, every stream read is checked
against its stream's end, and every loop runs over a declared count that has
already been checked against the bytes that would back it.  Anything
inconsistent is `none`.
-/

namespace LeanSvg.Woff

open Bytes (at')
open Font (u8 u16 u32 i16)

/-- The largest font (compressed input, any decompressed table set, or the
rebuilt sfnt) this module handles: the same 16 MB as `Font.parseSized`. -/
def maxFontBytes : Nat := 16 * 1024 * 1024

def tagOf (s : String) : Nat :=
  s.toUTF8.foldl (fun acc b => acc * 256 + b.toNat) 0

def tagGlyf : Nat := tagOf "glyf"
def tagLoca : Nat := tagOf "loca"
def tagHmtx : Nat := tagOf "hmtx"
def tagHead : Nat := tagOf "head"
def tagHhea : Nat := tagOf "hhea"
def tagMaxp : Nat := tagOf "maxp"

/-! ## Writing big-endian values -/

def pushU16 (b : ByteArray) (v : Nat) : ByteArray :=
  (b.push (v / 256 % 256).toUInt8).push (v % 256).toUInt8

def pushU32 (b : ByteArray) (v : Nat) : ByteArray :=
  pushU16 (pushU16 b (v / 65536 % 65536)) (v % 65536)

/-- An `i16`, two's complement (the caller checks the range). -/
def pushI16 (b : ByteArray) (v : Int) : ByteArray :=
  pushU16 b (if v < 0 then (v + 65536).toNat else v.toNat)

def pad4 (b : ByteArray) : ByteArray := Id.run do
  let mut o := b
  for _ in [0:3] do
    if o.size % 4 != 0 then o := o.push 0
  return o

/-- The sfnt table checksum: the sum of its big-endian `u32` words. -/
def checksum (t : ByteArray) : Nat := Id.run do
  let mut s := 0
  for k in [0:(t.size + 3) / 4] do
    s := (s + u32 t (4 * k)) % 4294967296
  return s

/-- An sfnt from `(tag, data)` tables, in the given order. -/
def buildSfnt (flavor : Nat) (tables : Array (Nat × ByteArray)) : ByteArray := Id.run do
  let n := tables.size
  let mut es := 0
  for _ in [0:16] do
    if (1 <<< (es + 1)) ≤ n then es := es + 1
  let sr := 16 * (1 <<< es)
  let mut out := pushU32 ByteArray.empty flavor
  out := pushU16 out n
  out := pushU16 out sr
  out := pushU16 out es
  out := pushU16 out (if n * 16 ≥ sr then n * 16 - sr else 0)
  let mut off := 12 + 16 * n
  for (tag, d) in tables do
    out := pushU32 out tag
    out := pushU32 out (checksum d)
    out := pushU32 out off
    out := pushU32 out d.size
    off := off + (d.size + 3) / 4 * 4
  for (_, d) in tables do
    out := pad4 (out ++ d)
  return out

/-! ## WOFF 1.0 -/

/-- WOFF 1.0 to sfnt. -/
def woff1 (bs : ByteArray) : Option ByteArray := Id.run do
  if bs.size < 44 then return none
  let flavor := u32 bs 4
  let numTables := u16 bs 12
  if u32 bs 16 > maxFontBytes || 44 + 20 * numTables > bs.size then return none
  let mut tables : Array (Nat × ByteArray) := #[]
  let mut total := 0
  for i in [0:numTables] do
    let d := 44 + 20 * i
    let tag := u32 bs d
    let off := u32 bs (d + 4)
    let compLen := u32 bs (d + 8)
    let origLen := u32 bs (d + 12)
    total := total + origLen
    if off + compLen > bs.size || compLen > origLen || total > maxFontBytes then return none
    let raw := bs.extract off (off + compLen)
    if compLen == origLen then tables := tables.push (tag, raw)
    else match Inflate.zlib raw origLen with
      | some t => tables := tables.push (tag, t)
      | none => return none
  return some (buildSfnt flavor tables)

/-! ## WOFF 2.0: primitives -/

/-- The 63 table tags a WOFF 2.0 directory entry can name by index. -/
def knownTags : Array Nat := #[
  "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post", "cvt ", "fpgm", "glyf", "loca",
  "prep", "CFF ", "VORG", "EBDT", "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea",
  "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH", "CBDT", "CBLC", "COLR", "CPAL",
  "SVG ", "sbix", "acnt", "avar", "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
  "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop", "trak", "Zapf", "Silf", "Glat",
  "Gloc", "Feat", "Sill"].map tagOf

/-- `UIntBase128` at `off`: the value and the offset after it; `none` for a
leading zero byte, more than five bytes, or a value past 32 bits. -/
def base128 (bs : ByteArray) (off : Nat) : Option (Nat × Nat) := Id.run do
  let mut acc := 0
  for i in [0:5] do
    let b := u8 bs (off + i)
    if off + i ≥ bs.size || (i == 0 && b == 0x80) || acc ≥ (1 <<< 25) then return none
    acc := acc * 128 + b % 128
    if b < 128 then return some (acc, off + i + 1)
  return none

/-- `255UInt16` at `off`: the value and the offset after it. -/
def read255 (bs : ByteArray) (off : Nat) : Nat × Nat :=
  let c := u8 bs off
  if c == 253 then (u16 bs (off + 1), off + 3)
  else if c == 255 then (u8 bs (off + 1) + 253, off + 2)
  else if c == 254 then (u8 bs (off + 1) + 506, off + 2)
  else (c, off + 1)

/-- One point's `(dx, dy)` from its flag and the glyph stream at `off`, and
the number of bytes it took (WOFF 2.0 section 5.2, triplet encoding). -/
def triplet (bs : ByteArray) (flag off : Nat) : Int × Int × Nat :=
  let sgn := fun (f : Nat) (v : Nat) => if f % 2 == 1 then (v : Int) else -(v : Int)
  let b0 := u8 bs off
  let b1 := u8 bs (off + 1)
  let b2 := u8 bs (off + 2)
  let b3 := u8 bs (off + 3)
  if flag < 10 then (0, sgn flag (((flag &&& 14) <<< 7) + b0), 1)
  else if flag < 20 then (sgn flag ((((flag - 10) &&& 14) <<< 7) + b0), 0, 1)
  else if flag < 84 then
    let f := flag - 20
    (sgn flag (1 + (f &&& 0x30) + (b0 >>> 4)), sgn (flag >>> 1) (1 + ((f &&& 0x0C) <<< 2) + (b0 &&& 0x0F)), 1)
  else if flag < 120 then
    let f := flag - 84
    (sgn flag (1 + ((f / 12) <<< 8) + b0), sgn (flag >>> 1) (1 + (((f % 12) >>> 2) <<< 8) + b1), 2)
  else if flag < 124 then
    (sgn flag ((b0 <<< 4) + (b1 >>> 4)), sgn (flag >>> 1) (((b1 &&& 0x0F) <<< 8) + b2), 3)
  else (sgn flag ((b0 <<< 8) + b1), sgn (flag >>> 1) ((b2 <<< 8) + b3), 4)

/-- Whether `v` fits an `i16`. -/
def fitsI16 (v : Int) : Bool := -32768 ≤ v && v ≤ 32767

/-! ## WOFF 2.0: the `glyf`/`loca` transform -/

/-- A simple glyph's record in plain `glyf` form: the contour end points, the
instructions, one flag byte per point (on-curve bit only) and word deltas. -/
def encodeSimple (endPts : Array Nat) (instr : ByteArray) (pts : Array (Int × Int × Bool))
    (box : Int × Int × Int × Int) : Option ByteArray := Id.run do
  let (x0, y0, x1, y1) := box
  let mut o := pushU16 ByteArray.empty endPts.size
  for v in [x0, y0, x1, y1] do
    if !fitsI16 v then return none
    o := pushI16 o v
  for e in endPts do o := pushU16 o e
  o := pushU16 o instr.size
  o := o ++ instr
  for (_, _, on) in pts do o := o.push (if on then 1 else 0)
  let mut px : Int := 0
  for (x, _, _) in pts do
    if !fitsI16 (x - px) then return none
    o := pushI16 o (x - px)
    px := x
  let mut py : Int := 0
  for (_, y, _) in pts do
    if !fitsI16 (y - py) then return none
    o := pushI16 o (y - py)
    py := y
  return some o

/-- Undo the WOFF 2.0 `glyf` transform (section 5.1): the plain `glyf`
table, a long `loca` for it, and every glyph's `xMin` (for `hmtx`). -/
def reconstructGlyf (t : ByteArray) : Option (ByteArray × ByteArray × Array Int) := Id.run do
  if t.size < 36 then return none
  let optionFlags := u16 t 2
  let numGlyphs := u16 t 4
  let sizes := (List.range 7).toArray.map (fun k => u32 t (8 + 4 * k))
  let mut starts : Array Nat := #[]
  let mut p := 36
  for s in sizes do
    starts := starts.push p
    p := p + s
  let streamsEnd := p
  if streamsEnd > t.size then return none
  if optionFlags % 2 == 1 && streamsEnd + (numGlyphs + 7) / 8 > t.size then return none
  let endOf := fun (k : Nat) => starts.getD k 0 + sizes.getD k 0
  let ncS := starts.getD 0 0
  if sizes.getD 0 0 < 2 * numGlyphs then return none
  let bmS := starts.getD 5 0
  let bmLen := (numGlyphs + 31) / 32 * 4
  if sizes.getD 5 0 < bmLen then return none
  let mut pP := starts.getD 1 0
  let mut pF := starts.getD 2 0
  let mut pG := starts.getD 3 0
  let mut pC := starts.getD 4 0
  let mut pB := bmS + bmLen
  let mut pI := starts.getD 6 0
  let mut glyf := ByteArray.empty
  let mut loca := pushU32 ByteArray.empty 0
  let mut xMins : Array Int := Array.emptyWithCapacity numGlyphs
  for i in [0:numGlyphs] do
    let nc := i16 t (ncS + 2 * i)
    let hasBox := (u8 t (bmS + i / 8)) &&& (0x80 >>> (i % 8)) != 0
    if nc == 0 then
      if hasBox then return none
      xMins := xMins.push 0
    else if nc < 0 then
      -- composite: the components are copied as they are
      if nc != -1 || !hasBox || pB + 8 > endOf 5 then return none
      let box := t.extract pB (pB + 8)
      xMins := xMins.push (i16 t pB)
      pB := pB + 8
      let c0 := pC
      let mut more := true
      let mut instr := false
      for _ in [0:sizes.getD 4 0 + 1] do
        if !more then break
        let fl := u16 t pC
        let argLen := if fl % 2 == 1 then 4 else 2
        let scLen := if fl &&& 0x8 != 0 then 2 else if fl &&& 0x40 != 0 then 4
          else if fl &&& 0x80 != 0 then 8 else 0
        pC := pC + 4 + argLen + scLen
        if pC > endOf 4 then return none
        more := fl &&& 0x20 != 0
        if fl &&& 0x100 != 0 then instr := true
      if more then return none
      let mut g := pushI16 ByteArray.empty (-1)
      g := g ++ box ++ t.extract c0 pC
      if instr then
        let (n, pG') := read255 t pG
        pG := pG'
        if pG > endOf 3 || pI + n > endOf 6 then return none
        g := pushU16 g n ++ t.extract pI (pI + n)
        pI := pI + n
      glyf := pad4 (glyf ++ g)
    else
      -- simple: contour end points, flags, triplets, instructions
      let mut endPts : Array Nat := #[]
      let mut total := 0
      for _ in [0:nc.toNat] do
        let (n, pP') := read255 t pP
        pP := pP'
        total := total + n
        if total == 0 || pP > endOf 1 then return none
        endPts := endPts.push (total - 1)
      if pF + total > endOf 2 || total > 65535 then return none
      let mut pts : Array (Int × Int × Bool) := Array.emptyWithCapacity total
      let mut x : Int := 0
      let mut y : Int := 0
      for k in [0:total] do
        let f := u8 t (pF + k)
        let (dx, dy, len) := triplet t (f % 128) pG
        pG := pG + len
        if pG > endOf 3 then return none
        x := x + dx
        y := y + dy
        pts := pts.push (x, y, f < 128)
      pF := pF + total
      let (n, pG') := read255 t pG
      pG := pG'
      if pG > endOf 3 || pI + n > endOf 6 then return none
      let instr := t.extract pI (pI + n)
      pI := pI + n
      let box : Int × Int × Int × Int ←
        if hasBox then
          if pB + 8 > endOf 5 then return none
          let b := (i16 t pB, i16 t (pB + 2), i16 t (pB + 4), i16 t (pB + 6))
          pB := pB + 8
          pure b
        else pure (pts.foldl (fun (a, b, c, d) (px, py, _) => (min a px, min b py, max c px, max d py))
            ((pts.getD 0 (0, 0, false)).1, (pts.getD 0 (0, 0, false)).2.1,
             (pts.getD 0 (0, 0, false)).1, (pts.getD 0 (0, 0, false)).2.1))
      xMins := xMins.push box.1
      match encodeSimple endPts instr pts box with
      | some g => glyf := pad4 (glyf ++ g)
      | none => return none
    if glyf.size > maxFontBytes then return none
    loca := pushU32 loca glyf.size
  return some (glyf, loca, xMins)

/-- Undo the WOFF 2.0 `hmtx` transform (section 5.4): the omitted left side
bearings are the glyphs' `xMin`s. -/
def reconstructHmtx (t : ByteArray) (numGlyphs nHM : Nat) (xMins : Array Int) : Option ByteArray := Id.run do
  let fl := u8 t 0
  if fl &&& 0xFC != 0 || nHM == 0 || nHM > numGlyphs then return none
  let hasProp := fl % 2 == 0
  let hasMono := fl &&& 2 == 0
  let need := 1 + 2 * nHM + (if hasProp then 2 * nHM else 0) + (if hasMono then 2 * (numGlyphs - nHM) else 0)
  if t.size < need then return none
  let lsbS := 1 + 2 * nHM
  let monoS := lsbS + (if hasProp then 2 * nHM else 0)
  let mut o := ByteArray.empty
  for i in [0:nHM] do
    o := pushU16 o (u16 t (1 + 2 * i))
    o := pushI16 o (if hasProp then i16 t (lsbS + 2 * i) else xMins.getD i 0)
  for j in [0:numGlyphs - nHM] do
    o := pushI16 o (if hasMono then i16 t (monoS + 2 * j) else xMins.getD (nHM + j) 0)
  return some o

/-- Every glyph's `xMin` from a plain `glyf` and a long `loca`. -/
def xMinsOf (glyf loca : ByteArray) (numGlyphs : Nat) : Array Int := Id.run do
  let mut out : Array Int := Array.emptyWithCapacity numGlyphs
  for i in [0:numGlyphs] do
    let o0 := u32 loca (4 * i)
    let o1 := u32 loca (4 * i + 4)
    out := out.push (if o1 > o0 then i16 glyf (o0 + 2) else 0)
  return out

/-- A plain `loca` of either format as a long one. -/
def longLoca (loca : ByteArray) (short : Bool) : ByteArray := Id.run do
  if !short then return loca
  let mut o := ByteArray.empty
  for k in [0:loca.size / 2] do
    o := pushU32 o (2 * u16 loca (2 * k))
  return o

/-! ## WOFF 2.0 -/

/-- WOFF 2.0 to sfnt. -/
def woff2 (bs : ByteArray) : Option ByteArray := Id.run do
  if bs.size < 48 then return none
  let flavor := u32 bs 4
  let numTables := u16 bs 12
  let compLen := u32 bs 20
  if flavor == tagOf "ttcf" || u32 bs 16 > maxFontBytes || numTables == 0 then return none
  -- the table directory: (tag, transformed, length in the stream)
  let mut dir : Array (Nat × Bool × Nat) := #[]
  let mut p := 48
  let mut total := 0
  for _ in [0:numTables] do
    if p ≥ bs.size then return none
    let fl := u8 bs p
    p := p + 1
    let tag := if fl % 64 == 63 then u32 bs p else knownTags.getD (fl % 64) 0
    if fl % 64 == 63 then p := p + 4
    let tv := fl / 64
    let some (origLen, p1) := base128 bs p | return none
    p := p1
    let isGL := tag == tagGlyf || tag == tagLoca
    let transformed := if isGL then tv == 0 else tv != 0
    if (isGL && tv != 0 && tv != 3) || (!isGL && tv != 0 && !(tag == tagHmtx && tv == 1)) then
      return none
    let mut len := origLen
    if transformed then
      let some (tl, p2) := base128 bs p | return none
      p := p2
      len := tl
      if tag == tagLoca && tl != 0 then return none
    total := total + len
    if total > maxFontBytes || origLen > maxFontBytes then return none
    dir := dir.push (tag, transformed, len)
  if p + compLen > bs.size then return none
  let some data := Brotli.decompress (bs.extract p (p + compLen)) total | return none
  -- the tables, sliced out of the stream
  let mut raw : Array (Nat × Bool × ByteArray) := #[]
  let mut q := 0
  for (tag, tr, len) in dir do
    raw := raw.push (tag, tr, data.extract q (q + len))
    q := q + len
  let find := fun (tag : Nat) => raw.find? (fun e => e.1 == tag)
  let glyfT := find tagGlyf
  let locaT := find tagLoca
  let glyfTr := (glyfT.map (·.2.1)).getD false
  if glyfTr != (locaT.map (·.2.1)).getD false then return none
  let numGlyphs := u16 ((find tagMaxp).map (·.2.2) |>.getD ByteArray.empty) 4
  let nHM := u16 ((find tagHhea).map (·.2.2) |>.getD ByteArray.empty) 34
  -- `glyf`/`loca`: rebuilt, with a long `loca`
  let mut newGlyf : Option ByteArray := none
  let mut newLoca : Option ByteArray := none
  let mut xMins : Array Int := #[]
  if glyfTr then
    let some (g, l, xs) := reconstructGlyf ((glyfT.map (·.2.2)).getD ByteArray.empty) | return none
    newGlyf := some g
    newLoca := some l
    xMins := xs
  let hmtxT := find tagHmtx
  let mut newHmtx : Option ByteArray := none
  if (hmtxT.map (·.2.1)).getD false then
    if !glyfTr then
      match glyfT, locaT, find tagHead with
      | some (_, _, g), some (_, _, l), some (_, _, h) =>
        xMins := xMinsOf g (longLoca l (i16 h 50 != 1)) numGlyphs
      | _, _, _ => return none
    match reconstructHmtx ((hmtxT.map (·.2.2)).getD ByteArray.empty) numGlyphs nHM xMins with
    | some h => newHmtx := some h
    | none => return none
  let mut tables : Array (Nat × ByteArray) := #[]
  for (tag, _, d) in raw do
    let d' :=
      if tag == tagGlyf then newGlyf.getD d
      else if tag == tagLoca then newLoca.getD d
      else if tag == tagHmtx then newHmtx.getD d
      else if tag == tagHead && glyfTr then
        -- `indexToLocFormat` := 1 (long), to match the rebuilt `loca`
        if d.size ≥ 54 then (d.extract 0 50).push 0 |>.push 1 |>.append (d.extract 52 d.size) else d
      else d
    tables := tables.push (tag, d')
  let out := buildSfnt flavor tables
  if out.size > maxFontBytes then return none
  return some out

/-- Any supported font file as an sfnt: WOFF 2.0, WOFF 1.0, or an sfnt as
is (`Font.parse` decides whether it can read it). -/
def toSfnt (bs : ByteArray) : Option ByteArray :=
  if bs.size > maxFontBytes then none
  else
    let magic := u32 bs 0
    if magic == tagOf "wOF2" then woff2 bs
    else if magic == tagOf "wOFF" then woff1 bs
    else some bs

/-- A font file of any supported format, parsed. -/
def parseFont (bs : ByteArray) : Option Font := (toSfnt bs).bind Font.parse

end LeanSvg.Woff
