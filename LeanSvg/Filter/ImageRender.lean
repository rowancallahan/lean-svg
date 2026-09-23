import LeanSvg.FilterApply
import LeanSvg.Svg

/-!
# `feImage` (T67): what `Render` needs to fill in a primitive

`Render.renderNodes` does the rendering itself (it has to call itself); this
module finds the `feImage` primitives of a filter, with the geometry resvg's
`apply_image` uses, and builds the linked element's sub-document.
-/

namespace LeanSvg
namespace FeImage

/-- One `feImage` of a filter: its primitive index, the filter region's size
in pixels (resvg's pixmap), and the subregion in layer pixels. -/
structure Job where
  prim : Nat
  spec : Spec
  rw : Nat
  rh : Nat
  sx : Int
  sy : Int
  sw : Int
  sh : Int
  /-- The subregion's own width/height in *user* units (`p.sub`, before `ts`):
  what a `data:` href is fit into by `preserveAspectRatio`, matching usvg's
  `filter_subregion` (`sw`/`sh` are its already-scaled device pixels, whose
  aspect ratio can differ from this one under a non-uniform `ts`). -/
  uw : Fx
  uh : Fx

/-- The `feImage`s of `f` on a `w × h` layer whose pixels `ts` maps the filter's
user space to, with `FilterApply.run`'s region (`fit_to_rect`); none when the
region is empty, since `run` then clears the layer without looking. -/
def jobs (f : Filter.Resolved) (ts : Mat) (w h : Nat) : Array Job := Id.run do
  let some (gx, gy, gw, gh) := FilterApply.devRect ts f.region | return #[]
  let x0 := max gx 0
  let y0 := max gy 0
  let x1 := min (gx + gw) w
  let y1 := min (gy + gh) h
  if x1 ≤ x0 || y1 ≤ y0 then return #[]
  let mut out : Array Job := #[]
  for i in [0:f.prims.size] do
    let p := f.prims.getD i default
    match p.kind, FilterApply.devRect ts p.sub with
    | .image s, some (sx, sy, sw, sh) =>
      out := out.push ⟨i, s, (x1 - x0).toNat, (y1 - y0).toNat, sx, sy, sw, sh, p.sub.w, p.sub.h⟩
    | _, _ => pure ()
  return out

/-- resvg's `Transform::from_row(sx, 0, 0, sy, subregion.x, subregion.y)`: the
linked element's user space onto the region pixmap. -/
def Job.mat (j : Job) (ts : Mat) : Mat :=
  let (sx, sy) := FilterApply.scaleOf ts
  Mat.mk' sx 0 0 sy (j.sx * 256) (j.sy * 256)

/-- Store a rendered image in primitive `pi` of filter `fi`. -/
def setPre (fs : Array Filter.Resolved) (fi pi : Nat) (cv : Canvas) : Array Filter.Resolved :=
  fs.modify fi fun f => { f with prims := f.prims.modify pi fun p =>
    match p.kind with
    | .image s => { p with kind := .image { s with pre := some cv } }
    | _ => p }

/-- What rendering one link costs against `Render.maxMaskRenders`: one render,
plus the sub-document's interpretation, which is about the document's size. -/
def cost (events : Array Xml.Event) : Nat := 1 + events.size / 4096

/-- The linked element as a document of its own; `none` when nothing has that
id (the dummy primitive). -/
def subDoc (events : Array Xml.Event) (id : String) : Except String (Option Svg.Doc) :=
  match subEvents events id with
  | none => .ok none
  | some evs => (Svg.interpret evs).map some

end FeImage
end LeanSvg
