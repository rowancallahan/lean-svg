import LeanSvg.Filter
import LeanSvg.Filter.Gamma
import LeanSvg.Filter.Tile
import LeanSvg.Filter.DisplacementMap

/-!
# Filters (T51): running a filter on a layer's pixels

A port of resvg 0.48.1's `filter/mod.rs` and the per-primitive files, on the
premultiplied `Canvas`.  resvg's own structure is kept, quirks included,
because the pixels are what is compared:

* every image is anchored at the layer's pixel `(0, 0)`; `SourceGraphic` is
  the whole layer, while a primitive that makes a *new* image (`feFlood`,
  `feBlend`, `feComposite`, `feMerge`) makes it the size of the filter region;
* each result carries its colour space, and an input is converted (demultiply,
  8-bit table, premultiply) only when the primitive's space differs;
* a subregion clips by clearing whole pixels outside it, except on `feOffset`;
* the last result is converted to sRGB and replaces the layer.

Arithmetic: `feGaussianBlur` is resvg's choice of algorithm — a five-pass box
blur when either device σ is at least 2, the IIR (Alvarez–Mazorra) otherwise.
The box blur is integer and exact (its `f32` rounding can never meet a tie,
see `boxPass`); the IIR runs in 2^-16 fixed point.  The colour-matrix,
transfer and arithmetic-composite channel formulas run on `F32` (see
`Filter.lean`), and the Porter–Duff operators on `F32` as tiny-skia's highp
pipeline does.

Resource bounds: every image is at most the layer's size, which `Render`
bounds; blur costs O(area) per pass whatever σ is (sliding window / recursive
filter); a filter has at most `Filter.maxPrims` primitives.
-/

namespace LeanSvg
namespace FilterApply

open Filter

/-! ## Colour spaces -/

/-- resvg's `SRGB_TO_LINEAR_RGB_TABLE`. -/
def srgbToLin : Array Nat := #[
    0,   0,   0,   0,   0,   0,  0,    1,   1,   1,   1,   1,   1,   1,   1,   1,
    1,   1,   2,   2,   2,   2,  2,    2,   2,   2,   3,   3,   3,   3,   3,   3,
    4,   4,   4,   4,   4,   5,  5,    5,   5,   6,   6,   6,   6,   7,   7,   7,
    8,   8,   8,   8,   9,   9,  9,   10,  10,  10,  11,  11,  12,  12,  12,  13,
    13,  13,  14,  14,  15,  15,  16,  16,  17,  17,  17,  18,  18,  19,  19,  20,
    20,  21,  22,  22,  23,  23,  24,  24,  25,  25,  26,  27,  27,  28,  29,  29,
    30,  30,  31,  32,  32,  33,  34,  35,  35,  36,  37,  37,  38,  39,  40,  41,
    41,  42,  43,  44,  45,  45,  46,  47,  48,  49,  50,  51,  51,  52,  53,  54,
    55,  56,  57,  58,  59,  60,  61,  62,  63,  64,  65,  66,  67,  68,  69,  70,
    71,  72,  73,  74,  76,  77,  78,  79,  80,  81,  82,  84,  85,  86,  87,  88,
    90,  91,  92,  93,  95,  96,  97,  99, 100, 101, 103, 104, 105, 107, 108, 109,
    111, 112, 114, 115, 116, 118, 119, 121, 122, 124, 125, 127, 128, 130, 131, 133,
    134, 136, 138, 139, 141, 142, 144, 146, 147, 149, 151, 152, 154, 156, 157, 159,
    161, 163, 164, 166, 168, 170, 171, 173, 175, 177, 179, 181, 183, 184, 186, 188,
    190, 192, 194, 196, 198, 200, 202, 204, 206, 208, 210, 212, 214, 216, 218, 220,
    222, 224, 226, 229, 231, 233, 235, 237, 239, 242, 244, 246, 248, 250, 253, 255]

