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

## Report

Implemented all four locality theorems plus the counting corollary, in a new
`proofs/Locality.lean`. `LeanSvg/*.lean` is **untouched** — no renderer
behaviour changed, so byte-identity was never at risk and no restatement of
any loop was needed.

### The idiom that worked

`proofs/SizeBound.lean`'s own header pointed at a restructure-and-prove-equal
idiom, but a cheaper one was available for *this* property. Core Lean has a
`@[simp]` lemma, `Std.Legacy.Range.forIn_eq_forIn_range'`
(`Init/Data/Range/Lemmas.lean`), that rewrites `forIn r init f` — what
`for a in [s:t] do ...` compiles to — into a plain `List.forIn` over
`List.range' r.start r.size r.step`. That turns every loop in `fillMask`,
`fillMaskShader`, `compositeNormal` and `compositeBlend` into an ordinary
`List.forIn` without touching `LeanSvg/Canvas.lean` or `LeanSvg/Shader.lean`
at all, so `SizeBound.lean`'s `forIn_invariant` idiom (list induction,
`ForInStep.val` to unify the `.done`/`.yield` cases) applies directly — except
the per-step hypothesis has to be scoped to `a ∈ l` rather than universal
(`forIn_invariant_mem`), because placing a written pixel inside the rectangle
needs the loop variable's bound, and that only holds for members of the list
actually walked (`List.mem_range'_1 : m ∈ range' s n ↔ s ≤ m ∧ m < s + n` for
step 1). `forIn_range_invariant` packages that specialisation for `[0:n]`,
which is what all eight loops (two per function) use.

Per pixel, the only fact needed is `getD_setIfInBounds_ne`: a write at
`idx ≠ i` leaves index `i` alone, whatever value was written and whether or
not `idx` was in the array's bounds (`setIfInBounds` is a no-op out of
bounds, which matters for `compositeNormal`/`compositeBlend` walking past a
layer clipped against the canvas edge). Combined with `.done`/`.yield` both
going through `ForInStep.val`, `compositeNormal`'s and `compositeBlend`'s
`break`s (`if oy + ly ≥ cv.h then break`, `if ox + lx ≥ cv.w then break`) need
no special-casing: a `break` before any write in that iteration is exactly as
inert as `fillMask`'s `continue` on a below-threshold coverage pixel, or
`fillMaskShader`'s `continue` on a `Grad.paramAt` miss.

