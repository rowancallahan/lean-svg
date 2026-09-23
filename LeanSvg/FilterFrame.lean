import LeanSvg.Geom
import LeanSvg.Canvas
import LeanSvg.Filter
import LeanSvg.Svg

/-!
# Filters under rotation and skew (T90): a local frame for the filter layer

resvg (and `Render`'s ordinary filter layer) filters in an axis-aligned
device-pixel box, so a primitive's own geometry — a blur axis, an offset, a
flood or turbulence rectangle, a subregion — stays screen-aligned when the
element is rotated or skewed.  The spec (and the suite PNG, Chromium) filter in
the element's user space, then transform the result.

When the device matrix `D` of the filter's user space has a rotation or skew
(`b ≠ 0` or `c ≠ 0`), the layer is instead a *local* frame:

    local pixel = S · user − (x0, y0),     S = diag(|D·e₁|, |D·e₂|)

— the user space scaled by `D`'s column lengths, so the layer keeps device
resolution and the filter sees an axis-aligned scale (`FilterApply.scaleOf`),
exactly its ordinary case.  After the filters run, the layer is resampled
(bilinear, transparent outside) into the parent frame through `D · S⁻¹`.

Tiles: `D` is taken in whole-frame coordinates (the parent's `vx`/`vy` added
back), so the local frame and every sampled pixel depend only on the pixel's
position in the whole image, never on the band.
-/

namespace LeanSvg
namespace FilterFrame

/-- The resampling back into the parent frame: `local = K · (P − t) − (x0, y0)`
with `K = S · L⁻¹` in 32 fractional bits, `P` a whole-frame pixel centre. -/
structure Back where
  k11 : Int
  k12 : Int
  k21 : Int
  k22 : Int
  tx : Fx
  ty : Fx
  x0 : Int
  y0 : Int
  /-- Local pixels to band pixels, for the output's bounding box only. -/
  fwd : Mat
  /-- The parent frame's `vx`/`vy`. -/
  vx : Int
  vy : Int
deriving Inhabited

/-- A planned local filter layer. -/
structure Plan where
  w : Nat
  h : Nat
  /-- The filters' user space to layer pixels (`Layer.fts`). -/
  fts : Mat
  /-- The document's root user space to layer pixels (`curRoot` inside). -/
  root : Mat
  back : Back
deriving Inhabited

/-- `S · M⁻¹` for `M`'s linear part, `S = diag(sx, sy)` (16.16), in `2^sh`
fractional bits: `(k11, k12, k21, k22)`, `none` when `M` is singular. -/
def invScaled (m : Mat) (sx sy : Int) (sh : Nat) : Option (Int × Int × Int × Int) :=
  let det := m.a * m.d - m.b * m.c
  if det == 0 then none
  else
    let k : Int := 2 ^ sh
    some (Int.ediv (sx * m.d * k) det, Int.ediv (-sx * m.c * k) det,
          Int.ediv (-sy * m.b * k) det, Int.ediv (sy * m.a * k) det)

/-- Plan a local frame for a filter group whose user space maps to the band by
`dev`, inside a frame at `(vx, vy)` of the whole image; `fcm` maps that user
space to the document root's.  `none` when `dev` is axis-aligned (the ordinary
layer is exact then), singular, or the local layer is empty or past `maxPx`. -/
def plan (vx vy : Int) (dev fcm : Mat) (fs : Array Filter.Resolved) (maxPx : Nat) :
    Option Plan := Id.run do
  if dev.b == 0 && dev.c == 0 then return none
  let sx : Int := Nat.sqrt (dev.a * dev.a + dev.b * dev.b).toNat
  let sy : Int := Nat.sqrt (dev.c * dev.c + dev.d * dev.d).toNat
  if sx == 0 || sy == 0 then return none
  let mut u : Option Box := none
  for f in fs do
    let r := f.region
    u := Svg.Box.union u (some ⟨r.x, r.y, r.x + r.w, r.y + r.h⟩)
  let some ub := u | return none
  let sm := Mat.scale16 sx sy
  let lb : Box ← match Svg.Box.transformed sm ub with
    | some b => pure b
    | none => return none
  let x0 := Fx.floor lb.x0
  let y0 := Fx.floor lb.y0
  let w := (max 1 (Fx.ceil (lb.x1 - lb.x0))).toNat
  let h := (max 1 (Fx.ceil (lb.y1 - lb.y0))).toNat
  if w * h > maxPx then return none
  let fts := (Mat.translate (-(x0 * 256)) (-(y0 * 256))).mul sm
  -- `root · fcm = fts`: the root user space goes through `fcm⁻¹` first.
  let some (r11, r12, r21, r22) := invScaled fcm sx sy 16 | return none
  let re := -(Int.ediv (r11 * fcm.e + r12 * fcm.f) 65536) - x0 * 256
  let rf := -(Int.ediv (r21 * fcm.e + r22 * fcm.f) 65536) - y0 * 256
  let root := Mat.mk' r11 r21 r12 r22 re rf
  -- Whole-frame device matrix of the user space.
  let dx := dev.e + vx * 256
  let dy := dev.f + vy * 256
  let some (k11, k12, k21, k22) := invScaled dev sx sy 32 | return none
  -- Local pixels to band pixels: `dev · S⁻¹ · translate(x0, y0)`.
  let isx := Int.ediv (65536 * 65536) sx
  let isy := Int.ediv (65536 * 65536) sy
  let fwd := (dev.mul (Mat.scale16 isx isy)).mul (Mat.translate (x0 * 256) (y0 * 256))
  return some { w, h, fts, root,
                back := { k11, k12, k21, k22, tx := dx, ty := dy, x0, y0, fwd, vx, vy } }

