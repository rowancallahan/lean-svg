import LeanSvg.Canvas
import LeanSvg.Xml
import LeanSvg.Viewport
import LeanSvg.Use
import LeanSvg.Image

/-!
# `feImage` (T67): the parts that run before rendering

usvg (`parser/filter.rs`, `convert_image`) turns an `feImage` into one of:

* a link to an element of the same document (`href="#id"`): the element is
  converted on its own — its own `transform`, `opacity`, `filter`, … apply;
  its ancestors' transforms do not, their inherited properties do — and resvg
  (`filter/mod.rs`, `apply_image`) renders it with
  `[sx 0 0 sy subregion.x subregion.y]` onto a region-sized pixmap, `sx`/`sy`
  being the filter transform's scale;
* an image it can decode (a `data:` URL, or a file resvg would load): drawn
  into the subregion under `preserveAspectRatio`;
* anything else (no `href`, a missing id, an undecodable or external image):
  the dummy primitive, a transparent-black flood.

This renderer has no node tree to convert an element from, so a link is
rendered from a *sub-document*: the document's events with every child of the
root moved into one `<defs>` (so every paint server, filter, clip and mask is
still defined) followed by the target's subtree under one `<g>` per ancestor
that carries only what the ancestor passes on by inheritance.  `Render`
interprets it with `Svg.interpret` and paints it with `Render.renderNodes`.

`fixRecursive` is usvg's `fix_recursive_fe_image`: a linked element whose own
`filter` names the `feImage`'s filter gets `filter="none"`, everywhere.
Longer cycles are cut by `renderNodes`' fuel.
-/

namespace LeanSvg
namespace FeImage

open Bytes

/-- What `href` names. -/
inductive Href where
  | elem (id : String)
  | data (uri : ByteArray)
  /-- No `href`, or one this renderer never loads (a file, a URL). -/
  | other
deriving Inhabited

structure Spec where
  href : Href
  aspect : Viewport.AspectRatio
  /-- `image-rendering`, resolved the way usvg's `find_attribute` reads it for
  `feImage`: the element's own attribute, or bicubic (`auto`) when absent. -/
  quality : Image.Quality := .bicubic
  /-- Filled in by `Render` just before the filter runs: the element or image,
  rendered onto the filter region's pixels.  `none` is the dummy primitive. -/
  pre : Option Canvas := none
deriving Inhabited

def attr (attrs : Array Xml.Attr) (name : String) : Option ByteArray :=
  (attrs.find? (fun a => a.name == name)).map (·.value)

/-- `href` with SVG 2's precedence (an unprefixed `href` wins). -/
def parse (attrs : Array Xml.Attr) : Spec :=
  let aspect := ((attr attrs "preserveAspectRatio").map Viewport.parseAspectRatio).getD {}
  let quality := ((attr attrs "image-rendering").map Image.parseRendering).getD .bicubic
  let href : Href := match Use.hrefId attrs with
    | some id => .elem id
    | none =>
      match (attr attrs "href").orElse (fun _ => attr attrs "xlink:href") with
      | some v => if startsWith (trim v) 0 "data:" then .data (trim v) else .other
      | none => .other
  { href, aspect, quality }

/-- Intersect a mask with an axis-aligned rectangle (device pixels): usvg's
"Image slice acts like a rectangular clip" for a `slice` `preserveAspectRatio`.
`Render.clipMask`'s logic, kept local since this module is one of `Render`'s
own dependencies and cannot import it back. -/
def clipToRect (m : Raster.Mask) (x0 y0 x1 y1 : Nat) : Option Raster.Mask :=
  if x0 ≤ m.x0 && y0 ≤ m.y0 && m.x0 + m.w ≤ x1 && m.y0 + m.h ≤ y1 then some m
  else
    let cx0 := Nat.max m.x0 x0
    let cy0 := Nat.max m.y0 y0
    let cx1 := Nat.min (m.x0 + m.w) x1
    let cy1 := Nat.min (m.y0 + m.h) y1
    if cx1 ≤ cx0 || cy1 ≤ cy0 then none
    else Id.run do
      let w := cx1 - cx0
      let h := cy1 - cy0
      let mut cov : Array Nat := Array.replicate (w * h) 0
      for j in [0:h] do
        let src := (cy0 - m.y0 + j) * m.w + (cx0 - m.x0)
        let dst := j * w
        for i in [0:w] do
          cov := cov.setIfInBounds (dst + i) (m.cov.getD (src + i) 0)
      return some ⟨cx0, cy0, w, h, cov⟩

