# T85 — implement context-fill/context-stroke with paint servers  (branch `claude/feat-context-paint`)

`tasks/T79-context-paint.md` has a full diagnosis in its `## Report`: usvg
resolves `context-fill`/`context-stroke` gradients and patterns against the
`<use>` element's bounding box (and transform), not the child's. Implement
that fix as the report proposes (about 150–250 lines across the frame, paint
and pattern-render code), or a better design if you find one. Files:
`painting/context/with-gradient-and-gradient-transform.svg`,
`with-gradient-in-use.svg`, `with-pattern-and-transform-in-use.svg`,
`with-pattern-in-use.svg`, `with-pattern-objectBoundingBox-in-use.svg`, plus
any other `painting/context` or `painting/marker` files this fixes.

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

## Spec implemented

usvg 0.48.1 (`parser/use_node.rs`, `parser/paint_server.rs::update_paint_servers`/
`process_paint`/`process_context_paint`): a paint that a shape gets through
`context-fill`/`context-stroke` from a `<use>` is a paint server *of that use*.
It is placed with the use group's absolute transform (the use's `transform`
followed by its `x`/`y` translate) and, for `objectBoundingBox` units, sized by
the object bbox of the use's whole expanded content in that space (usvg's
`Group::bounding_box`: children's fill boxes through their own transforms). The
painted descendant's own bbox and transform play no part. usvg does not apply
the descendant's own `has_bbox` check to a context paint either.

Design (smaller than T79's proposal: no change to `Paint` constructors, so
`PatternRender.lean` is untouched):

- `Svg.CtxUse {ctm, bbox}` and `Doc.ctxUses`: one slot per rendered `<use>`
  whose own fill or stroke is a gradient or pattern. The slot takes the use's
  CTM on open. Its bbox comes from the existing `Frame.bbox`/`want` machinery
  on close (the use frame sets `want`, the same way a `clip-path` use does).
- `Style.ctxSlot` (inherited; set on each `use`, `none` when the use's paint is
  not a server) and `Style.fillCtx`/`strokeCtx`. `applyProp` sets these to
  `ctxSlot` when the value is `context-*` and resets them for any other paint.
  An inherited context paint keeps its slot.
- `Render.drawShape`: `paintMask` takes the shape's `fillCtx`/`strokeCtx`. With
  a slot it hands `Grad.build`/`Pat.build` the slot's box as a rectangle path
  and `rootMat · slot.ctm` (layer-shifted as before) instead of the shape's own
  `cmds`/`gctm`. Without a slot the path is byte-identical to before.
- The shape-level `has_bbox` fallback (`fixPaint`, T64) is skipped for a
  context paint.

## Skipped

- Context paint inside markers (`with-gradient-on-marker`, `in-marker` etc.,
  T73's scope). Slots are only created for a `use` in `.render` mode, so a `use`
  inside a marker, `defs` or a clip keeps its old behaviour.
- `use` → `symbol` with a viewport clip: usvg marks the outer clip group as the
  context element, and that group's `abs_transform` is set to the parent's. We
  use the `use`'s CTM. This is not exercised by the corpus.
- Pattern content (`PatternRender`) does not read the slots. usvg resolves
  pattern children with an empty context.

## Report

Target files, within-8:

| file | 100 px before → after | 200 px before → after |
|---|---|---|
| with-gradient-and-gradient-transform | 69.45 → 99.71 (pass) | 71.04 → 99.93 (pass) |
| with-gradient-in-use | 69.83 → 99.66 (pass) | 70.74 → 99.94 (pass) |
| with-pattern-in-use | 82.42 → 99.84 (pass) | 83.70 → 99.94 (pass) |
| with-pattern-and-transform-in-use | 70.11 → 98.40 (fail) | 74.12 → 98.86 (fail) |
| with-pattern-objectBoundingBox-in-use | 68.94 → 98.07 (fail) | 72.06 → 93.45 (fail) |
| with-text (bonus) | 96.74 → 100.00 (pass) | 97.00 → 99.90 (pass) |

The pattern geometry in the two remaining failures now matches resvg (checked
with side-by-side renders). What is left sits along pattern-cell edges. In both
files the `use` has `transform="rotate(45)"`, so the pattern tile is sampled
under rotation. That is the same limitation that makes
`paint-servers/pattern/transform-and-patternTransform.svg` fail today (0.906 at
200 px) and has nothing to do with context paint.

Whole resvg suite (direct route): 100 px 1521 → 1525 pass. 200 px 1542 → 1546
pass (92.1%). 0 pass→fail and no within-8 drops at either width.
`tests/run_tests.py`: 47/51. The new `85_context_paint` passes (99.37); every
other file is unchanged, and the 4 failures that were already there remain.
`run_adversarial.py`: 117/117 clean. `run_tiles.py`: 51/51 byte-identical.
`lake build`: no warnings. `check-theorems.sh`: `theorems ok`.
