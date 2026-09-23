# T65 — feTurbulence  (branch `claude/feat-feturbulence`)

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

Target: `filters/feTurbulence` (19 failing). resvg's turbulence is the
reference implementation from the spec (Perlin noise with the spec's LCG
`random`, lattice init, `fTurbulence`, stitchTiles), computed in f64 then
converted. Reproduce it in fixed point to within tolerance: the LCG is
integer already; the gradient vectors and s-curve interpolation need enough
fractional bits (probably 32+) — measure the error. `numOctaves` capped (usvg
behaviour for large values; also cap for cost). Colour space as T51 does.

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

## What was implemented

`feTurbulence`, all in `LeanSvg/Filter/Turbulence.lean`, a port of resvg
0.48.1's `filter/turbulence.rs` + `apply_turbulence` + usvg's
`convert_turbulence`:

* **Parsing** (usvg): `baseFrequency` as a `Vec<f32>` of one or two numbers,
  both reset to `0` if either is negative (or the list is malformed);
  `numOctaves` rounded half away from zero, negative → 0; `seed` truncated to
  `i32` (saturating); `stitchTiles="stitch"`; `type="fractalNoise"`, anything
  else is `turbulence`.
* **Set-up**, exact: the Park–Miller `random` with Rust's truncating `/`/`%`,
  the seed normalisation (including the `i32` wrap of `-i32::MIN`), the
  lattice shuffle, and unit gradients rounded to 2^-24. A `0/0` gradient
  (both raw components zero) is NaN in resvg; it is tracked and a channel that
  touches it comes out 0, as `f32_bound` makes a NaN.
* **Stitching**: the adjusted frequency, `width` and per-pixel `wrap` are
  computed with every `f64` operation rounded as binary64 (`r64`), because the
  wrap points are discontinuous. `i32` wrapping of `width *= 2` and
  `2·wrap − 4096` is kept.
* **Coordinates**: `((x + region.x − ts.tx) / sx) · f · 2^k` is an exact
  rational per column/row and octave, giving the lattice indices (with resvg's
  `t as i32` saturation, wrapping `+ 1`, and the fraction going to 0 past
  `2^52`), `r0` and `s_curve(r0)` at 2^-24. All of this is precomputed per
  axis, O((w + h) · octaves).
* **Per pixel**: the dot products and the three lerps for all four channels in
  `Int64` at 2^-24. Every factor stays below 2^31, so nothing overflows.
  Octave sums are exact (`noise · 2^(K−k)`), and the output is
  `round-half-up(clamp(255·n))` (turbulence) or `(255·n + 255)/2`
  (fractalNoise), then premultiplied (`multiply_alpha`). The result is in the
  primitive's colour space, as in resvg, and the region origin comes from
  `SourceGraphic`'s region.
* **Bounds**: `numOctaves` is capped at 16. Octave `k` adds at most
  `180/2^k` levels, so the cap changes the output by < 0.006 levels. Each
  turbulence primitive counts `1 + octaves` units in `Render`'s filter-work
  budget (`Filter.Prim.cost`, a one-line change in `Render.lean`), because an
  octave costs about as much as ten ordinary passes.

Measured error: against a Python f64 port of resvg's code (64×64, 3 octaves,
both types), the premultiplied output matches exactly on 4095/4096
(turbulence) and 4089/4096 (fractalNoise) pixels, off by 1 otherwise. The
fractal misses are exact 127.5 ties at lattice points, where the noise is about
1e-8 and its sign is below 2^-24. The remaining differences in the corpus come
from the shared un/premultiply half-way cases (e.g. `37·255/74 = 127.5`),
amplified by the linearRGB→sRGB table.

## Skipped, and why

* **`numOctaves` beyond about 60**: resvg's `x·2^k` then passes 2^63, and
  `t − t as i64` stops being a fraction, so its output turns into noise
  saturated to 0/255. Reproducing that needs a soft binary64 for the whole
  noise function. Up to 60 octaves the capped output agrees with resvg (99.99%
  within 8 at 300×300, the same as at 16 octaves).
* **Fractal 127.5 ties** at exact lattice points, described above: ±1 level.

## Report

Baseline commit `1ba4c27`. `run_corpora.py --fast --corpus resvg --route direct` (width 100):

| dir | files | pass before | pass after | mean within-8 before | after |
|---|---|---|---|---|---|
| filters/feTurbulence | 19 | 0 | 19 | 66.66% | 99.99% |

At natural size (`--width` omitted), all 19 pass too (worst within-8:
`complex-transform` 99.89%, where the missing pixels are on the skewed region's
edge).
All of `filters/`: 257 → 276 of 397.
Whole suite: **1224 → 1243 of 1679; newly passing 19, newly failing 0**, no
file's within-8 dropped.

Other checks, all on the final tree:

* `lake build`: no errors, no warnings.
* `scripts/check-theorems.sh`: `invariants ok`, `theorems ok`.
* `tests/run_tests.py`: every file's score unchanged; new `44_turbulence`
  99.986% within 8 (PASS); 32/36 (the same four fail as before).
* `tests/run_adversarial.py`: 85/85 clean. New: `filter_turbulence_octaves`
  (`numOctaves=1e9`, `seed=-1e30` on a 9 Mpx layer → `filter budget`, 0.03 s),
  `filter_turbulence_budget` (two 1400² groups at the cap with a 1e30 frequency
  and stitching, just under both budgets, 25 s, the most turbulence one render
  may do).
* `tests/run_tiles.py`: 36/36 byte-identical.
* Timing: about 0.33 s per octave per Mpx; the corpus files take 10–25 ms at
  width 100.
