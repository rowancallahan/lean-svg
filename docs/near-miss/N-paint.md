# N-paint — diagnosis of the 97–99% near-misses: paint

Method: every file below was rendered with both `resvg` (font-pinned to the
suite's own fonts) and our `lean-svg` binary at `--width 200`, per-pixel
diffed at the corpus's own tolerance (max abs channel diff ≤ 8) and
threshold (99% of pixels within tolerance), then cropped to the differing
region (10 px padding) and zoomed ×4 nearest-neighbour so single AA levels
are visible. `docs/near-miss/N-paint.png` has one row per file in the same
order as this document: `resvg | ours | diff` (diff is white where the two
match, red where they don't, intensity ∝ the per-pixel difference). All
renders are `lean-svg` at commit `101e54d` (this branch's tip when the
render pass started) against `resvg`/`usvg` 0.48.1.

Five distinct root causes cover all 24 files. Three are genuine sub-pixel
antialiasing/rounding residuals exactly as the task brief expects; two
(**§2** and, to a lesser extent, **§4**'s first file) are real dropped
functionality that happens to be small enough in area to still land at
97–99% rather than failing outright — flagged clearly below since "diagnose
only" does not mean "assume it's AA".

---

## Per file

### §1 — circle / cubic-curve flattening residual (14 files)

Every file in this group's diff sits **only on curved edges**, is a thin
(1–2 device px) AA-level halo, and disappears entirely off the flattened
straight parts of the same path. This is the renderer's own documented,
accepted gap: `LeanSvg/Geom.lean`'s dashing section (comment above
`maxDashes`, lines 820–833) states that dash lengths are measured along the
*flattened* polyline with `Fx.hypot`, while tiny-skia measures along the
true curve (`ContourMeasure`), leaving "below a tenth of a pixel on a
circle" of phase drift; independently, `tasks/T17-cubic-subdivision.md`'s
own `## Report` measured the *exact* Bernstein evaluation in `cubicAt`
(`LeanSvg/Geom.lean:278`) against tiny-skia's forward-differencing at the
same `segCount` (`LeanSvg/Geom.lean:220`) subdivision count and found "a
tenth of a pixel at the very worst cubic... well inside one AA level" —
enough, on these specific shapes, to tip a handful of edge pixels across
the tol-8 boundary.

All scores below are `within-8 / exact` (percent of pixels matching within
tolerance 8, and exactly, respectively).

- `painting/stroke-dasharray/comma-ws-separator.svg` (task list 0.989;
  measured 98.887% / 98.885%) — `circle r=70`, dasharray `"10, 20"`. Diff
  bbox (25,25)–(174,174) (the ring), 445/40000 px, max_d 144. Speckle
  evenly around the whole circumference of every dash and gap edge.
- `painting/stroke-dasharray/em-units.svg` (0.987; 98.680% / 98.677%) —
  same circle, dasharray `"2em 1em"` at `font-size=20`. Diff bbox identical
  ring, 528 px, max_d 129.
- `painting/stroke-dasharray/mm-units.svg` (0.981; 98.145% / 98.142%) —
  same circle, `"5mm 2.5mm"`. 742 px, max_d 176 (worst of the dasharray
  set — `mm` resolves to a pattern whose period is least aligned with the
  circle's own flattening error).
- `painting/stroke-dasharray/odd-count.svg` (0.989; 98.860% / 98.858%) —
  same circle, `"10 20 30"` (odd length, doubled per spec). 456 px, max_d
  143.
- `painting/stroke-dasharray/ws-separator.svg` (0.988; 98.838% / 98.835%) —
  same circle, `"10\t20"`. 465 px, max_d 143.
- `painting/stroke-dashoffset/default.svg` (0.988; 98.838% / 98.835%) —
  same circle, `"10 20"` offset 0. Byte-for-byte the same diff as
  `ws-separator.svg` above (offset 0 is a no-op, so both reduce to the
  identical dashed circle).
- `painting/stroke-dashoffset/em-units.svg` (0.988; 98.838% / 98.835%) —
  offset `1.5em` at `font-size=20` = 30 = the pattern sum, so the phase is
  identical to `default.svg`'s; same diff.
- `painting/stroke-dashoffset/mm-units.svg` (0.989; 98.873% / 98.870%) —
  offset `1.5mm`. 451 px, max_d 160.
- `painting/stroke-dashoffset/negative-value.svg` (0.989; 98.880% /
  98.875%) — offset `-5`. 448 px, max_d 159.
- `painting/stroke-dashoffset/percent-units.svg` (0.989; 98.927% /
  98.925%) — offset `20%` (of the viewport diagonal). 429 px, max_d 159;
  bbox one column narrower (172 vs 174) because the percent resolves
  slightly differently and shifts the phase off the exact quadrant
  boundary.
- `painting/stroke-dashoffset/px-units.svg` (0.989; 98.880% / 98.875%) —
  offset `5px`, numerically identical to `negative-value.svg`'s effective
  phase after `mod S`; same diff.
- `shapes/path/M-C-S.svg` (0.990; 98.990% / 98.987%) — `M 30 40 C 16 137
  171 45 100 90 S 171 45 180 155`, no dashing at all. Diff bbox
  (26,39)–(182,155), 404 px, max_d 130, confined to a thin double-line
  straddling the stroke's curved passages (the zig-zag's straight segment
  between the two curves is exact). Confirms the residual is in curve
  flattening itself, independent of dashing.
- `shapes/path/M-S-S.svg` (0.990; 98.962% / 98.960%) — `M 30 40 S 160 45
  160 140 S 45 160 50 60`, two chained smooth cubics (each reflecting the
  previous control point — `Svg.lean:1248-1255`, `parsePathData`'s `'s'`
  branch, itself byte-correct per SVG 1.1 §8.3.6 and unrelated to this
  residual). 415 px, max_d 128, same thin curve-only halo.
- `painting/marker/marker-on-circle.svg` (task list 0.985; measured
  98.510% / 97.793%) — a `circle r=80` with three
  triangular markers. Visual check (`docs/near-miss/N-paint.png` row 8)
  shows the **markers themselves match resvg exactly, pixel for pixel** —
  the entire diff (596 px, max_d 255 from one stray far-outlier pixel,
  `mean_abs` only 0.115) is a faint dotted ring around the circle's own
  stroke, identical in character to the dasharray group above. This file
  belongs here, not in the marker groups below.

**Code location:** `LeanSvg/Geom.lean:220-263` (`segCount`/`segCountQuad`,
already tiny-skia-exact per T17), `LeanSvg/Geom.lean:278-288` (`cubicAt`,
exact Bernstein vs. tiny-skia's forward-differencing), `LeanSvg/Geom.lean
:829-833` (dash-length-on-chords vs. arc-length, doc comment).

**Proposed fix:** none that is both small and safe. T17's own report already
quantified porting forward-differencing rounding into `cubicAt` and found
the gain (~0.1 device px worst case, over 240 external-corpus files) "not
worth it now" given it touches the one function every curve in every shape,
clip path, mask, marker and pattern in the renderer flattens through.
Porting arc-length dash measurement (walking the flattened polyline with
per-vertex arc-length correction, or dashing before flattening à la a true
`ContourMeasure`) is more contained but still touches `Geom.lean`'s shared
dashing code.

**Size:** small in principle (a rounding-mode change to one hot function)
but **would touch every curve rendered anywhere** — cubics, quadratics,
arcs-as-cubics, ellipses, rounded rects, glyph outlines, pattern/marker
content.

**Risk: the highest of any group here.** `cubicAt`/`segCount` are the single
most shared code path in the renderer (`Raster.lean`'s own module doc calls
`Geom.lean`'s flattening "load-bearing"). T17's report already showed this
exact change moves scores on both directions (one file down 0.03 points,
eleven up) even when it was a pure win overall; a further tweak risks the
same kind of mixed movement across the **majority of the currently-passing
corpus**, not just these 14 files. Any change here needs the full
`run_corpora.py --corpus all --route both` sweep, not just this directory.

---

### §2 — `context-fill`/`context-stroke` unresolved inside `<marker>` content (4 files)

**Not an antialiasing issue.** In every file below, one or more marker
instances render as **fully invisible** (zero non-background pixels) where
resvg draws a solid shape. The reason these still land at 97–99% rather
than failing outright is purely that a 20×20-unit marker is a small
fraction of a 200×200 canvas.

Root cause, confirmed by direct inspection (`docs/near-miss/N-paint.png`
rows 3–6; per-vertex crops in the working notes measured the marker's own
drawn pixel bounding box, not just the aggregate score): `Style` carries
`ctxFill`/`ctxStroke` fields (`LeanSvg/Svg.lean:216-217`) that a
`Paint.context false/true` value (`fill="context-fill"` etc., parsed at
`LeanSvg/Svg.lean:883-884`, resolved at `LeanSvg/Svg.lean:1572`) reads.
These fields are populated in **exactly one place in the whole
interpreter**: entering a `<use>` element sets `ctxFill := noAlpha st.fill`
/ `ctxStroke := noAlpha st.stroke` from the `<use>`'s own resolved paint
(`LeanSvg/Svg.lean:3723-3728`, T47's own comment there literally says
`context-fill`). A `<marker>`'s content, however, is interpreted **once, at
marker-definition time**, into `MarkerEntry.content` (`Svg.lean`'s
`.markerDef` frame, around line 3994-4043) — long before any referencing
shape is known — and `Marker.expandContentList`
(`LeanSvg/Marker.lean:337-405`), which later splices that content in once
per vertex, copies each shape's `Style` verbatim except for `ctm` and
`clips` (`LeanSvg/Marker.lean:358-361`): it never touches `ctxFill`/
`ctxStroke`. So `context-fill`/`context-stroke` used directly inside a
`<marker>`'s own content — as opposed to inside a `<use>`, which T85 already
fixed for the gradient/pattern case — always resolves to `Paint.none` (the
struct's own default, `Svg.lean:216-217`), i.e. transparent.

- `painting/context/in-marker.svg` (0.980, within-8 98.035%, exact
  97.995%) — marker path `fill="context-stroke" stroke="context-fill"`,
  referencing `path1`
  (`fill="green" stroke="blue"`), on a 5-point star. Both properties are
  `.context`, so **all 6 marker instances (start+end share vertex 0, plus 4
  mids) are fully invisible**; the diff is exactly their 5 visible screen
  positions (786 px, confirmed empty in `ours` by direct pixel inspection —
  the small blue speckle visible in a naive crop is the star's own
  1-user-unit blue stroke, not a marker). `in-nested-use-and-marker.svg`
  below produces byte-identical output to this file (786/40000, same
  bbox) because the outer `<use>` only changes the outer path's own paint,
  not the marker-content resolution bug.
- `painting/context/in-nested-use-and-marker.svg` (0.980; 98.035% /
  97.995%) — same bug, one level removed through a `<use>`: `path1` (`stroke="context-fill"`,
  itself resolved correctly since `path1` is used, not the marker) is
  referenced via `<use xlink:href="#path1" stroke="red" fill="blue"/>`; its
  marker's content (`fill="context-stroke" stroke="context-fill"`) hits the
  identical unresolved-inside-marker path. Diff identical to `in-marker.svg`
  above (786/40000, same bbox), confirming the `<use>` layer is a red
  herring — the bug is purely in `Marker.expandContentList`.
- `painting/context/in-nested-marker.svg` (0.972, within-8 97.150%, exact
  97.130%, the worst of this group) — `marker2`'s content (`fill="red"`
  **hardcoded**, `stroke="context-fill"`) is itself referenced by
  `marker1` (nested:
  `marker1`'s `rect` has `fill="context-stroke" stroke="context-fill"`).
  Visual check confirms exactly the compounding this predicts: the plain
  `fill="red"` triangle **does** render (not `.context`, unaffected), but
  its `context-fill` stroke outline is missing, *and* every nested
  `marker1` instance (the small squares at each triangle's corners in
  resvg's render) is fully invisible. 1140/40000 px, the largest diff area
  of the group because two markers' worth of content is affected per
  vertex.
- `painting/context/with-gradient-on-marker.svg` (0.984, within-8 98.377%,
  exact 98.360%) — marker content is `fill="context-fill"` only (no
  stroke), referencing
  `path1` whose own fill is `url(#lg)` (a gradient, not a flat colour —
  confirms the gap is about the *marker* attachment point, not specifically
  about T85's `<use>`-vs-gradient case). All 5 visible marker positions
  fully invisible, 649/40000 px.

**Code location:** `LeanSvg/Marker.lean:357-366` (`expandContentList`'s
`.shape` branch — needs to rewrite `s.style.fill`/`stroke` when they are
`Paint.context _` before pushing `s'`); `LeanSvg/Svg.lean:212-217`
(`ctxFill`/`ctxStroke` fields) and `:3723-3728` (the only existing setter,
for reference). `tasks/T73-context-markers.md` scoped exactly this
(title: *"context-fill/context-stroke inside markers resolve to the
referencing shape's fill/stroke in usvg"*) but was never carried out — it
has no `## Report` section, and its listed scores for these five files are
identical, to four decimal places, to what this render pass measured today,
confirming nothing has touched this path since.

**Proposed fix:** thread the referencing shape's own resolved `(fill,
stroke)` as two extra `Paint` parameters through `expandContentList`
(alongside `fuel`/`active`/`extraCtm`), and in the `insideMarker` branch of
the `.shape` case, substitute `s.style.fill`/`.stroke` when they carry
`Paint.context false`/`Paint.context true` before building `s'`. The one
real subtlety, visible in `in-nested-marker.svg`: usvg resolves
`context-fill`/`context-stroke` against the *original* referencing element
at every nesting level (not against whichever marker is one level up), so
the pair must be captured once at the outermost `expand` call and passed
down unchanged through recursive marker-in-marker instancing, not
re-derived from `s'` at each level.

**Size:** small and local — one new pair of parameters on one recursive
function, plus a 2-way match on `Paint.context` at one call site. No new
control flow, no new data on `Style` (`ctxFill`/`ctxStroke` already exist).

**Risk: low, and well-isolated.** `expandContentList` only runs when
`doc.markers` is non-empty (`Marker.expand`'s own guard, `Marker.lean:415`),
and the substitution only fires on shapes `insideMarker` whose paint is
literally `Paint.context _` — every other shape, marker or not, is
byte-identical before and after. The one file to re-check closely after a
fix is `with-pattern-on-marker.svg` (outside this task's file list,
currently failing well below 90%): T52's own report already flagged that
file's score moving (87.89% → 86.94%, fail→fail) the last time marker
instancing changed, for the same reason (context resolution interacting
with an unsupported pattern fill) — worth a specific look, not a blocker.

---

### §3 — marker-then-stroke compositing seam under `paint-order` (3 files)

- `painting/paint-order/markers.svg` (0.983, within-8 98.310%, exact
  98.308%) — `paint-order="markers"` (markers, then fill, then stroke — the
  SVG2 default order with `markers` pulled to the front). 676/40000 px,
  max_d 255.
- `painting/paint-order/markers-stroke.svg` (0.983; 98.310% / 98.308%) —
  `paint-order="markers stroke"` (markers, stroke, fill). Byte-identical
  diff to `markers.svg` (same 676 px, same bbox) — the trailing `fill`
  position doesn't matter since fill and markers never overlap here.
- `painting/paint-order/fill-markers-stroke.svg` (0.988, within-8 98.800%,
  exact 98.797%) — `paint-order="fill markers stroke"` (SVG2's actual
  default order, spelled out). 480/40000 px — fewer than the other two
  because with `fill` first instead of `markers` first, less of the
  marker's edge ends up double-antialiased against non-background content
  (see below).

All three files use the identical marker (`refX/Y=10`, `markerWidth/Height
=40`, content a hardcoded `fill="orange"` 20×20 `rect`, `markerUnits=
"userSpaceOnUse"`) on the identical path (a `stroke-width=5` blue-stroked,
green-filled 160×160 square). Two probes isolate the cause precisely:

1. A hand-built variant of `markers.svg` with `overflow="visible"` added to
   `marker1` scores within-8 `0.9831` / exact `0.983075` — matching the
   original file's own metrics to the precision measured (`within-8
   98.310%`, `exact 98.308%`) — ruling out the marker's own
   `overflow:hidden` clip rectangle
   (`LeanSvg/Svg.lean:4016-4037`) as a contributor, since with `visible` no
   clip mask is built at all (`clip := false` short-circuits
   `clipEntryIdx`) and nothing changes.
2. The same path *without* any marker reference (`marker-start`/`-mid`/
   `-end` removed entirely) scores 100.0% within-8, effectively
   byte-identical to resvg (`mean_abs` 6×10⁻⁶, `max_d` 1) — ruling out the
   plain stroke's own miter-join geometry.

So the defect is produced only where the marker's orange rectangle and the
path's own painted stroke geometrically overlap, and only once both are
actually drawn (order 1 or 2 above). The diff in `docs/near-miss/N-paint.png`
(row 9) sits in four small squares, one at each of the four vertices, each
covering almost exactly the region where the marker rect and the 5px-wide
blue stroke cross.

**Cause (medium confidence — narrowed but not proven to the exact
arithmetic step):** each shape is painted with its own independent
coverage-antialiasing pass, composited onto whatever is already on the
canvas via `Canvas.fillMask`/`Canvas.blendOver`
(`LeanSvg/Canvas.lean:99,225`). A pixel that is simultaneously an AA edge
of the marker rect *and* an AA edge of the stroke drawn over it gets
blended twice in sequence (marker-edge-coverage over background, then
stroke-edge-coverage over that result) rather than once with a single
combined coverage value the way a shared-scanline rasterizer would compute
it — and `Canvas.lean:38`'s `div255 (x) := (x + 255) >>> 8` is a **ceiling**
approximation of `x / 255` (it rounds every fractional byte up, never down
or to nearest — e.g. `div255 1 = 1` where the true value rounds to `0`),
so two chained roundings at the same doubly-antialiased pixel compound in
the same direction rather than canceling. This is consistent with every
symptom observed (overlap-only, order-dependent in exactly the way
compositing order would predict, absent when either layer is flat) but was
not cross-checked against tiny-skia's own `div255`/blend-rounding formula
in this session — that comparison is the concrete next step before trusting
this as the final answer.

**Code location:** `LeanSvg/Canvas.lean:38` (`div255`), `:99` (`blendOver`),
`:225` (`fillMask`, the per-shape entry point both markers and ordinary
shapes paint through).

**Proposed fix:** none proposed pending the tiny-skia rounding comparison
above. If confirmed, the fix is a one-line change to `div255`'s formula —
but see risk below.

**Size:** tiny in code (one arithmetic expression) but the function is
`@[inline]` and sits on **every** pixel of every filled or stroked shape,
gradient stop, pattern tile and text glyph in the renderer.

**Risk: very high if `div255` itself is touched, essentially zero if it
isn't.** This is the most shared arithmetic primitive in the renderer;
`run_tests.py`'s own suite currently scores several files at `exact ~100%`
byte-identical to resvg, which a `div255` rounding change would put at
risk across the board. Do **not** change `div255` without the full
`run_corpora.py --corpus all --route both` sweep plus `run_tests.py`
`exact%` regression check on every currently-100%-exact file. A safer,
smaller-blast-radius alternative worth exploring first: special-case only
the marker-content compositing path (`Marker.lean`'s instancing, `groupBegin
`/`groupEnd` wrapping) to flatten each instance's coverage into the same
pass as whatever paints after it, rather than touching the shared blend
primitive.

---

### §4 — pattern-tile rasterisation rounding (2 files)

Both files show a diff confined to a handful of pixels **repeated
identically at every tile instance** (`docs/near-miss/N-paint.png` rows 1–2)
— the tell for a per-tile rounding error in `LeanSvg/PatternRender.lean`'s
own rasterise-once-then-sample architecture (module doc, lines 1-34: a
pattern's content is rendered once onto its own small canvas at `Pat.build`
time, then every output pixel samples that canvas), rather than a
geometry or paint-resolution bug (paint-servers' pattern content itself —
colours, nesting, `objectBoundingBox` scaling — matches resvg exactly by
eye in every tile).

- `paint-servers/pattern/out-of-order-referencing.svg` (0.989, within-8
  98.905%, exact 98.900%) — diff bbox (36,20)–(163,89), confined to the
  **top** rect only (`rect5`, filled with `patt1` directly:
  `patternUnits="objectBoundingBox"
  width="0.15" height="0.3"`, `patternContentUnits="objectBoundingBox"`,
  content two `0.1×0.1` rects). The **bottom** rect (`rect6`, filled with
  `patt2`, `patternUnits="userSpaceOnUse"`, whose own content references
  `patt1` recursively — the "out of order" part, `patt2` is declared before
  `patt1` in document order) has **zero diff**. 438/40000 px, an "L"-shaped
  1-2px mark repeated at every one of the 6×4 tile boundaries visible in
  the crop.

  `patt1`'s tile size resolves to exact integers in user space
  (`0.15×160=24`, `0.3×70=21`, both exact — `rect5`'s bbox is 160×70), so
  `PatternRender.lean:259-260`'s `pxW`/`pxH` (`round16` of the *device*
  scale applied to those, `PatternRender.lean:255-261`) land on exact
  integers too and are not the source. The content rects inside that tile,
  though, are declared in `patternContentUnits="objectBoundingBox"` — i.e.
  as fractions (`0.1`, `0.1`) of the *pattern's own* 0.15×0.3 box
  (`PatternRender.lean:269-271`, the `contentOBB` branch of `contentMat`),
  giving `0.1/0.15 × 24px = 16px` and `0.1/0.3 × 21px = 7px` — also exact —
  **but** at the render's actual device scale (200/100 = ×2 for this
  file's `--width 200` vs. its natural 100×100 size) those numbers scale by
  a further, non-power-of-two factor before `round16` truncates each
  corner independently, so the two rects' shared edge (`rect3` ends where
  `rect4` begins, at local `(0.1, 0.1)`) can round to different device
  pixels on its two sides — exactly an "L"-shaped seam.

- `paint-servers/pattern/tiny-pattern-upscaled.svg` (0.979, within-8
  97.870%, exact 97.540%, the lowest score in this task) — a 2×2-user-unit
  tile (`patternTransform="scale(10)"`, `r=1` circle) tiled across a
  160×160 rounded rect. 852/40000 px, max_d 149, a faint dotted ring around
  **every** circle
  (confirming this is `§1`'s circle-flattening residual, replayed once
  per tile) plus a visibly stronger cluster at the container's two visible
  rounded corners (top-left, top-right in the crop) where **partial** tiles
  are clipped against the rounded-rect boundary — an extra rounding step
  (the partial tile's own clip mask, at the container's curve, itself
  subject to `§1`) stacked on top of the per-circle residual.

**Code location:** `LeanSvg/PatternRender.lean:233-273` (`build`: `sx16`/
`sy16` continuous device scale, `round16`/`pxW`/`pxH` quantisation to an
integer tile raster, `contentMat`'s `contentOBB` branch).

**Proposed fix:** none proposed at this size/confidence — the exact
device-pixel rounding tiny-skia's own pattern tile builder uses (whether it
quantises tile *content* coordinates independently per edge the way
`round16` does here, or carries a single sub-pixel translation through the
whole tile) needs to be read from `resvg`/`tiny-skia` source before
proposing a specific change; this file only narrows *where* in
`PatternRender.lean` to look.

**Size:** unknown without the tiny-skia comparison above; likely small
(rounding-mode change local to `build`'s tile-sizing arithmetic) but could
touch `contentMat` too.

**Risk: medium.** `PatternRender.lean:build` is the single entry point for
every pattern fill in the renderer (recursive for nested patterns per its
own module doc), so a change here is corpus-wide for anything using
`fill="url(#pattern...)"` — but narrower in scope than `§1`/`§3` since it
does not touch plain shape/gradient/text rendering at all. Re-run
`run_corpora.py` filtered to `paint-servers/pattern` at minimum, full
suite before pushing.

---

### §5 — text glyph antialiasing (1 file)

- `painting/context/with-text.svg` (0.970, exact 96.135%, within-8
  97.002%) — `context-fill` gradient correctly resolved (this element is
  reached via `<use>`, so `§2`'s bug does not apply), underline correctly
  drawn and positioned; the entire 1199/40000-px diff
  (`docs/near-miss/N-paint.png` row 7) is a thin halo tracing every glyph's
  own outline in "Text", present on every letter and the underline alike,
  absent everywhere else in the gradient-filled rect. This is the
  renderer's general glyph-rasterisation residual — the same class of
  sub-pixel outline difference the sibling `N-text` task's whole file list
  is about — showing up here only because it happens to combine with a
  `context-fill` gradient close enough to the 99% bar. Not a `context-fill`
  bug (the colour and gradient direction match resvg exactly), not a
  marker bug, not `§1`'s curve residual (glyph outlines go through a
  separate rasterisation path in `LeanSvg/Font.lean`/`LeanSvg/Text.lean`,
  not `Svg.parsePathData`/`Geom.flatten`).

**Code location:** `LeanSvg/Font.lean`/`LeanSvg/Text.lean` (glyph outline
generation) — no single line identified; this file does not add anything
`N-text`'s own text-focused pass would not already have found across its
larger file list, and is called out here mainly to record that it is
**not** a `context-fill`/marker/curve issue despite living in
`painting/context/`.

**Proposed fix / size / risk:** out of scope for this pass — defer to
`N-text`'s diagnosis, which covers the general glyph-outline residual
across many more examples and is better positioned to localise it.

---

## Groups by shared cause (largest first)

| # | Group | Files | Nature | Fix size | Risk to passing files |
|---|---|---|---|---|---|
| 1 | Circle/cubic curve-flattening residual (`Geom.lean` `cubicAt`/dash-length-on-chords) | 14 | Sub-pixel AA, accepted/documented gap | Small arithmetic, but the shared change is large in reach | **Very high** — `cubicAt`/`segCount` are load-bearing for every curve in the renderer |
| 2 | `context-fill`/`context-stroke` unresolved inside `<marker>` content | 4 | **Real bug**: marker instances render fully invisible | Small, local (`Marker.expandContentList` + 2 threaded params) | Low — gated on `doc.markers` non-empty and `Paint.context` shapes only |
| 3 | Marker-then-stroke compositing seam under `paint-order` | 3 | Sub-pixel AA at overlap of two separately-antialiased draws | Unknown until confirmed against tiny-skia; if `div255`, one line | **Very high** if `div255` is the fix; near-zero if scoped to marker compositing only |
| 4 | Pattern-tile rasterisation rounding | 2 | Sub-pixel AA, per-tile quantisation | Unknown pending tiny-skia comparison | Medium — scoped to `PatternRender.lean`, but corpus-wide for patterns |
| 5 | Text glyph antialiasing | 1 | Sub-pixel AA, general glyph residual | Deferred to `N-text` | Deferred to `N-text` |

Two files (`marker-on-circle.svg`'s markers rendering exactly, and the
`overflow:visible`/no-marker probes for `§3`) were checked and found
**not** to be the cause of their file's near-miss, which is why they don't
appear as separate findings above; recorded here so a future pass doesn't
re-investigate the same dead ends.
