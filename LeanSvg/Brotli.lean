import LeanSvg.Bytes
import LeanSvg.Inflate
import LeanSvg.Font
import LeanSvg.BrotliData

/-!
# Brotli decoder (RFC 7932), for WOFF 2.0 fonts (T105)

`decompress inp cap` decodes the Brotli stream `inp` into exactly `cap` bytes,
or fails (`none`).  WOFF 2.0 states the decompressed size up front (the sum of
its table lengths), so `cap` is exact: the output never grows past it, and a
stream that would write more (a "zip bomb") fails as soon as it tries.

Everything is total and bounded:
- bits are read with `Inflate.peek` (reads past the end see `0`); every loop
  checks the bit position against `8 * inp.size` and fails once it ran over;
- the meta-block loop runs at most `8 * inp.size + 1` times (a header takes
  at least one bit), the command loop at most `cap + 8 * inp.size + 1` times
  (a command writes at least one byte or reads at least one bit, except a
  degenerate one that fails when the fuel runs out), a literal run and a copy
  are each bounded by the meta-block's remaining length;
- prefix codes are decoded canonically, one bit at a time over lengths 1–15
  (`Code.read`), so a code costs memory linear in its alphabet (≤ 704);
- `cap` itself is capped by the caller (16 MB per font, `Woff`).

Supported: the whole format of RFC 7932, including the static dictionary and
its 121 transforms (`BrotliData`), context modeling and block switching.  Not
supported (rejected): the large-window extension (`WBITS` > 24), which is not
part of RFC 7932 and never produced for WOFF 2.0.
-/

namespace LeanSvg.Brotli

