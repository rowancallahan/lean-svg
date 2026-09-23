# T75 — stroke long tail (branch `claude/feat-strokes`)

Remaining stroke/fill failures below (dasharray/dashoffset units and
edge cases, stroke-width, etc.). T57's report covers what was already done.
The rasterizer's default path is a careful tiny-skia port; do not change it,
and the stroker (`Geom.lean`) changes must keep every currently passing file
byte-identical or better.

Remaining resvg-correct failures at 200 px (from `tests/score_known.py` split):

- `painting/fill/radial-gradient-on-text.svg` (fail, within-8 0.946425)
- `painting/stroke-dasharray/comma-ws-separator.svg` (fail, within-8 0.988875)
- `painting/stroke-dasharray/em-units.svg` (fail, within-8 0.986800)
- `painting/stroke-dasharray/mm-units.svg` (fail, within-8 0.981450)
- `painting/stroke-dasharray/odd-count.svg` (fail, within-8 0.988600)
- `painting/stroke-dasharray/ws-separator.svg` (fail, within-8 0.988375)
- `painting/stroke-dashoffset/default.svg` (fail, within-8 0.988375)
- `painting/stroke-dashoffset/em-units.svg` (fail, within-8 0.988375)
- `painting/stroke-dashoffset/mm-units.svg` (fail, within-8 0.988725)
- `painting/stroke-dashoffset/negative-value.svg` (fail, within-8 0.988800)
- `painting/stroke-dashoffset/percent-units.svg` (fail, within-8 0.989275)
- `painting/stroke-dashoffset/px-units.svg` (fail, within-8 0.988800)
- `painting/stroke-width/percentage.svg` (fail, within-8 0.760000)
- `painting/stroke/radial-gradient-on-text.svg` (fail, within-8 0.944275)

Target: every file above passing at both widths, where achievable without breaking the invariants.

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