/-- resvg's `LINEAR_RGB_TO_SRGB_TABLE`. -/
def linToSrgb : Array Nat := #[
    0,  13,  22,  28,  34,  38,  42,  46,  50,  53,  56,  59,  61,  64,  66,  69,
    71,  73,  75,  77,  79,  81,  83,  85,  86,  88,  90,  92,  93,  95,  96,  98,
    99, 101, 102, 104, 105, 106, 108, 109, 110, 112, 113, 114, 115, 117, 118, 119,
    120, 121, 122, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136,
    137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 148, 149, 150, 151,
    152, 153, 154, 155, 155, 156, 157, 158, 159, 159, 160, 161, 162, 163, 163, 164,
    165, 166, 167, 167, 168, 169, 170, 170, 171, 172, 173, 173, 174, 175, 175, 176,
    177, 178, 178, 179, 180, 180, 181, 182, 182, 183, 184, 185, 185, 186, 187, 187,
    188, 189, 189, 190, 190, 191, 192, 192, 193, 194, 194, 195, 196, 196, 197, 197,
    198, 199, 199, 200, 200, 201, 202, 202, 203, 203, 204, 205, 205, 206, 206, 207,
    208, 208, 209, 209, 210, 210, 211, 212, 212, 213, 213, 214, 214, 215, 215, 216,
    216, 217, 218, 218, 219, 219, 220, 220, 221, 221, 222, 222, 223, 223, 224, 224,
    225, 226, 226, 227, 227, 228, 228, 229, 229, 230, 230, 231, 231, 232, 232, 233,
    233, 234, 234, 235, 235, 236, 236, 237, 237, 238, 238, 238, 239, 239, 240, 240,
    241, 241, 242, 242, 243, 243, 244, 244, 245, 245, 246, 246, 246, 247, 247, 248,
    248, 249, 249, 250, 250, 251, 251, 251, 252, 252, 253, 253, 254, 254, 255, 255]

@[inline] def chR (p : Nat) : Nat := p >>> 24
@[inline] def chG (p : Nat) : Nat := (p >>> 16) &&& 255
@[inline] def chB (p : Nat) : Nat := (p >>> 8) &&& 255
@[inline] def chA (p : Nat) : Nat := p &&& 255

/-- `demultiply_alpha` then a channel map then `multiply_alpha`, per pixel.
`Canvas.unpremul`/`premul` are the integer forms of resvg's `f32` ones (they
disagree only on a few exact half-way pairs). -/
def mapDemul (cv : Canvas) (f : Nat → Nat) : Canvas :=
  { cv with px := cv.px.map (fun p =>
    let a := chA p
    if a == 0 then p
    else
      let r := f (Canvas.unpremul (chR p) a)
      let g := f (Canvas.unpremul (chG p) a)
      let b := f (Canvas.unpremul (chB p) a)
      Canvas.pack (Canvas.premul r a) (Canvas.premul g a) (Canvas.premul b a) a) }

/-- `into_linear_rgb` / `into_srgb`. -/
def convert (cv : Canvas) (toLin : Bool) : Canvas :=
  let tab := if toLin then srgbToLin else linToSrgb
  mapDemul cv (fun c => tab.getD c 0)

/-- An intermediate image: pixels, the region that holds data (resvg's
`Image::region`, in layer pixels), and the colour space. -/
structure Img where
  cv : Canvas
  rx : Int
  ry : Int
  rw : Int
  rh : Int
  lin : Bool
deriving Inhabited

def Img.of (cv : Canvas) (lin : Bool) : Img := ⟨cv, 0, 0, cv.w, cv.h, lin⟩

/-- `Image::into_color_space`. -/
def Img.into (im : Img) (lin : Bool) : Img :=
  if im.lin == lin then im else { im with cv := convert im.cv lin, lin }

/-! ## Drawing -/

/-- `draw_pixmap(dx, dy, src)` with `SourceOver` onto `dst`, clipped to `dst`.
Onto a transparent pixel this is a copy; otherwise `Canvas.blendOverScaled` at
full opacity, the integer source-over `compositeLayer` uses (§3.9). -/
def drawOver (dst src : Canvas) (dx dy : Int) : Canvas := Id.run do
  let w := dst.w
  let h := dst.h
  let k := 255 * Canvas.opGrid
  let mut px := dst.px
  for sy in [0:src.h] do
    let y := (sy : Int) + dy
    if y < 0 then continue
    if y ≥ h then break
    let yn := y.toNat
    for sx in [0:src.w] do
      let x := (sx : Int) + dx
      if x < 0 then continue
      if x ≥ w then break
      let s := src.px.getD (sy * src.w + sx) 0
      if s &&& 255 == 0 then continue
      let i := yn * w + x.toNat
      let d := px.getD i 0
      px := px.setIfInBounds i
        (if d == 0 || s &&& 255 == 255 then s else Canvas.blendOverScaled d s Canvas.opGrid k)
  return ⟨w, h, px⟩

