import LeanSvg.ImageData
import LeanSvg.PngDecode
import LeanSvg.JpegDecode
import LeanSvg.GifDecode
import LeanSvg.Viewport
import LeanSvg.Shader

/-!
# `<image>` (T63)

Only `href="data:..."` is ever looked at: the bytes are already inside the SVG.
Any other `href` (a path, `file:`, `http:`) yields `none` here and the element
draws nothing, exactly as before this module existed.  There is no code path
from an image to a file or a URL.

Pipeline, mirroring usvg's `parser/image.rs` and resvg's `image.rs`:

* `dataUri`: WHATWG `data:` URL processing as the `data_url` crate does it
  (strip tab/LF/CR, split at the first `,`, a `;base64` suffix on the header,
  percent-decoding, forgiving base64).  The MIME type picks the decoder like
  usvg's `default_data_resolver`; `text/plain` (also what a missing or broken
  MIME type becomes) sniffs the magic bytes.  WebP and SVG images are `none`
  for now.
* `load`: decode through `PngDecode`/`JpegDecode`/`GifDecode` (first frame
  only, T78), check the size contract of `ImageData` once more (a violation
  is `none`, never a crash), premultiply with tiny-skia's `premultiply_u8`.
* `place`: `x`/`y`/`width`/`height` (auto-sized from the image) and
  `preserveAspectRatio` → the view box the image pixels map onto
  (`convert_inner`'s `fit_view_box` + `aligned_pos`).
* `build` + `Canvas.fillMaskImage`: resvg fills the image rectangle with a
  `Pattern` shader through the image's transform.  Here the rectangle is an
  ordinary shape (its coverage mask comes from `Raster.rasterize`, clipped and
  shifted like any fill) and the pattern is a per-pixel sampler over the
  *absolute* device position, like `Canvas.fillMaskShader`, so bands and tiles
  stay byte-identical and locality holds by the same argument
  (`proofs/ImageLocality.lean`).
-/

namespace LeanSvg
namespace Image

open Bytes

/-! ## `data:` URIs -/

/-- The URL parser drops ASCII tab and newlines anywhere in the input. -/
@[inline] def isTabNl (c : UInt8) : Bool := c == 9 || c == 10 || c == 13

/-- ASCII whitespace as forgiving-base64 and the MIME header trim define it. -/
@[inline] def isAsciiWs (c : UInt8) : Bool := c == 9 || c == 10 || c == 12 || c == 13 || c == 32

def hasByte (bs : ByteArray) (p : UInt8 → Bool) : Bool := Id.run do
  for i in [0:bs.size] do
    if p (at' bs i) then return true
  return false

def dropBytes (bs : ByteArray) (p : UInt8 → Bool) : ByteArray := Id.run do
  -- The common case (a base64 body on one line) has nothing to drop.
  if !hasByte bs p then return bs
  let mut out := ByteArray.emptyWithCapacity bs.size
  for i in [0:bs.size] do
    let c := at' bs i
    if !p c then out := out.push c
  return out

@[inline] def hexDigit (c : UInt8) : Option Nat :=
  if 48 ≤ c && c ≤ 57 then some (c.toNat - 48)
  else if 97 ≤ c && c ≤ 102 then some (c.toNat - 87)
  else if 65 ≤ c && c ≤ 70 then some (c.toNat - 55)
  else none

/-- Percent-decoding: `%XX` with two hex digits is that byte, anything else
(a lone `%` included) is itself. -/
def percentDecode (bs : ByteArray) : ByteArray := Id.run do
  if findByte bs 0 37 ≥ bs.size then return bs
  let mut out := ByteArray.emptyWithCapacity bs.size
  let mut skip : Nat := 0
  for i in [0:bs.size] do
    if skip > 0 then
      skip := skip - 1
      continue
    let c := at' bs i
    if c == 37 && i + 2 < bs.size then
      match hexDigit (at' bs (i + 1)), hexDigit (at' bs (i + 2)) with
      | some hi, some lo =>
        out := out.push (hi * 16 + lo).toUInt8
        skip := 2
      | _, _ => out := out.push c
    else out := out.push c
  return out

/-- The value of a base64 digit, or `64` for a byte outside the alphabet. -/
@[inline] def b64Val (c : UInt8) : Nat :=
  if 65 ≤ c && c ≤ 90 then c.toNat - 65
  else if 97 ≤ c && c ≤ 122 then c.toNat - 71
  else if 48 ≤ c && c ≤ 57 then c.toNat + 4
  else if c == 43 then 62
  else if c == 47 then 63
  else 64

/-- WHATWG forgiving-base64 decode: drop ASCII whitespace; with a length that
is a multiple of four drop one or two trailing `=`; a length of `1 mod 4` or
any byte outside the alphabet is an error.  Leftover bits are discarded. -/
def base64Decode (bs0 : ByteArray) : Option ByteArray := Id.run do
  let bs := dropBytes bs0 isAsciiWs
  let n0 := bs.size
  let n1 := if n0 % 4 == 0 && n0 > 0 && at' bs (n0 - 1) == 61 then n0 - 1 else n0
  let n := if n0 % 4 == 0 && n1 < n0 && n1 > 0 && at' bs (n1 - 1) == 61 then n1 - 1 else n1
  if n % 4 == 1 then return none
  -- Four digits (24 bits, three bytes) per step.  A digit is `< 64` or the
  -- sentinel `64`, so an OR of four is `≥ 64` exactly when one is invalid.
  let full := n / 4
  let mut out := ByteArray.emptyWithCapacity (full * 3 + 2)
  -- `UInt32` rather than `Nat`: six times faster on a 30 MB URI.
  for g in [0:full] do
    let a := (b64Val (at' bs (4 * g))).toUInt32
    let b := (b64Val (at' bs (4 * g + 1))).toUInt32
    let c := (b64Val (at' bs (4 * g + 2))).toUInt32
    let d := (b64Val (at' bs (4 * g + 3))).toUInt32
    if (a ||| b ||| c ||| d) ≥ 64 then return none
    let v := (a <<< 18) ||| (b <<< 12) ||| (c <<< 6) ||| d
    out := ((out.push (v >>> 16).toUInt8).push (v >>> 8).toUInt8).push v.toUInt8
  -- A tail of two or three digits is one or two bytes; its spare bits are
  -- dropped.
  if n % 4 ≥ 2 then
    let a := b64Val (at' bs (4 * full))
    let b := b64Val (at' bs (4 * full + 1))
    if (a ||| b) ≥ 64 then return none
    out := out.push (((a <<< 2) ||| (b >>> 4)) &&& 255).toUInt8
    if n % 4 == 3 then
      let c := b64Val (at' bs (4 * full + 2))
      if c ≥ 64 then return none
      out := out.push (((b <<< 4) ||| (c >>> 2)) &&& 255).toUInt8
  return some out

/-- An HTTP token byte (MIME type and subtype). -/
@[inline] def isToken (c : UInt8) : Bool :=
  isDigit c || isAlpha c || c == 33 || c == 35 || c == 36 || c == 37 || c == 38 || c == 39 ||
  c == 42 || c == 43 || c == 45 || c == 46 || c == 94 || c == 95 || c == 96 || c == 124 ||
  c == 126

def trimBy (bs : ByteArray) (p : UInt8 → Bool) : ByteArray := Id.run do
  let mut s := 0
  for i in [0:bs.size] do
    if p (at' bs i) then s := i + 1 else break
  let mut e := bs.size
  for j in [0:bs.size] do
    let i := bs.size - 1 - j
    if i < s then break
    if p (at' bs i) then e := i else break
  return bs.extract s e

/-- `data_url`'s `remove_base64_suffix`: `;` then optional spaces then
`base64` (any case) at the very end. -/
def stripBase64 (h : ByteArray) : Option ByteArray :=
  let n := h.size
  if n < 6 || !eqAsciiCI (h.extract (n - 6) n) "base64" then none
  else
    let k := Id.run do
      let mut k := n - 6
      for _ in [0:n] do
        if k > 0 && at' h (k - 1) == 32 then k := k - 1 else break
      return k
    if k > 0 && at' h (k - 1) == 59 then some (h.extract 0 (k - 1)) else none

/-- The essence (`type/subtype`, lower case) of a MIME header, or `text/plain`
when it does not parse (the `data_url` default). -/
def mimeOf (hdr : ByteArray) : String :=
  let upto := hdr.extract 0 (findByte hdr 0 59)
  let t := trimBy upto isAsciiWs
  let k := findByte t 0 47
  if k ≥ t.size then "text/plain"
  else
    let ty := t.extract 0 k
    let sub := t.extract (k + 1) t.size
    if ty.size == 0 || sub.size == 0 || !(ty.toList.all isToken) || !(sub.toList.all isToken)
    then "text/plain"
    else toStr (lower t)

/-- `DataUrl::process` + `decode_to_vec`: the MIME essence and the body bytes,
or `none` when `href` is not a `data:` URL or its base64 is malformed. -/
def dataUri (href0 : ByteArray) : Option (String × ByteArray) :=
  let href := dropBytes (trimBy href0 (fun c => c ≤ 32)) isTabNl
  if href.size < 5 || !eqAsciiCI (href.extract 0 5) "data:" then none
  else
    let rest := href.extract 5 href.size
    let comma := findByte rest 0 44
    if comma ≥ rest.size then none
    else
      let hdr0 := trimBy (rest.extract 0 comma) isAsciiWs
      let body0 := rest.extract (comma + 1) rest.size
      let body := body0.extract 0 (findByte body0 0 35)
      let (hdr, b64) := match stripBase64 hdr0 with
        | some h => (h, true)
        | none => (hdr0, false)
      let mime := if hdr.size > 0 && at' hdr 0 == 59 then "text/plain" else mimeOf hdr
      let raw := percentDecode body
      if b64 then (base64Decode raw).map (mime, ·) else some (mime, raw)

/-! ## Formats and decoding -/

inductive Fmt where
  | png
  | jpeg
  | gif
  /-- WebP, SVG, or anything else: not drawn (yet). -/
  | other
deriving BEq, Repr

/-- The magic bytes `imagesize::image_type` checks for the three formats we
can decode. -/
def sniff (d : ByteArray) : Fmt :=
  if at' d 0 == 0x89 && at' d 1 == 0x50 && at' d 2 == 0x4E && at' d 3 == 0x47 then .png
  else if at' d 0 == 0xFF && at' d 1 == 0xD8 && at' d 2 == 0xFF then .jpeg
  else if at' d 0 == 0x47 && at' d 1 == 0x49 && at' d 2 == 0x46 && at' d 3 == 0x38 then .gif
  else .other

/-- usvg's `default_data_resolver`: the declared MIME type wins; only
`text/plain` looks at the bytes. -/
def fmtOf (mime : String) (d : ByteArray) : Fmt :=
  if mime == "image/png" then .png
  else if mime == "image/jpeg" || mime == "image/jpg" then .jpeg
  else if mime == "image/gif" then .gif
  else if mime == "text/plain" then sniff d
  else .other

/-- A decoded image, premultiplied and packed like `Canvas.px`
(`Canvas.pack r g b a`), row-major, `px.size = w * h`. -/
structure Pix where
  w : Nat
  h : Nat
  px : Array Nat
deriving Inhabited

/-- tiny-skia's `premultiply_u8`. -/
@[inline] def premulU8 (c a : Nat) : Nat :=
  let p := c * a + 128
  (p + (p >>> 8)) >>> 8

/-- The `ImageData` contract, re-checked; a decoder that breaks it gives
`none` rather than an out-of-shape pixel array. -/
def ofDecoded (d : ImageData.Decoded) : Option Pix :=
  if d.w == 0 || d.h == 0 || d.w * d.h > ImageData.maxPixels || d.px.size != d.w * d.h * 4
  then none
  else some ⟨d.w, d.h, Id.run do
    let n := d.w * d.h
    let mut out : Array Nat := Array.emptyWithCapacity n
    for i in [0:n] do
      let r := (at' d.px (4 * i)).toNat
      let g := (at' d.px (4 * i + 1)).toNat
      let b := (at' d.px (4 * i + 2)).toNat
      let a := (at' d.px (4 * i + 3)).toNat
      out := out.push (Canvas.pack (premulU8 r a) (premulU8 g a) (premulU8 b a) a)
    return out⟩

/-- `href` bytes to pixels with the given decoders; `none` for anything that
is not an embedded PNG/JPEG/GIF that decodes. -/
def loadWith (png jpeg gif : ByteArray → Option ImageData.Decoded) (href : ByteArray) : Option Pix :=
  match dataUri href with
  | none => none
  | some (mime, d) =>
    match fmtOf mime d with
    | .png => (png d).bind ofDecoded
    | .jpeg => (jpeg d).bind ofDecoded
    | .gif => (gif d).bind ofDecoded
    | .other => none

def load (href : ByteArray) : Option Pix :=
  loadWith PngDecode.decode JpegDecode.decode GifDecode.decode href

/-- Decoded pixels one document may hold in all (two full-size images).  A
few bytes of deflate can decode to `ImageData.maxPixels`, so without a
document-wide bound many small `data:` URIs (or `use` copies of one) could
hold unbounded memory; past it, further images draw nothing and are not
decoded at all. -/
def maxTotalPixels : Nat := 2 * ImageData.maxPixels

/-! ## Placement -/

/-- `image-rendering` → tiny-skia `FilterQuality`, as resvg's `render_raster`
maps it: `optimizeSpeed`/`crisp-edges`/`pixelated` are nearest, `smooth` is
bilinear, everything else (the default `optimizeQuality`, `high-quality`,
`auto`) bicubic. -/
inductive Quality where
  | nearest
  | bilinear
  | bicubic
deriving BEq, Repr, Inhabited

def parseRendering (v : ByteArray) : Quality :=
  let t := trim v
  if eqAscii t "optimizeSpeed" || eqAscii t "crisp-edges" || eqAscii t "pixelated" then .nearest
  else if eqAscii t "smooth" then .bilinear
  else .bicubic

/-- An `<image>` ready to draw: its pixels, and the view box (user space, `Fx`)
that image pixel `(0, 0)`–`(w, h)` is stretched onto. -/
structure Placed where
  pix : Pix
  vx : Fx
  vy : Fx
  vw : Fx
  vh : Fx
  quality : Quality
deriving Inhabited

/-- `convert_inner`: `fit_view_box` then `aligned_pos`.  `(x, y, w, h)` is the
element's viewport, `w, h > 0`.  Returns the view box. -/
def viewBox (iw ih : Nat) (x y w h : Fx) (ar : Viewport.AspectRatio) : Fx × Fx × Fx × Fx :=
  match ar.align with
  | none => (x, y, w, h)
  | some (px, py) =>
    -- tiny-skia `size_scale(actual, rect, expand := slice)`.
    let rw := Int.ediv (h * iw) ih
    let withH := if ar.slice then rw ≤ w else rw ≥ w
    let (sw, sh) := if !withH then (rw, h) else (w, Int.ediv (w * ih) iw)
    (x + Viewport.posOff px (w - sw), y + Viewport.posOff py (h - sh), sw, sh)

/-- The rectangle a user-space `(x, y, w, h)` covers, as a closed path. -/
def rectCmds (x y w h : Fx) : Array PathCmd :=
  #[.moveTo ⟨x, y⟩, .lineTo ⟨x + w, y⟩, .lineTo ⟨x + w, y + h⟩, .lineTo ⟨x, y + h⟩, .close]

/-- usvg's `image::convert` after the `href` is resolved: the viewport from
`x`/`y`/`width`/`height` (`none` for a missing size stays auto: the image's
own, or scaled to keep its aspect ratio when only one side is given), the
view-box rectangle the image is painted through, and with `slice` the
viewport as a clip rectangle (usvg wraps the image in a group clipped to it;
the caller adds that clip).

`none` when the viewport is empty or negative ("Image has an invalid size"). -/
def place (pix : Pix) (x y : Fx) (w? h? : Option Fx) (ar : Viewport.AspectRatio)
    (q : Quality) : Option (Array PathCmd × Placed × Option (Fx × Fx × Fx × Fx)) :=
  let iw : Int := pix.w
  let ih : Int := pix.h
  let (w, h) : Fx × Fx := match w?, h? with
    | some w, some h => (w, h)
    | some w, none => (w, Int.ediv (w * ih) iw)
    | none, some h => (Int.ediv (h * iw) ih, h)
    | none, none => (iw * 256, ih * 256)
  if w ≤ 0 || h ≤ 0 then none
  else
    let (vx, vy, vw, vh) := viewBox pix.w pix.h x y w h ar
    if vw ≤ 0 || vh ≤ 0 then none
    else
      let clip := if ar.slice && ar.align.isSome then some (x, y, w, h) else none
      some (rectCmds vx vy vw vh, ⟨pix, vx, vy, vw, vh, q⟩, clip)

/-! ## The per-pixel sampler -/

/-- A placed image in device space: the inverse map from an absolute device
pixel to image coordinates (16.16, via `Grad.Axis`) and the filter. -/
structure Rt where
  pix : Pix
  px : Grad.Axis
  py : Grad.Axis
  quality : Quality
deriving Inhabited

/-- Image coordinates are clamped to this (16.16) before sampling, so the
integer part stays a small `Int` whatever the transform. -/
def coordMax : Int := 1073741824

/-- The device shader for `p` under `ctm0` (user → destination canvas), with
`(ox, oy)` the destination canvas' origin in the whole image — the same
contract as `Grad.build`: the inverse is taken about the whole image and the
offset folded into the constant term, so a tile samples exactly what the full
render samples.  `none` for a singular transform (tiny-skia: "failed to invert
a pattern transform. Nothing will be rendered").

A map that is a pure translation downgrades to nearest-neighbour, as
`Pattern::push_stages` does. -/
def build (p : Placed) (ctm0 : Mat) (ox oy : Int) : Option Rt :=
  let ctm := if ox == 0 && oy == 0 then ctm0
             else (Mat.translate (ox * 256) (oy * 256)).mul ctm0
  match (Grad.Aff.ofMat ctm).invert with
  | none => none
  | some (ax, cx, ex, ay, cy, ey) =>
    -- `invert` gives user coordinates with 32 fractional bits; image pixels
    -- are `(user − v) · iw / vw`, with `v`, `vw` on the 1/256 grid.
    let sx : Int := (p.pix.w : Int) * 256
    let sy : Int := (p.pix.h : Int) * 256
    let lx := fun (v : Int) => Grad.clampTo Grad.affMax (Int.ediv (v * sx) p.vw)
    let ly := fun (v : Int) => Grad.clampTo Grad.affMax (Int.ediv (v * sy) p.vh)
    let ax' := lx ax
    let cx' := lx cx
    let ay' := ly ay
    let cy' := ly cy
    -- Every coefficient above is floored, which leaves a pixel centre that
    -- lands exactly on an image pixel edge a hair below it and would pick
    -- the pixel before; f32 lands on the edge itself.  `tieBias` (2^-16 of
    -- an image pixel) is larger than those floors and far below anything a
    -- filter can see.
    let tieBias : Int := 65536
    let ex' := Grad.clampTo Grad.affTMax (Int.ediv ((ex - p.vx * 16777216) * sx) p.vw + tieBias)
    let ey' := Grad.clampTo Grad.affTMax (Int.ediv ((ey - p.vy * 16777216) * sy) p.vh + tieBias)
    let one : Int := 4294967296
    let tol : Int := 1024
    let isTranslate := (ax' - one).natAbs ≤ tol && (cy' - one).natAbs ≤ tol &&
      cx'.natAbs ≤ tol && ay'.natAbs ≤ tol
    some { pix := p.pix,
           px := Grad.Axis.mk3 ax' cx' (ex' + ax' * ox + cx' * oy),
           py := Grad.Axis.mk3 ay' cy' (ey' + ay' * ox + cy' * oy),
           quality := if isTranslate then .nearest else p.quality }

/-- `gather_ix` on one axis: clamp to `[0, n − 1]`. -/
@[inline] def clampIx (i : Int) (n : Nat) : Nat :=
  if i ≤ 0 then 0 else if i.toNat ≥ n then n - 1 else i.toNat

/-- tiny-skia's `bicubic_near`, 16.16 in and out (`t ∈ [0, 1]`). -/
@[inline] def bicNear (t : Int) : Int :=
  let a := -21 * t + 27 * 65536
  let b := Int.ediv (a * t) 65536 + 9 * 65536
  Int.ediv (Int.ediv (b * t) 65536 + 65536) 18

/-- tiny-skia's `bicubic_far`, 16.16 in and out. -/
@[inline] def bicFar (t : Int) : Int :=
  let t2 := Int.ediv (t * t) 65536
  Int.ediv (Int.ediv (t2 * (7 * t - 6 * 65536)) 65536) 18

/-- The four channels of a packed pixel. -/
@[inline] def chans (v : Nat) : Nat × Nat × Nat × Nat :=
  ((v >>> 24) &&& 255, (v >>> 16) &&& 255, (v >>> 8) &&& 255, v &&& 255)

/-- A weighted sum over taps (weights 16.16 per axis, so 2^32 in all),
clamped to `[0, 1]` per channel (`Clamp0`/`ClampA`) and rounded to 8 bits. -/
@[inline] def round32 (s : Int) : Nat :=
  if s ≤ 0 then 0 else Nat.min 255 ((s.toNat + 2147483648) >>> 32)

/-- The premultiplied colour of the image at absolute device pixel `(X, Y)`:
the pixel centre is mapped into the image and sampled with the filter
(`Gather`, `Bilinear` or `Bicubic` with `SpreadMode::Pad`). -/
def sampleAt (sh : Rt) (X Y : Nat) : Nat × Nat × Nat × Nat :=
  let pix := sh.pix
  let u := Grad.clampTo coordMax (sh.px.at X Y)
  let v := Grad.clampTo coordMax (sh.py.at X Y)
  match sh.quality with
  | .nearest =>
    chans (pix.px.getD (clampIx (Int.ediv v 65536) pix.h * pix.w + clampIx (Int.ediv u 65536) pix.w) 0)
  | q =>
    let tu := u - 32768
    let tv := v - 32768
    let iu := Int.ediv tu 65536
    let iv := Int.ediv tv 65536
    let fu := Int.emod tu 65536
    let fv := Int.emod tv 65536
    let (wx, wy, k0, n) : Array Int × Array Int × Int × Nat := match q with
      | .bilinear => (#[65536 - fu, fu], #[65536 - fv, fv], 0, 2)
      | _ =>
        (#[bicFar (65536 - fu), bicNear (65536 - fu), bicNear fu, bicFar fu],
         #[bicFar (65536 - fv), bicNear (65536 - fv), bicNear fv, bicFar fv], -1, 4)
    Id.run do
      let mut r : Int := 0
      let mut g : Int := 0
      let mut b : Int := 0
      let mut a : Int := 0
      for j in [0:n] do
        let row := clampIx (iv + k0 + j) pix.h * pix.w
        let wj := wy.getD j 0
        for i in [0:n] do
          let w := wx.getD i 0 * wj
          let (cr, cg, cb, ca) := chans (pix.px.getD (row + clampIx (iu + k0 + i) pix.w) 0)
          r := r + w * cr
          g := g + w * cg
          b := b + w * cb
          a := a + w * ca
      return (round32 r, round32 g, round32 b, round32 a)

end Image

namespace Canvas

/-- `fillMaskShader` with the image sampler as the paint source.  A pattern is
never opaque to tiny-skia (`Shader::is_opaque`), so this is always the
`SourceOver` path on a coverage-scaled source, and a fully transparent sample
leaves the pixel alone (it would blend to itself).  The shape of the loop is
exactly `fillMaskShader`'s, which is what `proofs/ImageLocality.lean` uses. -/
def fillMaskImage (cv : Canvas) (m : Raster.Mask) (sh : Image.Rt) : Canvas := Id.run do
  let w := cv.w
  let h := cv.h
  let mw := m.w
  let mut px := cv.px
  for y in [0:m.h] do
    let mrow := y * mw
    let prow := (m.y0 + y) * w + m.x0
    let ay := m.y0 + y
    for x in [0:mw] do
      let cov := m.cov.getD (mrow + x) 0
      if cov ≤ covNone then continue
      let (sr, sg, sb, sa) := Image.sampleAt sh (m.x0 + x) ay
      if sr == 0 && sg == 0 && sb == 0 && sa == 0 then continue
      let idx := prow + x
      let cov8 := if cov ≥ covFull then 255 else (cov * 255 + 32768) >>> 16
      let dst := px.getD idx 0
      px := px.setIfInBounds idx
        (blendOver dst (div255 (sr * cov8)) (div255 (sg * cov8)) (div255 (sb * cov8))
          (div255 (sa * cov8)))
  return ⟨w, h, px⟩

end Canvas
end LeanSvg
