# T7 — Blend speed: runs and fast paths in `Canvas.fillMask`

## Goal

T3 measured the per-pixel blend in `Canvas.fillMask` at ~94 ms per megapixel
per covering shape, the dominant cost at every large size (overdraw
multiplies it). Make it several times faster with **byte-identical output**.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T7` (branch `t7-blend`).
Only `MicroSvg/Canvas.lean` may change (`fillMask` and helpers it needs).

## What to change (in order of expected payoff; measure each)

1. **Opaque full-coverage fast path.** When `a8 == 255` and `cov8 == 255`,
   `blendLerp` returns exactly the packed source (`div255(x·255) = x`), so
   write a precomputed packed `Nat` directly, no arithmetic.
2. **Run skipping.** Iterate each mask row as runs: skip runs of `cov == 0`
   without touching `px`; handle runs of `cov == 65536` with the fast path.
   Reading `m.cov` once per pixel is fine; the win is not doing the blend.
3. **Hoist per-row work**: `row + m.x0` computed once per row; avoid recomputing
   `cov8` for the two constant cases.
4. If still hot, check whether `px.setIfInBounds` / `getD` are the cost by
   comparing against a version that uses `Array.uset`/`uget` with proofs
   (`i.toNat < px.size` derived from `idx < w*h` and `px.size = w*h`; you may
   need to carry `hsize : px.size = w * h` as a structure field or a hypothesis
   parameter). Only adopt it if it is a measurable win and stays panic-free.

Invariants in `tasks/README.md` apply.

## Measure

Baseline: build main as-is in the worktree; render the whole corpus at natural
size and `--width 1600` to a temp dir, sha256 each PNG; run
`python3 tests/run_sizes.py --widths 400,1600 --runs 3` and keep the net ms.
After each step: bytes must be identical for every file (assert it in a small
script and paste the result); report ms before/after per file at 1600 and the
median speedup. Adversarial must stay clean. Confirm `Effect.lean` is untouched
(`git diff --stat main -- MicroSvg/Effect.lean` empty).

## Done when

Byte-identical corpus, measurable speedup reported per step. Append
`## Report`. Do not commit.

## Report

### What changed

**`MicroSvg/Canvas.lean` only** (66 insertions, 14 deletions; `git diff --stat
HEAD` lists no other file). `toRgbaBytes` and `new` are untouched, as are
`div255`, `premul`, `unpremul`, `pack`, `blendLerp` and `blendOver` — the
arithmetic T2 pinned down is byte-for-byte the same code. The edit is confined
to `fillMask` plus two new constants it branches on:

* `covNone = 128`, `covFull = 65408`, with the derivation in a doc comment.
  `fillMask` maps the mask's `cov ∈ [0, 65536]` to tiny-skia's 0..255 coverage
  with `cov8 = (cov·255 + 32768) >>> 16`; `cov8 = 0 ↔ cov ≤ 128` and
  `cov8 = 255 ↔ cov ≥ 65408`. Both equivalences were checked over all 65537
  values of `cov`, so testing `cov` against the constants selects *exactly* the
  pixels the two degenerate cases apply to, and `cov8` is only computed on the
  pixels that actually need the general blend.
* `solid = blendLerp 0 sr sg sb 255`, hoisted out of the loop. At `cov8 = 255`
  the lerp's `inv` is `0`, so the destination drops out and the result is the
  same constant for every fully covered pixel under an opaque paint. It is
  *defined* as the general-path expression rather than as a hand-derived packed
  value, so the fast path cannot drift from the slow one.
* `fr fg fb fa = div255 (s·255)`, the `scale_1_float` stage at `cov8 = 255`,
  also hoisted, for the translucent full-coverage case.
* Per row, `prow = (m.y0 + y)·w + m.x0` and `mrow = y·m.w` are computed once
  instead of `row + m.x0 + x` and `y * m.w + x` per pixel.

