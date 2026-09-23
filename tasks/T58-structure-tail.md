# T58 — shapes and structure long tail  (branch `claude/feat-structure-tail`)

Fix remaining failures in `shapes/*` (path 7/57, rect 7/38, ellipse 6/12,
circle, line, polygon, polyline) and `structure/*` other than use/symbol/svg
/image (`transform-origin` 6/23, `transform`, `style`, `style-attribute`
incl. comment stripping in `style=""`, `systemLanguage`, `switch`, `a`, `g`,
`defs`), plus `masking/clipPath` and `masking/clip`/`clip-rule` leftovers and
`paint-servers/*Gradient`/`stop*` leftovers, matching resvg 0.48.1. Triage
first (run the dirs with composites, classify the causes), then fix the
biggest shared causes. Skip files that need use/symbol, nested svg, masks,
filters, markers, patterns, text or images: other agents own those
concurrently.

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

## Implementation

Triaged with `tests/run_corpora.py --fast --corpus resvg --route direct` (width
100, no `--worst`), then listed every non-`pass` row in the assigned
directories from the resulting CSV. Grouped by root cause instead of by
directory; fixed the ones that were both in scope (no `use`/`symbol`/nested
`svg`/mask/filter/marker/pattern/text/image) and low risk. All changes are in
`LeanSvg/Svg.lean`.

1. **Percent and `em`/`ex` on shape geometry** (`shapeCmds`, `resolveRxRy`,
   new `parseTextLenAll`). `x`/`y`/`width`/`height`/`cx`/`cy`/`rx`/`ry`/
   `x1`/`y1`/`x2`/`y2` went through `lengthAttr`/`parseLengthAll`, which
   rejects `%` outright (no reference to resolve it against) and resolves
   `em`/`ex` against a hard-coded 16 px font rather than the element's own
   (usvg/resvg default 12 px, `Options::font_size`, matching this codebase's
   own `Style.fontSize` default). Text already had the right machinery
   (`parseTextLen`/`parseTextLenList`, resolving `em`/`ex` against
   `st.fontSize` and `%` against the viewport axis the attribute names) — added
   `parseTextLenAll`, a single-value wrapper, and pointed every shape
   attribute at it, resolving against `st.pctRefW`/`st.pctRefH` (already
   computed once from the root `viewBox`/size, unchanged since T-whatever
   added `transform-origin`). `circle`'s `r` (the one length that names
   neither axis) resolves against `viewportDiag`, matching usvg's
   `convert_length` catch-all — same rule `letter-spacing` already uses.
