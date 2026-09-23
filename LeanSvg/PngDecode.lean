import LeanSvg.ImageData
import LeanSvg.Bytes
import LeanSvg.Png
import LeanSvg.Inflate

/-!
# PNG decoder (see `LeanSvg/ImageData.lean` for the contract)

Matches what resvg 0.48.1 gets from `tiny_skia::Pixmap::decode_png`: the `png`
crate (0.18) with `Transformations::normalize_to_color8()` (EXPAND | STRIP_16),
then widened to RGBA8. Straight alpha here; premultiplying is the renderer's.

* Chunks are walked up to the first `IDAT`; everything after the `IDAT` run is
  never read (the crate only needs the next chunk's length and type to see the
  run end, so those 8 bytes must exist).
* CRC-32 is checked on every chunk read. A bad CRC on a critical chunk (`IHDR`,
  `PLTE`, `IDAT`) is `none`; on an ancillary chunk the chunk is skipped, as the
  crate does (`skip_ancillary_crc_failures`). Adler-32 is not checked
  (`ignore_adler32`, the crate default).
* `tRNS` is kept only if valid for the colour type, first of its kind, and
  before `IDAT` (else ignored, as the crate ignores benign ancillary errors).
  Gray/RGB at depth ≤ 8 compare against the low byte(s) of the tRNS values;
  depth 16 compares all bytes (so a tRNS of the wrong length never matches).
  Palette tRNS longer than the palette is ignored; indices past the palette are
  opaque black.
* 16 → 8 bits keeps the high byte (`STRIP_16`); gray at depth < 8 scales by
  `255 / (2^d - 1)`.
* Size: `w * h > maxPixels` is `none` before anything is inflated, and the
  inflater is capped at the exact filtered-stream size.
-/

namespace LeanSvg.PngDecode