open Bytes (at')
open Inflate (peek)

/-- The static dictionary, decoded once. -/
def dict : ByteArray := Font.base64DecodeChunks BrotliData.dictChunks

/-- The context lookup table, decoded once (2048 bytes). -/
def ctxLut : ByteArray := Font.base64Decode BrotliData.contextLut

/-- `NDBITS` per word length (RFC 7932 section 8); 0 = no words of that length. -/
def dictSizeBits : Array Nat :=
  #[0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5]

/-- Offset of the words of each length in `dict`. -/
def dictOffsets : Array Nat := Id.run do
  let mut out : Array Nat := #[]
  let mut o := 0
  for l in [0:25] do
    out := out.push o
    let nb := dictSizeBits.getD l 0
    if nb > 0 then o := o + l * (1 <<< nb)
  return out

/-! ## Prefix codes -/

/-- A canonical prefix code: `count[len]` codes of each length 1–15 and the
symbols sorted by (length, value), decoded bit by bit (the `puff` scheme);
or a code with one symbol and zero bits. -/
structure Code where
  single : Option Nat := none
  count : Array Nat := #[]
  syms : Array Nat := #[]
deriving Inhabited

/-- The canonical code for the lengths `lens` (0 = unused, at most 15).  An
over-subscribed set is `none`; an incomplete one fails only if an unassigned
pattern is read. -/
def Code.ofLens (lens : Array Nat) : Option Code := Id.run do
  let mut count := Array.replicate 16 0
  for l in lens do
    if l > 15 then return none
    if l > 0 then count := count.modify l (· + 1)
  let mut left := 1
  for l in [1:16] do
    left := left * 2
    if count.getD l 0 > left then return none
    left := left - count.getD l 0
  let mut syms : Array Nat := Array.emptyWithCapacity lens.size
  for l in [1:16] do
    if count.getD l 0 > 0 then
      for s in [0:lens.size] do
        if lens.getD s 0 == l then syms := syms.push s
  return some { count, syms }

/-- The next symbol and the bit position after it; `none` on an unassigned
pattern. -/
def Code.read (c : Code) (inp : ByteArray) (bp : Nat) : Option (Nat × Nat) :=
  match c.single with
  | some s => some (s, bp)
  | none => Id.run do
    let mut code := 0
    let mut first := 0
    let mut index := 0
    let mut p := bp
    for len in [1:16] do
      code := code ||| peek inp p 1
      p := p + 1
      let cnt := c.count.getD len 0
      if code < first + cnt then return some (c.syms.getD (index + code - first) 0, p)
      index := index + cnt
      first := (first + cnt) * 2
      code := code * 2
    return none

/-- Bits needed to write `alpha - 1`. -/
def alphabetBits (alpha : Nat) : Nat := Id.run do
  let mut k := 0
  for _ in [0:16] do
    if (1 <<< k) < alpha then k := k + 1
  return k

/-- Order of the code-length code lengths (RFC 7932 section 3.5). -/
def clOrder : Array Nat := #[1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
/-- The fixed variable-length code of the code-length code lengths, indexed
by the next four bits: its length and value. -/
def clPrefixLen : Array Nat := #[2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4]
def clPrefixVal : Array Nat := #[0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5]

/-- Read a prefix code over `alpha` symbols (section 3.4 simple, 3.5 complex). -/
def readCode (inp : ByteArray) (bp0 alpha : Nat) : Option (Code × Nat) := Id.run do
  let mut bp := bp0
  let hskip := peek inp bp 2
  bp := bp + 2
  if hskip == 1 then
    let nsym := peek inp bp 2 + 1
    bp := bp + 2
    let ab := alphabetBits alpha
    let mut ss : Array Nat := #[]
    for _ in [0:nsym] do
      let s := peek inp bp ab
      bp := bp + ab
      if s ≥ alpha || ss.contains s then return none
      ss := ss.push s
    if bp > 8 * inp.size then return none
    if nsym == 1 then return some ({ single := some (ss.getD 0 0) }, bp)
    let lensOf : Array Nat :=
      if nsym == 2 then #[1, 1]
      else if nsym == 3 then #[1, 2, 2]
      else if peek inp bp 1 == 0 then #[2, 2, 2, 2]
      else #[1, 2, 3, 3]
    if nsym == 4 then bp := bp + 1
    let mut lens := Array.replicate alpha 0
    for k in [0:nsym] do
      lens := lens.setIfInBounds (ss.getD k 0) (lensOf.getD k 0)
    match Code.ofLens lens with
    | some c => return some (c, bp)
    | none => return none
  -- complex: the code-length code first
  let mut clens := Array.replicate 18 0
  let mut space : Int := 32
  let mut numCodes := 0
  for i in [hskip:18] do
    let v4 := peek inp bp 4
    bp := bp + clPrefixLen.getD v4 2
    let v := clPrefixVal.getD v4 0
    clens := clens.setIfInBounds (clOrder.getD i 0) v
    if v != 0 then
      space := space - ((32 >>> v : Nat) : Int)
      numCodes := numCodes + 1
      if space ≤ 0 then break
  if !(numCodes == 1 || space == 0) then return none
  let clCode : Code ←
    if numCodes == 1 then
      match (List.range 18).find? (fun s => clens.getD s 0 != 0) with
      | some s => pure { single := some s }
      | none => return none
    else match Code.ofLens clens with
      | some c => pure c
      | none => return none
  -- then the symbol code lengths
  let mut lens := Array.replicate alpha 0
  let mut sym := 0
  let mut prev := 8
  let mut rep := 0
  let mut repLen := 0
  let mut sp : Int := 32768
  for _ in [0:alpha + 1] do
    if sym ≥ alpha || sp ≤ 0 then break
    if bp > 8 * inp.size then return none
    match clCode.read inp bp with
    | none => return none
    | some (p, bp') =>
      bp := bp'
      if p < 16 then
        lens := lens.setIfInBounds sym p
        if p != 0 then
          prev := p
          sp := sp - ((32768 >>> p : Nat) : Int)
        rep := 0
        sym := sym + 1
      else
        let eb := if p == 16 then 2 else 3
        let newLen := if p == 16 then prev else 0
        if repLen != newLen then
          rep := 0
          repLen := newLen
        let old := rep
        if rep > 0 then rep := (rep - 2) <<< eb
        rep := rep + peek inp bp eb + 3
        bp := bp + eb
        let delta := rep - old
        if sym + delta > alpha then return none
        for k in [0:delta] do
          lens := lens.setIfInBounds (sym + k) repLen
        if repLen != 0 then sp := sp - ((delta * (32768 >>> repLen) : Nat) : Int)
        sym := sym + delta
  if sp != 0 || bp > 8 * inp.size then return none
  match Code.ofLens lens with
  | some c => return some (c, bp)
  | none => return none

/-- `VarLenUint8` (section 9.2). -/
def readVarLen8 (inp : ByteArray) (bp : Nat) : Nat × Nat :=
  if peek inp bp 1 == 0 then (0, bp + 1)
  else
    let n := peek inp (bp + 1) 3
    if n == 0 then (1, bp + 4)
    else ((1 <<< n) + peek inp (bp + 4) n, bp + 4 + n)

/-- Block-count codes: base and extra bits (section 6). -/
def blBase : Array Nat :=
  #[1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497,
    753, 1265, 2289, 4337, 8433, 16625]
def blExtra : Array Nat :=
  #[2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24]

def readBlockLen (inp : ByteArray) (c : Code) (bp : Nat) : Option (Nat × Nat) :=
  match c.read inp bp with
  | none => none
  | some (s, bp) =>
    let e := blExtra.getD s 0
    some (blBase.getD s 0 + peek inp bp e, bp + e)

/-! ## Block switching -/

/-- One category's block state: number of types, the block-type and
block-count codes, the current and the previous type, blocks left. -/
structure Blocks where
  n : Nat := 1
  types : Code := {}
  counts : Code := {}
  cur : Nat := 0
  last2 : Nat := 1
  left : Nat := 0
deriving Inhabited

def Blocks.header (inp : ByteArray) (bp : Nat) : Option (Blocks × Nat) := do
  let (v, bp) := readVarLen8 inp bp
  let n := v + 1
  if n < 2 then return ({ n }, bp)
  let (types, bp) ← readCode inp bp (n + 2)
  let (counts, bp) ← readCode inp bp 26
  let (left, bp) ← readBlockLen inp counts bp
  return ({ n, types, counts, left }, bp)

/-- Take one block unit, switching to the next block first if this one is
used up. -/
def Blocks.step (b : Blocks) (inp : ByteArray) (bp : Nat) : Option (Blocks × Nat) := do
  if b.n < 2 then return (b, bp)
  if b.left > 0 then return ({ b with left := b.left - 1 }, bp)
  let (s, bp) ← b.types.read inp bp
  let t0 := if s == 0 then b.last2 else if s == 1 then b.cur + 1 else s - 2
  let t := if t0 ≥ b.n then t0 - b.n else t0
  let (left, bp) ← readBlockLen inp b.counts bp
  if left == 0 then none
  return ({ b with cur := t, last2 := b.cur, left := left - 1 }, bp)

/-! ## Context maps -/

/-- A context map of `size` entries over `ntrees` trees (section 7.3). -/
def readContextMap (inp : ByteArray) (bp0 size ntrees : Nat) : Option (Array Nat × Nat) := Id.run do
  if ntrees < 2 then return some (Array.replicate size 0, bp0)
  let mut bp := bp0
  let rleMax := if peek inp bp 1 == 1 then peek inp (bp + 1) 4 + 1 else 0
  bp := bp + (if rleMax > 0 then 5 else 1)
  let (code, bp1) ← match readCode inp bp (ntrees + rleMax) with
    | some r => pure r
    | none => return none
  bp := bp1
  let mut m : Array Nat := Array.emptyWithCapacity size
  for _ in [0:size] do
    if m.size ≥ size then break
    if bp > 8 * inp.size then return none
    match code.read inp bp with
    | none => return none
    | some (s, bp') =>
      bp := bp'
      if s == 0 then m := m.push 0
      else if s ≤ rleMax then
        let reps := (1 <<< s) + peek inp bp s
        bp := bp + s
        if m.size + reps > size then return none
        m := m ++ Array.replicate reps 0
      else m := m.push (s - rleMax)
  if m.size != size then return none
  let imtf := peek inp bp 1
  bp := bp + 1
  if imtf == 1 then
    let mut mtf : Array Nat := (List.range 256).toArray
    for i in [0:m.size] do
      let idx := m.getD i 0
      let v := mtf.getD idx 0
      m := m.setIfInBounds i v
      mtf := #[v] ++ (mtf.extract 0 idx) ++ (mtf.extract (idx + 1) 256)
  return some (m, bp)

/-! ## Dictionary words -/

/-- `w` with byte `i` replaced, unchanged past its end. -/
def setByte (w : ByteArray) (i : Nat) (v : UInt8) : ByteArray :=
  if h : i < w.size then w.set i v h else w

/-- The simplified UTF-8 uppercasing of RFC 7932 section 8 at byte `i` of
`w`: returns the new word and how many bytes the step covered. -/
def upperAt (w : ByteArray) (i : Nat) : ByteArray × Nat :=
  let c := at' w i
  if c < 0xC0 then
    (if 97 ≤ c && c ≤ 122 then setByte w i (c ^^^ 32) else w, 1)
  else if c < 0xE0 then
    (setByte w (i + 1) (at' w (i + 1) ^^^ 32), 2)
  else
    (setByte w (i + 2) (at' w (i + 2) ^^^ 5), 3)

/-- Transform `tid` applied to `word` (section 8). -/
def transformWord (word : ByteArray) (tid : Nat) : ByteArray := Id.run do
  let (pre, typ, suf) := BrotliData.transforms.getD tid (#[], 0, #[])
  let mut w := word
  if typ ≤ 9 then w := w.extract 0 (w.size - typ)
  else if 12 ≤ typ && typ ≤ 20 then w := w.extract (typ - 11) w.size
  if typ == 10 && w.size > 0 then w := (upperAt w 0).1
  else if typ == 11 then
    let mut i := 0
    for _ in [0:w.size] do
      if i ≥ w.size then break
      let (w', step) := upperAt w i
      w := w'
      i := i + step
  return ⟨pre⟩ ++ w ++ ⟨suf⟩

/-! ## Commands -/

/-- Insert and copy length codes (section 5): extra bits; the bases are
their running sums from 0 and 2. -/
def insExtra : Array Nat := #[0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24]
def copyExtra : Array Nat := #[0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24]

def runningSums (extra : Array Nat) (start : Nat) : Array Nat := Id.run do
  let mut out : Array Nat := #[]
  let mut v := start
  for e in extra do
    out := out.push v
    v := v + (1 <<< e)
  return out

def insBase : Array Nat := runningSums insExtra 0
def copyBase : Array Nat := runningSums copyExtra 2

/-- Per 64-symbol cell of the insert-and-copy alphabet: the insert code base
(bits 3–4) and copy code base (bits 0–1, times 8).  Cells 0 and 1 use the
last distance implicitly. -/
def cellPos : Array Nat := #[0, 1, 0, 1, 8, 9, 2, 16, 10, 17, 18]

/-- Distance short codes 0–15 (section 4): which ring entry (0 = last) and
the delta added to it. -/
def shortIdx : Array Nat := #[0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1]
def shortDelta : Array Int := #[0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3]

/-- The stream's window size, from its `WBITS` header, and the bit position
after it; `none` for the reserved/large-window code. -/
def windowOf (inp : ByteArray) : Option (Nat × Nat) :=
  if peek inp 0 1 == 0 then some ((1 <<< 16) - 16, 1)
  else
    let n := peek inp 1 3
    if n != 0 then some ((1 <<< (17 + n)) - 16, 4)
    else
      let m := peek inp 4 3
      if m == 1 then none
      else if m != 0 then some ((1 <<< (8 + m)) - 16, 7)
      else some ((1 <<< 17) - 16, 7)

/-- Decode the Brotli stream `inp` into exactly `cap` bytes; `none` if it is
malformed, ends early or would write more. -/
def decompress (inp : ByteArray) (cap : Nat) : Option ByteArray := Id.run do
  let nbits := 8 * inp.size
  let some (window, bp0) := windowOf inp | return none
  let mut bp := bp0
  let mut out := ByteArray.emptyWithCapacity (Nat.min cap (1 <<< 20))
  -- the last four distances, last first
  let mut ring : Array Nat := #[4, 11, 15, 16]
  let mut done := false
  for _ in [0:nbits + 1] do
    if bp > nbits then return none
    let isLast := peek inp bp 1 == 1
    bp := bp + 1
    if isLast then
      let empty := peek inp bp 1 == 1
      bp := bp + 1
      if empty then
        done := true
        break
    let mn := peek inp bp 2
    bp := bp + 2
    if mn == 3 then
      -- a metadata block: skipped
      if isLast || peek inp bp 1 != 0 then return none
      let skipBytes := peek inp (bp + 1) 2
      bp := bp + 3
      let mut skip := 0
      for k in [0:skipBytes] do
        skip := skip ||| (peek inp bp 8 <<< (8 * k))
        bp := bp + 8
      if skipBytes > 1 && skip >>> (8 * (skipBytes - 1)) == 0 then return none
      if skipBytes > 0 then skip := skip + 1
      bp := (bp + 7) / 8 * 8 + 8 * skip
      continue
    let nib := mn + 4
    let mut mlen := 0
    for k in [0:nib] do
      mlen := mlen ||| (peek inp bp 4 <<< (4 * k))
      bp := bp + 4
    if nib > 4 && mlen >>> (4 * (nib - 1)) == 0 then return none
    mlen := mlen + 1
    let target := out.size + mlen
    if target > cap then return none
    if !isLast then
      let unc := peek inp bp 1
      bp := bp + 1
      if unc == 1 then
        let p := (bp + 7) / 8
        if p + mlen > inp.size then return none
        out := out ++ inp.extract p (p + mlen)
        bp := 8 * (p + mlen)
        continue
    -- a compressed meta-block: its header
    let some (bL0, b1) := Blocks.header inp bp | return none
    let some (bI0, b2) := Blocks.header inp b1 | return none
    let some (bD0, b3) := Blocks.header inp b2 | return none
    let npostfix := peek inp b3 2
    let ndirect := peek inp (b3 + 2) 4 <<< npostfix
    bp := b3 + 6
    let mut cmodes : Array Nat := #[]
    for _ in [0:bL0.n] do
      cmodes := cmodes.push (peek inp bp 2)
      bp := bp + 2
    let (ntl, b4) := readVarLen8 inp bp
    let some (cmapL, b5) := readContextMap inp b4 (64 * bL0.n) (ntl + 1) | return none
    let (ntd, b6) := readVarLen8 inp b5
    let some (cmapD, b7) := readContextMap inp b6 (4 * bD0.n) (ntd + 1) | return none
    bp := b7
    let mut treesL : Array Code := #[]
    for _ in [0:ntl + 1] do
      let some (c, b) := readCode inp bp 256 | return none
      treesL := treesL.push c
      bp := b
    let mut treesI : Array Code := #[]
    for _ in [0:bI0.n] do
      let some (c, b) := readCode inp bp 704 | return none
      treesI := treesI.push c
      bp := b
    let mut treesD : Array Code := #[]
    for _ in [0:ntd + 1] do
      let some (c, b) := readCode inp bp (16 + ndirect + (48 <<< npostfix)) | return none
      treesD := treesD.push c
      bp := b
    -- its commands
    let mut bL := bL0
    let mut bI := bI0
    let mut bD := bD0
    for _ in [0:mlen + nbits + 1] do
      if out.size ≥ target then break
      if bp > nbits then return none
      let some (bI', b) := bI.step inp bp | return none
      bI := bI'
      let some (cmd, b) := (treesI.getD bI.cur default).read inp b | return none
      let cell := cmd >>> 6
      let cp := cellPos.getD cell 0
      let insCode := (cp &&& 0x18) + ((cmd >>> 3) &&& 7)
      let copyCode := ((cp <<< 3) &&& 0x18) + (cmd &&& 7)
      let ie := insExtra.getD insCode 0
      let ilen := insBase.getD insCode 0 + peek inp b ie
      let ce := copyExtra.getD copyCode 0
      let clen := copyBase.getD copyCode 0 + peek inp (b + ie) ce
      bp := b + ie + ce
      if out.size + ilen > target then return none
      for _ in [0:ilen] do
        let some (bL', b) := bL.step inp bp | return none
        bL := bL'
        let p1 := if out.size ≥ 1 then (at' out (out.size - 1)).toNat else 0
        let p2 := if out.size ≥ 2 then (at' out (out.size - 2)).toNat else 0
        let mode := cmodes.getD bL.cur 0
        let ctx := (at' ctxLut (512 * mode + p1)).toNat ||| (at' ctxLut (512 * mode + 256 + p2)).toNat
        let some (lit, b) := (treesL.getD (cmapL.getD (64 * bL.cur + ctx) 0) default).read inp b
          | return none
        out := out.push lit.toUInt8
        bp := b
      if bp > nbits then return none
      if out.size ≥ target then break
      -- the distance
      let mut dist := ring.getD 0 4
      let mut keep := true
      if cell ≥ 2 then
        let some (bD', b) := bD.step inp bp | return none
        bD := bD'
        let dctx := if clen > 4 then 3 else clen - 2
        let some (dc, b) := (treesD.getD (cmapD.getD (4 * bD.cur + dctx) 0) default).read inp b
          | return none
        bp := b
        if dc < 16 then
          let d : Int := (ring.getD (shortIdx.getD dc 0) 1 : Int) + shortDelta.getD dc 0
          if d ≤ 0 then return none
          dist := d.toNat
          keep := dc == 0
        else if dc < 16 + ndirect then
          dist := dc - 15
          keep := false
        else
          let x := dc - ndirect - 16
          let ndb := 1 + (x >>> (npostfix + 1))
          let hcode := x >>> npostfix
          let lcode := x &&& ((1 <<< npostfix) - 1)
          let offset := ((2 + (hcode &&& 1)) <<< ndb) - 4
          dist := ((offset + peek inp bp ndb) <<< npostfix) + lcode + ndirect + 1
          bp := bp + ndb
          keep := false
      let maxDist := Nat.min window out.size
      if dist > maxDist then
        -- a static dictionary word
        if clen < 4 || clen > 24 then return none
        let nb := dictSizeBits.getD clen 0
        let wid := dist - maxDist - 1
        let tid := wid >>> nb
        if tid ≥ 121 then return none
        let off := dictOffsets.getD clen 0 + (wid &&& ((1 <<< nb) - 1)) * clen
        let w := transformWord (dict.extract off (off + clen)) tid
        if out.size + w.size > target then return none
        out := out ++ w
      else
        if !keep then ring := #[dist, ring.getD 0 0, ring.getD 1 0, ring.getD 2 0]
        if out.size + clen > target then return none
        for _ in [0:clen] do
          out := out.push (at' out (out.size - dist))
    if out.size != target then return none
    if isLast then
      done := true
      break
  if done && out.size == cap then return some out else return none

end LeanSvg.Brotli
