import MicroSvg.Raster

/-!
# Canvas

Premultiplied RGBA, 8 bits per channel, one packed `Nat` per pixel
(`r<<24 | g<<16 | b<<8 | a`).  Source-over compositing only.

The integer arithmetic below is a port of tiny-skia's `lowp` raster pipeline,
which is the pipeline resvg uses for a solid-colour anti-aliased fill or
stroke.  See `tasks/T2-blend-rounding.md` for where each formula comes from.
-/

namespace MicroSvg

structure Rgba where
  r : Nat
  g : Nat
  b : Nat
  a : Nat
deriving Repr, Inhabited, BEq

structure Canvas where
  w : Nat
  h : Nat
  px : Array Nat
deriving Inhabited

namespace Canvas

/-- tiny-skia `pipeline::lowp::div255`: `(v + 255) >> 8`.

This is deliberately *not* `round (v / 255)`.  Skia's lowp pipeline uses this
cheaper approximation and every blend stage (`scale_1_float`, `lerp_1_float`,
`source_over`) is built out of it, so the blend has to use it too to stay
bit-identical.  Note `div255 (x * 255) = x` for `x ≤ 255`, which is why a
coverage of 255 behaves exactly like the no-coverage fast path. -/
@[inline] def div255 (x : Nat) : Nat := (x + 255) >>> 8

/-- Premultiply one channel: `round (c * a / 255)`.

resvg premultiplies the paint colour in `f32` (`Color::premultiply`) and then
quantises with `(x * 255.0 + 0.5) as u16` in `RasterPipelineBuilder::
push_uniform_color`.  `(c * a + 127) / 255` agrees with that for all 256×256
pairs (checked exhaustively), and also matches `color::premultiply_u8`, which
is what `Pixmap::fill` uses for the background. -/
@[inline] def premul (c a : Nat) : Nat := (c * a + 127) / 255

/-- Unpremultiply one channel: `round (c * 255 / a)`.

`PremultipliedColorU8::demultiply` computes `(c as f64 / (a as f64 / 255.0)
+ 0.5) as u8`, which is round-half-up of `c * 255 / a` except at 38 of the
615 exact half-way `(c, a)` pairs, where the `f64` division lands just below
the tie and rounds down instead. -/
@[inline] def unpremul (c a : Nat) : Nat :=
  if a == 0 then 0 else Nat.min 255 ((c * 510 + a) / (2 * a))

@[inline] def pack (r g b a : Nat) : Nat := (r <<< 24) ||| (g <<< 16) ||| (b <<< 8) ||| a

def new (w h : Nat) (bg : Option Rgba) : Canvas :=
  let v := match bg with
    | none => 0
    | some c => pack (premul c.r c.a) (premul c.g c.a) (premul c.b c.a) c.a
  ⟨w, h, Array.replicate (w * h) v⟩

/-- Opaque paint, fractional coverage: tiny-skia `lowp::lerp_1_float`.

`RasterPipelineBlitter::new` strength-reduces `SourceOver` to `Source` when the
shader is opaque and there is no clip mask.  `Source` is not in
`BlendMode::should_pre_scale_coverage`, so the anti-aliased blitter *lerps*
between destination and source by the coverage — one `div255` over the sum —
instead of scaling the source and compositing separately.  `sr sg sb` are the
(already premultiplied, here opaque) source channels. -/
@[inline] def blendLerp (dst sr sg sb cov : Nat) : Nat :=
  let inv := 255 - cov
  let dr := (dst >>> 24) &&& 255
  let dg := (dst >>> 16) &&& 255
  let db := (dst >>> 8) &&& 255
  let da := dst &&& 255
  pack (Nat.min 255 (div255 (dr * inv + sr * cov)))
       (Nat.min 255 (div255 (dg * inv + sg * cov)))
       (Nat.min 255 (div255 (db * inv + sb * cov)))
       (Nat.min 255 (div255 (da * inv + 255 * cov)))