2. **`rx`/`ry` "auto" resolution** (`resolveRxRy`, shared by `rect` and
   `ellipse`, matching usvg's `resolve_rx_ry`): a negative value is dropped as
   if absent (checked post-resolve, which agrees with usvg's pre-resolve check
   since none of the unit factors here are negative); if exactly one of the
   two is given, its value is mirrored onto the other axis; `rect` already had
   the mirroring but not the percent/negative handling, `ellipse` had neither.
3. **A shape's own children are dropped, not rendered.** usvg's
   `convert_element_impl` calls `convert_children` only for `g`/`svg`/
   `switch`; `rect`/`circle`/.../`path` just call `shapes::convert` once and
   never recurse, so an XML child of a shape is simply not part of the render
   tree. This renderer's walk pushed a stack frame for every shape exactly
   like a container, so a child shape rendered as an independent sibling on
   top. Added `Frame.isShapeLeaf`, set on a shape's own frame; checked first
   thing on the next `.open_` (same slot as the `switch`-selection check) and
   skips the child's entire subtree if the immediate parent frame is a shape
   leaf.
4. **`<a>` is a plain container.** usvg's tree builder rewrites `<a>`'s tag
   name to `EId::G` before conversion ever sees it (`svgtree/parse.rs`) — a
   link has no rendering behaviour of its own. The dispatch had no branch for
   `"a"` at all, so the whole subtree fell to the final `else => skip := 1`.
   Folded `"a"` into the `"g"` branch.
5. **`/* ... */` comments inside `style=""`.** `parseStyleDecls` split
   directly on `;`/`:` with no comment stripping; `Css.stripComments` already
   existed for `<style>` sheets, so `parseStyleDecls` now runs it first.

### Skipped (out of scope or not a good size/risk tradeoff)

- `structure/transform-origin/on-gradient-{object-bounding-box,
  user-space-on-use}.svg`: `transform-origin` on a `linearGradient`/
  `radialGradient` element itself. Gradient elements are parsed in a separate
  pre-pass (`defsScan`/`parseGradDef`) that never goes through
  `applyEffective` (where `transform-origin` is read and composed today), and
  gradient coordinates live on the fine 16.16 grid `shapeCmds16` uses for the
  same T20/T31 quantization reasons — wiring a second `transform-origin`
  parse through that pipeline correctly, without risking every currently-
  passing gradient file, was not a small change. The other 4
  `transform-origin` failures need `pattern`/`image`/`textPath`, out of scope
  per the task.
- `structure/transform-origin/on-pattern-*.svg`, `.../on-image.svg`,
  `.../on-text-path.svg`; `structure/systemLanguage/on-tspan.svg`;
  `masking/clipPath/with-use-child.svg`; `structure/defs/style-inheritance*.svg`
  (both need `use`); `masking/clipPath/clip-path-with-transform-on-text.svg`;
  `structure/a/on-text.svg` (needed text, not `<a>` — fixed as a side effect
  of #4 anyway, see Report): all need `use`/`pattern`/`image`/`text`, owned by
  other agents.
- `masking/clip/simple-case.svg`: the only file in `masking/clip` in this
  corpus, and it's a `clip="rect(...)"` on an `<image>` — needs `<image>`,
  out of scope.
- `shapes/path/{M-A-s,M-C-S,M-C,M-S-S,M-S,M-T-S,invalid-transform}.svg`:
  all sit at 97.8–98.8% within-8 (threshold 99%), just under the line, and
  `M-C.svg`/`invalid-transform.svg` (same path, no smooth-curve command
  involved) fail identically — so this isn't a smooth-curve-default bug, it's
  antialiasing on the stroke outline of a sharply-curving open cubic, a
  rasterizer-fidelity gap rather than a missing feature. Diffed
  `M-C.svg` against `resvg` directly: the mismatched pixels are alpha-only,
  scattered along the stroke edge, consistent with flattening/join tolerance
  rather than a parsing error. Fixing that well means touching the stroke
  outliner or curve flattening shared by every passing curve test, which is
  outside "biggest shared cause, smallest diff" for a handful of files this
  close to the threshold already.
- `structure/transform`, `structure/style`, `structure/switch`,
  `structure/g`, `shapes/circle`, `shapes/polygon`, `shapes/polyline`,
  `masking/clip-rule`, all `paint-servers/*`: already 100% (or, for `circle`,
  effectively 100% — one file at 99.99%) pass at the fast/width-100 triage
  pass, nothing to fix.

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.

## Report

All changes are in `LeanSvg/Svg.lean`. New test: `tests/svg/28_shape_tail.svg`
(99.990% within-8, PASS), exercising percent geometry, `rx`-only/`ry`-only
auto-resolution, a negative `rx`, percent `line` coordinates, `<a>` as a
plain container, `style=""` comment stripping, and a shape's own (unrendered)
child.

Verification (all commands from "Verification before you push"):

- `lake build`: clean, no errors, no new warnings.
- `bash scripts/check-theorems.sh`: `theorems ok`.
- `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`:
  **18 newly passing, 0 newly failing**, 1661 unchanged.
- `python3 tests/run_tests.py`: 24/27 pre-existing local-corpus files unchanged
  (23/27 pass, same 4 pre-existing failures as baseline, no score regressed),
  plus the new `28_shape_tail` at 99.990% (PASS) — 24/28 overall.
- `python3 tests/run_adversarial.py`: 62/62 clean (was 61/61; +1 for the new
  test file's generated variants).
- `python3 tests/run_tiles.py`: 28/28 byte-identical (was 27/27).

### Whole corpus (resvg, direct route, `--fast`, width 100)

| | before | after |
|---|---|---|
| pass | 835 / 1679 (49.7%) | 853 / 1679 (50.8%) |
| med within-8 | 98.965% | 99.465% |
| med exact | 97.860% | 98.035% |

### Target directories (resvg, direct route, `--fast`, width 100)

| directory | files | pass before | pass after |
|---|---|---|---|
| shapes/path | 57 | 50 (87.7%) | 50 (87.7%) — unfixed, see "Skipped" |
| shapes/rect | 38 | 31 (81.6%) | **38 (100.0%)** |
| shapes/ellipse | 12 | 6 (50.0%) | **12 (100.0%)** |
| shapes/circle | 6 | 6 (100.0%) | 6 (100.0%) — already full |
| shapes/line | 10 | 9 (90.0%) | **10 (100.0%)** |
| shapes/polygon | 5 | 5 (100.0%) | 5 (100.0%) — already full |
| shapes/polyline | 5 | 5 (100.0%) | 5 (100.0%) — already full |
| structure/transform-origin | 23 | 17 (73.9%) | 17 (73.9%) — unfixed, see "Skipped" |
| structure/transform | 19 | 19 (100.0%) | 19 (100.0%) — already full |
| structure/style | 16 | 16 (100.0%) | 16 (100.0%) — already full |
| structure/style-attribute | 4 | 3 (75.0%) | **4 (100.0%)** |
| structure/systemLanguage | 10 | 9 (90.0%) | 9 (90.0%) — unfixed, needs `tspan` |
| structure/switch | 13 | 13 (100.0%) | 13 (100.0%) — already full |
| structure/a | 5 | 3 (60.0%) | **5 (100.0%)** |
| structure/g | 2 | 2 (100.0%) | 2 (100.0%) — already full |
| structure/defs | 7 | 5 (71.4%) | 5 (71.4%) — unfixed, needs `use` |
| masking/clipPath | 52 | 50 (96.2%) | 50 (96.2%) — unfixed, needs `use`/text |
| masking/clip | 1 | 0 (0.0%) | 0 (0.0%) — unfixed, needs `image` |
| masking/clip-rule | 1 | 1 (100.0%) | 1 (100.0%) — already full |
| paint-servers/linearGradient | 38 | 38 (100.0%) | 38 (100.0%) — already full |
| paint-servers/radialGradient | 45 | 45 (100.0%) | 45 (100.0%) — already full |
| paint-servers/stop | 32 | 32 (100.0%) | 32 (100.0%) — already full |
| paint-servers/stop-color | 1 | 1 (100.0%) | 1 (100.0%) — already full |
| paint-servers/stop-opacity | 2 | 2 (100.0%) | 2 (100.0%) — already full |

Net for the assigned directories: **17 files newly passing** (rect +7,
ellipse +6, line +1, style-attribute +1, `a` +2 — the `a` count includes both
`on-shape.svg`, the one this task targeted, and `on-text.svg`, a bonus from
the same `<a>`-as-`<g>` fix), 0 regressed. The whole-corpus diff shows 18
newly-passing files total; the 18th, `text/font-size/named-value.svg`, is
outside the assigned directories — a bonus from `em`/`ex` now resolving
against the element's own font size instead of a fixed 16 px.
