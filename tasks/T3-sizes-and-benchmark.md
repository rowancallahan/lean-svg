# T3 — Fidelity and speed across render sizes

## Goal

Answer two questions with numbers: (1) does agreement with resvg improve at
larger render sizes (edge pixels become a smaller fraction), and (2) how does
our render time scale with output size, in absolute ms and in ms per
megapixel, compared with resvg. This feeds the "interactive viewer backend"
question: a viewer needs a 512×512-ish tile in ~15–30 ms.

Python only. Do not change any Lean source. Work in the main tree
(/Users/rowancallahan/pdf_renderer), not in `.worktrees/`.

## Deliverable: `tests/run_sizes.py`

For every `tests/svg/*.svg` and every width in `[100, 200, 400, 800, 1600, 3200]`:

- ours: `.lake/build/bin/microsvg in.svg out.png --width W`
- resvg: `resvg -w W in.svg ref.png`
- If the two outputs differ in size, report it and skip metrics for that cell.
- Metrics as in `tests/run_tests.py` (exact, within 8, within 32, mean abs).
  Reuse its functions by importing from it if that is clean; otherwise copy.
- Timing: median of 3 runs each, wall clock. Also measure the process-start
  baseline once (render a trivial `<svg width="1" height="1"/>`) and report
  `ours_ms − baseline` as "net". Report ms per megapixel for the net time.
- Skip the 3200 width for `16_stress_2000` and `18_rose_lissajous` only if a
  single run exceeds 60 s; say so.

Outputs:
- A table per file: width, size, exact%, within8%, within32%, ours ms (net),
  resvg ms, ratio ours/resvg, ours ms/Mpx.
- A summary table: for each width, mean within8% over all files and mean
  ratio ours/resvg.
- `tests/out/sizes.csv` with every cell, and `tests/out/sizes.md` with the
  tables (Markdown) so it can be pasted into docs.
- Flags: `--widths`, `--filter`, `--runs`.

Write into your report: the three slowest (file, width) cells and, from
reading `MicroSvg/Raster.lean`, `MicroSvg/Canvas.lean` and
`MicroSvg/Render.lean` (read only), your best diagnosis of where the time
goes at large sizes (per-shape mask allocation `Array.replicate` over the
bbox, per-pixel `fillMask` loop, edge accumulation, PNG encoding of
uncompressed rows, `toRgbaBytes`). Rank the likely wins. Do not implement
them.

## Done when

`python3 tests/run_sizes.py` runs end to end and `tests/out/sizes.md` exists.
Append your `## Report` with the summary table, the slowest cells, and the
diagnosis.

## Report

### What changed

- **Added `tests/run_sizes.py`** (the only file added). Imports `run_renderer`,
  `load_rgba`, `compare`, `SVG_DIR`, `OUT_DIR`, `DEFAULT_BIN` and
  `RENDER_TIMEOUT` from `tests/run_tests.py`, so the metrics are the same ones
  the oracle harness reports. Flags: `--widths`, `--filter`, `--runs`, `--bin`.
  Renders go to a `tempfile.TemporaryDirectory` (a 3200-wide uncompressed PNG
  is ~41 MB); only `sizes.csv` and `sizes.md` are written under `tests/out/`.
- **Wrote `tests/out/sizes.csv`** (120 rows) and **`tests/out/sizes.md`**
  (summary, slowest cells, per-file tables). No Lean file was touched, no
  `lake build` was run, `.worktrees/` was not entered, nothing was committed.

Method: median of 3 wall-clock runs per renderer per cell. The process-start
baseline is measured once from a trivial `<svg width="1" height="1"/>` with one
discarded warm-up run and >= 5 samples: **ours 3.6 ms, resvg 2.5 ms**. `net` is
`median - baseline` and is **not** clamped, so a near-zero net at width 100 reads
honestly as "below the noise floor" rather than as a measurement. `ratio` is
`ours net / resvg ms` as specified; `sizes.csv` additionally carries
`ratio_net_net`, which also subtracts resvg's start-up cost.

`python3 tests/run_sizes.py` completed in **305.7 s**: 120 cells, **120 scored,
0 size mismatches, 0 skipped, 0 errors**. The 60 s skip clause for
`16_stress_2000` and `18_rose_lissajous` at width 3200 was never triggered —
the slowest single run in the whole sweep was 16_stress_2000 at 3200, ~14.2 s.

