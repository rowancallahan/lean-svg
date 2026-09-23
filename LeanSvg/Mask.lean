import LeanSvg.Clip
import LeanSvg.FilterApply

/-!
# `mask` (T49)

resvg (`crates/resvg/src/mask.rs`, usvg `parser/mask.rs`) masks a group's
finished layer after its clip and before the opacity/blend composite:

1. the mask's children are rendered, with the layer's own transform, onto a
   transparent pixmap the size of the layer (`render_nodes`);
2. that pixmap is multiplied by the anti-aliased coverage of the mask region
   `x/y/width/height` (`apply_mask` with a `fill_path` mask);
3. the `mask` element's own linked `mask`, if any, is applied to the *layer*
   (recursively, so the deepest link multiplies first);
4. the pixmap becomes an 8-bit mask — its alpha (`mask-type: alpha`) or its
   luminance — and multiplies the layer (`DestinationIn`, `div255`).

`Render.renderNodes` does step 1 (it has to call itself) and the multiplies;
this module holds the parts that do not render: resolving a use into the chain
of masks it applies, the region, and the pixel → coverage map.

Validity (usvg): a region with a non-positive width or height, a linked mask
that is invalid, or `maskContentUnits="objectBoundingBox"` on an element with
no box, makes the element not rendered; `maskUnits="objectBoundingBox"` on an
element with no box masks the whole element away.  Both are `Res.skip` here.
An id that resolves to no `mask` is ignored.  Cycles are cut when the document
is interpreted (`Svg.fixRecursiveMaskLinks`); `maxDepth` bounds what is left.
-/

namespace LeanSvg
namespace Mask

open Svg

