import LeanSvg.Xml
import LeanSvg.Css
import LeanSvg.Shader
import LeanSvg.Pattern
import LeanSvg.Canvas
import LeanSvg.Text
import LeanSvg.Viewport
import LeanSvg.Use
import LeanSvg.ForeignObject
import LeanSvg.Oklab
import LeanSvg.Filter
import LeanSvg.Image
import LeanSvg.SvgImage
import LeanSvg.Units
import LeanSvg.BasicShape
import LeanSvg.Warn
import LeanSvg.FontFace
import LeanSvg.StixNonUnicode
import Std.Data.HashMap

/-!
# SVG interpretation

Turns the XML event stream into a flat list of shapes with fully resolved
style and transform.  Supported: `svg g path rect circle ellipse line polygon
polyline`, solid paints, opacity, fill rule, stroke width/cap/join/miter,
`transform`, and the `style` attribute.  Everything else is skipped along with
its subtree.  References are followed only within the input: `url(#id)` and
same-document `use` `href="#id"` (T47, `LeanSvg/Use.lean`); nothing resolves
an external reference, so the renderer cannot be made to look outside the
input bytes.
-/

namespace LeanSvg
namespace Svg

open Bytes

inductive Paint where
  | none
  | solid (c : Rgba)
  /-- A `url(#id)` that named a usable gradient: the index of its entry in the
  style's `Grad.Defs` table (T18), plus the `<fallback>` from `url(#id)
  <fallback>` (T64): usvg's `has_bbox` check (SVG 7.11) can still reject an
  `objectBoundingBox` paint server at render time, once the shape's own
  geometry is known, and falls back to this instead of painting nothing. -/
  | gradient (idx : Nat) (fallback : Paint)
  /-- A `url(#id)` that named a usable `<pattern>`: the index of its entry in
  the style's `Pat.Defs` table.  Unlike a gradient, there is no further
  invalidity to defer to draw time except a zero-area referencing shape under
  `objectBoundingBox`, which usvg does not fall back for either — it paints
  nothing, exactly as `Grad.build`'s `.skip` already does — so this carries no
  fallback of its own; `resolvePaint` has already chosen between `.pattern`
  and the `url()` fallback the same way it does for a gradient. -/
  | pattern (idx : Nat)
deriving Repr, Inhabited

/-- `1.0` on the opacity grid: opacities are `Nat` numerators over 10^18.

resvg keeps an opacity as an `f32` in `[0, 1]` and only turns it into a `u8`
at the very end, with `Opacity::to_u8` = `round (x * 255)`.  Any coarser grid
of ours would have to round twice, and the two grids do not line up: on the
1/256 grid `0.7` becomes 179/256, and `round (179/256 * 255) = 178`, where
resvg says 179.

A decimal denominator fixes that.  The half-way points of the 255ths grid are
the odd multiples of 1/510, and the only ones in `[0, 1]` are `0.1`, `0.3`,
`0.5`, `0.7` and `0.9` (a tie needs `51 ∣ 2j+1`, and `51 * 11 / 510 > 1`).
They are one-digit decimals, so a power-of-ten grid represents every tie
*exactly* and the tie is then decided by our own rule rather than by rounding
noise.  10^18 also makes every decimal literal `parseDecimal` can return
(18 significant digits) exact in its own right. -/
def opacityOne : Nat := 1000000000000000000

structure Style where
  fill : Paint := .solid ⟨0, 0, 0, 255⟩
  fillOpacity : Nat := opacityOne
  evenOdd : Bool := false
  stroke : Paint := .none
  strokeOpacity : Nat := opacityOne
  strokeWidth : Fx := 256
  cap : Cap := .butt
  join : Join := .miter
  miterLimit : Fx := 1024
  /-- `stroke-dasharray`, raw: `Geom.dashPattern` normalises it.  Empty = solid. -/
  dashes : Array Fx := #[]
  dashOffset : Fx := 0
  /-- Group opacity folded into this element from ancestors that were rendered
  *without* a compositing layer (plain groups past `maxLayerDepth`), times
  nothing else: an element's own `opacity` is `ownOpacity` until `interpret`
  decides whether it becomes a layer or is folded in as well. -/
  opacity : Nat := opacityOne
  /-- `paint-order`, collapsed to the one bit that matters here: whether
  `stroke` is painted before `fill` (we have no markers, so their position in
  the property's value never changes what gets drawn).  Inherited, like every
  other paint property. -/
  strokeFirst : Bool := false
  /-- T95: where `markers` sits in `paint-order`'s resolved order (0, 1 or
  2; default 2, after fill and stroke).  `Marker.expand` reads it. -/
  markersPos : Nat := 2
  /-- This element's own `opacity` property; not inherited (reset to 1 for
  every element before its attributes apply). -/
  ownOpacity : Nat := opacityOne
  /-- `mix-blend-mode`; not inherited.  Only honoured from CSS (`style=""` or a
  `<style>` sheet), never as a presentation attribute — usvg drops the
  attribute form (`svgtree/parse.rs`: "allowed only inside a `style`"). -/
  blend : BlendMode := .normal
  /-- `isolation: isolate`; not inherited, CSS only, like `blend`. -/
  isolate : Bool := false
  visible : Bool := true
  /-- `shape-rendering: crispEdges`/`optimizeSpeed` (`usvg`'s
  `ShapeRendering::use_shape_antialiasing() == false`): the shape is filled and
  stroked with `Raster.rasterizeCrisp` instead of the antialiased default, and
  a thin stroke skips the hairline shortcut (`painter.rs`'s
  `treat_as_hairline` also refuses when `!paint.anti_alias`). Inherited;
  `auto`/`geometricPrecision` (the default) turn antialiasing back on. -/
  crisp : Bool := false
  /-- `text-rendering: optimizeSpeed`: glyphs and decorations of a `<text>`
  are drawn crisp (usvg's `text/flatten.rs::resolve_rendering_mode`). Read
  from the `<text>` element's style only; inherited. -/
  textCrisp : Bool := false
  /-- The CSS `color` property: inherited, defaults to black, and is what
  `fill`/`stroke: currentColor` resolve to (`interpret`'s `applyEffective`
  applies `color` before any other property so the resolution sees the
  element's own value). -/
  color : Rgba := ⟨0, 0, 0, 255⟩
  /-- Whether `pctRefW`/`pctRefH` have been established yet.  False only for
  the literal `default : Style` that `interpret` passes as the parent of the
  root `<svg>` element itself; every other `Style` inherits `true` and the
  values below, which only a nested `<svg>` rescopes (T48). -/
  pctRefSet : Bool := false
  /-- The rect `transform-origin` percentages resolve against: usvg's
  per-element `state.view_box`: the root's `viewBox`, or else its own
  resolved size, set in `applyEffective` from the root's own attrs; a nested
  `<svg>` replaces it for its subtree (T48).  Shape percentages (`shapeCmds`)
  resolve against it too. -/
  pctRefW : Fx := 0
  pctRefH : Fx := 0
  /-- `transform-origin`'s resolved offset, *not* inherited: every element
  gets its own, reset to `(0, 0)` (a no-op) unless this element itself has the
  property.  `applyProp`'s `"transform"` case wraps its matrix with
  `translate(originDx, originDy) · _ · translate(-originDx, -originDy)`. -/
  originDx : Fx := 0
  originDy : Fx := 0
  /-- The document's gradient definitions (T18).  Not a style property at all:
  it is one immutable table, built by `interpret`'s pre-pass and put on the
  root element's `Style` so that it reaches `resolvePaint` — which is where a
  `url(#id)` becomes a `Paint.gradient` — without changing `applyProp`'s
  signature.  Every other `Style` inherits the same table by copying. -/
  defs : Grad.Defs := {}
  /-- The document's `<pattern>` geometry table, built the same way and at the
  same time as `defs`: fully from the pre-pass's raw attributes and `href`
  chains, which is why it can be complete before the main walk even starts
  (unlike its *content*, `Doc.patternContent`, which the walk itself
  collects). -/
  patterns : Pat.Defs := {}
  ctm : Mat := Mat.identity
  -- The text properties (T36).  All inherited, all unused by every element
  -- except `text`/`tspan`, so nothing outside `Svg.textShapes` reads them.
  /-- `font-size`, already resolved: `em`/`ex`/`%` are relative to the
  inherited value (usvg's `resolve_font_size`), and the default is usvg's
  `Options::font_size`. -/
  fontSize : Fx := Fx.ofNat 12
  /-- The root `<svg>` element's own resolved `font-size` (T52-shapes): what
  `rem` resolves against (SVG2/CSS Values, always the root regardless of any
  element's local `font-size`), set once in `interpret`'s `applyEffective`
  when it processes the root element itself and inherited unchanged by every
  descendant after that, unlike `fontSize`.  T92: it also carries the output
  canvas size the viewport units (`vw`, ...) resolve against (`Units`). -/
  rootFontSize : Units.RootLen := {}
  /-- Numeric CSS `font-weight` after `bolder`/`lighter` stepping. -/
  fontWeight : Nat := 400
  /-- `font-style: italic` or `oblique`. -/
  fontItalic : Bool := false
  /-- T97: `font-variant: small-caps` (usvg: the inherited value is exactly
  `small-caps`), drawn with the font's `smcp` feature. -/
  fontSmallCaps : Bool := false
  /-- T118: `font-stretch` as an OS/2 width class (1–9, 5 = normal). -/
  fontStretch : Nat := 5
  letterSpacing : Fx := 0
  wordSpacing : Fx := 0
  /-- T90: CSS Fonts 4 `font-size-adjust` (number form, `ex-height`), as an
  `Fx` aspect value; inherited.  usvg parses it and never reads it. -/
  fontSizeAdjust : Option Fx := none
  /-- T90: set on a `path` shape only (never inherited through the cascade):
  indices of its commands that end inside an elliptical arc. -/
  arcJoins : Array Nat := #[]
  /-- `font-kerning: none`, or SVG 1.1 `kerning="0"`, turns pair kerning off. -/
  textKerning : Bool := true
  textAnchor : Text.Anchor := .start
  /-- `writing-mode` (T56): usvg resolves this once per `<text>` element from
  its own attribute or the nearest ancestor that has one (`lr-tb`/`lr`/
  `rl-tb`/`rl`/`horizontal-tb`/anything unrecognised is `LeftToRight`; only
  `tb`/`tb-rl`/`vertical-rl`/`vertical-lr` are `TopToBottom` — usvg 0.48.1
  does not distinguish `vertical-lr` from `vertical-rl`, or `tb` from
  `tb-rl`, so neither do we).  Inherited like the other text properties, but
  `Svg.textShapes` reads it only once, off the `<text>` element's own
  resolved `Style`, so a `writing-mode` on a `tspan` has no effect (matches
  usvg: it searches the `<text>` node's ancestors, which does not include its
  own descendants). -/
  writingMode : Bool := false
  /-- `dominant-baseline`/`alignment-baseline` (T54): ordinary CSS-inherited
  properties, unlike `baseline-shift` (`LeanSvg/Baseline.lean`, `textShapes`'s
  `bsStack`), which is not carried on `Style` at all. -/
  dominantBaseline : Text.AlignmentBaseline := .auto
  alignmentBaseline : Text.AlignmentBaseline := .auto
  /-- Whether `font-family` resolves to the one family this renderer embeds
  ("Noto Sans"): see `resolveFontFamily`.  Defaults to `false`, matching
  usvg's own default `font-family` ("Times New Roman"), which is not in the
  embedded set either. -/
  fontAvailable : Bool := false
  /-- Which embedded font `font-family` resolved to, as a `FontSet` index
  (meaningful only when `fontAvailable`; 0 = "Noto Sans"). -/
  fontFamily : Nat := 0
  /-- T98: the `font-family` value as written (usvg's default family when
  none is set), for the warning a run reports when it is not `fontAvailable`
  and falls through to Noto Sans. -/
  fontFamilyRaw : ByteArray := "Times New Roman".toUTF8
  /-- T105: the document's own `@font-face` faces (`FontFace.scan`), set on
  the root and inherited unchanged.  A `fontFamily` of `FontSet.count + k`
  names the family of face `k`. -/
  docFaces : Array FontFace.Face := #[]
  /-- `text-decoration`, *not* inherited: `applyEffective` resets all three to
  `false` for every element, and only that element's own raw attribute value
  (from any cascade layer) can set them back.  usvg's decoration search
  (`Svg.textShapes`) walks from a run's own element up through its ancestors
  and draws a line for every kind *any* of them sets this way, so an
  ancestor's own declaration must stay visible at its own level rather than
  spreading (or failing to spread) like an ordinary inherited property. -/
  ownUnderline : Bool := false
  ownOverline : Bool := false
  ownLineThrough : Bool := false
  /-- `textLength`/`lengthAdjust`, *not* inherited for the same reason: a
  `tspan`'s own `textLength` stretches only its own characters
  (`textLength/on-a-single-tspan.svg`), so a plain reset-per-element `Style`
  field is exactly what `Text.spanPropsOf` needs to hand `Text.layout` one
  value per run. -/
  ownTextLength : Option Fx := none
  ownLengthAdjustGlyphs : Bool := false
  /-- `direction: rtl` (T93), inherited. -/
  textRtl : Bool := false
  /-- `unicode-bidi: bidi-override`/`isolate-override` (T93): per element. -/
  ownBidiOverride : Bool := false
  /-- `xml:space="preserve"`. -/
  spacePreserve : Bool := false
  /-- T101: the nearest `xml:lang`/`lang` (`langOf`), inherited. -/
  lang : Nat := 0
  /-- `clip-rule`: inherited; the fill rule of a `clipPath` child (T20). -/
  clipEvenOdd : Bool := false
  /-- This element's own `clip-path` reference (the id inside `url(#id)`), *not*
  inherited: `applyEffective` resets it for every element.  `none` for an
  absent `clip-path`, an explicit `none`, an unparseable value (a CSS basic
  shape, say), all of which usvg treats alike: no clipping. -/
  clipRef : Option String := none
  /-- T92: this element's own `clip-path` when it is not `url(#id)` or
  `none`, raw: a candidate CSS basic shape (`BasicShape.parse`, run by
  `addClipUse` once the element's font sizes are final).  Not inherited. -/
  clipShapeRaw : Option ByteArray := none
  /-- The clip uses in force on this element, outermost first, as indices into
  `Doc.uses`.  Inherited; an element with its own `clip-path` appends one. -/
  clips : Array Nat := #[]
  /-- This element's own `transform` alone (wrapped with its origin), not
  inherited: what `ctm` gained on this element.  `Box.transformed` by it takes
  a child's object bounding box into the parent's user space (T20). -/
  ownMat : Mat := Mat.identity
  /-- What `context-fill`/`context-stroke` resolve to (T47): the fill and
  stroke of the nearest enclosing `use`, inherited; `none` outside any `use`,
  as in usvg without a context element.  Only the paint is kept, not a
  colour's alpha (usvg's `ContextElement` carries `Fill::paint` alone). -/
  ctxFill : Paint := .none
  ctxStroke : Paint := .none
  /-- T85: the `Doc.ctxUses` slot of the nearest enclosing `use`, when that
  `use`'s own fill or stroke is a gradient or pattern; inherited. -/
  ctxSlot : Option Nat := none
  /-- T85: set when `fill`/`stroke` came from `context-fill`/`context-stroke`
  (to `ctxSlot`), reset by any other paint.  usvg then resolves the paint
  server against that `use`'s transform and content bbox, not the shape's. -/
  fillCtx : Option Nat := none
  strokeCtx : Option Nat := none
  /-- T95: inside `<marker>` content with no `use` in between, where
  `context-*` means the referencing shape's paint (usvg's
  `ContextElement::PathNode`), known only once `Marker.expand` runs. -/
  markerCtx : Bool := false
  /-- T95: under `markerCtx`, `some stroke?` when `fill` (resp. `stroke`) was
  `context-fill`/`context-stroke`; `Marker.expand` substitutes the paint. -/
  fillCtxKind : Option Bool := none
  strokeCtxKind : Option Bool := none
  /-- This element's own `mask` reference (T49), not inherited, like `clipRef`. -/
  maskRef : Option String := none
  /-- `mask-type: alpha` on this element (T49), not inherited; only a `mask`
  element reads it. -/
  maskAlpha : Bool := false
  /-- This element's own `filter` value, raw (T51); not inherited. -/
  filterRaw : Option ByteArray := none
  /-- `marker-start`/`marker-mid`/`marker-end` (T52): the raw `url(#id)`
  target, inherited like any other paint property.  Resolved against
  `Doc.markers` by `Marker.expand`, after `interpret` has finished (markers
  may be defined anywhere, including after the element that uses them). -/
  markerStartId : Option String := none
  markerMidId : Option String := none
  markerEndId : Option String := none
  /-- `image-rendering` (T63), inherited; an unparseable value is the default,
  as usvg's `find_attribute` + `unwrap_or` makes it. -/
  imageRendering : Image.Quality := .bicubic
deriving Repr, Inhabited

structure Shape where
  cmds : Array PathCmd
  style : Style
  /-- Whether this shape's element is one usvg instantiates markers on --
  `path`, `line`, `polyline`, `polygon` -- as opposed to `rect`/`circle`/
  `ellipse`/text runs, which never draw a marker even when `marker-start`
  etc. are set (T52 reads this, not the element name, since a `Shape` no
  longer remembers it). -/
  markerable : Bool := false
  /-- T63: an `<image>`.  `cmds` is then the rectangle it paints through and
  this is the paint, in place of `style.fill`. -/
  image : Option Image.Placed := none
  /-- T84: an `<image>` of an SVG document, an index into `Doc.svgImages`.
  `cmds` is then its viewport and the style paints nothing itself. -/
  svgImage : Option Nat := none
deriving Inhabited

/-! ## `clipPath` (T20), and the shape of a defs table

`interpret` runs exactly one bounded pre-pass over the events (`defsScan`)
before its main walk.  That pass collects every kind of referenceable
definition the renderer knows about: T18's gradient elements with their
`<stop>` children, and T20's `clipPath` *slots* — one per `clipPath` element
with a usable `id`, in document order, remembering the event index it was
opened at.  A definition may sit anywhere (under `<defs>`, a `<g>`, or the
root), so the pass is flat, like usvg's id map.

The two kinds are collected together but resolved differently, and the split
is the point:

* A gradient is fully described by its own attributes and its stops, so the
  pre-pass finishes it: `Grad.Defs.build` resolves `href` chains and defaults
  straight away and the table is handed to the root `Style`, which every
  descendant inherits by copying.
* A `clipPath` is *not*: its `transform`, its `clip-path` and its children's
  `clip-rule` all come out of the CSS cascade, which only the main walk runs.
  So the pre-pass only reserves the slot, and the main walk fills it in when
  it reaches that event index (`ClipEntry.filled`).  A slot the walk never
  reaches — inside `display:none`, or in a `<switch>` branch that lost —
  stays unfilled and is invisible to the lookup, so a reference to it is
  simply ignored.

Lookup for the second kind is therefore: *slot by event index while walking,
id after walking*.  `interpret` builds the id map from the filled entries
only (a duplicated id resolves to the last such element, as in usvg's `links`
map) and rewrites every recorded reference — `Doc.uses` for the elements that
carry `clip-path`, and each entry's own `selfClip` — in one pass at the end,
which is what makes forward references work.

T21's `mask` and T19's `use` are the same shape and should reuse it: add an
`Array String × Nat` of slots to `DefsScan`, an entry array to `Doc` beside
`clips`, a `Style` field for the reference like `clipRef`, and one resolve
loop at the end of `interpret`.  Neither needs a second pass over the events,
and neither needs `Doc`'s type to grow a new lookup mechanism.

An element that references a clip through `clip-path="url(#id)"` records a
*use* in `Doc.uses` and carries its index in `Style.clips`;
`LeanSvg/Clip.lean` turns an entry into a device-space mask at render
time. -/

/-- One child of a `clipPath`: a shape whose fill (with `clip-rule`) is unioned
into the clip region.  Its `ctm` is relative to the `clipPath`'s own user space
*after* the element's `transform` and the `clipPathUnits` scaling (both applied
at render time), i.e. it is the product of the child's own transforms only. -/
structure ClipChild where
  cmds : Array PathCmd
  evenOdd : Bool
  ctm : Mat
  /-- `visibility`: a hidden child contributes nothing but still makes the
  `clipPath` valid (usvg converts it and the renderer skips it). -/
  visible : Bool
  /-- The child's own `clip-path` use, if any (an index into `Doc.uses`, whose
  `ctm` is then relative to the same space as this `ctm`). -/
  clips : Array Nat
  /-- `cmds` are on the 16.16 grid rather than `Fx`'s 1/256 (`shapeCmds16`),
  which is what an `objectBoundingBox` fraction needs; `Clip.build` divides
  the extra factor of 256 back out. -/
  fine : Bool := false
deriving Inhabited

structure ClipEntry where
  id : String
  /-- The `clipPath` element's own `transform`. -/
  transform : Mat
  /-- usvg drops the whole clip when that transform has a zero scale on either
  axis (`Transform::is_valid`), and every element using it with it. -/
  transformValid : Bool
  /-- `clipPathUnits="objectBoundingBox"`. -/
  objectBBox : Bool
  /-- The `clip-path` on the `clipPath` element itself: raw id, and its entry
  index once `interpret` has resolved it (`none` when absent or unresolvable,
  which usvg treats as no clip). -/
  selfClipId : Option String
  selfClip : Option Nat
  children : Array ClipChild
  /-- Whether the main walk reached this slot and filled the fields above in.
  An unfilled slot never enters the id map, so references to it are ignored. -/
  filled : Bool := false
deriving Inhabited

/-- T85: a `use` whose fill or stroke is a paint server: its CTM (after `x`/`y`)
and the object bounding box of its whole content in that space, filled in when
the `use` closes. -/
structure CtxUse where
  ctm : Mat
  bbox : Option Box
deriving Inhabited

/-- One `clip-path="url(#id)"` on an element: which clip, the referencing
element's `ctm` (relative to the space the referencing `Shape`/`ClipChild`
lives in) and its object bounding box in its own user space, for
`clipPathUnits="objectBoundingBox"`.  `entry` is filled in by id at the end of
`interpret`. -/
structure ClipUse where
  id : String
  entry : Option Nat
  ctm : Mat
  bbox : Option Box
  /-- T92: a CSS basic shape instead of an id, with the `view-box` reference
  box; `interpret` builds its entry at the end, from `bbox`/`sbox`. -/
  shape : Option (BasicShape.Spec × Box) := none
  /-- T92: the stroke bounding box, filled in with `bbox` when a `stroke-box`
  shape needs it. -/
  sbox : Option Box := none
deriving Inhabited

/-- The largest number of `clipPath` elements collected; later ones are skipped
(and references to them are unresolvable, i.e. ignored). -/
def maxClipPaths : Nat := 4096

/-- Ids longer than this are not collected. -/
def maxIdBytes : Nat := 256

structure RootInfo where
  /-- The raw parsed number and whether it was a percentage (`resolveRootSize`
  resolves it against the `viewBox` or the 100×100 default). -/
  width : Option (Fx × Bool) := none
  height : Option (Fx × Bool) := none
  viewBox : Option (Fx × Fx × Fx × Fx) := none
  /-- `preserveAspectRatio` (T48). -/
  aspect : Viewport.AspectRatio := {}
deriving Inhabited

/-- What a container (or a lone shape) that becomes a compositing *layer*
carries: its children render into a fresh transparent canvas which is then
composited onto the parent with these (resvg `render.rs::render_group`).

`clips` (T20) and `mask` (T49) are `Group::should_isolate`'s other reasons for a
layer; both multiply the finished layer *before* this composite, in
`Render.renderNodes`' `groupEnd`.  `filter` is not implemented. -/
structure GroupInfo where
  /-- Group opacity on the `opacityOne` grid. -/
  opacity : Nat := opacityOne
  blend : BlendMode := .normal
  isolate : Bool := false
  /-- T20 on top of T22: the `clip-path` uses to multiply into the finished
  layer, before the opacity and blend composite, which is where resvg puts
  them (`render.rs`: `clip::apply` on the sub-pixmap, then `draw_pixmap`).
  Empty unless this group carries a `clip-path` of its own; when it does, the
  use is *not* also on `Style.clips`, so the clip is applied once to the
  composite instead of once per descendant shape. -/
  clips : Array Nat := #[]
  /-- T49: this group's `mask` use (an index into `Doc.maskUses`), applied to the
  finished layer after the clip and before the composite (`render_group`). -/
  mask : Option Nat := none
  /-- T51: the element's resolved `filter` list, in the user space `filterCtm`
  maps to the root.  Filled in when the element closes (the object bounding
  box is needed); non-empty makes the layer a filter layer (`Render`). -/
  filters : Array Filter.Resolved := #[]
  filterCtm : Mat := Mat.identity
  /-- T51: the layer was opened only for a `filter` that resolved to nothing
  (unsupported, or a parse error): no layer at all, as before this task. -/
  passthrough : Bool := false
  /-- T51: usvg drops the element (an invalid filter reference or region). -/
  dropped : Bool := false
deriving Inhabited

/-- The document as a flat, ordered instruction stream.

Before T22 this was just `Array Shape`; a group's `opacity` was multiplied into
its children's paint, which is wrong as soon as the children overlap.  Now a
container that needs isolation brackets its subtree with `groupBegin`/`groupEnd`
and `Render` gives it a real layer.  Groups that need none emit nothing at all,
so a document without opacity, `mix-blend-mode` or `isolation` produces exactly
the shape sequence it produced before, in the same order. -/
inductive Node where
  | shape (s : Shape)
  | groupBegin (g : GroupInfo)
  | groupEnd
deriving Inhabited

/-- One `mask` element (T49): its attributes, and its children as their own
node stream, in the user space of the element that references it (the `mask`
element's own `transform` has no effect, and its ancestors' are dropped).
`x`/`y`/`w`/`h` are raw (`parseCoord16`), resolved per use in `Mask.region`. -/
structure MaskEntry where
  id : String
  userUnits : Bool := false
  contentBBox : Bool := false
  alpha : Bool := false
  /-- T90: `color-interpolation="linearRGB"` on the `<mask>` itself. -/
  linear : Bool := false
  x : Option Grad.LenPct := none
  y : Option Grad.LenPct := none
  w : Option Grad.LenPct := none
  h : Option Grad.LenPct := none
  /-- The viewport a `userSpaceOnUse` percentage resolves against, in `Fx`. -/
  pctW : Fx := 0
  pctH : Fx := 0
  selfMaskId : Option String := none
  selfMask : Option Nat := none
  nodes : Array Node := #[]
  filled : Bool := false
deriving Inhabited

/-- One `mask="url(#id)"` on a rendered element; shaped like `ClipUse`. -/
structure MaskUse where
  id : String
  entry : Option Nat
  ctm : Mat
  bbox : Option Box
deriving Inhabited
/-! ## `marker` (T52)

A `<marker>` element is a template, never drawn on its own: `interpret`
collects one `MarkerEntry` per element with a usable `id`, wherever it
appears (mirroring `ClipEntry`), and `LeanSvg/Marker.lean`'s `expand` turns
each `marker-start`/`marker-mid`/`marker-end` reference on a `path`/`line`/
`polyline`/`polygon` into copies of the marker's `content`, one per vertex,
after `interpret` has finished. -/