/-- Translucent paint: tiny-skia `lowp::source_over` on a source that
`lowp::scale_1_float` has already multiplied by the coverage.  `sr sg sb sa`
are the premultiplied, coverage-scaled source channels. -/
@[inline] def blendOver (dst sr sg sb sa : Nat) : Nat :=
  let inv := 255 - sa
  let dr := (dst >>> 24) &&& 255
  let dg := (dst >>> 16) &&& 255
  let db := (dst >>> 8) &&& 255
  let da := dst &&& 255
  pack (Nat.min 255 (sr + div255 (dr * inv)))
       (Nat.min 255 (sg + div255 (dg * inv)))
       (Nat.min 255 (sb + div255 (db * inv)))
       (Nat.min 255 (sa + div255 (da * inv)))

/-! ### Coverage thresholds

`fillMask` reduces the mask's `cov ∈ [0, 65536]` to tiny-skia's 0..255 coverage
with `cov8 = (cov · 255 + 32768) >>> 16`.  Two values of `cov8` make the blend
degenerate, and both are worth branching on before doing any arithmetic:

* `cov8 = 0` — nothing is written.  `cov · 255 + 32768 < 65536 ↔ cov · 255 <
  32768 ↔ cov ≤ ⌊32767/255⌋ = 128`.
* `cov8 = 255` — full coverage.  `cov · 255 + 32768 ≥ 255 · 65536 ↔ cov ≥
  ⌈16678912/255⌉ = 65408`; the upper end cannot overflow because `cov ≤ 65536`
  gives `cov8 ≤ 255`.

Both equivalences were checked over all 65537 values of `cov`.  Testing `cov`
against these constants is exactly `cov8 == 0` / `cov8 == 255`, so the fast
paths below are entered on precisely the pixels whose general-path result they
reproduce, and `cov8` itself is only computed on the remaining pixels. -/

/-- Largest `cov` whose `cov8` is `0`. -/
@[inline] def covNone : Nat := 128

/-- Smallest `cov` whose `cov8` is `255`. -/
@[inline] def covFull : Nat := 65408

/-- Fill the mask with a solid colour.  `alpha8` is the final paint alpha in
`[0, 255]`: the colour's own alpha, the fill/stroke opacity and the inherited
group opacity already collapsed into one `u8` by `Svg.opacityToU8`, exactly as
resvg does with `set_color_rgba8(r, g, b, fill.opacity().to_u8())`.

The colour is premultiplied by it *before* the rasteriser's coverage is
applied, so `c.a` plays no part below — only `alpha8` does.

The mask is walked row by row.  Per row, the destination index of its first
pixel is computed once; per pixel, the coverage decides between three cases:

* `cov ≤ covNone`: skip, without reading or writing the canvas.
* `cov ≥ covFull`: full coverage.  For an opaque paint `blendLerp`'s `inv` is
  `0`, so the destination drops out and the result is the constant `solid`,
  written with no read and no arithmetic.  For a translucent paint the
  coverage-scaled source is the loop-invariant `fr fg fb fa`, so only the
  `source_over` step remains.
* otherwise: the general blend, unchanged.

`solid` and `fr fg fb fa` are *defined* as the corresponding general-path
expressions at `cov8 = 255`, so the fast paths cannot drift from it. -/
def fillMask (cv : Canvas) (m : Raster.Mask) (c : Rgba) (alpha8 : Nat) : Canvas := Id.run do
  let w := cv.w
  let h := cv.h
  let a8 := Nat.min 255 alpha8
  if a8 == 0 then return cv
  let sr := premul c.r a8
  let sg := premul c.g a8
  let sb := premul c.b a8
  let isOpaque := a8 == 255
  -- `cov8 = 255`, opaque: `inv = 0`, so this is independent of the destination.
  let solid := blendLerp 0 sr sg sb 255
  -- `cov8 = 255`, translucent: the `scale_1_float` stage is loop-invariant.
  let fr := div255 (sr * 255)
  let fg := div255 (sg * 255)
  let fb := div255 (sb * 255)
  let fa := div255 (a8 * 255)
  let mw := m.w
  let mut px := cv.px
  for y in [0:m.h] do
    let mrow := y * mw
    let prow := (m.y0 + y) * w + m.x0
    for x in [0:mw] do
      let cov := m.cov.getD (mrow + x) 0
      if cov ≤ covNone then continue
      let idx := prow + x
      if cov ≥ covFull then
        if isOpaque then
          px := px.setIfInBounds idx solid
        else
          px := px.setIfInBounds idx (blendOver (px.getD idx 0) fr fg fb fa)
      else
        -- tiny-skia's blitter works on 0..255 coverage; ours is 0..65536.
        let cov8 := (cov * 255 + 32768) >>> 16
        let dst := px.getD idx 0
        let nv :=
          if isOpaque then blendLerp dst sr sg sb cov8
          else blendOver dst (div255 (sr * cov8)) (div255 (sg * cov8)) (div255 (sb * cov8))
                 (div255 (a8 * cov8))
        px := px.setIfInBounds idx nv
  return ⟨w, h, px⟩

