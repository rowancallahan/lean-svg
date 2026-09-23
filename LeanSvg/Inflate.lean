import LeanSvg.Bytes

/-!
# zlib / DEFLATE decoder (RFC 1950 / 1951)

Used by `PngDecode` only. Stored, fixed-Huffman and dynamic-Huffman blocks.

`zlib inp cap` inflates the zlib stream in `inp` into exactly `cap` bytes, or
fails. `cap` is the caller's exact expected size (PNG: the filtered scanline
stream), so the output never grows past it: once `cap` bytes are out, the rest
of the stream is not read (a zip bomb stops there). A stream that ends before
`cap` bytes is `none`. The Adler-32 trailer is not checked, like the `png`
crate's default (`ignore_adler32 = true`), which resvg uses.

Every loop is a `for` over a bounded range or structural fuel: the block loop
by the input's bit count (each block header takes at least 3 bits), the symbol
loop by `cap + 1` (every symbol but end-of-block emits at least one byte).
Reads past the end of `inp` see `0` (`Bytes.at'`); every step that advances the
bit position checks it against `8 * inp.size` and fails if it ran over.
-/

namespace LeanSvg.Inflate

open Bytes (at')

/-- `n ≤ 24` bits at bit position `bp`, LSB first (DEFLATE bit order). -/
@[inline] def peek (inp : ByteArray) (bp n : Nat) : Nat :=
  let i := bp / 8
  let v := (at' inp i).toNat ||| ((at' inp (i + 1)).toNat <<< 8) |||
    ((at' inp (i + 2)).toNat <<< 16) ||| ((at' inp (i + 3)).toNat <<< 24)
  (v >>> (bp % 8)) % (1 <<< n)

/-- A canonical Huffman code as one lookup table indexed by the next `bits`
input bits: entry `sym * 16 + len`, `0` for a bit pattern no code starts. -/
structure Huff where
  bits : Nat
  tab : Array Nat

/-- `c`'s low `len` bits, reversed (codes are packed MSB first). -/
def rev (c len : Nat) : Nat := Id.run do
  let mut r := 0
  for k in [0:len] do
    r := r * 2 + (c >>> k) % 2
  return r

/-- Canonical code for the code lengths `lens` (0 = unused, max 15).
Over-subscribed length sets are `none`; incomplete ones are accepted and fail
only when an unassigned pattern is actually read. -/
def build (lens : Array Nat) : Option Huff := Id.run do
  let mut count := Array.replicate 16 0
  let mut maxLen := 0
  for l in lens do
    if l > 15 then return none
    if l > 0 then
      count := count.modify l (· + 1)
      if l > maxLen then maxLen := l
  -- Kraft: codes left at each length never go negative.
  let mut left := 1
  for l in [1:16] do
    left := left * 2
    if count.getD l 0 > left then return none
    left := left - count.getD l 0
  let mut next := Array.replicate 16 0
  let mut code := 0
  for l in [1:16] do
    code := (code + count.getD (l - 1) 0) * 2
    next := next.setIfInBounds l code
  let size := 1 <<< maxLen
  let mut tab := Array.replicate size 0
  for s in [0:lens.size] do
    let l := lens.getD s 0
    if l > 0 then
      let c := next.getD l 0
      next := next.setIfInBounds l (c + 1)
      let r := rev c l
      for k in [0:size >>> l] do
        tab := tab.setIfInBounds (r + (k <<< l)) (s * 16 + l)
  return some ⟨maxLen, tab⟩

/-- Next symbol and the bit position after it, or `none` on an unassigned
pattern or a read past the end. -/
@[inline] def sym (inp : ByteArray) (t : Huff) (bp : Nat) : Option (Nat × Nat) :=
  let e := t.tab.getD (peek inp bp t.bits) 0
  let bp' := bp + e % 16
  if e == 0 || bp' > 8 * inp.size then none else some (e / 16, bp')

def lenBase : Array Nat :=
  #[3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
    67, 83, 99, 115, 131, 163, 195, 227, 258]
def lenExtra : Array Nat :=
  #[0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0]
def distBase : Array Nat :=
  #[1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513,
    769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
def distExtra : Array Nat :=
  #[0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
    11, 11, 12, 12, 13, 13]

/-- Order in which the code-length code lengths are stored. -/
def clOrder : Array Nat :=
  #[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

def fixedLit : Huff :=
  (build (Array.ofFn (n := 288) fun i =>
    if i.val < 144 then 8 else if i.val < 256 then 9 else if i.val < 280 then 7 else 8)).getD
    ⟨0, #[]⟩
def fixedDist : Huff := (build (Array.replicate 30 5)).getD ⟨0, #[]⟩

