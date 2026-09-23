# T50 — `<textPath>`  (branch `claude/feat-textpath`)

Rowan's priority. Implement `<textPath>` as usvg 0.48.1 does
(`crates/usvg/src/text/layout.rs`, search for `TextPath` / `path_offset` /
`glyph placement along path`). Target: `text/textPath` (36/44 failing).
Basic text already exists (`LeanSvg/Text.lean`, embedded Noto Sans in
`LeanSvg/Fonts/`, glyph outlines from `LeanSvg/Font.lean`).

Scope: `href`/`xlink:href` to a same-document `<path>` (and in 0.48.1 also
basic shapes? check); the path's own `transform`; `startOffset` (length and
percent); `text-anchor` on textPath; each glyph placed at the arc-length
position of its cluster *midpoint* and rotated to the tangent there, glyphs
beyond the path end are dropped, as usvg does; `method`/`spacing` (usvg
ignores stretch — check); `side="right"` if 0.48.1 supports it; nested
`tspan` inside textPath; `dx/dy` on characters within textPath; multiple
subpaths.

You need path arc-length: add a fixed-point arc-length table over the
flattened path (reuse `Geom.lean` flattening; lengths via the existing
`Fx.hypot`), and a total lookup `pointAndTangentAt (s : Fx)`. Rotation needs
the tangent angle as a unit vector (no atan2 needed: normalise the tangent
into a 16.16 cos/sin pair and build the matrix directly). Bound total glyph
count with the existing text limits. New code in `LeanSvg/TextPath.lean`
where possible.

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

## Spec implemented

usvg 0.48.1 `parser/text.rs` (`collect_text_chunks_impl`, `resolve_text_flow`,
`resolve_positions_list`, `resolve_rotate_list`) and `text/layout.rs`
(`resolve_clusters_positions_path`, `collect_normals`), plus kurbo 0.13.1's
`ParamCurveArclen::inv_arclen` / `common::solve_itp`.

* **Which `textPath`s count.** Only a direct child of `<text>`. Anywhere else
  (inside a `tspan`, inside another `textPath`) it is dropped with its
  characters, as usvg's tree builder does (already the case before T50).
* **Link.** `href`, else `xlink:href`, must be `#id`. The first element with
  that id wins. It must be a shape (`path`, `rect`, `circle`, `ellipse`,
  `line`, `polyline`, `polygon`, via the existing `shapeCmds`) that draws at
  least one segment. Its own `transform` is applied; ancestors' transforms
  are not. The `path` attribute on `textPath` (SVG 2) is ignored, as in usvg.
  `Svg.textPathTables` builds each linked table once per document, in one
  pass over the events.
* **Invalid `textPath`** (no link, missing id, not a shape): its characters
  keep their position-list slots but are not rendered, and chunking is not
  split, as in usvg.
* **Positions.** `x`/`y`/`dx`/`dy` on the `textPath` element are ignored;
  `rotate` on it is honoured. Inside it, `tspan` positions work as usual:
  a chunk's absolute `x` is an extra offset along the path, `y` is ignored,
  `dx` adds to the arc position and `dy` accumulates across the tangent. A
  cluster that lands off the path is hidden and does not accumulate its `dy`.
* **Chunks.** A new chunk starts at the first character of a `textPath` and at
  the first character after it. A chunk's flow is the flow at its first
  character. Like usvg, the flow resets to linear when any child element
  closes, including inside a `textPath`. After a path chunk, the next
  linear chunk continues from the last visible cluster's point plus its
  advance.