/-- `orient`: `auto`/`auto-start-reverse` compute the angle from the path's
own geometry at each vertex (`Marker.calcVertexAngle`); anything else is a
fixed angle in degrees, `0` if the attribute is absent or unparseable
(usvg's `convert_orientation`). -/
inductive MarkerOrient where
  | auto
  | autoStartReverse
  | fixed (deg : Fx)
deriving Inhabited

structure MarkerEntry where
  id : String
  refX : Fx := 0
  refY : Fx := 0
  /-- `markerWidth`/`markerHeight`; default `3` (usvg `Length::new_number(3.0)`). -/
  width : Fx := Fx.ofNat 3
  height : Fx := Fx.ofNat 3
  viewBox : Option (Fx × Fx × Fx × Fx) := none
  /-- `preserveAspectRatio`'s `align`, as the three primitives
  `Marker.viewBoxTransform` takes: `alignNone` for `"none"` (independent axis
  scaling), else `alignX`/`alignY` ∈ {0,1,2} for min/mid/max.  Default
  `xMidYMid`. -/
  alignNone : Bool := false
  alignX : Nat := 1
  alignY : Nat := 1
  slice : Bool := false
  orient : MarkerOrient := .fixed 0
  /-- `markerUnits`: `true` for `userSpaceOnUse`, `false` (default) for
  `strokeWidth` -- any value other than exactly `"userSpaceOnUse"`, including
  an absent or invalid one, is the default (`with-invalid-markerUnits.svg`). -/
  unitsUser : Bool := false
  /-- `overflow`: hidden by default and for `"hidden"`/`"scroll"`; anything
  else (`"visible"`, `"auto"`, ...) turns clipping off. -/
  clip : Bool := true
  /-- The synthetic `clipPath` entry (index into `Doc.clips`) built once, at
  parse time, for `clip`'s rectangle -- the `viewBox` rect if there is one,
  else `(0, 0, width, height)` -- so `Marker.expand` only has to add one
  `ClipUse` per instance, not rebuild the geometry.  `none` when `clip` is
  false or the marker is `!valid`. -/
  clipEntryIdx : Option Nat := none
  /-- `NonZeroRect::from_xywh` on `(refX, refY, width, height)`: `false` (and
  the whole marker unresolvable-but-referenceable, like an empty one) when
  `width ≤ 0 ∨ height ≤ 0` (`zero-sized.svg`, `marker-with-a-negative-
  size.svg`). -/
  valid : Bool := false
  /-- This marker's children, in its own local space (root ctm = identity),
  styled by its own ancestors -- never the referencing element's -- exactly
  as `interpret`'s ordinary cascade already gives an element wherever it
  sits.  Filled in when the `<marker>` element closes. -/
  content : Array Node := #[]
  /-- Whether the main walk actually reached this element (as opposed to a
  slot under `display:none` or a losing `switch` branch, which stays
  unresolvable, like `ClipEntry.filled`). -/
  filled : Bool := false
deriving Inhabited

/-- The largest number of `marker` elements collected; later ones are
unreferenceable, exactly as `maxClipPaths` bounds `clipPath`. -/
def maxMarkers : Nat := 4096

structure Doc where
  root : RootInfo
  nodes : Array Node
  /-- The `clipPath` table and the `clip-path` uses (T20). -/
  clips : Array ClipEntry := #[]
  uses : Array ClipUse := #[]
  /-- The `mask` table and the `mask` uses (T49). -/
  masks : Array MaskEntry := #[]
  maskUses : Array MaskUse := #[]
  /-- The `marker` table (T52); `Marker.expand` resolves references against
  it and consumes it after `Render.render` no longer needs anything but the
  expanded `nodes`. -/
  markers : Array MarkerEntry := #[]
  /-- T67: the input events after usvg's `fix_recursive_fe_image`, before `use`
  expansion: what an `feImage` link's sub-document is cut from. -/
  events : Array Xml.Event := #[]
  /-- The `<pattern>` geometry table (`Style.patterns` is the same value,
  reachable from every element for `resolvePaint`) and, parallel to its raw
  index rather than to `patterns.defs`, each pattern's own collected content —
  `PatternRender.build` reads `patternContent.getD entry.contentSlot`. -/
  patterns : Pat.Defs := {}
  patternContent : Array (Array Node) := #[]
  /-- T84: the SVG images' sub-documents, rendered by `Render.renderNodes`. -/
  svgImages : Array SvgImage.Entry := #[]
  /-- T85: the `context-fill`/`context-stroke` paint-server slots (`CtxUse`). -/
  ctxUses : Array CtxUse := #[]
  /-- T98: what the render drew differently from what was asked (`Warn`). -/
  warnings : Array String := #[]
deriving Inhabited

/-- How deep compositing layers may nest.  A document may nest groups far
deeper (the XML parser's own cap is `Xml.maxDepth` = 2048) and every level would
cost one canvas, so past this bound a group that asks for a layer is rendered
as a plain group instead: its opacity is folded into its children's paint, as
it was before T22, and its blend mode is ignored.  Ten is more than any real
document needs — the deepest nesting in the whole resvg test suite is eight,
and none of those levels is a layer. -/
def maxLayerDepth : Nat := 10

/-! ## Colours -/

/-- The 148 CSS Color Level 4 named colours (extended colour keywords plus
`rebeccapurple`), lower-cased.  `transparent` is not in this list; it stays a
special case in `parsePaint` since it is not itself an RGB colour name. -/
def namedColors : List (String × Nat) :=
  [("aliceblue", 0xf0f8ff), ("antiquewhite", 0xfaebd7), ("aqua", 0x00ffff),
   ("aquamarine", 0x7fffd4), ("azure", 0xf0ffff), ("beige", 0xf5f5dc), ("bisque", 0xffe4c4),
   ("black", 0x000000), ("blanchedalmond", 0xffebcd), ("blue", 0x0000ff),
   ("blueviolet", 0x8a2be2), ("brown", 0xa52a2a), ("burlywood", 0xdeb887),
   ("cadetblue", 0x5f9ea0), ("chartreuse", 0x7fff00), ("chocolate", 0xd2691e),
   ("coral", 0xff7f50), ("cornflowerblue", 0x6495ed), ("cornsilk", 0xfff8dc),
   ("crimson", 0xdc143c), ("cyan", 0x00ffff), ("darkblue", 0x00008b), ("darkcyan", 0x008b8b),
   ("darkgoldenrod", 0xb8860b), ("darkgray", 0xa9a9a9), ("darkgreen", 0x006400),
   ("darkgrey", 0xa9a9a9), ("darkkhaki", 0xbdb76b), ("darkmagenta", 0x8b008b),
   ("darkolivegreen", 0x556b2f), ("darkorange", 0xff8c00), ("darkorchid", 0x9932cc),
   ("darkred", 0x8b0000), ("darksalmon", 0xe9967a), ("darkseagreen", 0x8fbc8f),
   ("darkslateblue", 0x483d8b), ("darkslategray", 0x2f4f4f), ("darkslategrey", 0x2f4f4f),
   ("darkturquoise", 0x00ced1), ("darkviolet", 0x9400d3), ("deeppink", 0xff1493),
   ("deepskyblue", 0x00bfff), ("dimgray", 0x696969), ("dimgrey", 0x696969),
   ("dodgerblue", 0x1e90ff), ("firebrick", 0xb22222), ("floralwhite", 0xfffaf0),
   ("forestgreen", 0x228b22), ("fuchsia", 0xff00ff), ("gainsboro", 0xdcdcdc),
   ("ghostwhite", 0xf8f8ff), ("gold", 0xffd700), ("goldenrod", 0xdaa520), ("gray", 0x808080),
   ("green", 0x008000), ("greenyellow", 0xadff2f), ("grey", 0x808080), ("honeydew", 0xf0fff0),
   ("hotpink", 0xff69b4), ("indianred", 0xcd5c5c), ("indigo", 0x4b0082), ("ivory", 0xfffff0),
   ("khaki", 0xf0e68c), ("lavender", 0xe6e6fa), ("lavenderblush", 0xfff0f5),
   ("lawngreen", 0x7cfc00), ("lemonchiffon", 0xfffacd), ("lightblue", 0xadd8e6),
   ("lightcoral", 0xf08080), ("lightcyan", 0xe0ffff), ("lightgoldenrodyellow", 0xfafad2),
   ("lightgray", 0xd3d3d3), ("lightgreen", 0x90ee90), ("lightgrey", 0xd3d3d3),
   ("lightpink", 0xffb6c1), ("lightsalmon", 0xffa07a), ("lightseagreen", 0x20b2aa),
   ("lightskyblue", 0x87cefa), ("lightslategray", 0x778899), ("lightslategrey", 0x778899),
   ("lightsteelblue", 0xb0c4de), ("lightyellow", 0xffffe0), ("lime", 0x00ff00),
   ("limegreen", 0x32cd32), ("linen", 0xfaf0e6), ("magenta", 0xff00ff), ("maroon", 0x800000),
   ("mediumaquamarine", 0x66cdaa), ("mediumblue", 0x0000cd), ("mediumorchid", 0xba55d3),
   ("mediumpurple", 0x9370db), ("mediumseagreen", 0x3cb371), ("mediumslateblue", 0x7b68ee),
   ("mediumspringgreen", 0x00fa9a), ("mediumturquoise", 0x48d1cc),
   ("mediumvioletred", 0xc71585), ("midnightblue", 0x191970), ("mintcream", 0xf5fffa),
   ("mistyrose", 0xffe4e1), ("moccasin", 0xffe4b5), ("navajowhite", 0xffdead),
   ("navy", 0x000080), ("oldlace", 0xfdf5e6), ("olive", 0x808000), ("olivedrab", 0x6b8e23),
   ("orange", 0xffa500), ("orangered", 0xff4500), ("orchid", 0xda70d6),
   ("palegoldenrod", 0xeee8aa), ("palegreen", 0x98fb98), ("paleturquoise", 0xafeeee),
   ("palevioletred", 0xdb7093), ("papayawhip", 0xffefd5), ("peachpuff", 0xffdab9),
   ("peru", 0xcd853f), ("pink", 0xffc0cb), ("plum", 0xdda0dd), ("powderblue", 0xb0e0e6),
   ("purple", 0x800080), ("rebeccapurple", 0x663399), ("red", 0xff0000),
   ("rosybrown", 0xbc8f8f), ("royalblue", 0x4169e1), ("saddlebrown", 0x8b4513),
   ("salmon", 0xfa8072), ("sandybrown", 0xf4a460), ("seagreen", 0x2e8b57),
   ("seashell", 0xfff5ee), ("sienna", 0xa0522d), ("silver", 0xc0c0c0), ("skyblue", 0x87ceeb),
   ("slateblue", 0x6a5acd), ("slategray", 0x708090), ("slategrey", 0x708090),
   ("snow", 0xfffafa), ("springgreen", 0x00ff7f), ("steelblue", 0x4682b4), ("tan", 0xd2b48c),
   ("teal", 0x008080), ("thistle", 0xd8bfd8), ("tomato", 0xff6347), ("turquoise", 0x40e0d0),
   ("violet", 0xee82ee), ("wheat", 0xf5deb3), ("white", 0xffffff), ("whitesmoke", 0xf5f5f5),
   ("yellow", 0xffff00), ("yellowgreen", 0x9acd32)]

def hexVal (c : UInt8) : Option Nat :=
  if isDigit c then some (c.toNat - 48)
  else if 97 ≤ c && c ≤ 102 then some (c.toNat - 87)
  else if 65 ≤ c && c ≤ 70 then some (c.toNat - 55)
  else none

def parseHexColor (bs : ByteArray) : Option Rgba := Id.run do
  let n := bs.size - 1
  if n != 3 && n != 4 && n != 6 && n != 8 then return none
  let mut ds : Array Nat := #[]
  for k in [1:bs.size] do
    match hexVal (at' bs k) with
    | some d => ds := ds.push d
    | none => return none
  let g := fun i => ds.getD i 0
  if n == 3 || n == 4 then
    let a := if n == 4 then g 3 * 17 else 255
    return some ⟨g 0 * 17, g 1 * 17, g 2 * 17, a⟩
  else
    let a := if n == 8 then g 6 * 16 + g 7 else 255
    return some ⟨g 0 * 16 + g 1, g 2 * 16 + g 3, g 4 * 16 + g 5, a⟩

/-- A colour component under `rgb()`'s "percent" mode (selected when the
*red* component is itself a percentage; see `parseRgbFunc`): every
component is svgtypes' `parse_number_or_percent`, then `* 255` -- a
percentage divides by 100 first, but a *plain* number does not, so
`rgb(50%, 2, 0)` has green = `round (2 * 255)` = 255 (saturated), not the raw
integer `2`.  Confirmed against the compiled resvg 0.48.1 binary.  The whole
token must be consumed (plus the `%` when there is one); a leftover byte
invalidates the component rather than being silently ignored. -/
def compOf (bs : ByteArray) : Option Nat :=
  let t := trim bs
  match parseNumber t 0 with
  | none => none
  | some (v, j) =>
    if at' t j == 37 then
      -- `round (v/100 * 255) = round (v * 255 / 25600)`, halves up: adding
      -- half the denominator (`12800`) before flooring, in one division
      -- rather than the two-step floor-then-floor a naive `(v*255/256)/100`
      -- would do (which silently under-rounds, e.g. `18.4%` -> 46 instead
      -- of the correct 47 -- confirmed against the compiled resvg 0.48.1
      -- binary, and against svgtypes' own `rgb_percentage_float` test case).
      if j + 1 != t.size then none
      else if v ≤ 0 then some 0
      else some (Nat.min 255 ((v.toNat * 255 + 12800) / 25600))
    else if j == t.size then some (Nat.min 255 (Int.toNat (Fx.round (v * 255))))
    else none

/-- A colour component that must be a plain number: like `compOf`, but a
`%` is a hard error rather than a percentage.  svgtypes decides
percent-vs-plain for `rgb()`/`rgba()` from the *red* component alone; if red
is plain, green and blue must be plain too (`self.parse_list_number()`, not
`_or_percent`) -- a percentage there is then invalid, not silently accepted,
confirmed against the compiled resvg 0.48.1 binary (`rgb(0, 50%, 0)` falls
back to black). -/
def compNumOnly (bs : ByteArray) : Option Nat :=
  let t := trim bs
  match parseNumber t 0 with
  | some (v, j) => if j == t.size then some (Nat.min 255 (Fx.round v).toNat) else none
  | none => none

/-- Whether a colour component was written as a percentage: whether `%`
immediately follows its number, the same one-byte peek `rgb()`'s red
component decides the whole call's mode with. -/
def compIsPercent (bs : ByteArray) : Bool :=
  let t := trim bs
  match parseNumber t 0 with
  | some (_, j) => at' t j == 37
  | none => false

/-- Alpha component of `rgb()`/`rgba()`/`hsl()`/`hsla()`: a number in 0..1 or a
percentage, CSS Color 4 `<alpha-value>` (`resvg-test-suite`'s
`painting/fill/rgba-0-127-0-50percent.svg`: the suite PNG, Chromium, Firefox
and Safari all render `rgba(0, 127, 0, 50%)` as translucent green).

svgtypes 0.16.1 (the version resvg 0.48.1 actually embeds; confirmed against
the compiled binary) parses this argument with `parse_number`, not
`parse_number_or_percent`, in every one of the four functions, unlike the
R/G/B or S/L arguments that share this same call site's neighbours, so a
trailing `%` invalidates the value there and resvg 0.48.1 falls back to
black -- a real, verified bug in the exact svgtypes release resvg pins (a
later, unreleased svgtypes accepts it, matching every browser). Only this one
file in the whole corpus uses a percentage alpha, so accepting it here does
not touch resvg parity anywhere else.

Percent-or-not otherwise shares one scale, exactly as `hslFracOf` below
handles S/L: a trailing `%` divides the decimal by 100 by lowering its
exponent 2, before the same `scaleDecimal` call the plain form uses.

svgtypes stores it as a `u8` with `round (a * 255)`, and usvg then unpacks it
again as an opacity (`Color::split_alpha` → `a / 255`), so this has to land on
exactly the same 255ths grid as `parseOpacity`; going through the 1/256 grid
loses `0.7` and `0.35` the same way `fill-opacity` used to. -/
def alphaOf (bs : ByteArray) : Option Nat :=
  let t := trim bs
  match parseDecimal t 0 with
  | none => none
  | some (neg, mant, exp10, j) =>
    let isPct := at' t j == 37
    if (if isPct then j + 1 else j) != t.size then none
    else some (if neg then 0 else scaleDecimal mant (if isPct then exp10 - 2 else exp10) 255 255)

def parseRgbFunc (bs : ByteArray) (start : Nat) : Option Rgba :=
  let close := findByte bs start 41
  if close ≥ bs.size then none
  else
    let inner := bs.extract start close
    let parts := splitTrim inner 44
    let parts := if parts.size == 1 then splitTrim inner 32 else parts
    if parts.size == 3 || parts.size == 4 then
      let p0 := parts.getD 0 default
      let comp := if compIsPercent p0 then compOf else compNumOnly
      match comp p0, comp (parts.getD 1 default), comp (parts.getD 2 default) with
      | some r, some g, some b =>
        if parts.size == 4 then
          match alphaOf (parts.getD 3 default) with
          | some a => some ⟨r, g, b, a⟩
          | none => none
        else some ⟨r, g, b, 255⟩
      | _, _, _ => none
    else none

/-- Round `n/d` to the nearest integer, halves away from zero -- the same
rule `divRound` (below, in the arc-flattening section) uses, restated here
under a different name because colour parsing comes first in the file and
`hslToRgb` needs it before that definition. -/
def hueRound (n d : Int) : Int :=
  if d ≤ 0 then 0
  else if n ≥ 0 then Int.ediv (2 * n + d) (2 * d)
  else -(Int.ediv (2 * (-n) + d) (2 * d))

/-- The number or percentage that `hsl()`'s saturation and lightness are
given as, clamped to `[0, 1]` (i.e. `[0, opacityOne]`) exactly like svgtypes'
`f64_bound(0.0, x, 1.0)`.  Same grid and semantics as `parseOpacity` below,
duplicated here because that definition comes after `parsePaint` in the file
and this has to come before it. -/
def hslFracOf (bs : ByteArray) : Option Nat :=
  let t := trim bs
  match parseDecimal t 0 with
  | none => none
  | some (neg, mant, exp10, j) =>
    let exp10 := if at' t j == 37 then exp10 - 2 else exp10
    some (if neg then 0 else scaleDecimal mant exp10 opacityOne opacityOne)

/-- `hsl()`'s hue: a *plain* number -- svgtypes 0.16.1 (the version resvg
0.48.1 actually embeds, confirmed against the compiled binary: `hsl(86deg,
...)` falls back to black, even though the crate's later, unreleased source
adds CSS `<angle>` units here) parses it with `parse_number`, so `deg` and
friends are not a suffix to strip, they invalidate the value like any other
leftover byte.  Left unclamped -- `hslToRgb` wraps it into `[0, 360)` with a
true modulus, so `hsl(800, ...)` is meaningful, not an overflow.  Scaled by
`opacityOne`, same grid as `hslFracOf`. -/
def parseHueDeg (bs : ByteArray) : Option Int :=
  let t := trim bs
  match parseDecimal t 0 with
  | none => none
  | some (neg, mant, exp10, j) =>
    if j != t.size then none
    else
      let mag : Int := Int.ofNat (scaleDecimal mant exp10 opacityOne (10 ^ 40))
      some (if neg then -mag else mag)

/-- HSL → RGB, following svgtypes' `hsl_to_rgb`/`hue_to_rgb`
(`src/color.rs`) step for step in exact integer arithmetic instead of `f32`.
`hueDeg` is the hue in degrees scaled by `opacityOne` (`parseHueDeg`, any
sign/magnitude); `s`/`l` are already on the `opacityOne` grid, clamped to
`[0, opacityOne]` (`hslFracOf`).  Every intermediate is kept as a numerator
over the common denominator `bigG = 60 * opacityOne` -- `hueDeg`'s reduction
mod `360 * opacityOne` (`= 6 * bigG`) doubles as `hue/60`'s numerator over
`bigG` for free, and `s`/`l` become numerators over `bigG` by `* 60`.  The
seven divisions `hue_to_rgb` does in `f32` become seven `hueRound`s on that
grid: each is accurate to about one part in `6·10^19`, far finer than the
`round (x * 255)` (svgtypes' `f32::round`, halves away from zero, matched
here by `hueRound` again) that produces the final `u8`. -/
def hslToRgb (hueDeg : Int) (s l : Nat) : Nat × Nat × Nat :=
  let bigG : Int := 60 * (opacityOne : Int)
  -- `hue/60`'s numerator over `bigG`, in `[0, 6 * bigG)`.
  let hueX : Int := Int.emod hueDeg (360 * (opacityOne : Int))
  let sX : Int := (s : Int) * 60
  let lX : Int := (l : Int) * 60
  let t2X : Int :=
    if lX * 2 ≤ bigG then hueRound (lX * (sX + bigG)) bigG
    else lX + sX - hueRound (lX * sX) bigG
  let t1X : Int := 2 * lX - t2X
  let hueToRgbX (hOff : Int) : Int :=
    let h := if hOff < 0 then hOff + 6 * bigG else hOff
    let h := if h ≥ 6 * bigG then h - 6 * bigG else h
    if h < bigG then t1X + hueRound ((t2X - t1X) * h) bigG
    else if h < 3 * bigG then t2X
    else if h < 4 * bigG then t1X + hueRound ((t2X - t1X) * (4 * bigG - h)) bigG
    else t1X
  let toU8 (x : Int) : Nat :=
    let v := hueRound (x * 255) bigG
    if v ≤ 0 then 0 else if v ≥ 255 then 255 else v.toNat
  (toU8 (hueToRgbX (hueX + 2 * bigG)), toU8 (hueToRgbX hueX), toU8 (hueToRgbX (hueX - 2 * bigG)))

/-- Parse `hsl(...)`/`hsla(...)`'s contents (same comma-or-space splitting,
and the same alpha-in-either-function leniency, as `parseRgbFunc`). -/
def parseHslFunc (bs : ByteArray) (start : Nat) : Option Rgba :=
  let close := findByte bs start 41
  if close ≥ bs.size then none
  else
    let inner := bs.extract start close
    let parts := splitTrim inner 44
    let parts := if parts.size == 1 then splitTrim inner 32 else parts
    if parts.size == 3 || parts.size == 4 then
      match parseHueDeg (parts.getD 0 default), hslFracOf (parts.getD 1 default),
            hslFracOf (parts.getD 2 default) with
      | some hueDeg, some s, some l =>
        let (r, g, b) := hslToRgb hueDeg s l
        if parts.size == 4 then
          match alphaOf (parts.getD 3 default) with
          | some a => some ⟨r, g, b, a⟩
          | none => none
        else some ⟨r, g, b, 255⟩
      | _, _, _ => none
    else none

/-- The optional second half of `url(#id) <fallback>` (svgtypes'
`PaintFallback`): what to paint with when the reference resolves to nothing.
`absent` — no fallback was written — also means "paint nothing", but it is
kept distinct because it is the only case that matters for a future
`context-fill`. -/
inductive PaintFallback where
  | absent
  | none
  | currentColor
  | color (c : Rgba)
deriving Repr, Inhabited

/-- The result of parsing a paint value: a resolved paint, or a marker for
`currentcolor` that the caller (`applyProp` on `fill`/`stroke`) resolves
against the element's own `color` at apply time. -/
inductive PaintSpec where
  | none
  | solid (c : Rgba)
  | currentColor
  /-- `url(#id)` with its fallback; `resolvePaint` looks `id` up in the
  style's gradient table (T18). -/
  | url (id : String) (fb : PaintFallback)
  /-- `context-fill` (`false`) / `context-stroke` (`true`), SVG 2 (T47). -/
  | context (stroke : Bool)
deriving Repr, Inhabited

/-- Parse a plain colour (no `none`, no `url()`, no `currentcolor`). -/
def parseSolidColor (t : ByteArray) : Option Rgba :=
  if at' t 0 == 35 then parseHexColor t
  else if startsWith t 0 "rgba(" then parseRgbFunc t 5
  else if startsWith t 0 "rgb(" then parseRgbFunc t 4
  else if startsWith t 0 "hsla(" then parseHslFunc t 5
  else if startsWith t 0 "hsl(" then parseHslFunc t 4
  else if startsWith t 0 "oklab(" then Oklab.parse t   -- T104 (Chromium; usvg: invalid)
  else
    let s := toStr t
    match namedColors.find? (fun (n, _) => n == s) with
    | some (_, v) => some ⟨(v >>> 16) &&& 255, (v >>> 8) &&& 255, v &&& 255, 255⟩
    | none => none

/-- Parse `url(#id)` plus an optional fallback, as svgtypes' `Paint::FuncIRI`.
Only a *local* reference (`#id`) can ever resolve — this renderer has no code
path that opens a second file — so anything else keeps its fallback and
otherwise paints nothing, which is what usvg does with an id it cannot find.
An id longer than `Grad.maxIdLen` is treated as absent.

Text after the `url(…)` that is not a fallback at all — svgtypes' `Paint`
grammar has no room for the `icc-color(…)` of SVG 1.1 — makes the *whole*
value unparseable, and usvg then falls back to black for `fill` and to no
stroke for `stroke`; `none` here leaves the property inherited, which is
black at the root and so agrees on `fill`.

`raw` and `low` are the same bytes with and without case folding, and `lower`
preserves length, so the offsets are shared: ids are case-sensitive and come
out of `raw`, keywords and colour names out of `low`. -/
def parseUrlPaint (raw low : ByteArray) : Option PaintSpec :=
  let close := findByte low 4 41
  if close ≥ low.size then some .none
  else
    let inner := trim (raw.extract 4 close)
    -- `url('#id')` / `url("#id")` are both legal CSS.
    let q := at' inner 0
    let inner :=
      if (q == 34 || q == 39) && inner.size ≥ 2 then trim (inner.extract 1 (inner.size - 1))
      else inner
    let id := if at' inner 0 == 35 then toStr (inner.extract 1 inner.size) else ""
    let rest := trim (low.extract (close + 1) low.size)
    let fb : Option PaintFallback :=
      if rest.size == 0 then some .absent
      else if eqAscii rest "none" then some .none
      else if eqAscii rest "currentcolor" then some .currentColor
      else (parseSolidColor rest).map .color
    fb.map fun fb =>
      if id.isEmpty || id.length > Grad.maxIdLen then .url "" fb else .url id fb

/-- Parse a paint value. -/
def parsePaint (bs : ByteArray) : Option PaintSpec :=
  let raw := trim bs
  let t := lower raw
  if eqAscii t "none" then some .none
  else if eqAscii t "transparent" then some (.solid ⟨0, 0, 0, 0⟩)
  else if eqAscii t "currentcolor" then some .currentColor
  else if eqAscii t "context-fill" then some (.context false)
  else if eqAscii t "context-stroke" then some (.context true)
  else if startsWith t 0 "url(" then parseUrlPaint raw t
  else (parseSolidColor t).map .solid

/-- Opacity in `[0, opacityOne]`, i.e. usvg's `Opacity::new_clamped`.

The decimal is taken straight from `parseDecimal`, so no precision is lost on
the way in: a percentage is just an exponent shift, and the only rounding is
onto the 1/10^18 grid, which is exact for everything the lexer can produce. -/
def parseOpacity (bs : ByteArray) : Option Nat :=
  let t := trim bs
  match parseDecimal t 0 with
  | none => none
  | some (neg, mant, exp10, j) =>
    -- usvg parses an opacity as an `svgtypes::Length` and accepts it only when
    -- the unit is `None` or `%` (`FromValue for Opacity`); `Length::from_str`
    -- itself rejects trailing junk.  So a value with any other unit, or with
    -- anything after the number, is *invalid* rather than clamped —
    -- `none` here, which leaves the property at its default of fully opaque
    -- (`painting/opacity/invalid-value-2.svg`: `opacity="0.1mm"` renders the
    -- element opaque, not at 10%).
    let pct := at' t j == 37
    let e := if pct then j + 1 else j
    if e != t.size then none
    else
      let exp10 := if pct then exp10 - 2 else exp10
      some (if neg then 0 else scaleDecimal mant exp10 opacityOne opacityOne)

/-- Multiply two opacities, staying on the 1/10^18 grid (halves up).

usvg folds an element's opacities together as one `f32` product
(`parser/style.rs`: `opacity: sub_opacity * fill_opacity`) and quantises only
afterwards; nesting groups is the one place we have to round early, and a
product of two short decimals is exact on this grid anyway. -/
def mulOpacity (a b : Nat) : Nat := (a * b * 2 / opacityOne + 1) / 2

/-- Collapse a paint alpha and the fill/stroke and group opacities into the
single `u8` that resvg hands to tiny-skia.

`crates/resvg/src/path.rs` builds the paint with
`set_color_rgba8(r, g, b, fill.opacity().to_u8())`, and usvg has already folded
the colour's own alpha into that opacity (`convert_paint` does
`*opacity = alpha` from `Color::split_alpha`, i.e. `a / 255`, and `resolve_fill`
returns `sub_opacity * fill_opacity`).  So the whole chain is one product,
quantised once with `round (x * 255)`:

  `a8 = round (alpha/255 * fillOp * groupOp * 255) = round (alpha * fillOp * groupOp)`

computed here in exact integer arithmetic, halves away from zero. -/
def opacityToU8 (alpha fillOp groupOp : Nat) : Nat :=
  Nat.min 255 ((alpha * fillOp * groupOp * 2 / (opacityOne * opacityOne) + 1) / 2)

/-! ## Transforms -/

def parseTransform (bs : ByteArray) : Mat := Id.run do
  let mut m := Mat.identity
  let mut i := 0
  for _ in [0:bs.size + 1] do
    i := skipWsComma bs i
    if i ≥ bs.size then break
    let ne := skipWhile bs i isAlpha
    if ne == i then break
    let name := lower (bs.extract i ne)
    let j := skipWs bs ne
    if at' bs j != 40 then break
    let close := findByte bs (j + 1) 41
    if close ≥ bs.size then break
    let argBytes := bs.extract (j + 1) close
    let args := parseNumberList argBytes
    -- `scale`'s factors and `matrix`'s `a b c d` are multiplicative
    -- coefficients, not positions: parsed on the coarser `Fx` (1/256) grid
    -- and then promoted, their quantization is amplified by whatever they
    -- multiply (T31).  `args16` lexes the same tokens directly onto the
    -- 16.16 grid the matrix stores them on, so they reach `Mat` exactly,
    -- with no `* 256` promotion.  `translate`'s offsets and `matrix`'s `e f`
    -- stay positions, read from `args` (`Fx`) as before.
    let args16 := parseNumberList16 argBytes
    let g := fun k => args.getD k 0
    let g16 := fun k => args16.getD k 0
    let t : Option Mat :=
      if eqAscii name "matrix" && args.size == 6 then
        some (Mat.mk' (g16 0) (g16 1) (g16 2) (g16 3) (g 4) (g 5))
      else if eqAscii name "translate" && (args.size == 1 || args.size == 2) then
        some (Mat.translate (g 0) (if args.size == 2 then g 1 else 0))
      else if eqAscii name "scale" && (args.size == 1 || args.size == 2) then
        some (Mat.scale16 (g16 0) (if args.size == 2 then g16 1 else g16 0))
      else if eqAscii name "rotate" && args.size == 1 then
        some (Mat.rotate (g 0))
      else if eqAscii name "rotate" && args.size == 3 then
        some (((Mat.translate (g 1) (g 2)).mul (Mat.rotate (g 0))).mul (Mat.translate (-(g 1)) (-(g 2))))
      else if eqAscii name "skewx" && args.size == 1 then some (Mat.skewX (g 0))
      else if eqAscii name "skewy" && args.size == 1 then some (Mat.skewY (g 0))
      else none
    match t with
    | some t => m := m.mul t
    | none => break
    i := close + 1
  return m

/-! ## Elliptical arcs

`A`/`a` path commands, converted to at most four cubic Béziers by the
endpoint-to-centre parameterisation of SVG 1.1 §F.6.5.  Everything is integer
fixed point: `Fx` coordinates in 1/256 px, direction vectors in 16.16, and
`Nat.sqrt` for every square root.  No `atan2` appears anywhere.  The sweep is
walked one quarter turn at a time and the decision to stop comes from the sign
of a cross product; the Bézier constant for a segment spanning θ ≤ 90° comes
from the half- and quarter-angle tangent identities

    tan (θ/2) = s / (1 + c),    tan (θ/4) = tan (θ/2) / (1 + √(1 + tan² (θ/2)))

evaluated on `c = a · b` and `s = |a × b|` for the segment's unit endpoints,
and `k = 4/3 · tan (θ/4)`.  At θ = 90° that evaluates to exactly `kappa16`
(36195), so a quarter drawn as an arc and the same quarter drawn by
`ellipsePath` produce identical control points, and a circle written as four
`A` commands rasterises to the same pixels as a `<circle>`.  That is also what
usvg does: it splits a sweep at quarter-turn boundaries with κ controls rather
than choosing a segment count from a flatness tolerance.
-/

/-- Round-to-nearest division by a positive `d`, halves away from zero.  Plain
`Int.ediv` floors, which would bias every negative coordinate down by up to one
unit and make an arc quarter disagree with the same quarter from `ellipsePath`. -/
def divRound (n d : Int) : Int :=
  if d ≤ 0 then 0
  else if n ≥ 0 then Int.ediv (2 * n + d) (2 * d)
  else -(Int.ediv (2 * (-n) + d) (2 * d))

/-- A direction in the ellipse's own parameter space, 16.16 per component. -/
abbrev ArcDir := Int × Int

/-- A quarter turn in the sweep direction (`pos` is `sweep-flag = 1`, i.e. the
direction of increasing parameter angle).  A coordinate swap and one sign flip. -/
def rot90 (pos : Bool) (v : ArcDir) : ArcDir := if pos then (-v.2, v.1) else (v.2, -v.1)

/-- Rescale a 16.16 vector back to unit length, so that accumulated rounding
cannot present the quarter-turn test with a vector that is not a unit vector. -/
def unit16 (v : ArcDir) : ArcDir :=
  let h := Fx.hypot v.1 v.2
  if h ≤ 0 then (65536, 0)
  else (divRound (v.1 * 65536) h, divRound (v.2 * 65536) h)

/-- Largest magnitude of a centre coordinate on the refined grid. -/
def arcHiMax : Int := Fx.maxVal * 65536

def clampHi (a : Int) : Int :=
  if a > arcHiMax then arcHiMax else if a < -arcHiMax then -arcHiMax else a

/-- One arc segment as a cubic in user space: from unit direction `a` to unit
direction `b`, no more than a quarter turn apart.  `cx`, `cy` are the centre on
the refined 16-extra-bit grid (`Fx · 2^16`), and `rx`, `ry` with the 16.16
`(sn, cs)` of φ map parameter space to user space as
`c + R(φ)·(rx·v.x, ry·v.y)`; keeping the centre unrounded means a control point
is quantised once, at the end, exactly like a control point read from a file.
`fin`, when given, replaces the mapped endpoint: the last segment of an arc
must land *exactly* on the command's endpoint, otherwise a closed path stops
being closed. -/
def arcSegment (cx cy : Int) (rx ry sn cs : Int) (pos : Bool) (a b : ArcDir)
    (fin : Option Pt) : PathCmd :=
  let dotv := divRound (a.1 * b.1 + a.2 * b.2) 65536
  let crs := a.1 * b.2 - a.2 * b.1
  let sinv := divRound (if crs < 0 then -crs else crs) 65536
  let den := 65536 + dotv
  let t2 := if den ≤ 0 then 65536 else divRound (sinv * 65536) den
  let q := 65536 + divRound (t2 * t2) 65536
  let r := Int.ofNat (Nat.sqrt (q * 65536).toNat)
  let t4 := divRound (t2 * 65536) (65536 + r)
  let k := divRound (4 * t4) 3
  let ap := rot90 pos a
  let bp := rot90 pos b
  let c1v : ArcDir := (a.1 + divRound (k * ap.1) 65536, a.2 + divRound (k * ap.2) 65536)
  let c2v : ArcDir := (b.1 - divRound (k * bp.1) 65536, b.2 - divRound (k * bp.2) 65536)
  let toUser := fun (v : ArcDir) =>
    (⟨Fx.clamp (divRound (cx * 65536 + cs * rx * v.1 - sn * ry * v.2) 4294967296),
      Fx.clamp (divRound (cy * 65536 + sn * rx * v.1 + cs * ry * v.2) 4294967296)⟩ : Pt)
  .cubicTo (toUser c1v) (toUser c2v) (fin.getD (toUser b))

/-- Expand one `A`/`a` command into path commands.  `p1` is the current point,
`p2` the command's (already resolved) endpoint, `phi` the x-axis rotation in
degrees, `fA`/`fS` the large-arc and sweep flags. -/
def arcPath (p1 : Pt) (rxIn ryIn phi : Fx) (fA fS : Bool) (p2 : Pt) : Array PathCmd := Id.run do
  -- §F.6.2 out-of-range handling: a zero-length arc is dropped entirely, a
  -- zero radius degenerates to a straight line, and the radii are taken as
  -- absolute values.
  if p1.x == p2.x && p1.y == p2.y then return #[]
  let rx0 := rxIn.natAbs
  let ry0 := ryIn.natAbs
  if rx0 == 0 || ry0 == 0 then return #[.lineTo p2]
  let (sn, cs) := sinCos16 (degToRad16 phi)
  -- §F.6.5.1: half of `p1 − p2`, rotated by −φ.  The halving is folded into
  -- the 16.16 divisor so no bit is lost before the rounding.
  let dx := p1.x - p2.x
  let dy := p1.y - p2.y
  let x1 : Fx := divRound (cs * dx + sn * dy) 131072
  let y1 : Fx := divRound (cs * dy - sn * dx) 131072
  let xa := x1.natAbs
  let ya := y1.natAbs
  -- §F.6.6: if the endpoints do not fit on the ellipse, scale both radii by
  -- `√Λ`, i.e. `rx := √(x1'²ry² + y1'²rx²)/ry` and `ry := √(…)/rx` with the
  -- *original* radii on the right.
  --
  -- Both square root and division round *down*, deliberately.  A corrected
  -- ellipse is one the endpoints lie on, so `num` below is zero and the centre
  -- is the midpoint of the chord.  Rounding a radius up by even one 1/256 px
  -- makes `num` positive instead, and the centre then moves by
  -- `√(r'² − (chord/2)²)` — a square root of a tiny number, so a quarter of a
  -- pixel of slop in the radius throws the centre a third of a unit off the
  -- chord.  Rounding down keeps `num` at zero (`Nat` subtraction truncates)
  -- and lands on exactly the degenerate half-turn the geometry asks for.
  let fit := xa * xa * (ry0 * ry0) + ya * ya * (rx0 * rx0)
  let cap := rx0 * rx0 * (ry0 * ry0)
  let (rxN, ryN) :=
    if fit ≤ cap then (rx0, ry0)
    else
      let s := Nat.sqrt fit
      (Nat.max 1 (s / ry0), Nat.max 1 (s / rx0))
  let rx2 := rxN * rxN
  let ry2 := ryN * ryN
  let den := rx2 * (ya * ya) + ry2 * (xa * xa)
  if den == 0 then return #[.lineTo p2]
  -- §F.6.5.2: the centre in the rotated frame.  `Nat` subtraction truncates at
  -- zero, which is exactly the clamp the spec asks for when rounding has made
  -- the numerator slightly negative.  `coef` is `√(num/den)` in 16.16.
  let coef := Int.ofNat (Nat.sqrt ((rx2 * ry2 - den) * 4294967296 / den))
  let rx : Int := Int.ofNat rxN
  let ry : Int := Int.ofNat ryN
  let sgn : Int := if fA != fS then 1 else -1
  -- The centre stays on the refined `Fx · 2^16` grid all the way to the
  -- control points, so the only quantisation to 1/256 px is the final one.
  let cxp := clampHi (divRound (sgn * coef * rx * y1) ry)
  let cyp := clampHi (divRound (-(sgn * coef * ry * x1)) rx)
  -- §F.6.5.3: back to user space, `c = R(φ)·(cx', cy') + (p1 + p2)/2`.
  let cx := clampHi (divRound (2 * (cs * cxp - sn * cyp) + 4294967296 * (p1.x + p2.x)) 131072)
  let cy := clampHi (divRound (2 * (sn * cxp + cs * cyp) + 4294967296 * (p1.y + p2.y)) 131072)
  -- §F.6.5.5, without the angles: the two endpoints as unit directions.
  let u1 := unit16 (divRound (x1 * 65536 - cxp) rx, divRound (y1 * 65536 - cyp) ry)
  let u2 := unit16 (divRound (-(x1 * 65536) - cxp) rx, divRound (-(y1 * 65536) - cyp) ry)
  -- Walk the sweep.  A sweep is under a full turn, so at most four segments.
  let mut out : Array PathCmd := #[]
  let mut u := u1
  let mut done := false
  for step in [0:4] do
    let crs := u.1 * u2.2 - u.2 * u2.1
    let dotv := u.1 * u2.1 + u.2 * u2.2
    -- `u2` is inside the next quarter turn when the cross product carries the
    -- sweep's sign (or is zero) and the angle is at most 90°.  The exception
    -- is a full turn: rounding has collapsed `u2` onto `u1` while `fA` says
    -- the sweep is more than half a turn, which needs all four quarters.
    let full := step == 0 && fA && u.1 == u2.1 && u.2 == u2.2
    if (if fS then crs ≥ 0 else crs ≤ 0) && dotv ≥ 0 && !full then
      out := out.push (arcSegment cx cy rx ry sn cs fS u u2 (some p2))
      done := true
      break
    let v := rot90 fS u
    out := out.push (arcSegment cx cy rx ry sn cs fS u v none)
    u := v
  if !done then out := out.push (.lineTo p2)
  return out

/-! ## Path data -/

/-- Parse `d` path data.  On a syntax error the commands parsed so far are
returned, as the SVG spec requires ("render up to the error"). -/
def parsePathDataJ (bs : ByteArray) : Array PathCmd × Array Nat := Id.run do
  let mut out : Array PathCmd := #[]
  -- T90: indices in `out` of the cubics that end *inside* an arc (where
  -- `arcPath` split it), which are not path vertices for `marker-mid`.
  let mut joins : Array Nat := #[]
  let mut i := 0
  let mut cmd : UInt8 := 0
  let mut cur : Pt := ⟨0, 0⟩
  let mut start : Pt := ⟨0, 0⟩
  let mut lastC : Pt := ⟨0, 0⟩
  let mut lastQ : Pt := ⟨0, 0⟩
  let mut prevWasC := false
  let mut prevWasQ := false
  let mut haveMove := false
  for _ in [0:bs.size + 1] do
    i := skipWsComma bs i
    if i ≥ bs.size then break
    let c := at' bs i
    if isAlpha c then
      cmd := c
      i := i + 1
      if c == 90 || c == 122 then
        out := out.push .close
        cur := start
        prevWasC := false
        prevWasQ := false
      continue
    if cmd == 0 then break
    let rel := 97 ≤ cmd && cmd ≤ 122
    let base := if rel then cur else ⟨0, 0⟩
    let up := toLower cmd
    -- read up to seven numbers as needed
    let need : Nat :=
      if up == 109 || up == 108 || up == 116 then 2
      else if up == 104 || up == 118 then 1
      else if up == 99 then 6
      else if up == 115 || up == 113 then 4
      else if up == 97 then 7
      else 0
    if need == 0 then break
    let mut nums : Array Fx := #[]
    let mut j := i
    let mut okNums := true
    for t in [0:need] do
      j := skipWsComma bs j
      if up == 97 && (t == 3 || t == 4) then
        -- The two arc flags are single characters, and the grammar lets them
        -- run together with no separator and with the endpoint that follows
        -- (`a1 1 0 0110 5`), so exactly one byte is consumed for each.  They
        -- ride along in `nums` as `0` or `1` on the `Fx` grid.
        let fc := at' bs j
        if fc == 48 then
          nums := nums.push 0
          j := j + 1
        else if fc == 49 then
          nums := nums.push Fx.one
          j := j + 1
        else
          okNums := false
          break
      else
        match parseNumber bs j with
        | some (v, k) =>
          nums := nums.push v
          j := k
        | none =>
          okNums := false
          break
    if !okNums then break
    if !haveMove && up != 109 then break
    i := j
    let g := fun k => nums.getD k 0
    let p := fun k => (⟨base.x + g k, base.y + g (k + 1)⟩ : Pt)
    let nextC := fun (_ : Unit) => prevWasC
    let nextQ := fun (_ : Unit) => prevWasQ
    prevWasC := false
    prevWasQ := false
    if up == 109 then
      let q := p 0
      out := out.push (.moveTo q)
      cur := q
      start := q
      haveMove := true
      cmd := if rel then 108 else 76
    else if up == 108 then
      let q := p 0
      out := out.push (.lineTo q)
      cur := q
    else if up == 104 then
      let q : Pt := ⟨base.x + g 0, cur.y⟩
      out := out.push (.lineTo q)
      cur := q
    else if up == 118 then
      let q : Pt := ⟨cur.x, base.y + g 0⟩
      out := out.push (.lineTo q)
      cur := q
    else if up == 99 then
      let c1 := p 0
      let c2 := p 2
      let q := p 4
      out := out.push (.cubicTo c1 c2 q)
      lastC := c2
      prevWasC := true
      cur := q
    else if up == 115 then
      let c1 := if nextC () then ⟨2 * cur.x - lastC.x, 2 * cur.y - lastC.y⟩ else cur
      let c2 := p 0
      let q := p 2
      out := out.push (.cubicTo c1 c2 q)
      lastC := c2
      prevWasC := true
      cur := q
    else if up == 113 || up == 116 then
      let qc : Pt :=
        if up == 113 then p 0
        else if nextQ () then ⟨2 * cur.x - lastQ.x, 2 * cur.y - lastQ.y⟩ else cur
      let q := if up == 113 then p 2 else p 0
      out := out.push (.quadTo qc q)
      lastQ := qc
      prevWasQ := true
      cur := q
    else if up == 97 then
      -- rx ry φ are never relative; only the endpoint is.
      let q := p 5
      let arc := arcPath cur (g 0) (g 1) (g 2) (g 3 != 0) (g 4 != 0) q
      for k in [0:arc.size - 1] do
        joins := joins.push (out.size + k)
      out := out.append arc
      cur := q
  return (out, joins)

def parsePathData (bs : ByteArray) : Array PathCmd := (parsePathDataJ bs).1

/-! ## Basic shapes as paths -/

/-- κ = 4(√2 − 1)/3 ≈ 0.5523 in 16.16. -/
def kappa16 : Int := 36195

def ellipsePath (cx cy rx ry : Fx) : Array PathCmd :=
  let kx := Int.ediv (rx * kappa16) 65536
  let ky := Int.ediv (ry * kappa16) 65536
  #[.moveTo ⟨cx + rx, cy⟩,
    .cubicTo ⟨cx + rx, cy + ky⟩ ⟨cx + kx, cy + ry⟩ ⟨cx, cy + ry⟩,
    .cubicTo ⟨cx - kx, cy + ry⟩ ⟨cx - rx, cy + ky⟩ ⟨cx - rx, cy⟩,
    .cubicTo ⟨cx - rx, cy - ky⟩ ⟨cx - kx, cy - ry⟩ ⟨cx, cy - ry⟩,
    .cubicTo ⟨cx + kx, cy - ry⟩ ⟨cx + rx, cy - ky⟩ ⟨cx + rx, cy⟩,
    .close]

