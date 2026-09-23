# T48 — nested `<svg>` viewports and `overflow`  (branch `claude/feat-nested-svg`)

Nested `<svg>` elements are currently skipped. Implement them as usvg 0.48.1
does (usvg converts a nested svg into a group with a transform and, unless
`overflow` is visible/auto, a clip rect; see `crates/usvg/src/parser/use_node.rs`
`convert_svg` and `converter.rs`). Target: `structure/svg` (33/42 failing),
`painting/overflow` (5), and anything in `structure/style`/`transform-origin`
that falls out. Include `x`, `y`, `width`, `height` (incl. percentages vs the
parent viewport), `viewBox`, `preserveAspectRatio` (all align values and
`meet`/`slice`), and root-level behaviours that the `structure/svg` files test
(e.g. preserveAspectRatio on the root, zero/negative sizes, missing viewBox)
where they are within reach. Nesting must stay within the existing depth caps.

Another agent (T47) is doing `<use>`/`<symbol>` at the same time, which needs
the same viewBox/preserveAspectRatio math for symbols; put that math in a
small standalone function (e.g. `viewBoxTransform`) so the integrator can
share it.

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

- **`LeanSvg/Viewport.lean`** (new, standalone, for T47 to share):
  `parseAspectRatio` (svgtypes grammar `[defer] <align> [meet|slice]`,
  anything else → `xMidYMid meet`) and `viewBoxTransform vb ar w h : Option Mat`
  (usvg `ViewBox::to_transform`; `none` on a non-positive side). For
  `xMidYMid meet` it is operation-for-operation the old root formula, so
  existing output is byte-identical.
- **Root**: `RootInfo.aspect`; `Render.canvasSetup` uses `viewBoxTransform`, so
  every `preserveAspectRatio` on the root works.
- **Nested `<svg>`** (`Svg.interpret`, new branch), as usvg `convert_svg`:
  own `transform` → optional viewport clip → `translate(x, y)` → viewBox map.
  `x`/`width` resolve percentages against the parent viewport's width,
  `y`/`height` against its height; `width`/`height` default to 100%. The
  children's percentage reference becomes the `viewBox` (or `x y w h` when
  there is none). The clip is emitted unless `overflow` (attribute or
  `style=""`) is `visible`/`auto`, or `width`/`height` is missing, or either
  is ≤ 0 (`get_clip_rect`). It is a synthetic one-rect `ClipEntry` + `ClipUse`
  (pre-resolved `entry`, id `""`, never in the id map) that rides the element's
  layer beside its own `clip-path`; opacity/blend/`clip-path` on the nested svg
  apply in the inner space as in usvg. Past `maxLayerDepth` the clip degrades
  to per-shape clipping, like any other clip. No new depth caps needed.
- **Shape percentages** (fell out; needed by the nested-percent tests):
  `shapeCmds` takes the current viewport refs; `x cx width rx x1 x2` →
  width, `y cy height ry y1 y2` → height, `r` → `viewportDiag`.

## Skipped

- `painting/overflow/*` (5): all are `overflow` on `<marker>` → T52.
- `structure/svg`: ENTITY files (DTD rejected by design), `invalid-id-*` (`use`,
  T47), `xmlns-validation`/`mixed-namespaces` (namespaces), `no-size`
  (bbox refit), 3 files where resvg itself fails.
- `overflow` from a `<style>` sheet (only attribute and `style=""` are read).
- `<use>` → `<svg>` sizing (`state.use_size`) — T47's side.

## Report

`run_corpora.py --fast --corpus resvg --route direct` (width 100):

| dir | before | after |
|---|---|---|
| structure/svg | 9/42 | 30/42 |
| painting/overflow | 1/5 | 1/5 |
| structure/style | 16/16 | 16/16 |
| structure/transform-origin | 17/23 | 17/23 |
| shapes/rect | 31/38 | 33/38 |
| shapes/ellipse | 6/12 | 7/12 |
| shapes/line | 9/10 | 10/10 |
| **whole suite** | **835/1679** | **860/1679** |

25 newly passing, 0 newly failing, no file's within-8 score dropped
(`structure/use/xlink-to-svg-element-with-x-y-on-use` also 73.8 → 86.9%).
`run_tests.py`: no score changes on 01–27; new `28_nested_svg` 99.90% PASS.
`run_adversarial.py` 62/62 clean; `run_tiles.py` 28/28 byte-identical;
`check-theorems.sh` ok; `lake build` no warnings.