/-- Append the back-reference `len` bytes from `dist` back, clipped at `cap`. -/
def copyBack (out : ByteArray) (dist len cap : Nat) : ByteArray := Id.run do
  let mut o := out
  for _ in [0:Nat.min len (cap - out.size)] do
    o := o.push (at' o (o.size - dist))
  return o

/-- Decode one Huffman block's symbols until end-of-block or `cap` bytes out.
Returns the bit position after the block (or where it stopped) and the output. -/
def codes (inp : ByteArray) (lit dist : Huff) (cap : Nat) :
    Nat → Nat → ByteArray → Option (Nat × ByteArray)
  | 0, _, _ => none
  | fuel + 1, bp, out =>
    if out.size ≥ cap then some (bp, out) else
    match sym inp lit bp with
    | none => none
    | some (s, bp) =>
      if s < 256 then codes inp lit dist cap fuel bp (out.push s.toUInt8)
      else if s == 256 then some (bp, out)
      else if s > 285 then none
      else
        let li := s - 257
        let ne := lenExtra.getD li 0
        let len := lenBase.getD li 0 + peek inp bp ne
        match sym inp dist (bp + ne) with
        | none => none
        | some (d, bp) =>
          if d ≥ 30 then none else
          let de := distExtra.getD d 0
          let dst := distBase.getD d 0 + peek inp bp de
          let bp := bp + de
          if dst > out.size || bp > 8 * inp.size then none
          else codes inp lit dist cap fuel bp (copyBack out dst len cap)

/-- Code lengths of a dynamic block, `total` of them, via the code-length code. -/
def readLens (inp : ByteArray) (cl : Huff) (total : Nat) :
    Nat → Nat → Array Nat → Option (Nat × Array Nat)
  | 0, bp, acc => if acc.size == total then some (bp, acc) else none
  | fuel + 1, bp, acc =>
    if acc.size ≥ total then (if acc.size == total then some (bp, acc) else none) else
    match sym inp cl bp with
    | none => none
    | some (s, bp) =>
      if s < 16 then readLens inp cl total fuel bp (acc.push s)
      else
        let (v, n, bp) :=
          if s == 16 then (acc.back?.getD 0, 3 + peek inp bp 2, bp + 2)
          else if s == 17 then (0, 3 + peek inp bp 3, bp + 3)
          else (0, 11 + peek inp bp 7, bp + 7)
        if (s == 16 && acc.size == 0) || acc.size + n > total || bp > 8 * inp.size then none
        else readLens inp cl total fuel bp (acc ++ Array.replicate n v)

/-- Dynamic block header: the literal/length and distance codes. -/
def dynHeader (inp : ByteArray) (bp : Nat) : Option (Nat × Huff × Huff) := do
  let hlit := peek inp bp 5 + 257
  let hdist := peek inp (bp + 5) 5 + 1
  let hclen := peek inp (bp + 10) 4 + 4
  if hlit > 286 || hdist > 30 then none
  let bp := bp + 14
  let mut cll := Array.replicate 19 0
  for k in [0:hclen] do
    cll := cll.setIfInBounds (clOrder.getD k 0) (peek inp (bp + 3 * k) 3)
  let bp := bp + 3 * hclen
  if bp > 8 * inp.size then none
  let cl ← build cll
  let (bp, lens) ← readLens inp cl (hlit + hdist) (hlit + hdist + 1) bp #[]
  let litL := lens.extract 0 hlit
  if litL.getD 256 0 == 0 then none
  let lit ← build litL
  let dist ← build (lens.extract hlit (hlit + hdist))
  return (bp, lit, dist)

/-- One stored block starting at bit `bp` (header bits already consumed). -/
def stored (inp : ByteArray) (bp cap : Nat) (out : ByteArray) : Option (Nat × ByteArray) :=
  let p := (bp + 7) / 8
  let len := (at' inp p).toNat + (at' inp (p + 1)).toNat * 256
  let nlen := (at' inp (p + 2)).toNat + (at' inp (p + 3)).toNat * 256
  if len + nlen != 65535 || p + 4 + len > inp.size then none
  else
    let k := Nat.min len (cap - out.size)
    some (8 * (p + 4 + len), out ++ inp.extract (p + 4) (p + 4 + k))

/-- Blocks until `cap` bytes are out; `none` if the final block ends first. -/
def blocks (inp : ByteArray) (cap : Nat) : Nat → Nat → ByteArray → Option ByteArray
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
        if out.size ≥ cap then some out
        else if final == 1 then none
        else blocks inp cap fuel bp out

/-- Inflate the zlib stream `inp` to exactly `cap` bytes. The header is checked
as `fdeflate` checks it (method 8, window ≤ 32K, no preset dictionary, FCHECK). -/
def zlib (inp : ByteArray) (cap : Nat) : Option ByteArray :=
  let cmf := (at' inp 0).toNat
  let flg := (at' inp 1).toNat
  if inp.size < 2 || cmf % 16 != 8 || cmf / 16 > 7 || flg &&& 0x20 != 0 ||
      (cmf * 256 + flg) % 31 != 0 then none
  else
    match blocks inp cap (8 * inp.size + 1) 16 (ByteArray.emptyWithCapacity (Nat.min cap 65536)) with
    | some out => if out.size == cap then some out else none
    | none => none

end LeanSvg.Inflate