open Bytes (at')

@[inline] def be32 (b : ByteArray) (i : Nat) : Nat :=
  ((at' b i).toNat <<< 24) ||| ((at' b (i + 1)).toNat <<< 16) |||
    ((at' b (i + 2)).toNat <<< 8) ||| (at' b (i + 3)).toNat

/-- Chunk type as a big-endian 32-bit number. -/
def tag (s : String) : Nat := be32 s.toUTF8 0

structure Hdr where
  w : Nat
  h : Nat
  depth : Nat
  ctype : Nat
  interlace : Bool

/-- Samples per pixel for a valid colour type. -/
def channels (ct : Nat) : Nat :=
  if ct == 2 then 3 else if ct == 4 then 2 else if ct == 6 then 4 else 1

def validDepth (ct d : Nat) : Bool :=
  if ct == 0 then d == 1 || d == 2 || d == 4 || d == 8 || d == 16
  else if ct == 3 then d == 1 || d == 2 || d == 4 || d == 8
  else if ct == 2 || ct == 4 || ct == 6 then d == 8 || d == 16
  else false

def parseIhdr (b : ByteArray) (p : Nat) : Option Hdr :=
  let w := be32 b p
  let h := be32 b (p + 4)
  let d := (at' b (p + 8)).toNat
  let ct := (at' b (p + 9)).toNat
  let il := (at' b (p + 12)).toNat
  if w == 0 || h == 0 || !validDepth ct d || at' b (p + 10) != 0 || at' b (p + 11) != 0 || il > 1
  then none else some ⟨w, h, d, ct, il == 1⟩

/-- What the chunks before the first `IDAT` say. -/
structure Meta where
  hdr : Hdr
  plte : Option ByteArray
  trns : Option ByteArray

/-- Walk chunks from `pos` to the first `IDAT`; returns the metadata and the
`IDAT`'s offset. Each chunk is at least 12 bytes, so `b.size / 12 + 1` fuel
always suffices. -/
def walk (b : ByteArray) : Nat → Nat → Option Hdr → Option ByteArray → Option ByteArray →
    Option (Meta × Nat)
  | 0, _, _, _, _ => none
  | fuel + 1, pos, hdr, plte, trns =>
    let len := be32 b pos
    let typ := be32 b (pos + 4)
    let data := pos + 8
    let next := data + len + 4
    if len > 0x7fffffff || next > b.size then none else
    let crcOk := Png.crc32Range b (pos + 4) (data + len) == be32 b (data + len)
    let critical := (at' b (pos + 4)).toNat &&& 0x20 == 0
    match hdr with
    | none =>
      if typ != tag "IHDR" || len != 13 || !crcOk then none
      else match parseIhdr b data with
        | none => none
        | some hd => walk b fuel next (some hd) plte trns
    | some hd =>
      if typ == tag "IDAT" then some (⟨hd, plte, trns⟩, pos)
      else if critical then
        -- IHDR again, IEND before data, an unknown critical chunk, or a bad PLTE.
        if typ != tag "PLTE" || len < 3 || len > 768 || !crcOk || plte.isSome then none
        else walk b fuel next hdr (some (b.extract data (data + len))) trns
      else if typ == tag "fdAT" then none
      else if typ == tag "tRNS" && crcOk && len ≤ 256 && trns.isNone &&
          ((hd.ctype == 0 && len ≥ 2) || (hd.ctype == 2 && len ≥ 6) ||
           (hd.ctype == 3 && plte.isSome)) then
        walk b fuel next hdr plte (some (b.extract data (data + len)))
      else walk b fuel next hdr plte trns

/-- Concatenated payload of the `IDAT` run starting at `pos`. Needs the
following chunk's length and type, like the crate. -/
def idats (b : ByteArray) : Nat → Nat → ByteArray → Option ByteArray
  | 0, _, _ => none
  | fuel + 1, pos, acc =>
    if pos + 8 > b.size then none
    else if be32 b (pos + 4) != tag "IDAT" then some acc
    else
      let len := be32 b pos
      let data := pos + 8
      if len > 0x7fffffff || data + len + 4 > b.size ||
          Png.crc32Range b (pos + 4) (data + len) != be32 b (data + len) then none
      else idats b fuel (data + len + 4) (acc ++ b.extract data (data + len))

/-- Adam7 passes as `(x0, y0, dx, dy)`; a non-interlaced image is one pass. -/
def passes (interlace : Bool) : Array (Nat × Nat × Nat × Nat) :=
  if interlace then
    #[(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
  else #[(0, 0, 1, 1)]

/-- Pixels of a pass along one axis of length `n`. -/
@[inline] def passLen (n o d : Nat) : Nat := if n > o then (n - o + d - 1) / d else 0

/-- Adam7 pass of pixel `(x, y)`, indexed by `(y % 8) * 8 + x % 8`. -/
def adam7Pass : Array Nat := Id.run do
  let mut t := Array.replicate 64 0
  let ps := passes true
  for p in [0:7] do
    let (x0, y0, dx, dy) := ps.getD p (0, 0, 1, 1)
    for y in [0:8] do
      for x in [0:8] do
        if x % dx == x0 && y % dy == y0 then t := t.setIfInBounds (y * 8 + x) p
  return t

@[inline] def paeth (a b c : Nat) : Nat :=
  let pa := if b ≥ c then b - c else c - b
  let pb := if a ≥ c then a - c else c - a
  let pc := if a + b ≥ 2 * c then a + b - 2 * c else 2 * c - (a + b)
  if pa ≤ pb && pa ≤ pc then a else if pb ≤ pc then b else c

/-- Undo the row filters of every pass: `z` is the inflated stream (one filter
byte per row), the result the raw rows back to back. `none` on a filter type
above 4. -/
def unfilter (z : ByteArray) (rows : Array (Nat × Nat)) (bpp : Nat) : Option ByteArray := Id.run do
  let mut raw := ByteArray.emptyWithCapacity z.size
  let mut fo := 0
  for (ph, rb) in rows do
    for y in [0:ph] do
      let f := at' z fo
      if f > 4 then return none
      let rs := raw.size
      for i in [0:rb] do
        let x := at' z (fo + 1 + i)
        let a := if i ≥ bpp then at' raw (rs + i - bpp) else 0
        let up := if y > 0 then at' raw (rs + i - rb) else 0
        let v : UInt8 :=
          if f == 0 then x
          else if f == 1 then x + a
          else if f == 2 then x + up
          else if f == 3 then x + ((a.toNat + up.toNat) / 2).toUInt8
          else
            let c := if y > 0 && i ≥ bpp then at' raw (rs + i - rb - bpp) else 0
            x + (paeth a.toNat up.toNat c.toNat).toUInt8
        raw := raw.push v
      fo := fo + 1 + rb
  return some raw

/-- Everything the per-pixel conversion needs. `key` is the tRNS colour in
sample units (gray, or `r <<< 32 ||| g <<< 16 ||| b`), or `noKey`. -/
structure Fmt where
  ctype : Nat
  depth : Nat
  key : Nat
  pal : ByteArray   -- 256 RGBA entries

def noKey : Nat := 1 <<< 48

/-- The tRNS colour key as the crate compares it (see the module doc). -/
def trnsKey (ct d : Nat) (t : Option ByteArray) : Nat :=
  match t with
  | none => noKey
  | some t =>
    let byte (i : Nat) := (at' t i).toNat
    if ct == 0 then
      if d < 16 then byte 1 else if t.size == 2 then byte 0 * 256 + byte 1 else noKey
    else if ct == 2 then
      if d < 16 then (byte 1 <<< 32) ||| (byte 3 <<< 16) ||| byte 5
      else if t.size == 6 then
        ((byte 0 * 256 + byte 1) <<< 32) ||| ((byte 2 * 256 + byte 3) <<< 16) ||| (byte 4 * 256 + byte 5)
      else noKey
    else noKey

/-- 256-entry RGBA palette: PLTE colours, tRNS alphas (ignored whole if longer
than the palette), opaque black past the end. -/
def palette (plte : ByteArray) (trns : Option ByteArray) : ByteArray := Id.run do
  let n := plte.size / 3
  let t := match trns with
    | some t => if t.size ≤ n then t else ByteArray.empty
    | none => ByteArray.empty
  let mut out := ByteArray.emptyWithCapacity 1024
  for i in [0:256] do
    if i < n then
      out := out.push (at' plte (3 * i)) |>.push (at' plte (3 * i + 1)) |>.push (at' plte (3 * i + 2))
        |>.push (if i < t.size then at' t i else 255)
    else out := out.push 0 |>.push 0 |>.push 0 |>.push 255
  return out

/-- Sample `c` of pixel `x` in the raw row at `rs`, at the image's depth. -/
@[inline] def sample (raw : ByteArray) (d ch rs x c : Nat) : Nat :=
  if d == 8 then (at' raw (rs + x * ch + c)).toNat
  else if d == 16 then
    let i := rs + 2 * (x * ch + c)
    (at' raw i).toNat * 256 + (at' raw (i + 1)).toNat
  else
    let bit := x * d
    ((at' raw (rs + bit / 8)).toNat >>> (8 - d - bit % 8)) % (1 <<< d)

/-- A sample as 8 bits: high byte of 16, scaled up from 1/2/4. -/
@[inline] def to8 (d v : Nat) : UInt8 :=
  if d == 16 then (v >>> 8).toUInt8
  else if d == 8 then v.toUInt8
  else (v * (255 / ((1 <<< d) - 1))).toUInt8

/-- Push pixel `x` of the raw row at `rs` as RGBA8. -/
@[inline] def pushPx (f : Fmt) (raw : ByteArray) (rs x : Nat) (out : ByteArray) : ByteArray :=
  let d := f.depth
  if f.ctype == 3 then
    let i := 4 * sample raw d 1 rs x 0
    out.push (at' f.pal i) |>.push (at' f.pal (i + 1)) |>.push (at' f.pal (i + 2))
      |>.push (at' f.pal (i + 3))
  else if f.ctype == 0 then
    let v := sample raw d 1 rs x 0
    let g := to8 d v
    out.push g |>.push g |>.push g |>.push (if v == f.key then 0 else 255)
  else if f.ctype == 2 then
    let r := sample raw d 3 rs x 0
    let g := sample raw d 3 rs x 1
    let b := sample raw d 3 rs x 2
    let a : UInt8 := if (r <<< 32) ||| (g <<< 16) ||| b == f.key then 0 else 255
    out.push (to8 d r) |>.push (to8 d g) |>.push (to8 d b) |>.push a
  else if f.ctype == 4 then
    let g := to8 d (sample raw d 2 rs x 0)
    out.push g |>.push g |>.push g |>.push (to8 d (sample raw d 2 rs x 1))
  else
    out.push (to8 d (sample raw d 4 rs x 0)) |>.push (to8 d (sample raw d 4 rs x 1))
      |>.push (to8 d (sample raw d 4 rs x 2)) |>.push (to8 d (sample raw d 4 rs x 3))

/-- Decode to `(w, h, rgba)`; `decode` then checks the size contract. -/
def decodeRaw (b : ByteArray) : Option (Nat × Nat × ByteArray) := do
  let sig : List Nat := [137, 80, 78, 71, 13, 10, 26, 10]
  if (List.range 8).any (fun i => (at' b i).toNat != sig.getD i 0) then none
  let (m, pos) ← walk b (b.size / 12 + 1) 8 none none none
  let hd := m.hdr
  let (w, h) := (hd.w, hd.h)
  if w * h > ImageData.maxPixels then none
  -- The crate needs a PLTE for colour type 3 (and panics on a ragged one).
  let plte := m.plte.getD ByteArray.empty
  if hd.ctype == 3 && (m.plte.isNone || plte.size % 3 != 0) then none
  let ch := channels hd.ctype
  let bpp := Nat.max 1 (ch * hd.depth / 8)
  let ps := passes hd.interlace
  -- Per pass: (rows, row bytes, raw offset); empty passes have no rows.
  let mut rows : Array (Nat × Nat) := #[]
  let mut offs : Array Nat := #[]
  let mut rawSize := 0
  let mut zSize := 0
  for (x0, y0, dx, dy) in ps do
    let pw := passLen w x0 dx
    let ph := if pw == 0 then 0 else passLen h y0 dy
    let rb := (pw * ch * hd.depth + 7) / 8
    rows := rows.push (ph, rb)
    offs := offs.push rawSize
    rawSize := rawSize + ph * rb
    zSize := zSize + ph * (1 + rb)
  let z ← Inflate.zlib (← idats b (b.size / 12 + 1) pos ByteArray.empty) zSize
  let raw ← unfilter z rows bpp
  let f : Fmt := ⟨hd.ctype, hd.depth, trnsKey hd.ctype hd.depth m.trns, palette plte m.trns⟩
  let mut out := ByteArray.emptyWithCapacity (w * h * 4)
  for y in [0:h] do
    for x in [0:w] do
      let p := if hd.interlace then adam7Pass.getD ((y % 8) * 8 + x % 8) 0 else 0
      let (x0, y0, dx, dy) := ps.getD p (0, 0, 1, 1)
      let rs := offs.getD p 0 + ((y - y0) / dy) * (rows.getD p (0, 0)).2
      out := pushPx f raw rs ((x - x0) / dx) out
  return (w, h, out)

def decode (b : ByteArray) : Option ImageData.Decoded :=
  match decodeRaw b with
  | none => none
  | some (w, h, px) =>
    if px.size = w * h * 4 ∧ 0 < w ∧ 0 < h ∧ w * h ≤ ImageData.maxPixels then some ⟨w, h, px⟩
    else none

end LeanSvg.PngDecode
