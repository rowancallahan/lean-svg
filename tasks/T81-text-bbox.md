# T81 — filters on text, and textPath baseline-shift  (branch `claude/fix-text-bbox`)

T51 skipped filters on `<text>`: usvg uses the text layout bounding box (not
the glyph outlines) as the filter's object bounding box. T54's baseline
shift is not applied to glyphs on a textPath (the integrator only wired it
into the horizontal branch).

## Diagnosis

**`text/text/filter-bbox.svg`, `text/letter-spacing/filter-bbox.svg`.**
Rendering the unpatched binary shows the actual root cause is bigger than a
wrong-shaped box: `<text>` never applies a `filter` at all. The `<text>`
branch in `Svg.interpret` (`LeanSvg/Svg.lean`) opens and closes its own
compositing layer inline — unlike every other element, it never runs through
the shared `enter`/`frame` machinery at the bottom of the main loop that
wires `hasFilter`/`frame.filterAt` into a layer's `GroupInfo` (T51,
`LeanSvg/Svg.lean` around the `.close` handler's "T51: the object bounding
box is complete" comment). So `st.filterRaw` was simply never read for a
`<text>` element: `filter-bbox.svg`'s filtered `<text id="text1">` rendered
as plain black glyphs with no green `feFlood` at all, confirmed by rendering
both files and diffing against `resvg -w 200` pixel-for-pixel.

Separately, *if* filters were wired up, they would need the right object
bounding box. `crates/usvg/src/text/layout.rs`'s `convert_span` (usvg
0.48.1) builds a `<text>`'s bbox from each visible glyph cluster's *font
metrics* — `NonZeroRect::from_xywh(0.0, -cluster.ascent, advance,
cluster.height())` — transformed by that cluster's own `transform()`, not
from the glyph outlines `Text.layout` already produces. This is why the
reference flood in `text/filter-bbox.svg` extends below the baseline even
though "Text" has no descenders, and why `letter-spacing/filter-bbox.svg`'s
box does not grow past the first/last glyph's own advance (letter-spacing
only inserts space *between* clusters in usvg's model, never before the
first or after the last — `convert_span`'s per-glyph rectangle, placed only
at that glyph's own pen position, gets this right by construction). Our old
`tbox` computation (`Svg.lean`'s `<text>` branch) took the union of the
placed glyphs' *outline* boxes (`cmdsBox`) instead, which is both a
different box and, moot without the filter being applied, the wrong input.

**`text/textPath/with-baseline-shift.svg`.** `Text.layout`
(`LeanSvg/Text.lean`) has two glyph-placement branches sharing one `for`
loop: the horizontal/vertical branch computes `bshift := resolveBaseline16
...` and folds it into the glyph's pen position (`chunkY + y + bshift`); the
`flow.isSome` (textPath) branch never calls `resolveBaseline16` at all, so
every glyph sits on the path's own baseline regardless of `baseline-shift`.
Confirmed against `crates/usvg/src/text/layout.rs`'s
`resolve_clusters_positions_path`, which computes the same `resolve_baseline`
value per cluster (`let baseline_shift = ... -resolve_baseline(span, font,
writing_mode)`) and folds it into the perpendicular-to-path offset alongside
`dy` (`let shift = kurbo::Vec2::new(0.0, (dy - baseline_shift) as f64)`,
`cluster.transform.pre_translate(...)`), *before* the tangent rotation and
*not* affected by the glyph's own `rotate` — i.e. structurally the same
"add to the perpendicular pen offset, unrotated by the character's own
`rotate`" shape our horizontal branch already has for `bshift`, just
expressed along the path's normal instead of the page's `y` axis.

## Fix

**`LeanSvg/Text.lean`**

* `resolveBaseline16` is now also called from the `flow.isSome` branch of
  `layout`'s per-glyph loop, added into the local `y` (the path's own
  perpendicular running offset, i.e. same axis `dy` already uses) right
  before the tangent-rotation translate is built — mirroring exactly how the
  horizontal branch adds `bshift` straight into `gy`, unrotated by the
  glyph's own `rotate`. The `y` accumulator itself is untouched (it stays a
  pure `dy` running sum for the next character), matching how the horizontal
  branch's own `y` accumulator never gains `bshift` either.
* New: `rotMat16` (factored out of `glyphCmds`, used unchanged there too),
  `metricCorners` and `metricTopBot` — build one glyph cluster's *font-metric*
  rectangle (`(0, -ascent)` to `(advance, -descent)`, advance clamped up to
  one pixel when it collapsed to zero or below, matching usvg's own clamp)
  through the exact same rotation + translation `glyphCmdsLin` applies to the
  glyph's own outline, so the box lands in the same `<text>` user space.
  `layout` now folds every visible glyph's four corners (both placement
  branches) into a running `Option Box` via `Box.cover` and returns it
  alongside `Placed`/the character count — `Array Placed × Nat × Option Box`.

**`LeanSvg/Svg.lean`**