The loop now classifies each pixel before touching the canvas: `cov ≤ covNone`
skips with no read or write; `cov ≥ covFull` writes `solid` with no read and no
arithmetic (opaque) or runs `source_over` against the hoisted source
(translucent); everything else takes the unchanged general blend.

Invariants hold: no `partial` / `unsafe` / `@[extern]` / `panic!` / `!`-indexing,
no `Float`, all arithmetic in `Nat`, every loop a `for` over a finite range.
`lake build` from clean on this file: no errors, no warnings. Not committed.
`tests/out/` was written only by the harnesses themselves (it is gitignored).

### How the measurements were taken

Two harnesses, because the difference-of-large-numbers approach the first
attempt used turned out to be swamped by machine drift (it reported the
*unchanged* rasteriser at 217 and 242 ms/Mpx in two consecutive runs).

* **`fillMask` in isolation, paired.** `fill-opacity="0"` makes `fillMask`
  return on its first line (`a8 == 0`) while `drawShape` still flattens,
  rasterizes and allocates the mask. So *(shape painted) − (same shape,
  `fill-opacity="0"`)* is exactly `fillMask`'s cost. Both members of a pair are
  timed back to back inside one repetition and the **difference** is what gets
  aggregated (median of 9 paired reps, 4 shapes per case, width 1600), so drift
  cancels instead of landing in the result.