/-- Straight-alpha RGBA bytes, row-major, 4 bytes per pixel.  This is what
`Pixmap::encode_png` writes: it demultiplies every pixel first.

The two extreme alphas are special-cased, which covers almost every pixel of
almost every render and is bit-for-bit the same as calling `unpremul`:

* `a = 0` is `unpremul`'s own `0` case, and the three colour channels of a
  premultiplied transparent pixel are 0 anyway;
* `a = 255` leaves each channel alone, because for `c ≤ 255`
  `unpremul c 255 = min 255 ((c * 510 + 255) / 510) = c` — the remainder 255 is
  below the divisor 510, so the floor is exactly `c`.

The general branch also no longer builds a closure over `a` per pixel. -/
def toRgbaBytes (cv : Canvas) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity (cv.w * cv.h * 4)
  for v in cv.px do
    let a := v &&& 255
    if a == 0 then
      out := (((out.push 0).push 0).push 0).push 0
    else if a == 255 then
      out := (((out.push ((v >>> 24) &&& 255).toUInt8).push ((v >>> 16) &&& 255).toUInt8).push
        ((v >>> 8) &&& 255).toUInt8).push 255
    else
      out := (((out.push (unpremul ((v >>> 24) &&& 255) a).toUInt8).push
        (unpremul ((v >>> 16) &&& 255) a).toUInt8).push
        (unpremul ((v >>> 8) &&& 255) a).toUInt8).push a.toUInt8
  return out

end Canvas

/-! ## Compositing layers

A group with `opacity < 1`, a `mix-blend-mode` or `isolation: isolate` is
rendered into a *layer*: a fresh transparent canvas covering the group's device
bounding box, which is then composited onto its parent with the group opacity
and the blend mode (resvg `render.rs::render_group`, which draws the layer
with `Pixmap::draw_pixmap` and a `PixmapPaint { opacity, blend_mode }`).

### Which tiny-skia pipeline

`draw_pixmap` fills a rectangle with a `Pattern` shader.  The pattern's
`Gather` stage has no lowp implementation (`pipeline/lowp.rs` lists it as
`null_fn`), so `RasterPipelineBuilder::compile` falls back to the **highp**
pipeline for every layer composite — the f32 one — regardless of blend mode,
and that is the path ported here.  Its stages for our case (integer offset, no
mask, no anti-aliasing) are, per pixel and per channel in f32:

    load   s = c8 · F            F = f32(1/255) = 0x3B808081  (`load_8888`)
           s = s · opacity                                    (`scale_1_float`, only when opacity ≠ 1)
           d = c8 · F                                         (destination)
    blend  SourceOver: `source_over_rgba`  c = d · (1 − sa) + s
           other modes: `LoadDestination`, the mode's stage, `Store`
    store  round_to_nearest_even (clamp(c, 0, 1) · 255)      (`unnorm` in `store_8888`)

Every operation is IEEE binary32 with round-to-nearest-even: `f32x8` on x86-64
is two SSE2 `f32x4`s (`_mm_mul_ps` etc.; `round_int` is `_mm_cvtps_epi32` under
the default MXCSR), and on AArch64 the NEON equivalents.  The one exception is
`recip_fast` (`_mm_rcp_ps`, 12-bit accurate) in `color-dodge`/`color-burn`,
which is hardware-specific; it is replaced by a correctly rounded reciprocal
below.  Division by zero, which in f32 yields ±∞/NaN that `unnorm`'s clamp
later turns into 0 or 255, yields 0 here.

