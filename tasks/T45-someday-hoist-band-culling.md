# T45 — SOMEDAY: hoist per-shape device boxes out of the band loop

**Status: not scheduled.** Do not start this without Rowan asking for it by
name. It is recorded here so the reasoning is not lost, not because it is next.

This is the last known parallelism win. Everything cheaper has been taken
(T41 gradients, T42 flattening, T44 integer compositing). After this there is
nothing left that does not require changing the proof boundary.

## The problem

Each band decides, for every shape, whether that shape touches it, by calling
`Render.shapeOnCanvas` (`LeanSvg/Render.lean:178`) at `Render.lean:243`. That
calls `Geom.ctrlBoxMeets` (`LeanSvg/Geom.lean:377`), which walks every command
of the path and applies the matrix to every control point.

So the cull is proportional to total path geometry, and **every band repeats it
in full**. Its cost per band is fixed: it does not shrink when the band gets
thinner, because a thin band still has to consider all 2001 shapes.

That single fact explains the measured scaling. `tests/svg/stress.svg` at
2000 px, median of 11 interleaved runs, this laptop (M-series, 8 cores):

| bands | 1 | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| ms | 959 | 288 | **274** | 326 | 380 |

Past 4 bands it gets *worse*, by roughly 9 ms per extra band. Paint work per
band keeps shrinking; the cull does not. Note also that 1 band is not a fair
baseline — the jump to 2 is superlinear, so use 2 bands as the reference when
re-measuring.

## The change

Compute each shape's device bounding box **once**, before `Task.spawn` in
`Render.renderBands` (`Render.lean:597`, spawn at `:611`), and pass the array
into each band. Per-band culling then becomes a rectangle-overlap test: four
comparisons, no matrix work, no path walk.

`Geom.ctrlBox` (`Geom.lean:425`) already computes exactly the box needed — it
is the same traversal as `ctrlBoxMeets` without the early exit. The
computation is not the work; the plumbing is.

## Why it is not a small change

1. The box array has to thread through `renderRgba` and `drawShape` down to
   the call site at `Render.lean:243`, which touches several signatures.
2. Bands differ by a viewport translation (`renderBands` sets
   `viewport := some (vx, vy + y0, w, y1 - y0)`), so a shared box is only
   valid after offsetting. That offset is trivial arithmetic but it is the
   part most likely to be got subtly wrong, and getting it wrong silently
   drops shapes near a band seam.
3. `shapeOnCanvas` widens by the stroke reach (`Render.lean:143`). The
   precomputed box must widen identically or thin strokes vanish at edges.

Estimate: 40–60 lines across `Render.lean`, in the hot path. Not the 20-line
fix that was looked for.

## Expected payoff, and the 32-core question

On this laptop: measured hardware ceiling **5.23×** (many fully independent
processes, so no shared state at all), against **3.5×** achieved. The gap is
load imbalance, slowest band over mean = 1.25. Cheap culling makes
over-decomposition viable — many more bands than threads — which averages that
imbalance out. Plausible landing point 4.2–4.4×, so stress at 2000 px goes
from ~274 ms to ~220 ms. Roughly 20%.

**On a 32-core machine the two effects pull opposite ways.** Worth stating
plainly because the intuition can go either way:

- *More valuable.* The cull is a fixed per-band cost, and more cores means
  more bands, so the cull becomes a larger fraction of each band's work.
  This is the effect that already makes 16 bands slower than 4 today. At
  32 bands it dominates. Removing it matters **more**, not less.
- *Less valuable.* The 5.23× ceiling on 8 cores is not core count, it is
  memory bandwidth — rasterising is write-heavy. A 32-core box will hit that
  wall well before 32×. This change does nothing about bandwidth.

Net expectation: it raises the band count at which we peak, and it removes a
penalty that grows with core count, but it does not raise the bandwidth
ceiling. Do not expect linear scaling at 32 cores from this or anything else.

## What this deliberately does not do

Nothing here touches `LeanSvg/Effect.lean` or the effect boundary. Bands stay
`Task.spawn`, which is pure, so the "exactly two effects" guarantee is
unaffected. Processes would require new `Op` constructors and are ruled out.

## Verification

Standard invariants in `tasks/README.md` apply. Additionally:

1. `python3 tests/run_tests.py` — must stay 23/27, and byte-identity at
   natural size and `--width 800` must be unchanged. This is a culling
   change: it must be **bit-identical**, unlike T44. Any pixel difference
   means a shape was wrongly dropped.
2. Explicitly check a shape straddling a band seam, and a hairline stroke on
   a band edge.
3. `python3 tests/run_adversarial.py` — 61/61.
4. Re-run the band sweep above at matched width. Compare against 2 bands,
   not 1.

## Stop rule

If the band sweep after the change does not beat 274 ms at 2000 px by at
least 10%, revert and report. The plumbing cost is only justified by the
scaling improvement.

## Also recorded here: the three-line version

`--threads N` currently makes exactly N bands, and N is often the wrong band
count — stress peaks at 4, confetti at 8–16. Someone passing `--threads 8` on
a shape-heavy file gets 326 ms where 4 bands give 274. Capping band count is
about three lines.

Not done, because there is no defensible rule from two files, and a bad
heuristic would silently slow down cases that are fine today. If T45 is ever
picked up, derive the rule from the sweep it produces rather than guessing.
