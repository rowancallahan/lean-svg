import LeanSvg.Inflate

/-!
# gzip (RFC 1952) over `Inflate` (T84)

For `svgz` images: usvg's `decompress_svgz` (flate2 `GzDecoder`, read to the
end).  The DEFLATE blocks are `Inflate`'s own (`stored`, `codes`,
`dynHeader`); only the block loop differs, since here the stream decides the
length and `cap` is a ceiling, not the exact size.

`gunzip inp cap` is `none` for a bad header, a broken stream, or more than
`cap` bytes of output: decoding stops at `cap + 1` bytes, so a zip bomb costs
at most that much.  The CRC-32/ISIZE trailer is not checked.
-/

namespace LeanSvg.Gzip

open Bytes (at')
open Inflate

/-- DEFLATE blocks until the final one, or until `cap` bytes are out. -/
def blocksAll (inp : ByteArray) (cap : Nat) : Nat → Nat → ByteArray → Option ByteArray
  | 0, _, _ => none
  | fuel + 1, bp, out =>
    if out.size ≥ cap then some out
    else if bp + 3 > 8 * inp.size then none
    else
      let final := peek inp bp 1
      let typ := peek inp (bp + 1) 2
      let bp := bp + 3
      let r : Option (Nat × ByteArray) :=
        if typ == 0 then stored inp bp cap out
        else if typ == 1 then codes inp fixedLit fixedDist cap (cap + 1) bp out
        else if typ == 2 then
          match dynHeader inp bp with
          | none => none
          | some (bp, lit, dist) => codes inp lit dist cap (cap + 1) bp out
        else none
      match r with
      | none => none
      | some (bp, out) =>
        if out.size ≥ cap || final == 1 then some out
        else blocksAll inp cap fuel bp out

/-- Index just past the zero byte that ends the string at `i`. -/
def skipZ (inp : ByteArray) (i : Nat) : Nat := Bytes.findByte inp i 0 + 1

/-- Byte offset of the DEFLATE data after the gzip header, `none` if the
header is not method 8 or runs past the input. -/
def bodyStart (inp : ByteArray) : Option Nat :=
  if inp.size < 10 || at' inp 0 != 0x1f || at' inp 1 != 0x8b || at' inp 2 != 8 then none
  else
    let flg := (at' inp 3).toNat
    if flg &&& 0xE0 != 0 then none else
    let p := 10
    let p := if flg &&& 4 != 0 then p + 2 + (at' inp p).toNat + (at' inp (p + 1)).toNat * 256 else p
    let p := if flg &&& 8 != 0 then skipZ inp p else p
    let p := if flg &&& 16 != 0 then skipZ inp p else p
    let p := if flg &&& 2 != 0 then p + 2 else p
    if p > inp.size then none else some p

/-- The decompressed member, at most `cap` bytes, or `none`. -/
def gunzip (inp : ByteArray) (cap : Nat) : Option ByteArray :=
  match bodyStart inp with
  | none => none
  | some p =>
    match blocksAll inp (cap + 1) (8 * inp.size + 1) (8 * p)
        (ByteArray.emptyWithCapacity (Nat.min cap 65536)) with
    | some out => if out.size ≤ cap then some out else none
    | none => none

end LeanSvg.Gzip