def rectPath (x y w h rx ry : Fx) : Array PathCmd :=
  if rx ≤ 0 || ry ≤ 0 then
    #[.moveTo ⟨x, y⟩, .lineTo ⟨x + w, y⟩, .lineTo ⟨x + w, y + h⟩, .lineTo ⟨x, y + h⟩, .close]
  else
    let rx := Fx.min rx (Int.ediv w 2)
    let ry := Fx.min ry (Int.ediv h 2)
    let kx := Int.ediv (rx * kappa16) 65536
    let ky := Int.ediv (ry * kappa16) 65536
    #[.moveTo ⟨x + rx, y⟩,
      .lineTo ⟨x + w - rx, y⟩,
      .cubicTo ⟨x + w - rx + kx, y⟩ ⟨x + w, y + ry - ky⟩ ⟨x + w, y + ry⟩,
      .lineTo ⟨x + w, y + h - ry⟩,
      .cubicTo ⟨x + w, y + h - ry + ky⟩ ⟨x + w - rx + kx, y + h⟩ ⟨x + w - rx, y + h⟩,
      .lineTo ⟨x + rx, y + h⟩,
      .cubicTo ⟨x + rx - kx, y + h⟩ ⟨x, y + h - ry + ky⟩ ⟨x, y + h - ry⟩,
      .lineTo ⟨x, y + ry⟩,
      .cubicTo ⟨x, y + ry - ky⟩ ⟨x + rx - kx, y⟩ ⟨x + rx, y⟩,
      .close]

def polyPath (pts : Array Fx) (closed : Bool) : Array PathCmd := Id.run do
  let n := pts.size / 2
  if n == 0 then return #[]
  let mut out : Array PathCmd := #[.moveTo ⟨pts.getD 0 0, pts.getD 1 0⟩]
  for k in [1:n] do
    out := out.push (.lineTo ⟨pts.getD (2 * k) 0, pts.getD (2 * k + 1) 0⟩)
  if closed then out := out.push .close
  return out

/-! ## Attributes -/

def attr (attrs : Array Xml.Attr) (name : String) : Option ByteArray :=
  (attrs.find? (fun a => a.name == name)).map (·.value)

/-- A length or percentage at a byte offset -- like `parseLength` (which this
wraps for every non-percent unit), except it also accepts `%`: there is no
reference to resolve it against here, so the raw `N` of `N%` is returned
alongside the flag, and the caller resolves it against whatever the SVG spec
names for that attribute (`resolvePct`). -/
def parseLenPctAt (bs : ByteArray) (i : Nat) : Option (Fx × Bool × Nat) :=
  match parseNumber bs i with
  | none => none
  | some (v, j) =>
    if at' bs j == 37 then some (v, true, j + 1)
    else match parseLength bs i with
      | some (v', j') => some (v', false, j')
      | none => none

/-- Parse a whole attribute value as a length or a percentage. -/
def parseLengthOrPercent (bs : ByteArray) : Option (Fx × Bool) :=
  let t := trim bs
  match parseLenPctAt t 0 with
  | some (v, pct, j) => if j == t.size then some (v, pct) else none
  | none => none

/-- Resolve a length-or-percentage pair (as `parseLengthOrPercent`/
`parseLenPctAt` return it) against a reference length: usvg's `convert_length`
for `Units::UserSpaceOnUse` (`crates/usvg/src/parser/units.rs`), i.e. the raw
number times the reference over 100, floor-divided like every other unit
conversion in `parseLength`; unchanged if it was not a percentage. -/
def resolvePct (l : Fx × Bool) (ref : Fx) : Fx :=
  if l.2 then Int.ediv (l.1 * ref) 25600 else l.1

