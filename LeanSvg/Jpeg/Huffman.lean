/-!
# JPEG entropy decoding: bit reader and Huffman tables (T62)

A port of `zune-jpeg` 0.5.15 (the decoder resvg 0.48.1 uses), restricted to
what it does on well-formed data. The bit reader works on one restart
interval whose byte stuffing (`FF 00`) has already been removed; reads past
the end return zero bits, and the caller rejects the interval afterwards if
its position ran past the data (`pos > 8 * size`), so truncated data is
`none`, not padding.

Tables follow libjpeg's / zune's canonical construction: a 9-bit lookahead
table plus `maxcode`/`offset` for longer codes. A table with an all-ones code
or more codes than a length allows is rejected, as is a DC table with a
symbol above 15.
-/

namespace LeanSvg.Jpeg

@[inline] def byteAt (bs : ByteArray) (i : Nat) : Nat :=
  if h : i < bs.size then bs[i].toNat else 0

/-- `2^n` for `n < 64`, without `Nat.shiftLeft` (which goes through GMP). -/
@[inline] def pow2 (n : Nat) : Nat := ((1 : UInt64) <<< n.toUInt64).toNat

/-- `n ≤ 16` bits starting at bit `pos` (MSB first), zeros past the end. -/
@[inline] def peekBits (d : ByteArray) (pos n : Nat) : Nat :=
  let b := pos / 8
  let w : UInt32 := (byteAt d b).toUInt32 * 65536 + (byteAt d (b + 1)).toUInt32 * 256 +
    (byteAt d (b + 2)).toUInt32
  ((w >>> (24 - pos % 8 - n).toUInt32) &&& (((1 : UInt32) <<< n.toUInt32) - 1)).toNat

/-- JPEG's EXTEND: an `s`-bit magnitude `r` read as a signed value. -/
@[inline] def extend (r s : Nat) : Int :=
  if s == 0 then 0
  else if r < pow2 (s - 1) then (r : Int) - (pow2 s : Int) + 1 else r

/-- Read `s ≤ 16` bits and EXTEND them. -/
@[inline] def receive (d : ByteArray) (pos s : Nat) : Int × Nat :=
  (extend (peekBits d pos s) s, pos + s)

structure Huff where
  /-- 512 entries: `0` means "longer than 9 bits", else `len * 256 + symbol`. -/
  lookup : Array Nat
  /-- Per length 1..16: exclusive bound of that length's codes, left-justified
  to 16 bits; `-1` for a length with no codes. -/
  maxcode : Array Int
  /-- Per length: index of its first symbol minus its first code. -/
  offset : Array Int
  vals : ByteArray

/-- Build a table from the 16 `BITS` counts (`bits[l-1]` = number of codes of
length `l`) and the symbol list. -/
def Huff.build (bits : Array Nat) (vals : ByteArray) (isDc : Bool) : Option Huff := Id.run do
  let num := bits.foldl (· + ·) 0
  if bits.size != 16 || num > 256 || vals.size < num then return none
  -- canonical codes, one per symbol, in symbol order
  let mut codes : Array Nat := Array.emptyWithCapacity num
  let mut maxcode : Array Int := Array.replicate 18 (-1)
  let mut offset : Array Int := Array.replicate 18 0
  let mut code : Nat := 0
  for l in [1:17] do
    let n := bits.getD (l - 1) 0
    if n != 0 then
      offset := offset.setIfInBounds l ((codes.size : Int) - (code : Int))
    for _ in [0:n] do
      codes := codes.push code
      code := code + 1
    if code ≥ pow2 l then return none
    if n != 0 then maxcode := maxcode.setIfInBounds l ((code * pow2 (16 - l) : Nat) : Int)
    code := code * 2
  maxcode := maxcode.setIfInBounds 17 0xFFFFF
  let mut lookup := Array.replicate 512 0
  let mut p := 0
  for l in [1:10] do
    for _ in [0:bits.getD (l - 1) 0] do
      let base := codes.getD p 0 * pow2 (9 - l)
      for j in [0:pow2 (9 - l)] do
        lookup := lookup.setIfInBounds (base + j) (l * 256 + byteAt vals p)
      p := p + 1
  if isDc then
    for i in [0:num] do
      if byteAt vals i > 15 then return none
  return some ⟨lookup, maxcode, offset, vals⟩

/-- Decode one symbol at bit `pos`: `(symbol, newPos)`, `none` on a bit
pattern that is no code. -/
def Huff.decode (t : Huff) (d : ByteArray) (pos : Nat) : Option (Nat × Nat) := Id.run do
  let e := t.lookup.getD (peekBits d pos 9) 0
  if e != 0 then return some (e % 256, pos + e / 256)
  let p16 := peekBits d pos 16
  for l in [10:17] do
    if (p16 : Int) < t.maxcode.getD l (-1) then
      let idx := ((p16 / pow2 (16 - l) : Nat) : Int) + t.offset.getD l 0
      return some (byteAt t.vals (idx % 256).toNat, pos + l)
  return none

end LeanSvg.Jpeg
