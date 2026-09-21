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
