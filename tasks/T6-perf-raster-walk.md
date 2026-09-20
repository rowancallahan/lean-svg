# T6 — Rasterizer speed: sorted edge walk for normal shapes

## Goal

`Raster.rasterize` (T1's port) bins every active edge into a winding-delta
array and prefix-sums it on **every sub-scanline**, which is O(16 × bbox
pixels) per shape. tiny-skia instead walks the active edges sorted by x, which
is O(active edges) per sub-scanline plus O(covered pixels) for the blit. T1
avoided the sort only because `huge_path.svg` has ~2·10⁶ simultaneously
active edges. Do both: sorted walk when the active count is small, binned
prefix sum otherwise.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T6` (branch `t6-raster-walk`).
Only `MicroSvg/Raster.lean` may change.

## What to change

- Keep the active-edge array. On each sub-scanline, if `active.size ≤ 64`
  (tune; report the threshold you chose and why), insertion-sort the active
  edges by current `x` (bounded: at most `active.size²` steps, each a `for`)
  and emit spans exactly as `walk_edges` does: accumulate winding in edge
  order, emit `[left, xcol)` when the winding returns to outside. Otherwise
  keep the current binned path unchanged.
- Consider also bounding the binned path's prefix-sum to
  `[min sub-column, max sub-column]` of the active edges on that sub-scanline.
- Do not change `Mask`, `blitSpan` semantics, or the alpha→cov mapping.
- Invariants in `tasks/README.md` apply. No `partial`.

## Measure

Baseline first (build main as-is in the worktree): render every
`tests/svg/*.svg` at natural size and at `--width 1600` into a temp dir and
record sha256 of each PNG; record `python3 tests/run_tests.py` table and
`python3 tests/run_sizes.py --widths 400,1600 --runs 3 --filter _` net ms.
After: same. Report per file: ms before/after at 200-ish and 1600, and whether
the PNG bytes are identical. If bytes differ, `within%` and `exact%` must not
decrease for any file (the sorted walk is closer to tiny-skia, so a small
*increase* is expected on files with abutting spans; explain any change).
`python3 tests/run_adversarial.py` must stay clean and `huge_path.svg` must
not get slower than before by more than 10%.

Finally confirm `git diff --stat main -- MicroSvg/Effect.lean` is empty and
`lake env lean` on a scratch file with `#print axioms MicroSvg.Prog.renderProgram_spec`
still prints only `propext`.

## Done when

Corpus median speedup reported, no fidelity regression, adversarial clean.
Append `## Report`. Do not commit.