* **Placement.** `startOffset` can be a length (em units use the
  `textPath`'s own font size) or a percentage of the total length.
  `text-anchor` shifts by the chunk width. Each cluster's midpoint offset
  (`advance + dx + width/2`, where `width` is the advance before
  letter/word spacing) is located on the path. The glyph is drawn with
  `T(point) · R(tangent) · T(-width/2, dy) · R(rotate)`. Offsets below 0 or
  past the end are dropped.
* **Arc length.** usvg's segment model is reproduced exactly: `MoveTo` adds
  no length, `Close` is a line back to the subpath start, a line becomes the
  cubic with controls at 0.33 and 0.66, and quadratics are raised. Each
  cubic gets a chord-length table of up to 64 equal-parameter pieces (16.16
  px). The inverse is kurbo's ITP search, replicated step for step with the
  parameter in 2^-24 units. It stops at accuracy `0.5 / max(1, √(sx·sy))`
  px and returns the bracket midpoint. The replication matters because that
  tolerance leaves resvg up to about half a pixel off the exact point: an
  exact inverse scored ~98%, the replica 99.6%. The tangent is the
  derivative normalised to a 16.16 cos/sin pair, so no atan2 is needed.
* **Bounds.** At most 64 pieces per segment. A lookup is a binary search plus
  at most 64 ITP steps. The glyph count is capped by the existing 100 000
  character budget. On a 20 000-cubic path with 100 000 characters, the
  run takes 12.3 s, against 7.2 s for the same text laid out linearly.

## Skipped, and why

* `method="stretch"`, `spacing`, `side="right"`: usvg 0.48.1 does not parse
  them, so they are ignored here too (all three of those files now pass).
* Vertical `writing-mode` (`tb`, `tb-rl`, `vertical-rl`, `vertical-lr`, read
  from the `<text>` element's own attribute or `style` only): a `textPath`
  there is still dropped whole, as before. Vertical text is T56. Without
  this guard, `complex.svg` and `writing-mode=tb.svg` would go from pass to
  fail: resvg draws nothing for them (no font for "Mplus 1p"), while we would
  draw Noto Sans tofu.
* `baseline-shift`, `alignment-baseline`, `dominant-baseline` on path text
  (T54). usvg adds `-resolve_baseline(span)` to the per-cluster `dy` shift in
  path mode. The hook is the `y` term in the path branch of `Text.layout`.
  Until then those files render unshifted (see the drops below).
* `textLength`/`lengthAdjust` on a `textPath` (not supported anywhere yet),
  and `text-decoration` on path text (T55).
* Non-monotone arc offsets (negative `dx` or `letter-spacing` pulling a later
  cluster behind an earlier one): usvg's `collect_normals` then misaligns
  offsets and normals. Here each cluster gets its own point.
* `transform-origin` on the linked shape, and the root `viewBox` scale in the
  arc-length accuracy (usvg's `abs_transform` includes it; we use the
  `<text>`'s CTM without it). Every test-suite file has a viewBox equal to
  its size.

## Report

Files: `LeanSvg/TextPath.lean` (new), `LeanSvg/Text.lean` (`Ev.openPath`,
`Cluster.width`, flow/segment tracking, the path branch of chunk placement,
`glyphCmds` → `glyphCmdsLin` with a general linear part, bit-identical for the
old callers), `LeanSvg/Svg.lean` (`textPathHref`, `textPathTables`,
`startOffsetOf`, the `textPath` branch of `textShapes`, one table built in
`interpret`), `LeanSvg.lean` (import), `tests/svg/30_textpath.svg`.

resvg corpus, `--fast --route direct`, pass counts before → after:

| dir | files | before | after |
|---|---|---|---|
| `text/textPath` | 44 | 8 | 39 |
| `text/` (all) | 356 | 168 | 199 |
| whole suite | 1679 | 835 | 866 |

31 files newly pass. None go from pass to fail. Remaining `text/textPath`
failures:
`with-baseline-shift`, `with-baseline-shift-and-rotate`, `m-L-Z-path`
(`baseline-shift`, T54), `with-underline` (decoration, T55), and
`dy-with-tiny-coordinates` (`scale(100)` on 0.01-unit coordinates, below
`Fx`'s 1/256 px grid).

Files whose within-8 score dropped (all were already failing):
`textPath/with-baseline-shift-and-rotate` 91.56 → 85.24,
`textPath/with-baseline-shift` 91.48 → 86.08,
`alignment-baseline/middle-on-textPath` 95.92 → 93.95,
`textPath/m-L-Z-path` 93.92 → 92.64,
`lengthAdjust/text-on-path` 95.72 → 94.78. In each case the text used to be
dropped and is now drawn without the baseline or length adjustment the file
tests.

Local checks: `lake build` succeeds with no warnings. `tests/run_tests.py`:
no score changed, and the new `30_textpath` scores 99.80 (PASS; 24/28, the
same four failures as before). `run_adversarial.py`: 62/62 clean.
`run_tiles.py`: 28/28 byte-identical. `scripts/check-theorems.sh`: theorems
ok.
