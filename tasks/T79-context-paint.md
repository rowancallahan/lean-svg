# T79 — `context-fill`/`context-stroke` with gradients and patterns in `use`  (branch `claude/fix-context-paint`)

T47 added `ctxFill`/`ctxStroke` for `use`; solid colours work. With a gradient/pattern the paint server's units/transform must be resolved against the right element (usvg: the context element's bbox or the using element's?).

## How to work (research first)

1. **Diagnose first (keep it short).** Render each file below with
   `.lake/build/bin/lean-svg` and with `resvg -w 200`, look at both PNGs and a
   diff, find the root cause in our code, and find how resvg/usvg 0.48.1
   handles it in the Rust source.
2. **If the fix is small and safe**, implement it, verify it with the rules
   below, and push.
3. **If it is not**, do not force it: write the diagnosis (root cause, the
   relevant usvg/resvg code, the proposed fix and its risks, rough size) into
   your task file's `## Report`, and push only that.
Either way the report must name the root cause of every file below.

Files (within-8 at 200 px):

- `painting/context/with-gradient-and-gradient-transform.svg` (0.710)
- `painting/context/with-gradient-in-use.svg` (0.707)
- `painting/context/with-pattern-and-transform-in-use.svg` (0.741)
- `painting/context/with-pattern-in-use.svg` (0.837)
- `painting/context/with-pattern-objectBoundingBox-in-use.svg` (0.721)

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
3. Full corpus with delta table (the fast 100 px pass), and ALSO the default
   200 px pass that is the headline number: run the same command without
   `--fast` into `/tmp/base200` before editing and `/tmp/after200` after, and
   compare. Zero pass→fail at either width.
   Fast:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/<task number>_<feature>.svg` (use your
   task number as the file number, e.g. `71_image_gif.svg`, so files never
   collide) exercising the feature
   if it fits the local corpus style 

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.

## Report

No code changed. This is a diagnosis-only push: the fix is real but not
small, for reasons below, so per the task's own rules ("if it is not [small
and safe], do not force it") I'm leaving the implementation to a follow-up
task rather than risking the shared traversal/paint-server code on a rushed
patch.

### Root cause (one bug, all five files)

All five files follow the same shape: a `<g id="g1">` in `<defs>` holding
several children with `fill="context-fill" stroke="context-stroke"`, each
with its *own* extra `transform` (`rotate(90)`, `scale(0.8 0.8)`, etc.), used
once via `<use href="#g1" fill="url(#grad-or-pattern)" .../>`.

Side-by-side renders at 200px (`/tmp/ctxpaint/*_side.png` during this
session; not committed) show the bug directly: resvg paints one gradient/
pattern, positioned and scaled once for the whole `<use>` instance, so it
looks continuous across the rect and both rotated/scaled stars. lean-svg
paints a *different* gradient angle / pattern phase on each child, because
each child's own extra `transform` reorients the paint independently.

**Our code.** `ctxFill`/`ctxStroke` (`LeanSvg/Svg.lean:216-217`) are set once,
on entering a `use` (`LeanSvg/Svg.lean:3713-3734`), to the `noAlpha` of the
use element's own resolved `st.fill`/`st.stroke` — i.e. whatever
`Paint` `resolvePaint` built for `fill="url(#lg)"` on the `<use>` itself,
`.gradient i fallback` / `.pattern i`, carrying only the defs-table index
`i`. A descendant's `fill="context-fill"` (`PaintSpec.context`) resolves via
`resolvePaint` (`LeanSvg/Svg.lean:1572`) to that *same* `Paint` value,
unchanged. So far this matches usvg (solid colours already worked via this
path, per T47).

The bug is downstream, in `Render.drawShape`
(`LeanSvg/Render.lean:283-293`): for `.gradient i _`/`.pattern i` it always
calls `Grad.build st.defs i s.cmds gctm …` / `Pat.build doc … i s.cmds gctm
…` using **the currently-painted descendant's own** `s.cmds` (for
`objectBoundingBox` units, via `Grad.build`'s `tightBox cmds`,
`LeanSvg/Shader.lean:990-999`) and **its own** accumulated `gctm`
(`LeanSvg/Render.lean:238,269-270`, built from `st.ctm`, which already
includes the descendant's private `rotate(90)`/`scale(0.8 0.8)`). Nothing
about the fact that this paint arrived via `context-fill`/`context-stroke`
survives past `resolvePaint`, so the gradient/pattern gets re-anchored and
re-oriented per descendant instead of once for the `<use>`.

**usvg 0.48.1.** `crates/usvg/src/parser/use_node.rs:32-41` marks the fill/
stroke resolved on the `use` node itself with `context_element =
Some(ContextElement::UseNode)`, and `use_node.rs:98,123` marks the `use`'s
*own* synthesized group `g.is_context_element = true`. After the whole tree
is parsed, `crates/usvg/src/parser/paint_server.rs::update_paint_servers`
(555-573) walks it again: descending into a group with
`is_context_element`, the `context_transform`/`context_bbox` handed to its
children becomes that group's own `abs_transform`/`bounding_box` (i.e. the
`<use>`'s own absolute transform and the bbox of its *whole* expanded
content, computed once). `process_paint`/`process_context_paint`
(paint_server.rs:888-925, 815-886) then, for any fill/stroke whose
`context_element == UseNode`: (a) if the paint server uses
`objectBoundingBox`, resolves it against that `context_bbox` instead of the
individual path's own bbox; (b) folds in a `rev_transform` derived from
`context_transform` and the individual path's own `abs_transform`
(`path_transform⁻¹ ∘ context_transform`) so that once resvg later composes
the stored paint transform with the *path's* own `abs_transform` at render
time, the net effect is exactly `context_transform ∘ (bboxTransform(
context_bbox) ∘ gradientTransform ∘ frame)` — i.e. the paint server is
positioned and unit-scaled once, by the `<use>`'s own transform and its own
content's bbox, and every descendant that paints with `context-fill`/
`context-stroke` shares that same absolute gradient/pattern regardless of
its own extra `transform`.

So: **usvg resolves an `objectBoundingBox` paint server reached via
context-fill/-stroke against the `<use>` element's own bbox and transform,
not the bbox/transform of whichever descendant is actually being painted**
— confirming the question the task poses. Concretely for these five files:
because the shapes inside `#g1` are exactly `rect`/rotated-star/scaled-star,
each descendant's own bbox and ctm differ, and it is that per-descendant
divergence that our current code (wrongly) feeds into `Grad.build`/
`Pat.build`.

### Why this isn't a small fix

Reproducing usvg's behaviour needs the bbox of the **whole `<use>`
subtree**, in the `use`'s own local space, computed once — not any single
shape's bbox. The codebase already has exactly one mechanism for "the union
bbox of a subtree, in its own user space, computed once while walking it":
`Frame.bbox`/`Frame.want` in `LeanSvg/Svg.lean` (3163-3194), the machinery
`clip-path`/`mask` `objectBoundingBox` resolution already uses (`uses`/
`maskUses` arrays, `Box.union`, bbox written back into a table slot when the
frame closes: `LeanSvg/Svg.lean:3519,3522,3877,3880,3889` etc.). Reusing it
for `use` means:

1. On entering a `use` (`Svg.lean:3713-3734`), check whether the use's own
   resolved `fill`/`stroke` references an `objectBoundingBox` gradient or
   pattern, and if so set `frame.want := true` so a bbox gets accumulated
   for its whole expanded content, and allocate a slot (ctm + bbox-on-close)
   in a new small table, the same shape as `MaskUse`/`ClipUse`.
2. Give `Style` two more fields alongside `ctxFill`/`ctxStroke` (e.g.
   `ctxFillSlot`/`ctxStrokeSlot : Option Nat`) pointing at that slot, set at
   the same point and inherited the same way (record-update propagation
   already does this for `ctxFill`/`ctxStroke`, so this part is cheap).
3. Thread the new table through `interpret`'s traversal state into
   `Svg.Doc`, the way `doc.masks`/`doc.clips` already are.
4. Give `Paint.gradient`/`Paint.pattern` an optional slot reference and
   update every match on those constructors: construction sites
   `Svg.lean:1583,1586,3927,3945`, and consumption sites
   `Render.lean:283,289` *and* `PatternRender.lean:285,298` — pattern tiles
   recursively render their own content, which can itself paint with a
   gradient or pattern, so the same plumbing has to reach that recursive
   path too.
5. At each `Grad.build`/`Pat.build` call site, substitute the slot's stored
   ctm/bbox for the shape's own `gctm`/`s.cmds` when a slot is present
   (e.g. hand `Grad.build` a synthetic one-rect path spanning the stored box
   instead of `s.cmds`), leaving the ordinary (non-context) path byte-
   identical.

None of this is individually hard, but it touches the single ~4000-line
`interpret` walk in `Svg.lean`, reuses (and risks regressing) the
`Frame.bbox`/`want` machinery that today's passing `clipPath`/`mask`
`objectBoundingBox` tests depend on, and widens an enum matched in four
files including the pattern-tile recursion. Rough size: ~150-250 changed/
added lines across `Svg.lean`, `Render.lean`, `PatternRender.lean` (plus
maybe a small new module for the slot-table type), and a full corpus +
adversarial + tiles re-verification given the shared machinery touched.
That's more than a same-session, low-risk patch, so it's left as a
follow-up rather than forced here.

### Before / after

No code changed, so before == after. For the record, current state on this
branch (untouched):

- `painting/context/*` targets: unchanged at the scores given above (0.710,
  0.707, 0.741, 0.837, 0.721 within-8 at 200px).
- `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out
  /tmp/base --no-worst`: 1521/1679 pass (90.6%), unchanged from repo head.
- `python3 tests/run_tests.py`: 46/50 suites pass; the 4 pre-existing
  failures (`12_badge`, `14_flower_transforms`, `15_spiral_stroke`,
  `16_stress_2000`) are unrelated to context-fill/-stroke and predate this
  task.
