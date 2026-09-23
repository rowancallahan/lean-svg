# T66 — lighting filters  (branch `claude/feat-lighting`)

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

Target: `feDiffuseLighting` (22), `feSpecularLighting` (8), `feDistantLight`
(4), `fePointLight` (4), `feSpotLight` (12) — ~50 files. resvg's
`filter/lighting.rs`: surface normals via the spec's Sobel kernels (edge and
interior cases), `surfaceScale`, `diffuseConstant`, `specularConstant`/
`specularExponent` (pow — needs a fixed-point pow; check the exponent range
usvg clamps to), `lighting-color`, light source vectors in the primitive's
user space (transform them as resvg does), spot `limitingConeAngle` and
`specularExponent`. Needs normalised vectors and dot products in fixed point
with an integer sqrt. Both lighting primitives in one file
`LeanSvg/Filter/Lighting.lean`.

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

## Spec implemented

* **Parsing** (usvg `convert_diffuse_lighting` / `convert_specular_lighting` /
  `convert_light_source` / `convert_lighting_color`): `surfaceScale`,
  `diffuseConstant`, `specularConstant` (default 1) and `specularExponent`
  (default 1) as `f32`. A `specularExponent` outside `[1, 128]` or no light
  source child makes the primitive usvg's dummy: a transparent-black flood.
  The light is the first `feDistantLight`/`fePointLight`/`feSpotLight` child.
  Title, desc, comments and invalid children are skipped. A spot light's
  `specularExponent` that is not positive becomes 1. `limitingConeAngle` is
  optional. `lighting-color`: attribute or `style`. `currentColor` takes the
  inherited `color` (black when there is none). An unparsable or absent value
  is white. Alpha is dropped. Light coordinates are raw user units; usvg does
  not scale them by `primitiveUnits`.
* **Light transform** (resvg `transform_light_source`): x/y go through the
  user→layer matrix (tiny-skia `map_points` order), then relative to the
  filter region origin. z is multiplied by `√(sx² + sy²)/√2`.
* **Pixels** (resvg `lighting.rs`): the spec's Sobel normals with the nine
  edge/interior cases (written as one formula: missing rows/columns drop out,
  with factors 2/3, 1/3, 1/2 and 1/4). The distant-light vector is fixed.
  Point and spot vectors are computed per pixel from `a/255·surfaceScale`,
  and `normalized().unwrap_or(v)`. Diffuse is `kd·N·L/|N|`. Specular uses
  the halfway vector and `powf` unless the exponent is within 4 ulps of 1.
  A negative base with an integral exponent gives a signed power; with a
  non-integral one it is NaN, which becomes 0. Spot colour: black when
  `-L·S ≤ 0` or outside the cone (`cos(angle.to_radians())`), otherwise
  scaled by `(-L·S)^specularExponent`. Each channel is
  `(bound(0, c·f, 255) + 0.5) as u8`. Diffuse alpha is 255; specular alpha is
  max(r, g, b). Input smaller than 3×3 gives transparent black. Only the
  input's alpha is read, and the result is tagged with the primitive's colour
  space.
* **Arithmetic.** Everything runs on the exact binary32 emulation `F32`, in
  resvg's operation order. `sin`/`cos` use `Filter.sinCosF32`, passed in by
  `FilterApply`, because `Filter.lean` imports this file. `sqrt` is a new
  scalar `sqrtF`: the same correctly-rounded result as `F32.sqrt` (checked on
  200k inputs) with a 51-bit instead of a 76-bit radicand. `powf` works in
  two stages:
  * `powFast` computes on a 2^-44 grid. It uses a 256-entry ln table, a
    90-entry exp table and short series, and every product stays below 2^63,
    so there is no GMP. It carries an explicit error bound.
  * When the result is within that bound of an f32 rounding tie, `powExact`
    runs instead (2^-80 series, rounded once). That happens in about 0.1% of
    typical calls.

  On 120k random inputs across three regimes, every certified fast result
  equals `powExact`. Exact fallbacks are capped at `exactBudget` (16384) per
  primitive. Past the cap the uncertified fast value is used; it was within
  one f32 step of exact in every sampled case. Only huge spot exponents with
  a base within ~1e-6 of 1 get there.