/-- **The `data:` call site**, wired to T63's `LeanSvg.Image`: decode `uri`
and fit it (`preserveAspectRatio`) into the subregion, whose own size in user
units is `(uw, uh)` (usvg's `image::convert_inner` with
`filter_subregion.translate_to(0, 0)`), then place that onto the `rw × rh`
region canvas through `mat` — the same `[sx 0 0 sy subregion.x subregion.y]`
transform (`Job.mat`) the `href="#id"` link case renders with, i.e. resvg's
`apply_image`.  `none` — the dummy primitive — for an undecodable image, an
empty viewport, or a singular `mat`. -/
def dataCanvas (uri : ByteArray) (aspect : Viewport.AspectRatio) (quality : Image.Quality)
    (rw rh : Nat) (uw uh : Fx) (mat : Mat) : Option Canvas :=
  match Image.load uri with
  | none => none
  | some pix =>
    match Image.place pix 0 0 (some uw) (some uh) aspect quality with
    | none => none
    | some (cmds, placed, clip?) =>
      let dev := (flatten mat cmds).map fun p => p.pts.map mat.apply
      match Raster.rasterize rw rh dev false with
      | none => none
      | some m0 =>
        let clipped : Option Raster.Mask := match clip? with
          | none => some m0
          | some (cx, cy, cw, ch) =>
            let p0 := mat.apply ⟨cx, cy⟩
            let p1 := mat.apply ⟨cx + cw, cy + ch⟩
            clipToRect m0 (Fx.floor p0.x).toNat (Fx.floor p0.y).toNat
              (Fx.ceil p1.x).toNat (Fx.ceil p1.y).toNat
        match clipped, Image.build placed mat 0 0 with
        | some m, some sh => some (Canvas.fillMaskImage (Canvas.new rw rh none) m sh)
        | _, _ => none

/-! ## The event rewrites -/

/-- At most this many `feImage` links are checked by `fixRecursive`. -/
def maxLinks : Nat := 4096

/-- Does a `filter` value hold `url(#fid)`? -/
def namesFilter (v : ByteArray) (fid : String) : Bool := Id.run do
  let mut i := 0
  for _ in [0:v.size] do
    if i ≥ v.size then break
    let k := findByte v i 40
    if k ≥ v.size then break
    let j := skipWs v (k + 1)
    if k ≥ 3 && eqAscii (v.extract (k - 3) k) "url" && at' v j == 35 then
      let e := skipWhile v (j + 1) (fun c => c != 41 && !isWs c)
      if toStr (v.extract (j + 1) e) == fid then return true
    i := k + 1
  return false

/-- The declarations of a `style` value whose property satisfies `keep`. -/
def filterStyle (v : ByteArray) (keep : String → Bool) : ByteArray :=
  (splitTrim v 59).foldl (fun out decl =>
    let k := findByte decl 0 58
    if k < decl.size && !keep (toStr (lower (trim (decl.extract 0 k))))
    then out else (out ++ decl).push 59) .empty

/-- The effective `filter` of an element: `style` wins over the attribute. -/
def filterOf (attrs : Array Xml.Attr) : Option ByteArray := Id.run do
  let mut out := attr attrs "filter"
  if let some st := attr attrs "style" then
    for decl in splitTrim st 59 do
      let k := findByte decl 0 58
      if k < decl.size && eqAscii (lower (trim (decl.extract 0 k))) "filter" then
        out := some (trim (decl.extract (k + 1) decl.size))
  return out

