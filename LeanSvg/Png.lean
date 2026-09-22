/-!
# PNG encoder

Minimal, dependency-free PNG writer: 8-bit RGBA, no interlace, filter type 0 on
every row, and a zlib stream made of *stored* (uncompressed) DEFLATE blocks.
The output is larger than a compressed PNG but its structure is trivial, which
keeps this module small and makes its size a simple function of `(w, h)` —
`zlibLen` states that function, and `encode` uses it to size the output buffer
before writing a byte.

Everything is written once, into that one buffer.  The filtered scanline stream
is never materialised: each row's filter byte and its slice of `rgba` go
straight into the IDAT payload between the stored-block headers, and the IDAT
CRC is taken over the bytes where they already lie rather than over a freshly
built `"IDAT" ++ data`.  So the pixel bytes are touched four times in all —
built by `Canvas.toRgbaBytes`, copied into the buffer, walked by Adler-32,
walked by CRC-32 — instead of being copied through four intermediate
`ByteArray`s on top of that.

Swapping in a verified DEFLATE compressor (e.g. kim-em/lean-zip) is a
two-function change: `zlibStoredRows` writes the stream and `zlibLen` gives its
length.
-/

namespace LeanSvg
namespace Png

def crcTable : Array UInt32 :=
  Array.ofFn (n := 256) fun i =>
    (List.range 8).foldl
      (fun (c : UInt32) _ => if c &&& 1 == 1 then (0xEDB88320 : UInt32) ^^^ (c >>> 1) else c >>> 1)
      i.val.toUInt32

/-- `t` advanced by one more zero byte: if `t[i]` is the register after feeding
some bytes, `crcAdvance t` is the register after feeding one further zero. -/
def crcAdvance (t : Array UInt32) : Array UInt32 :=
  t.map fun (v : UInt32) => (v >>> 8) ^^^ crcTable.getD (v &&& 0xFF).toNat 0

def crcTable1 : Array UInt32 := crcAdvance crcTable
def crcTable2 : Array UInt32 := crcAdvance crcTable1
def crcTable3 : Array UInt32 := crcAdvance crcTable2

/-- Feed `bs[start:stop)` into the CRC register `c`, one byte at a time:
`c := crcTable[(c ^^^ b) &&& 0xFF] ^^^ (c >>> 8)`.

A closure per byte through `ByteArray.foldl` measured the same as a
tail-recursive loop over structurally decreasing fuel (211 ms vs 214 ms on the
3200² benchmark, inside the run-to-run spread), so this keeps the shorter of
the two.  One `UInt32` accumulator stays unboxed either way.  Adler-32 is the
opposite case only because it carries *two* accumulators, which a `for` loop
boxes into a `Prod` — see `adlerChunk`. -/
def crcBytes (bs : ByteArray) (start stop : Nat) (c : UInt32) : UInt32 :=
  bs.foldl (fun c b => crcTable.getD ((c ^^^ b.toUInt32) &&& 0xFF).toNat 0 ^^^ (c >>> 8))
    c start stop

