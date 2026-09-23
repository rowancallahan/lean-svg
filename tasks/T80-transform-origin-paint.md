# T80 — `transform-origin` on gradients and patterns  (branch `claude/fix-transform-origin-paint`)

`transform-origin` already works on elements (T24b/T38). usvg also applies it to `gradientTransform`/`patternTransform`.

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

- `structure/transform-origin/on-gradient-object-bounding-box.svg` (0.692)
- `structure/transform-origin/on-gradient-user-space-on-use.svg` (0.736)
- `structure/transform-origin/on-pattern-object-bounding-box.svg` (0.530)
- `structure/transform-origin/on-pattern-user-space-on-use.svg` (0.680)

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

---

## Report

### Root cause

usvg's `SvgNode::resolve_transform` (`crates/usvg/src/parser/converter.rs`) is
generic over which transform attribute it reads: it is called with
`AId::Transform` for a plain element, but also with `AId::GradientTransform`
(`paint_server.rs`, `convert_linear`/`convert_radial`) and
`AId::PatternTransform` (`paint_server.rs`, `convert_pattern`). In every case
it reads `transform-origin` from the *same node* (`self.attribute`, no
`href`-chain walk — unlike `gradientUnits`/`spreadMethod`/`gradientTransform`
itself, which do walk the chain via `resolve_attr`) and wraps the transform:
`translate(dx, dy) · transform · translate(-dx, -dy)`, with `dx`/`dy` resolved
as plain (non-percentage-`objectBoundingBox`) lengths against the current
viewport, exactly as for a plain element's `transform-origin`.

This renderer already implements `transform-origin` for elements (T24b/T38,
`Svg.lean`'s `parseTransformOrigin` and the `"transform"` case of
`applyProp`), but `parseGradDef`/`parsePatternDef` (`Svg.lean`) parsed
`gradientTransform`/`patternTransform` on their own, with no knowledge of the
sibling `transform-origin` attribute at all — so it was silently dropped for
every one of the four files, each of which relies on it to keep a
`gradientTransform="scale(2)"`/`patternTransform="scale(2)"` centred rather
than scaling away from the viewport's origin.

### Fix

Added `wrapTransformOrigin` (`Svg.lean`, next to `parseGradDef`): given the
element's own `attrs`, the viewport rect, and the already-parsed transform
matrix, it looks up the element's own `transform-origin` (no `href` walk,
matching `self.attribute`) and wraps the matrix the same way
`applyProp`'s `"transform"` case does for a plain element. Both
`parseGradDef` and `parsePatternDef` now call it right after parsing
`gradientTransform`/`patternTransform` (after the existing "invalid transform
becomes identity" step), so the origin wrap only ever applies to the
element's *own* transform value — never to one inherited through
`href`/`pickCommon`, matching `resolve_transform` being called on the
referenced node itself.

`defsScan` (`Svg.lean`) now also tracks `pctRefW`/`pctRefH` — the same
viewport rect as `Grad.PctRef`'s `pctRef.w`/`.h`, but in plain `Fx` (1/256 px)
rather than 16.16, since that is the scale `Mat.translate`'s `e`/`f` and
`applyEffective`'s `originDx`/`originDy` already use — and threads them into
both parse functions. They are set once, from the root `<svg>`'s own
`viewBox`/size, exactly where `pctRef` itself is set, so they are always
established before any `linearGradient`/`radialGradient`/`pattern` open event
can be reached.

No other files touched; `href` inheritance for `gradientTransform`/
`patternTransform` themselves (`pickCommon` in `Shader.lean`/`Pattern.lean`)
is untouched.

### Skipped

Nothing from the four target files. `transform-origin` on a gradient/pattern
reached only via `style=""`/CSS (rather than a presentation attribute) is not
handled, matching the pre-existing treatment of `gradientTransform`/
`patternTransform` themselves in `parseGradDef`/`parsePatternDef` (plain
`attr attrs "..."`, not `attrOrStyle` or the CSS cascade `defsScan` has no
access to) — no corpus file exercises this and it is out of this task's
scope.

### Before/after

Target files (`structure/transform-origin/`, within-8 at 200 px):

| file | before | after |
|---|---|---|
| `on-gradient-object-bounding-box.svg` | 0.692 | 1.000 |
| `on-gradient-user-space-on-use.svg` | 0.736 | 1.000 |
| `on-pattern-object-bounding-box.svg` | 0.530 | 1.000 |
| `on-pattern-user-space-on-use.svg` | 0.680 | 1.000 |

Whole `resvg` corpus, `--route direct`, zero pass→fail at both widths:

- `--fast` (100 px): 1521/1679 (90.6%) → 1525/1679 (90.8%). 4 newly passing
  (the target files), 0 newly failing, 1675 unchanged.
- default (200 px): 1542/1679 (91.8%) → 1546/1679 (92.1%). Same 4 newly
  passing, 0 newly failing, 1675 unchanged.

`lake build`: clean, no new warnings. `bash scripts/check-theorems.sh`:
`theorems ok`. `python3 tests/run_tests.py`: 47/51 pass; the 4 failures
(`12_badge`, `14_flower_transforms`, `15_spiral_stroke`, `16_stress_2000`)
are pre-existing stroke/path-rendering cases untouched by this change, and
the new `80_transform_origin_paint` fixture passes at 100.000% within-8.
`python3 tests/run_adversarial.py`: 117/117 clean. `python3
tests/run_tiles.py`: 51/51 byte-identical, including the new fixture.

Added `tests/svg/80_transform_origin_paint.svg`: two gradients
(`objectBoundingBox` and `userSpaceOnUse`) and two patterns
(`objectBoundingBox` and `userSpaceOnUse`), each with a `gradientTransform`/
`patternTransform` and a `transform-origin` (keyword and length forms).