/-- usvg's `fix_recursive_fe_image`.  The events are returned untouched when
there is no `feImage`. -/
def fixRecursive (events : Array Xml.Event) : Array Xml.Event := Id.run do
  -- (the feImage's parent's id, the linked id)
  let mut links : Array (String × String) := #[]
  let mut ids : Array (Option String) := #[]
  let mut byId : Std.HashMap String Nat := {}
  for i in [0:events.size] do
    match events.getD i default with
    | .open_ name attrs =>
      if name == "feImage" && links.size < maxLinks then
        match ids.back?, Use.hrefId attrs with
        | some (some fid), some tid => links := links.push (fid, tid)
        | _, _ => pure ()
      let id := (attr attrs "id").map toStr
      if let some s := id then byId := byId.insert s i
      ids := ids.push id
    | .close => ids := ids.pop
    | .text _ => pure ()
  if links.isEmpty then return events
  let mut out := events
  for (fid, tid) in links do
    let some k := byId.get? tid | continue
    let .open_ name attrs := out.getD k default | continue
    let some v := filterOf attrs | continue
    if !namesFilter v fid then continue
    let attrs := (attrs.filter (·.name != "filter")).map fun a =>
      if a.name == "style" then { a with value := filterStyle a.value (· != "filter") } else a
    out := out.setIfInBounds k (.open_ name (attrs.push ⟨"filter", "none".toUTF8⟩))
  return out

/-- Properties an ancestor wrapper must not carry: they belong to the ancestor
itself, not to what it passes on (usvg converts the linked element alone). -/
def ownProp (n : String) : Bool :=
  ["id", "transform", "clip-path", "mask", "filter", "opacity", "display", "x", "y",
   "width", "height", "viewBox", "preserveAspectRatio", "href", "xlink:href",
   "mix-blend-mode", "isolation", "transform-origin"].contains n

/-- An ancestor's attributes, reduced to what it passes on by inheritance. -/
def inherited (attrs : Array Xml.Attr) (keep : String → Bool) : Array Xml.Attr :=
  (attrs.filter fun a => keep a.name).map fun a =>
    if a.name == "style" then { a with value := filterStyle a.value (fun n => !ownProp n) } else a

/-- The sub-document that renders the element with id `id` on its own (see
the module comment), or `none` when no element has that id or it is the root.
The last element with the id wins, as in usvg's id map. -/
def subEvents (events : Array Xml.Event) (id : String) : Option (Array Xml.Event) := Id.run do
  let mut stack : Array Nat := #[]
  let mut found : Option (Nat × Array Nat) := none
  for i in [0:events.size] do
    match events.getD i default with
    | .open_ _ attrs =>
      if (attr attrs "id").map toStr == some id then found := some (i, stack)
      stack := stack.push i
    | .close => stack := stack.pop
    | .text _ => pure ()
  let some (k, anc) := found | return none
  let some r := anc[0]? | return none
  -- the close matching an open at `i`
  let endOf := fun (i : Nat) => Id.run do
    let mut d : Nat := 0
    for j in [i + 1 : events.size] do
      match events.getD j default with
      | .open_ .. => d := d + 1
      | .close => if d == 0 then return j else d := d - 1
      | .text _ => pure ()
    return events.size
  let rEnd := endOf r
  let kEnd := endOf k
  let .open_ rname rattrs := events.getD r default | return none
  let rootKeep := fun (n : String) =>
    n == "width" || n == "height" || n == "viewBox" || n == "preserveAspectRatio" || !ownProp n
  let mut out : Array Xml.Event := #[.open_ rname (inherited rattrs rootKeep), .open_ "defs" #[]]
  out := out ++ events.extract (r + 1) rEnd
  out := out.push .close
  for a in anc.extract 1 anc.size do
    match events.getD a default with
    | .open_ _ attrs => out := out.push (.open_ "g" (inherited attrs (fun n => !ownProp n)))
    | _ => pure ()
  -- the copy: definitions lose their ids so they never shadow the originals
  for j in [k : Nat.min (kEnd + 1) events.size] do
    match events.getD j default with
    | .open_ n attrs =>
      out := out.push (.open_ n (if Use.isDefLike n then attrs.filter (·.name != "id") else attrs))
    | ev => out := out.push ev
  for _ in [1:anc.size] do
    out := out.push .close
  return some (out.push .close)

end FeImage
end LeanSvg