* `textShapes` threads the new `Option Box` through as `mbox` and returns it
  (`Array Shape × Nat × Option Box`); its one other caller (marker content)
  discards it, since usvg does not instantiate markers on `<text>` either
  (existing T52 note).
* The `<text>` branch's `tbox` (what feeds a `clip-path`/`mask` use's own
  bbox, and the parent frame's bbox) is now `mbox` directly instead of
  `shs.foldl (Box.union · (cmdsBox sh.cmds)) none` over the glyph outlines.
* `<text>` now wires up `filter` the same way the shape/image branch's
  `hasFilter`/`should_isolate` logic does (`st.filterRaw` non-`none`, per
  T51), but resolved *inline* rather than deferred to `.close`: because
  `<text>` opens and closes its own layer in one place (it never visits the
  shared `enter`/`.close` machinery other containers do), the object
  bounding box (`tbox`) is already available by the time the layer is
  decided, so `Filter.resolve` runs right there and the `groupBegin` is
  built with `filters`/`filterCtm`/`dropped`/`passthrough` already set,
  instead of pushing a bare `GroupInfo` and patching it later. `want` (does
  the layout need `tbox` at all) now also considers `hasFilter`, matching
  `slot.isSome`/`mslot.isSome`/`pf.want`.

## What was skipped and why

* No skips: both bugs the task named are fixed, and filters on `<text>`
  (which turned out to be the real gap behind the first one) are wired up
  the same way every other filterable element already is, reusing
  `Filter.resolve`, `Render.lean`'s existing `dropped`/`passthrough` handling
  (already generic over any `GroupInfo`, so no `Render.lean` change was
  needed), and the same `ElemCtx` shape the `.close`-time patch builds.
* Vertical (`writing-mode: tb`) glyphs go through the same box formula as
  horizontal ones (the 90°-rotation-plus-centring usvg's own
  `apply_writing_mode` folds into the transform *before* `convert_span` runs
  is likewise already folded into `(rot, gx, gy)` before `glyphCmds`/our new
  box code run), so this is not a separate case — no corpus file exercises
  filter-on-vertical-text specifically, but nothing here special-cases
  horizontal vs. vertical either.

## Report

Build: `lake build` clean, no new warnings. `bash scripts/check-theorems.sh`
prints `theorems ok` (`proofs/SizeBound.lean` untouched by this change: no
new `render` code path, no change to worst-case sizes).

Target files (`resvg` corpus, `direct` route, 200 px, within-8):

| file | before | after |
|---|---|---|
| `text/letter-spacing/filter-bbox.svg` | 83.993% (fail) | 100.000% (pass) |
| `text/text/filter-bbox.svg` | 76.353% (fail) | 100.000% (pass) |
| `text/textPath/with-baseline-shift.svg` | 89.422% (fail) | 99.743% (pass) |

Full `resvg` corpus (1679 files), both widths, `--compare` against a
pre-edit baseline: **zero pass→fail regressions** at either width.

* fast (100 px): 1521/1679 pass (90.6%) → 1530/1679 (91.1%); 9 newly
  passing, 0 newly failing.
* default (200 px): 1542/1679 pass (91.8%) → 1550/1679 (92.3%); 8 newly
  passing (one file, `painting/visibility/bbox-impact-3.svg`, was already
  passing and moved from 99.070% to 99.987%), 0 newly failing.

Newly-passing files beyond the three named above (all incidental fallout of
the same two fixes, not separately targeted): `text/textPath/m-L-Z-path.svg`,
`text/textPath/with-baseline-shift-and-rotate.svg` (baseline-shift-on-path),
`masking/clipPath/clip-path-with-transform-on-text.svg`,
`text/alignment-baseline/middle-on-textPath.svg`,
`text/alignment-baseline/two-textPath-with-middle-on-first.svg` (all three:
`<text>`'s `tbox` now uses the metric box, which several `clip-path`/
`alignment-baseline` corpus files also depend on for a correct
`objectBoundingBox`-derived transform), `painting/visibility/bbox-impact-3.svg`
(a filter-adjacent bbox case).

Local suite (`tests/run_tests.py`, 51 files including the new one): 47/51
pass, same 4 pre-existing failures as baseline (`12_badge`, `14_flower_
transforms`, `15_spiral_stroke`, `16_stress_2000` — unrelated to text/
filters); no file's score dropped (checked against a saved baseline
`results.json`, per-file `within` diff, zero regressions). New file
`tests/svg/81_text_bbox.svg` (filter-on-text metric bbox + textPath
baseline-shift): 99.796% exact, PASS.

`tests/run_adversarial.py`: 117/117 clean (116/116 baseline; the count
scales with `tests/svg/*.svg`, and this task added one).
`tests/run_tiles.py`: 51/51 byte-identical quadrant stitching (50/50
baseline, same reason).

Files changed: `LeanSvg/Text.lean`, `LeanSvg/Svg.lean`,
`tests/svg/81_text_bbox.svg`, `tasks/T81-text-bbox.md`.