/-- The same, four bytes per step ("slicing by 4", as in zlib's `DOLIT32`).

Byte at a time, each step needs the previous step's table entry before it can
even form its own index, so the loop runs at the latency of a dependent load —
about four times what the work itself costs.  Feeding four bytes at once turns
that into four *independent* lookups: xor the four bytes into the register and
split it into four byte lanes, where lane `k` is a byte that still has `k`
further bytes to travel, so it is looked up in `crcTable` advanced `k` times.
`crcAdvance` is exactly that advance, which is why the tables are built from
`crcTable` rather than written out. -/
def crcRun4 (bs : ByteArray) (i fuel : Nat) (c : UInt32) : UInt32 :=
  match fuel with
  | 0 => c
  | fuel' + 1 =>
    if h : i + 3 < bs.size then
      let b0 : UInt32 := (bs[i]'(by omega)).toUInt32
      let b1 : UInt32 := (bs[i + 1]'(by omega)).toUInt32
      let b2 : UInt32 := (bs[i + 2]'(by omega)).toUInt32
      let b3 : UInt32 := (bs[i + 3]'h).toUInt32
      let d := c ^^^ b0 ^^^ (b1 <<< 8) ^^^ (b2 <<< 16) ^^^ (b3 <<< 24)
      let c' := crcTable3.getD (d &&& 0xFF).toNat 0
            ^^^ crcTable2.getD ((d >>> 8) &&& 0xFF).toNat 0
            ^^^ crcTable1.getD ((d >>> 16) &&& 0xFF).toNat 0
            ^^^ crcTable.getD (d >>> 24).toNat 0
      crcRun4 bs (i + 4) fuel' c'
    else
      -- `crc32Range` never runs off the end; fall back rather than stop early,
      -- so this agrees with `crcBytes` on every input and not just reachable ones.
      crcBytes bs i (i + 4 * (fuel' + 1)) c

/-- CRC-32 of `bs[start:stop)`, clamped to the array as `ByteArray.foldl` would
clamp it. -/
def crc32Range (bs : ByteArray) (start stop : Nat) : Nat :=
  let hi := Nat.min stop bs.size
  let lo := Nat.min start hi
  let quads := (hi - lo) / 4
  let c := crcRun4 bs lo quads 0xFFFFFFFF
  (crcBytes bs (lo + quads * 4) hi c ^^^ 0xFFFFFFFF).toNat

def crc32 (bs : ByteArray) : Nat := crc32Range bs 0 bs.size

/-- Adler-32 of the PNG scanline stream built from `rgba` as `h` rows of
`rowBytes` bytes, each preceded by a filter-type byte: `0 ++ row 0 ++ 0 ++
row 1 ++ ...`.  A filter byte is 0, so it leaves `a` alone and adds `a` to `b`.

The `% 65521` is deferred to the end of each 5552-byte chunk — the standard
zlib trick, and *exact*, not an approximation: entering a chunk of `k ≤ 5552`
bytes with `a, b < 65521` gives `a ≤ 65520 + 255*k` and
`b ≤ 65520 + k*(65520 + 255*k) < 2^33`, so nothing is lost and the two
accumulators fit a `UInt64` with room to spare.

`adlerChunk`/`adlerChunk4` carry them as arguments of a tail-recursive
function, which the compiler keeps in registers as unboxed `uint64_t`.  A `for`
loop with two mutable variables instead carries them in a `Prod` that it writes
and reads back every byte, and that store-to-load round trip costs more than
the additions do: on the 3200² benchmark the `for` loop measured 282 ms against
160 ms for this shape, both byte at a time with the same deferred `%`. -/
def adlerChunk (rgba : ByteArray) (i fuel : Nat) (a b : UInt64) : UInt64 × UInt64 :=
  match fuel with
  | 0 => (a, b)
  | fuel' + 1 =>
    let a' := a + (if _ : i < rgba.size then rgba[i].toUInt64 else 0)
    adlerChunk rgba (i + 1) fuel' a' (b + a')

/-- `adlerChunk`, four bytes per step, so that the bounds check and the index
and fuel bookkeeping are paid once per four bytes instead of once per byte. -/
def adlerChunk4 (rgba : ByteArray) (i fuel : Nat) (a b : UInt64) : UInt64 × UInt64 :=
  match fuel with
  | 0 => (a, b)
  | fuel' + 1 =>
    if h : i + 3 < rgba.size then
      let a1 := a + (rgba[i]'(by omega)).toUInt64
      let a2 := a1 + (rgba[i + 1]'(by omega)).toUInt64
      let a3 := a2 + (rgba[i + 2]'(by omega)).toUInt64
      let a4 := a3 + (rgba[i + 3]'h).toUInt64
      adlerChunk4 rgba (i + 4) fuel' a4 (b + a1 + a2 + a3 + a4)
    else
      -- Unreachable from `adler32Rows`; fall back rather than stop early, so
      -- this agrees with `adlerChunk` on every input and not just reachable ones.
      adlerChunk rgba i (4 * (fuel' + 1)) a b

def adler32Rows (rgba : ByteArray) (rowBytes h : Nat) : Nat := Id.run do
  let mut a : Nat := 1
  let mut b : Nat := 0
  let nchunks := (rowBytes + 5551) / 5552
  for y in [0:h] do
    b := (b + a) % 65521
    let base := y * rowBytes
    for c in [0:nchunks] do
      let lo := base + c * 5552
      let hi := Nat.min (base + rowBytes) (lo + 5552)
      let quads := (hi - lo) / 4
      let q := adlerChunk4 rgba lo quads a.toUInt64 b.toUInt64
      let r := adlerChunk rgba (lo + quads * 4) (hi - lo - quads * 4) q.1 q.2
      a := r.1.toNat % 65521
      b := r.2.toNat % 65521
  return (b <<< 16) ||| a

def be32 (n : Nat) : ByteArray :=
  (((ByteArray.empty.push ((n >>> 24) &&& 0xFF).toUInt8).push ((n >>> 16) &&& 0xFF).toUInt8).push
    ((n >>> 8) &&& 0xFF).toUInt8).push (n &&& 0xFF).toUInt8

def chunk (typ : String) (data : ByteArray) : ByteArray :=
  let td := typ.toUTF8 ++ data
  be32 data.size ++ td ++ be32 (crc32 td)

/-- Length of the zlib stream that `zlibStoredRows` writes for `h` rows of
`rowBytes` bytes: the 2-byte zlib header, a 5-byte header per stored block, the
scanline stream itself, and the 4-byte Adler-32.  An empty stream still gets
one (empty, final) block. -/
def zlibLen (rowBytes h : Nat) : Nat :=
  let raw := h * (rowBytes + 1)
  let nblocks := if raw == 0 then 1 else (raw + 65534) / 65535
  2 + nblocks * 5 + raw + 4

/-- The 5-byte header of the stored block that starts at offset `pos` of a
`rawSize`-byte stream: final flag, `len`, and `len` complemented. -/
@[inline] def blockHeader (out : ByteArray) (pos rawSize : Nat) : ByteArray :=
  let len := Nat.min 65535 (rawSize - pos)
  let final : UInt8 := if pos + len == rawSize then 1 else 0
  let nlen := 65535 - len
  ((((out.push final).push (len &&& 0xFF).toUInt8).push ((len >>> 8) &&& 0xFF).toUInt8).push
    (nlen &&& 0xFF).toUInt8).push ((nlen >>> 8) &&& 0xFF).toUInt8

/-- Copy the remaining fragments of one row. The fuel is the same fixed
fragment count as the original range loop; keeping the loop separate also
lets size proofs account for the remaining row bytes without unfolding the
whole encoder. -/
def storedPieces (rgba : ByteArray) (rawSize stop : Nat) :
    Nat → ByteArray → Nat → Nat → ByteArray × Nat
  | 0, out, pos, _ => (out, pos)
  | fuel + 1, out, pos, off =>
    if off < stop then
      let out := if pos % 65535 == 0 then blockHeader out pos rawSize else out
      let n := Nat.min (65535 - pos % 65535) (stop - off)
      storedPieces rgba rawSize stop fuel
        (rgba.copySlice off out out.size n false) (pos + n) (off + n)
    else (out, pos)

/-- Write a fixed number of rows, carrying the scanline-stream position.
Both this loop and `storedPieces` recurse on structurally decreasing fuel. -/
def storedRows (rgba : ByteArray) (rowBytes rawSize pieces : Nat) :
    Nat → Nat → ByteArray → Nat → ByteArray
  | 0, _, out, _ => out
  | fuel + 1, y, out, pos =>
    let out := if pos % 65535 == 0 then blockHeader out pos rawSize else out
    let row := storedPieces rgba rawSize (y * rowBytes + rowBytes) pieces
      (out.push 0) (pos + 1) (y * rowBytes)
    storedRows rgba rowBytes rawSize pieces fuel (y + 1) row.1 row.2

/-- Append to `out` the zlib stream for `h` scanlines of `rowBytes` bytes taken
from `rgba`: filter byte 0 and then the row, cut into stored DEFLATE blocks of
at most 65535 bytes.  Row boundaries and block boundaries do not line up, so a
row is copied in as many pieces as it straddles blocks — at most
`rowBytes / 65535 + 2` of them, which bounds the inner loop.  Each piece goes
straight from `rgba` into `out` with `ByteArray.copySlice`; nothing is copied
twice, and `out` is expected to be sized for the whole file already. -/
def zlibStoredRows (out : ByteArray) (rgba : ByteArray) (rowBytes h : Nat) : ByteArray :=
  let rawSize := h * (rowBytes + 1)
  let pieces := rowBytes / 65535 + 2
  let out := storedRows rgba rowBytes rawSize pieces h 0 ((out.push 0x78).push 0x01) 0
  let out := if rawSize == 0 then blockHeader out 0 0 else out
  out ++ be32 (adler32Rows rgba rowBytes h)

def signature : ByteArray :=
  ⟨#[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]⟩

/-- Encode `h` rows of `w` straight-alpha RGBA pixels (`rgba.size = w*h*4`). -/
def encode (w h : Nat) (rgba : ByteArray) : ByteArray := Id.run do
  let rowBytes := w * 4
  let idatLen := zlibLen rowBytes h
  let mut out := ByteArray.emptyWithCapacity (8 + 25 + (12 + idatLen) + 12)
  out := out ++ signature
  out := out ++ chunk "IHDR" (be32 w ++ be32 h ++ ⟨#[8, 6, 0, 0, 0]⟩)
  out := out ++ be32 idatLen
  let idatStart := out.size
  out := out ++ "IDAT".toUTF8
  out := zlibStoredRows out rgba rowBytes h
  let idatStop := out.size
  let crc := crc32Range out idatStart idatStop
  out := out ++ be32 crc
  return out ++ chunk "IEND" ByteArray.empty

end Png
end LeanSvg
