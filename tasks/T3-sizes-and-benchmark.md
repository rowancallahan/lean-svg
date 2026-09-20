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