/-- Clear every pixel outside `[x, x+w) × [y, y+h)`: resvg's four `Clear`
rectangles around a subregion. -/
def clearOutside (cv : Canvas) (x y w h : Int) : Canvas := Id.run do
  let mut px := cv.px
  for j in [0:cv.h] do
    let yin := (j : Int) ≥ y && (j : Int) < y + h
    for i in [0:cv.w] do
      if !(yin && (i : Int) ≥ x && (i : Int) < x + w) then
        px := px.setIfInBounds (j * cv.w + i) 0
  return { cv with px }

/-- tiny-skia's `load_8888`: `c · (1/255)`. -/
def loadTab : Array F32 := (Array.range 256).map fun c => F32.mul (F32.ofNat c) F32.inv255

/-- `feComposite`'s Porter–Duff operators on tiny-skia's highp pipeline:
`in` = `s·da`, `out` = `s·(1−da)`, `atop` = `s·da + d·(1−sa)`,
`xor` = `s·(1−da) + d·(1−sa)`, every channel alike, then `store_8888`. -/
def pdComposite (op : CompOp) (dst src : Canvas) : Canvas := Id.run do
  let n := Nat.min dst.px.size src.px.size
  let mut px := dst.px
  for i in [0:dst.px.size] do
    let s := if i < n then src.px.getD i 0 else 0
    let d := px.getD i 0
    let sa := loadTab.getD (chA s) 0
    let da := loadTab.getD (chA d) 0
    let isa := F32.sub F32.one sa
    let ida := F32.sub F32.one da
    let f := fun (sc dc : Nat) =>
      let sv := loadTab.getD sc 0
      let dv := loadTab.getD dc 0
      F32.toU8 <| match op with
        | .inn => F32.mul sv da
        | .out => F32.mul sv ida
        | .atop => F32.add (F32.mul sv da) (F32.mul dv isa)
        | .xor => F32.add (F32.mul sv ida) (F32.mul dv isa)
        | _ => F32.add sv (F32.mul dv isa)
    px := px.setIfInBounds i
      (Canvas.pack (f (chR s) (chR d)) (f (chG s) (chG d)) (f (chB s) (chB d)) (f (chA s) (chA d)))
  return { dst with px }

/-- `composite::arithmetic`: `k1·i1·i2 + k2·i1 + k3·i2 + k4` per premultiplied
channel, alpha first and clamped to `[0, 1]`, colour to `[0, a]`, then a
truncating `as u8`.  Pixels are paired by *index*, as resvg's `zip` does. -/
def arithmetic (k1 k2 k3 k4 : F32) (a b : Canvas) (w h : Nat) : Canvas := Id.run do
  let n := Nat.min (w * h) (Nat.min a.px.size b.px.size)
  let mut px : Array Nat := Array.replicate (w * h) 0
  let calcF := fun (i1 i2 : Nat) (mx : F32) =>
    let x1 := byteNorm.getD i1 0
    let x2 := byteNorm.getD i2 0
    let r := F32.add (F32.add (F32.add (F32.mul (F32.mul k1 x1) x2) (F32.mul k2 x1))
      (F32.mul k3 x2)) k4
    if F32.lt mx r then mx else if F32.isNeg r then 0 else r
  for i in [0:n] do
    let c1 := a.px.getD i 0
    let c2 := b.px.getD i 0
    let al := calcF (chA c1) (chA c2) F32.one
    -- `approx_zero_ulps(4)`: the four smallest magnitudes count as zero.
    if al == 0 then continue
    let u := fun (v : F32) => Nat.min 255 (f32Floor (F32.mul v F32.c255))
    px := px.setIfInBounds i (Canvas.pack (u (calcF (chR c1) (chR c2) al))
      (u (calcF (chG c1) (chG c2) al)) (u (calcF (chB c1) (chB c2) al)) (u al))
  return ⟨w, h, px⟩

/-! ## Colour matrix and component transfer -/