* **Corpus, paired A/B.** Two saved binaries render the same file back to back
  in each repetition; per-file median of the net times (median minus that
  binary's own measured 1×1 process-start cost).

For scale: one full-canvas shape costs **~218 ms/Mpx in `Raster.rasterize` plus
mask allocation**, unchanged by this task and now the dominant term.

### Per step

`ms per Mpx of mask bbox, per covering shape` — paired probe, width 1600:

| variant | opaque, full coverage | translucent, full coverage | empty mask (full bbox, no coverage) |
|---|---|---|---|
| baseline | 262.5 | 264.1 | 3.5 |
| **steps 1 + 3 (adopted)** | **5.4** | **262.7** | **2.5** |
| step 2, explicit runs (rejected) | 5.5 | 258.2 | 2.1 |
| extra, `dst == 0` shortcut (rejected) | 6.4 | 288.4 | 2.7 |

**Step 1 — opaque full-coverage fast path: 262.5 → 5.4 ms/Mpx, ~49× on that
stage.** This is the whole win. What remains (5.4 ms/Mpx ≈ 5.4 ns/pixel) is one
bounds-checked `cov` read, two comparisons and one store.

**Step 3 — hoisting.** Implemented in the same edit as step 1, but its
contribution is separable. The "empty mask" column is pure loop overhead with no
blending at all: **3.5 → 2.5 ms/Mpx (−29 %)**, which is the per-row index
hoisting and not recomputing `cov8` for the skipped pixels. Hoisting the
coverage scaling out of the translucent path is worth only 264.1 → 262.7, i.e.
nothing: `blendOver` itself, not the source scaling, is that path's cost.

**Step 2 — run skipping: implemented, measured, reverted.** A version that scans
each row into runs (empty runs skipped wholesale, fully covered opaque runs
filled by a tight inner `for`) is **within run-to-run spread of the flat loop on
every case** (5.5 vs 5.4, 258.2 vs 262.7, 2.1 vs 2.5). The reason is structural:
`Raster.Mask.cov` is a *dense* array, so finding a run's end costs exactly one
`getD` and one comparison per pixel — the same per-pixel work the flat loop
already does — and a fully covered run then needs a second pass to fill it. Runs
would pay only if the mask arrived already run-length encoded, and `Raster.lean`
is out of scope here. The ~25 extra lines bought nothing, so the flat
classify-per-pixel loop is what shipped. (Saved at
`scratchpad/Canvas_stepB_runs.lean` if it is wanted for the T6 rewrite, where
producing RLE spans directly *would* make it pay.)

**Step 4 — `uget`/`uset`: declined, with a measured ceiling.** Two reasons.
(a) It is blocked by this task's coordination constraint: the proof route the
task sketches wants `hsize : px.size = w * h` as a `Canvas` field, which changes
`Canvas` and therefore `new` — explicitly another agent's file right now. The
alternative, re-deriving `idx < px.size` inside the loop, needs `y < m.h` and
`x < m.w` as propositions out of `Std.Range.forIn` *and* a loop invariant
re-establishing `px.size` after each `uset`, which `for ... do` with a `mut`
binding does not carry. (b) It cannot matter enough to be worth that: the empty-
mask column measures one bounds-checked `Array.getD` plus a comparison plus loop
overhead at **2.5 ms/Mpx total**, and the heaviest path uses three array
accesses per pixel — so *removing every bounds check in `fillMask`* is bounded
above by roughly 7 ms/Mpx against the ~218 ms/Mpx a covering shape costs, i.e.
≲3 %, and the check itself is only a fraction of that 2.5. Not a measurable win.

**Extra, not in the task — transparent-destination shortcut: tried, reverted.**
`dst == 0` makes every `d·inv` term vanish, so both blends collapse to the
scaled source; a shape drawn over untouched canvas hits it on every pixel. On
the corpus it came out at **1.00× (22443 → 22372 ms total, paired, 3 reps)**,
with three files measurably *worse* (`08_group_inherit` 0.94×, `19_sierpinski`
0.95×, `18_rose_lissajous` 0.97×) and translucent overdraw worse in the probe
(262.7 → 288.4 ms/Mpx), because the extra test is paid on every pixel that
misses. Reverted in favour of the simpler code.

### Corpus numbers

**Paired A/B, `ours` net ms, median of 3 reps at width 1600 / 5 reps at 400:**

| file | 1600 before | 1600 after | speedup | 400 before | 400 after | speedup |
|---|---|---|---|---|---|---|
| 01_triangle | 569.2 | 265.5 | 2.14× | 32.1 | 15.9 | 2.02× |
| 02_rect_circle | 736.3 | 344.7 | 2.14× | 39.6 | 19.6 | 2.02× |
| 03_curves | 841.7 | 413.9 | 2.03× | 47.2 | 23.8 | 1.99× |
| 04_stroke | 507.3 | 357.9 | 1.42× | 29.1 | 21.1 | 1.38× |
| 05_transform | 310.1 | 151.5 | 2.05× | 17.8 | 9.3 | 1.92× |
| 06_evenodd | 745.1 | 592.9 | 1.26× | 42.1 | 34.9 | 1.21× |
| 07_opacity | 1136.2 | 923.3 | 1.23× | 63.0 | 52.9 | 1.19× |
| 08_group_inherit | 633.9 | 382.4 | 1.66× | 36.1 | 22.5 | 1.61× |
| 09_viewbox | 1046.1 | 475.1 | 2.20× | 58.5 | 27.2 | 2.15× |
| 10_polygon_star | 1051.7 | 749.8 | 1.40× | 59.7 | 45.3 | 1.32× |
| 11_style_attr | 963.8 | 694.1 | 1.39× | 55.4 | 39.9 | 1.39× |
| 12_badge | 3518.4 | 2196.8 | 1.60× | 199.1 | 124.6 | 1.60× |
| 13_gear_evenodd | 1302.7 | 916.7 | 1.42× | 77.4 | 57.1 | 1.35× |
| 14_flower_transforms | 2937.4 | 2109.0 | 1.39× | 165.4 | 125.0 | 1.32× |
| 15_spiral_stroke | 3162.4 | 2273.3 | 1.39× | 194.6 | 144.7 | 1.34× |
| 16_stress_2000 | 6698.4 | 5100.4 | 1.31× | 491.3 | 423.4 | 1.16× |
| 17_koch_snowflake | 2185.7 | 1306.7 | 1.67× | 141.7 | 91.2 | 1.55× |
| 18_rose_lissajous | 2989.0 | 2245.4 | 1.33× | 234.2 | 192.7 | 1.22× |
| 19_sierpinski | 1685.5 | 968.6 | 1.74× | 115.9 | 73.5 | 1.58× |
| 20_function_plot | 1535.0 | 996.9 | 1.54× | 114.2 | 79.0 | 1.45× |
| **TOTAL** | **34555.9** | **23464.9** | **1.47×** | **2214.4** | **1623.5** | **1.36×** |

**Median per-file speedup: 1.42× at width 1600, 1.42× at width 400.**

**`python3 tests/run_sizes.py --widths 400,1600 --runs 3`**, the command the task
names, run once before and once after (unpaired, and it interleaves resvg, so it
is noisier and reads a little low):

| width | mean net before | mean net after | mean ms/Mpx before → after | total | median speedup |
|---|---|---|---|---|---|
| 400 | 133.6 ms | 101.7 ms | 857.5 → 650.5 | 2672.5 → 2034.4 (1.31×) | 1.35× |
| 1600 | 1877.5 ms | 1389.8 ms | 752.9 → 555.6 | 37549.4 → 27797.0 (1.35×) | 1.37× |

Fidelity columns are unchanged to the last digit, as they must be: mean `exact%`
97.384 / 98.330 and mean `within8%` 99.366 / 99.733 at 400 / 1600, before and
after. The slowest-cell list changed only by `12_badge` dropping out of the top
three (3765 → 2311 ms at 1600).

### How much of the render is still the blend

A build with `fillMask`'s body short-circuited to `return cv` renders the whole
corpus at 1600 in **24.1 s** under the unpaired harness, against **25.9 s** for
the shipped build. So the entire blend stage is now **~1.8 s, about 7 % of
render time**; before this task the same floor implies roughly 12.9 s, about
37 %. The corpus speedup is 1.47× rather than ~2.5× because what is left is
almost entirely `Raster.rasterize` — ~218 ms/Mpx per covering shape for the
supersampling walk T1 introduced, which is T6's subject. **There is at most
7 % more to be had inside `fillMask`, and the remaining blend cost is
concentrated in translucent paints** (`blendOver` at ~263 ms/Mpx on fully
covered pixels, untouched by this task: it genuinely needs the destination, so
only cheaper arithmetic would help it — a 256-entry `div255 (d·inv)` table, or
dropping to `UInt64` lanes, which invariant 4 currently steers away from).

### Byte identity

**100 renders, 0 sha256 mismatches.** All 20 corpus files under five option
sets, baseline binary versus final binary:

| variant | what it exercises |
|---|---|
| natural size | default geometry, transparent canvas (`dst == 0` everywhere) |
| `--width 400` | different mask geometry and coverage distribution |
| `--width 1600` | as the task specifies |
| `--width 800 --background #ffffff` | **non-zero destination** — the blend runs against real `dst` |
| `--width 800 --background #203040` | ditto, different channel values |

The two background variants were added on purpose: with a transparent canvas the
full-coverage fast path writes over `dst = 0` and a mistake in the constant could
hide, whereas over a filled background the fast path has to reproduce a blend
that actually depends on the destination. Script:
`scratchpad/shas2.py <binA> <binB>`; output `100 renders compared (5 variants x
20 files) / baseline vs final: 0 sha256 mismatches / BYTE-IDENTICAL`.

`python3 tests/run_tests.py`: **15/20 passed, 5 failed, 0 render errors** — the
same as before, necessarily, since it renders at natural size and those bytes
are identical.

### Adversarial

`python3 tests/run_adversarial.py`: **37/37 cases clean, 0 with violations**,
before and after. (The task text says 28/28; the generated suite is 37 cases, as
T2's report also noted.)

### Effect.lean

`git diff --stat main -- MicroSvg/Effect.lean` is **empty**, and so is
`git diff --stat HEAD -- MicroSvg/Effect.lean`. Untouched.
