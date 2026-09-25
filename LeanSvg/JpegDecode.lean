import LeanSvg.ImageData
import LeanSvg.Jpeg.Huffman
import LeanSvg.Jpeg.Idct

/-!
# JPEG decoder (T62; interface in `LeanSvg/ImageData.lean`)

A total port of what `zune-jpeg` 0.5.15 (resvg 0.48.1's JPEG decoder, asked
for RGBA output) does on well-formed files: baseline/extended sequential and
progressive Huffman JPEG, 8-bit, one component (gray) or three (YCbCr), any
sampling factors zune decodes correctly, restart intervals.

Pipeline: markers → per-scan entropy decoding into per-component i16
coefficient planes (natural order, quantized, as zune's progressive path
keeps them) → dequantize + `Jpeg.idct` into 8-bit sample planes → per output
pixel, zune's chroma upsampling (triangle filter, `(3a + b + 2) >> 2`,
replicated at the *padded* plane edges; nearest for other ratios) → `Jpeg.ycc`.
No EXIF orientation: zune ignores it, so does resvg.

`none` (never a partial image) on: bad markers or segment lengths, a
precision other than 8, arithmetic coding / lossless / hierarchical SOFs,
`w*h > maxPixels` or a side over 16384 (zune's limit), checked at SOF before
any allocation; CMYK/YCCK/RGB/two-channel data (zune decodes these to
garbage or fails when asked for RGBA); sampling layouts zune mis-decodes;
undecodable Huffman codes; coefficient positions past the band; entropy data
that runs out (a scan whose decoding reads past its bytes); more than 100
scans; or no EOI (except a sequential image whose first scan already holds
every component, where zune stops reading, and so does this).

Where zune is lenient on corrupt data (fills the rest with grey, keeps going)
this decoder returns `none`, as the image contract requires.
-/

namespace LeanSvg.JpegDecode

open Jpeg

@[inline] private def setB (a : ByteArray) (i : Nat) (v : UInt8) : ByteArray :=
  if h : i < a.size then a.set i v h else a

@[inline] private def u16 (bs : ByteArray) (p : Nat) : Nat := byteAt bs p * 256 + byteAt bs (p + 1)

/-- `n` zero bytes. -/
private def zeros (n : Nat) : ByteArray := Id.run do
  let mut a := ByteArray.emptyWithCapacity n
  for _ in [0:n] do a := a.push 0
  return a

/-- Zigzag position → natural (row-major) position. -/
def unzigzag : Array Nat := #[
   0,  1,  8, 16,  9,  2,  3, 10, 17, 24, 32, 25, 18, 11,  4,  5,
  12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13,  6,  7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]

@[inline] private def zz (k : Nat) : Nat := unzigzag.getD k 63

/-- Wrap to i16, as zune stores progressive coefficients. -/
@[inline] private def w16 (x : Int) : Int := (x + 32768) % 65536 - 32768

/-! ## i16 coefficient planes (little-endian pairs in a `ByteArray`) -/

@[inline] private def getC (a : ByteArray) (i : Nat) : Int :=
  let u := byteAt a (2 * i) + byteAt a (2 * i + 1) * 256
  if u ≥ 32768 then (u : Int) - 65536 else u

@[inline] private def setC (a : ByteArray) (i : Nat) (v : Int) : ByteArray :=
  let u := (v % 65536).toNat
  setB (setB a (2 * i) (u % 256).toUInt8) (2 * i + 1) (u / 256).toUInt8

private def loadBlock (a : ByteArray) (b : Nat) : Array Int := Id.run do
  let mut blk := Array.emptyWithCapacity 64
  for i in [0:64] do blk := blk.push (getC a (b * 64 + i))
  return blk

private def storeBlock (a : ByteArray) (b : Nat) (blk : Array Int) : ByteArray := Id.run do
  let mut a := a
  for i in [0:64] do a := setC a (b * 64 + i) (blk.getD i 0)
  return a

/-! ## Frame and scan headers -/

structure Comp where
  id : Nat
  h : Nat
  v : Nat
  tq : Nat
  /-- Blocks per row / column of this component's plane (whole MCUs). -/
  bw : Nat := 0
  bh : Nat := 0

structure Frame where
  prog : Bool
  w : Nat
  h : Nat
  comps : Array Comp
  hmax : Nat := 1
  vmax : Nat := 1
  mcux : Nat := 0
  mcuy : Nat := 0