/-- The 3×3 of `saturate`/`hueRotate`, computed in binary32 as resvg does. -/
def sat3 (v : F32) : Array F32 :=
  let r := fun (n : Nat) => ofRatBig n 1000
  #[F32.add (r 213) (F32.mul (r 787) v), F32.sub (r 715) (F32.mul (r 715) v),
    F32.sub (r 72) (F32.mul (r 72) v),
    F32.sub (r 213) (F32.mul (r 213) v), F32.add (r 715) (F32.mul (r 285) v),
    F32.sub (r 72) (F32.mul (r 72) v),
    F32.sub (r 213) (F32.mul (r 213) v), F32.sub (r 715) (F32.mul (r 715) v),
    F32.add (r 72) (F32.mul (r 928) v)]

def hue3 (deg : F32) : Array F32 :=
  -- `angle.to_radians()` is `angle * (PI / 180.0)`, the constant folded in f32
  let rad := F32.mul deg (F32.div (ofRatBig piNum piDen) (F32.ofNat 180))
  let (a2, a1) := sinCosF32 rad
  let r := fun (n : Nat) => ofRatBig n 1000
  let t := fun (k0 k1 k2 : F32) => F32.add (F32.add k0 (F32.mul k1 a1)) (F32.mul k2 a2)
  let n := F32.neg
  #[t (r 213) (r 787) (n (r 213)), t (r 715) (n (r 715)) (n (r 715)), t (r 72) (n (r 72)) (r 928),
    t (r 213) (n (r 213)) (r 143), t (r 715) (r 285) (r 140), t (r 72) (n (r 72)) (n (r 283)),
    t (r 213) (n (r 213)) (n (r 787)), t (r 715) (n (r 715)) (r 715), t (r 72) (r 928) (r 72)]

/-- `c ↦ table[c] · m` for one coefficient, over all 256 bytes. -/
def mulTab (m : F32) : Array F32 := byteNorm.map (F32.mul · m)

