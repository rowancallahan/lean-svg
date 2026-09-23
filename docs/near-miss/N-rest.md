# N-rest — diagnosis of the 97–99% near-misses: rest

Same method as `N-paint.md`: rendered with `resvg` (font-pinned) and
`lean-svg` at `--width 200`, diffed at tol-8/threshold-99%, cropped to the
differing region (10 px padding) and zoomed ×4. `docs/near-miss/N-rest.png`
holds the one row: `resvg | ours | diff`.

## `masking/clipPath/clip-path-with-transform-on-text.svg` (0.986, exact 98.565%, within-8 98.575%)

```svg
<clipPath id="clip1" clipPathUnits="objectBoundingBox">
    <rect x="0.2" y="0.2" width="0.6" height="0.6" rx="0.1" ry="0.1"/>
</clipPath>
<text id="text1" fill="green" clip-path="url(#clip1)"
      font-family="Noto Sans" font-size="80"
      transform="translate(20 60) rotate(45)">Text</text>
```

**Where the diff is.** 570/40000 px, max_d 255, bbox (58,42)–(136,142).
Unlike `N-paint`'s `§5` (`with-text.svg`), this is **not** a thin halo
tracing every glyph outline — `docs/near-miss/N-rest.png` shows solid
multi-pixel chunks present in one render and absent in the other (a piece
of the "T"'s crossbar/serif area, a crescent along one side of the "e"),
i.e. the clip boundary is cutting through the glyph outlines at a
measurably different place, not just antialiasing their edges differently.

**Cause.** `clipPathUnits="objectBoundingBox"` resolves the clip rect's
`0.2/0.6/0.1`-fraction coordinates against `text1`'s own object bounding
box (`LeanSvg/Clip.lean:317-322`, the `e.objectBBox` branch of `Clip.build`,
which multiplies the clip's transform by `Svg.Box.unitMat b` for whatever
box `b` the caller passes in for this element). Text is converted to
ordinary flattened glyph-outline path commands before this stage (no
separate font-metric bounding box exists anywhere in `LeanSvg/Text.lean`
— confirmed by grep, zero hits for any box/bbox computation there), so `b`
is the tight control-point box (`Grad.tightBox`/`Box.cover`, the same
mechanism `N-paint §1`'s gradient `objectBoundingBox` case uses) over the
*rendered* glyph outlines. Those outlines are themselves subject to
whatever sub-pixel difference exists between our glyph rasteriser and
resvg's (the same general residual as `N-paint §5`/`with-text.svg`, and the
subject of the sibling `N-text` task) — normally invisible at the tol-8
threshold on its own, since a glyph-outline difference of a fraction of a
device pixel stays well under 8/255.

Here, though, that tiny bbox difference is **multiplied by the clip
rectangle's own size and then rotated 45°** (the element's `transform=
"translate(20 60) rotate(45)"` composes with the `objectBoundingBox` unit
matrix before the clip mask is rasterised): a bounding box that is off by a
small fraction of a percent gets scaled up by the box's own ~60–70 user-unit
size, and a rect edge that shifts by even one device pixel at 45° sweeps
across several pixels of a diagonal glyph stroke — turning a sub-threshold
outline difference into an above-threshold "this pixel belongs to the
letter in one render and not the other" difference exactly where the
(correctly axis-aligned, but bbox-scaled) clip rectangle's rounded corner
crosses a glyph.

**Code location:** `LeanSvg/Clip.lean:317-322` (`objectBoundingBox`
resolution, the amplification point — not itself wrong, see below) and
`LeanSvg/Font.lean`/`LeanSvg/Text.lean` (glyph outline generation — the
actual source of the small bbox difference being amplified; no single line
identified, same caveat as `N-paint §5`).

**Proposed fix:** none — the amplification site (`Clip.lean`) is doing
exactly what the spec requires; the fix, if any, belongs to whatever makes
`N-paint §5`/`N-text`'s glyph-outline residual smaller in the first place.
This file is evidence that that residual, small as it usually is, is worth
closing eventually: it is the one place in this task's whole file list
where a sub-pixel glyph difference is visibly amplified into multi-pixel
chunks rather than staying a thin AA halo.

**Size:** N/A (no fix proposed here; would inherit whatever size the
glyph-rasterisation fix turns out to be).

**Risk:** N/A for the same reason. Note for whoever does pick up the glyph
residual: this file is a good regression check specifically for the
*amplification* behaviour (rotated + scaled `objectBoundingBox` clipping on
text), which the more numerous plain-text files in `N-text` do not exercise.

## Groups by shared cause

Only one file in this task's list; no grouping table needed. Its cause
(glyph-outline residual, amplified by a rotated `objectBoundingBox` clip)
is a **specific consequence** of `N-paint §5`'s general text residual, not
an independent bug — recorded as a separate finding here only because this
task's own file list put it in a different task file from the plain-text
near-misses.