/-- One mask of a resolved chain: its table index, its region in the masked
element's user space, and the map from its content's user space into that one
(the identity, or the box's unit square for `maskContentUnits`). -/
structure Step where
  entry : Nat
  region : Box
  content : Mat
deriving Inhabited

/-- `skip`: the element is not rendered (or masked away entirely).  `chain`:
the masks to apply, outermost (the element's own) first. -/
inductive Res where
  | skip
  | chain (steps : Array Step)

/-- Longest chain of `mask` links followed. -/
def maxDepth : Nat := 8

/-- One region coordinate on the 16.16 grid: a fraction of the box
(`objectBoundingBox`; `N%` is `N/100`) or user units (`userSpaceOnUse`; `N%`
is of the viewport side `ref`, in `Fx`). -/
def coord (user : Bool) (l : Option Grad.LenPct) (dflt : Grad.LenPct) (ref : Fx) : Int :=
  let (v, pct) := l.getD dflt
  if !pct then v
  else if user then Int.ediv (v * ref) 25600
  else Int.ediv v 100

/-- The region in the element's user space, or `none` for a non-positive size.
`bbox` must be a non-empty box when the units are `objectBoundingBox`. -/
def region (e : MaskEntry) (bbox : Box) : Option Box :=
  let u := e.userUnits
  let x := coord u e.x (-655360, true) e.pctW
  let y := coord u e.y (-655360, true) e.pctH
  let w := coord u e.w (7864320, true) e.pctW
  let h := coord u e.h (7864320, true) e.pctH
  if w ≤ 0 || h ≤ 0 then none
  else if u then
    some ⟨Int.ediv x 256, Int.ediv y 256, Int.ediv (x + w) 256, Int.ediv (y + h) 256⟩
  else
    let bw := bbox.x1 - bbox.x0
    let bh := bbox.y1 - bbox.y0
    some ⟨bbox.x0 + Int.ediv (x * bw) 65536, bbox.y0 + Int.ediv (y * bh) 65536,
          bbox.x0 + Int.ediv ((x + w) * bw) 65536, bbox.y0 + Int.ediv ((y + h) * bh) 65536⟩

/-- Follow a use's mask and its `mask` links.  A dangling id is no mask. -/
def resolve (doc : Doc) (u : MaskUse) : Res := Id.run do
  let box? := u.bbox.filter Box.nonZero
  let b := box?.getD ⟨0, 0, 1, 1⟩
  let mut out : Array Step := #[]
  let mut cur := u.entry
  for _ in [0:maxDepth] do
    match cur with
    | none => return .chain out
    | some k =>
      let e := doc.masks.getD k default
      if !e.userUnits && box?.isNone then return .skip
      match region e b with
      | none => return .skip
      | some r =>
        let content := if !e.contentBBox then Mat.identity
          else match box? with
            | some bx => Box.unitMat bx
            | none => Mat.identity
        if e.contentBBox && box?.isNone then return .skip
        out := out.push ⟨k, r, content⟩
        cur := e.selfMask
  -- Still linked after `maxDepth` masks: a cycle `fixRecursiveMaskLinks` did
  -- not cut, or an absurd chain.  Not rendered, rather than truncated.
  if cur.isSome then return .skip
  return .chain out

/-- The device pixel rectangle `[x0, x1) × [y0, y1)` (not clipped to the
canvas) outside which the region's coverage is zero. -/
def regionPx (dev : Mat) (r : Box) : Int × Int × Int × Int :=
  match Box.transformed dev r with
  | some b => (Fx.floor b.x0 - 1, Fx.floor b.y0 - 1, Fx.ceil b.x1 + 1, Fx.ceil b.y1 + 1)
  | none => (0, 0, 0, 0)

/-- The region's anti-aliased coverage in device space (tiny-skia
`Mask::fill_path`, non-zero, anti-aliased), on the 0..255 grid. -/
def regionMask (W H : Nat) (dev : Mat) (r : Box) : Clip.Mask :=
  let cmds := rectPath r.x0 r.y0 (r.x1 - r.x0) (r.y1 - r.y0) 0 0
  let pts := (flatten dev cmds).map fun p => p.pts.map dev.apply
  match Raster.rasterize W H pts false with
  | some m => ⟨m.x0, m.y0, m.w, m.h, m.cov.map Clip.cov8⟩
  | none => ⟨0, 0, 0, 0, #[]⟩

/-- The luminance weights as the `f32` literals tiny-skia multiplies by. -/
def k1 : F32 := F32.ofRat 2126 10000
def k2 : F32 := F32.ofRat 7152 10000
def k3 : F32 := F32.ofRat 722 10000

/-- `⌈v⌉` of a binary32 in `[0, 255]`; `v = mant · 2^(expo − bias)`. -/
def ceilF32 (v : F32) : Nat :=
  if v == 0 then 0
  else
    let m := F32.mant v
    let eb := F32.expo v
    if eb ≥ F32.bias then m * F32.p2 (eb - F32.bias)
    else
      let s := F32.bias - eb
      if s > 60 then 1 else (m + F32.p2 s - 1) >>> s

/-- tiny-skia `Mask::from_pixmap`, `MaskType::Luminance`, in emulated `f32`:
normalise, demultiply, weight, remultiply, `ceil`. -/
def lumaF32 (r g b a : Nat) : Nat :=
  let c := F32.c255
  let fa := F32.div (F32.ofNat a) c
  let fr := F32.div (F32.div (F32.ofNat r) c) fa
  let fg := F32.div (F32.div (F32.ofNat g) c) fa
  let fb := F32.div (F32.div (F32.ofNat b) c) fa
  let luma := F32.add (F32.add (F32.mul fr k1) (F32.mul fg k2)) (F32.mul fb k3)
  let v := F32.mul (F32.mul luma fa) c
  if v == 0 || F32.isNeg v then 0
  else if F32.ge v c then 255
  else ceilF32 v

/-- One premultiplied pixel to its mask value.  The exact luminance of a
premultiplied pixel is `n / 10000` with `n = 2126 r + 7152 g + 722 b` (the
alpha divides out), and the `f32` path is within a few `1e-4` of it, so its
`ceil` is decided by `n` alone unless `n` is within `0.01` of an integer; only
those pixels pay for the `f32` emulation. -/
def maskValue (alpha : Bool) (p : Nat) : Nat :=
  let a := p &&& 255
  if alpha || a == 0 then a
  else
    let n := 2126 * (p >>> 24) + 7152 * ((p >>> 16) &&& 255) + 722 * ((p >>> 8) &&& 255)
    let rem := n % 10000
    if rem ≥ 100 && rem ≤ 9900 then n / 10000 + 1
    else lumaF32 (p >>> 24) ((p >>> 16) &&& 255) ((p >>> 8) &&& 255) a

/-- T90: the mask value under `color-interpolation="linearRGB"` on the
`<mask>` (SVG 1.1 §14.4, the suite PNG and Chromium; usvg never reads it):
the demultiplied colour goes through resvg's sRGB→linear table before the
luminance weights, then times alpha, rounded up. -/
def maskValueLinear (p : Nat) : Nat :=
  let a := p &&& 255
  if a == 0 then 0
  else
    let lin := fun (c : Nat) => FilterApply.srgbToLin.getD (Canvas.unpremul c a) 0
    let n := 2126 * lin (p >>> 24) + 7152 * lin ((p >>> 16) &&& 255) + 722 * lin ((p >>> 8) &&& 255)
    Nat.min 255 ((n * a + 2549999) / 2550000)

/-- A rendered mask canvas whose pixel `(0, 0)` sits at device `(ox, oy)`, as
a device-space `Clip.Mask`. -/
def toClipMask (cv : Canvas) (ox oy : Nat) (alpha : Bool) (linear : Bool := false) : Clip.Mask :=
  ⟨ox, oy, cv.w, cv.h, cv.px.map (if linear && !alpha then maskValueLinear else maskValue alpha)⟩

end Mask
end LeanSvg
