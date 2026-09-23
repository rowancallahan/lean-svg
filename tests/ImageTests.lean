import LeanSvg

/-!
# T63 — `<image>` tests

Plain `#guard` checks: this file must compile and print nothing under
`lake env lean tests/ImageTests.lean`.

`StoredPng` below is a test-only PNG decoder for stored (uncompressed) deflate
streams — enough for what `Png.encode` writes and `zlib` level 0 writes: 8-bit
gray / RGB / gray+alpha / RGBA, no interlace, every filter type.  It is *not*
part of the library (the real decoder is T61's `PngDecode`); it drives
`Image.loadWith` end to end before that lands.
-/

namespace StoredPng

open LeanSvg LeanSvg.Bytes

def be32 (b : ByteArray) (i : Nat) : Nat :=
  (at' b i).toNat * 16777216 + (at' b (i + 1)).toNat * 65536 +
  (at' b (i + 2)).toNat * 256 + (at' b (i + 3)).toNat

/-- The concatenated IDAT payload and the IHDR fields `(w, h, depth, ctype, interlace)`. -/
def chunks (b : ByteArray) : Option (ByteArray × Nat × Nat × Nat × Nat × Nat) := Id.run do
  let sig : List UInt8 := [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  if (b.extract 0 8).toList != sig then return none
  let mut i := 8
  let mut idat := ByteArray.empty
  let mut hdr : Option (Nat × Nat × Nat × Nat × Nat) := none
  for _ in [0:b.size] do
    if i + 12 > b.size then break
    let len := be32 b i
    if i + 12 + len > b.size then return none
    let ty := b.extract (i + 4) (i + 8)
    let data := b.extract (i + 8) (i + 8 + len)
    if eqAscii ty "IHDR" then
      hdr := some (be32 data 0, be32 data 4, (at' data 8).toNat, (at' data 9).toNat,
                   (at' data 12).toNat)
    else if eqAscii ty "IDAT" then idat := idat ++ data
    else if eqAscii ty "IEND" then break
    i := i + 12 + len
  return hdr.map fun (w, h, d, c, il) => (idat, w, h, d, c, il)

/-- zlib with stored blocks only. -/
def inflateStored (z : ByteArray) : Option ByteArray := Id.run do
  if z.size < 2 then return none
  let mut i := 2
  let mut out := ByteArray.empty
  for _ in [0:z.size] do
    if i + 5 > z.size then return none
    let hb := at' z i
    if (hb >>> 1) &&& 3 != 0 then return none
    let len := (at' z (i + 1)).toNat + (at' z (i + 2)).toNat * 256
    let nlen := (at' z (i + 3)).toNat + (at' z (i + 4)).toNat * 256
    if len + nlen != 65535 || i + 5 + len > z.size then return none
    out := out ++ z.extract (i + 5) (i + 5 + len)
    i := i + 5 + len
    if hb &&& 1 == 1 then return some out
  return none

@[inline] def paeth (a b c : Nat) : Nat :=
  let p : Int := (a : Int) + b - c
  let pa := (p - a).natAbs
  let pb := (p - b).natAbs
  let pc := (p - c).natAbs
  if pa ≤ pb && pa ≤ pc then a else if pb ≤ pc then b else c

def decode (b : ByteArray) : Option ImageData.Decoded := Id.run do
  let some (idat, w, h, depth, ctype, il) := chunks b | return none
  let ch := match ctype with
    | 0 => 1 | 2 => 3 | 4 => 2 | 6 => 4 | _ => 0
  if depth != 8 || ch == 0 || il != 0 || w == 0 || h == 0 || w * h > ImageData.maxPixels then
    return none
  let some raw := inflateStored idat | return none
  let stride := w * ch
  if raw.size < h * (stride + 1) then return none
  let mut cur := ByteArray.mk (Array.replicate (h * stride) 0)
  for y in [0:h] do
    let ft := at' raw (y * (stride + 1))
    for x in [0:stride] do
      let v := (at' raw (y * (stride + 1) + 1 + x)).toNat
      let a := if x ≥ ch then (at' cur (y * stride + x - ch)).toNat else 0
      let up := if y > 0 then (at' cur ((y - 1) * stride + x)).toNat else 0
      let c := if x ≥ ch && y > 0 then (at' cur ((y - 1) * stride + x - ch)).toNat else 0
      let pred := match ft with
        | 1 => a | 2 => up | 3 => (a + up) / 2 | 4 => paeth a up c | _ => 0
      let k := y * stride + x
      cur := if hk : k < cur.size then cur.set k ((v + pred) % 256).toUInt8 hk else cur
  let mut px := ByteArray.emptyWithCapacity (w * h * 4)
  for i in [0:w * h] do
    let g := at' cur (i * ch)
    match ch with
    | 1 => px := ((px.push g).push g).push g |>.push 255
    | 2 => px := ((px.push g).push g).push g |>.push (at' cur (i * ch + 1))
    | 3 => px := ((px.push g).push (at' cur (i * 3 + 1))).push (at' cur (i * 3 + 2)) |>.push 255
    | _ => px := ((px.push g).push (at' cur (i * 4 + 1))).push (at' cur (i * 4 + 2))
                  |>.push (at' cur (i * 4 + 3))
  return some ⟨w, h, px⟩

end StoredPng


open LeanSvg LeanSvg.Image

def bytesOf (s : String) : ByteArray := s.toUTF8

/-- A plain base64 encoder, to build `data:` URIs here. -/
def b64 (d : ByteArray) : String := Id.run do
  let al := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray
  let mut out := ""
  for g in [0:(d.size + 2) / 3] do
    let b0 := (Bytes.at' d (3 * g)).toNat
    let b1 := (Bytes.at' d (3 * g + 1)).toNat
    let b2 := (Bytes.at' d (3 * g + 2)).toNat
    let v := b0 * 65536 + b1 * 256 + b2
    let n := Nat.min 3 (d.size - 3 * g)
    for k in [0:4] do
      out := out.push (if k ≤ n then al.getD ((v >>> (18 - 6 * k)) % 64) 'A' else '=')
  return out

/-! ## forgiving base64 -/

#guard base64Decode (bytesOf "aGVsbG8=") == some (bytesOf "hello")
#guard base64Decode (bytesOf "aGVsbG8") == some (bytesOf "hello")
#guard base64Decode (bytesOf " aGV\nsbG8 = ") == some (bytesOf "hello")
#guard base64Decode (bytesOf "aGVsbG8==") == none   -- 9 digits: 1 mod 4
#guard base64Decode (bytesOf "aGVs=bG8") == none    -- `=` inside
#guard base64Decode (bytesOf "aGVs!bG8") == none    -- outside the alphabet
#guard base64Decode (bytesOf "a===") == none
#guard base64Decode (bytesOf "") == some ByteArray.empty
#guard b64 (bytesOf "hello") == "aGVsbG8="

/-! ## `data:` URIs -/

#guard dataUri (bytesOf "data:image/png;base64,aGk=") == some ("image/png", bytesOf "hi")
#guard dataUri (bytesOf " DATA:Image/PNG ; BASE64,aG\nk=") == some ("image/png", bytesOf "hi")
#guard dataUri (bytesOf "data:,A%20B%zz") == some ("text/plain", bytesOf "A B%zz")
#guard dataUri (bytesOf "data:;base64,aGk=") == some ("text/plain", bytesOf "hi")
#guard dataUri (bytesOf "data:image/png;base64,aGk=#frag") == some ("image/png", bytesOf "hi")
#guard dataUri (bytesOf "data:image/png;base64,a") == none
#guard dataUri (bytesOf "data:image/png;base64") == none      -- no comma
#guard dataUri (bytesOf "file:///etc/passwd") == none
#guard dataUri (bytesOf "image.png") == none
#guard dataUri (bytesOf "http://example.com/data:,x") == none

/-! ## formats: the MIME type decides, `text/plain` sniffs -/

def pngMagic : ByteArray := ⟨#[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]⟩
def jpegMagic : ByteArray := ⟨#[0xFF, 0xD8, 0xFF, 0xE0]⟩

#guard fmtOf "image/png" jpegMagic == .png
#guard fmtOf "image/jpg" pngMagic == .jpeg
#guard fmtOf "text/plain" pngMagic == .png
#guard fmtOf "text/plain" jpegMagic == .jpeg
#guard fmtOf "image/gif" pngMagic == .gif
#guard fmtOf "image/svg+xml" pngMagic == .other

/-! ## end to end: `Png.encode` → `data:` → pixels → canvas -/

/-- 2×2 RGBA: red, half-transparent green / blue, transparent. -/
def rgba2 : ByteArray := ⟨#[255, 0, 0, 255,  0, 255, 0, 128,  0, 0, 255, 255,  9, 9, 9, 0]⟩
def uri2 : ByteArray := bytesOf ("data:image/png;base64," ++ b64 (Png.encode 2 2 rgba2))
def pix2 : Option Pix := loadWith StoredPng.decode (fun _ => none) (fun _ => none) uri2

#guard (pix2.map (fun p => (p.w, p.h, p.px))) ==
  some (2, 2, #[Canvas.pack 255 0 0 255, Canvas.pack 0 128 0 128,
                Canvas.pack 0 0 255 255, 0])
-- The same bytes under a JPEG MIME type go to the JPEG decoder (here: none).
#guard (loadWith StoredPng.decode (fun _ => none) (fun _ => none)
  (bytesOf ("data:image/jpeg;base64," ++ b64 (Png.encode 2 2 rgba2)))).isNone
-- A decoder that breaks the size contract is caught, not trusted.
#guard (loadWith (fun _ => some ⟨2, 2, ByteArray.empty⟩) (fun _ => none) (fun _ => none) uri2).isNone
#guard (loadWith (fun _ => some ⟨0, 0, ByteArray.empty⟩) (fun _ => none) (fun _ => none) uri2).isNone

/-- Draw the 2×2 image at natural size, translated by one pixel, onto a
transparent 4×4 canvas through a full-coverage 2×2 mask at `(1, 1)`. -/
def drawn : Option Canvas := do
  let p ← pix2
  let (_, pl, _) ← place p 256 256 none none {} .bicubic
  let sh ← build pl Mat.identity 0 0
  return Canvas.fillMaskImage (Canvas.new 4 4 none) ⟨1, 1, 2, 2, Array.replicate 4 65536⟩ sh

-- A pure translation samples nearest (tiny-skia downgrades the filter), so
-- the pixels land unchanged — and nothing outside the mask is touched.
#guard (drawn.map (·.px)) == some
  #[0, 0, 0, 0,
    0, Canvas.pack 255 0 0 255, Canvas.pack 0 128 0 128, 0,
    0, Canvas.pack 0 0 255 255, 0, 0,
    0, 0, 0, 0]

/-! ## placement (`fit_view_box` + `aligned_pos`) -/

def pix42 : Pix := ⟨4, 2, Array.replicate 8 0⟩

-- `xMidYMid meet` of a 4×2 image in a 100×100 box: 100×50, centred.
#guard (place pix42 0 0 (some 25600) (some 25600) {} .bicubic).map
  (fun (_, p, c) => (p.vx, p.vy, p.vw, p.vh, c.isSome)) == some (0, 6400, 25600, 12800, false)
-- `xMaxYMax slice`: 200×100, right-aligned, clipped to the viewport.
#guard (place pix42 0 0 (some 25600) (some 25600) ⟨some (.max, .max), true⟩ .bicubic).map
  (fun (_, p, c) => (p.vx, p.vy, p.vw, p.vh, c)) ==
  some (-25600, 0, 51200, 25600, some (0, 0, 25600, 25600))
-- Width only: the height follows the aspect ratio.
#guard (place pix42 0 0 (some 2560) none {} .bicubic).map
  (fun (_, p, _) => (p.vw, p.vh)) == some (2560, 1280)
-- No size at all: the image's own, in px.
#guard (place pix42 0 0 none none {} .bicubic).map
  (fun (_, p, _) => (p.vw, p.vh)) == some (1024, 512)
-- An empty or negative viewport draws nothing.
#guard (place pix42 0 0 (some 0) (some 256) {} .bicubic).isNone
#guard (place pix42 0 0 (some (-256)) none {} .bicubic).isNone

/-! ## the bicubic filter's weights sum to one -/

#guard (List.range 17).all fun k =>
  let t : Int := k * 4096
  let s := bicFar (65536 - t) + bicNear (65536 - t) + bicNear t + bicFar t
  65530 ≤ s && s ≤ 65536

#guard parseRendering (bytesOf "optimizeSpeed") == .nearest
#guard parseRendering (bytesOf "pixelated") == .nearest
#guard parseRendering (bytesOf "smooth") == .bilinear
#guard parseRendering (bytesOf "auto") == .bicubic
#guard parseRendering (bytesOf "bogus") == .bicubic
