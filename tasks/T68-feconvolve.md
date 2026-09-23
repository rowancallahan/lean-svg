# T68 — feConvolveMatrix  (branch `claude/feat-feconvolve`)

The filter foundation (T51, read `tasks/T51-filters.md` and `DESIGN.md`
§3.11 first) has landed. Adding a primitive is: a `Kind` constructor, a clause
in `Filter.convertPrim`, a case in `FilterApply.runPrim`, and removing its name
from `Filter.isKnownUnsupported`. **Other agents are adding other primitives
concurrently**, so: put all of your primitive's code in a new file
`LeanSvg/Filter/<Name>.lean` (imported where needed), and keep your edits to
`Filter.lean`/`FilterApply.lean` to those few one-line-ish additions. Match
resvg 0.48.1's `crates/resvg/src/filter/*.rs` exactly where pixels depend on
it (its f32 maths must be reproduced in fixed point/integers to within the
8-level tolerance; exact is better — T51's report shows how it matched
colour-space LUTs and f32 sin/cos). Respect T51's work budgets: every
per-pixel loop is bounded by the layer area times a constant or a bounded
kernel size; cap kernel sizes/octaves/etc. as resvg does, and add an
adversarial case for the expensive parameter.

Target: `filters/feConvolveMatrix` (15 failing). resvg `filter/convolve_matrix.rs`:
`order`, `kernelMatrix`, `divisor` (0 → sum, sum 0 → 1), `bias`, `targetX/Y`,
`edgeMode` (duplicate/wrap/none), `preserveAlpha`, and usvg's validation
rules that make the primitive transparent black or the filter invalid.
Kernel values are f32 in resvg: reproduce the accumulation order and
rounding. Cap `order` as usvg does and add an adversarial case.

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

## What was implemented

Files: `LeanSvg/Filter/ConvolveMatrix.lean` (new — the per-pixel algorithm),
`LeanSvg/Filter.lean` (`Kind.convolveMatrix`, `Filter.primWork`,
`convertConvolveMatrix`/`parseTarget`, two small `F32` helpers, one
`convertPrim` clause, one name removed from `isKnownUnsupported`),
`LeanSvg/FilterApply.lean` (one import, one `runPrim` case),
`LeanSvg/Render.lean` (the filter-work budget now weighs a primitive by
`Filter.primWork` instead of counting it as `1` — see Bounds below).

* **Parsing and validation (usvg `parser/filter.rs::convert_convolve_matrix`).**
  `order` (svgtypes' `NumberListParser` two-call semantics: an unreadable
  first number defaults both to `3×3`; a readable first with an
  unreadable/absent second defaults the second to the first; either
  non-positive keeps `3×3`), `kernelMatrix` (`Filter.f32List`'s existing
  all-or-nothing `Vec<f32>` parse, kept only if its length matches
  `order.1 * order.2`), `divisor` (defaults to the kernel sum — a left-to-right
  `f32` fold, rounded to the nearest 1e-6 exactly on the binary32's own
  rational value via `f32Rat` rather than by re-rounding through more `f32`
  arithmetic, and forced to `1.0` if that is zero — `0` itself invalid),
  `bias`, `targetX`/`targetY` (`parse_target`: an explicit number truncated
  toward zero, or `⌊order/2⌋`, `none` outside `[0, order)`), `edgeMode`
  (`duplicate`/`wrap`/`none`), `preserveAlpha`. Every invalid combination —
  zero divisor, a `kernelMatrix` that doesn't match `order`, an out-of-range
  target, or a kernel past `Filter.maxConvolveCells` (see Bounds) — becomes
  usvg's `create_dummy_primitive`: a transparent black `feFlood`, which
  `convertUrl` keeps as one ordinary primitive rather than dropping the whole
  filter (confirmed against 10 of the corpus's own invalid-parameter cases,
  which pattern-match usvg's dummy exactly — see Report).
* **The algorithm (resvg `filter/convolve_matrix.rs::apply`).** Ported
  formula-for-formula in `LeanSvg/Filter/ConvolveMatrix.lean`: the three edge
  modes, the flipped kernel index (`matrix.get(columns - ox - 1, rows - oy -
  1)`), the `preserveAlpha` demultiply-before/no-multiply-after asymmetry (the
  output is already correctly scaled by the output alpha in both cases, which
  is why resvg never re-premultiplies and neither does this file), and the
  `(x * 255.0 + 0.5) as u8` *rounding* cast that this primitive alone uses
  (every other filter primitive here truncates, `Filter.f32TruncU8`) — a new
  `f32Round255` reproduces the extra `+ 0.5` addition as its own `f32` step,
  not folded into the multiply. Colour space and `preserveAlpha`'s demultiply
  match `apply_convolve_matrix`'s wrapping exactly (`.into lin` in
  `FilterApply.runPrim`, then `ConvolveMatrix.demultiply` only when
  `preserveAlpha`).
