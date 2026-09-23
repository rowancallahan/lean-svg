import LeanSvg.ImageData
import LeanSvg.Bytes
import LeanSvg.Inflate

/-!
# GIF decoder (see `LeanSvg/ImageData.lean` for the contract)

Matches what resvg 0.48.1 gets from the `gif` crate 0.14.1 with
`ColorOutput::RGBA`, first frame only (`decoder.read_next_frame()` once):
the returned pixmap is exactly the *first frame's own* width/height (its
`left`/`top` and the logical screen size are never consulted, since
`decode_gif` builds a fresh `tiny_skia::Pixmap` sized to the frame). Straight
alpha; premultiplying is `Image.lean`'s job, same as PNG/JPEG.

* Header (`GIF87a`/`GIF89a`), logical screen descriptor, optional global
  colour table, any run of extensions (only the most recent Graphic Control
  Extension's transparent index survives, as `read_control_extension`
  overwrites the pending frame's fields), then the first Image Descriptor:
  that is the frame decoded. A malformed Graphic Control Extension (its
  sub-blocks not exactly 4 bytes) fails the whole decode, like the crate.
* The colour table read for the frame is its local one if present, else the
  global one; neither present is `none` ("no color table available").
* LZW (`weezl`, `BitOrder::Lsb`): a code above `min_code_size` is a literal
  0..`clear`-1; `clear = 1 <<< min_code_size` resets the table and code size
  to `min_code_size + 1`; `end` (`clear + 1`) stops decoding early exactly as
  the crate's pixel filler does once the frame's `w * h` indices are out,
  even if the bitstream has not reached its own end code. The table freezes
  at 4096 entries (`weezl`'s `MAX_ENTRIES`) rather than erroring.
* An index past the palette leaves the pixel `(0,0,0,0)`, the RGBA buffer's
  zero-init in `converter.rs::fill_buffer` that a missing `palette.get` never
  overwrites (unlike PNG, where an out-of-range index is opaque black).
* Interlaced frames (GIF's four-pass, row-only interlacing) are deinterlaced
  the way `converter.rs`'s `InterlaceIterator` orders rows.
* Size: `w * h > maxPixels` is `none` right after the Image Descriptor,
  before any LZW decoding.
-/

namespace LeanSvg.GifDecode

open Bytes (at')

@[inline] def le16 (b : ByteArray) (i : Nat) : Nat :=
  (at' b i).toNat + (at' b (i + 1)).toNat * 256

/-- Concatenate a run of length-prefixed sub-blocks starting at `pos` (the
first length byte) up to the zero-length terminator. Each sub-block consumes
at least one byte of `b`, so `b.size + 1` fuel always suffices. -/
def subBlocks (b : ByteArray) : Nat → Nat → ByteArray → Option (Nat × ByteArray)
  | 0, _, _ => none
  | fuel + 1, pos, acc =>
    if pos ≥ b.size then none else
    let n := (at' b pos).toNat
    if n == 0 then some (pos + 1, acc)
    else if pos + 1 + n > b.size then none
    else subBlocks b fuel (pos + 1 + n) (acc ++ b.extract (pos + 1) (pos + 1 + n))

/-- Walk blocks from `pos` (an Extension Introducer, Image Descriptor or
Trailer) to the first Image Descriptor, tracking the transparent index of the
most recently read Graphic Control Extension. `none` on the Trailer, an
unknown block type (as `allow_unknown_blocks = false`, the crate default) or
a malformed control extension. -/
def walk (b : ByteArray) : Nat → Nat → Option Nat → Option (Nat × Option Nat)
  | 0, _, _ => none
  | fuel + 1, pos, trans =>
    if pos ≥ b.size then none else
    let bt := at' b pos
    if bt == 0x2C then some (pos, trans)
    else if bt == 0x21 then
      match subBlocks b (b.size + 1) (pos + 2) ByteArray.empty with
      | none => none
      | some (pos', data) =>
        if at' b (pos + 1) == 0xF9 then
          if data.size != 4 then none
          else
            let flags := at' data 0
            let idx := (at' data 3).toNat
            walk b fuel pos' (if flags &&& 1 == 1 then some idx else none)
        else walk b fuel pos' trans
    else none

/-- Root dictionary after a Clear code: literal codes `0 .. clear - 1`, plus
two unused placeholder slots for the clear/end codes so indices line up. -/
def initDict (clear : Nat) : Array (Array Nat) := Id.run do
  let mut d := Array.emptyWithCapacity (clear + 2)
  for i in [0:clear] do d := d.push #[i]
  return d.push #[] |>.push #[]

/-- LZW body: `bp` the bit position, `codeSize` the current code width,
`nextCode` the next free dictionary slot (frozen at 4096, `weezl`'s
`MAX_ENTRIES`), `prev` the previous code (`none` right after a Clear).
Every entry appended to `out` is clipped to leave room for exactly `desired`
symbols, so `out.size` never overshoots. Fuel: each step consumes at least
`clear`'s code size (≥ 2) bits, so `8 * data.size + 1` steps always suffice
for a stream that ends in bounds. -/
def run (data : ByteArray) (clear endc minCS desired : Nat) :
    Nat → Nat → Nat → Nat → Array (Array Nat) → Option Nat → Array Nat → Option (Array Nat)
  | 0, _, _, _, _, _, _ => none
  | fuel + 1, bp, codeSize, nextCode, dict, prev, out =>
    if out.size ≥ desired then some out
    else if bp + codeSize > 8 * data.size then none
    else
      let code := Inflate.peek data bp codeSize
      let bp' := bp + codeSize
      if code == clear then
        run data clear endc minCS desired fuel bp' (minCS + 1) (clear + 2) (initDict clear) none out
      else if code == endc then none
      else
        let room := desired - out.size
        let push (entry : Array Nat) (nextCode' : Nat) (dict' : Array (Array Nat)) : Option (Array Nat) :=
          let codeSize' := if nextCode' == (1 <<< codeSize) && codeSize < 12 then codeSize + 1 else codeSize
          let clipped := if entry.size > room then entry.extract 0 room else entry
          run data clear endc minCS desired fuel bp' codeSize' nextCode' dict' (some code) (out ++ clipped)
        match prev with
        | none =>
          if code ≥ clear then none else push (dict.getD code #[]) nextCode dict
        | some p =>
          -- Every code after the first (post-clear) one both emits its
          -- string and adds prefix `p`'s string plus that string's first
          -- byte as a new table entry (the KwKwK case reads its own
          -- about-to-be-added entry back).
          let entryOpt :=
            if code < nextCode then some (dict.getD code #[])
            else if code == nextCode then
              let pe := dict.getD p #[]
              some (pe.push (pe.getD 0 0))
            else none
          match entryOpt with
          | none => none
          | some entry =>
            let pe := dict.getD p #[]
            let added := pe.push (entry.getD 0 0)
            let dict' := if nextCode < 4096 then dict.push added else dict
            push entry (if nextCode < 4096 then nextCode + 1 else nextCode) dict'

/-- LZW-decode `desired` palette indices from `data` (the concatenated
sub-blocks), `minCS` the minimum code size byte. `minCS` outside `1..11`
(`weezl`'s `check_code_size`) is `none`. -/
def lzwDecode (data : ByteArray) (minCS desired : Nat) : Option (Array Nat) :=
  if minCS < 1 || minCS > 11 then none
  else if desired == 0 then some #[]
  else
    let clear := 1 <<< minCS
    run data clear (clear + 1) minCS desired (8 * data.size + 1) 0 (minCS + 1) (clear + 2)
      (initDict clear) none #[]

/-- Row `y` of `h` rows, in GIF's four-pass interlace order (start 0 step 8,
start 4 step 8, start 2 step 4, start 1 step 2), or sequential if not
interlaced. -/
def rowOrder (h : Nat) (interlaced : Bool) : Array Nat := Id.run do
  let mut out := Array.emptyWithCapacity h
  if !interlaced then
    for y in [0:h] do out := out.push y
    return out
  for (start, step) in (#[(0, 8), (4, 8), (2, 4), (1, 2)] : Array (Nat × Nat)) do
    for y in [0:h] do
      if y ≥ start && (y - start) % step == 0 then out := out.push y
  return out

/-- `idx`'s palette entry as straight-alpha RGBA8; past the palette (or no
palette at all) is transparent black, the RGBA buffer's zero-init that
`converter.rs::fill_buffer` leaves untouched when `palette.get` fails. -/
@[inline] def pushGifPx (pal : ByteArray) (trans : Option Nat) (idx : Nat) (out : ByteArray) : ByteArray :=
  let off := 3 * idx
  if off + 3 ≤ pal.size then
    out.push (at' pal off) |>.push (at' pal (off + 1)) |>.push (at' pal (off + 2))
      |>.push (if trans == some idx then 0 else 255)
  else out.push 0 |>.push 0 |>.push 0 |>.push 0

/-- Decode to `(w, h, rgba)`; `decode` then checks the size contract. -/
def decodeRaw (b : ByteArray) : Option (Nat × Nat × ByteArray) := do
  if !(Bytes.startsWith b 0 "GIF87a" || Bytes.startsWith b 0 "GIF89a") then none
  let sflags := (at' b 10).toNat
  let gctSize := if sflags &&& 0x80 != 0 then 3 * (1 <<< ((sflags &&& 7) + 1)) else 0
  if 13 + gctSize > b.size then none
  let gct := b.extract 13 (13 + gctSize)
  let (framePos, trans) ← walk b (b.size + 1) (13 + gctSize) none
  if framePos + 10 > b.size then none
  let w := le16 b (framePos + 5)
  let h := le16 b (framePos + 7)
  if w == 0 || h == 0 || w * h > ImageData.maxPixels then none
  let iflags := (at' b (framePos + 9)).toNat
  let interlace := iflags &&& 0x40 != 0
  let localSize := if iflags &&& 0x80 != 0 then 3 * (1 <<< ((iflags &&& 7) + 1)) else 0
  let palEnd := framePos + 10 + localSize
  if palEnd > b.size then none
  let pal := if localSize > 0 then b.extract (framePos + 10) palEnd else gct
  if pal.isEmpty then none
  let minCS := (at' b palEnd).toNat
  let (_, lzwData) ← subBlocks b (b.size + 1) (palEnd + 1) ByteArray.empty
  let idxs ← lzwDecode lzwData minCS (w * h)
  let order := rowOrder h interlace
  let mut inv := Array.replicate h 0
  for k in [0:h] do inv := inv.setIfInBounds (order.getD k 0) k
  let mut out := ByteArray.emptyWithCapacity (w * h * 4)
  for y in [0:h] do
    let k := inv.getD y 0
    let rowStart := k * w
    for x in [0:w] do
      out := pushGifPx pal trans (idxs.getD (rowStart + x) 0) out
  return (w, h, out)

def decode (b : ByteArray) : Option ImageData.Decoded :=
  match decodeRaw b with
  | none => none
  | some (w, h, px) =>
    if px.size = w * h * 4 ∧ 0 < w ∧ 0 < h ∧ w * h ≤ ImageData.maxPixels then some ⟨w, h, px⟩
    else none

end LeanSvg.GifDecode
