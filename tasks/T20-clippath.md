# T20 — `clipPath`  [Opus]

PLAN C26 (C27 optional). Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T20`
(branch `t20-clippath`). Builds on the defs table from T18 (merge main first
if T18 has landed; if not, add a minimal `clipPath` entry to the same table
shape and expect a merge task). Files: `MicroSvg/Svg.lean` (defs entry for
`clipPath` and its children; `clip-path` property on `Style`), new
`MicroSvg/Clip.lean` (build a coverage mask from a clipPath), `MicroSvg/Render.lean`
(multiply the shape's coverage by the clip mask before painting; group
`clip-path` applies to each descendant shape — note the AA-edge divergence
from resvg's layer clip in the report; T22's layers will fix that later).
Invariants in `tasks/README.md`; `Effect.lean` untouched; no `Float`.

## Behaviour (usvg `crates/usvg/src/parser/clippath.rs`, resvg `clip.rs`)

- `clipPath` children: shapes, `text` (if T36 has landed, else skipped and
  reported), `use` (skip, report); each child's own `clip-path` and
  transform apply; the clip region is the union of the children's fills
  (each with its `clip-rule`), rasterised with the normal AA scan converter
  into a `Mask` in device space; `clipPathUnits` userSpaceOnUse (default)
  or objectBoundingBox (scaled by the clipped element's user-space bbox,
  same bbox rule as T18 gradients); `transform` on the `clipPath` element;
  a `clip-path` on the `clipPath` element itself intersects (multiply).
  Invalid references → element not rendered (usvg drops it); self/cyclic
  references → dropped; nesting fuel 8.
- Coverage combine: `cov' = cov × clip / covFull` with the same rounding as
  tiny-skia's mask multiply (check `Mask::apply` / the pipeline's
  `mask_u8`), so tiles stay byte-identical.

## Verify

- `lake build` clean; `git diff main -- MicroSvg/Effect.lean` empty.
- New `tests/svg/27_clip.svg` ≥ 99% within 8 vs resvg.
- Corpora fast sizes, direct route, `--compare`: `--dir masking/clipPath
  --dir masking/clip-rule --dir masking/clip`. Target clipPath ≥ 30/52; one
  line per remaining failure grouped by cause (text clips, `use`, layers).
- `run_tests.py` byte-identical on existing files; `run_tiles.py`
  byte-identical incl. the new file; `run_adversarial.py` clean plus: a
  clipPath referencing itself, an 8-deep chain, 10 000 clip children, a clip
  on every one of 100 000 shapes.