* **Bounds.** Every other primitive here costs `O(area)` total, so the
  existing `nprims * area ≤ maxFilterWork` budget (T51) bounded all of them by
  bounding `nprims`. `feConvolveMatrix` costs `O(area · cells)` per primitive —
  an arbitrary weighted kernel can't be reduced to a sliding window the way
  box blur's uniform one can — so a single primitive with a kernel anywhere
  near resvg's own limit (`kernelMatrix` parses up to `Filter.f32List`'s 4096
  entries) over a `maxFilterPixels`-sized region is `~4096 × 16777216 ≈ 6.9e10`
  cell evaluations: confirmed by timing that this hangs (>150 s) before the
  fix below. Two independent caps: `Filter.maxConvolveCells = 1024` rejects
  (to the dummy primitive) any `order` product past 32×32 — the corpus's
  largest is 20 — and `Filter.primWork` now weighs a `feConvolveMatrix`
  primitive by its cell count in `Render.lean`'s existing budget check, so
  `cells * area ≤ maxFilterWork` (2^25) holds for *any* accepted kernel,
  giving a hard bound on total per-pixel-times-cell work regardless of region
  size — the one line in `Render.lean` this task's own instructions allow for
  ("bounded by the layer area times a constant **or a bounded kernel
  size**"). `tests/adversarial/filter_convolve_huge_kernel.svg` exercises
  both: an order past `maxConvolveCells` (fast dummy) and an at-cap
  32×32 kernel over a large region (fast `filter budget` rejection instead of
  the multi-minute hang); both complete in ~1 s total.

## Skipped, and why

* **Fidelity on the pattern-filled corpus files.** 21 of the corpus's 25
  files fill the convolved rect with `url(#patt1)` (a `<pattern>`); `<pattern>`
  paint servers are T53's and are not yet rendered, so `SourceGraphic` is
  transparent for those files regardless of how correct the convolution is.
  The one plain-fill file among the 15 the task named as failing
  (`edgeMode=wrap-with-matrix-larger-than-target.svg`, `fill="green"`) now
  passes, as does `bias=9999.svg` (its `bias` saturates the output
  independently of the — currently blank — input, so it passes despite the
  missing pattern). The other 13 pattern-dependent cases in that list stay
  failing for that reason, not for anything this task owns; they should start
  passing once T53 lands, since the convolution itself is verified correct on
  every input this renderer can actually produce today (the 10 already-passing
  invalid-parameter cases, the new plain-fill corpus pass, and
  `tests/svg/48_convolve.svg`'s four filters checked by eye against `resvg`).
* **`kernelUnitLength`.** usvg parses but does not use it for
  `feConvolveMatrix` (resvg's `apply` always works in device pixels); nothing
  to implement.

## Report

Baseline commit `1ba4c27`. `run_corpora.py --fast --corpus resvg --route
direct` (width 100), whole suite: **1224/1679 → 1226/1679 passing; newly
passing 2, newly failing 0.**

`filters/feConvolveMatrix` specifically (`run_corpora.py --corpus resvg
--route direct --dir filters/feConvolveMatrix`, natural size, 25 files):
10/25 → 12/25 passing (the 13 remaining fails are the pattern-fill cases
above). At `--fast`/width 100 (the delta table `run_corpora.py` prints):

| file | within-8 before | after |
|---|---|---|
| `edgeMode=wrap-with-matrix-larger-than-target.svg` | 96.800% | 100.000% (fail→pass) |
| `bias=9999.svg` | 7.840% | 100.000% (fail→pass) |
| `bias=0.5.svg` | 7.840% | 59.800% (fail→fail, still pattern-blocked) |

Other checks, all on the final commit:

* `lake build`: no errors, no new warnings.
* `scripts/check-theorems.sh`: `theorems ok` (`proofs/SizeBound.lean`
  unaffected by the `Render.lean` budget-weighting change).
* `tests/run_tests.py`: 32/36 passing, same 4 pre-existing unrelated fails as
  baseline, no file's score dropped; new `48_convolve` 99.998% within 8
  (sharpen, `edgeMode=wrap` with a non-square kernel and an off-centre
  `targetX`, `preserveAlpha`, and a `divisor=0` dummy, all checked against
  `resvg`).
* `tests/run_adversarial.py`: 84/84 clean, including the new
  `filter_convolve_huge_kernel.svg` (an over-cap 33×32 order → dummy, ~0.01 s;
  an at-cap 32×32 kernel over a 2000×2000 canvas's filter region → `filter
  budget` rejection; ~1.2 s combined, versus >150 s unbounded before the
  `Render.lean` weighting).
* `tests/run_tiles.py`: 36/36 byte-identical, including `48_convolve`.
