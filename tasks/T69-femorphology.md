# T69 — feMorphology  (branch `claude/feat-femorphology`)

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

Target: `filters/feMorphology` (14 failing). resvg `filter/morphology.rs`:
`operator` erode/dilate, `radius` (x, y; zero/negative rules; conversion to
pixels through the primitive units and transform as resvg does). Naive
per-pixel window is O(area·r²): resvg's own cost; cap the radius as resvg
does and make sure T51's budget covers it, or implement the separable
min/max (morphology with a rectangle is separable) for O(area·r). Add an
adversarial case with a huge radius.

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

All new logic lives in `LeanSvg/Filter/Morphology.lean` (imported by
`Filter.lean`); the only touches to `Filter.lean`/`FilterApply.lean` are the
one `import`, the `Kind.morphology` constructor, one `convertPrim` clause,
one `runPrim` case, and removing `"feMorphology"` from `isKnownUnsupported`
(added to `isPrimitive` instead).

* **Parsing (usvg `convert_morphology`).** `operator` (`"dilate"`, else
  `erode`). `radius`: usvg's generic `Vec<f32>` attribute parse is
  all-or-nothing (one unreadable number drops the *whole* list), unlike
  `stdDeviation`'s bespoke partial-tolerant parser that `Filter.stdDevOf`
  already implements — so `radius` gets its own list parser
  (`morphDecList`) rather than reusing it. A list of one number is `rx = ry`;
  two numbers are `rx, ry`; absent, unreadable, empty, or 3+ numbers all fall
  back to the default. The default, and both of usvg's zero-radius quirks,
  are ported exactly: if both values are zero, both become `1`; if only one
  is zero, *only that one* becomes `1` (not in the spec, usvg does it to
  match Chrome/Safari); if either surviving value is negative, *both* values
  revert to the default (`1`), discarding a still-valid other one — usvg's
  `PositiveF32::new(…).unwrap()` on the pre-declared default. The default and
  every parsed value are scaled by `primitiveUnits` on the 16.16 grid, same
  as every other primitive's lengths.
* **Rendering (resvg `filter/morphology.rs` and `apply_morphology`).** The
  radius is scaled by the device transform; if either resulting value is not
  strictly positive (a degenerate transform), resvg clears the whole layer
  rather than passing it through, which `FilterApply`'s new case reproduces.
  Otherwise each device radius is ceiling'd to whole pixels
  (`morphCeil`, an exact-rational ceiling — never rounds a genuinely positive
  product down to `0`, unlike a rounding-to-nearest 16.16 conversion would at
  extreme scales). `columns`/`rows` are `min(2·⌈r⌉, dimension)`, exactly
  resvg's own cap, and the window is resvg's asymmetric
  `[i - target, i - target + win - 1]` (not symmetric around `i` unless the
  window happens to run uncapped). The per-channel min/max runs directly on
  premultiplied bytes, as resvg's `RGBA8` implementation does (no
  demultiply/premultiply round-trip).
* **Complexity.** resvg's own algorithm is a direct 2-D window scan,
  `O(area · r²)`. A rectangle is separable for min/max (the window is a
  product set `X(x) × Y(y)`, each axis clipped to the image independently),
  so this implements it as two 1-D passes — one along rows, one along columns
  — each `O(area · win)`, giving `O(area · r)` total: strictly less work than
  resvg's own algorithm on every input, so nothing that would be tractable
  for the reference renderer becomes intractable here. `columns`/`rows` are
  already capped to the image's own dimensions (resvg's own cap, not an
  additional one), so cost never depends on how large `radius` is written in
  the file, only on the layer size `Render.lean` already bounds.

## Skipped, and why

* **`filters/feMorphology/source-with-opacity`**: fills with a `<pattern>`
  paint server, which is out of scope (patterns are a separate task) and was
  already failing before this change with the identical score
  (`0.7735` within-8 before and after) — not a regression, not something
  `feMorphology` itself touches.

## Report

Baseline commit `1ba4c27`. `run_corpora.py --fast --corpus resvg --route
direct` (width 100), before → after:

| dir | files | pass before | pass after | mean within-8 before | after |
|---|---|---|---|---|---|
| filters/feMorphology | 14 | 0 | 13 | 69.84% | 98.38% |

At natural size (`--width 200`, the corpus files' own viewBox size):
13/14 pass, all at 100.000% within-8 (the 13 non-pattern files are
99.81–100.00% *exact*, i.e. bit-identical to resvg on all but a couple of
antialiasing-seam pixels); `source-with-opacity` is the pre-existing pattern
failure above.

Whole suite (`--fast`, width 100): **1224 → 1237 of 1679 passing; newly
passing 13, newly failing 0.**

Other checks, all on the final commit:

* `lake build`: no errors, no new warnings.
* `scripts/check-theorems.sh`: `theorems ok` (`proofs/SizeBound.lean`
  unaffected).
* `tests/run_tests.py`: 32/36 pass (unchanged 31/35 plus the new
  `45_morphology`, which is 100.000% exact); no existing file's score moved.
* `tests/run_adversarial.py`: 84/84 clean. New input:
  `filter_morphology_huge_radius.svg` (`radius="1e9 1e30"`, dilate, 300×300
  canvas) — 0.77s, well inside the 120s timeout, demonstrating the window cap
  holds regardless of how the radius is written. The three existing filter
  adversarial cases (`filter_huge_stddev`, `filter_huge_region`,
  `filter_budget`) are unaffected (same timings as before this task).
* `tests/run_tiles.py`: 36/36 byte-identical, including the new
  `45_morphology` (an anisotropic `radius="2 10"` dilate straddling the
  quadrant seam).
* Timing: `filters/feMorphology/huge-radius` (`radius="9999"` on a 200×200
  canvas) is 402ms here vs resvg's own 1636ms on the same file — the
  separable implementation is faster than the reference renderer's direct
  scan, not just bounded by it.