* **Work bounds.** One pass over the input with constant work per pixel.
  Per-primitive tables (coordinates, `a/255·ss`, normal components per edge
  class) cost about 12k F32 operations each. The adversarial case
  `tests/adversarial/filter_lighting_huge.svg` is a 4 Mpx specular spot light
  where every pixel runs two non-integral `powf`s, one of them with base near
  1 and exponent 1.2e6. It takes 13 s and matches resvg byte for byte. At
  16 Mpx, the largest layer `maxFilterPixels` allows, it took about 50 s.
  Measured per-pixel cost: diffuse distant 1.2 µs, point 1.9 µs, spot with
  exponent 2.6 µs, specular point 2.7 µs. The remaining time is almost all in
  the shared `F32.norm`/`F32.bitLen`.

Code: `LeanSvg/Filter/Lighting.lean` (new), plus the one-line hooks:
* `Kind.lighting`, the `convertPrim` clause, the removal from
  `isKnownUnsupported` and the addition to `isPrimitive` (all in
  `Filter.lean`);
* the `runPrim` case in `FilterApply.lean`. The filter region origin comes
  from `(inp .source).rx/ry`, so `runPrim`'s signature is unchanged.

## Skipped, and why

* **`lighting-color="inherit"`** is read as absent (white). svgtree would copy
  the parent `<filter>`'s value, which `RawPrim` does not carry (the one
  corpus file has no parent value and passes). Supporting it means one more
  `RawPrim` field in `scan`, which is shared code.
* **Specular in linearRGB** differs from resvg by up to 4 levels on about 0.1%
  of pixels. That comes from the shared premultiplied linear→sRGB conversion
  (T51's integer `unpremul`/`premul` against resvg's f32 on exact half-way
  pairs). Specular's `a = max(r, g, b)` output hits those pairs more often.
  With identical input alpha, every other probe (diffuse/specular × three
  lights × both colour spaces) is byte-identical to resvg.
* **Tiles:** a filter region that crosses the document edge paints outside
  the document in a partly-off-document viewport tile. This is pre-existing
  and a plain `feFlood` reproduces it, so it is not lighting-specific.
  `tests/svg/35_lighting.svg` therefore uses bounding-box filter regions.

## Report

Baseline commit `1ba4c27`. `run_corpora.py --fast --corpus resvg
--route direct` (width 100), before → after:

| dir | files | pass before | pass after | mean within-8 before | after |
|---|---|---|---|---|---|
| filters/feDiffuseLighting | 22 | 0 | 22 | 11.85% | 99.99% |
| filters/feSpecularLighting | 8 | 0 | 8 | 23.20% | 99.95% |
| filters/feDistantLight | 4 | 0 | 4 | 7.84% | 100.00% |
| filters/fePointLight | 4 | 0 | 4 | 16.54% | 100.00% |
| filters/feSpotLight | 12 | 0 | 12 | 10.74% | 100.00% |

Target directories: 0 → 50 of 50 passing. At natural size (200 px) all 50
pass as well: mean within-8 99.997%, mean exact 99.26%, slowest file 0.19 s.
Whole suite: **1224 → 1274 of 1679; newly passing 50, newly failing 0.**

Other checks, all on the final commit:

* `lake build`: no errors, no warnings.
* `scripts/check-theorems.sh`: `invariants ok`, `theorems ok`.
* `tests/run_tests.py`: every existing file's score unchanged. The new
  `35_lighting` is 99.88% exact and 100% within 8 (PASS). 32/36 pass; the
  same four fail as before.
* `tests/run_adversarial.py`: 84/84 clean, including the new
  `filter_lighting_huge` (13 s).
* `tests/run_tiles.py`: 36/36 byte-identical, including `35_lighting`.