Each locality proof: `unfold` the function, `simp only [Id.run, bind, pure]`
to drop the monad wrappers, then two nested `forIn_range_invariant`
applications (outer over the row range, inner over the column range) with a
fixed invariant `fun s => s.getD i 0 = cv.px.getD i 0`. Inside the inner
step, `repeat' split` case-splits every remaining `if`/`match` (coverage
thresholds, opaque/translucent choice, the gradient's `none`/`some`), then
every leaf is closed by either `exact hs'` (no write) or
`rw [getD_setIfInBounds_ne hidx]; exact hs'` (write, at an index proved `≠ i`
from `¬ inRect ... i` plus the loop bounds). `compositeNormal`/
`compositeBlend`'s row step uses a plain single `split` instead of `repeat'`,
because `compositeBlend` hoists an unrelated `if` (choosing `srcTab`) that
`repeat'` would otherwise also split at the row level, leaving a case the two
handwritten bullets don't cover.

### Signatures actually proved

```
def inRect (x0 y0 rw rh stride i : Nat) : Prop :=
  ∃ x y, x < rw ∧ y < rh ∧ i = (y0 + y) * stride + (x0 + x)

theorem fillMask_local (cv : Canvas) (m : Raster.Mask) (c : Rgba) (a i : Nat)
    (hi : ¬ inRect m.x0 m.y0 m.w m.h cv.w i) :
    (Canvas.fillMask cv m c a).px.getD i 0 = cv.px.getD i 0

theorem fillMaskShader_local (cv : Canvas) (m : Raster.Mask) (sh0 : Grad.Rt) (i : Nat)
    (hi : ¬ inRect m.x0 m.y0 m.w m.h cv.w i) :
    (Canvas.fillMaskShader cv m sh0).px.getD i 0 = cv.px.getD i 0

theorem compositeNormal_local (cv layer : Canvas) (ox oy opQ i : Nat)
    (hi : ¬ inRect ox oy layer.w layer.h cv.w i) :
    (Canvas.compositeNormal cv layer ox oy opQ).px.getD i 0 = cv.px.getD i 0

theorem compositeBlend_local (cv layer : Canvas) (ox oy : Nat) (opacity : F32) (mode : BlendMode)
    (i : Nat) (hi : ¬ inRect ox oy layer.w layer.h cv.w i) :
    (Canvas.compositeBlend cv layer ox oy opacity mode).px.getD i 0 = cv.px.getD i 0
```

`inRect x0 y0 rw rh stride i` is the mask's rectangle (`m.x0 m.y0 m.w m.h`)
for the first two, the layer's rectangle (`ox oy layer.w layer.h`) for the
last two, exactly as the handoff asked.

### The counting corollary

No `Finset`/`Fintype` is available (`lakefile.toml`: "No dependencies on
purpose... no mathlib"), so "at most `rw * rh` pixels change" is stated
without cardinality machinery, as a covering list:

```
theorem inRect_count (x0 y0 rw rh stride : Nat) :
    ∃ l : List Nat, l.length = rw * rh ∧ ∀ i, inRect x0 y0 rw rh stride i → i ∈ l
```

`inRect`'s witness pair `(x, y)` ranges over `rw * rh` combinations, so the
list built from `(List.range rh).flatMap (fun y => (List.range rw).map ...)`
(length `rh * rw`, i.e. `rw * rh`) contains every index the predicate can
hold of — with duplicates if the rectangle overflows a row of the canvas,
which can only shrink the true count of pixels actually touched, never grow
it past `rw * rh`. `fillMask_count`, `fillMaskShader_count`,
`compositeNormal_count` and `compositeBlend_count` each combine
`inRect_count` with the matching `_local` theorem (contrapositive, via
`Classical.byContradiction` — `by_contra` is a Mathlib tactic, not core) to
get: `∃ l, l.length = <rect area> ∧ ∀ i, result.px.getD i 0 ≠ cv.px.getD i 0 → i ∈ l`.

### What was skipped

Nothing from the spec. `scripts/check-theorems.sh` was not edited: its
`for f in proofs/*.lean tests/*.lean` glob already picks up
`proofs/Locality.lean` (confirmed below), so no line needed adding. No new
`tests/svg/NN_*.svg` was added — this task proves a property of existing
compositing code, not a new renderer feature, so there is nothing new to
exercise visually; the fidelity/adversarial/tile suites below are the actual
regression check and they are unaffected (expected, since `LeanSvg/*.lean` is
untouched).

### Verification

1. `lake build`: clean, no new warnings (45/45 jobs, no rebuild triggered
   for the renderer itself since only a new `proofs/` file was added).
2. `bash scripts/check-theorems.sh`: `theorems ok`. All 8 new theorems
   (`fillMask_local`, `fillMaskShader_local`, `compositeNormal_local`,
   `compositeBlend_local`, `fillMask_count`, `fillMaskShader_count`,
   `compositeNormal_count`, `compositeBlend_count`) print
   `depends on axioms: [propext, Classical.choice, Quot.sound]` — no
   `sorryAx`, same axiom set as `SizeBound.lean`'s `render_output_size_bound`.
   `lake env lean proofs/Locality.lean` alone: ~2s.
3. Corpus fidelity, before vs. after (`tests/run_corpora.py --fast --corpus
   resvg --route direct`): 1679/1679 files rendered identically — "0 file(s)
   moved by more than 0.1 points of within-8", "newly passing 0 - newly
   failing 0 - unchanged 1679". 835 pass both times.
4. `python3 tests/run_tests.py`: 23/27 before and after, identical scores
   per file (the 4 known failures — `14_flower_transforms`,
   `15_spiral_stroke`, `16_stress_2000`, an existing hairline/gradient
   rounding gap on a couple of others — are pre-existing and untouched).
5. `python3 tests/run_adversarial.py`: 61/61 clean.
6. `python3 tests/run_tiles.py`: 27/27 files byte-identical, quadrant tiles
   stitch identically to the full render.
7. No timing comparison was taken: since no loop was restated (the whole
   proof works directly against the `for`-loop definitions as written,
   nothing in `LeanSvg/Canvas.lean` or `LeanSvg/Shader.lean` changed), the
   "no slower" condition does not apply — the compiled renderer binary's
   inputs are byte-for-byte the same Lean source as before this task.

`git diff --stat` against the branch point: one new file,
`proofs/Locality.lean`; `LeanSvg/*.lean` untouched.
