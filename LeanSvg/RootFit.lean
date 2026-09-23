import LeanSvg.Svg

/-!
# Root size refit (T86)

usvg's `resolve_svg_size` falls back to `Options::default_size` (100×100) for a
root `<svg>` with no `viewBox` whose `width` or `height` is absent or a
percentage, and flags that case (`restore_viewbox`).  After the whole tree is
built, `calculate_svg_bbox` replaces the document size by
`(bbox.right, bbox.bottom)` of the root's absolute object bounding box (fill
geometry, no stroke, no filter or clip), keeping the fallback when that box
has no positive right/bottom edge.  No `viewBox` means the root transform is
the identity, so the refit only changes the canvas size.

`apply` runs on the finished node stream, before `Render.canvasSetup`, so the
canvas size it picks is still checked against `maxDim`/`maxPixels` before
anything is allocated.  Content keeps the viewport it was interpreted against
(the pre-refit size), as in usvg.
-/

namespace LeanSvg
namespace RootFit

open Svg

/-- `restore_viewbox`: no `viewBox`, and `width` or `height` absent or a
percentage (an absent one defaults to `100%`). -/
def needsRefit (root : RootInfo) : Bool :=
  let pctOrNone : Option (Fx × Bool) → Bool := fun l => match l with
    | none => true
    | some (_, pct) => pct
  root.viewBox.isNone && (pctOrNone root.width || pctOrNone root.height)

/-- The pre-refit size: each side resolved against the 100 × 100 default. -/
def fallbackSize (root : RootInfo) : Fx × Fx :=
  let side : Option (Fx × Bool) → Fx := fun l => match l with
    | none => Fx.ofNat 100
    | some lp => resolvePct lp (Fx.ofNat 100)
  (side root.width, side root.height)

/-- The union of every painted shape's flattened geometry (flattened in its
own space, finely enough for its `ctm`, then mapped through it) in root user space
(`Group::abs_bounding_box`, tight bounds up to the flattening error). -/
def contentBox (nodes : Array Node) : Option Box := Id.run do
  let mut b : Option Box := none
  for n in nodes do
    match n with
    | .shape s =>
      for poly in flatten s.style.ctm s.cmds do
        for p in poly.pts do
          b := Box.cover b (s.style.ctm.apply p)
    | _ => pure ()
  return b

/-- `calculate_svg_bbox`: give a root that needs it an explicit size. -/
def apply (doc : Doc) : Doc :=
  if !needsRefit doc.root then doc
  else
    let (w, h) := match contentBox doc.nodes with
      | some b => if b.x1 > 0 && b.y1 > 0 then (b.x1, b.y1) else fallbackSize doc.root
      | none => fallbackSize doc.root
    { doc with root := { doc.root with width := some (w, false), height := some (h, false) } }

end RootFit
end LeanSvg