### Integer emulation

There are no floats in this code base, so binary32 is emulated exactly in
`Nat`: a value is packed as `m ||| (eb <<< 24) ||| (neg <<< 34)` — a 24-bit
normalised mantissa `m ∈ [2^23, 2^24)`, a biased exponent `eb` (value
`m · 2^(eb − F32.bias)`), and a sign bit — with `0` for zero.  Every result is
computed exactly in `Nat` and rounded once to 24 bits, nearest-even, with a
sticky bit where the exact value was truncated (division, square root), which
is precisely IEEE arithmetic.  Denormals cannot arise (the smallest magnitudes
here are around `(1/255)^4`) and are flushed to zero.  The whole pipeline was
checked against resvg 0.48.1 on 1-px strip images that put every `(s8, d8)`
pair through every mode and several opacities (`tasks/T22-group-layers.md`).
-/

/-- One binary32 value, packed into a `Nat` as described above. -/
abbrev F32 := Nat

namespace F32

/-- Exponent bias of the packed form. -/
def bias : Nat := 512

/-- `2^k` for `k < 64`, tabulated.

`Nat.shiftLeft` is the one bitwise operation Lean's runtime has no scalar fast
path for (`lean_nat_shiftr`, `lean_nat_land` and friends are inlined; `<<<`
calls out to `lean_nat_shiftl`, which goes through GMP and allocates), so a
left shift on this path cost an `mpz` round trip and a `malloc` per float
operation.  Multiplying by a tabulated power of two instead stays in unboxed
arithmetic: `lean_nat_mul` is inlined with an overflow check.

The table is a closed term, so it is built once when the module is loaded. -/
def pow2Tab : Array Nat := (Array.range 64).map (Nat.pow 2 ·)