/-- `color_matrix::apply` on demultiplied pixels, then premultiplied again. -/
def colorMatrix (k : CMKind) (cv : Canvas) : Canvas :=
  let dem := fun (p : Nat) =>
    let a := chA p
    if a == 0 then (0, 0, 0, 0)
    else (Canvas.unpremul (chR p) a, Canvas.unpremul (chG p) a, Canvas.unpremul (chB p) a, a)
  let out := fun (r g b a : Nat) =>
    Canvas.pack (Canvas.premul r a) (Canvas.premul g a) (Canvas.premul b a) a
  match k with
  | .matrix m =>
    let T := (List.range 20).toArray.map fun i => mulTab (m.getD i 0)
    let row := fun (j r g b a : Nat) =>
      f32TruncU8 (F32.add (F32.add (F32.add (F32.add ((T.getD (5 * j) #[]).getD r 0)
        ((T.getD (5 * j + 1) #[]).getD g 0)) ((T.getD (5 * j + 2) #[]).getD b 0))
        ((T.getD (5 * j + 3) #[]).getD a 0)) (m.getD (5 * j + 4) 0))
    { cv with px := cv.px.map (fun p =>
      let (r, g, b, a) := dem p
      out (row 0 r g b a) (row 1 r g b a) (row 2 r g b a) (row 3 r g b a)) }
  | .saturate _ | .hueRotate _ =>
    let m := match k with
      | .saturate v => sat3 (if F32.isNeg v then 0 else v)
      | .hueRotate d => hue3 d
      | _ => #[]
    let T := (List.range 9).toArray.map fun i => mulTab (m.getD i 0)
    let row := fun (j r g b : Nat) =>
      f32TruncU8 (F32.add (F32.add ((T.getD (3 * j) #[]).getD r 0)
        ((T.getD (3 * j + 1) #[]).getD g 0)) ((T.getD (3 * j + 2) #[]).getD b 0))
    { cv with px := cv.px.map (fun p =>
      let (r, g, b, a) := dem p
      out (row 0 r g b) (row 1 r g b) (row 2 r g b) a) }
  | .lumToAlpha =>
    let tr := mulTab (ofRatBig 2125 10000)
    let tg := mulTab (ofRatBig 7154 10000)
    let tb := mulTab (ofRatBig 721 10000)
    { cv with px := cv.px.map (fun p =>
      let (r, g, b, _) := dem p
      f32TruncU8 (F32.add (F32.add (tr.getD r 0) (tg.getD g 0)) (tb.getD b 0))) }

/-- One transfer function as a 256-entry table (`component_transfer::transfer`),
or `none` for resvg's `is_dummy` (the channel is left alone). -/
def tfTable (f : TF) : Option (Array Nat) :=
  let mk := fun (g : F32 → F32) => some (byteNorm.map fun c => f32TruncU8 (g c))
  match f with
  | .identity => none
  | .table vs =>
    if vs.isEmpty then none
    else
      let n := vs.size - 1
      let nf := F32.ofNat n
      mk fun c =>
        let k := Nat.min n (f32Floor (F32.mul c nf))
        if k == n then vs.getD k 0
        else
          let vk := vs.getD k 0
          let vk1 := vs.getD (k + 1) 0
          F32.add vk (F32.mul (F32.mul (F32.sub c (F32.div (F32.ofNat k) nf)) nf) (F32.sub vk1 vk))
  | .discrete vs =>
    if vs.isEmpty then none
    else
      let n := vs.size
      mk fun c => vs.getD (Nat.min (n - 1) (f32Floor (F32.mul c (F32.ofNat n)))) 0
  | .linear s i => mk fun c => F32.add (F32.mul s c) i
  | .gamma amp ex off => mk fun c => F32.add (F32.mul amp (powF32 c ex)) off

def transfer (fr fg fb fa : TF) (cv : Canvas) : Canvas :=
  let ap := fun (t : Option (Array Nat)) (c : Nat) => match t with
    | some tab => tab.getD c c
    | none => c
  let tr := tfTable fr
  let tg := tfTable fg
  let tb := tfTable fb
  let ta := tfTable fa
  { cv with px := cv.px.map (fun p =>
    let a := chA p
    let (r, g, b) := if a == 0 then (0, 0, 0)
      else (Canvas.unpremul (chR p) a, Canvas.unpremul (chG p) a, Canvas.unpremul (chB p) a)
    let a' := ap ta a
    Canvas.pack (Canvas.premul (ap tr r) a') (Canvas.premul (ap tg g) a')
      (Canvas.premul (ap tb b) a') a') }

/-! ## Gaussian blur -/

/-- One box pass of radius `r` along rows (`horiz`) or columns, zero outside
the image: resvg's `box_blur_horz`/`box_blur_vert`, whose three loops add up to
exactly `round(Σ_{|k| ≤ r} v[i+k] / (2r+1))`.  The `f32` rounding there can
never meet a tie: `(2r+1)` is odd, so the exact quotient is never `n + ½`, and
it is at least `1/(2(2r+1))` away from one, far above the float error. -/
def boxPass (cv : Canvas) (r : Nat) (horiz : Bool) : Canvas := Id.run do
  if r == 0 then return cv
  let w := cv.w
  let h := cv.h
  let (n, lines, step, lstep) := if horiz then (w, h, 1, w) else (h, w, w, 1)
  let d := 2 * r + 1
  let src := cv.px
  let mut out := src
  for l in [0:lines] do
    let base := l * lstep
    let mut sr := 0
    let mut sg := 0
    let mut sb := 0
    let mut sa := 0
    -- window for position 0: [0, r]
    for k in [0:Nat.min (r + 1) n] do
      let p := src.getD (base + k * step) 0
      sr := sr + chR p
      sg := sg + chG p
      sb := sb + chB p
      sa := sa + chA p
    for i in [0:n] do
      let q := fun (s : Nat) => (2 * s + d) / (2 * d)
      out := out.setIfInBounds (base + i * step) (Canvas.pack (q sr) (q sg) (q sb) (q sa))
      if i + r + 1 < n then
        let p := src.getD (base + (i + r + 1) * step) 0
        sr := sr + chR p
        sg := sg + chG p
        sb := sb + chB p
        sa := sa + chA p
      if i ≥ r then
        let p := src.getD (base + (i - r) * step) 0
        sr := sr - chR p
        sg := sg - chG p
        sb := sb - chB p
        sa := sa - chA p
  return { cv with px := out }

/-- `create_box_gauss`: five box sizes for σ (16.16 device pixels). -/
def boxSizes (s16 : Nat) : Array Nat := Id.run do
  if s16 == 0 then return #[1, 1, 1, 1, 1]
  let q := s16 * s16
  let mut wl := Nat.sqrt (12 * q / 5) / 65536 + 1
  if wl % 2 == 0 then wl := wl - 1
  let wu := wl + 2
  -- m = round((5wl² + 20wl + 15 − 12σ²) / (4wl + 4)), half away from zero,
  -- a negative one saturating to 0 as `as usize` does.
  let num : Int := ((5 * wl * wl + 20 * wl + 15) * 4294967296 : Nat) - ((12 * q : Nat) : Int)
  let den : Int := ((4 * wl + 4) * 4294967296 : Nat)
  let m : Nat := if num ≤ 0 then 0 else ((2 * num + den) / (2 * den)).toNat
  return (List.range 5).toArray.map fun i => if i < m then wl else wu

def boxBlur (sx sy : Nat) (cv : Canvas) : Canvas := Id.run do
  let bh := boxSizes sx
  let bv := boxSizes sy
  let mut c := cv
  for i in [0:5] do
    c := boxPass c ((bv.getD i 1 - 1) / 2) false
    c := boxPass c ((bh.getD i 1 - 1) / 2) true
  return c

/-- `gen_coefficients` in fixed point: `(dnu, (dnu/λ)^4)`, both scaled by
`2^32`, for σ in 16.16.  `λ = σ²/8` (four steps). -/
def iirCoeffs (s16 : Nat) : Nat × Nat :=
  let S : Nat := 4294967296
  let L := s16 * s16 / 8
  if L == 0 then (0, S)
  else
    let sq := Nat.sqrt ((S + 4 * L) * S)
    let dnu := (S + 2 * L - sq) * S / (2 * L)
    let R := dnu * S / L
    (dnu, R * R / S * R / S * R / S)

/-- One IIR axis over one channel buffer (values scaled by 2^16), four steps of
a causal and an anti-causal first-order pass per line, `dnu` at 2^24. -/
def iirAxis (buf : Array Nat) (w h : Nat) (horiz : Bool) (D : Nat) : Array Nat := Id.run do
  let (n, lines, step, lstep) := if horiz then (w, h, 1, w) else (h, w, w, 1)
  let mut b := buf
  if n < 2 then return b
  for l in [0:lines] do
    let base := l * lstep
    for _ in [0:4] do
      for x in [1:n] do
        let i := base + x * step
        b := b.setIfInBounds i (b.getD i 0 + (D * b.getD (i - step) 0) >>> 24)
      for k in [0:n - 1] do
        let x := n - 1 - k
        let i := base + x * step
        let j := i - step
        b := b.setIfInBounds j (b.getD j 0 + (D * b.getD i 0) >>> 24)
  return b

/-- `iir_blur::apply`: each channel on its own, `(buf · 255) as u8` at the end. -/
def iirBlur (sx sy : Nat) (cv : Canvas) : Canvas := Id.run do
  let (dx, fx) := iirCoeffs sx
  let (dy, fy) := iirCoeffs sy
  let S : Nat := 4294967296
  let post := (fx * fy / S) >>> 8
  let mut chans : Array (Array Nat) := #[]
  for c in [0:4] do
    let sh := 24 - 8 * c
    let mut b := cv.px.map fun p => ((p >>> sh) &&& 255) * 65536
    if sx > 0 && dx > 0 then b := iirAxis b cv.w cv.h true (dx >>> 8)
    if sy > 0 && dy > 0 then b := iirAxis b cv.w cv.h false (dy >>> 8)
    chans := chans.push (b.map fun v => Nat.min 255 ((v * post) >>> 40))
  let rs := chans.getD 0 #[]
  let gs := chans.getD 1 #[]
  let bs := chans.getD 2 #[]
  let al := chans.getD 3 #[]
  let px := (List.range cv.px.size).toArray.map fun i =>
    Canvas.pack (rs.getD i 0) (gs.getD i 0) (bs.getD i 0) (al.getD i 0)
  return { cv with px }

/-- `resolve_std_dev`: device σ in 16.16 from user σ (16.16) and the
transform's scale (16.16); `none` when both are zero (the input passes
through), tiny σ dropped, and whether the box blur is used. -/
def stdDev (sx sy : Int) (scx scy : Nat) : Option (Nat × Nat × Bool) :=
  let dx := (sx.toNat * scx) / 65536
  let dy := (sy.toNat * scy) / 65536
  if dx == 0 && dy == 0 then none
  else
    -- 0.05 in 16.16 is 3276.8
    let dx := if dx * 10 < 32768 then 0 else dx
    let dy := if dy * 10 < 32768 then 0 else dy
    some (dx, dy, dx ≥ 131072 || dy ≥ 131072)

def blur (sx sy : Nat) (box : Bool) (cv : Canvas) : Canvas :=
  if box then boxBlur sx sy cv else iirBlur sx sy cv

/-! ## Geometry -/

/-- `NonZeroRect::transform(ts).to_int_rect()`, in layer pixels, `none` when
the transformed rectangle is degenerate. -/
def devRect (ts : Mat) (r : URect) : Option (Int × Int × Int × Int) :=
  let ps := #[ts.apply ⟨r.x, r.y⟩, ts.apply ⟨r.x + r.w, r.y⟩, ts.apply ⟨r.x, r.y + r.h⟩,
              ts.apply ⟨r.x + r.w, r.y + r.h⟩]
  let x0 := ps.foldl (fun m p => min m p.x) (ps.getD 0 ⟨0, 0⟩).x
  let y0 := ps.foldl (fun m p => min m p.y) (ps.getD 0 ⟨0, 0⟩).y
  let x1 := ps.foldl (fun m p => max m p.x) (ps.getD 0 ⟨0, 0⟩).x
  let y1 := ps.foldl (fun m p => max m p.y) (ps.getD 0 ⟨0, 0⟩).y
  if x1 ≤ x0 || y1 ≤ y0 then none
  else some (Fx.floor x0, Fx.floor y0, max 1 (Fx.ceil (x1 - x0)), max 1 (Fx.ceil (y1 - y0)))

/-- `Transform::get_scale` in 16.16: `(√(a² + c²), √(b² + d²))`. -/
def scaleOf (ts : Mat) : Nat × Nat :=
  (Nat.sqrt ((ts.a * ts.a + ts.c * ts.c).toNat), Nat.sqrt ((ts.b * ts.b + ts.d * ts.d).toNat))

/-- `(x * scale) as i32`: a 16.16 user length through a 16.16 scale, to whole
device pixels, truncating toward zero. -/
def truncPx (v : Int) (sc : Nat) : Int := Int.tdiv (v * sc) 4294967296

/-! ## Running a filter -/

def getInput (src : Canvas) (region : Int × Int × Int × Int) (results : Array Img) :
    Input → Img
  | .source => ⟨src, region.1, region.2.1, region.2.2.1, region.2.2.2, false⟩
  | .alpha => ⟨{ src with px := src.px.map (· &&& 255) },
               region.1, region.2.1, region.2.2.1, region.2.2.2, false⟩
  | .ref i => results.getD i ⟨src, region.1, region.2.1, region.2.2.1, region.2.2.2, false⟩

/-- One primitive: resvg's `apply_*`.  `rw × rh` is the filter region's size.
`ox`/`oy` (absolute device pixels) are the filter region's own origin,
needed only by `.tile` to turn an input's absolute recorded region into
region-local pixel coordinates; every other case ignores them, so the
default keeps every other call site unchanged. -/
def runPrim (k : Kind) (lin : Bool) (ts : Mat) (rw rh : Nat) (inp : Input → Img)
    (ox oy : Int := 0) : Img :=
  let (scx, scy) := scaleOf ts
  match k with
  | .flood r g b a => Img.of (Canvas.new rw rh (some ⟨r, g, b, a⟩)) false
  | .offset i dx dy =>
    let im := inp i
    let ddx := truncPx dx scx
    let ddy := truncPx dy scy
    -- `approx_zero_ulps` on the f32 product: only a true zero passes through.
    if dx * scx == 0 && dy * scy == 0 then im
    else Img.of (drawOver (Canvas.new im.cv.w im.cv.h none) im.cv ddx ddy) im.lin
  | .blur i sx sy =>
    let im := inp i
    match stdDev sx sy scx scy with
    | none => im
    | some (dx, dy, box) => Img.of (blur dx dy box (im.into lin).cv) lin
  | .dropShadow i dx dy sx sy r g b a =>
    let im := (inp i).into lin
    let ddx := truncPx dx scx
    let ddy := truncPx dy scy
    let sh0 := match stdDev sx sy scx scy with
      | none => im.cv
      | some (bx, by_, box) => blur bx by_ box im.cv
    -- flood: the colour at `a · pixel alpha`, premultiplied
    let sh := { sh0 with px := sh0.px.map (fun p =>
      let pa := chA p
      let al := (a * pa + 127) / 255
      let c := fun (v : Nat) => (2 * v * a * pa + 65025) / 130050
      Canvas.pack (c r) (c g) (c b) al) }
    -- resvg converts the shadow into the primitive's space unconditionally
    -- (`into_srgb` in sRGB mode), which is what is emulated here.
    let sh := convert sh lin
    let base := drawOver (Canvas.new im.cv.w im.cv.h none) sh ddx ddy
    Img.of (drawOver base im.cv 0 0) lin
  | .merge ins =>
    Img.of (ins.foldl (fun c i => drawOver c ((inp i).into lin).cv 0 0) (Canvas.new rw rh none)) lin
  | .blend i1 i2 mode =>
    let a := ((inp i1).into lin).cv
    let b := ((inp i2).into lin).cv
    let base := drawOver (Canvas.new rw rh none) b 0 0
    Img.of (Canvas.compositeLayer base a 0 0 F32.one Canvas.opGrid mode) lin
  | .composite i1 i2 op =>
    let a := ((inp i1).into lin).cv
    let b := ((inp i2).into lin).cv
    match op with
    | .arith k1 k2 k3 k4 => Img.of (arithmetic k1 k2 k3 k4 a b rw rh) lin
    | .over => Img.of (drawOver (drawOver (Canvas.new rw rh none) b 0 0) a 0 0) lin
    | _ => Img.of (pdComposite op (drawOver (Canvas.new rw rh none) b 0 0) a) lin
  | .colorMatrix i m => Img.of (colorMatrix m ((inp i).into lin).cv) lin
  | .transfer i fr fg fb fa => Img.of (transfer fr fg fb fa ((inp i).into lin).cv) lin
  | .tile i =>
    let im := inp i
    Img.of (runTileCanvas rw rh (im.rx - ox) (im.ry - oy) im.rw im.rh im.cv) false
  | .displacementMap i1 i2 chX chY scale =>
    let a := ((inp i1).into lin).cv
    let m := ((inp i2).into lin).cv
    Img.of (runDisplacementMap rw rh scx scy scale chX chY a m) lin

/-- `filter::apply`: run `f` on the layer `src`, whose user space maps to the
layer's pixels by `ts`.  An invalid region clears the layer, as resvg does. -/
def run (f : Resolved) (ts : Mat) (src : Canvas) : Canvas := Id.run do
  let clear := Canvas.new src.w src.h none
  let some (gx, gy, gw, gh) := devRect ts f.region | return clear
  -- `fit_to_rect(region, (0, 0, w, h))`
  let x0 := max gx 0
  let y0 := max gy 0
  let x1 := min (gx + gw) src.w
  let y1 := min (gy + gh) src.h
  if x1 ≤ x0 || y1 ≤ y0 then return clear
  let region := (x0, y0, x1 - x0, y1 - y0)
  let rw := (x1 - x0).toNat
  let rh := (y1 - y0).toNat
  let mut results : Array Img := #[]
  for p in f.prims do
    let some sub0 := devRect ts p.sub | return clear
    let mut sub := sub0
    let mut isOffset := false
    match p.kind with
    | .offset (.ref i) _ _ =>
      isOffset := true
      match results[i]? with
      | some r => sub := (r.rx, r.ry, r.rw, r.rh)
      | none => pure ()
    | .offset .. => isOffset := true
    | _ => pure ()
    let mut res := runPrim p.kind p.linear ts rw rh (getInput src region results) x0 y0
    if region != sub then
      let (cx, cy, cw, ch) :=
        if isOffset then (0, 0, (x1 - x0), (y1 - y0))
        else (sub.1 - x0, sub.2.1 - y0, sub.2.2.1, sub.2.2.2)
      res := { res with cv := clearOutside res.cv cx cy cw ch,
                        rx := sub.1, ry := sub.2.1, rw := sub.2.2.1, rh := sub.2.2.2 }
    results := results.push res
  match results.back? with
  | none => return clear
  | some r => return drawOver clear (r.into false).cv 0 0

end FilterApply
end LeanSvg