### Summary

| width | files | mean exact% | mean within8% | mean ours net ms | mean resvg ms | mean ratio ours/resvg | mean ours ms/Mpx |
|---|---|---|---|---|---|---|---|
| 100 | 20/20 | 79.029 | 94.179 | 9.4 | 4.5 | 1.7 | 964.5 |
| 200 | 20/20 | 83.700 | 96.765 | 22.6 | 5.4 | 3.6 | 579.3 |
| 400 | 20/20 | 86.535 | 98.526 | 68.6 | 8.1 | 8.2 | 439.8 |
| 800 | 20/20 | 88.062 | 99.252 | 240.6 | 15.3 | 16.6 | 386.0 |
| 1600 | 20/20 | 88.943 | 99.606 | 909.5 | 35.8 | 27.0 | 365.0 |
| 3200 | 20/20 | 89.325 | 99.767 | 3549.7 | 101.7 | 35.2 | 356.3 |

**Q1, does fidelity improve with size: yes, monotonically, for every one of the
20 files.** Mean `within8` climbs 94.18% -> 99.77% from width 100 to 3200 and
mean absolute error roughly halves per doubling — the signature of a fixed
per-edge disagreement whose share shrinks as the edge-to-area ratio falls. The
weakest files at 100 gain the most (`18_rose_lissajous` 75.65 -> 99.56,
`16_stress_2000` 83.12 -> 99.14). `exact%` improves far more slowly (79.0 ->
89.3): interiors converge, but exact byte equality stays limited by blend
rounding, which is size-independent and is T2's subject, not a size effect.

**Q2, how time scales:** our cost is asymptotically **linear in output pixels**.
Every file's ms/Mpx flattens by width 800-1600 (e.g. `01_triangle` 226 -> 175,
`19_sierpinski` 1128 -> 371), converging to a per-file constant of ~175-1390
ms/Mpx, mean 356. resvg's per-pixel cost is roughly an order of magnitude lower
and its small-size numbers are dominated by its own fixed overhead, which is why
the ratio grows 1.7x -> 35x rather than staying flat.

### Three slowest cells

| file | width | size | ours net ms | resvg ms | ratio |
|---|---|---|---|---|---|
| 16_stress_2000 | 3200 | 3200x3200 | 14201.4 | 480.1 | 29.6 |
| 12_badge | 3200 | 3200x3200 | 6613.0 | 102.6 | 64.5 |
| 15_spiral_stroke | 3200 | 3200x3200 | 5672.8 | 104.4 | 54.3 |

### Where the time actually goes (measured, not inferred)

The per-stage split below is measured with synthetic SVGs rendered at width 3200
(10.24 Mpx), differencing cases that isolate one stage at a time. These inputs
live in a scratch directory; they were deliberately not added to `tests/svg/`,
since they are diagnostics, not corpus cases.

| case | net ms | ms/Mpx | isolates |
|---|---|---|---|
| empty canvas, transparent | 566.8 | 55.3 | `Canvas.new` + `toRgbaBytes` + `Png.encode` + file write |
| same, output to `/dev/null` | 592.0 | 57.8 | the file write itself: **~0** |
| empty canvas, `--background #fff` | 648.9 | 63.4 | + unpremultiply branch in `toRgbaBytes`: **+8.0** |
| full-bbox sliver (~zero coverage) | 806.0 | 78.7 | + mask alloc, prefix sum, `fillMask` scan: **+15.3** |
| one full-canvas opaque rect | 1771.5 | 173.0 | + the blend itself: **+94.3** |

So one shape covering the whole canvas costs **117.6 ms/Mpx**, of which **94.3 is
the per-pixel blend** in `Canvas.fillMask` and 15.3 is mask setup. Each further
full-canvas rect adds a near-identical 107-110 ms/Mpx (measured at 1, 2 and 4
rects), i.e. **cost scales with overdraw, `sum(shape bbox area) / canvas area`**.

Another agent's `run_tests.py` run overlapped this first measurement (it
rewrote `tests/out/results.json` mid-way), so the split was re-taken on an idle
machine with 5 runs per point. It reproduces within a few percent: empty canvas
59.8 ms/Mpx, unpremultiply +6.9, mask setup +14.7, blend **+95.0**, second
full-canvas shape +107.9. The 120-cell sweep itself finished before that run
started. Treat the fixed output-path figure as ~55-60 ms/Mpx; the blend and
mask-setup figures are stable to ~1%.

