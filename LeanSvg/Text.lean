import LeanSvg.Geom
import LeanSvg.TextPath
import LeanSvg.Font
import LeanSvg.Baseline
import LeanSvg.Fonts.NotoSans
import LeanSvg.Fonts.NotoSansBold
import LeanSvg.Fonts.NotoSansItalic

/-!
# Text layout

Characters in, positioned glyph outlines out.  Pure, total, fixed point, and
deliberately independent of `LeanSvg/Svg.lean`: this module knows nothing
about XML, CSS or `Style`.  `Svg.lean` resolves the cascade, hands us a flat
event list (`Ev`) carrying only the properties layout needs plus an opaque
`styleIdx` per run, and gets back `Placed` shapes — glyph outlines already in
the `<text>` element's own user space, tagged with the `styleIdx` they came
from — which it pairs back up with the styles it resolved.

The algorithm follows usvg (`crates/usvg/src/parser/svgtree/text.rs` for
whitespace, `crates/usvg/src/parser/text.rs` for character positions and
chunking, `crates/usvg/src/text/layout.rs` for advances, spacing and
anchoring), simplified to what one Latin face per span can do:

* one glyph per character (no ligatures, no complex-script shaping, no BiDi
  reordering — every run is left to right);
* kerning from `Font.kern` (GPOS pairs, or a legacy `kern` table) between
  adjacent characters of the same chunk.

`dominant-baseline`, `alignment-baseline` and `baseline-shift` (T54,
`LeanSvg/Baseline.lean`) shift each glyph vertically off the alphabetic
baseline; `Svg.lean` resolves them into `SpanProps` and `resolveBaseline16`
computes the per-glyph offset here.

A chunk inside a `textPath` (T50) is laid out the same way and then placed
glyph by glyph along the path by `LeanSvg/TextPath.lean`.

Precision: pen positions and advances are carried in 16.16 fixed point (units
of 1/65536 px) and only rounded to `Fx` once, when a glyph's control points
are written out, so a long line does not accumulate 1/256 px of drift per
character.
-/

namespace LeanSvg
namespace Text

open Bytes

/-! ## Faces

Only the three embedded Noto Sans subsets exist.  `font-family` selects
nothing: every family falls back to Noto Sans (recorded as this task's
fallback policy).  Weight and slant pick among the three. -/

inductive Face where
  | regular
  | bold
  | italic
deriving DecidableEq, Repr, Inhabited, BEq

/-- usvg maps `font-weight` to a number (`bolder`/`lighter` step relative to
the inherited one); we have no semibold face, so anything at 600 or above is
bold.  Italic and oblique both pick the italic face, and bold wins over
italic because there is no bold-italic subset. -/
def pickFace (weight : Nat) (italic : Bool) : Face :=
  if weight ≥ 600 then .bold else if italic then .italic else .regular

/-- The three embedded faces, parsed at most once per render.  `Font.parse` is
pure, so this is a plain function; `Svg.lean` calls it once and keeps the
result in a `let`.  A face that no span asks for is never decoded: hex-decoding
one subset costs about half a millisecond, which is worth skipping on the
overwhelmingly common documents that use one face or none. -/
structure Faces where
  regular : Option Font := none
  bold : Option Font := none
  italic : Option Font := none
deriving Inhabited

def Faces.get (fs : Faces) : Face → Option Font
  | .regular => fs.regular
  | .bold => fs.bold
  | .italic => fs.italic

def loadFaces (needRegular needBold needItalic : Bool) : Faces :=
  { regular := if needRegular then Font.parse (Fonts.NotoSans.bytes ()) else none,
    bold := if needBold then Font.parse (Fonts.NotoSansBold.bytes ()) else none,
    italic := if needItalic then Font.parse (Fonts.NotoSansItalic.bytes ()) else none }

/-! ## What `Svg.lean` resolves for us -/

inductive Anchor where
  | start
  | middle
  | atEnd
deriving DecidableEq, Repr, Inhabited, BEq

/-- Everything about a text run that layout depends on, resolved from the SVG
cascade by `Svg.lean`.  `size`, `letterSpacing` and `wordSpacing` are `Fx`
(1/256 px) user-space lengths. -/
structure SpanProps where
  face : Face := .regular
  size : Fx := Fx.ofNat 12
  letterSpacing : Fx := 0
  wordSpacing : Fx := 0
  /-- `font-kerning: none` (or SVG 1.1 `kerning="0"`) turns pair kerning off. -/
  kerning : Bool := true
  anchor : Anchor := .start
  /-- `dominant-baseline`/`alignment-baseline`, ordinary CSS-inherited `Style`
  fields (`LeanSvg/Baseline.lean`). -/
  dominantBaseline : AlignmentBaseline := .auto
  alignmentBaseline : AlignmentBaseline := .auto
  /-- `baseline-shift`'s accumulated absolute-length contributions (`Fx`,
  1/256 px) and `sub`/`super` keyword counts, from `Svg.textShapes`'s
  tspan-local walk — *not* inherited through the ordinary cascade, see
  `LeanSvg/Baseline.lean`. -/
  baselineShiftPx : Fx := 0
  baselineShiftSub : Nat := 0
  baselineShiftSuper : Nat := 0
  /-- `text-decoration`, resolved by `Svg.lean` to *which ancestor's* style
  supplies the fill/stroke for each line that is in effect (usvg walks from
  this element up to the root, drawing a line for every kind any of them
  declares, coloured by the nearest one that declares that particular kind —
  see `Svg.textShapes`), as an index into its own per-run style table.
  `none` when no ancestor declares that kind at all. -/
  underlineIdx : Option Nat := none
  overlineIdx : Option Nat := none
  throughIdx : Option Nat := none
  /-- `textLength`, already resolved to an `Fx` user-space length (`none` if
  the element carries no such attribute of its own: like `text-decoration`,
  it is not inherited). -/
  textLength : Option Fx := none
  /-- `lengthAdjust="spacingAndGlyphs"` (`false`, the default, is `"spacing"`
  — the only mode implemented). -/
  lengthAdjustGlyphs : Bool := false
deriving Inhabited, Repr

/-- The per-character position lists of one `text`/`tspan` element. -/
structure ElemPos where
  xs : Array Fx := #[]
  ys : Array Fx := #[]
  dxs : Array Fx := #[]
  dys : Array Fx := #[]
  rots : Array Fx := #[]
  /-- Whether the element carried a `rotate` attribute at all: an absent list
  leaves the running "last angle" of usvg's rotation algorithm alone, an empty
  one does not. -/
  hasRot : Bool := false
deriving Inhabited