- Commit (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.

## Report

Branch `t20-clippath`, rebased onto `origin/main` at `a932752`. T18 had **not** merged
(`git log` shows no T18 commit on main), so this task adds the minimal defs
table the spec describes: `Doc.clips` / `Doc.uses`, filled by a `clipPath`
branch in `interpret` and resolved by id after the walk. The shape is meant for
T18/T21 to extend with their own entry kinds; the module comment in
`MicroSvg/Svg.lean` says so, and a merge with T18's table will have to fold the
two collections into one pre-pass.

### Files

| file | change |
|---|---|
| `MicroSvg/Svg.lean` | `ClipChild`/`ClipEntry`/`ClipUse` + `Doc.clips`/`Doc.uses`; `clip-path`, `clip-rule` on `Style` (plus `clips`, `ownMat`); `parseClipRef`; bbox helpers on `Box`; a `Frame` stack in `interpret` tracking clip mode and object bounding boxes; `clipPath` and `defs` branches |
| `MicroSvg/Clip.lean` | new: builds a device-space `Mask` per clip, folds children with tiny-skia's `Clear`/`Xor` arithmetic, multiplies a shape's coverage by the chain |
| `MicroSvg/Render.lean` | `drawShape` resolves the shape's clip chain and multiplies every coverage mask by it; `renderRgba` carries a per-canvas mask cache |
| `MicroSvg.lean` | imports `MicroSvg.Clip` |
| `tests/svg/27_clip.svg` | new fidelity case |

`git diff origin/main -- MicroSvg/Effect.lean` is empty. `render`'s type is
unchanged. No `partial`, `unsafe`, `@[extern]`, `panic!`, `!`-indexing or
`Float` in the new code; every loop is bounded by the input or by a constant
(`maxClipPaths` 4096, `maxIdBytes` 256, nesting fuel 8).

### How the clip is applied, and where it diverges from resvg

resvg renders a clipped element into a layer, builds the clip as a black pixmap
that each `clipPath` child *clears* (so the alpha is `Π (255 − cᵢ)`), inverts
it into a `Mask`, and multiplies the layer by it (`DestinationIn`, `div255`).
T22 owns the layer. Here the same mask multiplies each shape's **coverage**
instead, on tiny-skia's 8-bit grid and with its `div255`, then back to the
rasterizer's 0..65536 convention. For an opaque paint over a transparent
canvas the two are identical arithmetic; the divergences are:

- **AA edges of overlapping shapes under one group clip.** resvg clips the
  composited layer once, this clips each shape separately, so where two clipped
  shapes overlap on the clip's anti-aliased boundary the coverage is applied
  twice. One level on edge pixels; T22's layers remove it.
- **Colour rounding on the clip edge.** resvg multiplies the layer's already
  rounded premultiplied colour by the mask; here the mask scales the coverage
  before the blend. Also at most one level.

Tiles are unaffected: masks are built in absolute device space with the ordinary
rasterizer, so §3.5's whole-pixel shift invariance carries over.

### Verify

- `lake build`: clean, no errors, no new warnings.
- **`tests/svg/27_clip.svg`** (userSpaceOnUse and objectBoundingBox units, a
  transform on the `clipPath`, `clip-rule="evenodd"`, multi-child unions, a clip
  on a group, a clip on a `clipPath` child, a `clip-path` on the `clipPath`
  itself, a hidden child, a clipped stroke, an unresolvable reference):
  **99.759% within 8**, 98.412% exact, max d 53 — passes the 99% bar.
- **Corpora**, `--fast --corpus resvg --route direct`, `--compare` against
  main's binary:

  | directory | before | after |
  |---|---|---|
  | `masking/clipPath` | 7/52 | **49/52** |
  | `masking/clip-rule` | 0/1 | **1/1** |
  | `masking/clip` | 0/1 | 0/1 |

  41 newly passing, then 2 more after the recursion fix; 0 newly failing.
  Median within-8 over the slice went from 12.6% to 100%. Target was ≥ 30/52.

  Remaining failures, one line each:
  - `masking/clip/simple-case.svg` — not a `clipPath` at all: the legacy `clip`
    property on an `<image>`. No image support; out of scope.
  - `masking/clipPath/with-use-child.svg` — `use` child of a `clipPath`, skipped
    as the spec allows. The clip then has no valid child, so the element is
    dropped (resvg paints 2648 px, we paint 396). Needs T19.
  - `masking/clipPath/clip-path-with-transform.svg`,
    `transform-on-clipPath.svg` — 98.3% within 8, max d 128. **Not the clip
    logic**: `clipPathUnits="objectBoundingBox"` coordinates are parsed on the
    `Fx` 1/256 grid, so `0.6` becomes `153/256` and, scaled by a 200-unit box,
    lands at 119.53 rather than 120 — a half pixel of clip edge. Verified by
    rewriting the same clip in user space (`x=40 … width=120`), which scores
    **99.98%** within 8 with 2 pixels off by 16. This is T31's problem for
    positions rather than coefficients and needs a higher-precision coordinate
    parse; it is not fixable inside this task.

  **Caveat on the 49/52.** Five of those passes are hollow: the five `<text>`
  clip fixtures agree at 100% only because the harness invokes `resvg -w W`
  with no fonts directory, so the oracle draws no text either and both sides
  emit just the 396-pixel frame. Re-running one with
  `--use-fonts-dir tests/corpora/resvg-test-suite/fonts` scores 94.35%. Text
  clips are genuinely unimplemented (T36 has not landed); the honest count on
  the non-text files is **44/47**.

- **`run_tests.py`**: all 23 pre-existing files **byte-identical** to main's
  binary (sha256, at natural size and at `--width 800`). 20/24 pass; the four
  failures (12_badge, 14_flower_transforms, 15_spiral_stroke, 16_stress_2000)
  are the same four that fail on main.
- **`run_tiles.py`**: 24/24 byte-identical, including `27_clip`. `--threads 4`
  is byte-identical to `--threads 1` on `27_clip` at 800 px.
- **`run_adversarial.py`**: 44/44 clean, 0 violations (it picked up a truncated
  `27_clip` case on its own). The four cases the spec names, run separately,
  all exit 0 with a valid PNG and no stray files:

  | case | ms |
  |---|---|
  | a `clipPath` referencing itself (and a child referencing its own parent) | 15 |
  | an 8-deep chain | 25 |
  | 10 000 clip children | 361 |
  | a clip on every one of 100 000 shapes | 2 568 |

  Also checked: 4 096 + 1 `clipPath` elements (44 ms), a 64-deep chain (7 ms),
  an `objectBoundingBox` clip on a zero-area shape (6 ms).

  The 100 000-shape case first took **96 s**, because the mask cache keyed on
  the referencing element's bounding box even for clips that cannot use it, so
  every shape rebuilt the mask. `Clip.needsBBox` now drops the box from the key
  unless the entry (or a clip it applies to itself) is `objectBoundingBox`:
  **96 s → 2.6 s**, with the corpora slice and `run_tests` byte-identity
  re-checked afterwards to confirm the output did not move.

- **Timing** (median of 7, natural size): `16_stress_2000` 247 ms on main vs
  220 ms here, `19_sierpinski` 24.2 vs 23.6 — no regression (a first median-of-3
  run suggested +25%, which more repeats showed to be noise). `27_clip` is
  20.8 ms at natural size and 90.2 ms at `--width 800`.

### Semantics implemented, and the two deliberate deviations

Matched against usvg `parser/clippath.rs` + `converter.rs` and resvg `clip.rs`:
children are shapes only (`line` excluded, as a stroke-less line has no fill;
`g` skipped but descended so a nested `clipPath` stays referenceable by id, as
in usvg's flat id map); each child's own `clip-rule`, `transform` and
`clip-path` apply; `visibility`/`display:none` children contribute nothing but
keep the clip valid; `clipPathUnits`; `transform` on the `clipPath`; a
`clip-path` on the `clipPath` itself intersects; an invalid clip (zero-scale
transform, zero-area box under `objectBoundingBox`, no valid child) drops the
referencing element, while an unresolvable `url(#id)` is simply ignored;
forward references work; a clip on the root `<svg>` applies.

- **Cycles.** A reference back to a `clipPath` already being built is dropped
  (the link becomes `none`) rather than invalidating the clip, which is what
  usvg's `fix_recursive_links` does; `self-recursive` and `recursive-on-child`
  both match after this was corrected.
- **Fuel 8.** A chain deeper than 8 makes the clip invalid, so the element is
  not rendered, where resvg (which has no limit) still paints it — checked on a
  64-deep chain: resvg 2348 px, we paint 0. The conservative direction for a
  clip. An exactly-8-deep chain matches resvg at 99.86%.

### Not done

- Text clips (T36), `use` children (T19).
- The `objectBoundingBox` coordinate precision above; it wants its own task.

### Rebase onto main

Main moved 11 commits while this was in flight (T34 paint-order, T37 drop zone,
T38 `transform-origin` under the CSS cascade). Rebased onto `a932752`; two
conflicts, both in code the other tasks had restructured:

- `Render.lean` — T34 split `drawShape` into `drawFill`/`drawStroke` closures
  chosen by `st.strokeFirst`. Kept that structure and applied the clip chain
  inside both, so the clip multiplies each coverage mask whichever order they
  are painted in.
- `Svg.lean` — T38 rewrote `applyEffective`'s cascade around `winning`/`early`.
  Kept that and added the per-element reset of `clipRef`/`ownMat` beside
  T38's `transform-origin` reset, which is the same rule for the same reason.

Both behaviours are preserved. Every number above was re-measured on the
rebased tree against a binary freshly built from `a932752`: clipPath still
7/52 → 49/52 and clip-rule 0/1 → 1/1 (43 newly passing, 0 newly failing), all
23 pre-existing corpus files still byte-identical at natural size and at
`--width 800`, `run_tiles` 24/24, `run_adversarial` 44/44 clean, the four named
clip cases still exit 0 with no strays (100 000 clipped shapes 2.4 s),
`--threads 4` still byte-identical to `--threads 1`, and
`git diff origin/main -- MicroSvg/Effect.lean` still empty.

## Report 2 — merge with main (T18 gradients, T36 text), one defs pre-pass

`origin/main` at `ff06548` (T18 gradients, T36 text, on top of the T34/T37/T38
that Report 1 rebased onto) merged into `t20-clippath`.  Eight conflict hunks,
five in `MicroSvg/Svg.lean` and three in `MicroSvg/Render.lean`.  Everything
Report 1 measured still holds, and the two follow-ups it deferred to "their own
task" are both done here, because T36 and T31 made them cheap.

### Conflicts, and how each was resolved

| file | hunk | resolution |
|---|---|---|
| `Render.lean` | `drawShape`'s fill and the two stroke arms (×3) | T18's `paintMask` closure is kept as the painter — so a `.gradient` still reaches `Grad.build`, and T34's `drawFill`/`drawStroke` split with the `st.strokeFirst` swap is untouched — and T20's `.map (Clip.applyChain chain)` is applied to each of the three coverage masks before it gets there.  One line each. |
| `Svg.lean` | imports | both (`MicroSvg.Text`, `Std.Data.HashMap`). |
| `Svg.lean` | `Style` fields | T36's nine text fields and T20's four clip fields, side by side. |
| `Svg.lean` | the block before `interpret` | T18's gradient parsers and T36's `textShapes` kept verbatim, then T20's `ClipMode`/`Frame`. |
| `Svg.lean` | `interpret`'s root branch | `addClipUse (applyEffective { (default : Style) with defs := gradTable } …)`: T18's gradient table still reaches every element by inheritance from the root `Style`, and the root `<svg>`'s own `clip-path` still registers a use. |
| `Svg.lean` | `interpret`'s `text` vs `switch` branch | both, in order; the `text` branch is rewritten (below). |

`applyEffective` remains the only cascade entry point (`applyAttrs` does not
exist); T38's per-element reset of `originDx`/`originDy` and T20's of
`clipRef`/`ownMat` sit on consecutive lines.  `render`'s type is unchanged,
`git diff origin/main -- MicroSvg/Effect.lean` is empty, and the invariants of
`tasks/README.md` hold in the new code (no `partial`, `unsafe`, `@[extern]`,
`panic!`, `!`-indexing or `Float`; every loop bounded by the input or by
`maxClipPaths` / `maxIdBytes` / fuel 8 / `Grad.maxDefs`).

### The fold: one pre-pass, one lookup shape

Report 1 wrote `Doc.clips`/`Doc.uses` as a stand-in and said a merge with T18's
table "will have to fold the two collections into one pre-pass".  Done:
`Svg.defsScan` is now the single bounded pass over the events, and it replaces
both `gradRawDefs` and `gradPctRef` (main ran two passes; this runs one).  It
returns `DefsScan`: the gradient `RawDef`s, the percentage reference rect, and
one *slot* per `clipPath` element with a usable `id`, in document order, with
the index of the `open_` event it starts at.

The two kinds are collected together and resolved differently, which is the
point and is written down in `Svg.lean` under "`clipPath` (T20), and the shape
of a defs table":

* A gradient is fully described by its own attributes and its stops, so the
  pre-pass finishes it — `Grad.Defs.build` runs on the spot and the table goes
  to the root `Style`.
* A `clipPath` is not: its `transform`, its own `clip-path` and its children's
  `clip-rule` all come out of the CSS cascade, which only the main walk runs.
  So the pre-pass reserves the slot and the walk fills it (`ClipEntry.filled`)
  when it reaches that event index, tracked with one monotone cursor — the walk
  meets `clipPath` opens in increasing index order, so no hashing is needed.
  Ids are resolved after the walk, over the filled entries only, which is
  exactly the set Report 1's `clipTable` held, so behaviour is unchanged: a
  slot the walk never reaches (inside `display:none`, or a `<switch>` branch
  that lost) stays invisible to the lookup and a reference to it is ignored.

Lookup shape, for T21 masks and T19 `use`: *slot by event index while walking,
id after walking*.  Adding one is an `Array (String × Nat)` on `DefsScan`, an
entry array on `Doc` beside `clips`, a non-inherited `Style` field like
`clipRef`, and one resolve loop at the end of `interpret` — no second pass over
the events, no new mechanism on `Doc`.  A definition that needs no cascade
should instead go the gradient way, beside `Grad.RawDef`; `Shader.lean`'s
module comment now says which of the two to pick.

### Text clips (T36 had not landed for Report 1; it has now)

Report 1's "caveat on the 49/52": five `masking/clipPath` text fixtures passed
only because the harness gave the oracle no fonts, so neither side drew text.
T36 pins the oracle to the suite's `fonts/`, so those five are now real tests —
and they pass for the right reason.  `interpret`'s `text` branch is mode-aware:

* `.render` — unchanged, the shapes are appended.
* `.clip k` — each laid-out run becomes a `ClipChild` with its own `clip-rule`,
  which is what usvg does (text is converted to paths, then clipped with).
* `.defs` — nothing.  This is a merge bug Report 1 could not have had: T20 made
  `<defs>` a descended branch (so the `clipPath`s inside it are collected)
  rather than a skipped one, and T36's `text` branch rendered whatever it
  walked.  A `<text>` under `<defs>` is now correctly invisible (checked
  against resvg: 0 painted pixels both sides).
* A `clip-path` **on** the `<text>` element itself now registers a use, with
  the union of its glyph outlines as its object bounding box — `textShapes`
  gives every run the element's own `ctm`, so that union is exactly the box.
  The `<text>` also contributes that box to a clipped ancestor's.

### `clipPathUnits="objectBoundingBox"` precision (Report 1's other deferral)

Report 1 traced `clip-path-with-transform.svg` and `transform-on-clipPath.svg`
to coordinates lexed on the `Fx` 1/256 grid: under `objectBoundingBox` a
coordinate is a *fraction of a box*, so quantizing it to 1/256 is quantizing a
multiplier, and on a 200-unit box `0.6` lands at 119.53 instead of 120 — half a
pixel of clip edge.  That is T31's finding about transform coefficients, one
level down, and it takes T31's fix:

* `Fixed.lean`: `parseLength16`/`parseLengthAll16`, siblings of
  `parseLength`/`parseLengthAll` that call the existing `parseNumber16`
  (16.16) instead of `parseNumber` (1/256).  Purely additive; the 1/256
  parsers are untouched.
* `Svg.lean`: `shapeCmds16`, reachable *only* from the clip-child branch of a
  `objectBoundingBox` entry, so nothing else can move.  `rectPath`,
  `ellipsePath` and `polyPath` are grid-agnostic (their only division is by
  `kappa16`, a ratio) and are reused unchanged.  `path` is deliberately not
  handled — `arcPath`'s trigonometry assumes the `Fx` grid — so a `<path>`
  child keeps the old coordinates; none of the affected fixtures uses one.
* `Clip.lean`: `Clip.fineScale` divides the extra factor of 256 back out of
  the child's matrix (`childMat`).  The composition costs at most one 16.16
  unit of the matrix, i.e. 1/256 px on a unit-square coordinate, against the
  half device pixel it removes.

Not fixed by this, and left as it was: a `transform` **on** such a child still
has its `translate` offsets on the 1/256 grid (T31 fixed the linear
coefficients, not positions), and a `<path>` child keeps 1/256 coordinates.
Neither shows up in the suite.

### Verification (all on the merged branch, resvg 0.48.1, fonts pinned)

| check | result |
|---|---|
| `lake build` | clean, 45 jobs, no errors, no warnings (forced rebuild of the four touched modules) |
| `python3 tests/run_tests.py` | 26 files, 22 pass; `27_clip` **99.759% within 8** (98.412 exact, max d 53), `24_gradients` 99.993%, `25_text` 99.530%; the 4 failures (12, 14, 15, 16) are main's |
| 25 pre-existing files vs main's binary, natural size **and** `--width 800` | **50/50 byte-identical** (`cmp`) |
| `python3 tests/run_tiles.py` | **26/26** quadrant tiles stitch byte-identically, `27_clip` included |
| `--threads 4` vs `--threads 1`, `27_clip` at 800 px | byte-identical |
| `python3 tests/run_adversarial.py` | **56/56 clean, 0 violations** |
| `git diff origin/main -- MicroSvg/Effect.lean` | empty |

Corpora, `--fast` (width 100), direct route, `--dir masking --dir paint-servers
--dir text --dir painting/fill --dir structure/style --dir structure/switch
--dir structure/transform-origin` (737 files), against a binary built from
`origin/main` at `ff06548`:

| directory | main | merged |
|---|---|---|
| `masking/clipPath` | 6/52 | **50/52** |
| `masking/clip-rule` | 0/1 | **1/1** |
| `structure/transform-origin` | 15/23 | **17/23** |
| every other directory in the slice (41 of them) | — | unchanged |
| **total** | 402/737 | **449/737** |

47 newly passing, **0 newly failing**, no directory below main's count.  The
44 of those from the clip work land in two groups: the 41 Report 1 already had,
plus the four real text-clip fixtures (`clipping-with-text`,
`clipping-with-complex-text-1`/`-2`, `clipping-with-complex-text-and-clip-rule`,
99.94–99.97% each).  The `objectBoundingBox` precision fix adds the last three:
`clip-path-with-transform` and `transform-on-clipPath` 98.30% → **99.97%**,
`structure/transform-origin/on-clippath-objectBoundingBox` 96.60% → **99.82%**,
and `clipPathUnits=objectBoundingBox` improves 99.50% → 99.99% inside its pass.

Remaining `masking/clip*` failures, one line each:

- `masking/clip/simple-case.svg` — the legacy `clip` property on an `<image>`,
  not a `clipPath`.  No image support; out of scope (unchanged).
- `masking/clipPath/with-use-child.svg` — a `use` child of a `clipPath`,
  skipped, so the clip has no valid child and the element is dropped.  Needs
  T19 (unchanged).
- `masking/clipPath/clip-path-with-transform-on-text.svg` — 98.27%.  The same
  `objectBoundingBox` story, but the box is a *text* bounding box: it comes
  from the glyph outlines, which are already on the `Fx` grid by the time
  `Text.layout` is done, so the fix above cannot reach it.  Would want text
  layout carried at 16.16 end to end; not attempted.

Adversarial, the four cases Report 1 names plus two for this merge, each exit 0
with a valid PNG and no stray files:

| case | ms |
|---|---|
| a `clipPath` referencing itself (and a child referencing its own parent) | 9 |
| an 8-deep chain | 14 |
| 10 000 clip children | 246 |
| a clip on every one of 100 000 shapes | 2 600 |
| `<text>` under `<defs>` | 9 |
| a `clipPath` inside `display:none`, referenced | 8 |

The first four match resvg where Report 1 says they should (self-reference and
the 8-deep chain pixel-exact here).  The last is the one known divergence and
it is Report 1's, not new: a `clipPath` the walk cannot reach is
unreferenceable here, while usvg's id map finds it, so resvg clips and we do
not.  No suite file covers it; fixing it means descending `display:none`
subtrees in `defs` mode, which is a behaviour change beyond a merge.

Timing, median of 9 at natural size, main's binary → merged: `16_stress_2000`
277 → 273 ms, `19_sierpinski` 40 → 36 ms, `25_text` 44 → 41 ms.  No regression;
the extra pre-pass work is one `name == "clipPath"` test per element.
