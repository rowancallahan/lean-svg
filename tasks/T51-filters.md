# T51 — filter foundation and simple primitives  (branch `claude/feat-filters`)

Filters are the biggest failing cluster (~250 files). Build the foundation
and the simple primitives, matching resvg 0.48.1 (`crates/usvg/src/parser/filter.rs`,
`crates/resvg/src/filter/mod.rs` and friends). Everything in fixed point /
integer arithmetic; no floats. Follow resvg's algorithms exactly where it
matters for pixels (e.g. its box-blur vs IIR choice for Gaussian blur and its
rounding), since the harness tolerance is 8 levels.

Foundation: `filter="url(#id)"` on shapes and groups (element becomes a
layer); `filterUnits`/`primitiveUnits` and the filter region (default
-10%/-10%/120%/120%) and per-primitive subregions; the `in`/`in2`/`result`
graph with `SourceGraphic`, `SourceAlpha` (BackgroundImage etc. as usvg
treats them); `color-interpolation-filters` linearRGB (default) vs sRGB with
exact integer LUTs matching resvg's conversion tables; invalid references →
element not rendered (usvg rules); multiple filters in a list
(`filter="url(#a) url(#b)"`); CSS filter functions (`blur()`,
`drop-shadow()`, `grayscale()`, `sepia()`, `saturate()`, `hue-rotate()`,
`invert()`, `opacity()`, `brightness()`, `contrast()`) — see
`filters/filter-functions`.

Primitives in this task: `feFlood` (+flood-color/flood-opacity), `feOffset`,
`feMerge`, `feBlend`, `feComposite` (all operators incl. arithmetic),
`feColorMatrix`, `feGaussianBlur`, `feDropShadow`. Unsupported primitives
(lighting, turbulence, morphology, convolve, componentTransfer, tile, image,
displacement) should behave exactly as usvg does for an unknown primitive
(check — probably transparent black result); a wave-2 agent will add them, so
make adding a primitive a local change: one constructor + one function in
`LeanSvg/Filter.lean` (or `LeanSvg/Filter/*.lean`).

**Resource bounds (hard):** the filter region can be much larger than the
shape; clamp every intermediate surface to region ∩ canvas (or resvg's
equivalent), bound blur radius work, and bound primitive count per filter.
Add adversarial cases (huge stdDeviation, huge region, 1000 primitives) to
`tests/adversarial/`.

Target dirs: `filters/filter`, `filters/filter-functions`, `filters/feFlood`,
`flood-color`, `flood-opacity`, `feOffset`, `feMerge`, `feBlend`,
`feComposite`, `feColorMatrix`, `feGaussianBlur`, `feDropShadow`,
`enable-background` (usvg behaviour only).

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