/-- The `<text>` subtree, flattened.  `Svg.lean` emits one `open_`/`close`
pair per `text`/`tspan` (elements it does not recognise inside `<text>` are
dropped whole, as usvg's tree builder does) and one `text` node per XML
character-data run. -/
inductive Ev where
  | open_ (p : ElemPos)
  /-- A valid `textPath` (direct child of `<text>`, linking to a shape):
  its arc-length table, resolved `startOffset` and arc-length `accuracy` (16.16
  px, `TextPath.accuracyFor` the text's scale).  `p` carries only
  `rotate`, since usvg ignores `x`/`y`/`dx`/`dy` on a `textPath`.  An invalid
  one is sent as an `open_` whose characters are not rendered. -/
  | openPath (p : ElemPos) (path : TextPath.Table) (startOffset accuracy : Int)
  | close
  /-- `preserve` is the node's inherited `xml:space`; `rendered` is false for a
  `display:none` span, whose characters still consume position-list slots but
  produce no glyphs and no advance (usvg's `is_visible_element` check). -/
  | text (bytes : ByteArray) (preserve : Bool) (styleIdx : Nat) (props : SpanProps)
         (rendered : Bool)
deriving Inhabited

/-- One run of glyph outlines sharing a resolved style, in the `<text>`
element's user space.  `Svg.lean` turns each into a `Shape`. -/
structure Placed where
  styleIdx : Nat
  cmds : Array PathCmd
deriving Inhabited

/-! ## UTF-8 -/

/-- Decode UTF-8 to codepoints.  Total and bounded: any byte that does not
start a well-formed sequence that fits in the remaining input becomes
`U+FFFD` and is skipped.  Overlong forms and surrogates are decoded as
written rather than rejected; they end up as `.notdef` either way. -/
def decodeUtf8 (bs : ByteArray) : Array Nat := Id.run do
  let mut out : Array Nat := Array.emptyWithCapacity bs.size
  let mut i := 0
  for _ in [0:bs.size] do
    if i ≥ bs.size then break
    let b0 := (at' bs i).toNat
    let cont := fun (k : Nat) => (at' bs k).toNat &&& 0x3F
    let isCont := fun (k : Nat) => k < bs.size && (at' bs k).toNat &&& 0xC0 == 0x80
    if b0 < 0x80 then
      out := out.push b0
      i := i + 1
    else if b0 &&& 0xE0 == 0xC0 && isCont (i + 1) then
      out := out.push ((b0 &&& 0x1F) * 0x40 + cont (i + 1))
      i := i + 2
    else if b0 &&& 0xF0 == 0xE0 && isCont (i + 1) && isCont (i + 2) then
      out := out.push ((b0 &&& 0x0F) * 0x1000 + cont (i + 1) * 0x40 + cont (i + 2))
      i := i + 3
    else if b0 &&& 0xF8 == 0xF0 && isCont (i + 1) && isCont (i + 2) && isCont (i + 3) then
      out := out.push ((b0 &&& 0x07) * 0x40000 + cont (i + 1) * 0x1000 +
                       cont (i + 2) * 0x40 + cont (i + 3))
      i := i + 4
    else
      out := out.push 0xFFFD
      i := i + 1
  return out

/-! ## Whitespace (`xml:space`)

usvg does this in two stages while building its tree: `trim_text` per
character-data node, then `trim_text_nodes` across the whole `<text>` element.
Both are reproduced exactly, on codepoints rather than bytes — the only
character either ever compares against is `U+0020`, whose UTF-8 encoding is a
single byte, so the two agree. -/

/-- `trim_text`: tabs and newlines become spaces, and (unless
`xml:space="preserve"`) a run of spaces collapses to one. -/
def trimChars (preserve : Bool) (cps : Array Nat) : Array Nat := Id.run do
  let mut out : Array Nat := Array.emptyWithCapacity cps.size
  -- usvg seeds `prev` with `'0'`, i.e. something that is not a space.
  let mut prev : Nat := 0x30
  for k in [0:cps.size] do
    let c0 := cps.getD k 0
    let c := if c0 == 13 || c0 == 10 || c0 == 9 then 32 else c0
    if !preserve && c == 32 && c == prev then continue
    prev := c
    out := out.push c
  return out

def dropFirst (a : Array Nat) : Array Nat := if a.size == 0 then a else a.extract 1 a.size
def dropLast (a : Array Nat) : Array Nat := if a.size == 0 then a else a.extract 0 (a.size - 1)
def firstIs (a : Array Nat) (c : Nat) : Bool := a.size > 0 && a.getD 0 0 == c
def lastIs (a : Array Nat) (c : Nat) : Bool := a.size > 0 && a.getD (a.size - 1) 0 == c
/-- `str::trim().is_empty()`: after `trimChars` the only whitespace left is
`U+0020`. -/
def allSpace (a : Array Nat) : Bool := a.all (fun c => c == 32)

/-- `trim_text_nodes`: trim one leading and one trailing space across the
`<text>` element's character-data nodes taken as a single string, with the
pairwise rules usvg uses to mimic Chrome across `tspan` boundaries.

`depths` is each node's nesting depth below the `<text>` element (its direct
children are depth 0), `preserves` each node's inherited `xml:space`, and
`rootPreserve` the `<text>` element's own. -/
def normalizeTexts (texts : Array (Array Nat)) (depths : Array Nat)
    (preserves : Array Bool) (rootPreserve : Bool) : Array (Array Nat) := Id.run do
  let n := texts.size
  let mut ts := texts
  if n == 1 then
    if !rootPreserve then
      let t := ts.getD 0 #[]
      if t.size == 1 then
        if t.getD 0 0 == 32 then ts := ts.setIfInBounds 0 #[]
      else if t.size > 1 then
        let mut t := t
        if firstIs t 32 then t := dropFirst t
        if lastIs t 32 then t := dropLast t
        ts := ts.setIfInBounds 0 t
  else if n > 1 then
    let len := n - 1
    let mut lastNonEmpty : Option Nat := none
    for i in [0:len] do
      let mut n1 := i
      let n2 := i + 1
      let d1 := depths.getD n1 0
      let d2 := depths.getD n2 0
      if (ts.getD n1 #[]).size == 0 then
        match lastNonEmpty with
        | some m => n1 := m
        | none => pure ()
      let sp1 := preserves.getD n1 rootPreserve
      let sp2 := preserves.getD n2 rootPreserve
      -- `>text<..>text<`, the four boundary characters, read before any of
      -- this iteration's edits (usvg reads them all up front too).
      let t1 := ts.getD n1 #[]
      let t2 := ts.getD n2 #[]
      let c1 := firstIs t1 32
      let c2 := lastIs t1 32
      let c3 := firstIs t2 32
      let c4 := lastIs t2 32
      if d1 < d2 then
        if c3 && !sp2 then ts := ts.setIfInBounds n2 (dropFirst (ts.getD n2 #[]))
      else if c2 && c3 then
        if !sp1 && !sp2 then ts := ts.setIfInBounds n1 (dropLast (ts.getD n1 #[]))
        else if sp1 && !sp2 then ts := ts.setIfInBounds n2 (dropFirst (ts.getD n2 #[]))
      let isFirst := i == 0
      let isLast := i + 1 == len
      if isFirst && c1 && !sp1 && (ts.getD n1 #[]).size > 0 then
        ts := ts.setIfInBounds n1 (dropFirst (ts.getD n1 #[]))
      else if isLast && c4 && (ts.getD n2 #[]).size > 0 && !sp2 then
        ts := ts.setIfInBounds n2 (dropLast (ts.getD n2 #[]))
      if isLast && c2 && (ts.getD n1 #[]).size > 0 && (ts.getD n2 #[]).size == 0 &&
         lastIs (ts.getD n1 #[]) 32 then
        ts := ts.setIfInBounds n1 (dropLast (ts.getD n1 #[]))
      if !allSpace (ts.getD n1 #[]) then lastNonEmpty := some n1
  return ts

/-! ## Character positions -/

structure CharPos where
  x : Option Fx := none
  y : Option Fx := none
  dx : Fx := 0
  dy : Fx := 0
  rot : Fx := 0
deriving Inhabited

/-- usvg's `is_word_separator_characters`. -/
def isWordSep (cp : Nat) : Bool :=
  cp == 0x20 || cp == 0xA0 || cp == 0x1361 || cp == 0x010100 || cp == 0x010101 ||
  cp == 0x01039F || cp == 0x01091F

/-! ## Glyph outlines -/

/-- One glyph's outline, scaled by `size / unitsPerEm`, flipped in `y`,
mapped through the 16.16 linear part `[la lc; lb ld]` about the pen, and
translated to the pen position `(ox, oy)` — all in one pass, so each control
point is rounded to `Fx` exactly once.  `ox`/`oy` are 16.16 (1/65536 px).

This walks `Font.rawContours` rather than calling `Font.outline`, for
precision: `Font.outline` elevates every TrueType quadratic to a cubic and
rounds the resulting `2/3` control points back to *whole font units*, which
at a 280 px `font-size` is worth about a fifth of a device pixel along every
curve.  `PathCmd` has a `quadTo`, `Geom.flatten` subdivides it directly (and
so does tiny-skia, which is what resvg feeds glyph outlines to), so the
elevation is pure loss here.  Coordinates are carried in *half* font units so
that the implied on-curve point between two consecutive off-curve points —
the one place TrueType asks for a midpoint — is exact rather than floored. -/
def glyphCmdsLin (f : Font) (gid : Nat) (sizeFx : Fx) (la lb lc ld : Int) (ox oy : Int) :
    Array PathCmd := Id.run do
  let upem := if f.unitsPerEm == 0 then 1000 else f.unitsPerEm
  let den : Int := 2 * upem
  let k : Int := sizeFx * 256
  -- `x2`/`y2` are twice the font-unit coordinate.
  let tr := fun (x2 y2 : Int) =>
    let sx := Int.ediv (x2 * k + upem) den
    let sy := -(Int.ediv (y2 * k + upem) den)
    let rx := Int.ediv (la * sx + lc * sy) 65536
    let ry := Int.ediv (lb * sx + ld * sy) 65536
    (⟨Fx.clamp (Int.ediv (rx + ox + 128) 256), Fx.clamp (Int.ediv (ry + oy + 128) 256)⟩ : Pt)
  let mut out : Array PathCmd := #[]
  for pts in Font.rawContours f gid do
    let n := pts.size
    if n == 0 then continue
    let at1 := fun (i : Nat) => pts.getD (i % n) (0, 0, false)
    -- Where the contour starts: the first on-curve point, else the last one,
    -- else the midpoint of the wrap-around pair (`Font.buildContourPath`).
    let mut sx2 : Int := 0
    let mut sy2 : Int := 0
    let mut s : Nat := 0
    if (at1 0).2.2 then
      sx2 := 2 * (at1 0).1; sy2 := 2 * (at1 0).2.1; s := 1
    else if (at1 (n - 1)).2.2 then
      sx2 := 2 * (at1 (n - 1)).1; sy2 := 2 * (at1 (n - 1)).2.1; s := 0
    else
      sx2 := (at1 (n - 1)).1 + (at1 0).1; sy2 := (at1 (n - 1)).2.1 + (at1 0).2.1; s := 0
    out := out.push (.moveTo (tr sx2 sy2))
    let mut haveCtrl := false
    let mut qx2 : Int := 0
    let mut qy2 : Int := 0
    let mut lastX2 := sx2
    let mut lastY2 := sy2
    for i in [0:n] do
      let pt := at1 (s + i)
      let x2 := 2 * pt.1
      let y2 := 2 * pt.2.1
      if pt.2.2 then
        if haveCtrl then
          out := out.push (.quadTo (tr qx2 qy2) (tr x2 y2))
          haveCtrl := false
        else out := out.push (.lineTo (tr x2 y2))
        lastX2 := x2; lastY2 := y2
      else
        if haveCtrl then
          -- both are twice a font unit, so their midpoint is exact here
          let mx2 := Int.ediv (qx2 + x2) 2
          let my2 := Int.ediv (qy2 + y2) 2
          out := out.push (.quadTo (tr qx2 qy2) (tr mx2 my2))
          lastX2 := mx2; lastY2 := my2
        qx2 := x2; qy2 := y2
        haveCtrl := true
    if haveCtrl then out := out.push (.quadTo (tr qx2 qy2) (tr sx2 sy2))
    else if lastX2 != sx2 || lastY2 != sy2 then out := out.push (.lineTo (tr sx2 sy2))
    out := out.push .close
  return out

/-- The rotation-only linear part `glyphCmds` feeds `glyphCmdsLin`, factored
out so `T81`'s text-bbox rectangle (below) can rotate by the exact same
matrix a glyph's own outline does. -/
def rotMat16 (rot : Fx) : Int × Int × Int × Int :=
  if rot == 0 then (65536, 0, 0, 65536)
  else
    let (sn, cs) := sinCos16 (degToRad16 rot)
    (cs, sn, -sn, cs)

/-- `glyphCmdsLin` with the linear part a rotation by `rot` degrees (the
identity, which maps every point exactly to itself, when `rot` is zero). -/
def glyphCmds (f : Font) (gid : Nat) (sizeFx : Fx) (rot : Fx) (ox oy : Int) : Array PathCmd :=
  let (la, lb, lc, ld) := rotMat16 rot
  glyphCmdsLin f gid sizeFx la lb lc ld ox oy

/-! ## Text bounding box (T81)

A `<text>`'s `objectBoundingBox` (what a `filter`/`mask`/`clipPathUnits=
"objectBoundingBox"` on it sizes against) is *not* the union of its glyph
outlines: usvg's `convert_span` builds it from each visible cluster's font
*metrics* instead -- `(0, -ascent)` to `(advance, -descent)` in the glyph's
own local space, `ascent`/`descent` the resolved font metrics at that span's
size, not the glyph's actual ink. This is why a filter region sized off text
with no descenders does not grow to fit one, and why `letter-spacing` (which
only inserts extra advance *between* clusters, never before the first or
after the last) does not widen the box past the outermost glyphs' own
advances. The rectangle is carried through the exact same rotation and
translation as the glyph's own outline, so it lands in the same `<text>`
user space `layout` already returns outlines in. -/

/-- One glyph cluster's metric-box corners, already rotated and translated
into the `<text>` element's user space -- `(la, lb, lc, ld, ox, oy)` the same
six values `glyphCmdsLin` takes for this glyph's own outline, `adv16` its
(already `letter-spacing`/`word-spacing`-adjusted) advance clamped up to one
pixel when it collapsed to zero or below (usvg: `if advance <= 0.0 { advance
= 1.0 }`), `top16`/`bot16` the font's ascent/descent scaled to this glyph's
size (screen-`y`, so `top16` is usually negative). -/
def metricCorners (la lb lc ld ox oy adv16 top16 bot16 : Int) : Array Pt :=
  let tr := fun (lx ly : Int) =>
    let rx := Int.ediv (la * lx + lc * ly) 65536
    let ry := Int.ediv (lb * lx + ld * ly) 65536
    (⟨Fx.clamp (Int.ediv (rx + ox + 128) 256), Fx.clamp (Int.ediv (ry + oy + 128) 256)⟩ : Pt)
  #[tr 0 top16, tr adv16 top16, tr adv16 bot16, tr 0 bot16]

/-- The 16.16 screen-space top/bottom of one glyph's metric box, from the
font's resolved ascent/descent (`Font.ascent` positive, `Font.descent`
negative, both font units above/below the baseline, see `Font.lean`) scaled
to `sizeFx`. -/
def metricTopBot (f : Font) (sizeFx : Fx) : Int × Int :=
  let upem := if f.unitsPerEm == 0 then 1000 else f.unitsPerEm
  (-(Font.unitsToFx16 f.ascent sizeFx upem), -(Font.unitsToFx16 f.descent sizeFx upem))

/-! ## Text decoration (`text-decoration`)

`underline`/`overline`/`line-through` are drawn as a plain filled rectangle
per run, `underlineThickness` tall, spanning the run's own advance width,
offset from the baseline by a font-metric that is otherwise never read
(`Font.underlinePosition`/`ascent`/`Font.strikeoutPosition`), and rotated
about the *first* character's pen position exactly like a glyph outline —
usvg builds the same rectangle from the first glyph cluster's own transform
and the summed advance of the run, so a `rotate`/`dy`/`y` list that only
touches a later character in the run moves the glyphs but not the line
underneath them (`text-decoration/underline-with-{dy,rotate,y}-list-*.svg`
pin this down). -/

/-- One open decoration run: which ancestor's style colours it
(`Placed.styleIdx`), the pen position and rotation of the run's first
character, the accumulated advance so far, and the font metrics (already
picked for this run's own face/size) the rectangle is built from. -/
structure DecorRun where
  styleIdx : Nat := 0
  ox : Int := 0
  oy : Int := 0
  rot : Fx := 0
  width : Int := 0
  unitsPerEm : Nat := 1000
  size : Fx := 0
  /-- Font-unit Y coordinate the rectangle is centred on, in the same
  convention as a glyph's own contour points (negative is above the
  baseline): `Font.underlinePosition`, `Font.ascent` or
  `Font.strikeoutPosition`, depending on which line this run is. -/
  dyUnits : Int := 0
  /-- `Font.underlineThickness`, shared by all three kinds. -/
  thicknessUnits : Int := 0
deriving Inhabited

/-- Round `v * size256 / upem` to the nearest integer, ties away from zero.
Unlike `glyphCmds`'s `tr` (which works in doubled font units so a contour's
implied midpoints come out exact), a decoration metric is a plain scalar, so
a symmetric round is simpler and exactly as correct. -/
def roundScale (v size256 upem : Int) : Int :=
  if upem == 0 then 0
  else if v ≥ 0 then Int.ediv (v * size256 + upem / 2) upem
  else -(Int.ediv (-v * size256 + upem / 2) upem)

/-- One decoration run's rectangle, already rotated and translated to the
`<text>` element's user space — the same final transform `glyphCmds` applies
to a contour, just to four straight corners instead of control points.
`#[]` for a run with zero or negative width (`letter-spacing` collapsed it
away, or the character never advanced): a rectangle here is drawn only from
its own width, there is no glyph outline to fall back on. -/
def decorRectCmds (r : DecorRun) : Array PathCmd :=
  if r.width ≤ 0 then #[]
  else
    let upem : Int := if r.unitsPerEm == 0 then 1000 else r.unitsPerEm
    let k : Int := r.size * 256
    let dy := -(roundScale r.dyUnits k upem)
    let th := roundScale r.thicknessUnits k upem
    let y0 := dy - Int.ediv th 2
    let y1 := y0 + th
    let (sn, cs) := if r.rot == 0 then ((0 : Int), (65536 : Int)) else sinCos16 (degToRad16 r.rot)
    let tr := fun (lx ly : Int) =>
      let (rx, ry) :=
        if r.rot == 0 then (lx, ly)
        else (Int.ediv (cs * lx - sn * ly) 65536, Int.ediv (sn * lx + cs * ly) 65536)
      (⟨Fx.clamp (Int.ediv (rx + r.ox + 128) 256), Fx.clamp (Int.ediv (ry + r.oy + 128) 256)⟩ : Pt)
    #[.moveTo (tr 0 y0), .lineTo (tr r.width y0), .lineTo (tr r.width y1), .lineTo (tr 0 y1), .close]

/-! ## Layout -/

/-- One laid-out character. -/
structure Cluster where
  cp : Nat
  styleIdx : Nat
  props : SpanProps
  /-- Advance in 16.16 px, kerning and spacing included. -/
  adv : Int := 0
  /-- The advance before `letter-spacing`/`word-spacing` (usvg's `width`),
  used to centre a glyph on its point along a `textPath`. -/
  width : Int := 0
  /-- The same advance before `letter-spacing`/`word-spacing`: what
  `textLength` measures a run against (`apply_length_adjust` explicitly uses
  the un-spaced `cluster.width`, "discard[ing] any word-spacing and
  letter-spacing" — none of the corpus's `textLength` cases combine the two,
  but keeping the two numbers distinct costs nothing and is exact either
  way). -/
  natWidth : Int := 0
  /-- Cleared by the `letter-spacing` rule that drops a cluster whose advance
  went to zero or below. -/
  dropped : Bool := false
deriving Inhabited

/-- `a[i] := Box.cover a[i] p`, growing `a` with `none` up to `i` (T90). -/
def coverAt (a : Array (Option Box)) (i : Nat) (p : Pt) : Array (Option Box) := Id.run do
  let mut a := a
  for _ in [a.size : i + 1] do
    a := a.push none
  return a.modify i (Box.cover · p)

/-- Lay out one `<text>` element.

`budget` caps how many characters the whole document may lay out; the returned
`Nat` is how many this element used, so the caller can keep the running total
bounded (T36's 100 000 character cap).  Characters past the budget are dropped
before any position or chunk is resolved, so the work really is bounded.

`vertical` is the `<text>` element's resolved `writing-mode` (T56: `true` for
`tb`/`tb-rl`/`vertical-rl`/`vertical-lr`, `false` otherwise — see
`usvg::WritingMode`).  usvg lays a `TopToBottom` chunk out exactly like a
horizontal one — same anchor, same per-character `dx`/`dy`/`rotate` model,
same running pen — in a *local* frame where the pen still advances along
`x`, then rotates the whole chunk 90° about the chunk's own anchor point
(`crates/usvg/src/text/layout.rs`, `layout_text`'s `text_ts.pre_rotate_at
(90.0, x, y)`).  We reproduce that net rotation directly at the point each
glyph's final position and angle are computed, rather than building and then
rotating an intermediate transform, since `glyphCmds` already takes a single
rotation angle and a single pen position:

* the incoming `dx`/`dy` swap axes (`y -= dx; x += dy`, usvg's
  `resolve_clusters_positions_horizontal`), because usvg's local `x` is
  always the advance axis and local `y` always the perpendicular one,
  whichever screen axis they end up on;
* a glyph's own outline additionally rotates 90° (`apply_writing_mode`'s
  per-cluster rotation composes with the chunk's), which for us means adding
  90° to the explicit `rotate` value fed to `glyphCmds`;
* usvg also centers each glyph on the column by shifting it a
  `(ascent + descent) / 2` along local `y` before the rotation
  (`apply_writing_mode`'s "could not find a spec that explains this" shift,
  applied to every "Rotated" — i.e. not `Vertical_Orientation=Upright` —
  character); Noto Sans is Latin-only and every codepoint outside the ranges
  `unicode-vo` lists as `Upright` defaults to `Rotated` (all of Basic Latin
  is: the table's lowest entry is U+00A7), so every glyph this renderer can
  ever place in vertical text takes this branch and the `Upright` branch
  (which counter-rotates a CJK-style glyph back to standing upright) is not
  implemented — it would be dead code with no character able to reach it;
* the local-space point `(x, y)` a glyph would sit at in the horizontal
  layout maps to final position `(chunkX - y, chunkY + x)`, i.e. `(x, y)`
  rotated 90° about the origin (usvg: `rotate(90)` is `x' = -y, y' = x`)
  then translated by the chunk's real anchor;
* the running `(x, y)` that seeds the *next* chunk's default position when
  it has no explicit `x`/`y` of its own carries over as `(y, x)` — swapped
  but *not* rotated (usvg's `layout_text` does a plain
  `std::mem::swap(&mut curr_pos.0, &mut curr_pos.1)` on the chunk's final pen
  position, not the same 90° rotation every glyph gets — `tb-with-dx-on-
  second-tspan.svg` exercises exactly this fallback). -/
def layout (evs : Array Ev) (rootPreserve : Bool) (budget : Nat) (vertical : Bool) :
    Array Placed × Nat × Option Box × Array (Option Box) :=
  Id.run do
  -- ---- 1. character-data nodes, in document order, with their nesting depth
  let mut texts : Array (Array Nat) := #[]
  let mut depths : Array Nat := #[]
  let mut preserves : Array Bool := #[]
  let mut styleIdxs : Array Nat := #[]
  let mut propsOf : Array SpanProps := #[]
  let mut renderedOf : Array Bool := #[]
  -- text flow (`collect_text_chunks_impl`): `flows[k-1]` is the `k`-th valid
  -- `textPath`; a node's flow is `0` (linear) or `k`.  usvg resets the flow to
  -- linear whenever *any* child element ends, even inside a `textPath`.
  -- `segOf` counts textPath boundaries: a chunk must start wherever it changes.
  let mut flows : Array (TextPath.Table × Int × Int) := #[]
  let mut flowOf : Array Nat := #[]
  let mut segOf : Array Nat := #[]
  let mut curFlow : Nat := 0
  let mut seg : Nat := 0
  let mut kinds : Array Bool := #[]
  let mut depth : Nat := 0
  for ev in evs do
    match ev with
    | .open_ _ =>
      depth := depth + 1
      kinds := kinds.push false
    | .openPath _ tbl so acc =>
      depth := depth + 1
      kinds := kinds.push true
      flows := flows.push (tbl, so, acc)
      curFlow := flows.size
      seg := seg + 1
    | .close =>
      depth := depth - 1
      curFlow := 0
      if kinds.back?.getD false then seg := seg + 1
      kinds := kinds.pop
    | .text bs pres si pr rend =>
      flowOf := flowOf.push curFlow
      segOf := segOf.push seg
      texts := texts.push (trimChars pres (decodeUtf8 bs))
      -- `collect_text_nodes` starts the `<text>` element's own children at
      -- depth 0; our `depth` counts the `<text>` open itself, hence `- 1`.
      depths := depths.push (depth - 1)
      preserves := preserves.push pres
      styleIdxs := styleIdxs.push si
      propsOf := propsOf.push pr
      renderedOf := renderedOf.push rend
  -- ---- 2. `xml:space` trimming across the element
  let mut ts := normalizeTexts texts depths preserves rootPreserve
  -- ---- 3. the document-wide character cap
  let mut used : Nat := 0
  for i in [0:ts.size] do
    let t := ts.getD i #[]
    if used ≥ budget then ts := ts.setIfInBounds i #[]
    else if used + t.size > budget then
      ts := ts.setIfInBounds i (t.extract 0 (budget - used))
      used := budget
    else used := used + t.size
  if used == 0 then return (#[], 0, none, #[])
  -- ---- 4. flatten to characters
  let mut chars : Array Nat := Array.emptyWithCapacity used
  let mut cStyle : Array Nat := Array.emptyWithCapacity used
  let mut cProps : Array SpanProps := Array.emptyWithCapacity used
  let mut cRend : Array Bool := Array.emptyWithCapacity used
  let mut cFlow : Array Nat := Array.emptyWithCapacity used
  let mut cSeg : Array Nat := Array.emptyWithCapacity used
  for i in [0:ts.size] do
    for c in ts.getD i #[] do
      chars := chars.push c
      cStyle := cStyle.push (styleIdxs.getD i 0)
      cProps := cProps.push (propsOf.getD i default)
      cRend := cRend.push (renderedOf.getD i true)
      cFlow := cFlow.push (flowOf.getD i 0)
      cSeg := cSeg.push (segOf.getD i 0)
  let total := chars.size
  -- ---- 5. per-element character spans, then the position lists
  --
  -- `counts.[j]` is how many characters the element opened at event `j`
  -- contains; `offsets.[j]` how many precede it.  usvg walks descendants in
  -- document order and lets a later (deeper) element overwrite an earlier
  -- one's values, which a pre-order pass reproduces.
  let mut counts : Array Nat := Array.replicate evs.size 0
  let mut offsets : Array Nat := Array.replicate evs.size 0
  let mut openStack : Array Nat := #[]
  let mut off : Nat := 0
  let mut ni : Nat := 0
  for j in [0:evs.size] do
    match evs.getD j default with
    | .open_ _ | .openPath _ _ _ _ =>
      offsets := offsets.setIfInBounds j off
      openStack := openStack.push j
    | .close =>
      match openStack.back? with
      | some o =>
        counts := counts.setIfInBounds o (off - offsets.getD o 0)
        openStack := openStack.pop
      | none => pure ()
    | .text _ _ _ _ _ =>
      off := off + (ts.getD ni #[]).size
      ni := ni + 1
  -- any element left open (malformed input cannot reach here, but be total)
  for o in openStack do
    counts := counts.setIfInBounds o (off - offsets.getD o 0)
  let mut pos : Array CharPos := Array.replicate total {}
  let mut lastRot : Fx := 0
  for j in [0:evs.size] do
    match evs.getD j default with
    | .open_ p | .openPath p _ _ _ =>
      let o := offsets.getD j 0
      let c := counts.getD j 0
      for k in [0:Nat.min p.xs.size c] do
        pos := pos.setIfInBounds (o + k) { pos.getD (o + k) {} with x := some (p.xs.getD k 0) }
      for k in [0:Nat.min p.ys.size c] do
        pos := pos.setIfInBounds (o + k) { pos.getD (o + k) {} with y := some (p.ys.getD k 0) }
      for k in [0:Nat.min p.dxs.size c] do
        pos := pos.setIfInBounds (o + k) { pos.getD (o + k) {} with dx := p.dxs.getD k 0 }
      for k in [0:Nat.min p.dys.size c] do
        pos := pos.setIfInBounds (o + k) { pos.getD (o + k) {} with dy := p.dys.getD k 0 }
      -- `resolve_rotate_list`: a character past the end of the list keeps the
      -- last angle seen, and that "last" carries across elements.
      if p.hasRot then
        for k in [0:c] do
          let a := if k < p.rots.size then p.rots.getD k 0 else lastRot
          if k < p.rots.size then lastRot := a
          pos := pos.setIfInBounds (o + k) { pos.getD (o + k) {} with rot := a }
    | _ => pure ()
  -- ---- 6. faces
  let mut needR := false
  let mut needB := false
  let mut needI := false
  for i in [0:total] do
    if cRend.getD i true then
      match (cProps.getD i default).face with
      | .regular => needR := true
      | .bold => needB := true
      | .italic => needI := true
  let faces := loadFaces needR needB needI
  -- ---- 7. the renderable characters, in order
  let mut rend : Array Nat := Array.emptyWithCapacity total
  for i in [0:total] do
    if cRend.getD i true then rend := rend.push i
  let rn := rend.size
  if rn == 0 then return (#[], used, none, #[])
  -- ---- 8. chunk by chunk
  -- A decoration rectangle breaks more often than a glyph-outline run: usvg
  -- starts a new one not only where the style changes but at *any* character
  -- that carries its own `dx`, `dy` or `rotate` (`GlyphCluster::
  -- has_relative_shift`, `text/layout.rs`) — `text-decoration/underline-
  -- with-{dy,rotate}-list-*.svg` give every character in the run a `dy`/
  -- `rotate`, and the reference draws one short underline per glyph rather
  -- than one line spanning the word.  All of a run's rectangles for one
  -- decoration kind still end up in a *single* path, though (below), same as
  -- its glyph outlines: usvg resolves one fill/stroke per (span, kind) pair
  -- against the whole thing, so a gradient across an underline spans the
  -- true run width even when the line itself is several disjoint segments.
  let mut placed : Array Placed := #[]
  -- T81: the metric-box union, in the same `<text>` user space as `placed`'s
  -- outlines -- see "Text bounding box" above.
  let mut mbox : Option Box := none
  -- T90: the same union per run style (`Placed.styleIdx`), for a layer on a
  -- `tspan`/`textPath` that sizes against its own glyphs.
  let mut sbox : Array (Option Box) := #[]
  let mut lastX : Int := 0
  let mut lastY : Int := 0
  let mut a : Nat := 0
  for _ in [0:rn] do
    if a ≥ rn then break
    -- the chunk is [a, b): it ends where the next absolute `x`/`y` begins,
    -- or at a `textPath` boundary
    let seg0 := cSeg.getD (rend.getD a 0) 0
    let mut b := a + 1
    for q in [a + 1 : rn] do
      let p := pos.getD (rend.getD q 0) {}
      if p.x.isSome || p.y.isSome || cSeg.getD (rend.getD q 0) 0 != seg0 then break
      b := q + 1
    let fk := cFlow.getD (rend.getD a 0) 0
    let flow := if fk == 0 then none else flows[fk - 1]?
    -- advances, with kerning
    let mut cl : Array Cluster := Array.emptyWithCapacity (b - a)
    for q in [a:b] do
      let i := rend.getD q 0
      let cp := chars.getD i 0
      let pr := cProps.getD i default
      let mut adv : Int := 0
      match faces.get pr.face with
      | some f =>
        let upem := if f.unitsPerEm == 0 then 1000 else f.unitsPerEm
        let gid := Font.glyphId f cp
        let mut fu : Int := Font.advance f gid
        if pr.kerning && q + 1 < b then
          let nextCp := chars.getD (rend.getD (q + 1) 0) 0
          fu := fu + Font.kern f gid (Font.glyphId f nextCp)
        adv := Int.ediv (fu * (pr.size * 256) + (upem / 2 : Nat)) upem
      | none => pure ()
      cl := cl.push { cp := cp, styleIdx := cStyle.getD i 0, props := pr, adv := adv, width := adv, natWidth := adv }
    -- `letter-spacing`, then `word-spacing` (usvg applies each only when some
    -- span of the chunk actually asks for it)
    if cl.any (fun c => c.props.letterSpacing != 0) then
      for q in [0:cl.size] do
        let c := cl.getD q default
        let adv := if q + 1 == cl.size then c.adv else c.adv + c.props.letterSpacing * 256
        cl := cl.setIfInBounds q
          (if adv ≤ 0 then { c with adv := 0, width := 0, dropped := true } else { c with adv := adv })
    if cl.any (fun c => c.props.wordSpacing != 0) then
      for q in [0:cl.size] do
        let c := cl.getD q default
        if isWordSep c.cp then
          cl := cl.setIfInBounds q { c with adv := c.adv + c.props.wordSpacing * 256 }
    -- `textLength`/`lengthAdjust` (`apply_length_adjust`, "spacing" mode
    -- only), per maximal same-`styleIdx` run, not per chunk, since a
    -- `textLength` on one `tspan` must leave its neighbours' widths alone
    -- (`textLength/on-a-single-tspan.svg`).  "spacingAndGlyphs" additionally
    -- scales each glyph outline horizontally about a pen position that is
    -- itself scaled by the *same* factor from the run's start — not just the
    -- glyph in place — which needs the scale threaded into the chunk's own
    -- x-accumulation, not just `glyphCmds`; approximated here by the same
    -- "spacing" redistribution rather than left undone, since it reproduces
    -- the dominant visual effect (the run ends up `textLength` wide) even
    -- though the individual glyphs are not rescaled.
    if cl.any (fun c => c.props.textLength.isSome) then
      let mut i := 0
      for _ in [0:cl.size] do
        if i ≥ cl.size then break
        let styleIdx := (cl.getD i default).styleIdx
        let mut j := i + 1
        for q in [i + 1 : cl.size] do
          if (cl.getD q default).styleIdx == styleIdx then j := q + 1 else break
        match (cl.getD i default).props.textLength with
        | none => pure ()
        | some target =>
          let n := j - i
          let natSum : Int := Id.run do
            let mut s : Int := 0
            for q in [i:j] do s := s + (cl.getD q default).natWidth
            return s
          let factor : Int := if n > 1 then Int.ediv (target * 256 - natSum) (n - 1) else 0
          for q in [i:j] do
            let c := cl.getD q default
            cl := cl.setIfInBounds q { c with adv := c.natWidth + factor, dropped := false }
        i := j
    -- anchored chunk: the whole run shifts by its own width
    let width := cl.foldl (fun w c => w + c.adv) 0
    let anchor := (cl.getD 0 default).props.anchor
    let x0 : Int := match anchor with
      | .start => 0
      | .middle => -(Int.ediv width 2)
      | .atEnd => -width
    let p0 := pos.getD (rend.getD a 0) {}
    let chunkX : Int := match p0.x with | some v => v * 256 | none => lastX
    let chunkY : Int := match p0.y with | some v => v * 256 | none => lastY
    -- On a path (`resolve_clusters_positions_path`) the chunk's `x` is an extra
    -- offset along the path and its `y` is ignored; each cluster sits at the
    -- point of its advance midpoint, `dx` included.
    let nrm : Array (Option TextPath.Normal) := match flow with
      | some (tbl, so, acc) => Id.run do
        let mut s : Int := (p0.x.getD 0) * 256 + so + x0
        let mut offs : Array Int := Array.emptyWithCapacity cl.size
        for q in [0:cl.size] do
          let c := cl.getD q default
          s := s + (pos.getD (a + q) {}).dx * 256
          offs := offs.push (s + Int.ediv c.width 2)
          s := s + c.adv
        return TextPath.normals tbl acc offs
      | none => #[]
    let mut x : Int := x0
    let mut y : Int := 0
    -- SVG2's text-chunk algorithm computes the position handed to the next
    -- chunk (when it has no explicit `x`/`y` of its own) "before applying
    -- the text-anchor property" -- i.e. from this chunk's raw advance, not
    -- from its anchor-shifted glyph positions. `x` above is deliberately
    -- seeded with the anchor shift `x0` for glyph placement, so it can't
    -- also serve as that unshifted total; `adv` mirrors every update `x`
    -- receives but starts at 0, giving the next chunk's fallback pen the
    -- same shift-free value browsers agree on (`coordinates-list.svg`: the
    -- suite reference, Chrome and Safari all carry the raw advance forward,
    -- not resvg/Firefox's anchor-shifted one -- `docs/resvg-wrong/
    -- R5-text-props.md`).
    let mut adv : Int := 0
    let mut pathEnd : Int × Int := (0, 0)
    -- A style run never crosses a chunk boundary (`collect_decoration_spans`
    -- runs per chunk): every buffer below starts fresh each chunk and is
    -- flushed at the end of this `for`, never carried into the next one.
    --
    -- Within a run, a shift-break (see above) closes the *currently open*
    -- rectangle into the run's own buffer without flushing anything: usvg
    -- builds one path per (span, decoration kind) out of every rectangle the
    -- run produced (`convert_decoration`'s one `PathBuilder` for the whole
    -- `decoration_spans` slice) and resolves *one* fill/stroke against it, so
    -- a gradient painted across an underline spans the true run width even
    -- when the line itself is drawn as several disjoint segments
    -- (`underline-with-{dy,rotate}-list-2/4.svg`, both gradient-filled).
    let mut curStyle : Option Nat := none
    let mut curCmds : Array PathCmd := #[]
    let mut olIdx : Option Nat := none
    let mut ulIdx : Option Nat := none
    let mut thIdx : Option Nat := none
    let mut olCmds : Array PathCmd := #[]
    let mut ulCmds : Array PathCmd := #[]
    let mut thCmds : Array PathCmd := #[]
    let mut olRun : Option DecorRun := none
    let mut ulRun : Option DecorRun := none
    let mut thRun : Option DecorRun := none
    let closeSub := fun (cmds : Array PathCmd) (r : Option DecorRun) =>
      match r with | some r => cmds ++ decorRectCmds r | none => cmds
    let flushBuf := fun (placed : Array Placed) (idx? : Option Nat) (cmds : Array PathCmd) =>
      match idx? with
      | some idx => if cmds.size > 0 then placed.push ⟨idx, cmds⟩ else placed
      | none => placed
    for q in [0:cl.size] do
      let c := cl.getD q default
      -- usvg indexes `dx`/`dy`/`rotate` by the character's position among the
      -- *rendered* characters (`layout.rs` accumulates `char_offset` from the
      -- chunks' own text, which never contains a hidden span's characters),
      -- while chunk starts and `x`/`y` use the position among *all*
      -- characters.  `rotate-and-display-none.svg` pins this down.
      let p := pos.getD (a + q) {}
      let mut cmds : Array PathCmd := #[]
      -- T55: where a decoration run anchors (the pen before this advance)
      let mut ox : Int := chunkX + x
      let mut oy : Int := chunkY + y
      if flow.isSome then
        -- off the path: hidden, and its `dy` is not accumulated either
        match nrm.getD q none with
        | none => pure ()
        | some n =>
          -- `y` accumulates `dy`, applied across the tangent
          y := y + p.dy * 256
          pathEnd := (n.x + c.adv, n.y)
          if !c.dropped then
            match faces.get c.props.face with
            | some f =>
              -- T(n) · R(tangent) · T(-width/2, dy + baseline-shift) · R(rotate)
              --
              -- T54's `resolveBaseline16` gives the same pen offset the
              -- horizontal branch adds straight into `gy` (unrotated by the
              -- character's own `rotate`); here the perpendicular-to-path
              -- axis plays that role, so it folds into `y` exactly like `dy`
              -- does, before the tangent rotation -- not into the
              -- accumulator itself (`y` stays a pure `dy` running sum for
              -- the next character), just this glyph's own translation.
              let pr := c.props
              let bshift := resolveBaseline16 pr.dominantBaseline pr.alignmentBaseline
                pr.baselineShiftPx pr.baselineShiftSub pr.baselineShiftSuper f pr.size
              let yEff := y + bshift
              let (sr, cr) := if p.rot == 0 then ((0 : Int), (65536 : Int))
                else sinCos16 (degToRad16 p.rot)
              let hw := Int.ediv c.width 2
              let la := Int.ediv (n.cos * cr - n.sin * sr) 65536
              let lb := Int.ediv (n.sin * cr + n.cos * sr) 65536
              let lc := Int.ediv (-(n.cos * sr) - n.sin * cr) 65536
              let tox := n.x + Int.ediv (-(n.cos * hw) - n.sin * yEff) 65536
              let toy := n.y + Int.ediv (n.cos * yEff - n.sin * hw) 65536
              cmds := glyphCmdsLin f (Font.glyphId f c.cp) c.props.size la lb lc la tox toy
              let adv16 := if c.adv ≤ 0 then 65536 else c.adv
              let (top16, bot16) := metricTopBot f c.props.size
              for pt in metricCorners la lb lc la tox toy adv16 top16 bot16 do
                mbox := Box.cover mbox pt
                sbox := coverAt sbox c.styleIdx pt
            | none => pure ()
      else
        if vertical then
          y := y - p.dx * 256
          x := x + p.dy * 256
          adv := adv + p.dy * 256
        else
          x := x + p.dx * 256
          y := y + p.dy * 256
          adv := adv + p.dx * 256
        ox := chunkX + x
        oy := chunkY + y
        if !c.dropped then
          match faces.get c.props.face with
          | some f =>
            let (rot, gx, gy) :=
              if vertical then
                let upem := if f.unitsPerEm == 0 then 1000 else f.unitsPerEm
                -- centers the (rotated-sideways) glyph on the column, usvg's
                -- `apply_writing_mode` shift, before the 90° chunk rotation
                let half : Int := Int.ediv ((f.ascent + f.descent) * (c.props.size * 256))
                  (2 * upem)
                (p.rot + Fx.ofNat 90, chunkX - (y + half), chunkY + x)
              else
                -- T54 `resolve_baseline`: a per-span vertical offset
                -- (`dominant-baseline`/`alignment-baseline`/`baseline-shift`),
                -- added to the pen position only, never to `x`/`y`/`lastX`/`lastY`.
                let pr := c.props
                let bshift := resolveBaseline16 pr.dominantBaseline pr.alignmentBaseline
                  pr.baselineShiftPx pr.baselineShiftSub pr.baselineShiftSuper f pr.size
                (p.rot, chunkX + x, chunkY + y + bshift)
            let (la, lb, lc, ld) := rotMat16 rot
            cmds := glyphCmdsLin f (Font.glyphId f c.cp) c.props.size la lb lc ld gx gy
            let adv16 := if c.adv ≤ 0 then 65536 else c.adv
            let (top16, bot16) := metricTopBot f c.props.size
            for pt in metricCorners la lb lc ld gx gy adv16 top16 bot16 do
              mbox := Box.cover mbox pt
              sbox := coverAt sbox c.styleIdx pt
          | none => pure ()
        x := x + c.adv
        adv := adv + c.adv
      let styleChanged := curStyle != some c.styleIdx
      let shiftBreak := p.dx != 0 || p.dy != 0 || p.rot != 0
      if styleChanged then
        -- close the whole old run and flush it, in painter's order:
        -- overline, underline, its glyph outline, then line-through.
        olCmds := closeSub olCmds olRun
        ulCmds := closeSub ulCmds ulRun
        thCmds := closeSub thCmds thRun
        placed := flushBuf placed olIdx olCmds
        placed := flushBuf placed ulIdx ulCmds
        placed := match curStyle with
          | some s => if curCmds.size > 0 then placed.push ⟨s, curCmds⟩ else placed
          | none => placed
        placed := flushBuf placed thIdx thCmds
        curStyle := some c.styleIdx
        curCmds := #[]
        olIdx := c.props.overlineIdx; ulIdx := c.props.underlineIdx; thIdx := c.props.throughIdx
        olCmds := #[]; ulCmds := #[]; thCmds := #[]
      else if shiftBreak then
        -- only the currently open rectangle closes; the run (and its
        -- buffers) keeps going.
        olCmds := closeSub olCmds olRun
        ulCmds := closeSub ulCmds ulRun
        thCmds := closeSub thCmds thRun
      if styleChanged || shiftBreak then
        let mkRun := fun (idx? : Option Nat) (metric : Font → Int) =>
          match idx?, faces.get c.props.face with
          | some idx, some f =>
            some { styleIdx := idx, ox := ox, oy := oy, rot := p.rot, width := 0,
                   unitsPerEm := f.unitsPerEm, size := c.props.size,
                   dyUnits := metric f, thicknessUnits := f.underlineThickness : DecorRun }
          | _, _ => none
        olRun := mkRun olIdx (·.ascent)
        ulRun := mkRun ulIdx (·.underlinePosition)
        thRun := mkRun thIdx (·.strikeoutPosition)
      -- the run's width counts every character's advance, dropped or not,
      -- the same way the pen itself always moves on.
      olRun := olRun.map (fun r => { r with width := r.width + c.adv })
      ulRun := ulRun.map (fun r => { r with width := r.width + c.adv })
      thRun := thRun.map (fun r => { r with width := r.width + c.adv })
      curCmds := curCmds ++ cmds
    olCmds := closeSub olCmds olRun
    ulCmds := closeSub ulCmds ulRun
    thCmds := closeSub thCmds thRun
    placed := flushBuf placed olIdx olCmds
    placed := flushBuf placed ulIdx ulCmds
    placed := match curStyle with
      | some s => if curCmds.size > 0 then placed.push ⟨s, curCmds⟩ else placed
      | none => placed
    placed := flushBuf placed thIdx thCmds
    if flow.isSome then
      lastX := pathEnd.1
      lastY := pathEnd.2
    else
      -- usvg swaps (not rotates) the chunk's final pen position for the next
      -- chunk's fallback anchor; see the `layout` docstring. Only the
      -- primary (anchor-shiftable) axis needs `adv` in place of `x`: `y`
      -- never receives `x0`, in either orientation.
      lastX := chunkX + (if vertical then y else adv)
      lastY := chunkY + (if vertical then adv else y)
    a := b
  return (placed, used, mbox, sbox)

end Text
end LeanSvg
