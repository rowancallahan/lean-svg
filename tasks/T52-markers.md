# T52 — markers  (branch `claude/feat-markers`)

Implement `<marker>` with `marker-start`, `marker-mid`, `marker-end` and the
`marker` shorthand (CSS/presentation attribute), matching usvg 0.48.1
(`crates/usvg/src/parser/marker.rs` — port its vertex/angle logic closely,
including bisector angles at mid vertices, the behaviour at subpath starts,
closepaths and curves). Target: `painting/marker` (47/63 failing).

Scope: `markerWidth`/`markerHeight`, `refX`/`refY`, `viewBox` +
`preserveAspectRatio`, `orient` (`auto`, `auto-start-reverse`, angle with
units), `markerUnits` (strokeWidth default, userSpaceOnUse), overflow clip
(default hidden), markers on `path`, `line`, `polyline`, `polygon` only (as
usvg), stroke-width scaling, marker content inheriting style from the marker
not the referencing element, recursive markers (marker inside marker content)
handled as usvg does. Bound the total number of marker instances (vertices ×
3) with a budget so a path with 10^6 vertices and a heavy marker cannot blow
up; add an adversarial case.

Another agent (T47) is doing `<use>`/`<symbol>` concurrently and a third
(T48) nested svg. You will need a viewBox→viewport transform; write it as a
small standalone function (e.g. `markerViewBoxTransform`) so the integrator
can unify. Put the code in `LeanSvg/Marker.lean`.

---

## Common rules (every lean-svg agent)

You are one of ~15 agents working in parallel on lean-svg, a total, float-free
SVG→PNG renderer in Lean 4 whose output is compared against resvg 0.48.1.
An integrator merges all branches afterwards, so **keep your diff small and
local**: prefer new functions/new modules (`LeanSvg/<Feature>.lean`, imported
from `LeanSvg.lean`) over rewriting shared code in `Svg.lean` / `Render.lean`.
No drive-by refactors, renames or reformatting of code you do not need.

**Setup (first thing):** `bash scripts/cloud-setup.sh` then
`export PATH=$HOME/.elan/bin:$PATH`. It installs Lean from the GitHub release,
resvg/usvg 0.48.1, numpy/pillow and the resvg test suite under
`tests/corpora/resvg-test-suite`, and builds. Read `tasks/README.md`,
`DESIGN.md` and the relevant parts of `SPEC.md` before editing.

**Invariants (hard, from tasks/README.md):** no `partial`, `unsafe`,
`@[extern]`, `panic!`, `!`-indexing, `Float`; loops over finite ranges or
structurally decreasing fuel; hot loops in `Nat`; no new build warnings;
`LeanSvg/Effect.lean` untouched unless your task is about it; no IO outside
`Effect.lean`. Code should fail loudly rather than silently: prefer
rejecting/asserting over swallowing errors, but a feature that is not
supported should degrade exactly as it does today (skip), not error.

