# T60 — locality theorem, cheap half  (branch `claude/feat-locality`)

`ROADMAP.md` §3b, "the cheap half": prove that the per-shape compositing
loops never write outside the mask's rectangle.

```
theorem fillMask_local (cv : Canvas) (m : Raster.Mask) (c : Rgba) (a i : Nat) :
  ¬ inRect m cv.w i → (fillMask cv m c a).px.getD i 0 = cv.px.getD i 0
```

(adjust the signature to the real one) for `Canvas.fillMask`,
`Shader.fillMaskShader`, and `Canvas.compositeNormal` / `compositeBlend` (the
last two w.r.t. the layer's rectangle), plus the counting corollary (at most
`m.w * m.h` pixels change). Proofs in a new `proofs/Locality.lean`, checked by
`lake env lean proofs/Locality.lean`, `#print axioms` at the bottom, no
`sorry`; add it to `scripts/check-theorems.sh`. Read `proofs/SizeBound.lean`
first: it shows the idiom that worked here for `for` loops (rewriting as
explicit recursion with a proved-equal reference definition) and records what
did not elaborate. **Do not change renderer behaviour.** If a loop must be
restated to be provable, the restatement must be byte-identical (run_tests,
run_tiles, corpus all identical) and no slower (median of 3 on
`tests/svg/16_stress.svg` at `--width 1600`). Other agents are concurrently
editing `Render.lean`/`Canvas.lean` for features; prefer proving about the
existing definitions over restructuring them.

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