/-- Does the filter's result depend on the orientation of its user space,
so that the axis-aligned layer would visibly differ?  An isotropic blur, a
colour operation or a composite commute with a rotation (up to the resampling,
which is then pure loss); anything with a direction, or that fills its region,
or a subregion that cuts the image, does not.  A region that cuts the content
is `Render`'s check, since it needs the content's box. -/
def sensitive (fs : Array Filter.Resolved) : Bool :=
  fs.any fun f => f.prims.any fun p =>
    p.sub != f.region ||
    match p.kind with
    | .offset _ dx dy => dx != 0 || dy != 0
    | .blur _ sx sy => sx != sy
    | .dropShadow _ dx dy sx sy .. => dx != 0 || dy != 0 || sx != sy
    | .morphology _ _ rx ry => rx != ry
    | .merge _ | .blend .. | .composite .. | .colorMatrix .. | .transfer .. => false
    | _ => true

@[inline] def chan (v : Nat) (s : Nat) : Nat := (v >>> s) &&& 255

/-- The premultiplied pixel of `c` at `(i, j)`, transparent outside. -/
@[inline] def texel (c : Canvas) (i j : Int) : Nat :=
  if i < 0 || j < 0 || i ≥ c.w || j ≥ c.h then 0
  else c.px.getD (j.toNat * c.w + i.toNat) 0

/-- Resample the filtered local layer `src` into the parent frame, whose canvas
sits at band pixel `(ox, oy)` and is `pw × ph`: the part of `src`'s image that
lands there, as a canvas and its band position; `none` if nothing does. -/
def resample (b : Back) (src : Canvas) (ox oy pw ph : Nat) : Option (Canvas × Nat × Nat) := Id.run do
  let cs := #[b.fwd.apply ⟨0, 0⟩, b.fwd.apply ⟨src.w * 256, 0⟩,
              b.fwd.apply ⟨0, src.h * 256⟩, b.fwd.apply ⟨src.w * 256, src.h * 256⟩]
  let bb : Box ← match cs.foldl (fun o p => Box.cover o p) none with
    | some b => pure b
    | none => return none
  let x0 := max (Fx.floor bb.x0 - 2) (ox : Int)
  let y0 := max (Fx.floor bb.y0 - 2) (oy : Int)
  let x1 := min (Fx.ceil bb.x1 + 2) ((ox + pw : Nat) : Int)
  let y1 := min (Fx.ceil bb.y1 + 2) ((oy + ph : Nat) : Int)
  if x1 ≤ x0 || y1 ≤ y0 then return none
  let w := (x1 - x0).toNat
  let h := (y1 - y0).toNat
  let mut px : Array Nat := Array.replicate (w * h) 0
  let one : Int := 4294967296
  for j in [0:h] do
    -- Pixel centre, whole frame, in 1/512 px, relative to the translation.
    let py := (2 * (y0 + j + b.vy) + 1) * 256 - 2 * b.ty
    for i in [0:w] do
      let qx := (2 * (x0 + i + b.vx) + 1) * 256 - 2 * b.tx
      -- local coordinates in 32 fractional bits, minus the texel centre
      let lx := Int.ediv (b.k11 * qx + b.k12 * py) 512 - b.x0 * one - one / 2
      let ly := Int.ediv (b.k21 * qx + b.k22 * py) 512 - b.y0 * one - one / 2
      let iu := Int.ediv lx one
      let iv := Int.ediv ly one
      if iu < -1 || iv < -1 || iu ≥ src.w || iv ≥ src.h then continue
      let fu := Int.ediv (Int.emod lx one) 65536
      let fv := Int.ediv (Int.emod ly one) 65536
      let t00 := texel src iu iv
      let t10 := texel src (iu + 1) iv
      let t01 := texel src iu (iv + 1)
      let t11 := texel src (iu + 1) (iv + 1)
      if t00 == 0 && t10 == 0 && t01 == 0 && t11 == 0 then continue
      let w00 := ((65536 - fu) * (65536 - fv)).toNat
      let w10 := (fu * (65536 - fv)).toNat
      let w01 := ((65536 - fu) * fv).toNat
      let w11 := (fu * fv).toNat
      let mix := fun (s : Nat) =>
        Nat.min 255 ((w00 * chan t00 s + w10 * chan t10 s + w01 * chan t01 s
          + w11 * chan t11 s + 2147483648) >>> 32)
      px := px.setIfInBounds (j * w + i) (Canvas.pack (mix 24) (mix 16) (mix 8) (mix 0))
  return some (⟨w, h, px⟩, x0.toNat, y0.toNat)

end FilterFrame
end LeanSvg