**Reference behaviour:** match resvg/usvg 0.48.1. The Rust source is the spec
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`
into a scratch dir; `crates/usvg/src/parser/*` and `crates/resvg/src/*`).

**Baseline first, before any edit:**
```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/base --no-worst
python3 tests/run_tests.py
```

**Verification before you push (all must hold):**
1. `lake build` — no errors, no new warnings.
2. `bash scripts/check-theorems.sh` prints `theorems ok`. Note
   `proofs/SizeBound.lean` reasons about `render`; if your change breaks it,
   fix the proof, do not delete or weaken it.
3. Full corpus with delta table:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/NN_<feature>.svg` exercising the feature
   if it fits the local corpus style (pick an unused number; collisions with
   other agents are resolved by the integrator).

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.

---

## Report

### What was implemented

- Full `<marker>` parsing: `refX`/`refY`/`markerWidth`/`markerHeight`
  (including `%`, against the root viewport, same convention as
  `transform-origin`), `viewBox`, `preserveAspectRatio` (all nine `align`
  values plus `none`, `meet`/`slice`), `orient` (`auto`,
  `auto-start-reverse`, or an angle in `deg`/`grad`/`rad`/`turn`, default
  `0`), `markerUnits` (`strokeWidth` default, `userSpaceOnUse`), `overflow`
  (hidden by default and for `hidden`/`scroll`; off for anything else).
- `marker-start`/`marker-mid`/`marker-end` as ordinary inherited
  presentation-and-CSS properties, and the `marker` shorthand as CSS-only
  (`isCssOnlyProp`) — confirmed against the corpus's own
  `the-marker-property.svg` ("should be ignored" as a bare attribute) versus
  `the-marker-property-in-CSS.svg` (honoured from `<style>`).
- The vertex/angle algorithm, ported branch-for-branch from
  `calc_vertex_angle`/`calc_angle`/`calc_curves_angle` in usvg's
  `marker.rs`, but computed without ever forming an angle or calling
  `atan2`: usvg's float bisector formula (`atan2` of each direction, average,
  flip 180° if more than 90° apart) is exactly `atan2` of the sum of the two
  *unit* direction vectors, an identity derived and explained in
  `Marker.lean`'s module doc, with the one case that identity cannot see
  through (two vectors exactly antiparallel, where the unit-vector sum is
  the zero vector) handled by the exact integer sign test that stands in for
  it. All of `orient=auto-on-M-*` (9 files covering every `calc_vertex_angle`
  branch: M-L, M-C, M-L-L, M-C-C ×8, M-L-Z, M-C-M-L, M-L-M-C, M-L-L-Z-Z-Z)
  pass.
- `Marker.viewBoxTransform`: a standalone `viewBox`→viewport transform
  (align as three primitives, not an enum, so it depends on nothing but
  `Mat`/`Fx`) for the integrator to share with T47/T48.
- Markers instantiate on every basic shape usvg 0.48.1 actually instantiates
  them on: `path`, `line`, `polyline`, `polygon`, **and also** `rect`,
  `circle`, `ellipse` — `converter.rs` routes all seven through the same
  `convert_path` call that invokes `marker::convert`. This is broader than
  this file's own Scope line above (which follows the SVG 1.1 restriction),
  but matching the actual resvg pixels is the point of the exercise, and the
  corpus is explicit about it: `marker-on-rect.svg`, `marker-on-circle.svg`
  and `marker-on-rounded-rect.svg` are titled "(SVG 2)" and expect the
  marker to be drawn; `marker-on-text.svg` (not in that `EId` list) expects
  it not to be, and stays that way here.
- `stroke-width ≤ 0` with `markerUnits = strokeWidth` (the default)
  suppresses every instance of that reference, matching
  `NonZeroPositiveF32::new` returning `None` (`zero-sized-stroke.svg`).
- Recursive/self-referential markers: a stack of marker-table indices
  currently being expanded, checked before following any reference — a
  cycle is skipped (that one reference only), never followed forever,
  matching usvg's `state.parent_markers`. `recursive-1.svg`..`recursive-4.svg`
  pass; `recursive-5.svg` needs `<use>` inside marker content (see gaps).
- A hard budget, independent of the cycle guard: `Marker.maxMarkerNodes`
  caps the total number of `Node`s instancing may add across the whole
  document, decremented once per `Node` emitted while inside marker content
  (never for ordinary top-level content, so a marker-free document is
  untouched however large), and `Marker.maxMarkerDepth` caps nesting depth
  the way `Clip.maxDepth` already caps `clipPath` nesting. Both degrade by
  silently dropping further instances, never an error.
- `overflow`'s clip: one synthetic `ClipEntry` built per `<marker>` at parse
  time (the `viewBox` rect, or `(0, 0, width, height)`), and one `ClipUse`
  appended per instance with that instance's transform — reusing
  `Clip.lean`'s existing mask cache/application machinery completely
  unchanged, since from `Render.lean`'s point of view an instance's clip is
  just another `clip-path` use.
- Marker content is styled from the marker element's own ancestors, never
  the referencing element's: the main `interpret` walk already resolves
  every element's cascade from its true XML position, so a new `ClipMode`
  case (`.markerDef k`) just routes a `<marker>` subtree's `Node`s into a
  side table (`markerNodes[k]`, becoming `MarkerEntry.content` on `.close`)
  instead of the document, reusing the entire existing style/layer/clip
  pipeline for markers' descendants (`g`, nested markers, gradients,
  `clip-path` on the *marker itself* — not on something inside it, see
  gaps) rather than writing a second one.

### Architecture

- `LeanSvg/Svg.lean`: `MarkerEntry`/`MarkerOrient` next to `ClipEntry` (same
  precedent — the data model lives here, not in `Marker.lean`, so `Marker.lean`
  can import `Svg.lean` without a cycle), `DefsScan.markers` (a pre-pass slot
  per `<marker id>`, exactly like `clips`), the `marker` branch in
  `interpret`'s element dispatch, `ClipMode.markerDef` and the handful of
  `Node`-emission sites it routes, `applyProp` cases for the four
  properties, `isCssOnlyProp`, `Shape.markerable` (so expansion does not
  need the element name, which a `Shape` never kept).
- `LeanSvg/Marker.lean` (new): `viewBoxTransform`; the vertex/angle geometry
  (`dirUnit16`, `bisector16`, `Seg`/`toSegments` with exact quadratic
  elevation, `calcVertexAngle` and its helpers, `orientMat`); and `expand :
  Doc → Doc`, one fuel-and-budget-bounded recursive pass
  (`expandContentList`) that turns every `MarkerEntry.content` template
  into placed, transformed copies and splices them in as ordinary
  `Node`s right after the shape they mark, exactly where resvg's own
  `parent.children.push` puts them.
- `LeanSvg/Render.lean`: one line, `Marker.expand doc` between
  `Svg.interpret` and `canvasSetup`/`renderRgba`/`renderBands`. Nothing else
  in `Render.lean` changed — a marker instance is just another `Shape`/
  `groupBegin`/`groupEnd` in the `Node` stream by the time the renderer
  ever sees it, so culling, tiling, `--threads` banding and clip-path
  application all apply to it for free, unmodified and already tested.
- `proofs/SizeBound.lean`: one line (`Render.canvasSetup doc.root opts` →
  `Render.canvasSetup (Marker.expand doc).root opts`, matching the code
  change) — `render_output_size_bound`/`render_size_le_const` still hold,
  no `sorryAx`.

### What was skipped (documented gaps; each degrades to "not drawn", never an error)

- `<text>` inside marker content (`with-a-text-child.svg`): `textShapes`
  handles its own layering and has three separate `Node`-emission sites of
  its own; routing all three through `markerNodes` too was judged not worth
  the added risk given the size of everything else in this task, so a
  `<text>` inside a `<marker>` is skipped outright (one guard at the top of
  the `text` branch). `<text>` at the top level, and a `marker-start` etc.
  set on a `<text>` element itself (never valid, per usvg), are both
  unaffected.
- `<image>` inside marker content (`with-an-image-child.svg`): `<image>` is
  unimplemented everywhere in this renderer already; this task adds nothing
  new here.
- `<use>` inside marker content (`recursive-5.svg`, which nests `<use
  xlink:href="#path1">`): `<use>` is unimplemented everywhere in this
  renderer already (T47's task, concurrent with this one); a marker whose
  only content is a `<use>` collects as empty and draws nothing, which is
  this renderer's existing behaviour for `<use>` anywhere, not a new gap.
- A `clip-path` set on an element *inside* marker content (as opposed to
  the marker's own `overflow` clip, which is what every one of the 63
  corpus files that touches clipping actually tests, and is fully
  supported): dropped rather than remapped — the element still renders,
  just unclipped. Supporting it would mean cloning a `ClipUse` with a
  per-instance transform for every clipped descendant, which no corpus file
  exercises, so it was left as a documented gap instead of added risk.
- `preserveAspectRatio`'s error handling is not fully spec-literal: a
  malformed token after a *valid* `align` keyword (e.g. `"xMidYMid
  garbage"`) is read as `meet` rather than reverting the whole attribute to
  its default, the way svgtypes' single all-or-nothing parse does. No
  marker test in the corpus has a malformed `preserveAspectRatio`.

### Report

Before (this branch's own pre-edit state):

```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/base --no-worst
  1679 files, pass 835/1679 (49.7%)
  painting/marker: 16/63 pass (47/63 failing, matching this file's own line 7)
python3 tests/run_tests.py
  23/27 passed
```

After:

```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/final \
    --no-worst --compare /tmp/base/resvg_direct.csv
  1679 files, pass 892/1679 (53.1%)
  newly passing 57 - newly failing 0 - unchanged 1606
  painting/marker: 60/63 pass (the three documented gaps above are the only failures left)
python3 tests/run_tests.py
  24/28 passed (23 unchanged + the new 36_markers.svg; no existing file's score moved)
python3 tests/run_adversarial.py
  63/63 clean (61 unchanged + 2 new: marker_huge_path.svg -- 500,000-vertex path,
  all three marker refs on a 10-child marker, naively 15,000,000 Nodes, finishes
  in ~22s under the maxMarkerNodes cap; marker_mutual_cycle.svg -- two markers
  that reference each other, caught by the active-marker stack)
python3 tests/run_tiles.py
  27/27 byte-identical
lake build
  clean, no new warnings
bash scripts/check-theorems.sh
  theorems ok, no sorryAx (proofs/SizeBound.lean updated for the one-line
  Marker.expand insertion into render)
```

One file's within-8 score dropped without crossing pass/fail, investigated as
the verification rules require:
`painting/context/with-pattern-on-marker.svg` went from 87.89% to 86.94%
(fail → fail, same verdict both times). It combines two features outside
this task's scope — `fill="url(#pattern)"` (patterns are unimplemented,
T53) on the target path, and `fill="context-fill"` inside the marker's own
content (`context-fill`/`context-stroke` are T47's `painting/context`
scope). The drop is exactly the marker now being correctly instantiated
(this task's job) but painted opaque black instead of transparent, since
"context-fill" is not a recognised paint value and `resolvePaint` leaves
the inherited default rather than resolving to the referencing path's own
(unsupported) pattern fill. Not fixed, since both root causes belong to
other tasks; recorded here rather than left silent.

### Budget choice

`Marker.maxMarkerNodes := 200_000`. Large enough that no real corpus file
comes close (the worst legitimate case in the suite, `target-with-subpaths-
*.svg`, uses three different markers across roughly a dozen vertices); small
enough that the adversarial case's naive worst case — 500,000 vertices × 3
marker refs × a 10-child marker = 15,000,000 `Node`s — is cut by two orders
of magnitude and still finishes in about 22 seconds, comfortably inside the
harness's 120 s timeout. `Marker.maxMarkerDepth := 8` reuses `Clip.maxDepth`'s
existing precedent for nesting fuel; every cyclic case in the corpus
(`recursive-1.svg`..`recursive-5.svg`) is caught by the active-marker-stack
check long before fuel would matter, so fuel is only the independent
backstop against a wide, *non*-cyclic fan-out of many distinct markers
nested inside each other.
