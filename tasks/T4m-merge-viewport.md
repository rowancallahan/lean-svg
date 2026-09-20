# T4m — Merge the viewport branch onto the new rasterizer

## Situation

Branch `t4-viewport` (see `tasks/T4-viewport-tiles.md` Report) adds
`--viewport X Y W H` tile rendering and `tests/run_tiles.py`, and it fixed
tile-border identity by changing the *old* accumulation rasterizer. Since
then `main` replaced `MicroSvg/Raster.lean` entirely (T1: tiny-skia
supersampling port) and changed opacity plumbing (T5). A plain merge
conflicts in `Raster.lean`, `Render.lean`, `DESIGN.md`.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T4m` (branch
`t4m-merge`, created from `main`). Do not commit the merge yourself; leave
the worktree in a clean, built, tested state with the merge staged or
committed on the branch (a commit on the branch is fine; do not touch `main`).

## Steps

1. `git merge t4-viewport`. Resolve:
   - `MicroSvg/Raster.lean`: take **main's version unchanged** (`git checkout
     --ours`). T4's `Rect`/`accumEdge`/`accumPiece` changes belong to the old
     rasterizer and must not be resurrected.
   - `MicroSvg/Render.lean`: keep T4's `Options.viewport`, the tile size and
     `translate(−X·256, −Y·256)` composition in `canvasSetup`, but call
     main's `Raster.rasterize W H dev evenOdd` (no document-rectangle
     argument), and keep main's `opacityToU8` calls from T5 in `drawShape`.
   - `Main.lean`: T4's version (viewport parsing, usage text).
   - `DESIGN.md`: keep main's §3.5 (T1's description); add T4's §3.8
     viewport section. `README.md`, `Makefile`: T4's additions.
2. `lake build` clean. `python3 tests/run_tests.py` must reproduce main's
   current table exactly (15/20, same metrics; compare against a render of
   the corpus from main's binary at `/Users/rowancallahan/pdf_renderer/.lake/build/bin/microsvg`
   by sha256 of the PNGs, all must be identical).
3. `python3 tests/run_tiles.py`. Expected: byte-identical stitching, because
   the new rasterizer's edge setup rounds relative to whole-pixel mask
   origins (`top = (y0+32)>>6`, `x = (x0 + ...) << 10` shift by exact
   multiples when the origin moves by whole pixels) and clamps out-of-mask
   sub-columns rather than re-interpolating. If it is **not** identical,
   find the mask-origin dependence in `mkEdge`/`blitSpan`/`rasterize` and
   fix it minimally in `Raster.lean`, keeping the no-viewport corpus
   byte-identical (re-check the sha256s) and explaining the cause.
4. `python3 tests/run_adversarial.py` clean. Re-time the three 512×512 tiles
   at `--width 4000` from T4's report and note the numbers.
5. Append `## Report` here: conflicts and how resolved, tile identity
   result, timings, sha256 check result.
