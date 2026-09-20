# T4 — Viewport (tile) rendering

## Goal

Make the renderer usable as the backend of a zoomable viewer: render only a
rectangular window of the zoomed document. A viewer then renders visible
tiles and caches them; nothing else changes.

Work ONLY in the worktree `/Users/rowancallahan/pdf_renderer/.worktrees/T4`
(branch `t4-viewport`).

## CLI

```
microsvg in.svg out.png --width 4000 --viewport X Y W H
```

- `--width N` (or `--zoom Z`) fixes the zoom exactly as today: the *virtual*
  full image is `N` pixels wide.
- `--viewport X Y W H` (integers, output-pixel coordinates in that virtual
  image; `X`, `Y` may be negative or beyond the image, `W`, `H` ≥ 1) makes
  the output exactly `W × H` pixels showing that window. Pixels outside the
  document are transparent (or the `--background` colour).
- Without `--viewport` behaviour is unchanged, byte for byte. Verify by
  rendering the whole corpus before and after and comparing file hashes.

## Implementation

- `Options` gets `viewport : Option (Int × Int × Nat × Nat)`.
- `Render.canvasSetup` returns the tile size `(W, H)` as the canvas size and
  composes `Mat.translate (−X·256) (−Y·256)` *after* the zoom matrix
  (i.e. `translate.mul (scale.mul vbMat)`), so document geometry lands in
  tile coordinates. The caps `maxDim`/`maxPixels` apply to the tile, not the
  virtual image. Note that the 16.16 matrix clamps the linear part at 4096×
  (`Mat.linMax`); document this as the maximum zoom in the task report and in
  `--help`/usage text.
- `Main.lean`: parse the four integers (negative allowed for X, Y).
- Everything must satisfy `tasks/README.md`.

## Tests

Add `tests/run_tiles.py`:
1. For each corpus file: render the full image at `--width 800` and render
   the four quadrant tiles (`--viewport 0 0 400 H/2`, etc., computing `H`
   from the full render's size; handle odd heights) with the same `--width`.
   Stitch the tiles with numpy and assert they are **byte-identical** to the
   full render. This must hold exactly (same fixed-point math, same
   coverage); if it does not, find out why and fix it (likely: the mask
   bounding box or edge clipping depends on canvas bounds in a way that
   changes coverage at tile borders; the accumulation must be identical for
   interior pixels regardless of clipping).
2. Render one off-document tile (`--viewport -100 -100 50 50`) and assert it
   is fully transparent; one partially overlapping tile and assert the
   overlap region equals the corresponding crop of the full render.
3. Timing: for `12_badge`, `16_stress_2000` and `18_rose_lissajous`, time a
   `512×512` tile at `--width 4000` (median of 5) and report ms. This is the
   "interactive tile" number.

## Done when

`lake build` clean, `python3 tests/run_tests.py` unchanged from baseline,
`python3 tests/run_tiles.py` passes, adversarial 28/28. Append `## Report`
with the tile timings and any fix you needed for tile-border identity.
Do not commit.