/-- Resolve the root element's natural (pre-`--width`/`--zoom`) size in user
units from `width`, `height` and `viewBox`, matching usvg's `resolve_svg_size`
(`crates/usvg/src/parser/converter.rs`, `get_svg_size`): a percentage on
either axis resolves against the matching `viewBox` dimension when a
`viewBox` is present, or against the 100×100 default otherwise
(`Options::default_size`); when exactly one of `width`/`height` is given and a
`viewBox` is present, the other is derived from the `viewBox`'s aspect ratio,
exactly as before this task. `none` means the size cannot be determined (one
of `width`/`height` given, the other entirely absent, no `viewBox`) -- unlike
usvg we do not fall back to a bounding-box refit here (a separate, bigger
feature; see T24a's `Report` on `no-size.svg`), so the caller keeps failing
exactly as it did before percentages existed. -/
def resolveRootSize (root : RootInfo) : Option (Fx × Fx) :=
  match root.width, root.height, root.viewBox with
  | some w, some h, some (_, _, vw, vh) => some (resolvePct w vw, resolvePct h vh)
  | some w, some h, none => some (resolvePct w (Fx.ofNat 100), resolvePct h (Fx.ofNat 100))
  | some w, none, some (_, _, vw, vh) =>
    let wv := resolvePct w vw
    some (wv, if vw > 0 then Int.ediv (wv * vh) vw else wv)
  | none, some h, some (_, _, vw, vh) =>
    let hv := resolvePct h vh
    some (if vh > 0 then Int.ediv (hv * vw) vh else hv, hv)
  | none, none, some (_, _, vw, vh) => some (vw, vh)
  | none, none, none => some (Fx.ofNat 100, Fx.ofNat 100)
  | _, _, _ => none

def parseRoot (attrs : Array Xml.Attr) : RootInfo :=
  let vb := match attr attrs "viewBox" with
    | some v =>
      let ns := parseNumberList v
      if ns.size == 4 then some (ns.getD 0 0, ns.getD 1 0, ns.getD 2 0, ns.getD 3 0) else none
    | none => none
  { width := (attr attrs "width").bind parseLengthOrPercent,
    height := (attr attrs "height").bind parseLengthOrPercent,
    viewBox := vb,
    aspect := ((attr attrs "preserveAspectRatio").map Viewport.parseAspectRatio).getD {} }

/-! ## `marker` attribute grammars (T52)

These four are read straight off a `<marker>` element's own attributes, the
way `clipPathUnits` already is (`attr`, not the CSS-aware `attrOrStyle`):
usvg's own resolution for them is `SvgNode::attribute`/`convert_length`, not
the inherited-property cascade `applyEffective` runs, and no marker test in
the corpus sets any of them from `style=""` or a stylesheet. -/

/-- A length-or-percentage attribute, resolved against `refLen` -- T52's
`refX`/`markerWidth` against the viewport's width, `refY`/`markerHeight`
against its height, exactly like `parseTransformOrigin`'s lengths. -/
def lengthOrPctAttr (attrs : Array Xml.Attr) (name : String) (dflt refLen : Fx) : Fx :=
  match attr attrs name with
  | some v => match parseLengthOrPercent v with
    | some lp => resolvePct lp refLen
    | none => dflt
  | none => dflt

/-- `orient`'s fixed-angle grammar: a number, then an optional lower-case unit
(`deg` if absent, `grad`, `rad`, `turn`), converted to degrees as `Fx`
(svgtypes' `Stream::parse_angle`/`Angle::to_degrees`).  `none` on anything
left over after a recognised suffix or no number at all, matching
`Angle::from_str`'s error, which `convert_orientation` turns into a fixed
`0°` (not this function's job -- its caller decides the fallback). -/
def parseAngleDeg (bs : ByteArray) : Option Fx :=
  let t := trim bs
  match parseNumber t 0 with
  | none => none
  | some (n, j) =>
    if j == t.size then some n
    else if startsWith t j "deg" && j + 3 == t.size then some n
    else if startsWith t j "grad" && j + 4 == t.size then some (Int.ediv (n * 9) 10)
    else if startsWith t j "rad" && j + 3 == t.size then some (Int.ediv (n * 180 * 65536) pi16)
    else if startsWith t j "turn" && j + 4 == t.size then some (n * 360)
    else none

/-- `orient`: `auto`, `auto-start-reverse`, an angle, or (absent/unparseable)
a fixed `0°` (usvg's `convert_orientation`). -/
def parseOrientAttr (attrs : Array Xml.Attr) : MarkerOrient :=
  match attr attrs "orient" with
  | none => .fixed 0
  | some v =>
    let t := trim v
    if eqAscii t "auto" then .auto
    else if eqAscii t "auto-start-reverse" then .autoStartReverse
    else match parseAngleDeg t with
      | some d => .fixed d
      | none => .fixed 0

/-- `preserveAspectRatio`: `[defer ]align[ meet|slice]` (svgtypes'
`AspectRatio`, `defer` accepted and ignored like usvg).  Absent or
unparseable is the default, `xMidYMid meet` -- as `(alignNone, alignX,
alignY, slice)` = `(false, 1, 1, false)`, `Marker.viewBoxTransform`'s own
parameters. -/
def parseAspectAttr (attrs : Array Xml.Attr) : Bool × Nat × Nat × Bool :=
  let dflt := (false, 1, 1, false)
  match attr attrs "preserveAspectRatio" with
  | none => dflt
  | some v =>
    let t := trim v
    let t := if startsWith t 0 "defer " then trim (t.extract 6 t.size) else t
    let e := skipWhile t 0 isAlpha
    let word := t.extract 0 e
    let align? : Option (Bool × Nat × Nat) :=
      if eqAscii word "none" then some (true, 0, 0)
      else if eqAscii word "xMinYMin" then some (false, 0, 0)
      else if eqAscii word "xMidYMin" then some (false, 1, 0)
      else if eqAscii word "xMaxYMin" then some (false, 2, 0)
      else if eqAscii word "xMinYMid" then some (false, 0, 1)
      else if eqAscii word "xMidYMid" then some (false, 1, 1)
      else if eqAscii word "xMaxYMid" then some (false, 2, 1)
      else if eqAscii word "xMinYMax" then some (false, 0, 2)
      else if eqAscii word "xMidYMax" then some (false, 1, 2)
      else if eqAscii word "xMaxYMax" then some (false, 2, 2)
      else none
    match align? with
    | none => dflt
    | some (an, ax, ay) => (an, ax, ay, eqAscii (trim (t.extract e t.size)) "slice")

/-! ## `transform-origin` -/

/-- One `transform-origin` token: a directional keyword or a length/percentage
(the raw number and whether it was a percentage, as `parseLenPctAt` returns
it).  Mirrors svgtypes' `Position`/`DirectionalPosition`
(`transform_origin.rs`, `directional_position.rs`): a length is usable on
either axis, while a keyword is usable only on the axis(es) its name implies
(`center` on both). -/
inductive OriginTok where
  | len (v : Fx) (isPct : Bool)
  | left
  | right
  | top
  | bottom
  | center
deriving Inhabited

def OriginTok.isHoriz : OriginTok → Bool
  | .top => false
  | .bottom => false
  | _ => true

def OriginTok.isVert : OriginTok → Bool
  | .left => false
  | .right => false
  | _ => true

/-- Usable as *either* axis without being a directional keyword: a length, or
`center` (svgtypes' `check`). -/
def OriginTok.isCheck : OriginTok → Bool
  | .len _ _ => true
  | .center => true
  | _ => false

/-- As a length/percentage (`From<Position> for Length` /
`From<DirectionalPosition> for Length` in svgtypes): `left`/`top` are `0%`,
`right`/`bottom` are `100%`, `center` is `50%`. -/
def OriginTok.asLen : OriginTok → Fx × Bool
  | .len v p => (v, p)
  | .left => (0, true)
  | .top => (0, true)
  | .right => (Fx.ofNat 100, true)
  | .bottom => (Fx.ofNat 100, true)
  | .center => (Fx.ofNat 50, true)

def parseOriginTok (bs : ByteArray) (i : Nat) : Option (OriginTok × Nat) :=
  if isAlpha (at' bs i) then
    let ne := skipWhile bs i isAlpha
    let w := bs.extract i ne
    if eqAscii w "left" then some (.left, ne)
    else if eqAscii w "right" then some (.right, ne)
    else if eqAscii w "top" then some (.top, ne)
    else if eqAscii w "bottom" then some (.bottom, ne)
    else if eqAscii w "center" then some (.center, ne)
    else none
  else
    match parseLenPctAt bs i with
    | some (v, pct, j) => some (.len v pct, j)
    | none => none

/-- Parse `transform-origin`: one or two lengths/percentages/keywords
(`left|center|right` for x, `top|center|bottom` for y; one value → the second
is `center`), resolved against `(refW, refH)`.  usvg always resolves
`transform-origin` percentages against the *current viewport*, on every
element, never the object bounding box: `resolve_transform`
(`crates/usvg/src/parser/converter.rs`) hard-codes `Units::UserSpaceOnUse`
regardless of element type, so `convert_length` always takes the `view_box`
branch.  Confirmed against the `structure/transform-origin` corpus -- e.g.
`left`/`right`/`right bottom`/`top left` land at the *viewport*'s edges, not
the rectangle's own bounding box, even though the two coincide for several of
those fixtures (a 200×200 viewBox and a rect centred in it).  A malformed
value, or a three-token one (a z-offset, which this 2-D renderer has no use
for and doesn't validate), yields `(0, 0)`: a no-op wherever it's applied,
identical to `transform-origin` being entirely absent. -/
def parseTransformOrigin (bs : ByteArray) (refW refH : Fx) : Fx × Fx :=
  let t := trim bs
  if t.size == 0 then (0, 0)
  else match parseOriginTok t 0 with
    | none => (0, 0)
    | some (p1, j1) =>
      let j1' := skipWsComma t j1
      if j1' ≥ t.size then
        if p1.isHoriz then (resolvePct p1.asLen refW, resolvePct OriginTok.center.asLen refH)
        else (resolvePct OriginTok.center.asLen refW, resolvePct p1.asLen refH)
      else match parseOriginTok t j1' with
        | none => (0, 0)
        | some (p2, j2) =>
          if skipWsComma t j2 < t.size then (0, 0)
          else if p1.isCheck && p2.isCheck then (resolvePct p1.asLen refW, resolvePct p2.asLen refH)
          else if p1.isHoriz && p2.isVert then (resolvePct p1.asLen refW, resolvePct p2.asLen refH)
          else if p1.isVert && p2.isHoriz then (resolvePct p2.asLen refW, resolvePct p1.asLen refH)
          else (0, 0)

/-- Resolve a parsed paint against the style's own `color` (for
`currentcolor`) and its gradient table (for `url(#id)`).

usvg's `convert_paint` on a `FuncIRI`: a reference that names nothing, or a
paint server that resolves to nothing (no stops, an `href` that leaves the
gradients), uses the fallback; one that resolves to a single colour becomes
that colour, which happens here instead in `Grad.build`, where the stop's own
opacity can still be folded in exactly.  The one case we do not reproduce is
an id that exists but belongs to some *other* element: usvg paints nothing
there, while we take the fallback, because only paint servers are indexed. -/
def resolvePaint (st : Style) : PaintSpec → Paint
  | .none => .none
  | .solid c => .solid c
  | .currentColor => .solid st.color
  | .context stroke => if stroke then st.ctxStroke else st.ctxFill
  | .url id fb =>
    let fallback : Paint := match fb with
      | .absent => .none
      | .none => .none
      | .currentColor => .solid st.color
      | .color c => .solid c
    match st.defs.lookup id with
    | some i =>
      match (st.defs.defs.getD i default).shape with
      | .invalid => fallback
      | _ => .gradient i fallback
    | none =>
      match st.patterns.lookup id with
      | some i => if (st.patterns.defs.getD i default).valid then .pattern i else fallback
      | none => fallback

/-- T85: the `ctxUses` slot a paint resolved from `context-*` is tied to. -/
def ctxSlotOf (st : Style) : PaintSpec → Option Nat
  | .context _ => st.ctxSlot
  | _ => none

/-- T95: which `context-*` a paint is, when it is left for `Marker.expand`. -/
def markerCtxKind (st : Style) : PaintSpec → Option Bool
  | .context stroke => if st.markerCtx then some stroke else none
  | _ => none

/-- Parse the `color` property.  It is an ordinary colour, never `none` or
`url(...)`; reusing `parsePaint` and rejecting anything but `.solid` gets that
for free (`none`/`url()` parse to `PaintSpec.none`, and `currentcolor` to
`PaintSpec.currentColor`, both filtered out here). -/
def parseColor (bs : ByteArray) : Option Rgba :=
  match parsePaint bs with
  | some (.solid c) => some c
  | _ => none

/-! ## Text properties (T36)

`font-size`, `letter-spacing` and `word-spacing` are lengths whose `em`/`ex`
(and, for `font-size`, `%`) units resolve against a *font size* rather than the
viewport, so `Fixed.lean`'s `parseLength` — which prices `em` at a fixed 16 px —
cannot be reused for them. -/

/-- usvg's `convert_named_font_size`: a factor of `1.2^n` on the inherited
size, with `n` from the keyword.  Anything unrecognised is `n = 0`, i.e. the
inherited size itself (usvg warns and carries on), which is also what makes a
malformed `font-size` inherit rather than fail. -/
def namedFontSize (t : ByteArray) (parent : Fx) : Fx :=
  let step : Int :=
    if eqAscii t "xx-small" then -3
    else if eqAscii t "x-small" then -2
    else if eqAscii t "small" then -1
    else if eqAscii t "smaller" then -1
    else if eqAscii t "large" then 1
    else if eqAscii t "larger" then 1
    else if eqAscii t "x-large" then 2
    else if eqAscii t "xx-large" then 3
    else 0
  let pow := fun (b : Int) (n : Nat) => Id.run do
    let mut r : Int := 1
    for _ in [0:n] do r := r * b
    return r
  if step > 0 then Fx.clamp (Int.ediv (parent * pow 6 step.toNat) (pow 5 step.toNat))
  else if step < 0 then Fx.clamp (Int.ediv (parent * pow 5 (-step).toNat) (pow 6 (-step).toNat))
  else parent

/-- The unit suffix of a font-relative length, as a multiplier applied to
`ref` (`em`), half of it (`ex`) or a hundredth (`%`); absolute units go
through `Fixed.lean`'s own conversions, and `dpi` is usvg's default 96. -/
def applyFontUnit (rest : ByteArray) (n ref : Fx) : Option Fx :=
  if rest.size == 0 || eqAscii rest "px" then some n
  else if eqAscii rest "em" then some (Fx.mul n ref)
  else if eqAscii rest "ex" then some (Int.ediv (Fx.mul n ref) 2)
  else if eqAscii rest "%" then some (Int.ediv (Fx.mul n ref) 100)
  else if eqAscii rest "pt" then some (Int.ediv (n * 4) 3)
  else if eqAscii rest "pc" then some (n * 16)
  else if eqAscii rest "mm" then some (Int.ediv (n * 960) 254)
  else if eqAscii rest "cm" then some (Int.ediv (n * 9600) 254)
  else if eqAscii rest "in" then some (n * 96)
  else none

/-- T92: the units `applyFontUnit` lacks (`rem` and `Units.parseAt`'s), for a
whole value `n` + `t[j:]`; font units measure against `ref`. -/
def applyNewUnit (t : ByteArray) (j : Nat) (n ref : Fx) (ctx : Units.RootLen) : Option Fx :=
  if eqAscii (t.extract j t.size) "rem" then some (Fx.mul n ctx.size)
  else match Units.parseAt t j n ref ctx with
    | some (v, k) => if k == t.size then some v else none
    | none => none

/-- `font-size`: a length relative to the inherited size, or a keyword. -/
def parseFontSize (parent : Fx) (bs : ByteArray) (ctx : Units.RootLen) : Fx :=
  let t := trim bs
  match parseNumber t 0 with
  | none => namedFontSize t parent
  | some (n, j) =>
    match applyFontUnit (t.extract j t.size) n parent with
    | some v => v
    | none => (applyNewUnit t j n parent ctx).getD (namedFontSize t parent)

/-- The length a percentage resolves against on an attribute that names
neither axis (`letter-spacing`, `word-spacing`): usvg's
`√((w² + h²) / 2)` of the viewport, i.e. `hypot(w, h)/√2`; `46341/65536` is
`1/√2`. -/
def viewportDiag (w h : Fx) : Fx := Fx.scale16 (Fx.hypot w h) 46341

/-- `letter-spacing` / `word-spacing`.  `normal` is zero; a percentage
resolves against `viewportDiag`, as `convert_length`'s catch-all arm does. -/
def parseSpacing (fontSize refLen : Fx) (bs : ByteArray) (ctx : Units.RootLen) : Option Fx :=
  let t := trim bs
  if eqAscii t "normal" then some 0
  else match parseNumber t 0 with
    | none => none
    | some (n, j) =>
      let rest := t.extract j t.size
      if eqAscii rest "%" then some (Int.ediv (Fx.mul n refLen) 100)
      else match applyFontUnit rest n fontSize with
        | some v => some v
        | none => applyNewUnit t j n fontSize ctx

/-- `font-weight`, as usvg resolves it: the keywords map to numbers, and
`bolder`/`lighter` step from the inherited value by 300/200 at 400 and by 100
elsewhere (Chrome's behaviour, which usvg follows over the CSS 2 spec),
clamped to `[100, 900]`. -/
def parseFontWeight (parent : Nat) (bs : ByteArray) : Nat :=
  let t := trim bs
  if eqAscii t "normal" then 400
  else if eqAscii t "bold" then 700
  else if eqAscii t "bolder" then Nat.min 900 (parent + (if parent == 400 then 300 else 100))
  else if eqAscii t "lighter" then Nat.max 100 (parent - (if parent == 400 then 200 else 100))
  else if eqAscii t "100" then 100
  else if eqAscii t "200" then 200
  else if eqAscii t "300" then 300
  else if eqAscii t "400" then 400
  else if eqAscii t "500" then 500
  else if eqAscii t "600" then 600
  else if eqAscii t "700" then 700
  else if eqAscii t "800" then 800
  else if eqAscii t "900" then 900
  -- usvg's own `resolve_font_weight` only matches these nine literals and a
  -- number outside them falls through to `_ => weight` (the inherited
  -- value, unchanged) -- a parsing bug, not a deliberate simplification:
  -- fontdb's `find_best_match` already implements CSS Fonts 4's
  -- nearest-installed-weight rule correctly once given a number (confirmed
  -- against `fontdb`'s source), so e.g. `650` should resolve to the nearest
  -- installed weight (`pickFace`, e.g. `650 → bold`) rather than being dropped.
  else match parseNumberAll t with
    | some n => if n ≥ 256 && n ≤ 256000 then (n / 256).toNat else parent
    | none => parent

/-- `font-stretch` as usvg's `conv_font_stretch` reads it (T118): the nine
keywords give width classes 1–9, `narrower` is `condensed` and `wider` is
`expanded` (absolute, not relative to the parent), `inherit` keeps the
parent's, and anything else, percentages included, is normal. -/
def parseFontStretch (parent : Nat) (bs : ByteArray) : Nat :=
  let t := trim bs
  let kws := #["ultra-condensed", "extra-condensed", "condensed", "semi-condensed", "normal",
    "semi-expanded", "expanded", "extra-expanded", "ultra-expanded"]
  if eqAscii t "inherit" then parent
  else if eqAscii t "narrower" then 3
  else if eqAscii t "wider" then 7
  else match kws.findIdx? (eqAscii t ·) with
    | some i => i + 1
    | none => 5

/-- Strip one matching layer of straight quotes (CSS allows a quoted family
name in a `font-family` list). -/
def stripQuotes (bs : ByteArray) : ByteArray :=
  if bs.size ≥ 2 &&
     ((Bytes.at' bs 0 == 34 && Bytes.at' bs (bs.size - 1) == 34) ||
      (Bytes.at' bs 0 == 39 && Bytes.at' bs (bs.size - 1) == 39)) then
    bs.extract 1 (bs.size - 1)
  else bs

/-- Families installed in the resvg test suite's font directory (the
reference's `fontdb`) that this renderer does not embed: usvg would select
one of these, so a family list that names one before any embedded family
resolves to a font we cannot draw. -/
def suiteOnlyFamilies : Array String :=
  #["Source Sans Pro", "Amiri", "Noto Serif", "Noto Mono", "Noto Sans Devanagari",
    "Noto Color Emoji", "Noto Emoji", "Sedgwick Ave Display", "Yellowtail"]

/-- `font-family`, resolved against the embedded fonts (`FontSet`, T91) to
the index of the font usvg would pick, or `none` when it would pick no font
or one we do not embed.  usvg resolves the comma-separated family list
against `fontdb`'s installed fonts (here, the resvg-test-suite's pinned
directory) in list order, stopping at the first name that matches an
installed font; a CSS generic keyword (`serif`, `sans-serif`, …) maps to an
`Options` generic-family name (`Times New Roman`, `Arial`, …) that is never
installed either, and an unmatched list falls back to that same default
family — also never installed.  T106: each name is matched by
`FamilyMatch.lookup` (exact family, alias, then the unquoted CSS generics as
Chromium on Linux resolves them), so e.g. `Times`, `serif` and `sans-serif`
are real matches that raise no warning.  A name that is installed there but not
embedded here (`suiteOnlyFamilies`) ends the search with `none`; any other
unrecognised name is skipped, as `fontdb::Database::query` does.  An unquoted
name must be a sequence of CSS identifiers: svgtypes rejects the whole value
when a word starts with a digit (`Mplus 1p`), and usvg then uses its default
family, so that is `none` too. -/
def resolveFontFamily (bs : ByteArray) (doc : Array FontFace.Face := #[]) : Option Nat := Id.run do
  for tok in Bytes.splitTrim bs 44 do
    let name := stripQuotes tok
    if name.size == tok.size then
      for w in Bytes.splitTrim name 32 do
        let c := Bytes.at' w 0
        if 48 ≤ c && c ≤ 57 then return none
    -- T105: the document's `@font-face` families come first (Chromium's
    -- order: a family list is matched name by name, each against the
    -- document's faces before the installed fonts)
    let lname := Bytes.lower name
    match (List.range doc.size).find? (fun k => doc[k]?.map (·.family) == some lname) with
    | some k => return some (FontSet.count + k)
    | none => pure ()
    -- T106: exact family, alias, then generic (`FamilyMatch.lookup`)
    match FamilyMatch.lookup name (name.size != tok.size) with
    | some k => return some k
    | none => if suiteOnlyFamilies.any (eqAscii name ·) then return none
  return none

/-- One item of an `x`/`y`/`dx`/`dy` list: `convert_user_length`, which
resolves `em`/`ex` against the element's own font size, `rem` against the
root element's (`Style.rootFontSize`), a percentage against the viewport axis
the attribute belongs to (`x`/`dx` → width, `y`/`dy` → height), and `Q`
(quarter-millimetres, SVG 2) as a fixed ratio like `mm`/`cm`. -/
def parseTextLen (fontSize refLen : Fx) (rootFontSize : Units.RootLen) (bs : ByteArray) (i : Nat) : Option (Fx × Nat) :=
  match parseNumber bs i with
  | none => none
  | some (v, j) =>
    if startsWith bs j "px" then some (v, j + 2)
    else if startsWith bs j "rem" then some (Fx.mul v rootFontSize.size, j + 3)
    else if startsWith bs j "em" then some (Fx.mul v fontSize, j + 2)
    else if startsWith bs j "ex" then some (Int.ediv (Fx.mul v fontSize) 2, j + 2)
    else if startsWith bs j "pt" then some (Int.ediv (v * 4) 3, j + 2)
    else if startsWith bs j "pc" then some (v * 16, j + 2)
    else if startsWith bs j "mm" then some (Int.ediv (v * 960) 254, j + 2)
    else if startsWith bs j "cm" then some (Int.ediv (v * 9600) 254, j + 2)
    else if startsWith bs j "in" then some (v * 96, j + 2)
    -- 1Q = 1/40 cm = 96 / (2.54 * 40) px = 120/127 px, exactly (SVG 2).
    else if startsWith bs j "Q" then some (Int.ediv (v * 120) 127, j + 1)
    else if at' bs j == 37 then some (Int.ediv (Fx.mul v refLen) 100, j + 1)
    -- T92: the CSS Values 4 units usvg lacks (`vw`, `ch`, `rlh`, ...).
    else match Units.parseAt bs j v fontSize rootFontSize with
      | some r => some r
      | none => some (v, j)

/-- Parse a whole attribute value as a single `parseTextLen` length: usvg's
`convert_user_length`, which every non-text geometry attribute
(`x`/`y`/`width`/`height`/`cx`/`cy`/`r`/`rx`/`ry`/`x1`/`y1`/`x2`/`y2`) goes
through as well as text's own `x`/`y`/`dx`/`dy` -- the same em/ex-against-
font-size and percentage-against-viewport-axis resolution, just for a single
value instead of a list. -/
def parseTextLenAll (fontSize refLen : Fx) (rootFontSize : Units.RootLen) (bs : ByteArray) : Option Fx :=
  let t := trim bs
  match parseTextLen fontSize refLen rootFontSize t 0 with
  | some (v, j) => if j == t.size then some v else none
  | none => none

/-- `textLength`: one length, the whole (trimmed) attribute value, negative
rejected (`n < 0` in usvg's parser turns `text_length` back into `None`
rather than clamping it). -/
def parseTextLength (fontSize refLen : Fx) (rootFontSize : Units.RootLen) (bs : ByteArray) : Option Fx :=
  let t := trim bs
  match parseTextLen fontSize refLen rootFontSize t 0 with
  | some (v, j) => if j == t.size && v ≥ 0 then some v else none
  | none => none

/-- A whitespace/comma separated list of such lengths.  Stops at the first
item it cannot read, like `parseNumberList`. -/
def parseTextLenList (fontSize refLen : Fx) (rootFontSize : Units.RootLen) (bs : ByteArray) : Array Fx := Id.run do
  let mut out : Array Fx := #[]
  let mut i := 0
  for _ in [0:bs.size + 1] do
    i := skipWsComma bs i
    if i ≥ bs.size then break
    match parseTextLen fontSize refLen rootFontSize bs i with
    | some (v, j) =>
      out := out.push v
      i := j
    | none => break
  return out

/-- `stroke-dasharray`: a whitespace/comma separated list of lengths, resolved
like `parseTextLen` (`em`/`ex` against `fontSize`, `%` against `refLen`), but
all-or-nothing like `parseAbsLengthList` — one bad item drops the whole list,
matching `Geom.dashPattern`'s downstream fallback to an undashed stroke. -/
def parseDashLengthList (fontSize refLen : Fx) (rootFontSize : Units.RootLen) (bs : ByteArray) : Option (Array Fx) := Id.run do
  let t := trim bs
  let mut out : Array Fx := #[]
  let mut i := 0
  for _ in [0:t.size + 1] do
    i := skipWsComma t i
    if i ≥ t.size then break
    match parseTextLen fontSize refLen rootFontSize t i with
    | some (v, j) =>
      out := out.push v
      i := j
    | none => return none
  return some out

/-- `stroke-dashoffset`: a single length, resolved the same way. -/
def parseDashLengthAll (fontSize refLen : Fx) (rootFontSize : Units.RootLen) (bs : ByteArray) : Option Fx :=
  let t := trim bs
  match parseTextLen fontSize refLen rootFontSize t 0 with
  | some (v, j) => if j == t.size then some v else none
  | none => none

/-- `rotate` is a *number* list, and usvg's `Vec<f32>` reader propagates a
parse error out of the whole attribute (`n.ok()?`), so one bad item — a unit
suffix, say — makes the element carry no rotation at all rather than a
truncated list. -/
def parseStrictNumberList (bs : ByteArray) : Option (Array Fx) := Id.run do
  let mut out : Array Fx := #[]
  let mut i := 0
  for _ in [0:bs.size + 1] do
    i := skipWsComma bs i
    if i ≥ bs.size then break
    match parseNumber bs i with
    | some (v, j) =>
      -- a trailing unit is a `NumberListParser` error, not a stopping point
      if j < bs.size && !(isWs (at' bs j)) && at' bs j != 44 then return none
      out := out.push v
      i := j
    | none => return none
  return some out
/-- `fill` / `stroke` / `markers`, by position (`0`/`1`/`2`), matching
svgtypes' `PaintOrderKind`. -/
def paintOrderKindOf (tok : ByteArray) : Option Nat :=
  if eqAscii tok "fill" then some 0
  else if eqAscii tok "stroke" then some 1
  else if eqAscii tok "markers" then some 2
  else none

/-- `paint-order`'s resolved order, as the three kinds of `paintOrderKindOf`.

Mirrors svgtypes' `PaintOrder::from_str` (`src/paint_order.rs`) exactly: up to
three whitespace-separated idents; `normal` short-circuits to the default
order; any unrecognised ident, or anything left over after (at most) three
idents, falls back to the default order; missing kinds are then appended in
`fill stroke markers` order; and a duplicate among the resolved three slots
*also* falls back to the default `#[0, 1, 2]`. -/
def paintOrderOf (bs : ByteArray) : Array Nat := Id.run do
  let t := trim bs
  let mut order : Array Nat := #[]
  let mut left : Array Nat := #[0, 1, 2]
  let mut i := 0
  let mut bad := false
  for _ in [0:3] do
    if !bad && order.size < 3 && i < t.size then
      let e := skipWhile t i isAlpha
      let tok := t.extract i e
      i := skipWs t e
      if eqAscii tok "normal" then bad := true
      else
        match paintOrderKindOf tok with
        | some k => left := left.filter (· != k); order := order.push k
        | none => bad := true
  if bad || order.isEmpty || i < t.size then #[0, 1, 2]
  else
    for k in left do
      if order.size < 3 then order := order.push k
    let o0 := order.getD 0 9
    let o1 := order.getD 1 9
    let o2 := order.getD 2 9
    if o0 == o1 || o0 == o2 || o1 == o2 then #[0, 1, 2] else order

/-- Position of kind `k` in a resolved `paintOrderOf`. -/
def paintOrderPos (order : Array Nat) (k : Nat) : Nat :=
  if order.getD 0 9 == k then 0 else if order.getD 1 9 == k then 1 else 2

/-- Whether `paint-order`'s resolved order puts `stroke` before `fill`
(usvg's `svg_paint_order_to_usvg`). -/
def strokeBeforeFill (bs : ByteArray) : Bool :=
  let o := paintOrderOf bs
  decide (paintOrderPos o 1 < paintOrderPos o 0)

/-- Properties usvg honours only from CSS — a `style=""` declaration or a
`<style>` rule — and ignores as presentation attributes
(`parser/svgtree/parse.rs`: "For some reason those properties are allowed only
inside a `style` attribute and CSS").  Confirmed by the corpus files
`painting/mix-blend-mode/as-property.svg` and
`painting/isolation/as-property.svg`, both of which must render *unblended*. -/
-- T52: the `marker` shorthand is CSS-only too (`svgtree/parse.rs`'s CSS
-- declaration parser expands it into the three longhands; presentation
-- attribute parsing has no such case), confirmed by `the-marker-property.svg`
-- ("Should be ignored") against `the-marker-property-in-CSS.svg`.
def isCssOnlyProp (name : String) : Bool :=
  name == "mix-blend-mode" || name == "isolation" || name == "marker"

/-- Parse a `clip-path` value into the referenced id: `url(#id)`, with optional
whitespace and single or double quotes around the `#id` (svgtypes' `FuncIRI`).
`none`, a CSS basic shape (`circle()`), or anything else yields `none`, which
is exactly what usvg does with a value it cannot parse as a `FuncIRI`: it logs
and treats the attribute as absent. -/
def parseClipRef (bs : ByteArray) : Option String :=
  let t := trim bs
  if !(startsWith t 0 "url(") then none
  else
    let close := findByte t 4 41
    if close ≥ t.size then none
    else
      let inner := trim (t.extract 4 close)
      let q := at' inner 0
      let inner := if (q == 34 || q == 39) && inner.size ≥ 2 && at' inner (inner.size - 1) == q
        then trim (inner.extract 1 (inner.size - 1)) else inner
      if at' inner 0 != 35 || inner.size < 2 || inner.size > maxIdBytes + 1 then none
      else some (toStr (inner.extract 1 inner.size))

/-- The `objectBoundingBox` unit square's map into user space:
`Transform::from_bbox` = `matrix(w 0 0 h x y)`. -/
def Box.unitMat (b : Box) : Mat :=
  Mat.mk' ((b.x1 - b.x0) * 256) 0 0 ((b.y1 - b.y0) * 256) b.x0 b.y0

/-- `NonZeroRect`: a box with positive width and height. -/
def Box.nonZero (b : Box) : Bool := b.x1 > b.x0 && b.y1 > b.y0

def Box.union (a b : Option Box) : Option Box :=
  match a, b with
  | none, b => b
  | a, none => a
  | some a, some b => some ⟨Fx.min a.x0 b.x0, Fx.min a.y0 b.y0, Fx.max a.x1 b.x1, Fx.max a.y1 b.y1⟩

/-- The box of a box's four corners under `m` (`Rect::transform`): what usvg
does to a child's bounding box on the way up through a group's transform. -/
def Box.transformed (m : Mat) (b : Box) : Option Box :=
  let c := Box.cover none (m.apply ⟨b.x0, b.y0⟩)
  let c := Box.cover c (m.apply ⟨b.x1, b.y0⟩)
  let c := Box.cover c (m.apply ⟨b.x0, b.y1⟩)
  Box.cover c (m.apply ⟨b.x1, b.y1⟩)

/-- T85: a box as a closed rectangle path, for `Grad.build`/`Pat.build`. -/
def Box.cmds (b : Box) : Array PathCmd :=
  #[.moveTo ⟨b.x0, b.y0⟩, .lineTo ⟨b.x1, b.y0⟩, .lineTo ⟨b.x1, b.y1⟩, .lineTo ⟨b.x0, b.y1⟩, .close]

/-- A path's bounding box in its own user space, from the flattened polylines
(with the identity as the flattening `ctm`): usvg's `compute_tight_bounds` up
to the flattening error, which is what `objectBoundingBox` units scale by. -/
def cmdsBox (cmds : Array PathCmd) : Option Box := Id.run do
  let mut b : Option Box := none
  for poly in flatten Mat.identity cmds do
    for p in poly.pts do
      b := Box.cover b p
  return b

/-- `Transform::is_valid`: neither axis scale is zero, i.e. neither column of
the linear part vanishes. -/
def Mat.hasScale (m : Mat) : Bool := !(m.a == 0 && m.c == 0) && !(m.b == 0 && m.d == 0)

/-- Record this element's `clip-path` as a use, if it has one: the new use
carries the element's `ctm`; its bounding box is filled in when the element
closes.  Returns the style with the use appended to `clips`, the table, and the
new use's index. -/
def addClipUse (st : Style) (uses : Array ClipUse) : Style × Array ClipUse × Option Nat :=
  match st.clipRef with
  | some id => ({ st with clips := st.clips.push uses.size }, uses.push ⟨id, none, st.ctm, none, none, none⟩, some uses.size)
  | none =>
    let env : BasicShape.Env := ⟨parseTextLenAll st.fontSize 0 st.rootFontSize, parsePathData⟩
    match st.clipShapeRaw.bind (BasicShape.parse env) with
    | some spec =>
      let vb : Box := ⟨0, 0, st.pctRefW, st.pctRefH⟩
      ({ st with clips := st.clips.push uses.size },
       uses.push { id := "", entry := none, ctm := st.ctm, bbox := none, shape := some (spec, vb) },
       some uses.size)
    | none => (st, uses, none)

/-- T90: split the CSS `font` shorthand (`[style] [variant] [weight] [stretch]
size[/line-height] family`) into `(italic, weight, size, family)`; `none`
without a size and a family. -/
def fontShorthand (v : ByteArray) : Option (Bool × Option ByteArray × ByteArray × ByteArray) := Id.run do
  let t := trim v
  let isWs := fun (b : UInt8) => b == 32 || b == 9 || b == 10 || b == 13
  -- token boundaries
  let mut toks : Array (Nat × Nat) := #[]
  let mut i := 0
  for _ in [0:t.size] do
    if i ≥ t.size then break
    if isWs (at' t i) then i := i + 1
    else
      let a := i
      for _ in [a:t.size] do
        if i < t.size && !isWs (at' t i) then i := i + 1
      toks := toks.push (a, i)
  let tok := fun (k : Nat) => let (a, b) := toks.getD k (0, 0); t.extract a b
  let numeric := fun (b : ByteArray) => let c := at' b 0; (c ≥ 48 && c ≤ 57) || c == 46
  let sizeKw := #["xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large",
                  "larger", "smaller"]
  let mut italic := false
  let mut weight : Option ByteArray := none
  for k in [0:Nat.min toks.size 5] do
    let w := tok k
    let nextNum := numeric (tok (k + 1)) || sizeKw.any (eqAscii (tok (k + 1)) ·)
    if eqAscii w "italic" || eqAscii w "oblique" then italic := true
    else if eqAscii w "bold" || eqAscii w "bolder" || eqAscii w "lighter" then weight := some w
    else if numeric w && nextNum && k + 1 < toks.size then weight := some w
    else if numeric w || sizeKw.any (eqAscii w ·) then
      -- the size, an optional `/line-height`, then the family
      let (a, b) := toks.getD k (0, 0)
      let slash := findByte (t.extract a b) 0 47
      let size := t.extract a (a + slash)
      let mut f := k + 1
      if slash == b - a && eqAscii (tok f) "/" then f := f + 2
      else if slash == b - a && at' (tok f) 0 == 47 then f := f + 1
      if f ≥ toks.size then return none
      return some (italic, weight, size, t.extract (toks.getD f (0, 0)).1 t.size)
  return none

/-- T101: an `xml:lang`/`lang` value by its primary subtag, ASCII
case-insensitively: 1 `ja`, 2 `ko`, 3 any other, 0 empty (`xml:lang=""`,
"unknown", resets to no tag) (`Text.SpanProps.lang`). -/
def langOf (v : ByteArray) : Nat :=
  let prim := v.extract 0 (findByte v 0 45)
  if v.size == 0 then 0
  else if eqAsciiCI prim "ja" then 1 else if eqAsciiCI prim "ko" then 2 else 3

def applyProp (st : Style) (name : String) (v : ByteArray) : Style :=
  match name with
  | "color" => match parseColor v with | some c => { st with color := c } | none => st
  | "clip-path" =>
    let r := parseClipRef v
    { st with clipRef := r,
              clipShapeRaw := if r.isNone && !eqAscii (trim v) "none" then some v else none }
  | "mask" => { st with maskRef := parseClipRef v }
  | "mask-type" => { st with maskAlpha := eqAscii (trim v) "alpha" }
  | "filter" => { st with filterRaw := some v }
  -- T52: `url(#id)` or `none`, exactly `clip-path`'s grammar, so `parseClipRef`
  -- (which already yields `none` for `none` and anything else it can't parse
  -- as a `FuncIRI`) is reused unchanged.  All three are ordinary inherited
  -- presentation attributes; `marker` (the shorthand) is CSS-only
  -- (`isCssOnlyProp`) and, when it does apply, sets all three together.
  | "marker-start" => { st with markerStartId := parseClipRef v }
  | "marker-mid" => { st with markerMidId := parseClipRef v }
  | "marker-end" => { st with markerEndId := parseClipRef v }
  | "marker" =>
    let r := parseClipRef v
    { st with markerStartId := r, markerMidId := r, markerEndId := r }
  | "clip-rule" =>
    let t := trim v
    if eqAscii t "evenodd" then { st with clipEvenOdd := true }
    else if eqAscii t "nonzero" then { st with clipEvenOdd := false } else st
  | "fill" => match parsePaint v with
    | some p => { st with fill := resolvePaint st p, fillCtx := ctxSlotOf st p,
                          fillCtxKind := markerCtxKind st p } | none => st
  | "stroke" => match parsePaint v with
    | some p => { st with stroke := resolvePaint st p, strokeCtx := ctxSlotOf st p,
                          strokeCtxKind := markerCtxKind st p } | none => st
  | "fill-opacity" => match parseOpacity v with | some o => { st with fillOpacity := o } | none => st
  | "stroke-opacity" => match parseOpacity v with | some o => { st with strokeOpacity := o } | none => st
  -- `opacity` is not an inherited property: it belongs to this element alone
  -- and `interpret` turns it into a layer (or, past the nesting bound, folds
  -- it into `opacity`, which *is* what descendants inherit).  `applyEffective`
  -- resets `ownOpacity` for every element, so two sources on the same element
  -- (a presentation attribute and CSS, say) still let the last one win,
  -- exactly as any other property does.
  | "opacity" => match parseOpacity v with | some o => { st with ownOpacity := o } | none => st
  | "mix-blend-mode" =>
    let t := lower (trim v)
    let m : Option BlendMode :=
      if eqAscii t "normal" then some .normal
      else if eqAscii t "multiply" then some .multiply
      else if eqAscii t "screen" then some .screen
      else if eqAscii t "overlay" then some .overlay
      else if eqAscii t "darken" then some .darken
      else if eqAscii t "lighten" then some .lighten
      else if eqAscii t "color-dodge" then some .colorDodge
      else if eqAscii t "color-burn" then some .colorBurn
      else if eqAscii t "hard-light" then some .hardLight
      else if eqAscii t "soft-light" then some .softLight
      else if eqAscii t "difference" then some .difference
      else if eqAscii t "exclusion" then some .exclusion
      else if eqAscii t "hue" then some .hue
      else if eqAscii t "saturation" then some .saturation
      else if eqAscii t "color" then some .color
      else if eqAscii t "luminosity" then some .luminosity
      else none
    match m with | some m => { st with blend := m } | none => st
  | "isolation" =>
    let t := lower (trim v)
    if eqAscii t "isolate" then { st with isolate := true }
    else if eqAscii t "auto" then { st with isolate := false } else st
  | "fill-rule" =>
    let t := trim v
    if eqAscii t "evenodd" then { st with evenOdd := true }
    else if eqAscii t "nonzero" then { st with evenOdd := false } else st
  -- `em`/`ex` against `fontSize`, `%` against the viewport diagonal
  -- (`units::convert_length`'s catch-all `aid` arm), exactly like
  -- `stroke-dasharray`/`stroke-dashoffset` above.
  | "stroke-width" =>
    match parseDashLengthAll st.fontSize (viewportDiag st.pctRefW st.pctRefH) st.rootFontSize v with
    | some w => { st with strokeWidth := Fx.max 0 w } | none => st
  | "stroke-linecap" =>
    let t := trim v
    if eqAscii t "round" then { st with cap := .round }
    else if eqAscii t "square" then { st with cap := .square }
    else if eqAscii t "butt" then { st with cap := .butt } else st
  | "stroke-linejoin" =>
    let t := trim v
    if eqAscii t "round" then { st with join := .round }
    else if eqAscii t "bevel" then { st with join := .bevel }
    else if eqAscii t "miter" then { st with join := .miter }
    -- SVG 2's `miter-clip` is a real usvg `LineJoin` variant (`arcs` is not:
    -- unrecognised, so it falls through to `else st`, keeping whatever was
    -- inherited — usvg's own fallback, since `LineJoin::default()` is `Miter`
    -- and `find_attribute` skips a value that fails to parse).
    else if eqAscii t "miter-clip" then { st with join := .miterClip } else st
  | "stroke-miterlimit" => match parseNumberAll v with | some m => { st with miterLimit := Fx.max 256 m } | none => st
  -- `none` and plain junk mean "not dashed" rather than "inherit": usvg
  -- resolves the dash properties on the nearest ancestor that *has* the
  -- attribute and drops them when that one does not parse.  `em`/`ex` resolve
  -- against the current font size and `%` against the viewport diagonal,
  -- exactly as `letter-spacing` does (`units.rs`'s `convert_length` catch-all).
  | "stroke-dasharray" =>
    { st with dashes := (parseDashLengthList st.fontSize (viewportDiag st.pctRefW st.pctRefH) st.rootFontSize v).getD #[] }
  | "stroke-dashoffset" =>
    { st with dashOffset := (parseDashLengthAll st.fontSize (viewportDiag st.pctRefW st.pctRefH) st.rootFontSize v).getD 0 }
  | "transform" =>
    -- `translate(originDx, originDy) · transform · translate(-originDx, -originDy)`
    -- (`applyEffective` sets `originDx`/`originDy` from this element's own
    -- `transform-origin`, before any `transform` value is folded in, so this
    -- sees it regardless of attribute order or which cascade layer supplies
    -- either property); a no-op, exactly the plain `parseTransform v`,
    -- whenever there is none.
    let localM := parseTransform v
    let wrapped :=
      if st.originDx == 0 && st.originDy == 0 then localM
      else ((Mat.translate st.originDx st.originDy).mul localM).mul (Mat.translate (-st.originDx) (-st.originDy))
    { st with ctm := st.ctm.mul wrapped, ownMat := st.ownMat.mul wrapped }
  | "image-rendering" => { st with imageRendering := Image.parseRendering v }
  | "visibility" =>
    let t := trim v
    if eqAscii t "hidden" || eqAscii t "collapse" then { st with visible := false }
    else if eqAscii t "visible" then { st with visible := true } else st
  | "text-rendering" =>
    let t := trim v
    if eqAscii t "optimizeSpeed" then { st with textCrisp := true }
    else if eqAscii t "auto" || eqAscii t "optimizeLegibility" || eqAscii t "geometricPrecision" then
      { st with textCrisp := false }
    else st
  | "shape-rendering" =>
    let t := trim v
    if eqAscii t "crispEdges" || eqAscii t "optimizeSpeed" then { st with crisp := true }
    else if eqAscii t "geometricPrecision" || eqAscii t "auto" then { st with crisp := false }
    else st
  -- T36: text properties.  Inherited like every other property here; only
  -- `Svg.textShapes` ever reads them.
  | "font-size" => { st with fontSize := parseFontSize st.fontSize v st.rootFontSize }
  | "font-weight" => { st with fontWeight := parseFontWeight st.fontWeight v }
  | "font-stretch" => { st with fontStretch := parseFontStretch st.fontStretch v }
  | "font-family" =>
    match resolveFontFamily v st.docFaces with
    | some k => { st with fontAvailable := true, fontFamily := k, fontFamilyRaw := trim v }
    | none => { st with fontAvailable := false, fontFamily := 0, fontFamilyRaw := trim v }
  -- `find_decoration`: space-separated tokens of this element's own raw
  -- value, freshly parsed (not merged with whatever the parent had).
  | "text-decoration" =>
    let has := fun (name : String) => (Bytes.splitTrim v 32).any (fun t => eqAscii t name)
    { st with ownUnderline := has "underline", ownOverline := has "overline",
              ownLineThrough := has "line-through" }
  -- Negative values are ignored (`text_length = None`); `%` is a fraction of
  -- the viewport width, the axis a left-to-right run measures along.
  | "textLength" => { st with ownTextLength := parseTextLength st.fontSize st.pctRefW st.rootFontSize v }
  | "lengthAdjust" => { st with ownLengthAdjustGlyphs := eqAscii (trim v) "spacingAndGlyphs" }
  | "direction" =>
    let t := trim v
    if eqAscii t "rtl" then { st with textRtl := true }
    else if eqAscii t "ltr" then { st with textRtl := false } else st
  | "unicode-bidi" =>
    let t := trim v
    { st with ownBidiOverride := eqAscii t "bidi-override" || eqAscii t "isolate-override" }
  | "font-style" =>
    let t := trim v
    if eqAscii t "italic" || eqAscii t "oblique" then { st with fontItalic := true }
    else if eqAscii t "normal" then { st with fontItalic := false } else st
  -- T97: usvg compares the inherited value with `small-caps`; `inherit`
  -- keeps the parent's
  | "font-variant" =>
    let t := trim v
    if eqAscii t "inherit" then st else { st with fontSmallCaps := eqAscii t "small-caps" }
  | "font" =>
    -- T90: the CSS `font` shorthand, in either delivery form (usvg expands
    -- only the CSS one): reset, then the longhands it names.
    match fontShorthand v with
    | none => st
    | some (italic, weight, size, family) =>
      let st := { st with fontItalic := italic, fontWeight := 400, textKerning := true,
                          fontSizeAdjust := none,
                          fontSmallCaps := (Bytes.splitTrim v 32).any (eqAscii · "small-caps"),
                          -- T118: reset, then a stretch keyword the shorthand names
                          fontStretch := ((Bytes.splitTrim v 32).map (parseFontStretch 5 ·)).foldl
                            (fun a k => if k != 5 then k else a) 5 }
      let st := match weight with
        | some w => { st with fontWeight := parseFontWeight st.fontWeight w }
        | none => st
      let st := { st with fontSize := parseFontSize st.fontSize size st.rootFontSize }
      match resolveFontFamily family st.docFaces with
      | some k => { st with fontAvailable := true, fontFamily := k, fontFamilyRaw := trim family }
      | none => { st with fontAvailable := false, fontFamily := 0, fontFamilyRaw := trim family }
  | "font-size-adjust" =>
    let t := trim v
    if eqAscii t "none" then { st with fontSizeAdjust := none }
    else match parseNumber t 0 with
      | some (n, j) => if j == t.size && n > 0 then { st with fontSizeAdjust := some n } else st
      | none => st
  | "letter-spacing" =>
    match parseSpacing st.fontSize (viewportDiag st.pctRefW st.pctRefH) v st.rootFontSize with
    | some s => { st with letterSpacing := s } | none => st
  | "word-spacing" =>
    match parseSpacing st.fontSize (viewportDiag st.pctRefW st.pctRefH) v st.rootFontSize with
    | some s => { st with wordSpacing := s } | none => st
  | "font-kerning" =>
    let t := trim v
    if eqAscii t "none" then { st with textKerning := false }
    else if eqAscii t "auto" || eqAscii t "normal" then { st with textKerning := true } else st
  -- SVG 1.1's `kerning` property: usvg turns pair kerning off only for an
  -- explicit zero length, and leaves `auto` (and anything unparsable) alone.
  | "kerning" =>
    match parseLengthAll v with | some k => { st with textKerning := k != 0 } | none => st
  | "text-anchor" =>
    let t := trim v
    if eqAscii t "middle" then { st with textAnchor := .middle }
    else if eqAscii t "end" then { st with textAnchor := .atEnd }
    else if eqAscii t "start" then { st with textAnchor := .start } else st
  -- `convert_writing_mode`: any value at all (including one this renderer
  -- does not recognise) resets the flag — a nearer ancestor's explicit
  -- `lr`/`lr-tb`/junk overrides a farther ancestor's `tb`.
  | "writing-mode" =>
    let t := trim v
    { st with writingMode :=
        eqAscii t "tb" || eqAscii t "tb-rl" || eqAscii t "vertical-rl" || eqAscii t "vertical-lr" }
  -- T54: `dominant-baseline`/`alignment-baseline`.  Ordinary CSS inheritance
  -- (nearest ancestor's own value wins, like every other property here);
  -- `no-change` (and any other unrecognised token) is a no-op, which is
  -- exactly usvg's "use the parent's own value" for `no-change` — see
  -- `LeanSvg/Baseline.lean`'s module docs for the one case that differs.
  | "dominant-baseline" =>
    let t := trim v
    if eqAscii t "auto" || eqAscii t "use-script" || eqAscii t "reset-size" then
      { st with dominantBaseline := .auto }
    else if eqAscii t "ideographic" then { st with dominantBaseline := .ideographic }
    else if eqAscii t "alphabetic" then { st with dominantBaseline := .alphabetic }
    else if eqAscii t "hanging" then { st with dominantBaseline := .hanging }
    else if eqAscii t "mathematical" then { st with dominantBaseline := .mathematical }
    else if eqAscii t "central" then { st with dominantBaseline := .central }
    else if eqAscii t "middle" then { st with dominantBaseline := .middle }
    else if eqAscii t "text-after-edge" then { st with dominantBaseline := .textAfterEdge }
    else if eqAscii t "text-before-edge" then { st with dominantBaseline := .textBeforeEdge }
    else st
  | "alignment-baseline" =>
    let t := trim v
    if eqAscii t "auto" then { st with alignmentBaseline := .auto }
    else if eqAscii t "baseline" then { st with alignmentBaseline := .baseline }
    else if eqAscii t "before-edge" then { st with alignmentBaseline := .beforeEdge }
    else if eqAscii t "text-before-edge" then { st with alignmentBaseline := .textBeforeEdge }
    else if eqAscii t "middle" then { st with alignmentBaseline := .middle }
    else if eqAscii t "central" then { st with alignmentBaseline := .central }
    else if eqAscii t "after-edge" then { st with alignmentBaseline := .afterEdge }
    else if eqAscii t "text-after-edge" then { st with alignmentBaseline := .textAfterEdge }
    else if eqAscii t "ideographic" then { st with alignmentBaseline := .ideographic }
    else if eqAscii t "alphabetic" then { st with alignmentBaseline := .alphabetic }
    else if eqAscii t "hanging" then { st with alignmentBaseline := .hanging }
    else if eqAscii t "mathematical" then { st with alignmentBaseline := .mathematical }
    else st
  -- `get_xmlspace`: `preserve` turns collapsing off, any *other* value turns
  -- it back on, and an absent attribute inherits (which is what not matching
  -- here does).
  | "xml:space" => { st with spacePreserve := eqAscii (trim v) "preserve" }
  | "xml:lang" | "lang" => { st with lang := langOf (trim v) }
  | "paint-order" =>
    { st with strokeFirst := strokeBeforeFill v, markersPos := paintOrderPos (paintOrderOf v) 2 }
  | _ => st

/-- Parse a `style="a:b; c:d"` attribute into (name, value) pairs. -/
def parseStyleDecls (v : ByteArray) : Array (String × ByteArray) :=
  (splitTrim (Css.stripComments v) 59).filterMap fun decl =>
    let k := findByte decl 0 58
    if k ≥ decl.size then none
    else some (toStr (lower (trim (decl.extract 0 k))), trim (decl.extract (k + 1) decl.size))

/-- `display="none"` (attribute or style) hides the element and its subtree. -/
def isDisplayNone (attrs : Array Xml.Attr) : Bool :=
  let a := match attr attrs "display" with
    | some v => eqAscii (trim v) "none"
    | none => false
  let s := match attr attrs "style" with
    | some v => (parseStyleDecls v).any fun (n, val) => n == "display" && eqAscii val "none"
    | none => false
  a || s

/-- `rx`/`ry` for `rect` and `ellipse` (usvg's `resolve_rx_ry`,
`crates/usvg/src/parser/shapes.rs`, shared between the two elements): a
negative value is dropped as if absent -- checked here on the *resolved*
length rather than usvg's raw pre-unit-conversion number, which agrees for
every unit this parses since none of their factors are negative; if exactly
one of the two is present, its value is mirrored onto the other axis; if
neither is, both are 0 (a later `≤ 0` check then drops the shape, same as an
explicit 0). -/
def resolveRxRy (attrs : Array Xml.Attr) (fontSize pctRefW pctRefH : Fx) (rootFontSize : Units.RootLen) : Fx × Fx :=
  let rxo := ((attr attrs "rx").bind (parseTextLenAll fontSize pctRefW rootFontSize)).filter (· ≥ 0)
  let ryo := ((attr attrs "ry").bind (parseTextLenAll fontSize pctRefH rootFontSize)).filter (· ≥ 0)
  match rxo, ryo with
  | some rx, some ry => (rx, ry)
  | some rx, none => (rx, rx)
  | none, some ry => (ry, ry)
  | none, none => (0, 0)

/-- Every shape's geometry attributes go through usvg's `convert_user_length`
(`parseTextLenAll`): `em`/`ex` against the element's own font size, `%`
against the viewport axis the attribute names (`x`-like → `pctRefW`, `y`-like
→ `pctRefH`), same as text's `x`/`y`/`dx`/`dy`.  `r` (`circle`'s only length
that names neither axis) instead falls to `convert_length`'s catch-all,
`viewportDiag`, exactly like `letter-spacing`. -/
def shapeCmds (name : String) (attrs : Array Xml.Attr) (fontSize pctRefW pctRefH : Fx) (rootFontSize : Units.RootLen) :
    Option (Array PathCmd) :=
  let lx := fun (n : String) (dflt : Fx) => ((attr attrs n).bind (parseTextLenAll fontSize pctRefW rootFontSize)).getD dflt
  let ly := fun (n : String) (dflt : Fx) => ((attr attrs n).bind (parseTextLenAll fontSize pctRefH rootFontSize)).getD dflt
  match name with
  | "path" => (attr attrs "d").map parsePathData
  | "rect" =>
    let w := lx "width" 0
    let h := ly "height" 0
    if w ≤ 0 || h ≤ 0 then none
    else
      let (rx, ry) := resolveRxRy attrs fontSize pctRefW pctRefH rootFontSize
      some (rectPath (lx "x" 0) (ly "y" 0) w h rx ry)
  | "circle" =>
    let r := ((attr attrs "r").bind (parseTextLenAll fontSize (viewportDiag pctRefW pctRefH) rootFontSize)).getD 0
    if r ≤ 0 then none else some (ellipsePath (lx "cx" 0) (ly "cy" 0) r r)
  | "ellipse" =>
    let (rx, ry) := resolveRxRy attrs fontSize pctRefW pctRefH rootFontSize
    if rx ≤ 0 || ry ≤ 0 then none
    else some (ellipsePath (lx "cx" 0) (ly "cy" 0) rx ry)
  | "line" =>
    some #[.moveTo ⟨lx "x1" 0, ly "y1" 0⟩, .lineTo ⟨lx "x2" 0, ly "y2" 0⟩]
  | "polygon" => (attr attrs "points").map fun v => polyPath (parseNumberList v) true
  | "polyline" => (attr attrs "points").map fun v => polyPath (parseNumberList v) false
  | _ => none

/-- `shapeCmds` with every coordinate on the 16.16 grid instead of `Fx`'s
1/256, i.e. the very same path scaled by 256.

Only a `clipPath` child under `clipPathUnits="objectBoundingBox"` uses this,
and nothing else can reach it, so the ordinary path stays bit-for-bit as it
was.  There such a coordinate is a *fraction of the referencing element's
bounding box*, so `Fx`'s 1/256 is a quantization of a multiplier: on a
200-unit box, `0.6` lexed as 153/256 lands at 119.53 rather than 120, half a
pixel of clip edge (T20's finding; T31 fixed the same class of error for
transform coefficients).  Lexing at 16.16 leaves the error at 200/65536, well
under a supersample, and `Clip.build` divides the extra 256 back out of the
matrix it applies (`Clip.fineScale`).

`rectPath`/`ellipsePath`/`polyPath` are grid-agnostic — their only division
is by `kappa16`, a ratio — so they are reused unchanged.  `path` is *not*
handled here (`arcPath`'s trigonometry assumes the `Fx` grid): it keeps the
1/256 coordinates, which is what `none` tells the caller. -/
def shapeCmds16 (name : String) (attrs : Array Xml.Attr) : Option (Array PathCmd) :=
  let len := fun (n : String) (dflt : Int) =>
    match attr attrs n with
    | some v => (parseLengthAll16 v).getD dflt
    | none => dflt
  match name with
  | "rect" =>
    let w := len "width" 0
    let h := len "height" 0
    if w ≤ 0 || h ≤ 0 then none
    else
      let rxo := attr attrs "rx" |>.bind parseLengthAll16
      let ryo := attr attrs "ry" |>.bind parseLengthAll16
      let (rx, ry) := match rxo, ryo with
        | some rx, some ry => (rx, ry)
        | some rx, none => (rx, rx)
        | none, some ry => (ry, ry)
        | none, none => (0, 0)
      some (rectPath (len "x" 0) (len "y" 0) w h rx ry)
  | "circle" =>
    let r := len "r" 0
    if r ≤ 0 then none else some (ellipsePath (len "cx" 0) (len "cy" 0) r r)
  | "ellipse" =>
    let rx := len "rx" 0
    let ry := len "ry" 0
    if rx ≤ 0 || ry ≤ 0 then none
    else some (ellipsePath (len "cx" 0) (len "cy" 0) rx ry)
  | "polygon" => (attr attrs "points").map fun v => polyPath (parseNumberList16 v) true
  | "polyline" => (attr attrs "points").map fun v => polyPath (parseNumberList16 v) false
  | _ => none

def isShape (name : String) : Bool :=
  name == "path" || name == "rect" || name == "circle" || name == "ellipse" ||
  name == "line" || name == "polygon" || name == "polyline"

/-- SVG conditional processing on `attrs`: `systemLanguage`, `requiredFeatures`,
`requiredExtensions`.  Matches usvg's `is_condition_passed`
(`crates/usvg/src/parser/switch.rs`).

`requiredExtensions` present at all always fails the element, since we
support none.  `requiredFeatures` is a space-separated list (never trimmed,
never collapsed: an empty value or a stray double space produces an empty
token, same as Rust's `str::split(' ')`); every token must be one of usvg's
own hard-coded SVG 1.1 Feature Strings — what *usvg* claims to implement, not
what *we* happen to — or the element is skipped.  `systemLanguage` is a
comma-separated list; it passes if some entry, after trimming, equals `en` or
starts with `en-` (usvg's default `languages = ["en"]`); an empty value has
no matching entry, so it fails.  Either attribute absent passes that check. -/
def passesConditions (attrs : Array Xml.Attr) : Bool := Id.run do
  if (attr attrs "requiredExtensions").isSome then return false
  match attr attrs "requiredFeatures" with
  | some v =>
    let features : List String :=
      ["http://www.w3.org/TR/SVG11/feature#SVGDOM-static",
       "http://www.w3.org/TR/SVG11/feature#SVG-static",
       "http://www.w3.org/TR/SVG11/feature#CoreAttribute",
       "http://www.w3.org/TR/SVG11/feature#Structure",
       "http://www.w3.org/TR/SVG11/feature#BasicStructure",
       "http://www.w3.org/TR/SVG11/feature#ContainerAttribute",
       "http://www.w3.org/TR/SVG11/feature#ConditionalProcessing",
       "http://www.w3.org/TR/SVG11/feature#Image",
       "http://www.w3.org/TR/SVG11/feature#Style",
       "http://www.w3.org/TR/SVG11/feature#Shape",
       "http://www.w3.org/TR/SVG11/feature#Text",
       "http://www.w3.org/TR/SVG11/feature#BasicText",
       "http://www.w3.org/TR/SVG11/feature#PaintAttribute",
       "http://www.w3.org/TR/SVG11/feature#BasicPaintAttribute",
       "http://www.w3.org/TR/SVG11/feature#OpacityAttribute",
       "http://www.w3.org/TR/SVG11/feature#GraphicsAttribute",
       "http://www.w3.org/TR/SVG11/feature#BasicGraphicsAttribute",
       "http://www.w3.org/TR/SVG11/feature#Marker",
       "http://www.w3.org/TR/SVG11/feature#Gradient",
       "http://www.w3.org/TR/SVG11/feature#Pattern",
       "http://www.w3.org/TR/SVG11/feature#Clip",
       "http://www.w3.org/TR/SVG11/feature#BasicClip",
       "http://www.w3.org/TR/SVG11/feature#Mask",
       "http://www.w3.org/TR/SVG11/feature#Filter",
       "http://www.w3.org/TR/SVG11/feature#BasicFilter",
       "http://www.w3.org/TR/SVG11/feature#XlinkAttribute"]
    let mut i := 0
    for _ in [0:v.size + 1] do
      if i > v.size then break
      let j := findByte v i 32
      let tok := v.extract i j
      if !(features.any fun f => eqAscii tok f) then return false
      i := j + 1
  | none => pure ()
  match attr attrs "systemLanguage" with
  | some v =>
    let mut matched := false
    for e in splitTrim v 44 do
      if eqAscii e "en" || startsWith e 0 "en-" then
        matched := true
        break
    if !matched then return false
  | none => pure ()
  return true

/-! ## Gradient definitions

The pre-pass `interpret` runs before its main walk.  It only *parses*; the
`href` inheritance, the defaults and the degenerate cases all live in
`Grad.resolve`, which is where usvg's rules are written down. -/

/-- A gradient coordinate on the 16.16 grid: a number, a percentage, or a
length with a unit.

`objectBoundingBox` coordinates are fractions of the bounding box, where
`Fx`'s 1/256 would be several pixels on a large shape, so the plain-number and
percentage cases keep all sixteen fractional bits; only the rarely used
absolute units go through `parseLength` and its `Fx`. -/
def parseCoord16 (bs : ByteArray) : Option Grad.LenPct :=
  let t := trim bs
  match parseDecimal t 0 with
  | none => none
  | some (neg, mant, exp10, j) =>
    let mag := Int.ofNat (scaleDecimal mant exp10 65536 (Fx.maxVal * 256).toNat)
    let v := if neg then -mag else mag
    if j == t.size then some (v, false)
    else if at' t j == 37 && j + 1 == t.size then some (v, true)
    else match parseLengthAll t with
      | some fx => some (fx * 256, false)
      | none => none

/-- `parseCoord16`, at `Pat.coordScale` (2^32) instead of 16.16: a `<pattern>`
`x`/`y`/`width`/`height` may still be multiplied by a bounding box
(`objectBoundingBox`) after parsing, and 16.16 is too coarse a grid for that
fraction — `Pat.coordScale`'s doc comment has the worked example. -/
def parsePatCoordFine (bs : ByteArray) : Option Grad.LenPct :=
  let t := trim bs
  match parseDecimal t 0 with
  | none => none
  | some (neg, mant, exp10, j) =>
    let mag := Int.ofNat (scaleDecimal mant exp10 Pat.coordScale.toNat (Fx.maxVal.toNat * 16777216))
    let v := if neg then -mag else mag
    if j == t.size then some (v, false)
    else if at' t j == 37 && j + 1 == t.size then some (v, true)
    else match parseLengthAll t with
      | some fx => some (fx * 16777216, false)
      | none => none

/-- A `<stop>`'s `offset`: a number or a percentage, clamped to `[0, 1]`
(usvg's `f32_bound(0.0, offset, 1.0)`), as 16.16.  `offset` is a
`<number-or-percentage>`, so *any* unit (`5mm`) keeps the previous stop's
offset, as does an absent or malformed value — `convert_stops`'
`_ => prev_offset.number`. -/
def parseStopOffset (bs : ByteArray) (prev : Int) : Int :=
  let t := trim bs
  match parseDecimal t 0 with
  | none => prev
  | some (neg, mant, exp10, j) =>
    let pct := at' t j == 37
    if (if pct then j + 1 else j) != t.size then prev
    else if neg then 0
    else
      let v := Int.ofNat (scaleDecimal mant (if pct then exp10 - 2 else exp10) 65536 65536)
      if v > 65536 then 65536 else v

/-- Presentation attribute or `style` declaration, whichever wins. -/
def attrOrStyle (attrs : Array Xml.Attr) (n : String) : Option ByteArray :=
  let decls := match attr attrs "style" with
    | some v => parseStyleDecls v
    | none => #[]
  match decls.findSome? (fun (k, v) => if k == n then some v else none) with
  | some v => some v
  | none => attr attrs n

/-- `<stop>` → `Grad.RawStop`.  Presentation attributes first, then `style`,
as everywhere else.

`inhColor` is the `color` in force on the stop's ancestors, which
`defsScan` tracks with its own small stack, because usvg reads
`currentColor` with `find_attribute(AId::Color)` and that walks all of them.
`inhStopColor` is instead the *gradient element's own* `stop-color`, and only
that: `stop-color` is not an inherited property, so `inherit` takes the direct
parent's computed value, which for a parent that does not declare it is the
initial value, black — `stop-color-with-inherit-2` and `-3`, where an
ancestor `<g>` declares it and the stop still comes out black.  Neither can
see a value that only a CSS rule sets, since this pre-pass runs before the
cascade. -/
def parseStop (attrs : Array Xml.Attr) (prev : Int) (inhColor : Rgba)
    (inhStopColor : Option ByteArray) : Grad.RawStop :=
  let pick := attrOrStyle attrs
  let black : Rgba := ⟨0, 0, 0, 255⟩
  let ofValue := fun (v : ByteArray) =>
    match parsePaint v with
    | some (.solid c) => c
    | some .currentColor => inhColor
    -- usvg: an unparseable `stop-color` warns and falls back to black.
    | _ => black
  let col := match pick "stop-color" with
    | none => black
    | some v => if eqAsciiCI (trim v) "inherit" then (inhStopColor.map ofValue).getD black
                else ofValue v
  let op := match (pick "stop-opacity").bind parseOpacity with
    | some o => o
    | none => opacityOne
  { off := parseStopOffset ((pick "offset").getD ByteArray.empty) prev, col := col, op := op }

/-- Wrap a parsed `gradientTransform`/`patternTransform` matrix with its
element's own `transform-origin`, exactly like `applyProp`'s `"transform"`
case does for a plain element: `translate(dx, dy) · m · translate(-dx, -dy)`.
usvg's `resolve_transform` (`crates/usvg/src/parser/converter.rs`) is generic
over the transform attribute id and reads both it and `transform-origin` with
`self.attribute`, i.e. from the gradient/pattern element's own attributes
only, never its `href` chain — so this runs inside `parseGradDef`/
`parsePatternDef`, before `href` inheritance (`pickCommon`) ever sees the
result, matching `resolve_transform` being called on the referenced node
itself rather than on whichever link in the chain actually supplies the
matrix. -/
def wrapTransformOrigin (attrs : Array Xml.Attr) (pctRefW pctRefH : Fx) (m : Mat) : Mat :=
  match attr attrs "transform-origin" with
  | none => m
  | some ov =>
    let (odx, ody) := parseTransformOrigin ov pctRefW pctRefH
    if odx == 0 && ody == 0 then m
    else ((Mat.translate odx ody).mul m).mul (Mat.translate (-odx) (-ody))

/-- T102: what an invalid `gradientTransform`/`patternTransform` becomes: the
zero matrix, which no paint server can invert, so the paint is `none`. -/
def singularMat : Mat := ⟨0, 0, 0, 0, 0, 0⟩

/-- One `linearGradient`/`radialGradient` element's own attributes.
`pctRefW`/`pctRefH` are the same viewport rect `applyEffective` resolves
`transform-origin` percentages against (`DefsScan.pctRef`'s doc comment). -/
def parseGradDef (name : String) (attrs : Array Xml.Attr) (pctRefW pctRefH : Fx) : Grad.RawDef :=
  let coord := fun (n : String) => (attr attrs n).bind parseCoord16
  let href := match attr attrs "href" with
    | some v => v
    | none => (attr attrs "xlink:href").getD ByteArray.empty
  let href := let t := trim href; if at' t 0 == 35 then toStr (t.extract 1 t.size) else ""
  { id := match attr attrs "id" with | some v => toStr v | none => "",
    kind := if name == "radialGradient" then .radial else .linear,
    href := if href.length > Grad.maxIdLen then "" else href,
    oBB := (attr attrs "gradientUnits").bind fun v =>
      let t := trim v
      if eqAscii t "userSpaceOnUse" then some false
      else if eqAscii t "objectBoundingBox" then some true else none,
    -- T102: a transform with a zero-length column (`matrix(0 0 0 0 0 0)`)
    -- becomes the zero matrix, so the paint draws nothing, as in Chromium
    -- (usvg's `svgtree` would use the identity instead; Rowan's review).
    -- Any singular matrix is then dropped by the inversion in `Grad.build`.
    transform := (attr attrs "gradientTransform").map fun v =>
      let m := parseTransform v
      let m := if m.a * m.a + m.b * m.b == 0 || m.c * m.c + m.d * m.d == 0 then singularMat else m
      wrapTransformOrigin attrs pctRefW pctRefH m,
    spread := (attr attrs "spreadMethod").bind fun v =>
      let t := trim v
      if eqAscii t "reflect" then some Grad.Spread.reflect
      else if eqAscii t "repeat" then some Grad.Spread.rep
      else if eqAscii t "pad" then some Grad.Spread.pad else none,
    x1 := coord "x1", y1 := coord "y1", x2 := coord "x2", y2 := coord "y2",
    cx := coord "cx", cy := coord "cy", r := coord "r",
    fx := coord "fx", fy := coord "fy", fr := coord "fr" }

/-- `preserveAspectRatio`: an optional leading `defer` (ignored — this
renderer has no external image to defer to), one of the nine alignment
keywords or `none`, and an optional trailing `meet`/`slice`.  `none` on a
malformed value, which callers treat as "attribute absent" and keep
searching the `href` chain, exactly like a malformed `viewBox`. -/
def parsePreserveAspectRatio (bs : ByteArray) : Option (Nat × Nat × Bool × Bool) :=
  let toks := (splitTrim bs 32).filter (·.size > 0)
  let toks := match toks[0]? with
    | some t => if eqAscii t "defer" then toks.extract 1 toks.size else toks
    | none => toks
  match toks[0]? with
  | none => none
  | some align =>
    if eqAscii align "none" then some (1, 1, (toks[1]?.map fun s => eqAscii s "slice").getD false, true)
    else
      -- The nine keywords are `xAlignYAlign` concatenated; matched whole
      -- (case-insensitively, as usvg's `svgtypes` does) rather than split,
      -- since the boundary is not at a fixed offset in general.
      let table : List (String × Nat × Nat) :=
        [("xminymin", 0, 0), ("xmidymin", 1, 0), ("xmaxymin", 2, 0),
         ("xminymid", 0, 1), ("xmidymid", 1, 1), ("xmaxymid", 2, 1),
         ("xminymax", 0, 2), ("xmidymax", 1, 2), ("xmaxymax", 2, 2)]
      match table.find? (fun (k, _, _) => eqAsciiCI align k) with
      | none => none
      | some (_, ax, ay) =>
        some (ax, ay, (toks[1]?.map fun s => eqAscii s "slice").getD false, false)

/-- One `<pattern>` element's own attributes: everything but its children,
which the main walk collects (`patternContentShapes`) because they need the
cascade.  `pctRefW`/`pctRefH` are `parseGradDef`'s, for `transform-origin`. -/
def parsePatternDef (attrs : Array Xml.Attr) (hadChildren : Bool) (eventIdx : Nat)
    (pctRefW pctRefH : Fx) : Pat.RawDef :=
  let coord := fun (n : String) => (attr attrs n).bind parsePatCoordFine
  let href := match attr attrs "href" with
    | some v => v
    | none => (attr attrs "xlink:href").getD ByteArray.empty
  let href := let t := trim href; if at' t 0 == 35 then toStr (t.extract 1 t.size) else ""
  let units := fun (n : String) => (attr attrs n).bind fun v =>
    let t := trim v
    if eqAscii t "userSpaceOnUse" then some false
    else if eqAscii t "objectBoundingBox" then some true else none
  { id := match attr attrs "id" with | some v => toStr v | none => "",
    href := if href.length > Pat.maxIdLen then "" else href,
    oBB := units "patternUnits", contentOBB := units "patternContentUnits",
    -- Same "invalid transform draws nothing" rule as `gradientTransform`
    -- (`Pat.build` skips a zero scale).
    transform := match attr attrs "patternTransform" with
      | none => Mat.identity
      | some v =>
        let m := parseTransform v
        let m := if m.a * m.a + m.b * m.b == 0 || m.c * m.c + m.d * m.d == 0 then singularMat else m
        wrapTransformOrigin attrs pctRefW pctRefH m,
    hasTransform := (attr attrs "patternTransform").isSome,
    x := coord "x", y := coord "y", width := coord "width", height := coord "height",
    viewBox := (attr attrs "viewBox").bind fun v =>
      let ns := parseNumberList16 v
      if ns.size == 4 then some (ns.getD 0 0, ns.getD 1 0, ns.getD 2 0, ns.getD 3 0) else none,
    aspect := (attr attrs "preserveAspectRatio").bind parsePreserveAspectRatio,
    hadChildren := hadChildren, eventIdx := eventIdx }

/-- What one pass over the events collects for every kind of referenceable
definition (see "the shape of a defs table" above).

`clips` is one entry per `clipPath` element with a usable `id`, in document
order: the id, and the index of the `open_` event it starts at.  The main walk
meets those events in increasing index order, so it finds an element's slot
with a single monotone cursor, no hashing. -/
structure DefsScan where
  grads : Array Grad.RawDef := #[]
  /-- The rect a `userSpaceOnUse` percentage resolves against: usvg's
  `state.view_box`, which — with no nested `<svg>` in this renderer — is the
  root's `viewBox` if it has one and its own resolved size otherwise.  The
  same rect `applyEffective` uses for `transform-origin`. -/
  pctRef : Grad.PctRef := {}
  clips : Array (String × Nat) := #[]
  /-- T49: the same slots for `mask` elements. -/
  masks : Array (String × Nat) := #[]
  /-- T52: one slot per `marker` element with a usable `id`, same shape as
  `clips`. -/
  markers : Array (String × Nat) := #[]
  /-- Every `<pattern>` element's own attributes, `href` and whether it had
  any children, wherever it appears (see `Doc.patterns`/`patternContent`). -/
  patterns : Array Pat.RawDef := #[]
deriving Inhabited

/-- The one pre-pass.  Collects every gradient element with its direct
`<stop>` children, the viewport percentages resolve against, and a slot for
every `clipPath`, wherever they appear — a definition does not have to be
under `<defs>`, and usvg indeed indexes elements by id across the whole
document.  At most `Grad.maxDefs` gradients, `Grad.maxStops` stops each and
`maxClipPaths` clips; every loop is bounded by `events.size`. -/
def defsScan (events : Array Xml.Event) : DefsScan := Id.run do
  let mut out : Array Grad.RawDef := #[]
  let mut clips : Array (String × Nat) := #[]
  let mut masks : Array (String × Nat) := #[]
  let mut markers : Array (String × Nat) := #[]
  let mut patterns : Array Pat.RawDef := #[]
  let mut pctRef : Grad.PctRef := {}
  -- `pctRef.w`/`.h` in 16.16, for `Grad`/`Pat`'s own geometry; these are the
  -- same rect in plain `Fx`, for `transform-origin` (`Mat.translate`'s scale).
  let mut pctRefW : Fx := 0
  let mut pctRefH : Fx := 0
  let mut seenRoot := false
  let mut depth : Nat := 0
  let mut cur : Option Nat := none
  let mut curDepth : Nat := 0
  -- The `color` in force, one entry per open element, so a stop's
  -- `currentColor` sees what usvg's ancestor walk sees.  `Xml`'s depth cap
  -- keeps this bounded.  `curStopColor` is only ever the open gradient
  -- element's own `stop-color`, which is all `inherit` may reach.
  let mut colors : Array Rgba := #[]
  let mut curStopColor : Option ByteArray := none
  for idx in [0:events.size] do
    match events.getD idx default with
    | .text _ => pure ()
    | .close =>
      depth := depth - 1
      colors := colors.pop
      if cur.isSome && depth == curDepth then
        cur := none
        curStopColor := none
    | .open_ name attrs =>
      let inhColor := colors.back?.getD ⟨0, 0, 0, 255⟩
      -- The root `<svg>`'s own size fixes the percentage reference; a document
      -- whose first element is not `<svg>` has none (`interpret` rejects it).
      if !seenRoot then
        seenRoot := true
        if name == "svg" then
          let r := parseRoot attrs
          let (w, h) := match r.viewBox with
            | some (_, _, vw, vh) => (vw, vh)
            | none => (resolveRootSize r).getD (Fx.ofNat 100, Fx.ofNat 100)
          pctRef := { w := w * 256, h := h * 256 }
          pctRefW := w
          pctRefH := h
      if name == "clipPath" then
        match (attr attrs "id").filter (·.size ≤ maxIdBytes) with
        | some cid => if clips.size < maxClipPaths then clips := clips.push (toStr cid, idx)
        | none => pure ()
      if name == "mask" then
        match (attr attrs "id").filter (·.size ≤ maxIdBytes) with
        | some cid => if masks.size < maxClipPaths then masks := masks.push (toStr cid, idx)
        | none => pure ()
      if name == "marker" then
        match (attr attrs "id").filter (·.size ≤ maxIdBytes) with
        | some mid => if markers.size < maxMarkers then markers := markers.push (toStr mid, idx)
        | none => pure ()
      if name == "pattern" then
        if patterns.size < Pat.maxDefs then
          -- usvg's `has_children`: at least one child *element*, checked
          -- before any validity filtering, so a `display:none` child (or one
          -- this renderer would otherwise skip) still counts.
          let hadChildren : Bool := Id.run do
            for j in [idx + 1 : events.size] do
              match events.getD j default with
              | .text _ => pure ()
              | .open_ _ _ => return true
              | .close => return false
            return false
          patterns := patterns.push (parsePatternDef attrs hadChildren idx pctRefW pctRefH)
      if name == "linearGradient" || name == "radialGradient" then
        if out.size < Grad.maxDefs then
          out := out.push (parseGradDef name attrs pctRefW pctRefH)
          cur := some (out.size - 1)
          curDepth := depth
          curStopColor := attrOrStyle attrs "stop-color"
      else if name == "stop" then
        match cur with
        | some i =>
          if depth == curDepth + 1 then
            let g := out.getD i default
            if g.stops.size < Grad.maxStops then
              let prev := (g.stops.back?).map (·.off) |>.getD 0
              out := out.setIfInBounds i
                { g with stops := g.stops.push (parseStop attrs prev inhColor curStopColor) }
        | none => pure ()
      colors := colors.push (((attrOrStyle attrs "color").bind parseColor).getD inhColor)
      depth := depth + 1
  return { grads := out, pctRef := pctRef, clips := clips, masks := masks, markers := markers,
           patterns := patterns }

/-! ## `text` (T36) -/

/-- `baseline-shift`'s own contribution from *one* element (a `tspan`, or the
`<text>` element for its own direct text — though `textShapes` never actually
calls this for `<text>` itself, see its `bsStack`), as `(px, isSub, isSuper)`:
usvg's `convert_baseline_shift` first tries the value as a CSS
`<length-percentage>` (a percentage of *this* element's own `font-size`,
`fontSize`); if that fails to parse, it falls back to matching `sub`/`super`
literally, and anything else (`baseline`, `inherit`, an invalid token, or no
attribute at all) contributes nothing — the actual `sub`/`super` pixel offset
needs the *leaf* span's font metrics, not available here, so `textShapes`
only counts them (`LeanSvg/Baseline.lean`'s `resolveBaseline16` scales the
count). -/
def baselineShiftDelta (attrs : Array Xml.Attr) (fontSize : Fx) : Fx × Bool × Bool :=
  match attrOrStyle attrs "baseline-shift" with
  | none => (0, false, false)
  | some v =>
    let t := trim v
    match parseNumber t 0 with
    | some (n, j) =>
      match applyFontUnit (t.extract j t.size) n fontSize with
      | some px => (px, false, false)
      | none => (0, false, false)
    | none =>
      if eqAscii t "sub" then (0, true, false)
      else if eqAscii t "super" then (0, false, true)
      else (0, false, false)

/-- The text-layout properties of a resolved `Style`, plus this run's
`baseline-shift` accumulation (`bpx`/`bsub`/`bsup` — from `textShapes`'s
`bsStack`, not from `st`: see `baselineShiftDelta`). -/
def spanPropsOf (st : Style) (bpx : Fx) (bsub bsup : Nat) : Text.SpanProps :=
  { face := Text.pickFace st.fontWeight st.fontItalic,
    weight := st.fontWeight,
    italic := st.fontItalic,
    stretch := st.fontStretch,
    smallCaps := st.fontSmallCaps,
    -- T105: a document family picks its face by weight and style
    family := if st.fontFamily < FontSet.count then st.fontFamily
      else FontSet.count + FontFace.select st.docFaces (st.fontFamily - FontSet.count) st.fontWeight st.fontItalic,
    size := st.fontSize,
    sizeAdjust := st.fontSizeAdjust,
    letterSpacing := st.letterSpacing,
    wordSpacing := st.wordSpacing,
    kerning := st.textKerning,
    anchor := st.textAnchor,
    dominantBaseline := st.dominantBaseline,
    alignmentBaseline := st.alignmentBaseline,
    baselineShiftPx := bpx,
    baselineShiftSub := bsub,
    baselineShiftSuper := bsup,
    textLength := st.ownTextLength,
    lengthAdjustGlyphs := st.ownLengthAdjustGlyphs,
    rtl := st.textRtl,
    bidiOverride := st.ownBidiOverride,
    lang := st.lang }

/-- The per-character position lists of one `text`/`tspan` element, resolved
against that element's own font size and the viewport. -/
def elemPosOf (st : Style) (attrs : Array Xml.Attr) : Text.ElemPos :=
  let horiz := parseTextLenList st.fontSize st.pctRefW st.rootFontSize
  let vert := parseTextLenList st.fontSize st.pctRefH st.rootFontSize
  let rots := (attr attrs "rotate").bind parseStrictNumberList
  { xs := (attr attrs "x").map horiz |>.getD #[],
    ys := (attr attrs "y").map vert |>.getD #[],
    dxs := (attr attrs "dx").map horiz |>.getD #[],
    dys := (attr attrs "dy").map vert |>.getD #[],
    rots := rots.getD #[],
    hasRot := rots.isSome }

/-- The `#id` a `textPath` links to (`href`, else `xlink:href`), if any. -/
def textPathHref (attrs : Array Xml.Attr) : Option String :=
  let href := match attr attrs "href" with
    | some v => v
    | none => (attr attrs "xlink:href").getD ByteArray.empty
  let t := trim href
  if at' t 0 == 35 && t.size ≤ maxIdBytes + 1 then some (toStr (t.extract 1 t.size))
  -- T90: a bare name is taken as an id too (the suite's `with-invalid-path-
  -- and-xlink-href.svg` falls back to `xlink:href="path1"`); usvg rejects it.
  else if t.size > 0 && t.size ≤ maxIdBytes
      && !Image.hasByte t (fun b => b == 35 || b == 47 || b == 58 || b == 46 || b ≤ 32) then
    some (toStr t)
  else none

/-- T90: the table key of a `textPath`'s own SVG 2 `path` attribute: a string
no `id` can equal (it starts with a NUL). -/
def inlinePathKey (v : ByteArray) : String := "\x00" ++ toStr v

/-- T90: the arc-length table a `textPath` follows: its `path` attribute when
that parses to something drawable (SVG 2: `path` wins over `href`), else the
element its `href` links to. -/
def textPathTable (paths : Std.HashMap String TextPath.Table) (attrs : Array Xml.Attr) :
    Option TextPath.Table :=
  match (attr attrs "path").bind (fun v => paths.get? (inlinePathKey v)) with
  | some t => some t
  | none => (textPathHref attrs).bind paths.get?

/-- T50: the arc-length tables of every element some `textPath` links to,
keyed by id, built once per document.  The first element carrying an id wins,
as in usvg's `svgtree`; an id whose element is not a shape, or whose shape
draws nothing, gets no table, which makes the `textPath` invalid.  The shape
is taken with its own `transform` and nothing above it (`resolve_text_flow`),
wrapped by its own `transform-origin` (T96: `resolve_transform`, the same
viewport rect `pctRefW`/`pctRefH` as everywhere else). -/
def textPathTables (events : Array Xml.Event) (pctRefW pctRefH : Fx) :
    Std.HashMap String TextPath.Table := Id.run do
  let mut wanted : Std.HashMap String Bool := {}
  for ev in events do
    match ev with
    | .open_ "textPath" attrs =>
      match textPathHref attrs with
      | some id => wanted := wanted.insert id false
      | none => pure ()
    | _ => pure ()
  let mut out : Std.HashMap String TextPath.Table := {}
  -- T90: inline `path` attributes, in the `<text>`'s own user space.
  for ev in events do
    match ev with
    | .open_ "textPath" attrs =>
      match attr attrs "path" with
      | some v =>
        match (shapeCmds "path" #[⟨"d", v⟩] 0 0 0 { size := 0 }).bind (fun cmds => TextPath.build cmds Mat.identity) with
        | some tbl => out := out.insert (inlinePathKey v) tbl
        | none => pure ()
      | none => pure ()
    | _ => pure ()
  if wanted.isEmpty then return out
  for ev in events do
    match ev with
    | .open_ nm attrs =>
      match attr attrs "id" with
      | some v =>
        let id := toStr v
        if wanted.get? id == some false then
          wanted := wanted.insert id true
          let m := match attr attrs "transform" with
            | some t => wrapTransformOrigin attrs pctRefW pctRefH (parseTransform t)
            | none => Mat.identity
          match (shapeCmds nm attrs 0 0 0 { size := 0 }).bind (fun cmds => TextPath.build cmds m) with
          | some tbl => out := out.insert id tbl
          | none => pure ()
      | none => pure ()
    | _ => pure ()
  return out

/-- `startOffset` in 16.16 px: a length (resolved against the `textPath`'s
own font size), or a percentage of the path's total length.  Anything
unparsable is `0`, usvg's default. -/
def startOffsetOf (st : Style) (tbl : TextPath.Table) (attrs : Array Xml.Attr) : Int :=
  match attr attrs "startOffset" with
  | none => 0
  | some v =>
    let t := trim v
    match parseNumber t 0 with
    | some (n, j) =>
      if at' t j == 37 && j + 1 == t.size then Int.ediv (tbl.total * n) 25600
      else match parseTextLen st.fontSize 0 st.rootFontSize t 0 with
        | some (l, k) => if k == t.size then l * 256 else 0
        | none => 0
    | none => 0

/-- Every element name usvg's `svgtree` recognises while building its DOM
(`svgtree/mod.rs`'s tag-name table): an element with any other name is
dropped, together with its children, before anything downstream — `<switch>`
child selection and `tref` target resolution both need this, since either can
land on an arbitrary node the rest of the renderer never otherwise looks at
(`switch/non-SVG-child.svg`, `tref/link-to-a-non-SVG-element.svg`). -/
def svgTagNames : List String :=
  ["a", "circle", "clipPath", "defs", "ellipse", "feBlend", "feColorMatrix",
   "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting",
   "feDisplacementMap", "feDistantLight", "feDropShadow", "feFlood", "feFuncA",
   "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur", "feImage", "feMerge",
   "feMergeNode", "feMorphology", "feOffset", "fePointLight", "feSpecularLighting",
   "feSpotLight", "feTile", "feTurbulence", "filter", "g", "image", "line",
   "linearGradient", "marker", "mask", "path", "pattern", "polygon", "polyline",
   "radialGradient", "rect", "stop", "svg", "switch", "symbol", "text", "textPath",
   "tref", "tspan", "use"]

/-- `tref`'s `xlink:href`/`href`, a local IRI only (`#id`): the bare id, or
`none` for anything else (a fragment-less or external reference, which usvg's
own `svgtypes::IRI` parser also cannot resolve). -/
def stripFragmentId (bs : ByteArray) : Option ByteArray :=
  if bs.size ≥ 2 && bs.size ≤ maxIdBytes + 1 && at' bs 0 == 35 then some (bs.extract 1 bs.size)
  else none

/-- The event index of the first `.open_` anywhere in the document, of a tag
name `svgtree` would keep (`tref`'s target can be any element, before or
after it, but usvg's tree only holds recognised tag names to begin with —
`resolve_tref_text` runs `parse_tag_name(node)?` before collecting anything),
whose own `id` attribute is exactly `target`; `none` otherwise. usvg looks
this up in the *original* XML tree, so a target inside `defs`, or one a
`<switch>`/`display:none` ancestor would otherwise hide from rendering, still
resolves — matching that means searching the raw event stream here rather
than any id table `interpret`'s main walk builds while it decides what is
actually drawn. -/
def findById (events : Array Xml.Event) (target : ByteArray) : Option Nat := Id.run do
  for j in [0:events.size] do
    match events.getD j default with
    | .open_ nm attrs => if svgTagNames.contains nm && attr attrs "id" == some target then return some j
    | _ => pure ()
  return none

/-- Every character-data byte under the element opened at `events[openIdx]`,
concatenated across all descendants regardless of nesting (`tref`'s "all
character data within the referenced element, including character data
enclosed within additional markup, will be rendered" — usvg just filters the
subtree for text nodes, so a `<tspan>` or any other child contributes its text
but not itself). -/
def collectText (events : Array Xml.Event) (openIdx : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.empty
  let mut depth : Nat := 1
  for j in [openIdx + 1 : events.size] do
    if depth == 0 then break
    match events.getD j default with
    | .open_ _ _ => depth := depth + 1
    | .close => depth := depth - 1
    | .text bs => out := out.append bs
  return out

/-- T90: the SVG 2 layers of a `<text>`'s spans.  `clip-path`, `mask`,
`filter`, `opacity` (and a blend mode or isolation) on a `tspan`/`textPath`
make it a group of its own, like any other element (`should_isolate`); usvg
does not (resvg's `svg2-changelog.md` lists it as a gap). -/
structure SpanLayers where
  /-- Each layer-owning span's style and its runs' font-metric box. -/
  owners : Array (Style × Option Box) := #[]
  /-- Per output shape, the owners it sits in, outermost first. -/
  chains : Array (Array Nat) := #[]
deriving Inhabited

def spanNeedsLayer (st : Style) : Bool :=
  st.ownOpacity != opacityOne || st.blend != .normal || st.isolate
    || st.clipRef.isSome || st.maskRef.isSome
    || match st.filterRaw with
      | some v => !(eqAscii (trim v) "none")
      | none => false

/-- T90: each decoration's size from the style that declared it. -/
def decorSizes (styles : Array Style) (sp : Text.SpanProps) : Text.SpanProps :=
  let sz := fun (i : Option Nat) => (i.map fun k => (styles.getD k default).fontSize).getD 0
  { sp with underlineSize := sz sp.underlineIdx, overlineSize := sz sp.overlineIdx,
            throughSize := sz sp.throughIdx }

/-- Give every style index below `n` a chain, `c` for the new ones. -/
def padChains (a : Array (Array Nat)) (n : Nat) (c : Array Nat) : Array (Array Nat) := Id.run do
  let mut a := a
  for _ in [a.size : n] do
    a := a.push c
  return a

/-- Turn the `<text>` element opened at `events[idx]` into shapes.

The subtree is walked here rather than by `interpret`'s main loop because text
layout is not per-element: whitespace collapsing, character positions and
anchored chunks all need the whole element at once.  `interpret` therefore
calls this once and then skips the subtree, which keeps its own edit to a
single branch.

`applyEff` is `interpret`'s own four-layer cascade, passed in so `tspan`
styling goes through exactly the same CSS resolution as everything else.
`tref` is converted to a `tspan` the same way, plus one synthetic text node
resolved from its `href` (`stripFragmentId`/`findById`/`collectText` above);
its own children, if any, are dropped unread, exactly as usvg drops them once
it has taken the tref's own attributes (`with-a-title-child.svg`,
`with-text.svg`).  Other elements besides `tspan`, `a` (which SVG says to
treat as a `tspan` here), `tref` and `textPath` are dropped together with
their character data, as usvg's tree builder does.  A `textPath` that is a
direct child of the `<text>` element becomes `Text.Ev.openPath` when it links
to an entry of `paths` (T50), and a non-rendering span otherwise (usvg skips an
invalid one but its characters keep their position-list slots); one anywhere
else is dropped whole, as usvg's tree builder does.

Only `Text.SpanProps` and an index into a local table of resolved styles cross
into `LeanSvg/Text.lean`; the styles come back attached to whole runs of
glyphs, which become ordinary `Shape`s.  `evenOdd` is forced off because
`fill-rule` does not apply to text (SVG 2 §text-rendering-order), and `ctm` is
the `<text>` element's, because `transform` on a `tspan` is not a thing. -/
def textShapes (applyEff : Style → Array Xml.Attr → Array Css.ElemInfo → Style)
    (events : Array Xml.Event) (idx : Nat) (textStyle : Style)
    (chain : Array Css.ElemInfo) (budget : Nat)
    (paths : Std.HashMap String TextPath.Table) (ancestors : Array Style) :
    Array Shape × Nat × Option Box × SpanLayers × Array String := Id.run do
  let textAttrs := match events.getD idx default with
    | .open_ _ a => a
    | _ => #[]
  let mut styles : Array Style := #[]
  -- T102: a `textPath` under a vertical `writing-mode` is laid out too
  -- (`Text.layout`'s path branch); before, it was dropped whole.
  let mut evs : Array Text.Ev := #[Text.Ev.open_ (elemPosOf textStyle textAttrs)]
  let mut warns : Array String := #[]
  -- `ancestors` is the outer walk's own style stack at the point `<text>` was
  -- reached, i.e. everything *outside* it (`<g>`, `<svg>`, ...): usvg's
  -- decoration search walks from a tspan up through the document root, not
  -- just up to `<text>` (`text-decoration/all-types-nested.svg` sets it on
  -- two ancestor `<g>`s, neither of which is `<text>` or a `tspan`), so it
  -- has to be part of the same stack `textShapes` searches.
  let mut stStack : Array Style := ancestors.push textStyle
  let mut chStack : Array (Array Css.ElemInfo) := #[chain]
  let mut ccStack : Array Nat := #[0]
  let mut rendStack : Array Bool := #[true]
  -- `baseline-shift`'s own accumulator (T54): seeded at `(0, 0, 0)` for the
  -- `<text>` element itself and pushed to only by a `tspan`'s own attribute
  -- — deliberately not derived from `Style`, which is what keeps a
  -- `baseline-shift` set on `<text>` itself, or on some non-`tspan` ancestor
  -- reached through `textStyle`, from ever contributing.  See
  -- `LeanSvg/Baseline.lean`'s module docs and `baselineShiftDelta`.
  let mut bsStack : Array (Fx × Nat × Nat) := #[(0, 0, 0)]
  -- `resolve_decoration`: *whether* a kind is drawn at all is `.any` over
  -- every ancestor's own value, all the way to the document root
  -- (`text-decoration/all-types-nested.svg` sets it on two `<g>`s, neither of
  -- them `<text>` or a `tspan`). *Which* style colours it is a separate,
  -- shorter search: nearest declaring element from this run up, but never
  -- past `<text>` itself — usvg's loop condition is "declares it, OR is the
  -- `<text>` element", so an outer `<g>` that made the kind active is never
  -- consulted for colour if `<text>` (or a tspan below it) does not also
  -- redeclare it (`text-decoration/style-resolving-2.svg`: `<g>` sets
  -- line-through and fill=stroke=red, but the line comes out in `<text>`'s
  -- own yellow/green, not red).  Shared by every run, whether its text comes
  -- from a `.text` node or a `tref`'s resolved target.
  let resolveDecor := fun (styles : Array Style) (stk : Array Style) => Id.run do
    let mut styles := styles
    let underlineActive := stk.any (·.ownUnderline)
    let overlineActive := stk.any (·.ownOverline)
    let throughActive := stk.any (·.ownLineThrough)
    let mut underlineIdx : Option Nat := none
    let mut overlineIdx : Option Nat := none
    let mut throughIdx : Option Nat := none
    if underlineActive || overlineActive || throughActive then
      for k in [0:stk.size] do
        let j := stk.size - 1 - k
        if j ≥ ancestors.size then
          let s := stk.getD j default
          let atText := j == ancestors.size
          if underlineActive && underlineIdx.isNone && (s.ownUnderline || atText) then
            styles := styles.push s; underlineIdx := some (styles.size - 1)
          if overlineActive && overlineIdx.isNone && (s.ownOverline || atText) then
            styles := styles.push s; overlineIdx := some (styles.size - 1)
          if throughActive && throughIdx.isNone && (s.ownLineThrough || atText) then
            styles := styles.push s; throughIdx := some (styles.size - 1)
    return (styles, underlineIdx, overlineIdx, throughIdx)
  -- T90: the spans that need a layer of their own (`SpanLayers`), the chain
  -- of them open at each nesting level, and each run style's chain.
  let mut owners : Array Style := #[]
  let mut layStack : Array (Array Nat) := #[#[]]
  let mut chainOf : Array (Array Nat) := #[]
  let mut skip : Nat := 0
  let mut depth : Nat := 1
  for j in [idx + 1 : events.size] do
    if depth == 0 then break
    match events.getD j default with
    | .close =>
      depth := depth - 1
      if skip > 0 then skip := skip - 1
      else
        evs := evs.push .close
        layStack := layStack.pop
        stStack := stStack.pop
        chStack := chStack.pop
        ccStack := ccStack.pop
        rendStack := rendStack.pop
        bsStack := bsStack.pop
    | .open_ nm attrs =>
      depth := depth + 1
      if skip > 0 then skip := skip + 1
      else if nm == "tspan" || nm == "a" || (nm == "textPath" && depth == 2) then
        let isFirst := ccStack.back?.getD 0 == 0
        ccStack := match ccStack.back? with
          | some c => ccStack.pop.push (c + 1)
          | none => ccStack
        let info := Css.buildElemInfo nm (attrs.map (fun a => (a.name, toStr a.value))) isFirst
        let ch := (chStack.back?.getD #[]).push info
        let st := applyEff (stStack.back?.getD default) attrs ch
        stStack := stStack.push st
        chStack := chStack.push ch
        ccStack := ccStack.push 0
        let lc := layStack.back?.getD #[]
        if spanNeedsLayer st then
          layStack := layStack.push (lc.push owners.size)
          owners := owners.push st
        else layStack := layStack.push lc
        -- usvg's `is_visible_element`: `display:none` or failed conditional
        -- processing (`systemLanguage`, ...) drops a span's glyphs while its
        -- characters keep their slots in the position lists.
        let (dpx, dsub, dsup) := baselineShiftDelta attrs st.fontSize
        let (bpx, bsub, bsup) := bsStack.back?.getD (0, 0, 0)
        bsStack := bsStack.push
          (bpx + dpx, bsub + (if dsub then 1 else 0), bsup + (if dsup then 1 else 0))
        let rend := (rendStack.back?.getD true) && !isDisplayNone attrs && passesConditions attrs
        if nm == "textPath" then
          -- usvg reads no `x`/`y`/`dx`/`dy` from a `textPath`, only `rotate`
          let ep := elemPosOf st attrs
          let ep : Text.ElemPos := { rots := ep.rots, hasRot := ep.hasRot }
          let side := (attr attrs "side").map (fun v => eqAscii (trim v) "right")
          match (textPathTable paths attrs).map (fun t => if side == some true then t.reverse else t) with
          | some tbl =>
            rendStack := rendStack.push rend
            let m := textStyle.ctm
            evs := evs.push (Text.Ev.openPath ep tbl (startOffsetOf st tbl attrs)
              (TextPath.accuracyFor m.a m.b m.c m.d))
          | none =>
            rendStack := rendStack.push false
            evs := evs.push (Text.Ev.open_ ep)
        else
          rendStack := rendStack.push rend
          evs := evs.push (Text.Ev.open_ (elemPosOf st attrs))
      else if nm == "tref" then
        -- `resolve_tref_text`: `href` (falling back to `xlink:href`) must be
        -- a bare local IRI; the target is looked up by id anywhere in the
        -- document and every character-data byte under it concatenated.
        -- Converted to a `tspan` carrying the tref's own attributes plus one
        -- synthetic text node — its own children are never visited at all
        -- (`with-a-title-child.svg`, `with-text.svg`), which is why this
        -- branch ends by skipping them exactly like an unrecognised element.
        let href := match attr attrs "href" with
          | some v => some v
          | none => attr attrs "xlink:href"
        let targetText : ByteArray :=
          match href.bind stripFragmentId with
          | some tid => match findById events tid with
            | some tIdx => collectText events tIdx
            | none => ByteArray.empty
          | none => ByteArray.empty
        let isFirst := ccStack.back?.getD 0 == 0
        ccStack := match ccStack.back? with
          | some c => ccStack.pop.push (c + 1)
          | none => ccStack
        let info := Css.buildElemInfo "tspan" (attrs.map (fun a => (a.name, toStr a.value))) isFirst
        let ch := (chStack.back?.getD #[]).push info
        let st := applyEff (stStack.back?.getD default) attrs ch
        evs := evs.push (Text.Ev.open_ (elemPosOf st attrs))
        if targetText.size > 0 then
          let (styles', underlineIdx, overlineIdx, throughIdx) := resolveDecor styles (stStack.push st)
          styles := styles'.push st
          chainOf := padChains chainOf styles.size (layStack.back?.getD #[])
          let selfIdx := styles.size - 1
          let (bpx, bsub, bsup) := bsStack.back?.getD (0, 0, 0)
          let sp := spanPropsOf st bpx bsub bsup
          -- T119: matplotlib's STIXNonUnicode letters → Unicode (`StixNonUnicode`)
          let targetText := if StixNonUnicode.isFamily st.fontFamilyRaw then StixNonUnicode.remap targetText else targetText
          evs := evs.push
            (Text.Ev.text targetText st.spacePreserve selfIdx
              (decorSizes styles
                { sp with underlineIdx, overlineIdx, throughIdx })
              ((rendStack.back?.getD true) && !isDisplayNone attrs && passesConditions attrs && st.fontSize > 0))
          if (rendStack.back?.getD true) && !isDisplayNone attrs && st.fontSize > 0 && !st.fontAvailable then
            warns := Warn.add warns (Warn.missingFont st.fontFamilyRaw)
          if (rendStack.back?.getD true) && !isDisplayNone attrs && st.fontSize < 0 then
            warns := Warn.add warns Warn.negativeFontSize
        evs := evs.push .close
        skip := skip + 1
      else skip := skip + 1
    | .text bs =>
      if skip == 0 then
        let st := stStack.back?.getD default
        let (styles', underlineIdx, overlineIdx, throughIdx) := resolveDecor styles stStack
        styles := styles'.push st
        chainOf := padChains chainOf styles.size (layStack.back?.getD #[])
        let selfIdx := styles.size - 1
        let (bpx, bsub, bsup) := bsStack.back?.getD (0, 0, 0)
        let sp := spanPropsOf st bpx bsub bsup
        -- T119: matplotlib's STIXNonUnicode letters → Unicode (`StixNonUnicode`)
        let bs := if StixNonUnicode.isFamily st.fontFamilyRaw then StixNonUnicode.remap bs else bs
        evs := evs.push
          (Text.Ev.text bs st.spacePreserve selfIdx
            (decorSizes styles
                { sp with underlineIdx, overlineIdx, throughIdx })
            -- usvg's zero-`font-size` guard is per text node (the span's own
            -- size), not inherited: `<text font-size="0"><tspan
            -- font-size="40">` still draws the tspan.  A `font-family` that
            -- does not resolve to an embedded font draws in Noto Sans and
            -- reports a warning (T98; usvg's `process_chunk` draws nothing).
            ((rendStack.back?.getD true) && st.fontSize > 0))
        if (rendStack.back?.getD true) && st.fontSize > 0 && !st.fontAvailable && (trim bs).size > 0 then
          warns := Warn.add warns (Warn.missingFont st.fontFamilyRaw)
        -- T102: a negative `font-size` draws nothing (as usvg) and says so.
        if (rendStack.back?.getD true) && st.fontSize < 0 && (trim bs).size > 0 then
          warns := Warn.add warns Warn.negativeFontSize
  -- T96: under a large scale (`transform="scale(100)"` on tiny text) an
  -- outline rounded to `Fx` user units is visibly jagged, so it is laid out
  -- `outK` times larger and drawn through `ctm · scale(1 / outK)`; only for
  -- plain paints, whose meaning does not depend on the user-space scale.
  let m := textStyle.ctm
  let sc := Nat.sqrt (Nat.sqrt (m.a.natAbs * m.a.natAbs + m.b.natAbs * m.b.natAbs)
    * Nat.sqrt (m.c.natAbs * m.c.natAbs + m.d.natAbs * m.d.natAbs))
  let plain := fun (p : Paint) => match p with | .none | .solid _ => true | _ => false
  let outK : Nat := Id.run do
    let mut k := 1
    for _ in [0:8] do
      if 2 * k * 65536 ≤ sc then k := 2 * k
    return if k < 16 || !(styles.all fun s => plain s.fill && plain s.stroke) then 1 else k
  let (placed, used, mbox, sbox) :=
    Text.layout evs textStyle.spacePreserve budget textStyle.writingMode outK
      (textStyle.docFaces.map fun f => (some f.font, f.coverage))
  let outCtm := if outK == 1 then textStyle.ctm
    else textStyle.ctm.mul (Mat.scale16 (65536 / outK) (65536 / outK))
  let mut out : Array Shape := #[]
  let mut chains : Array (Array Nat) := #[]
  let mut oboxes : Array (Option Box) := owners.map fun _ => none
  for k in [0:sbox.size] do
    for o in chainOf.getD k #[] do
      oboxes := oboxes.modify o (Box.union · (sbox.getD k none))
  for p in placed do
    let st := styles.getD p.styleIdx textStyle
    if st.visible then
      -- `text-rendering` of the `<text>` element, not `shape-rendering`, decides
      -- glyph antialiasing (usvg's `text/flatten.rs::resolve_rendering_mode`;
      -- `painting/shape-rendering/optimizeSpeed-on-text.svg`).
      let st := if outK == 1 then st else
        { st with strokeWidth := st.strokeWidth * outK, dashes := st.dashes.map (· * outK),
                  dashOffset := st.dashOffset * outK }
      -- T116: a synthetic-bold outline is stroked in the fill's paint (Skia's
      -- fake bold), under the run's own fill and stroke
      let st := if p.boldSize == 0 then st else
        { st with stroke := st.fill, strokeOpacity := st.fillOpacity, strokeCtx := st.fillCtx,
                  strokeWidth := Synth.boldWidth p.boldSize sc * outK, fill := .none, fillCtx := none,
                  cap := .butt, join := .miter, miterLimit := 1024, dashes := #[], dashOffset := 0 }
      out := out.push ⟨p.cmds, { st with evenOdd := false, ctm := outCtm, crisp := textStyle.textCrisp }, false, none, none⟩
      chains := chains.push (chainOf.getD p.styleIdx #[])
  -- T81: `mbox` is usvg's font-metric bounding box (`Text.layout`'s doc
  -- comment), not the glyph outlines' -- what a `filter`/`mask`/
  -- `clipPathUnits="objectBoundingBox"` on this `<text>` actually sizes
  -- against.
  return (out, used, mbox, ⟨owners.zip oboxes, chains⟩, warns)

/-! ## `pattern` content

One `<pattern>` element's own children, collected independently of where (or
whether) anything ends up using them — `Pat.Defs.build`'s `href` chain
decides that, by raw index, from `Pat.RawDef.hadChildren` alone.  This
mirrors `textShapes` just above: a bounded walk over a subrange of `events`,
reusing `applyEffective` for the cascade, because pattern content needs
exactly the same style resolution as the main document, just rooted
differently (a fresh `ctm`, no inherited `clip-path` chain) and written to its
own array instead of `Doc.nodes`.

Two accepted gaps, both silent: `clip-path` on a content element or group
(parsed into `Style.clipRef` as usual, but nothing here ever adds it to
`Doc.uses`, so it is never applied), and `switch`/a nested `<pattern>` as
content (skipped like any other element this function does not know, which
for a nested `<pattern>` is correct regardless — it is not a drawable child,
and it still gets its own top-level slot and content array from the loop
that calls this function once per raw index). -/
def patternContentShapes (applyEff : Style → Array Xml.Attr → Array Css.ElemInfo → Style)
    (events : Array Xml.Event) (idx : Nat) (rootStyle : Style) (budget : Nat) (fine : Bool := false) :
    Array Node × Nat := Id.run do
  let mut nodes : Array Node := #[]
  let mut stStack : Array Style := #[rootStyle]
  let mut chStack : Array (Array Css.ElemInfo) := #[#[]]
  let mut ccStack : Array Nat := #[0]
  let mut layerOpen : Array Bool := #[]
  let mut layerDepth : Nat := 0
  let mut skip : Nat := 0
  let mut depth : Nat := 1
  let mut budget := budget
  -- The "does this element need its own layer" decision, shared by the
  -- `g`/shape branches below (`interpret`'s own bottom logic, T22).
  let layerDecision := fun (st : Style) =>
    let needs := st.ownOpacity != opacityOne || st.blend != .normal || st.isolate
    let layered := needs && layerDepth < maxLayerDepth
    let st' := if needs && !layered then { st with opacity := mulOpacity st.opacity st.ownOpacity }
               else st
    (st', layered)
  for j in [idx + 1 : events.size] do
    if depth == 0 then break
    match events.getD j default with
    | .text _ => pure ()
    | .close =>
      depth := depth - 1
      if skip > 0 then skip := skip - 1
      else
        if layerOpen.back?.getD false then
          nodes := nodes.push .groupEnd
          layerDepth := layerDepth - 1
        stStack := stStack.pop
        chStack := chStack.pop
        ccStack := ccStack.pop
        layerOpen := layerOpen.pop
    | .open_ nm attrs =>
      depth := depth + 1
      if skip > 0 then skip := skip + 1
      else if isDisplayNone attrs || !passesConditions attrs then skip := 1
      else
        let isFirst := ccStack.back?.getD 0 == 0
        ccStack := match ccStack.back? with
          | some c => ccStack.pop.push (c + 1)
          | none => ccStack
        let info := Css.buildElemInfo nm (attrs.map (fun a => (a.name, toStr a.value))) isFirst
        let chain := (chStack.back?.getD #[]).push info
        let parent := stStack.back?.getD rootStyle
        if nm == "text" then
          -- `<text>` bypasses the layer machinery below exactly as
          -- `interpret`'s own `<text>` branch does: it opens and closes its
          -- own layer right here, because `textShapes` needs the style
          -- *before* the layer decision folds opacity into it.
          let st := applyEff parent attrs chain
          let (st', layered) := layerDecision st
          if layered then
            nodes := nodes.push (.groupBegin { opacity := st'.ownOpacity, blend := st'.blend, isolate := st'.isolate })
            layerDepth := layerDepth + 1
          let (shs, used, _, _, _) := textShapes applyEff events j st' chain budget {} stStack
          budget := budget - used
          nodes := nodes ++ shs.map Node.shape
          if layered then nodes := nodes.push .groupEnd
          skip := 1
        else if nm == "g" || nm == "use" then
          -- T104: `Use.expand` has already copied a `use`'s target inside it,
          -- so it is a `g` whose `x`/`y` translate after its own transform
          -- (as in `interpret`).  A symbol's generated viewport clip is
          -- ignored here like every content `clip-path`.
          let st := applyEff parent attrs chain
          let st := if nm == "g" then st else
            let len := fun (n : String) (ref : Fx) =>
              (((attr attrs n).bind parseLengthOrPercent).map (resolvePct · ref)).getD 0
            let tr := Mat.translate (len "x" st.pctRefW) (len "y" st.pctRefH)
            { st with ctm := st.ctm.mul tr, ownMat := st.ownMat.mul tr }
          let (st', layered) := layerDecision st
          if layered then
            nodes := nodes.push (.groupBegin { opacity := st'.ownOpacity, blend := st'.blend, isolate := st'.isolate })
            layerDepth := layerDepth + 1
          stStack := stStack.push st'
          chStack := chStack.push chain
          ccStack := ccStack.push 0
          layerOpen := layerOpen.push layered
        else if isShape nm then
          -- A shape has no valid children of its own (SVG 1.1's basic
          -- shapes are never containers), so its subtree — if it has one at
          -- all — is dropped the same way an unknown element's is, below.
          let st := applyEff parent attrs chain
          let (st', layered) := layerDecision st
          if layered then
            nodes := nodes.push (.groupBegin { opacity := st'.ownOpacity, blend := st'.blend, isolate := st'.isolate })
            layerDepth := layerDepth + 1
          -- T108: under `patternContentUnits="objectBoundingBox"` (`fine`) a
          -- fill-only shape whose paint does not live in user units is lexed
          -- on the 16.16 grid, as `objectBoundingBox` mask content is (T49):
          -- `0.1` at `Fx`'s 1/256 is a quarter pixel off on a 160-unit box.
          let fine := fine && st'.stroke matches .none &&
            (match st'.fill with
             | .solid _ => true
             | .gradient i _ => (st'.defs.defs.getD i default).oBB
             | _ => false) && (shapeCmds16 nm attrs).isSome
          let (cmdsO, st') := if fine then
              (shapeCmds16 nm attrs, { st' with ctm := st'.ctm.mul (Mat.mk' 256 0 0 256 0 0) })
            else (shapeCmds nm attrs st'.fontSize st'.pctRefW st'.pctRefH st'.rootFontSize, st')
          match cmdsO with
          | some cmds => if st'.visible && cmds.size > 0 then nodes := nodes.push (.shape ⟨cmds, st', false, none, none⟩)
          | none => pure ()
          if layered then nodes := nodes.push .groupEnd
          skip := 1
        else
          skip := 1
  return (nodes, budget)

/-- T108: usvg's `fix_recursive_patterns` (`svgtree/parse.rs`), on the
collected content instead of the attributes.  For each pattern `p` in
document order, a content shape whose fill names `p` itself becomes `none`;
one naming another pattern `l` instead cuts every shape in `l`'s *own*
content that names `p` back.  Cut paint is `none`, never the `url()`
fallback, and fill and stroke are done in two separate passes, as there.  So
the first pattern of a mutual pair keeps its reference (`recursive-on-child`)
and a self-reference paints nothing (`self-recursive`); `patternFuel` still
bounds longer cycles.  usvg compares ids, not elements, hence `pt.ids`. -/
def fixRecursivePatterns (pt : Pat.Defs) (pc : Array (Array Node)) : Array (Array Node) :=
  let ids := pt.ids
  let refId := fun (p : Paint) => match p with
    | .pattern j => some (ids.getD j "")
    | _ => none
  let pass := fun (pc : Array (Array Node)) (get : Shape → Paint) (cut : Shape → Shape) => Id.run do
    let mut pc := pc
    for p in [0:pc.size] do
      let pid := ids.getD p ""
      if pid.isEmpty then continue
      for k in [0:(pc.getD p #[]).size] do
        let .shape s := (pc.getD p #[]).getD k .groupEnd | continue
        let some lid := refId (get s) | continue
        if lid == pid then
          pc := pc.modify p (·.setIfInBounds k (.shape (cut s)))
        else
          -- `element_by_id`: the first pattern with that id.
          let some l := pt.lookup lid | continue
          for k2 in [0:(pc.getD l #[]).size] do
            let .shape s2 := (pc.getD l #[]).getD k2 .groupEnd | continue
            if refId (get s2) == some pid then
              pc := pc.modify l (·.setIfInBounds k2 (.shape (cut s2)))
    return pc
  let pc := pass pc (·.style.fill) fun s => { s with style := { s.style with fill := .none } }
  pass pc (·.style.stroke) fun s => { s with style := { s.style with stroke := .none } }

/-- What the shapes under an element become (T20): rendered, nothing (under
`defs`), or children of the `clipPath` with this table index. -/
inductive ClipMode where
  | render
  | defs
  | clip (k : Nat)
  /-- T52: everything under a `<marker>` element, at table index `k`.  Behaves
  like `.render` (shapes get a `shapeNode`, containers may layer, nested
  `marker-start`/`-mid`/`-end` still resolve) except that every `Node` this
  subtree would emit goes into `markerNodes[k]` instead of the document's
  `nodes`, becoming `Doc.markers[k].content` once the `<marker>` element
  itself closes.  A `<marker>` nested inside another (unusual, but not
  disallowed) gets its own fresh `k` and is collected into its own slot,
  independent of the marker it is textually inside. -/
  | markerDef (k : Nat)
deriving Inhabited

/-- The mode of a `g`/`switch` opened in this mode: a `g` inside a `clipPath`
is not a valid child, so usvg skips it and its subtree (`convert_clip_path_
elements`); it is descended here in `defs` mode so that a `clipPath` inside it
is still collected, which keeps it referenceable by id as in usvg.  A `g`
inside a `<marker>` stays in that marker's mode, so its whole subtree keeps
routing to the same `markerNodes` slot (T52). -/
def ClipMode.inner : ClipMode → ClipMode
  | .clip _ => .defs
  | m => m

/-- Is content in this mode actually drawn?  Only rendered content can open a
compositing layer: a `clipPath` child contributes a fill and nothing else, and
what is under `defs` is not drawn at all, so usvg never asks `should_isolate`
about either (T20 × T22).  Marker content is drawn too, once per instance
(T52), so it counts as rendered here as well. -/
def ClipMode.isRender : ClipMode → Bool
  | .render => true
  | .markerDef _ => true
  | _ => false

/-- Per-element state kept in lockstep with the style stack (T20). -/
structure Frame where
  mode : ClipMode := .render
  /-- The object bounding box of this element's rendered content so far, in
  its own user space (children's boxes come through their own transforms). -/
  bbox : Option Box := none
  /-- This element's `clip-path` use, if any: the box goes there on close. -/
  useSlot : Option Nat := none
  /-- Whether a box is wanted at all: this element or an ancestor has a
  `clip-path`.  Everything else skips the flattening the box costs. -/
  want : Bool := false
  /-- T49: this element's `mask` use; the box goes there on close, as above. -/
  maskUse : Option Nat := none
  /-- T49: this element *is* the `mask` with this table index; its close ends
  the content node stream. -/
  maskSlot : Option Nat := none
  /-- T49: inside a `maskContentUnits="objectBoundingBox"` mask, where
  coordinates are fractions of a box and a fill-only shape is lexed on the
  16.16 grid, as a `clipPath` child is (`ClipChild.fine`). -/
  fine : Bool := false
  /-- Set on a shape element's own frame: usvg's `convert_element_impl` never
  recurses into a `rect`/`circle`/.../`path`'s children (only `g`/`svg`/
  `switch` call `convert_children`), so any XML children of a shape are not
  part of the render tree at all, not even as siblings drawn on top of it.
  Checked at the very top of the next `.open_`, before any other branch, so
  such a child is dropped exactly like a `switch`'s non-selected child. -/
  isShapeLeaf : Bool := false
  /-- T51: the index in `nodes` of this element's `groupBegin` when it opened
  a layer for a `filter`, patched with the resolved filters on close. -/
  filterAt : Option Nat := none
  /-- T51: whether that layer has a reason besides the filter. -/
  filterOnly : Bool := false
  /-- T85: this `use`'s `ctxUses` slot; the box goes there on close. -/
  ctxUse : Option Nat := none
  /-- T92: the stroke bounding box of this element's rendered content so far
  (`bbox`'s counterpart), kept only while `wantS`: this element or an
  ancestor has a `stroke-box` basic-shape `clip-path`. -/
  sbox : Option Box := none
  wantS : Bool := false
deriving Inhabited

/-- T92: whether clip use `slot` is a basic shape on the `stroke-box`. -/
def strokeShapeUse (uses : Array ClipUse) (slot : Option Nat) : Bool :=
  match slot.bind (fun k => uses[k]?) with
  | some u => match u.shape with
    | some (spec, _) => spec.ref == .stroke
    | none => false
  | none => false

/-- T92: a shape's stroke bounding box, Chromium's `stroke-box`: the bounds of
the exact stroke outline (`strokePoly`, without dashes) joined with the fill
box; just the fill box when there is no stroke. -/
def strokeBoxOf (st : Style) (cmds : Array PathCmd) : Option Box := Id.run do
  let mut b := cmdsBox cmds
  let painted := match st.stroke with | .none => false | _ => true
  if !painted || st.strokeWidth ≤ 0 then return b
  let ss : StrokeStyle := ⟨st.strokeWidth, st.cap, st.join, st.miterLimit⟩
  for poly in flatten Mat.identity cmds do
    for ring in strokePoly ss poly #[] do
      for p in ring do
        b := Box.cover b p
  return b

/-- `Use.expand` must not let `use` nest deeper than compositing layers may. -/
theorem use_maxDepth_le : Use.maxDepth ≤ maxLayerDepth := by decide

/-- The rect percentages resolve against at the root, as `defsScan` computes
it: the root's `viewBox` size, else its own resolved size (T47 hands it to
`Use.expand`). -/
def rootViewport (events : Array Xml.Event) : Fx × Fx :=
  match events.find? (fun e => match e with | .open_ _ _ => true | _ => false) with
  | some (.open_ "svg" attrs) =>
    let r := parseRoot attrs
    match r.viewBox with
    | some (_, _, vw, vh) => (vw, vh)
    | none => (resolveRootSize r).getD (Fx.ofNat 100, Fx.ofNat 100)
  | _ => (Fx.ofNat 100, Fx.ofNat 100)
/-- A `mask` link that `fixRecursiveMaskLinks` may cut: a `mask` element's own
`mask` attribute, or a use. -/
inductive MaskLink where
  | self_ (k : Nat)
  | use (u : Nat)
deriving Inhabited

/-- Record a rendered element's `mask` as a use (like `addClipUse`) and list it
as a link held inside every `mask` element it sits in (`openMasks`). -/
def addMaskUse (ref : Option String) (ctm : Mat) (uses : Array MaskUse)
    (holders : Array (Array MaskLink)) (openMasks : Array Nat) :
    Array MaskUse × Array (Array MaskLink) × Option Nat :=
  match ref with
  | none => (uses, holders, none)
  | some id =>
    let u := uses.size
    (uses.push ⟨id, none, ctm, none⟩,
     openMasks.foldl (fun hs k => hs.modify k (·.push (.use u))) holders, some u)

/-- usvg's `fix_recursive_links(EId::Mask, AId::Mask)`: while some `mask`
element `M` has, among its descendants (itself included, in document order), a
link to `M`, or a link to a mask `L` one of whose descendants links to `M`, set
the first such link to `none`.  `holders[m]` lists the links under mask `m` in
document order.  Each round removes a link, so `total + 1` rounds suffice. -/
def fixRecursiveMaskLinks (masks : Array MaskEntry) (uses : Array MaskUse)
    (holders : Array (Array MaskLink)) : Array MaskEntry × Array MaskUse := Id.run do
  let target := fun (ms : Array MaskEntry) (us : Array MaskUse) (l : MaskLink) => match l with
    | .self_ k => (ms.getD k default).selfMask
    | .use u => (us.getD u default).entry
  let total := holders.foldl (fun n h => n + h.size) 0
  let mut ms := masks
  let mut us := uses
  for _ in [0:total + 1] do
    let found : Option MaskLink := Id.run do
      for m in [0:ms.size] do
        for l in holders.getD m #[] do
          match target ms us l with
          | none => pure ()
          | some t =>
            if t == m then return some l
            for l2 in holders.getD t #[] do
              if target ms us l2 == some m then return some l2
      return none
    match found with
    | none => break
    | some (.self_ k) => ms := ms.modify k fun e => { e with selfMask := none }
    | some (.use u) => us := us.modify u fun x => { x with entry := none }
  return (ms, us)

/-- T63: an `<image>` element's rectangle and placed pixels, or `none` when it
draws nothing: no embedded (`data:`) PNG/JPEG that decodes, one that would
overrun the `budget` of decoded pixels left, or an empty viewport.  Also the
budget left afterwards.  Lengths as `shapeCmds` resolves them; a `width`/`height` that does
not parse (`auto`, say) is absent, i.e. taken from the image. -/
def imageShape (attrs : Array Xml.Attr) (st : Style) (budget : Nat) :
    Option (Array PathCmd × Image.Placed × Option (Fx × Fx × Fx × Fx)) × Nat :=
  let href := (attr attrs "href").orElse (fun _ => attr attrs "xlink:href")
  -- Past the document's pixel budget nothing more is even decoded, and the
  -- first image that overruns it spends it all, so at most one decode is
  -- ever thrown away.
  match if budget == 0 then none else href.bind Image.load with
  | none => (none, budget)
  | some pix =>
    if pix.w * pix.h > budget then (none, 0) else
    let lx := fun (n : String) => (attr attrs n).bind (parseTextLenAll st.fontSize st.pctRefW st.rootFontSize)
    let ly := fun (n : String) => (attr attrs n).bind (parseTextLenAll st.fontSize st.pctRefH st.rootFontSize)
    let ar := match attr attrs "preserveAspectRatio" with
      | some v => Viewport.parseAspectRatio v
      | none => {}
    (Image.place pix ((lx "x").getD 0) ((ly "y").getD 0) (lx "width") (ly "height") ar
      st.imageRendering, budget - pix.w * pix.h)

/-- T84: an `<image>` of an SVG document (`LeanSvg/SvgImage.lean`) with source
`src`: its entry, the elements it spends of the `elems` left, and the viewport
as a clip for `slice`.  `depth` is the element's nesting and `layerDepth` the
layers above its content, both shared with the sub-document.  `none` when it
draws nothing: over a budget, a sub-document that does not parse, or an empty
size. -/
def svgImageEntry (attrs : Array Xml.Attr) (st : Style) (src : ByteArray) (elems depth layerDepth : Nat) :
    Option (SvgImage.Entry × Nat × Option (Fx × Fx × Fx × Fx)) := do
  let evs ← match Xml.parse src with
    | .ok e => some e
    | .error _ => none
  let (n, d) := SvgImage.stats evs
  if n > elems || depth + d > Xml.maxDepth then none
  let r ← match evs.find? (fun e => match e with | .open_ _ _ => true | _ => false) with
    | some (.open_ "svg" a) => some (parseRoot a)
    | _ => none
  let (sw, sh) ← resolveRootSize r
  let rootMat := match r.viewBox with
    | some vb => (Viewport.viewBoxTransform vb r.aspect sw sh).getD Mat.identity
    | none => Mat.identity
  let lx := fun (n : String) => (attr attrs n).bind (parseTextLenAll st.fontSize st.pctRefW st.rootFontSize)
  let ly := fun (n : String) => (attr attrs n).bind (parseTextLenAll st.fontSize st.pctRefH st.rootFontSize)
  let ar := match attr attrs "preserveAspectRatio" with
    | some v => Viewport.parseAspectRatio v
    | none => {}
  let (x, y, w, h, inner) ←
    SvgImage.place sw sh rootMat ((lx "x").getD 0) ((ly "y").getD 0) (lx "width") (ly "height") ar
  let clip := if ar.slice && ar.align.isSome then some (x, y, w, h) else none
  some (⟨evs, layerDepth, x, y, w, h, inner⟩, n, clip)

/-- T84: how a document is interpreted.  The top level is `{}`; an SVG
image's sub-document starts at the layer depth its image sits at, and loads no
images of its own (usvg drops external ones; here every one, so SVG images
never nest). -/
structure SubCfg where
  layerDepth : Nat := 0
  nested : Bool := false
  /-- T92: the output canvas size in px (after `--width`/`--zoom`), what the
  viewport units resolve against (Chromium's `<img>` viewport); `none` means
  the root's natural size. -/
  outSize : Option (Nat × Nat) := none

/-- T104: the root `<svg>`'s non-standard `background-color` (usvg
`convert_doc`): the winning value across `!important` CSS, `style=""`, normal
CSS and the attribute, if it is a plain colour, as a shape filling `area` (the
`viewBox`, or the root size without one) in the root's user space.  usvg makes
it a sibling *before* the root group, so the root's own opacity, clip, mask
and filter do not apply to it. -/
def rootBackground (rules : Array Css.Rule) (attrs : Array Xml.Attr) (chain : Array Css.ElemInfo)
    (area : Fx × Fx × Fx × Fx) : Option Shape :=
  let n := "background-color"
  let (normalCss, importantCss) := Css.matchingDeclsSplit rules chain
  let lastNamed := fun (decls : Array (String × ByteArray)) =>
    (decls.filter (fun d => d.1 == n)).back?.map (·.2)
  let styleDecls := match attr attrs "style" with
    | some v => parseStyleDecls v
    | none => #[]
  let v := (lastNamed importantCss).orElse fun _ =>
    (lastNamed styleDecls).orElse fun _ => (lastNamed normalCss).orElse fun _ => attr attrs n
  v.bind fun v => (parseSolidColor (lower (trim v))).bind fun c =>
    let (x, y, w, h) := area
    if w ≤ 0 || h ≤ 0 then none else
    some { cmds := #[.moveTo ⟨x, y⟩, .lineTo ⟨x + w, y⟩, .lineTo ⟨x + w, y + h⟩,
                     .lineTo ⟨x, y + h⟩, .close],
           style := { (default : Style) with fill := .solid c } }

/-- Walk the event stream with a style stack.

T29 adds CSS from `<style>` elements, collected in one pre-pass over `events`
(`combinedCss`) before the main walk.  A second stack, `elemStack`/
`childCounts`, is kept in exact lockstep with the existing `Style` stack
(pushed/popped in the same three places: root, `g`, shape; left alone while
`skip > 0`) to build each element's ancestor `Css.ElemInfo` chain and its
`:first-child` flag.  `applyEffective` is the four-layer cascade at all
three sites: presentation attributes, then non-important CSS, then the
`style=""` attribute, then `!important` CSS, with `color` and
`transform-origin` resolved first from whichever layer wins (and the root's
percentage reference seeded on the root push).

T27 adds a third stack, `switchSel`, kept the same size as `stack` and
pushed/popped together, tracking what a `<switch>` ancestor demands of its
direct children: `none` (unfiltered), `some none` (switch with no passing
child, all children skipped), or `some (some j)` (only the direct child
whose `.open_` event is at index `j` may render).  `g`, `switch`, shape
elements and the root `<svg>` all also check `passesConditions attrs`
alongside `isDisplayNone`.  A `<switch>` that passes its own checks runs a
bounded forward lookahead to find the first direct child whose tag usvg
recognises and whose own `passesConditions` holds; that index becomes its
`switchSel` target.  All three stacks move together at every push/pop site
so CSS resolution and switch selection never drift out of sync. -/
def interpretWith (cfg : SubCfg) (events : Array Xml.Event) : Except String Doc := do
  -- T47: `use` references are copied in first; everything below sees the
  -- expanded stream (see `LeanSvg/Use.lean`).
  let events := FeImage.fixRecursive events
  let srcEvents := events
  let events ← Use.expand events (rootViewport events) maxClipPaths
  let combinedCss : ByteArray := Id.run do
    let mut out := ByteArray.empty
    let mut curDepth : Nat := 0
    let mut styleDepth : Option Nat := none
    let mut styleOk := false
    for ev in events do
      match ev with
      | .open_ name attrs =>
        if styleDepth.isNone && name == "style" then
          styleOk := match attr attrs "type" with
            | none => true
            | some v => let t := trim v; t.size == 0 || eqAsciiCI t "text/css"
          styleDepth := some curDepth
        curDepth := curDepth + 1
      | .close =>
        curDepth := curDepth - 1
        if styleDepth == some curDepth then styleDepth := none
      | .text bytes =>
        if styleDepth.isSome && styleOk then out := (out ++ bytes).push 32
    return out
  let rules := Css.parseStylesheet combinedCss
  -- T105: fonts embedded in the document (`@font-face` with `data:` URLs)
  let docFaces := FontFace.scan combinedCss
  -- T104: XHTML labels in `foreignObject` become SVG text (after `use`
  -- expansion, so copies are rewritten too; needs the stylesheet).
  let events ← ForeignObject.rewrite rules events
  -- One bounded pre-pass over the same events collects every referenceable
  -- definition: T18's gradient paint servers, resolved here into an immutable
  -- table that is handed to the root element's `Style` and inherited by
  -- copying, and T20's `clipPath` slots, which the walk below fills in
  -- because their contents need the cascade.  See "the shape of a defs table".
  let scan := defsScan events
  let textPaths := textPathTables events (Int.ediv scan.pctRef.w 256) (Int.ediv scan.pctRef.h 256)
  let gradTable := Grad.Defs.build scan.grads scan.pctRef
  -- T51: every `<filter>` element, collected up front like the gradients.
  let fparsers : Filter.Parsers := ⟨parseColor, parseOpacity, opacityOne⟩
  let ftab := Filter.scan fparsers events
  -- Geometry only, no content yet: `Pat.resolve` needs nothing but the raw
  -- attributes and `href` chain, so the table can be complete before the
  -- main walk starts, exactly like `gradTable` (`Doc.patterns`'s doc
  -- comment).  `resolvePaint` reaches it through every `Style` from here.
  let patTable := Pat.Defs.build scan.patterns scan.pctRef
  let applyEffective := fun (parent : Style) (attrs : Array Xml.Attr) (chain : Array Css.ElemInfo) =>
    -- `transform-origin` percentages resolve against usvg's per-element
    -- `state.view_box`: the root's `viewBox` if it has one, else the root's
    -- own resolved size (`resolveRootSize`).  Established here from the root
    -- `<svg>`'s own attrs and inherited; only a nested `<svg>` rescopes it.
    -- `parent.pctRefSet` is false only for the literal `default : Style`
    -- passed as the parent of the root element itself -- the one call where
    -- `attrs` *are* the root's own `width`/`height`/`viewBox`.  Captured
    -- before the shadowing below: `rootFontSize` (what `rem` resolves
    -- against) is set from this call's own resolved `fontSize` only when it
    -- is processing the root, then just inherited like `pctRefW`/`pctRefH`
    -- for every descendant -- but unlike them, never rescoped by a nested
    -- `<svg>` (SVG 2 `rem` always means the *document* root).
    let isRoot := !parent.pctRefSet
    let parent :=
      if parent.pctRefSet then parent
      else
        let r := parseRoot attrs
        let (rw, rh) := match r.viewBox with
          | some (_, _, vw, vh) => (vw, vh)
          | none => (resolveRootSize r).getD (Fx.ofNat 100, Fx.ofNat 100)
        -- T92: the canvas the viewport units resolve against: the output
        -- size when the caller knows it, else the root's natural size.
        let (vw, vh) := match cfg.outSize with
          | some (w, h) => (Fx.ofNat w, Fx.ofNat h)
          | none => (resolveRootSize r).getD (Fx.ofNat 100, Fx.ofNat 100)
        { parent with pctRefSet := true, pctRefW := rw, pctRefH := rh,
                      rootFontSize := { parent.rootFontSize with vpW := vw, vpH := vh },
                      docFaces }
    let styleDecls := match attr attrs "style" with
      | some v => parseStyleDecls v
      | none => #[]
    let (normalCss, importantCss) := Css.matchingDeclsSplit rules chain
    let lastNamed := fun (decls : Array (String × ByteArray)) (n : String) =>
      (decls.filter (fun d => d.1 == n)).back?.map (·.2)
    -- The winning value of a single-valued property across the four layers,
    -- highest precedence first: `!important` CSS, `style=""`, normal CSS,
    -- presentation attribute.  Used for the two properties that must be
    -- resolved *before* the generic folds run, regardless of markup order:
    -- `color` (so `fill`/`stroke: currentcolor` on the same element sees the
    -- element's own final `color`) and `transform-origin` (so `applyProp`'s
    -- `"transform"` case sees `originDx`/`originDy`, whichever layer the
    -- `transform` itself comes from).  usvg lists both `transform` and
    -- `transform-origin` as presentation attributes (`svgtree/mod.rs`,
    -- `is_presentation`), so CSS sets them exactly like any other property.
    let winning := fun (n : String) =>
      match lastNamed importantCss n with
      | some v => some v
      | none =>
        match styleDecls.findSome? (fun (m, val) => if m == n then some val else none) with
        | some v => some v
        | none =>
          match lastNamed normalCss n with
          | some v => some v
          | none => attr attrs n
    let base := match winning "color" with
      | some v => applyProp parent "color" v
      | none => parent
    -- `transform-origin` is *not* inherited (unlike `color`): every element
    -- gets its own, freshly reset to "no adjustment" here rather than carrying
    -- the parent's, so an ancestor's `transform-origin` never leaks onto a
    -- descendant that has no `transform-origin` of its own.
    let (odx, ody) := match winning "transform-origin" with
      | some v => parseTransformOrigin v base.pctRefW base.pctRefH
      | none => (0, 0)
    let base := { base with originDx := odx, originDy := ody }
    -- Not inherited, like `transform-origin`: every element starts from
    -- "no layer" and only its own declarations can change that (T22).
    let base := { base with ownOpacity := opacityOne, blend := .normal, isolate := false }
    -- `clip-path` and the element's own transform are per-element too, and for
    -- the same reason (T20).
    let base := { base with clipRef := none, clipShapeRaw := none, ownMat := Mat.identity, maskRef := none,
                            maskAlpha := false, filterRaw := none }
    -- `text-decoration` and `textLength`/`lengthAdjust` are per-element for
    -- the same reason (T55): see the field docs on `Style`.
    let base := { base with ownUnderline := false, ownOverline := false, ownLineThrough := false,
                            ownTextLength := none, ownLengthAdjustGlyphs := false,
                            ownBidiOverride := false }
    let early (n : String) := n == "color" || n == "transform-origin"
    -- `font-kerning` (like `mix-blend-mode` and `isolation`) is deliberately
    -- *not* a presentation attribute in usvg: `parse_svg_element` drops it and
    -- only the `style=""`/CSS layers below can set it (T36).
    -- `mix-blend-mode` and `isolation` (`isCssOnlyProp`) are dropped from
    -- the presentation-attribute layer for the same reason; the three CSS
    -- layers below still apply all three.
    let skipName (n : String) := n == "style" || early n || n == "font-kerning"
                                 || isCssOnlyProp n
    -- T63: usvg also drops the attribute form of `image-rendering` for its
    -- CSS-only values (`svgtree/parse.rs`).
    let cssOnlyValue (a : Xml.Attr) := a.name == "image-rendering" &&
      (eqAscii a.value "smooth" || eqAscii a.value "high-quality" ||
       eqAscii a.value "crisp-edges" || eqAscii a.value "pixelated")
    let afterAttrs := attrs.foldl (fun st a =>
      if skipName a.name || cssOnlyValue a then st else applyProp st a.name a.value) base
    let afterNormalCss := normalCss.foldl (fun st (n, v) => if early n then st else applyProp st n v) afterAttrs
    let afterStyle := styleDecls.foldl (fun st (n, val) => if early n then st else applyProp st n val) afterNormalCss
    let final := importantCss.foldl (fun st (n, v) => if early n then st else applyProp st n v) afterStyle
    if isRoot then { final with rootFontSize := { final.rootFontSize with size := final.fontSize } } else final
  let mut stack : Array Style := #[]
  let mut elemStack : Array Css.ElemInfo := #[]
  let mut childCounts : Array Nat := #[]
  let mut switchSel : Array (Option (Option Nat)) := #[]
  -- T22's fifth stack, again in lockstep with `stack`: did this element open a
  -- compositing layer (so its `.close` must emit a `groupEnd`)?
  let mut layerOpen : Array Bool := #[]
  let mut layerDepth : Nat := cfg.layerDepth
  -- T20: a sixth stack, in lockstep with the other five, for `clipPath`
  -- collection and object bounding boxes (see `Frame`).
  let mut frames : Array Frame := #[]
  -- One slot per `clipPath` the pre-pass found, in document order; the walk
  -- fills in the ones it reaches.  `clipCursor` steps through the scan's
  -- slots as the walk passes their event indices.
  let mut clipTable : Array ClipEntry := scan.clips.map fun (cid, _) =>
    { id := cid, transform := Mat.identity, transformValid := false, objectBBox := false,
      selfClipId := none, selfClip := none, children := #[], filled := false }
  let mut clipCursor : Nat := 0
  let mut uses : Array ClipUse := #[]
  -- T49: the same for `mask`, plus the content streams being collected: while
  -- inside a `mask` element, `nodes` is that mask's content and the enclosing
  -- stream (with its `layerDepth`) waits on `maskSaved`.
  let mut maskTable : Array MaskEntry := scan.masks.map fun (mid, _) => { id := mid }
  let mut maskHolders : Array (Array MaskLink) := scan.masks.map fun _ => #[]
  let mut maskCursor : Nat := 0
  let mut maskUses : Array MaskUse := #[]
  let mut ctxUses : Array CtxUse := #[]
  let mut openMasks : Array Nat := #[]
  let mut maskSaved : Array (Array Node × Nat) := #[]
  -- T52: one slot per `<marker id>` the pre-pass found, mirroring `clipTable`.
  -- `markerCursor` steps through them the same way `clipCursor` does.  Unlike
  -- a `clipPath`, a marker's own geometry attributes (`refX`/`markerWidth`/
  -- `viewBox`/`orient`/...) are all on the element itself, so the slot is
  -- filled in as soon as the walk opens it; only `content` waits for `.close`,
  -- once every descendant routed into `markerNodes[k]` (see `ClipMode.
  -- markerDef`) has been collected.
  let mut markerTable : Array MarkerEntry := scan.markers.map fun (mid, _) =>
    { id := mid, filled := false }
  let mut markerCursor : Nat := 0
  let mut markerNodes : Array (Array Node) := scan.markers.map fun _ => #[]
  -- Seventh lockstep stack: `some k` on the element that opened marker slot
  -- `k` (so `.close` knows when to freeze `markerNodes[k]` into
  -- `markerTable[k].content`), `none` on every other element, including ones
  -- nested inside a marker.
  let mut markerOpenSlot : Array (Option Nat) := #[]
  let mut skip : Nat := 0
  let mut nodes : Array Node := #[]
  let mut root : Option RootInfo := none
  -- T36: how many more characters the whole document may lay out.  Every
  -- `<text>` element draws from this one budget, so glyph generation is
  -- bounded by a constant however much text the input contains.
  let mut textBudget : Nat := 100000
  -- T63: decoded image pixels the whole document may keep (`Image.maxTotalPixels`).
  let mut imageBudget : Nat := if cfg.nested then 0 else Image.maxTotalPixels
  -- T84: what SVG images may still add to the document: elements (with the
  -- document's own, at most `Xml.maxElements`) and bytes of source.
  let mut svgImages : Array SvgImage.Entry := #[]
  let mut warnings : Array String := #[]
  let mut svgElems : Nat := Xml.maxElements - (SvgImage.stats events).1
  let mut svgBytes : Nat := if cfg.nested then 0 else SvgImage.maxTotalBytes
  for idx in [0:events.size] do
    match events.getD idx default with
    | .text _ => pure ()
    | .close =>
      if skip > 0 then skip := skip - 1
      else
        let st := stack.back?.getD default
        let fr := frames.back?.getD default
        if layerOpen.back?.getD false then
          match fr.mode with
          | .markerDef k => markerNodes := markerNodes.setIfInBounds k ((markerNodes.getD k #[]).push .groupEnd)
          | _ => nodes := nodes.push .groupEnd
          layerDepth := layerDepth - 1
        stack := stack.pop
        elemStack := elemStack.pop
        childCounts := childCounts.pop
        switchSel := switchSel.pop
        layerOpen := layerOpen.pop
        frames := frames.pop
        -- T52: this element is exactly where marker slot `k` was opened (not
        -- merely inside it), so its whole content has finished arriving in
        -- `markerNodes[k]`.
        match markerOpenSlot.back?.getD none with
        | some k =>
          let e := markerTable.getD k default
          markerTable := markerTable.setIfInBounds k { e with content := markerNodes.getD k #[] }
        | none => pure ()
        markerOpenSlot := markerOpenSlot.pop
        -- T20: the element's object bounding box is complete now.  It goes to
        -- the element's own use, and (through the element's own transform)
        -- into the parent's box -- but only for rendered content: what is
        -- under `defs` or inside a `clipPath` is not a child of the parent
        -- group in usvg's tree and does not count towards its box.
        match fr.useSlot with
        | some k => uses := uses.modify k (fun u => { u with bbox := fr.bbox, sbox := fr.sbox })
        | none => pure ()
        match fr.maskUse with
        | some k => maskUses := maskUses.modify k (fun u => { u with bbox := fr.bbox })
        | none => pure ()
        match fr.ctxUse with
        | some k => ctxUses := ctxUses.modify k (fun u => { u with bbox := fr.bbox })
        | none => pure ()
        match fr.maskSlot with
        | some k =>
          maskTable := maskTable.modify k fun e => { e with nodes := nodes }
          let (sv, ld) := maskSaved.back?.getD (#[], 0)
          nodes := sv
          layerDepth := ld
          maskSaved := maskSaved.pop
          openMasks := openMasks.pop
        | none => pure ()
        -- T51: the object bounding box is complete, so the `filter` can be
        -- resolved; the layer's `groupBegin` is patched with the outcome.
        match fr.filterAt, st.filterRaw with
        | some k, some raw =>
          let bbox : Option Filter.URect := fr.bbox.bind fun b =>
            if Box.nonZero b then some ⟨b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0⟩ else none
          let cx : Filter.ElemCtx := ⟨bbox, st.color, st.fontSize, st.pctRefW, st.pctRefH⟩
          nodes := nodes.modify k fun n => match n with
            | .groupBegin g =>
              match Filter.resolve fparsers ftab raw cx with
              | .filters fs => .groupBegin { g with filters := fs, filterCtm := st.ctm }
              | .drop => .groupBegin { g with dropped := true }
              | .noFilter => .groupBegin { g with passthrough := fr.filterOnly }
            | n => n
        | _, _ => pure ()
        match fr.mode, frames.back? with
        | .render, some pf =>
          if pf.want then
            frames := frames.pop.push
              { pf with bbox := Box.union pf.bbox (fr.bbox.bind (Box.transformed st.ownMat)),
                        sbox := if pf.wantS then
                            Box.union pf.sbox ((fr.sbox <|> fr.bbox).bind (Box.transformed st.ownMat))
                          else pf.sbox }
        | _, _ => pure ()
    | .open_ name attrs =>
      if skip > 0 then
        skip := skip + 1
      else
        let isFirst := childCounts.back?.getD 0 == 0
        childCounts := match childCounts.back? with
          | some c => childCounts.pop.push (c + 1)
          | none => childCounts
        let elemInfo := Css.buildElemInfo name (attrs.map (fun a => (a.name, toStr a.value))) isFirst
        let chain := elemStack.push elemInfo
        let parent := stack.back?.getD default
        let pf := frames.back?.getD default
        -- Each branch below either sets `skip` (the element and its subtree are
        -- dropped) or fills `enter` with the style to push and `frame` with the
        -- `Frame` beside it — and, for a shape, `shapeNode` with the geometry
        -- to emit.  The layer decision and all six stack pushes then happen
        -- once, at the bottom, so no site can push a `groupBegin` without the
        -- matching `layerOpen` entry.
        --
        -- The two flags the bottom needs from the branch: `renders` (T20 ×
        -- T22 — `clipPath` and `defs` define rather than draw, so they never
        -- open a layer, and neither does anything inside them) and
        -- `container` (this element can have children that overlap each
        -- other, so a `clip-path` on it is worth a layer; see the bottom).
        let mut enter : Option Style := none
        let mut shapeNode : Option Shape := none
        let mut sel : Option (Option Nat) := none
        let mut frame : Frame := {}
        let mut renders : Bool := false
        let mut container : Bool := false
        -- T48: a nested `<svg>`'s viewport clip use, which rides the layer
        -- beside (outside) the element's own `clip-path`.
        let mut viewportClip : Option Nat := none
        let mut fineShape : Bool := false
        -- T52: `some k` only from the `marker` branch below, when this
        -- element is exactly where slot `k` was opened; pushed onto
        -- `markerOpenSlot` alongside the other six stacks.
        let mut markerSlot : Option Nat := none
        match root with
        | none =>
          if name != "svg" then throw s!"root element must be <svg>, found <{name}>"
          root := some (parseRoot attrs)
          if isDisplayNone attrs || !passesConditions attrs then
            skip := 1
          else
            let r := parseRoot attrs
            let area := match r.viewBox with
              | some vb => some vb
              | none => (resolveRootSize r).map fun (w, h) => (0, 0, w, h)
            match area.bind (rootBackground rules attrs chain) with
            | some bg => nodes := nodes.push (.shape bg)
            | none => pure ()
            -- usvg converts the root `svg` as a group, so its own `clip-path`
            -- applies (`masking/clipPath/on-the-root-svg-with-size`).  T18's
            -- gradient table reaches every element from here, by inheritance.
            let (st, uses', slot) :=
              addClipUse
                (applyEffective { (default : Style) with defs := gradTable, patterns := patTable }
                  attrs chain) uses
            uses := uses'
            let (mu, mh, mslot) := addMaskUse st.maskRef st.ctm maskUses maskHolders openMasks
            maskUses := mu
            maskHolders := mh
            enter := some st
            frame := { mode := .render, useSlot := slot, maskUse := mslot,
                       want := slot.isSome || mslot.isSome }
            renders := true
            container := true
        | some _ =>
          let allowed := match switchSel.back?.getD none with
            | none => true
            | some none => false
            | some (some target) => idx == target
          if !allowed then skip := 1
          else if pf.isShapeLeaf then skip := 1
          else if name == "clipPath" then
            -- T20: collect the clip wherever it appears.  Its contents live in
            -- the user space of the element that will reference it, so the
            -- ancestors' transforms and clips are dropped here, while the
            -- inherited properties (`clip-rule`, `visibility`) flow through
            -- the style as usual.  The element's own `transform` is kept
            -- aside so `clipPathUnits` can be slotted in after it.
            -- The slot the pre-pass reserved for *this* element, found by its
            -- event index.  No slot means no usable `id`, or past the cap:
            -- the clip is unreferenceable, so the subtree is skipped.
            while clipCursor < scan.clips.size && (scan.clips.getD clipCursor ("", 0)).2 < idx do
              clipCursor := clipCursor + 1
            let slotK :=
              if clipCursor < scan.clips.size && (scan.clips.getD clipCursor ("", 0)).2 == idx
              then some clipCursor else none
            match slotK with
            | some k =>
              let stC := applyEffective { parent with ctm := Mat.identity, clips := #[] } attrs chain
              let obb := match attr attrs "clipPathUnits" with
                | some v => eqAscii (trim v) "objectBoundingBox"
                | none => false
              clipTable := clipTable.modify k (fun e =>
                { e with transform := stC.ctm, transformValid := Mat.hasScale stC.ctm,
                         objectBBox := obb, selfClipId := stC.clipRef, filled := true })
              enter := some { stC with ctm := Mat.identity, ownMat := Mat.identity, clipRef := none,
                                       clipShapeRaw := none }
              frame := { mode := .clip k }
            | none => skip := 1
          else if name == "mask" then
            -- T49: like `clipPath`, collected wherever it appears, in the user
            -- space of the referencing element (its own `transform` has no
            -- effect).  Its children are rendered content, but into the mask's
            -- own node stream (see `maskSaved`).
            while maskCursor < scan.masks.size && (scan.masks.getD maskCursor ("", 0)).2 < idx do
              maskCursor := maskCursor + 1
            let slotK :=
              if maskCursor < scan.masks.size && (scan.masks.getD maskCursor ("", 0)).2 == idx
              then some maskCursor else none
            match slotK with
            | some k =>
              let stM := applyEffective
                { parent with ctm := Mat.identity, clips := #[], opacity := opacityOne } attrs chain
              let isUser := fun (n : String) (dflt : Bool) => match attr attrs n with
                | some v =>
                  let t := trim v
                  if eqAscii t "userSpaceOnUse" then true
                  else if eqAscii t "objectBoundingBox" then false else dflt
                | none => dflt
              maskTable := maskTable.modify k fun e =>
                { e with userUnits := isUser "maskUnits" false,
                         contentBBox := !(isUser "maskContentUnits" true),
                         alpha := stM.maskAlpha,
                         linear := (attrOrStyle attrs "color-interpolation").any
                           (fun v => eqAscii (trim v) "linearRGB"),
                         x := (attr attrs "x").bind parseCoord16,
                         y := (attr attrs "y").bind parseCoord16,
                         w := (attr attrs "width").bind parseCoord16,
                         h := (attr attrs "height").bind parseCoord16,
                         pctW := stM.pctRefW, pctH := stM.pctRefH,
                         selfMaskId := stM.maskRef, filled := true }
              openMasks := openMasks.push k
              if stM.maskRef.isSome then
                maskHolders := openMasks.foldl (fun hs j => hs.modify j (·.push (.self_ k))) maskHolders
              maskSaved := maskSaved.push (nodes, layerDepth)
              nodes := #[]
              layerDepth := 0
              enter := some { stM with ctm := Mat.identity, ownMat := Mat.identity,
                                       clipRef := none, clipShapeRaw := none, maskRef := none }
              frame := { mode := .render, maskSlot := some k,
                         fine := (maskTable.getD k default).contentBBox }
            | none => skip := 1
          else if name == "defs" then
            -- T20: descended, not rendered, so the `clipPath`s inside are
            -- collected.
            enter := some (applyEffective parent attrs chain)
            frame := { mode := .defs }
          else if name == "g" || name == "a" then
            -- usvg's tree builder rewrites `<a>`'s tag name to `EId::G` before
            -- conversion ever sees it (`svgtree/parse.rs`): a link has no
            -- rendering behaviour of its own, only its `<g>`-identical
            -- properties and children.
            if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              let (st, uses', slot) := addClipUse (applyEffective parent attrs chain) uses
              uses := uses'
              let (mu, mh, mslot) := addMaskUse (if pf.mode.isRender then st.maskRef else none)
                st.ctm maskUses maskHolders openMasks
              maskUses := mu
              maskHolders := mh
              enter := some st
              frame := { mode := pf.mode.inner, useSlot := slot, maskUse := mslot,
                         want := slot.isSome || mslot.isSome || pf.want, fine := pf.fine }
              renders := pf.mode.isRender
              container := true
          else if name == "use" then
            -- T47: `Use.expand` has put the linked content inside.  A `use` is a
            -- group whose `x`/`y` translate after its own transform, and it
            -- keeps its parent's mode: a `use` of a shape is a valid `clipPath`
            -- child, while the `g` it may contain is not (`.inner`).
            if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              let st := applyEffective parent attrs chain
              let len := fun (n : String) (ref : Fx) =>
                (((attr attrs n).bind parseLengthOrPercent).map (resolvePct · ref)).getD 0
              let tr := Mat.translate (len "x" st.pctRefW) (len "y" st.pctRefH)
              let noAlpha := fun (p : Paint) => match p with
                | .solid c => Paint.solid { c with a := 255 }
                | p => p
              -- T85: a paint-server context needs this `use`'s box and CTM.
              let server := fun (p : Paint) => match p with
                | .gradient .. | .pattern _ => true
                | _ => false
              let cslot := if pf.mode matches .render && (server st.fill || server st.stroke)
                then some ctxUses.size else none
              let st := { st with ctm := st.ctm.mul tr, ownMat := st.ownMat.mul tr,
                                  ctxFill := noAlpha st.fill, ctxStroke := noAlpha st.stroke,
                                  ctxSlot := cslot, markerCtx := false }
              if cslot.isSome then ctxUses := ctxUses.push ⟨st.ctm, none⟩
              let (st, uses', slot) := addClipUse st uses
              uses := uses'
              enter := some st
              frame := { mode := pf.mode, useSlot := slot, ctxUse := cslot,
                         want := slot.isSome || cslot.isSome || pf.want }
              renders := pf.mode.isRender
              container := true
          else if name == "switch" then
            if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              -- First direct child (depth 0 relative to this `switch`) whose
              -- own conditional-processing attributes pass; `none` if the
              -- switch closes with no such child.  Tag support and
              -- `display:none` are deliberately not considered here, only
              -- checked once we reach that child below (matching usvg: the
              -- switch commits to this child regardless).
              --
              -- usvg's `svgtree` drops any element with an unrecognised tag
              -- name (and `<style>`, special-cased) while building its tree,
              -- before `switch`'s own child search ever runs, so such a
              -- child is not a candidate at all here either (`non-SVG-
              -- child.svg`: `switch` skips straight past `<random/>` to the
              -- next real child) — every other SVG 1.1 element name usvg
              -- knows still is, whether or not *we* render it.
              let target : Option Nat := Id.run do
                let mut depth : Nat := 0
                for j in [idx + 1 : events.size] do
                  match events.getD j default with
                  | .close =>
                    if depth == 0 then return none else depth := depth - 1
                  | .open_ cname cattrs =>
                    if depth == 0 && svgTagNames.contains cname && passesConditions cattrs then
                      return some j
                    else depth := depth + 1
                  | .text _ => pure ()
                return none
              let (st, uses', slot) := addClipUse (applyEffective parent attrs chain) uses
              uses := uses'
              let (mu, mh, mslot) := addMaskUse (if pf.mode.isRender then st.maskRef else none)
                st.ctm maskUses maskHolders openMasks
              maskUses := mu
              maskHolders := mh
              enter := some st
              sel := some target
              frame := { mode := pf.mode.inner, useSlot := slot, maskUse := mslot,
                         want := slot.isSome || mslot.isSome || pf.want, fine := pf.fine }
              renders := pf.mode.isRender
              container := true
          else if name == "svg" then
            -- T48: a nested viewport, as usvg's `use_node::convert_svg`: the
            -- element's own `transform`, then (unless `overflow` is
            -- visible/auto, or `width`/`height` is missing) a clip to
            -- `x y width height`, then `translate(x, y)` and the `viewBox`
            -- map.  Percentages resolve against the parent viewport, and
            -- the children's against the new one.
            if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              let st0 := applyEffective parent attrs chain
              let len := fun (n : String) (ref dflt : Fx) =>
                match (attr attrs n).bind parseLengthOrPercent with
                | some l => resolvePct l ref
                | none => dflt
              let pw := parent.pctRefW
              let ph := parent.pctRefH
              let x := len "x" pw 0
              let y := len "y" ph 0
              let w := len "width" pw pw
              let h := len "height" ph ph
              let r := parseRoot attrs
              let vbT := r.viewBox.bind fun vb => Viewport.viewBoxTransform vb r.aspect w h
              let newTs := match vbT with
                | some m => (Mat.translate x y).mul m
                | none => Mat.translate x y
              let (refW, refH) := match r.viewBox with
                | some (_, _, vw, vh) => if vw > 0 && vh > 0 then (vw, vh) else (pw, ph)
                | none => if w > 0 && h > 0 then (w, h) else (pw, ph)
              let visibleOverflow := match attrOrStyle attrs "overflow" with
                | some v => eqAscii (trim v) "visible" || eqAscii (trim v) "auto"
                | none => false
              let clipped := pf.mode.isRender && !visibleOverflow
                && (attr attrs "width").isSome && (attr attrs "height").isSome && w > 0 && h > 0
              -- The viewport clip is a synthetic one-rect `clipPath` in the
              -- space after the element's own `transform` (usvg's
              -- `clip_element`); its use is appended to the chain exactly
              -- like a `clip-path` one, and the bottom hands it to the layer.
              let mut st0 := st0
              if clipped then
                let child : ClipChild := ⟨rectPath x y w h 0 0, false, Mat.identity, true, #[], false⟩
                clipTable := clipTable.push
                  { id := "", transform := Mat.identity, transformValid := true, objectBBox := false,
                    selfClipId := none, selfClip := none, children := #[child] }
                uses := uses.push ⟨"", some (clipTable.size - 1), st0.ctm, none, none, none⟩
                st0 := { st0 with clips := st0.clips.push (uses.size - 1) }
                viewportClip := some (uses.size - 1)
              let st1 := { st0 with ctm := st0.ctm.mul newTs, ownMat := st0.ownMat.mul newTs,
                                    pctRefW := refW, pctRefH := refH }
              let (st, uses', slot) := addClipUse st1 uses
              uses := uses'
              enter := some st
              frame := { mode := pf.mode.inner, useSlot := slot, want := slot.isSome || pf.want }
              renders := pf.mode.isRender
              container := true
          else if name == "text" then
            -- T36: one branch.  `textShapes` walks the whole subtree itself
            -- (layout is not per-element) and the main loop skips it, so this
            -- is the one element that cannot go through `enter` below: its
            -- layer, if it needs one, is opened and closed right here, and so
            -- is the `Frame` bookkeeping every other branch defers to
            -- `.close`.  A `<text>` is a container like a `g` — its runs and
            -- glyphs can overlap — so a `clip-path` on it takes the layer
            -- route too, on the same terms as the bottom's.
            -- T52: `<text>` inside a `<marker>`'s content is not supported
            -- (`with-a-text-child.svg`) -- skipped like any other unsupported
            -- element, rather than routed through `markerNodes` alongside the
            -- three `nodes.push` sites below, which stay pointed at the
            -- document unconditionally.
            if (match pf.mode with | .markerDef _ => true | _ => false) then skip := 1
            else if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              let (st, uses', slot) := addClipUse (applyEffective parent attrs chain) uses
              uses := uses'
              let (mu, mh, mslot) := addMaskUse (if pf.mode.isRender then st.maskRef else none)
                st.ctm maskUses maskHolders openMasks
              maskUses := mu
              maskHolders := mh
              -- T81: a `filter` is `should_isolate`'s third case, same as the
              -- generic shape/image path (`hasFilter` below).  Unlike that
              -- path, `<text>` opens and closes its own layer right here, so
              -- there is no need for the generic path's `.close`-time patch
              -- (`frame.filterAt`): the object bounding box (`tbox`, from
              -- `textShapes`) is already in hand by the time the layer is
              -- decided, so `Filter.resolve` runs inline, below.
              let hasFilter := pf.mode.isRender && match st.filterRaw with
                | some v => !(eqAscii (trim v) "none")
                | none => false
              let other := st.ownOpacity != opacityOne || st.blend != .normal || st.isolate
                || slot.isSome || mslot.isSome
              let needs := pf.mode.isRender && (other || hasFilter)
              let layered := needs && layerDepth < maxLayerDepth
              let st := if needs && !layered then
                  { st with opacity := mulOpacity st.opacity st.ownOpacity } else st
              -- The clip rides the layer, so it comes back off the chain the
              -- runs carry (see the bottom).
              let layerClips : Array Nat :=
                if layered then (match slot with | some k => #[k] | none => #[]) else #[]
              let st := if layered && slot.isSome then { st with clips := st.clips.pop } else st
              let (shs, used, mbox, spans, ws) := textShapes applyEffective events idx st chain textBudget textPaths stack
              textBudget := textBudget - used
              warnings := Warn.addAll warnings ws
              -- T81: usvg's `objectBoundingBox` for `<text>` is the union of
              -- each glyph's *font-metric* box, not its outline (`Text.
              -- layout`'s doc comment) -- `mbox` is already that, in this
              -- `<text>`'s own user space (`textShapes` gives every run the
              -- element's `ctm`).
              let want := slot.isSome || mslot.isSome || pf.want || hasFilter
              let tbox := if want then mbox else none
              if layered then
                let gi : GroupInfo :=
                  { opacity := st.ownOpacity, blend := st.blend, isolate := st.isolate,
                    clips := layerClips, mask := mslot }
                let gi := if hasFilter then
                    let fbox : Option Filter.URect := tbox.bind fun b =>
                      if Box.nonZero b then some ⟨b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0⟩ else none
                    let cx : Filter.ElemCtx := ⟨fbox, st.color, st.fontSize, st.pctRefW, st.pctRefH⟩
                    match st.filterRaw with
                    | some raw =>
                      match Filter.resolve fparsers ftab raw cx with
                      | .filters fs => { gi with filters := fs, filterCtm := st.ctm }
                      | .drop => { gi with dropped := true }
                      | .noFilter => { gi with passthrough := !other }
                    | none => gi
                  else gi
                nodes := nodes.push (.groupBegin gi)
              match slot with
              | some k => uses := uses.modify k (fun u => { u with bbox := tbox })
              | none => pure ()
              match mslot with
              | some k => maskUses := maskUses.modify k (fun u => { u with bbox := tbox })
              | none => pure ()
              match pf.mode with
              | .render =>
                -- T109: usvg resolves a text run's paint server against the
                -- whole `<text>`'s font-metric box (`text_bbox` in
                -- `paint_server.rs`), not the run's own glyph outlines; a
                -- `ctxUses` slot carries that box and the text's `ctm` to
                -- `Render`, as `Marker.expand` does for a shape's own box.
                -- A paint already tied to a `use` (`context-*`) keeps its slot.
                let server := fun (p : Paint) (ctx : Option Nat) => ctx.isNone && match p with
                  | .gradient .. | .pattern _ => true
                  | _ => false
                let tslot := ctxUses.size
                let needT := shs.any fun s =>
                  server s.style.fill s.style.fillCtx || server s.style.stroke s.style.strokeCtx
                if needT then ctxUses := ctxUses.push ⟨st.ctm, mbox⟩
                let shs := if !needT then shs else shs.map fun s =>
                  { s with style := { s.style with
                      fillCtx := if server s.style.fill s.style.fillCtx then some tslot else s.style.fillCtx,
                      strokeCtx := if server s.style.stroke s.style.strokeCtx then some tslot else s.style.strokeCtx } }
                -- T90: each run inside its spans' layers (`SpanLayers`).
                let mut opened : Array (Nat × Bool) := #[]
                let base := layerDepth + (if layered then 1 else 0)
                for si in [0:shs.size] do
                  let c := spans.chains.getD si #[]
                  let mut keep := 0
                  for q in [0:opened.size] do
                    if keep == q && c.getD q opened.size == (opened.getD q default).1 then keep := q + 1
                  for _ in [keep:opened.size] do
                    if (opened.back?.map (·.2)).getD false then nodes := nodes.push .groupEnd
                    opened := opened.pop
                  for q in [keep:c.size] do
                    let o := c.getD q 0
                    let (ost, obox) := spans.owners.getD o default
                    let open? := base + opened.size < maxLayerDepth
                    if open? then
                      let (ost, uses', oslot) := addClipUse ost uses
                      uses := uses'
                      let (mu, mh, omslot) := addMaskUse ost.maskRef ost.ctm maskUses maskHolders openMasks
                      maskUses := mu
                      maskHolders := mh
                      match oslot with
                      | some k => uses := uses.modify k (fun u => { u with bbox := obox })
                      | none => pure ()
                      match omslot with
                      | some k => maskUses := maskUses.modify k (fun u => { u with bbox := obox })
                      | none => pure ()
                      let gi : GroupInfo :=
                        { opacity := ost.ownOpacity, blend := ost.blend, isolate := ost.isolate,
                          clips := oslot.toArray, mask := omslot }
                      let gi := match ost.filterRaw with
                        | some raw =>
                          if eqAscii (trim raw) "none" then gi else
                          let fbox : Option Filter.URect := obox.bind fun b =>
                            if Box.nonZero b then some ⟨b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0⟩ else none
                          let cx : Filter.ElemCtx := ⟨fbox, ost.color, ost.fontSize, ost.pctRefW, ost.pctRefH⟩
                          match Filter.resolve fparsers ftab raw cx with
                          | .filters fs => { gi with filters := fs, filterCtm := ost.ctm }
                          | .drop => { gi with dropped := true }
                          | .noFilter => gi
                        | none => gi
                      nodes := nodes.push (.groupBegin gi)
                    opened := opened.push (o, open?)
                  nodes := nodes.push (.shape (shs.getD si default))
                for _ in [0:opened.size] do
                  if (opened.back?.map (·.2)).getD false then nodes := nodes.push .groupEnd
                  opened := opened.pop
                if pf.want then
                  match frames.back? with
                  | some pf' =>
                    frames := frames.pop.push
                      { pf' with bbox := Box.union pf'.bbox (tbox.bind (Box.transformed st.ownMat)),
                                 sbox := if pf'.wantS then Box.union pf'.sbox (tbox.bind (Box.transformed st.ownMat))
                                   else pf'.sbox }
                  | none => pure ()
              | .defs => pure ()
              | .markerDef _ => pure ()  -- unreachable: gated above, kept for exhaustiveness
              | .clip k =>
                -- T36 landed, so `<text>` *is* a valid `clipPath` child:
                -- usvg converts it to paths first and clips with those.  Each
                -- laid-out run becomes one child with its own `clip-rule`;
                -- `textShapes` has already dropped the invisible runs.
                for sh in shs do
                  if sh.cmds.size ≥ 2 then
                    let child : ClipChild :=
                      ⟨sh.cmds, sh.style.clipEvenOdd, sh.style.ctm, true, st.clips, false⟩
                    clipTable := clipTable.modify k fun e =>
                      { e with children := e.children.push child }
              if layered then nodes := nodes.push .groupEnd
              skip := 1
          else if isShape name then
            if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              let (st, uses', slot) := addClipUse (applyEffective parent attrs chain) uses
              uses := uses'
              let (mu, mh, mslot) := addMaskUse (if pf.mode.isRender then st.maskRef else none)
                st.ctm maskUses maskHolders openMasks
              maskUses := mu
              maskHolders := mh
              let cmds := shapeCmds name attrs st.fontSize st.pctRefW st.pctRefH st.rootFontSize
              -- T64: `has_bbox` (SVG 7.11) — an `objectBoundingBox` paint
              -- server cannot paint a shape whose own geometry has a
              -- degenerate (zero-width or zero-height) bounding box, e.g. a
              -- horizontal/vertical `line`; usvg checks this once, from the
              -- shape's own untransformed path, when resolving `fill`/
              -- `stroke`, and uses the `url(#id) <fallback>` colour instead.
              -- Distinct from `Grad.build`'s `.skip` (a singular transform,
              -- decided at render time, which paints nothing, never a
              -- fallback).
              let hasBbox := (cmds.bind cmdsBox).any Box.nonZero
              let fixPaint := fun (p : Paint) => match p with
                | .gradient i fb => if hasBbox || !(st.defs.defs.getD i default).oBB then p else fb
                | _ => p
              -- A `context-*` paint was checked on the `use`, not here (T85).
              let st := { st with fill := if st.fillCtx.isSome then st.fill else fixPaint st.fill,
                                  stroke := if st.strokeCtx.isSome then st.stroke else fixPaint st.stroke }
              -- T52: usvg 0.48.1 actually instantiates markers on every basic
              -- shape (`converter.rs`'s `EId::Rect | Circle | Ellipse |
              -- Polyline | Polygon | Path` all take the same `convert_path`
              -- route that calls `marker::convert`) -- confirmed against
              -- `marker-on-rect.svg`/`-circle.svg`/`-rounded-rect.svg`,
              -- titled "(SVG 2)" -- but never on `<text>`, which is not in
              -- that list (`marker-on-text.svg`).
              let markerable := isShape name
              match pf.mode with
              | .render | .markerDef _ =>
                -- T49: in `objectBoundingBox` mask content a fill-only shape
                -- whose paint does not live in user units takes the 16.16
                -- coordinates; `fineCtm` divides the 256 back out.
                let fine := pf.fine && st.stroke matches .none &&
                  (match st.fill with
                   | .gradient i _ => (st.defs.defs.getD i default).oBB
                   | _ => true) && (shapeCmds16 name attrs).isSome
                fineShape := fine
                match (if fine then shapeCmds16 name attrs else cmds) with
                | some cmds =>
                  -- T90: an arc is one segment: no `marker-mid` where
                  -- `arcPath` split it into cubics (the suite, Chromium).
                  let st := if name == "path" && st.markerMidId.isSome then
                      { st with arcJoins := ((attr attrs "d").map fun d => (parsePathDataJ d).2).getD #[] }
                    else st
                  if st.visible && cmds.size > 0 then shapeNode := some ⟨cmds, st, markerable, none, none⟩
                | none => pure ()
              | .defs => pure ()
              | .clip k =>
                -- `convert_clip_path_elements_impl`: `line` is not a valid
                -- child (a stroke-less line has no fill), nor is a shape
                -- whose path has fewer than two verbs or whose own transform
                -- has a zero scale (`is_visible_element`).
                --
                -- Under `clipPathUnits="objectBoundingBox"` the coordinates
                -- are fractions of a box, so they are lexed on the 16.16 grid
                -- where `shapeCmds16` can (everything but `path`).
                let fine := (clipTable.getD k default).objectBBox && (shapeCmds16 name attrs).isSome
                let cmds := if fine then shapeCmds16 name attrs else cmds
                match cmds with
                | some cmds =>
                  if name != "line" && cmds.size ≥ 2 && Mat.hasScale st.ownMat then
                    let child : ClipChild := ⟨cmds, st.clipEvenOdd, st.ctm, st.visible, st.clips, fine⟩
                    clipTable := clipTable.modify k fun e => { e with children := e.children.push child }
                | none => pure ()
              let want := slot.isSome || mslot.isSome || pf.want || st.filterRaw.isSome
              let wantS := pf.wantS || strokeShapeUse uses slot
              enter := some st
              frame := { mode := pf.mode, useSlot := slot, maskUse := mslot, want,
                         bbox := if want then cmds.bind cmdsBox else none,
                         sbox := if want && wantS then cmds.bind (strokeBoxOf st) else none,
                         wantS, isShapeLeaf := true }
              renders := pf.mode.isRender
          else if name == "marker" then
            -- T52: like `clipPath`, a `<marker>` never renders itself -- only
            -- `.markerDef k` routing of its descendants and, on `.close`,
            -- freezing `markerNodes[k]` into `markerTable[k].content`.  The
            -- slot the pre-pass reserved for *this* element, found by event
            -- index; no slot means no usable `id` (or past `maxMarkers`), so
            -- the element is collected (its subtree still routes through
            -- `.markerDef` machinery harmlessly) but stays unreferenceable --
            -- matching `clipPath`'s `none => skip := 1` would instead drop a
            -- `<path>` inside it from `defsScan`'s later, unrelated passes,
            -- which nothing here does, so there is no reason to skip.
            while markerCursor < scan.markers.size &&
                (scan.markers.getD markerCursor ("", 0)).2 < idx do
              markerCursor := markerCursor + 1
            let slotK :=
              if markerCursor < scan.markers.size &&
                  (scan.markers.getD markerCursor ("", 0)).2 == idx
              then some markerCursor else none
            match slotK with
            | none => skip := 1
            | some k =>
              markerSlot := some k
              let stM := applyEffective
                { parent with ctm := Mat.identity, ownMat := Mat.identity,
                              clips := #[], clipRef := none, clipShapeRaw := none,
                              -- T95: `context-*` in here is the referencing shape's.
                              ctxFill := .none, ctxStroke := .none, ctxSlot := none,
                              markerCtx := true } attrs chain
              let refX := lengthOrPctAttr attrs "refX" 0 stM.pctRefW
              let refY := lengthOrPctAttr attrs "refY" 0 stM.pctRefH
              let width := lengthOrPctAttr attrs "markerWidth" (Fx.ofNat 3) stM.pctRefW
              let height := lengthOrPctAttr attrs "markerHeight" (Fx.ofNat 3) stM.pctRefH
              let viewBox := match attr attrs "viewBox" with
                | some v =>
                  let ns := parseNumberList v
                  if ns.size == 4 then some (ns.getD 0 0, ns.getD 1 0, ns.getD 2 0, ns.getD 3 0)
                  else none
                | none => none
              let (alignNone, alignX, alignY, slice) := parseAspectAttr attrs
              let orient := parseOrientAttr attrs
              let unitsUser := match attr attrs "markerUnits" with
                | some v => eqAscii (trim v) "userSpaceOnUse"
                | none => false
              let clip := match attr attrs "overflow" with
                | none => true
                | some v =>
                  let t := trim v
                  eqAscii t "hidden" || eqAscii t "scroll"
              let valid := width > 0 && height > 0
              -- The `overflow:hidden` clip rectangle, built once here so
              -- `Marker.expand` only has to add one `ClipUse` per instance:
              -- the `viewBox` rect if there is one, else `(0, 0, width,
              -- height)` -- `refX`/`refY` do *not* shift it (`convert_rect`'s
              -- `r.size()` drops the rect's own origin before this step).
              let mut clipEntryIdx : Option Nat := none
              if clip && valid then
                let (rx, ry, rw, rh) := viewBox.getD (0, 0, width, height)
                let rect := rectPath rx ry rw rh 0 0
                let child : ClipChild := ⟨rect, false, Mat.identity, true, #[], false⟩
                let entry : ClipEntry :=
                  { id := "", transform := Mat.identity, transformValid := true,
                    objectBBox := false, selfClipId := none, selfClip := none,
                    children := #[child], filled := true }
                clipTable := clipTable.push entry
                clipEntryIdx := some (clipTable.size - 1)
              markerTable := markerTable.setIfInBounds k
                { (markerTable.getD k default) with
                  refX, refY, width, height, viewBox, alignNone, alignX, alignY, slice,
                  orient, unitsUser, clip, clipEntryIdx, valid, filled := true }
              enter := some stM
              frame := { mode := .markerDef k }
          else if name == "image" then
            -- T63: a leaf like a shape (`LeanSvg/Image.lean`): its coverage is
            -- the placed rectangle and its paint the image, so opacity,
            -- `clip-path`, `mask` and `transform` take the shape's route.  Not
            -- a valid `clipPath` child, and never decoded outside a render.
            if isDisplayNone attrs || !passesConditions attrs then skip := 1
            else
              let (st, uses', slot) := addClipUse (applyEffective parent attrs chain) uses
              uses := uses'
              let (mu, mh, mslot) := addMaskUse (if pf.mode.isRender then st.maskRef else none)
                st.ctm maskUses maskHolders openMasks
              maskUses := mu
              maskHolders := mh
              let (placed, budget') :=
                if pf.mode.isRender then imageShape attrs st imageBudget else (none, imageBudget)
              imageBudget := budget'
              -- T84: not a raster image, so maybe an SVG document.
              let mut svgImg : Option (Nat × Array PathCmd × Option (Fx × Fx × Fx × Fx)) := none
              if placed.isNone && pf.mode.isRender && !cfg.nested then
                let href := (attr attrs "href").orElse (fun _ => attr attrs "xlink:href")
                let (src?, spent) := match href with
                  | some v => SvgImage.load v svgBytes
                  | none => (none, 0)
                svgBytes := svgBytes - spent
                match src?.bind (svgImageEntry attrs st · svgElems (stack.size + 1) (layerDepth + 1)) with
                | some (e, ne, clip) =>
                  svgElems := svgElems - ne
                  svgImages := svgImages.push e
                  svgImg := some (svgImages.size - 1, Image.rectCmds e.x e.y e.w e.h, clip)
                | none => pure ()
              let sliceClip := match placed, svgImg with
                | some (_, _, c), _ => c
                | none, some (_, _, c) => c
                | none, none => none
              -- `slice`: usvg's group clipped to the viewport, as a synthetic
              -- one-rect `clipPath` on this element's chain (like T48's).
              let mut st := st
              if let some (x, y, w, h) := sliceClip then
                let child : ClipChild := ⟨rectPath x y w h 0 0, false, Mat.identity, true, #[], false⟩
                clipTable := clipTable.push
                  { id := "", transform := Mat.identity, transformValid := true,
                    objectBBox := false, selfClipId := none, selfClip := none,
                    children := #[child] }
                uses := uses.push ⟨"", some (clipTable.size - 1), st.ctm, none, none, none⟩
                -- Inside this element's own `clip-path` use, which stays last on
                -- the chain because a layer takes it back off from there.
                let k := uses.size - 1
                st := { st with clips := match slot with
                  | some own => (st.clips.pop.push k).push own
                  | none => st.clips.push k }
              match placed with
              | some (cmds, p, _) =>
                if st.visible then
                  shapeNode := some ⟨cmds, { st with fill := .solid ⟨0, 0, 0, 255⟩, stroke := .none },
                    false, some p, none⟩
              | none =>
                match svgImg with
                | some (k, cmds, _) =>
                  if st.visible then
                    shapeNode := some { cmds, style := { st with fill := .none, stroke := .none },
                                        svgImage := some k }
                | none => pure ()
              let want := slot.isSome || mslot.isSome || pf.want || st.filterRaw.isSome
              let cmds? := match placed, svgImg with
                | some (c, _, _), _ => some c
                | none, some (_, c, _) => some c
                | none, none => none
              enter := some st
              frame := { mode := pf.mode, useSlot := slot, maskUse := mslot, want,
                         bbox := if want then cmds?.bind cmdsBox else none,
                         isShapeLeaf := true }
              renders := pf.mode.isRender
          else
            skip := 1
        match enter with
        | none => pure ()
        | some st =>
          -- usvg's `Group::should_isolate`, minus the `mask`/`filter` cases
          -- this renderer does not implement.  It applies to every element
          -- usvg wraps in a group, shapes included: `opacity` on a `<rect>` is
          -- a one-child layer there, not a paint-alpha shortcut.
          --
          -- T20 × T22: `clip-path` is `should_isolate`'s first case, and resvg
          -- clips the finished layer once (`clip::apply`, a `DestinationIn`
          -- multiply) rather than each shape in it.  That matters exactly when
          -- two clipped shapes overlap on the clip's anti-aliased boundary, so
          -- the layer route is taken for a *container* — the root `svg`, a
          -- `g`, a `switch`, a `text` — whose children can overlap.  A leaf
          -- shape has nothing to overlap with, so its own `clip-path` keeps
          -- T20's cheaper per-coverage multiply unless the element is getting
          -- a layer anyway, in which case the clip rides it.
          let clipLayer := container && (st.clipRef.isSome || frame.useSlot.isSome || viewportClip.isSome)
          let other := st.ownOpacity != opacityOne || st.blend != .normal || st.isolate || clipLayer
            || frame.maskUse.isSome
          -- T51: a `filter` is `should_isolate`'s third case.  Whether it
          -- resolves to anything is only known on close (it needs the box).
          let hasFilter := renders && match st.filterRaw with
            | some v => !(eqAscii (trim v) "none")
            | none => false
          let needs := renders && (other || hasFilter)
          -- Past `maxLayerDepth` the layer is dropped: the opacity is folded
          -- into the subtree's paint the way it was before T22 (wrong where
          -- children overlap, but bounded and never an error) and the blend
          -- mode is ignored.  The clip is *not* dropped with it — it stays on
          -- `Style.clips`, so a degraded group still clips, per shape.
          let layered := needs && layerDepth < maxLayerDepth
          let st := if needs && !layered then { st with opacity := mulOpacity st.opacity st.ownOpacity } else st
          -- `addClipUse` pushed this element's own use onto the inherited
          -- chain; when the layer takes it, it comes back off, so no
          -- descendant multiplies by it a second time.
          let layerClips : Array Nat :=
            if layered then (match frame.useSlot with | some k => #[k] | none => #[]) else #[]
          let st := if layered && frame.useSlot.isSome then { st with clips := st.clips.pop } else st
          -- T48: the viewport clip sits under the own use on the chain, and is
          -- the outer of the two (applied last, like usvg's outer group).
          let layerClips := match viewportClip with
            | some k => if layered then #[k] ++ layerClips else layerClips
            | none => layerClips
          let st := if layered && viewportClip.isSome then { st with clips := st.clips.pop } else st
          if layered then
            if hasFilter then
              frame := { frame with filterAt := some nodes.size, filterOnly := !other,
                                    want := true }
            let gb := Node.groupBegin
              { opacity := st.ownOpacity, blend := st.blend, isolate := st.isolate,
                clips := layerClips, mask := if layered then frame.maskUse else none }
            match frame.mode with
            | .markerDef k => markerNodes := markerNodes.setIfInBounds k ((markerNodes.getD k #[]).push gb)
            | _ => nodes := nodes.push gb
            layerDepth := layerDepth + 1
          match shapeNode with
          | some s =>
            let st := if fineShape then { st with ctm := st.ctm.mul (Mat.mk' 256 0 0 256 0 0) } else st
            let st := { st with arcJoins := s.style.arcJoins }
            match frame.mode with
            | .markerDef k =>
              markerNodes := markerNodes.setIfInBounds k
                ((markerNodes.getD k #[]).push (.shape { s with style := st }))
            | _ => nodes := nodes.push (.shape { s with style := st })
          | none => pure ()
          stack := stack.push { st with arcJoins := #[] }
          elemStack := chain
          childCounts := childCounts.push 0
          switchSel := switchSel.push sel
          layerOpen := layerOpen.push layered
          frames := frames.push { frame with wantS := frame.wantS || pf.wantS || strokeShapeUse uses frame.useSlot }
          markerOpenSlot := markerOpenSlot.push markerSlot
  -- T20: resolve the ids, over the slots the walk actually filled.  Like
  -- usvg's `links` map, a duplicated id resolves to the last such element.
  let idMap : Std.HashMap String Nat := Id.run do
    let mut m : Std.HashMap String Nat := {}
    for i in [0:clipTable.size] do
      let e := clipTable.getD i default
      if e.filled then m := m.insert e.id i
    return m
  let clipsResolved := clipTable.map fun e => { e with selfClip := e.selfClipId.bind idMap.get? }
  -- T92: a basic-shape use gets a synthetic one-child entry, like T48's
  -- viewport clips, now that its element's boxes are known.  No box (an
  -- empty group) means no outline, which clips everything away.
  let mut shapeClips : Array ClipEntry := #[]
  for i in [0:uses.size] do
    let u := uses.getD i default
    match u.shape with
    | some (spec, vb) =>
      let box := match spec.ref with
        | .fill => u.bbox
        | .stroke => u.sbox <|> u.bbox
        | .view => some vb
      let children := match box.map (BasicShape.build spec) with
        | some (cmds, eo) => if cmds.size ≥ 2 then #[(⟨cmds, eo, Mat.identity, true, #[], false⟩ : ClipChild)] else #[]
        | none => #[]
      uses := uses.modify i fun x => { x with entry := some (clipsResolved.size + shapeClips.size) }
      shapeClips := shapeClips.push
        { id := "", transform := Mat.identity, transformValid := true, objectBBox := false,
          selfClipId := none, selfClip := none, children, filled := false }
    | none => pure ()
  let clipsResolved := clipsResolved ++ shapeClips
  -- A use that already has its entry (T48's viewport clips) keeps it.
  let usesResolved := uses.map fun u =>
    { u with entry := match u.entry with | some k => some k | none => idMap.get? u.id }
  -- T49: the same for masks, then usvg's cycle cutting.
  let maskIdMap : Std.HashMap String Nat := Id.run do
    let mut m : Std.HashMap String Nat := {}
    for i in [0:maskTable.size] do
      let e := maskTable.getD i default
      if e.filled then m := m.insert e.id i
    return m
  let (masksFixed, maskUsesFixed) := fixRecursiveMaskLinks
    (maskTable.map fun e => { e with selfMask := e.selfMaskId.bind maskIdMap.get? })
    (maskUses.map fun u => { u with entry := maskIdMap.get? u.id }) maskHolders
  -- One content array per raw `<pattern>` index, collected now that the walk
  -- above is done — `Doc.patterns`'s doc comment explains why this cannot
  -- run any earlier than `gradTable`/`patTable` themselves, and does not need
  -- to: nothing before this point ever reads a pattern's *content*, only its
  -- geometry and its index (`resolvePaint`'s `.pattern i`). `patRootStyle` is
  -- the ambient style pattern content inherits from: fresh defaults (colour
  -- black, fill black, etc.) rather than whatever element the `<pattern>`
  -- happens to sit under in the markup, which usvg's own cascade would use —
  -- an accepted gap, since every `<pattern>` in this task's corpus sits
  -- directly under `<svg>` or `<defs>`, where that is the same thing anyway.
  let prW := Int.ediv scan.pctRef.w 256
  let prH := Int.ediv scan.pctRef.h 256
  let patRootStyle : Style :=
    { (default : Style) with defs := gradTable, patterns := patTable, pctRefSet := true, pctRefW := prW, pctRefH := prH }
  let mut patternContent : Array (Array Node) := #[]
  for raw in scan.patterns do
    let i := patternContent.size
    let fine := patTable.defs.any fun d =>
      d.valid && d.contentSlot == i && d.contentOBB && d.viewBox.isNone
    let (shs, used) := patternContentShapes applyEffective events raw.eventIdx patRootStyle textBudget fine
    textBudget := used
    patternContent := patternContent.push shs
  patternContent := fixRecursivePatterns patTable patternContent
  match root with
  | none => throw "no <svg> root element"
  | some r => return ⟨r, nodes, clipsResolved, usesResolved, masksFixed, maskUsesFixed, markerTable,
      srcEvents, patTable, patternContent, svgImages, ctxUses, warnings⟩

def interpret (events : Array Xml.Event) : Except String Doc := interpretWith {} events

end Svg
end LeanSvg