/-- `2^k`, for `k < 64` only; `0` past the table, which no caller reaches (the
largest shift in this namespace is `sqrt`'s 52). -/
@[inline] def p2 (k : Nat) : Nat := pow2Tab.getD k 0

/-! The sign is the *low* bit, not the high one, and the exponent sits above
the mantissa: `neg ||| m * 2 ||| eb * 2^25`.

That ordering is a performance requirement, not a style choice.  Lean's code
generator emits a `Nat` literal that does not fit in 32 bits as
`lean_cstr_to_nat("…")`, which parses a decimal string into a GMP bignum *on
every evaluation*; with the sign at bit 34 the `1 <<< 34` in `neg` and in the
comparison mask turned every float operation into several `malloc`s, and the
composite spent most of its time in GMP.  With the sign low, every constant in
this namespace is under `2^32` and the whole path is scalar arithmetic.

Two consequences the comparison below relies on: a non-negative word is
monotone in `(eb, m)`, and zero's word is `0`, which is below every non-zero
one (a normal mantissa has bit 23 set). -/
@[inline] def mant (x : F32) : Nat := (x >>> 1) &&& 0xFFFFFF
@[inline] def expo (x : F32) : Nat := x >>> 25
@[inline] def isNeg (x : F32) : Bool := x &&& 1 == 1
@[inline] def mk (neg : Bool) (m eb : Nat) : F32 :=
  (if neg then 1 else 0) ||| (m * 2) ||| (Nat.min eb 1023 * 33554432)

/-- Bit length of `m`: the least `k` with `m < 2^k`, and `0` for `0`.

A six-step binary search rather than `Nat.log2`, which walks one bit at a time;
this is called once per arithmetic operation and is the hottest line in a layer
composite.

Every comparison is against a constant below `2^63`, so no step allocates a
bignum — which is the point, and why there is no 64-bit step.  Nothing here
reaches that far: the widest value `norm` is ever handed is `add`'s
`mant a <<< 26 + mant b`, at 51 bits, and `sqrt` calls it on the *root*
(38 bits), never on the 76-bit radicand. -/
def bitLen (m : Nat) : Nat := Id.run do
  if m == 0 then return 0
  let mut n := m
  let mut k := 1
  -- Tested as `n >>> j != 0` rather than `n ≥ 2^j`, so that no step mentions a
  -- constant of its own (see the packing note above).
  if n >>> 32 != 0 then n := n >>> 32; k := k + 32
  if n >>> 16 != 0 then n := n >>> 16; k := k + 16
  if n >>> 8 != 0 then n := n >>> 8; k := k + 8
  if n >>> 4 != 0 then n := n >>> 4; k := k + 4
  if n >>> 2 != 0 then n := n >>> 2; k := k + 2
  if n >>> 1 != 0 then k := k + 1
  return k

/-- Bias of the *working* exponent `norm` and its callers pass around.

Everything below is `Nat`, never `Int`: an unboxed `Int` is 31 bits on a 64-bit
host while an unboxed `Nat` is 63 (`tasks/README.md`, invariant 4), and this is
the hottest arithmetic in the renderer.  A working exponent `p` stands for the
true exponent `p - pbias`, and `pbias` is large enough that every intermediate
each operation forms stays non-negative without a single signed subtraction:
the smallest is `div`'s, at `1 - 1023 - 26 + pbias`. -/
def pbias : Nat := 4096

/-- Round `(−1)^neg · m · 2^(p − pbias)` to a binary32, nearest-even.  `m` may
have any number of bits; `sticky` says the exact value lies strictly above
`m · 2^(p − pbias)` (bits already truncated away, always below `m`'s lowest
bit), which only matters for breaking a tie upwards.  A result below the
smallest normal binary32 flushes to zero, which cannot happen for the values
this file computes with (the smallest is around `(1/255)^4`). -/
def norm (neg : Bool) (m p : Nat) (sticky : Bool) : F32 :=
  if m == 0 then 0
  else
    let k := bitLen m
    if k ≤ 24 then
      let sh := 24 - k
      let t := p + bias
      if t ≤ pbias + sh then 0 else mk neg (m * p2 sh) (t - pbias - sh)
    else
      let drop := k - 24
      let q := m >>> drop
      let low := m &&& (p2 drop - 1)
      let half := p2 (drop - 1)
      let up := low > half || (low == half && (sticky || q &&& 1 == 1))
      let q := if up then q + 1 else q
      -- The round-up carried into bit 24: renormalise, one exponent higher.
      -- Written as two scalars rather than one `(q, p)` pair because a tuple
      -- here is a heap allocation on every arithmetic operation.
      let carry := q == 16777216
      let q := if carry then 8388608 else q
      let t := p + drop + bias + (if carry then 1 else 0)
      if t ≤ pbias then 0 else mk neg q (t - pbias)

def ofNat (n : Nat) : F32 := norm false n pbias false

/-- The binary32 nearest to `num / den`. -/
def ofRat (num den : Nat) : F32 :=
  if num == 0 || den == 0 then 0
  else
    -- `k` puts the quotient at roughly 26 bits: wide enough that the rounding
    -- position and the sticky bit are inside it, narrow enough that it never
    -- becomes a bignum (`bitLen`'s bound).  `den` can be as large as
    -- `Svg.opacityOne`, so scaling by a flat `2^(26 + bitLen den)` would.
    let bn := bitLen num
    let bd := bitLen den
    let k := if bn ≥ bd + 26 then 0 else 26 + bd - bn
    let q := (num <<< k) / den
    norm false q (pbias - k) (q * den != num <<< k)

def neg (a : F32) : F32 := if a == 0 then 0 else a ^^^ 1

def mul (a b : F32) : F32 :=
  if a == 0 || b == 0 then 0
  else
    norm (isNeg a != isNeg b) (mant a * mant b) (expo a + expo b + (pbias - 2 * bias)) false

def add (a b : F32) : F32 :=
  if a == 0 then b
  else if b == 0 then a
  else
    -- `hi` is the operand of larger magnitude (again two scalars rather than a
    -- swapped pair, to keep the hot path allocation-free).
    let swap := !(expo a > expo b || (expo a == expo b && mant a ≥ mant b))
    let hi := if swap then b else a
    let lo := if swap then a else b
    let d := expo hi - expo lo
    -- `lo` is then below an eighth of `hi`'s last place: `hi ± lo` rounds to `hi`.
    if d > 26 then hi
    else
      let ma := mant hi * p2 d
      let mb := mant lo
      let p := expo lo + (pbias - bias)
      if isNeg hi == isNeg lo then norm (isNeg hi) (ma + mb) p false
      else norm (isNeg hi) (ma - mb) p false

def sub (a b : F32) : F32 := add a (neg b)

def div (a b : F32) : F32 :=
  if a == 0 || b == 0 then 0
  else
    let num := mant a * 67108864
    let q := num / mant b
    norm (isNeg a != isNeg b) q (expo a + (pbias - 26) - expo b) (q * mant b != num)

def sqrt (a : F32) : F32 :=
  if a == 0 || isNeg a then 0
  else
    -- The exponent must be even before it is halved; `pbias` is even, so the
    -- working exponent's parity is the true one's.
    let pRaw := expo a + (pbias - bias)
    let odd := pRaw % 2 == 1
    let m := if odd then mant a * 2 else mant a
    let p0 := if odd then pRaw - 1 else pRaw
    let big := m * p2 52
    let r := Nat.sqrt big
    norm false r ((p0 + pbias - 52) / 2) (r * r != big)

/-- `a < b`.  Non-negative words compare directly (the exponent sits above the
mantissa), and two negatives compare by magnitude, reversed, with the sign bit
shifted off.  That is what the packing above is for. -/
def lt (a b : F32) : Bool :=
  match isNeg a, isNeg b with
  | false, false => a < b
  | true, true => (b >>> 1) < (a >>> 1)
  | true, false => true
  | false, true => false

def le (a b : F32) : Bool := !(lt b a)
def gt (a b : F32) : Bool := lt b a
def ge (a b : F32) : Bool := !(lt a b)
/-- SSE `min`: the second operand on equality.  Named `fmin`/`fmax` rather
than `min`/`max` so they never collide with the `Min`/`Max` classes on the
underlying `Nat`. -/
def fmin (a b : F32) : F32 := if lt a b then a else b
def fmax (a b : F32) : F32 := if lt b a then a else b

def one : F32 := ofNat 1
def two : F32 := ofNat 2
def seven : F32 := ofNat 7
def c255 : F32 := ofNat 255
/-- `1.0 / 255.0` as tiny-skia's `load_8888` computes it. -/
def inv255 : F32 := ofRat 1 255
/-- The `lum` weights of the non-separable modes, as f32 literals. -/
def w30 : F32 := ofRat 30 100
def w59 : F32 := ofRat 59 100
def w11 : F32 := ofRat 11 100

/-- `unnorm`: `round_to_nearest_even (clamp (v, 0, 1) · 255)`. -/
def toU8 (v : F32) : Nat :=
  if v == 0 || isNeg v then 0
  else if !(lt v one) then 255
  else
    let p := mul v c255
    let m := mant p
    let eb := expo p
    if eb ≥ bias then m * p2 (eb - bias)
    else
      let s := bias - eb
      if s > 30 then 0
      else
        let q := m >>> s
        let low := m &&& (p2 s - 1)
        let half := p2 (s - 1)
        if low > half || (low == half && q &&& 1 == 1) then q + 1 else q

end F32

/-- The sixteen `mix-blend-mode` values. -/
inductive BlendMode where
  | normal | multiply | screen | overlay | darken | lighten | colorDodge | colorBurn
  | hardLight | softLight | difference | exclusion | hue | saturation | color | luminosity
deriving Repr, Inhabited, BEq

namespace Canvas

open F32 in
/-- `pipeline/highp.rs`, the `blend_fn`/`blend_fn2` channel formulas, on
premultiplied `(s, sa)` over `(d, da)`.  The evaluation order of every `+` and
`·` is the Rust source's, so the roundings happen in the same places. -/
def blendSep (mode : BlendMode) (s d sa da : F32) : F32 :=
  let inv := fun v => sub one v
  let two := fun v => add v v
  match mode with
  | .multiply => add (add (mul s (inv da)) (mul d (inv sa))) (mul s d)
  | .screen => sub (add s d) (mul s d)
  | .darken => sub (add s d) (fmax (mul s da) (mul d sa))
  | .lighten => sub (add s d) (fmin (mul s da) (mul d sa))
  | .difference => sub (add s d) (two (fmin (mul s da) (mul d sa)))
  | .exclusion => sub (add s d) (two (mul s d))
  | .colorBurn =>
    if d == da then add d (mul s (inv da))
    else if s == 0 then mul d (inv sa)
    else
      let t := mul (mul (sub da d) sa) (div one s)
      add (add (mul sa (sub da (fmin da t))) (mul s (inv da))) (mul d (inv sa))
  | .colorDodge =>
    if d == 0 then mul s (inv da)
    else if s == sa then add s (mul d (inv sa))
    else
      let t := mul (mul d sa) (div one (sub sa s))
      add (add (mul sa (fmin da t)) (mul s (inv da))) (mul d (inv sa))
  | .hardLight =>
    let br := if le (two s) sa then two (mul s d)
      else sub (mul sa da) (two (mul (sub da d) (sub sa s)))
    add (add (mul s (inv da)) (mul d (inv sa))) br
  | .overlay =>
    let br := if le (two d) da then two (mul s d)
      else sub (mul sa da) (two (mul (sub da d) (sub sa s)))
    add (add (mul s (inv da)) (mul d (inv sa))) br
  | .softLight =>
    let m := if gt da 0 then div d da else 0
    let s2 := two s
    let m4 := two (two m)
    let darkSrc := mul d (add sa (mul (sub s2 sa) (sub one m)))
    let darkDst := add (mul (add (mul m4 m4) m4) (sub m one)) (mul seven m)
    let liteDst := sub (sqrt m) m
    let liteSrc := add (mul d sa) (mul (mul da (sub s2 sa)) (if le (two (two d)) da then darkDst else liteDst))
    add (add (mul s (inv da)) (mul d (inv sa))) (if le s2 sa then darkSrc else liteSrc)
  | _ => s

open F32 in
def sat (r g b : F32) : F32 := sub (fmax r (fmax g b)) (fmin r (fmin g b))

open F32 in
def lum (r g b : F32) : F32 := add (add (mul r w30) (mul g w59)) (mul b w11)

open F32 in
def setSat (r g b s : F32) : F32 × F32 × F32 :=
  let mn := fmin r (fmin g b)
  let mx := fmax r (fmax g b)
  let st := sub mx mn
  let scale := fun c => if st == 0 then 0 else div (mul (sub c mn) s) st
  (scale r, scale g, scale b)

open F32 in
def setLum (r g b l : F32) : F32 × F32 × F32 :=
  let diff := sub l (lum r g b)
  (add r diff, add g diff, add b diff)

open F32 in
def clipColor (r g b a : F32) : F32 × F32 × F32 :=
  let mn := fmin r (fmin g b)
  let mx := fmax r (fmax g b)
  let l := lum r g b
  let clip := fun c =>
    let c := if ge mx 0 then c else add l (div (mul (sub c l) l) (sub l mn))
    let c := if gt mx a then add l (div (mul (sub c l) (sub a l)) (sub mx l)) else c
    fmax c 0
  (clip r, clip g, clip b)

open F32 in
/-- `hue_k`, `saturation_k`, `color_k`, `luminosity_k`. -/
def blendNonSep (mode : BlendMode) (r g b a dr dg db da : F32) : F32 × F32 × F32 × F32 :=
  let inv := fun v => sub one v
  let (rr, gg, bb) := match mode with
    | .hue =>
      let (x, y, z) := setSat (mul r a) (mul g a) (mul b a) (mul (sat dr dg db) a)
      setLum x y z (mul (lum dr dg db) a)
    | .saturation =>
      let (x, y, z) := setSat (mul dr a) (mul dg a) (mul db a) (mul (sat r g b) da)
      setLum x y z (mul (lum dr dg db) a)
    | .color => setLum (mul r da) (mul g da) (mul b da) (mul (lum dr dg db) a)
    | _ => setLum (mul dr a) (mul dg a) (mul db a) (mul (lum r g b) da)
  let (rr, gg, bb) := clipColor rr gg bb (mul a da)
  (add (add (mul r (inv da)) (mul dr (inv a))) rr,
   add (add (mul g (inv da)) (mul dg (inv a))) gg,
   add (add (mul b (inv da)) (mul db (inv a))) bb,
   sub (add a da) (mul a da))

open F32 in
/-- One layer pixel `s` (premultiplied, packed) over one destination pixel `d`
through the highp pipeline.  `srcTab`/`dstTab` hold `c8 · F (· opacity)` and
`c8 · F` for every byte value, hoisted out of the pixel loop. -/
def blendPixel (mode : BlendMode) (srcTab dstTab : Array F32) (s d : Nat) : Nat :=
  let r := srcTab.getD ((s >>> 24) &&& 255) 0
  let g := srcTab.getD ((s >>> 16) &&& 255) 0
  let b := srcTab.getD ((s >>> 8) &&& 255) 0
  let a := srcTab.getD (s &&& 255) 0
  let dr := dstTab.getD ((d >>> 24) &&& 255) 0
  let dg := dstTab.getD ((d >>> 16) &&& 255) 0
  let db := dstTab.getD ((d >>> 8) &&& 255) 0
  let da := dstTab.getD (d &&& 255) 0
  let mad := fun f m x => add (mul f m) x
  let (r, g, b, a) : F32 × F32 × F32 × F32 :=
    match mode with
    | .normal =>
      let ia := sub one a
      (mad dr ia r, mad dg ia g, mad db ia b, mad da ia a)
    | .multiply | .screen =>
      (blendSep mode r dr a da, blendSep mode g dg a da, blendSep mode b db a da,
       blendSep mode a da a da)
    | .hue | .saturation | .color | .luminosity => blendNonSep mode r g b a dr dg db da
    | _ =>
      (blendSep mode r dr a da, blendSep mode g dg a da, blendSep mode b db a da,
       mad da (sub one a) a)
  pack (toU8 r) (toU8 g) (toU8 b) (toU8 a)

/-- Composite `layer` onto `cv` with its top-left corner at pixel `(ox, oy)` of
`cv`, with `opacity` (a binary32 in `[0, 1]`, `F32.one` for none) and `mode`.

A transparent layer pixel leaves the destination untouched in every mode (with
`s = sa = 0` each formula collapses to `d` exactly, in f32 as much as here),
so those are skipped without arithmetic; an opaque pixel composited normally
at full opacity is the source itself (`255 · F` rounds to exactly `1.0`, so
`inv(sa) = 0` and `unnorm` returns the byte it came from), so that case is a
copy.  Everything else goes through `blendPixel`. -/
def compositeLayer (cv layer : Canvas) (ox oy : Nat) (opacity : F32) (mode : BlendMode) :
    Canvas := Id.run do
  let scaled := opacity != F32.one
  let byteTab := (Array.range 256).map fun c => F32.mul (F32.ofNat c) F32.inv255
  let srcTab := if scaled then byteTab.map (F32.mul · opacity) else byteTab
  let copyOpaque := mode == .normal && !scaled
  -- `w` and `h` are read out *before* `px`, and `cv` is not touched again, so
  -- the destination array reaches the loop uniquely referenced and is updated
  -- in place; mentioning `cv.h` inside the loop would keep `cv` alive and cost
  -- a full copy of the canvas on the first write.
  let w := cv.w
  let h := cv.h
  let lw := layer.w
  let mut px := cv.px
  for ly in [0:layer.h] do
    let y := oy + ly
    if y ≥ h then break
    let lrow := ly * lw
    let row := y * w
    for lx in [0:lw] do
      let s := layer.px.getD (lrow + lx) 0
      let sa := s &&& 255
      if sa == 0 then continue
      let x := ox + lx
      if x ≥ w then break
      let idx := row + x
      if copyOpaque && sa == 255 then
        px := px.setIfInBounds idx s
      else
        px := px.setIfInBounds idx (blendPixel mode srcTab byteTab s (px.getD idx 0))
  return ⟨w, h, px⟩

end Canvas
end MicroSvg