structure Scan where
  /-- (component index, DC table, AC table) -/
  comps : Array (Nat × Nat × Nat)
  ss : Nat
  se : Nat
  ah : Nat
  al : Nat

/-- Colour space as zune tracks it: 0 YCbCr, 1 Luma, 2 CMYK, 3 YCCK, 4 RGB. -/
abbrev Cs := Nat

/-- Parse SOF at `p` (just after the marker). Returns the frame and the
colour space after zune's SOF rules. -/
def parseSof (bs : ByteArray) (p : Nat) (prog : Bool) (cs : Cs) : Option (Frame × Cs) := Id.run do
  let len := u16 bs p
  if byteAt bs (p + 2) != 8 then return none
  let h := u16 bs (p + 3)
  let w := u16 bs (p + 5)
  if w == 0 || h == 0 || w > 16384 || h > 16384 then return none
  if w * h > ImageData.maxPixels then return none
  let nc := byteAt bs (p + 7)
  if nc == 0 || nc > 4 || len != 8 + 3 * nc || p + len > bs.size then return none
  let mut comps : Array Comp := #[]
  for i in [0:nc] do
    let q := p + 8 + 3 * i
    let hv := byteAt bs (q + 1)
    let c : Comp := { id := byteAt bs q, h := hv / 16, v := hv % 16, tq := byteAt bs (q + 2) }
    if !(c.h == 1 || c.h == 2 || c.h == 4) || c.v == 0 || c.v > 4 || c.tq ≥ 4 then return none
    comps := comps.push c
  let cs := if nc == 1 then 1 else if nc == 4 && cs == 0 then 2 else cs
  -- one component: a single non-interleaved scan covers ceil(w/8) x ceil(h/8)
  -- blocks whatever its sampling factors say (zune's `reset_params`)
  if nc == 1 then comps := comps.modify 0 fun c => { c with h := 1, v := 1 }
  let hmax := comps.foldl (fun m c => max m c.h) 1
  let vmax := comps.foldl (fun m c => max m c.v) 1
  let mcux := (w + 8 * hmax - 1) / (8 * hmax)
  let mcuy := (h + 8 * vmax - 1) / (8 * vmax)
  let cs' := comps.map fun c => { c with bw := mcux * c.h, bh := mcuy * c.v }
  return some ({ prog, w, h, comps := cs', hmax, vmax, mcux, mcuy }, cs)

/-- Sampling layouts whose zune output is the plain full-plane filter below:
component 0 carries the maximum factors (zune sizes planes with a running
maximum), factors divide the maximum, a vertically upsampled component has
`v = 1`, and nearest-neighbour ratios are not mixed with vertical triangles. -/
def samplingOk (f : Frame) : Bool := Id.run do
  let c0 := f.comps.getD 0 { id := 0, h := 1, v := 1, tq := 0 }
  if c0.h != f.hmax || c0.v != f.vmax then return false
  let mut anyV := false
  let mut anyGeneric := false
  for c in f.comps do
    if f.hmax % c.h != 0 || f.vmax % c.v != 0 then return false
    let hs := f.hmax / c.h
    let vs := f.vmax / c.v
    if hs ≤ 2 && vs == 2 then
      anyV := true
      if c.v != 1 then return false
    if hs > 2 || vs > 2 then anyGeneric := true
  return !(anyV && anyGeneric)

/-- Parse SOS at `p` (just after the marker). -/
def parseSos (bs : ByteArray) (p : Nat) (f : Frame) : Option Scan := Id.run do
  let len := u16 bs p
  let ns := byteAt bs (p + 2)
  if ns == 0 || ns > 4 || len != 6 + 2 * ns || p + len > bs.size then return none
  let mut comps : Array (Nat × Nat × Nat) := #[]
  let mut seen : Array Nat := #[]
  for i in [0:ns] do
    let id := byteAt bs (p + 3 + 2 * i)
    let t := byteAt bs (p + 4 + 2 * i)
    if seen.contains id then return none
    seen := seen.push id
    let some ci := f.comps.findIdx? (·.id == id) | return none
    if t / 16 ≥ 4 || t % 16 ≥ 4 then return none
    comps := comps.push (ci, t / 16, t % 16)
  let q := p + 3 + 2 * ns
  let ss := byteAt bs q
  let se := byteAt bs (q + 1)
  let ah := byteAt bs (q + 2) / 16
  let al := byteAt bs (q + 2) % 16
  if ss > 63 || se > 63 || ah > 13 || al > 13 then return none
  return some { comps, ss, se, ah, al }

/-- Parse DQT at `p` into the four tables (natural order). -/
def parseDqt (bs : ByteArray) (p : Nat) (qt : Array (Option (Array Nat))) :
    Option (Array (Option (Array Nat))) := Id.run do
  let len := u16 bs p
  if len < 2 || p + len > bs.size then return none
  let mut qt := qt
  let mut q := p + 2
  let stop := p + len
  for _ in [0:len] do
    if q ≥ stop then break
    let info := byteAt bs q
    let pq := info / 16
    let tq := info % 16
    if pq > 1 || tq ≥ 4 || q + 1 + 64 * (pq + 1) > stop then return none
    let mut t := Array.replicate 64 0
    for k in [0:64] do
      let v := if pq == 0 then byteAt bs (q + 1 + k) else u16 bs (q + 1 + 2 * k)
      t := t.setIfInBounds (zz k) v
    qt := qt.setIfInBounds tq (some t)
    q := q + 1 + 64 * (pq + 1)
  return some qt

/-- Parse DHT at `p` into the DC and AC table sets. -/
def parseDht (bs : ByteArray) (p : Nat) (dc ac : Array (Option Huff)) :
    Option (Array (Option Huff) × Array (Option Huff)) := Id.run do
  let len := u16 bs p
  if len < 2 || p + len > bs.size then return none
  let mut dc := dc
  let mut ac := ac
  let mut q := p + 2
  let mut left := len - 2
  for _ in [0:len] do
    if left ≤ 16 then break
    let info := byteAt bs q
    let tc := info / 16
    let th := info % 16
    if th ≥ 4 || tc > 1 then return none
    let bits := (Array.range 16).map fun i => byteAt bs (q + 1 + i)
    let n := bits.foldl (· + ·) 0
    left := left - 17
    if n > 256 || n > left then return none
    left := left - n
    let vals := bs.extract (q + 17) (q + 17 + n)
    let some t := Huff.build bits vals (tc == 0) | return none
    if tc == 0 then dc := dc.setIfInBounds th (some t) else ac := ac.setIfInBounds th (some t)
    q := q + 17 + n
  if left > 0 then return none
  return some (dc, ac)

/-- Entropy-coded data starting at `start`: its restart intervals with byte
stuffing removed, and the index of the `FF` of the marker that ends it
(`bs.size` if the data just ends). -/
def scanData (bs : ByteArray) (start : Nat) : Array ByteArray × Nat := Id.run do
  let mut ivs : Array ByteArray := #[]
  let mut cur := ByteArray.empty
  let mut i := start
  for _ in [start:bs.size] do
    if i ≥ bs.size then break
    let b := byteAt bs i
    if b != 0xFF then
      cur := cur.push b.toUInt8
      i := i + 1
    else
      let mut j := i + 1
      for _ in [i + 1:bs.size] do
        if byteAt bs j == 0xFF then j := j + 1 else break
      let m := byteAt bs j
      if m == 0 then
        cur := cur.push 0xFF
        i := j + 1
      else if 0xD0 ≤ m && m ≤ 0xD7 then
        ivs := ivs.push cur
        cur := ByteArray.empty
        i := j + 1
      else
        return (ivs.push cur, i)
  return (ivs.push cur, bs.size)

/-! ## Block decoding (one Huffman-coded block or band) -/

/-- Sequential block: DC difference plus all 63 AC coefficients. -/
def decSeq (d : ByteArray) (pos : Nat) (dc ac : Huff) (pred : Int32) :
    Option (Array Int × Nat × Int32) := Id.run do
  let some (s, pos) := dc.decode d pos | return none
  let (diff, pos) := receive d pos s
  let pred := pred + Int32.ofInt diff
  let mut blk : Array Int := (Array.replicate 64 0).setIfInBounds 0 pred.toInt
  let mut pos := pos
  let mut k := 1
  for _ in [0:64] do
    if k ≥ 64 then break
    let some (rs, p') := ac.decode d pos | return none
    pos := p'
    let r := rs / 16
    let s := rs % 16
    if s == 0 then
      if r == 15 then k := k + 16 else break
    else
      k := k + r
      if k > 63 then return none
      let (v, p') := receive d pos s
      pos := p'
      blk := blk.setIfInBounds (zz k) v
      k := k + 1
  return some (blk, pos, pred)

/-- Progressive AC first pass over band `ss..se`; `eob` is the end-of-band run
left after this block. -/
def decAcFirst (d : ByteArray) (pos : Nat) (ac : Huff) (ss se al : Nat) (blk : Array Int) :
    Option (Array Int × Nat × Nat) := Id.run do
  let mut blk := blk
  let mut pos := pos
  let mut k := ss
  for _ in [0:64] do
    let some (rs, p') := ac.decode d pos | return none
    pos := p'
    let r := rs / 16
    let s := rs % 16
    if s != 0 then
      k := k + r
      if k > se then return none
      let (v, p') := receive d pos s
      pos := p'
      blk := blk.setIfInBounds (zz k) (w16 (v * (pow2 al : Nat)))
      k := k + 1
    else if r != 15 then
      let e := pow2 r + peekBits d pos r - 1
      return some (blk, pos + r, e)
    else k := k + 16
    if k > se then break
  return some (blk, pos, 0)

/-- Refine a nonzero coefficient with one correction bit (zune's rule). -/
@[inline] private def refineCoef (c : Int) (bitSet : Bool) (bit : Nat) : Int :=
  if bitSet && ((c % 65536).toNat &&& bit) == 0 then
    if c ≥ 0 then w16 (c + bit) else w16 (c - bit)
  else c

/-- Progressive AC refinement pass (zune's `decode_mcu_ac_refine`). -/
def decAcRefine (d : ByteArray) (pos : Nat) (ac : Huff) (ss se al : Nat) (blk : Array Int)
    (eob : Nat) : Option (Array Int × Nat × Nat) := Id.run do
  let bit := pow2 al
  let mut blk := blk
  let mut pos := pos
  let mut eob := eob
  let mut k := ss
  if eob == 0 then
    for _ in [0:64] do
      let some (rs, p') := ac.decode d pos | return none
      pos := p'
      let mut r : Int := rs / 16
      let s := rs % 16
      let mut sym : Int := 0
      if s == 0 then
        if rs / 16 != 15 then
          eob := pow2 (rs / 16) + peekBits d pos (rs / 16)
          pos := pos + rs / 16
          break
      else
        sym := if peekBits d pos 1 == 1 then bit else -(bit : Int)
        pos := pos + 1
      if k ≤ se then
        for _ in [0:64] do
          let c := blk.getD (zz k) 0
          if c != 0 then
            let b := peekBits d pos 1 == 1
            pos := pos + 1
            blk := blk.setIfInBounds (zz k) (refineCoef c b bit)
          else
            r := r - 1
            if r < 0 then break
          if k == se then break
          k := k + 1
      if sym != 0 then blk := blk.setIfInBounds (zz k) sym
      k := k + 1
      if k > se then break
  if eob > 0 then
    let mut anyAc := false
    for i in [1:64] do
      if blk.getD i 0 != 0 then anyAc := true
    if anyAc then
      for _ in [0:64] do
        if k > se then break
        let c := blk.getD (zz k) 0
        if c != 0 then
          let b := peekBits d pos 1 == 1
          pos := pos + 1
          blk := blk.setIfInBounds (zz k) (refineCoef c b bit)
        k := k + 1
    eob := eob - 1
  return some (blk, pos, eob)

/-! ## Scans -/

/-- Blocks a scan's unit `u` covers: (component index, block index). -/
def unitBlocks (f : Frame) (sc : Scan) (u : Nat) : Array (Nat × Nat) := Id.run do
  if sc.comps.size == 1 then
    let (ci, _, _) := sc.comps.getD 0 (0, 0, 0)
    let c := f.comps.getD ci { id := 0, h := 1, v := 1, tq := 0 }
    let uw := (f.w * c.h + 8 * f.hmax - 1) / (8 * f.hmax)
    return #[(ci, (u / uw) * c.bw + u % uw)]
  let mx := u % f.mcux
  let my := u / f.mcux
  let mut out := #[]
  for (ci, _, _) in sc.comps do
    let c := f.comps.getD ci { id := 0, h := 1, v := 1, tq := 0 }
    for v in [0:c.v] do
      for h in [0:c.h] do
        out := out.push (ci, (my * c.v + v) * c.bw + mx * c.h + h)
  return out

/-- Number of units (MCUs, or blocks for a one-component scan). -/
def unitCount (f : Frame) (sc : Scan) : Nat :=
  if sc.comps.size == 1 then
    let (ci, _, _) := sc.comps.getD 0 (0, 0, 0)
    let c := f.comps.getD ci { id := 0, h := 1, v := 1, tq := 0 }
    ((f.w * c.h + 8 * f.hmax - 1) / (8 * f.hmax)) * ((f.h * c.v + 8 * f.vmax - 1) / (8 * f.vmax))
  else f.mcux * f.mcuy

/-- Decode one scan into the coefficient planes. -/
def decodeScan (f : Frame) (sc : Scan) (dcT acT : Array (Option Huff)) (ri : Nat)
    (ivs : Array ByteArray) (coef : Array ByteArray) : Option (Array ByteArray) := Id.run do
  let ns := sc.comps.size
  if f.prog then
    if sc.ss == 0 && sc.se != 0 then return none
    if ns > 1 && sc.se != 0 then return none
    if sc.ss > sc.se then return none
  let dcFirst := f.prog && sc.ss == 0 && sc.ah == 0
  let needDc := !f.prog || dcFirst
  let needAc := !f.prog || sc.ss != 0
  -- tables per scan component
  let mut dcs : Array Huff := #[]
  let mut acs : Array Huff := #[]
  for (_, td, ta) in sc.comps do
    let empty : Huff := ⟨#[], #[], #[], ByteArray.empty⟩
    match needDc, dcT.getD td none with
    | true, none => return none
    | _, t => dcs := dcs.push (t.getD empty)
    match needAc, acT.getD ta none with
    | true, none => return none
    | _, t => acs := acs.push (t.getD empty)
  let units := unitCount f sc
  let nIv := if ri == 0 then 1 else (units + ri - 1) / ri
  if ivs.size < nIv || (ri == 0 && ivs.size != 1) then return none
  let mut coef := coef
  let mut preds : Array Int32 := Array.replicate f.comps.size 0
  let mut eob := 0
  let mut iv := 0
  let mut d := ivs.getD 0 ByteArray.empty
  let mut pos := 0
  for u in [0:units] do
    if ri != 0 && u != 0 && u % ri == 0 then
      iv := iv + 1
      d := ivs.getD iv ByteArray.empty
      pos := 0
      preds := Array.replicate f.comps.size 0
      eob := 0
    for (ci, b) in unitBlocks f sc u do
      let si := (sc.comps.findIdx? (·.1 == ci)).getD 0
      let dc := dcs.getD si ⟨#[], #[], #[], ByteArray.empty⟩
      let ac := acs.getD si ⟨#[], #[], #[], ByteArray.empty⟩
      if !f.prog then
        let some (blk, p', pr) := decSeq d pos dc ac (preds.getD ci 0) | return none
        pos := p'
        preds := preds.setIfInBounds ci pr
        coef := coef.modify ci (storeBlock · b blk)
      else if sc.ss == 0 then
        if sc.ah == 0 then
          let some (s, p') := dc.decode d pos | return none
          let (diff, p') := receive d p' s
          pos := p'
          let pr := preds.getD ci 0 + Int32.ofInt diff
          preds := preds.setIfInBounds ci pr
          coef := coef.modify ci (setC · (b * 64) (w16 (w16 pr.toInt * (pow2 sc.al : Nat))))
        else
          let c := getC (coef.getD ci ByteArray.empty) (b * 64)
          let c := if peekBits d pos 1 == 1 then w16 (c + (pow2 sc.al : Nat)) else c
          pos := pos + 1
          coef := coef.modify ci (setC · (b * 64) c)
      else if sc.ah == 0 then
        if eob > 0 then eob := eob - 1
        else
          let some (blk, p', e) := decAcFirst d pos ac sc.ss sc.se sc.al
            (loadBlock (coef.getD ci ByteArray.empty) b)
            | return none
          pos := p'
          eob := e
          coef := coef.modify ci (storeBlock · b blk)
      else
        let some (blk, p', e) := decAcRefine d pos ac sc.ss sc.se sc.al
          (loadBlock (coef.getD ci ByteArray.empty) b) eob
          | return none
        pos := p'
        eob := e
        coef := coef.modify ci (storeBlock · b blk)
    -- entropy data exhausted: truncated or corrupt
    if pos > 8 * d.size then return none
  return some coef

/-! ## Samples and pixels -/

/-- Dequantize and inverse-transform every block of a component. -/
def samplePlane (c : Comp) (qt : Array Nat) (coef : ByteArray) : ByteArray := Id.run do
  let sw := c.bw * 8
  let mut out := zeros (sw * c.bh * 8)
  for bj in [0:c.bh] do
    for bx in [0:c.bw] do
      let b := bj * c.bw + bx
      let mut t : Array Int32 := Array.emptyWithCapacity 64
      for i in [0:64] do
        t := t.push (Int32.ofInt (getC coef (b * 64 + i)) * Int32.ofNat (qt.getD i 0))
      let s := idct t
      for y in [0:8] do
        for x in [0:8] do
          out := setB out ((bj * 8 + y) * sw + bx * 8 + x) (s.getD (y * 8 + x) 0)
  return out

/-- zune's vertical triangle `(3a + b + 2) >> 2` at column `cx` between rows
`r` (nearest) and `rb`; with `rb = r` it is just the sample. -/
@[inline] private def vTri (pl : ByteArray) (sw r rb cx : Nat) : Nat :=
  (3 * byteAt pl (r * sw + cx) + byteAt pl (rb * sw + cx) + 2) / 4

/-- zune's horizontal triangle filter over a row of `sw` vertically filtered
samples: output column `x` of `2 * sw`. -/
@[inline] private def hTri (pl : ByteArray) (sw r rb x : Nat) : Nat :=
  let i := x / 2
  if x == 0 then vTri pl sw r rb 0
  else if x + 1 == 2 * sw then vTri pl sw r rb (sw - 1)
  else if x % 2 == 0 then (3 * vTri pl sw r rb i + vTri pl sw r rb (i - 1) + 2) / 4
  else (3 * vTri pl sw r rb i + vTri pl sw r rb (i + 1) + 2) / 4

/-- Component sample at output pixel `(x, y)`, upsampled as zune does:
triangle filters for 2x ratios (clamped at the padded plane edges), nearest
for the rest. `sw`/`sh` are the plane's size, `hs`/`vs` its ratios. -/
@[inline] private def sampleAt (pl : ByteArray) (sw sh hs vs x y : Nat) : Nat :=
  if hs == 1 && vs == 1 then byteAt pl (y * sw + x)
  else if hs > 2 || vs > 2 then byteAt pl ((y / vs) * sw + x / hs)
  else
    -- vertical: output row y sits in plane row y/vs, its neighbour above
    -- (even y) or below (odd y), clamped
    let r := y / vs
    let rb := if vs == 1 then r else if y % 2 == 0 then r - 1 else min (r + 1) (sh - 1)
    if hs == 1 then vTri pl sw r rb x else hTri pl sw r rb x

/-- Everything but the final size check. -/
def decodeRaw (bs : ByteArray) : Option ImageData.Decoded := Id.run do
  if byteAt bs 0 != 0xFF || byteAt bs 1 != 0xD8 then return none
  let mut qt : Array (Option (Array Nat)) := Array.replicate 4 none
  let mut dcT : Array (Option Huff) := Array.replicate 4 none
  let mut acT : Array (Option Huff) := Array.replicate 4 none
  let mut frame : Option Frame := none
  let mut cs : Cs := 0
  let mut ri := 0
  let mut coef : Array ByteArray := #[]
  let mut qts : Array (Array Nat) := #[]
  let mut scans := 0
  let mut done := false
  let mut p := 2
  for _ in [0:bs.size] do
    if p ≥ bs.size then break
    if byteAt bs p != 0xFF then
      p := p + 1
      continue
    -- skip fill bytes
    let mut j := p + 1
    for _ in [p + 1:bs.size] do
      if byteAt bs j == 0xFF then j := j + 1 else break
    let m := byteAt bs j
    let q := j + 1
    if m == 0 then
      p := q
      continue
    if m == 0xD9 then
      done := true
      break
    if m == 0xC0 || m == 0xC1 || m == 0xC2 then
      if frame.isSome then return none
      let some (f, cs') := parseSof bs q (m == 0xC2) cs | return none
      frame := some f
      cs := cs'
      p := q + u16 bs q
    else if m == 0xC4 then
      let some (d, a) := parseDht bs q dcT acT | return none
      dcT := d
      acT := a
      p := q + u16 bs q
    else if m == 0xDB then
      let some t := parseDqt bs q qt | return none
      qt := t
      p := q + u16 bs q
    else if m == 0xDD then
      if u16 bs q != 4 then return none
      ri := u16 bs (q + 2)
      p := q + 4
    else if m == 0xEE then
      let len := u16 bs q
      if len < 2 || q + len > bs.size then return none
      if frame.isNone || scans == 0 then
        if (bs.extract (q + 2) (q + 7)).data == "Adobe".toUTF8.data then
          if len < 14 then return none
          let t := byteAt bs (q + 13)
          if t == 0 then cs := 2 else if t == 1 then cs := 0 else if t == 2 then cs := 3
          else return none
      p := q + len
    else if m == 0xDA then
      let some f := frame | return none
      let some sc := parseSos bs q f | return none
      if scans == 0 then
        -- headers complete: zune's colour-space and table binding
        let isRgb := f.comps.size == 3 &&
          f.comps.map (·.id) == #['R'.toNat, 'G'.toNat, 'B'.toNat]
        let cs' := if isRgb || (f.comps.size == 3 && cs == 2) then 4 else cs
        let ok := (cs' == 0 && f.comps.size == 3) || (cs' == 1 && f.comps.size == 1)
        if !ok || !samplingOk f then return none
        for c in f.comps do
          let some t := qt.getD c.tq none | return none
          qts := qts.push t
          coef := coef.push (zeros (c.bw * c.bh * 128))
      scans := scans + 1
      if scans > 100 then return none
      let (ivs, next) := scanData bs (q + u16 bs q)
      let some c' := decodeScan f sc dcT acT ri ivs coef | return none
      coef := c'
      p := next
      -- sequential with every component in the first scan: zune stops here
      if !f.prog && scans == 1 && sc.comps.size == f.comps.size then
        done := true
        break
    else if (0xC3 ≤ m && m ≤ 0xCF) || (0xD0 ≤ m && m ≤ 0xD8) || m == 0xDC then
      -- other SOFs (lossless, arithmetic, hierarchical), DAC, stray RST/SOI, DNL
      return none
    else
      let len := u16 bs q
      if len < 2 || q + len > bs.size then return none
      p := q + len
  let some f := frame | return none
  if !done || scans == 0 then return none
  -- samples
  let mut planes : Array ByteArray := #[]
  for i in [0:f.comps.size] do
    planes := planes.push (samplePlane (f.comps.getD i { id := 0, h := 1, v := 1, tq := 0 })
      (qts.getD i #[]) (coef.getD i ByteArray.empty))
  let gray := f.comps.size == 1
  let c0 := f.comps.getD 0 { id := 0, h := 1, v := 1, tq := 0 }
  let c1 := f.comps.getD 1 c0
  let c2 := f.comps.getD 2 c0
  let p0 := planes.getD 0 ByteArray.empty
  let p1 := planes.getD 1 ByteArray.empty
  let p2 := planes.getD 2 ByteArray.empty
  let (sw0, sh0, hs0, vs0) := (c0.bw * 8, c0.bh * 8, f.hmax / c0.h, f.vmax / c0.v)
  let (sw1, sh1, hs1, vs1) := (c1.bw * 8, c1.bh * 8, f.hmax / c1.h, f.vmax / c1.v)
  let (sw2, sh2, hs2, vs2) := (c2.bw * 8, c2.bh * 8, f.hmax / c2.h, f.vmax / c2.v)
  let mut px := ByteArray.emptyWithCapacity (f.w * f.h * 4)
  for y in [0:f.h] do
    for x in [0:f.w] do
      let yv := sampleAt p0 sw0 sh0 hs0 vs0 x y
      if gray then
        px := (((px.push yv.toUInt8).push yv.toUInt8).push yv.toUInt8).push 255
      else
        let (r, g, b) := ycc yv (sampleAt p1 sw1 sh1 hs1 vs1 x y) (sampleAt p2 sw2 sh2 hs2 vs2 x y)
        px := (((px.push r).push g).push b).push 255
  return some ⟨f.w, f.h, px⟩

/-- Decode a JPEG to straight RGBA8. The final check makes the
`ImageData` contract hold by construction (`spec/JpegDecode.lean`). -/
def decode (bs : ByteArray) : Option ImageData.Decoded :=
  match decodeRaw bs with
  | some d =>
    if d.px.size = d.w * d.h * 4 ∧ 0 < d.w ∧ 0 < d.h ∧ d.w * d.h ≤ ImageData.maxPixels then
      some d
    else none
  | none => none

end LeanSvg.JpegDecode