Two hypotheses tested and **rejected**: (a) disk I/O — rendering to `/dev/null`
is the same within noise, so the 41 MB uncompressed PNG costs CPU, not disk;
(b) a per-shape copy of the canvas array (which would happen if `cv.px` were not
uniquely referenced in `fillMask`) — the marginal cost of one extra *tiny* shape
is 16 us at width 800 and ~100-220 us at 3200, not the ~5 ms a 82 MB copy would
take, so Lean is updating the canvas in place.

Cross-check on the worst cell: `16_stress_2000` is 2001 shapes whose device
bounding boxes sum to **9.3 canvases at every width** (95.5 Mpx at 3200). The
constants above predict ~7.4 s against 14.2 s measured — the right order, with
the residual attributable to per-shape allocation overhead (2001 small
`Array.replicate` pairs amortise far worse than one big one) and to the rough
coverage fraction in the estimate. `12_badge` (14 shapes, ~6 canvases of bbox)
and `15_spiral_stroke` (a stroke outline expanded to one quad plus one join
polygon per segment) are the same story with fewer, larger shapes.

### Ranked diagnosis and likely wins (not implemented)

1. **The per-pixel blend in `Canvas.fillMask` — 94 ms/Mpx per covering shape,
   multiplied by overdraw.** The dominant term at every large size. The loop
   does `m.cov.getD`, a 4-way `div255` blend and `px.setIfInBounds` for every
   pixel of every shape's bbox, with no run handling: a fully covered
   (`cov = 65536`) opaque span is still blended pixel by pixel, and `cov = 0`
   pixels still cost a bounds-checked read before `continue`. Span/run-based
   fill, with an opaque-copy fast path and bulk skipping of empty runs, is the
   single biggest lever.
2. **Mask materialisation in `Raster.rasterize` — 15.3 ms/Mpx of bbox, per
   shape, paid even for near-empty shapes.** Two `Array.replicate` allocations
   (`stride*bh` Ints, `bw*bh` Nats) plus a full prefix-sum pass build a `cov`
   array that `fillMask` then reads exactly once. Fusing the prefix sum with the
   blend would delete one whole allocation and one whole pass per shape; keeping
   the `Mask` interface but making `cov` a reused scratch buffer is the smaller,
   less invasive version. Note this interacts with T1, which rewrites this file.
3. **The output path — ~55-63 ms/Mpx, paid once per render.** `toRgbaBytes` does
   four `ByteArray.push` calls per pixel (plus three divisions per pixel once
   alpha > 0, measured at 8 ms/Mpx); `Png.encode` then copies each row via
   `extract` + `++`, `zlibStored` copies the whole 41 MB buffer again in 64 KB
   stored blocks, and `adler32` and `crc32` each fold over every one of those
   41 MB. A single fused pass from packed canvas to filtered PNG rows would
   remove two full copies; real DEFLATE would additionally shrink the bytes the
   two checksums have to walk. Worth doing, but it is a fixed ~15% of a typical
   large render, not the main event.
4. **Edge accumulation — not the problem at large sizes.** `segCount` caps
   subdivision at 100 segments per cubic and `circlePoly` at 64 points, so edge
   count grows only ~sqrt(scale) and then saturates, while pixel work grows with
   scale^2. Its cost is visible only at small sizes, where mean ms/Mpx is 964 at
   width 100 versus 356 at 3200. Optimising it would buy little above width 800.

### Implication for the interactive-viewer question

Measured separately, a 512x512 tile over all 20 corpus files: min **33.3 ms**
(`05_transform`), median **64.7 ms**, mean **104.9 ms**, max **491.9 ms**
(`16_stress_2000`); resvg does the same tiles in 4.3-54.3 ms. **0 of 20 files
meet the 15-30 ms budget**, and the simplest file in the corpus misses it by
itself — the ~55 ms/Mpx fixed output path plus one background fill already
spends ~45 ms on a 0.26 Mpx tile. Items 1-3 above are the prerequisites for a
viewer backend; item 1 alone is worth roughly 2-3x on typical content.
