/-!
# PNG encoder

Minimal, dependency-free PNG writer: 8-bit RGBA, no interlace, filter type 0 on
every row, and a zlib stream made of *stored* (uncompressed) DEFLATE blocks.
The output is larger than a compressed PNG but its structure is trivial, which
keeps this module small and makes its size a simple function of `(w, h)`.

Swapping in a verified DEFLATE compressor (e.g. kim-em/lean-zip) is a
one-function change in `zlibStored`.
-/

namespace MicroSvg
namespace Png

def crcTable : Array UInt32 :=
  Array.ofFn (n := 256) fun i =>
    (List.range 8).foldl
      (fun (c : UInt32) _ => if c &&& 1 == 1 then (0xEDB88320 : UInt32) ^^^ (c >>> 1) else c >>> 1)
      i.val.toUInt32

def crc32 (bs : ByteArray) : UInt32 :=
  let c := bs.foldl
    (fun c b => crcTable.getD ((c ^^^ b.toNat.toUInt32) &&& 0xFF).toNat 0 ^^^ (c >>> 8))
    0xFFFFFFFF
  c ^^^ 0xFFFFFFFF

def adler32 (bs : ByteArray) : Nat :=
  let (a, b) := bs.foldl
    (fun (ab : Nat × Nat) x =>
      let a' := (ab.1 + x.toNat) % 65521
      (a', (ab.2 + a') % 65521))
    (1, 0)
  (b <<< 16) ||| a

def be32 (n : Nat) : ByteArray :=
  (((ByteArray.empty.push ((n >>> 24) &&& 0xFF).toUInt8).push ((n >>> 16) &&& 0xFF).toUInt8).push
    ((n >>> 8) &&& 0xFF).toUInt8).push (n &&& 0xFF).toUInt8

def chunk (typ : String) (data : ByteArray) : ByteArray :=
  let td := typ.toUTF8 ++ data
  be32 data.size ++ td ++ be32 (crc32 td).toNat

/-- zlib stream using stored blocks of at most 65535 bytes. -/
def zlibStored (raw : ByteArray) : ByteArray := Id.run do
  let mut out := (ByteArray.empty.push 0x78).push 0x01
  let n := raw.size
  let nblocks := if n == 0 then 1 else (n + 65534) / 65535
  for k in [0:nblocks] do
    let off := k * 65535
    let len := Nat.min 65535 (n - off)
    let final : UInt8 := if k + 1 == nblocks then 1 else 0
    let nlen := 65535 - len
    out := ((((out.push final).push (len &&& 0xFF).toUInt8).push ((len >>> 8) &&& 0xFF).toUInt8).push
      (nlen &&& 0xFF).toUInt8).push ((nlen >>> 8) &&& 0xFF).toUInt8
    out := out ++ raw.extract off (off + len)
  return out ++ be32 (adler32 raw)

def signature : ByteArray :=
  ⟨#[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]⟩

/-- Encode `h` rows of `w` straight-alpha RGBA pixels (`rgba.size = w*h*4`). -/
def encode (w h : Nat) (rgba : ByteArray) : ByteArray := Id.run do
  let rowBytes := w * 4
  let mut raw := ByteArray.emptyWithCapacity (h * (rowBytes + 1))
  for y in [0:h] do
    raw := raw.push 0
    raw := raw ++ rgba.extract (y * rowBytes) ((y + 1) * rowBytes)
  let ihdr := be32 w ++ be32 h ++ ⟨#[8, 6, 0, 0, 0]⟩
  return signature ++ chunk "IHDR" ihdr ++ chunk "IDAT" (zlibStored raw) ++ chunk "IEND" ByteArray.empty

end Png
end MicroSvg
