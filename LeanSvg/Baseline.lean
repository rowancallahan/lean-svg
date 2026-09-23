import LeanSvg.Fixed
import LeanSvg.Font

/-!
# Text baselines (T54)

`dominant-baseline`, `alignment-baseline` and `baseline-shift`, matching usvg
0.48.1 (`crates/usvg/src/text/layout.rs`'s `resolve_baseline`,
`dominant_baseline_shift`, `alignment_baseline_shift` and
`resolve_baseline_shift`; `crates/usvg/src/parser/text.rs`'s
`convert_baseline_shift`).

A separate module rather than more of `LeanSvg/Text.lean` (a concurrent task
touches that file too, per `tasks/T54-text-baselines.md`): `Svg.lean` uses
`AlignmentBaseline` to type two new `Style` fields and to compute
`baseline-shift`'s own accumulation (see `Svg.textShapes`'s `bsStack`, which
this module does not otherwise touch), and `Text.lean` calls
`resolveBaseline16` once per glyph to get the 16.16 pen offset.

**`dominant-baseline` and `alignment-baseline`** are ordinary CSS-inherited
properties in this renderer (nearest ancestor's own value wins, `Svg.lean`'s
`applyProp`): one `AlignmentBaseline` type serves both `Style` fields, since
usvg funnels every `DominantBaseline` variant into the `AlignmentBaseline`
formula anyway (`dominant_baseline_shift`), and `dominant-baseline="no-change"`
— usvg's "use the parent element's own value" — is exactly what *not*
overriding the inherited `Style` field already does, so `applyProp` treats it
(and any other unrecognised token) as a no-op. usvg's own `no-change`
handling actually walks at most one extra ancestor level rather than the
whole chain (`SvgNode::find_attribute` on a non-inheritable `AId` only checks
a node's own attribute or its *direct* parent's), which this renderer's
plain-inherited `Style` field does not reproduce exactly; every file in
`tests/text/dominant-baseline` and `tests/text/alignment-baseline` only
nests shallowly enough (the value is always set on the run's own element or
its immediate parent) that the difference does not show, see the Report.

**`baseline-shift` does not inherit** through the ordinary cascade at all —
SVG/CSS reset it on every element, and its effect *accumulates* only through
an element's own explicit value at each `tspan` level (`convert_baseline_shift`
walks a run's enclosing `tspan` ancestors, summing each one's own attribute,
and stops *before* reaching the `<text>` element, so a `baseline-shift` on
`<text>` itself, or on any non-`tspan` ancestor such as `<g>`, never
contributes — `tests/text/baseline-shift/inheritance-*.svg` pin this down).
`Svg.textShapes` therefore keeps a small parallel stack (`bsStack`), seeded at
`(0, 0, 0)` for the `<text>` element itself and only ever pushed to by a
`tspan`'s *own* attribute, never derived from the ordinary `Style` cascade.
Each level contributes to one of: an absolute length/percentage (summed
directly, `Fx`), or a `sub`/`super` keyword (counted, since the actual pixel
offset needs the *leaf* span's font metrics — `resolveBaseline16` applies
`subscriptOffset`/`superscriptOffset` once, scaled by the count).
-/

namespace LeanSvg
namespace Text

/-- SVG's `alignment-baseline` keywords. `dominant-baseline` reuses the same
type: usvg's `dominant_baseline_shift` maps every `DominantBaseline` variant
onto one of these (`ideographic`→`ideographic`, …, and `auto`/`use-script`/
`reset-size`/the already-resolved `no-change` all onto `auto`), so one
`AlignmentBaseline.shift16` serves both `Style.dominantBaseline` and
`Style.alignmentBaseline`. -/
inductive AlignmentBaseline where
  | auto
  | baseline
  | beforeEdge
  | textBeforeEdge
  | middle
  | central
  | afterEdge
  | textAfterEdge
  | ideographic
  | alphabetic
  | hanging
  | mathematical
deriving DecidableEq, Repr, Inhabited, BEq

/-- `crates/usvg/src/text/layout.rs`'s `alignment_baseline_shift`, in 16.16
fixed point (1/65536 px, the precision `Text.layout` carries pen positions
in). `f` already carries the fully resolved font metrics (`Font.parse`'s
`ascent`/`descent`/`xHeight`); `sizeFx` is the span's `font-size` (`Fx`,
1/256 px). A positive result moves the glyph *down* (this renderer's `y`,
like usvg's, increases downward): e.g. `textBeforeEdge` is `ascent`, which
moves the glyph down by its ascent so that what was the top of the em box
now sits at the given anchor — the anchor becomes the *top* edge, so the
glyph, drawn below its own top, ends up lower on the page. -/
def AlignmentBaseline.shift16 (a : AlignmentBaseline) (f : Font) (sizeFx : Fx) : Int :=
  let upem := if f.unitsPerEm == 0 then 1000 else f.unitsPerEm
  let scaled := fun (v : Int) => Font.unitsToFx16 v sizeFx upem
  match a with
  | .auto => 0
  | .baseline => 0
  | .beforeEdge | .textBeforeEdge => scaled f.ascent
  | .middle => Int.ediv (scaled f.xHeight) 2
  | .central => Int.ediv (scaled f.ascent + scaled f.descent) 2
  | .afterEdge | .textAfterEdge => scaled f.descent
  | .ideographic => scaled f.descent
  | .alphabetic => 0
  | .hanging => Int.ediv (scaled f.ascent * 8 + 5) 10
  | .mathematical => Int.ediv (scaled f.ascent + 1) 2

/-- `crates/usvg/src/text/layout.rs`'s `resolve_baseline`, in 16.16.

`bpx` is the span's accumulated `baseline-shift` *length* contributions
(`Fx`, 1/256 px — usvg's `BaselineShift::Number` entries, summed);
`bsub`/`bsup` the accumulated `sub`/`super` keyword counts. Both come from
`Svg.textShapes`'s tspan-local walk, *not* from the ordinary `Style` cascade
— see the module docs. `dominant`/`alignment` are the ordinary
CSS-inherited `Style` fields.

Matches `resolve_baseline_shift`'s sign: a `Subscript` entry is `shift -=
subscriptOffset` and the whole thing is later negated (`-resolve_baseline_
shift`), so its net contribution here is `+subscriptOffset` — moves the
glyph down, as a subscript should; `Superscript` nets `-superscriptOffset`,
moving it up. -/
def resolveBaseline16 (dominant alignment : AlignmentBaseline) (bpx : Fx) (bsub bsup : Nat)
    (f : Font) (sizeFx : Fx) : Int :=
  let upem := if f.unitsPerEm == 0 then 1000 else f.unitsPerEm
  let subShift := Font.unitsToFx16 f.subscriptOffset sizeFx upem
  let supShift := Font.unitsToFx16 f.superscriptOffset sizeFx upem
  let baseShift :=
    if alignment == .auto || alignment == .baseline then dominant.shift16 f sizeFx
    else alignment.shift16 f sizeFx
  baseShift - bpx * 256 + (bsub : Int) * subShift - (bsup : Int) * supShift

end Text
end LeanSvg
