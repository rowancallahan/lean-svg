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

## Report

### What changed

| file | change |
|---|---|
| `MicroSvg/Render.lean` | `Options.viewport : Option (Int × Int × Nat × Nat)`; `canvasSetup` returns the tile size, the tile transform and the document rectangle; `drawShape` passes that rectangle to `rasterize` |
| `MicroSvg/Raster.lean` | `Rect`; `accumPiece` clips to the mask *exactly* instead of taking pre-clipped `Nat` coordinates; `accumEdge` clips to the document rectangle instead of the mask; `rasterize` takes the document rectangle |
| `Main.lean` | `--viewport X Y W H` (`parseIntArg` allows a leading `-`), usage text incl. the 4096× zoom ceiling |
| `tests/run_tiles.py` | new harness (stitching, off-document tile, partial tile, tile timings) |
| `DESIGN.md`, `README.md`, `Makefile` | §3.5 rewritten, new §3.8 "Viewport (tiles)"; CLI example; `make tiles` |

`tests/run_tests.py` and `tests/run_adversarial.py` are untouched.
`MicroSvg/Effect.lean` is untouched — the CLI still builds the same one-read /
one-write `Prog`, so the effect theorems still cover it. No `partial`, no
`unsafe`, no `panic!`, no `!`-indexing, no `Float`; every new loop is a `for`
over a range bounded by the tile (`bh` rows, `bw + 2` columns) or by 2.

### CLI

```
microsvg in.svg out.png --width 4000 --viewport 1744 1744 512 512
```

`X`, `Y` may be negative or past the edge; `W`, `H` ≥ 1. `--width` / `--zoom`
fix the zoom of the *virtual* image exactly as before, and `maxDim` /
`maxPixels` bound the tile, not the virtual image: a 512×512 tile of a
1 000 000 px wide image renders in about 1 s. **Maximum zoom is 4096×**, where
`Mat.linMax` clamps the 16.16 linear part; this is now in the usage text and in
`DESIGN.md` §3.8.

### Byte-identity of the no-viewport path

Every corpus file rendered four ways (default, `--width 800`,
`--width 1600 --background white`, `--zoom 2.5`) with the pre-change binary and
with the final one: **80/80 sha256 hashes identical**. `run_tests.py` is
therefore unchanged from baseline — 10/20 passed before and after, and every
metric in `results.json` (exact, within, within32, mean_abs, max_d, passed) is
equal file by file, checked by running the harness against the saved baseline
binary.

### Tile-border identity: what had to be fixed

Stitched quadrants are **byte-identical** to the full render for all 20 corpus
files, and so are tiles at odd offsets and sizes, tiles hanging off an edge, and
512×512 tiles of the 4000 px wide image.

That did not hold with the old rasterizer, and the reason was the one the task
guessed. The mask is the shape's bounding box ∩ canvas, so it is a *different*
rectangle for a tile than for the full image, and every edge was geometrically
clipped to it: the part outside was cut off and the part left over was then
re-interpolated from its new endpoints. Both steps round (`Int.ediv` in the
clip, truncating division per row), so an edge crossing a tile border got
slightly different x positions inside the tile than it had in the full render —
a ±1/256 px shift, visible as ±1 in the 8-bit alpha of pixels near the border.

The fix, in `Raster.lean`, splits the two jobs clipping was doing:

* **Clipping to the document rectangle** (the old rounding) is kept, but the
  rectangle is now the *document*, not the mask: `(0, 0, W, H)` for a full
  render and `(−X, −Y, W−X, H−Y)` for a tile, which is the same rectangle of
  the document in both cases. In a full render the mask edges that the old code
  clipped at only ever bite at the canvas edges, so this is exactly the old
  behaviour — that is why the 80 hashes are unchanged, by construction rather
  than by luck.
* **Restricting to the mask** is now done without touching the geometry:
  `accumPiece` visits only rows `[0, bh)` and columns `[0, bw]`, but computes x
  at each row boundary from the piece's own endpoints, and the area function
  `r2` already yields 0 for a column left of the piece and full coverage for one
  to its right. So a pixel's coverage no longer depends on where the mask
  boundary is.

Correctness of the claim rests on two invariances: the mask origin of a tile
differs from the full render's by a whole number of pixels (both are
`max(0, floor(min))` of the same geometry offset by an integer number of
pixels), and both `r2` and the row interpolation are invariant under a common
shift of their arguments. The same shift trick keeps the loops in `Nat` as the
invariants require: a piece reaching outside the mask is shifted right/down by
whole pixels until it is non-negative, and the constant is subtracted back when
indexing, so no hot-loop arithmetic moved to `Int`.

### Interactive tile timings

512×512 tile at `--width 4000`, centred (`--viewport 1744 1744 512 512`),
median of 5, wall clock including process start (M-series macOS):

| file | tile ms | full 4000 px render | 1×1 tile (fixed cost) |
|---|---|---|---|
| `12_badge` | **457.6** | 10 676 ms | 9.4 ms |
| `16_stress_2000` | **587.2** | 21 486 ms | 211.4 ms |
| `18_rose_lissajous` | **220.3** | 7 073 ms | 63.1 ms |

`run_tiles.py` reported 449.9 / 580.2 / 220.4 ms on its own run. A tile is
23–37× cheaper than the whole image, but it is not yet interactive: nothing is
culled, so every shape is still parsed, flattened, stroked and transformed for
every tile. The 1×1 column is that fixed cost — 211 ms of `16_stress_2000`'s
587 ms is parsing 223 KB and flattening 2000 shapes, and only the rest is
rasterizing. Bounding-box culling against the tile before flattening is the
obvious next step and is not part of this task.

### Checks

* `lake build` — clean, no warnings.
* `python3 tests/run_tests.py` — 10/20, identical to baseline metric by metric.
* `python3 tests/run_adversarial.py` — **37/37 clean, 0 violations** (the task
  says 28/28; the harness now generates more cases — the pre-change binary also
  reports 37/37). The heaviest case, `gen/huge_path.svg`, is within noise of
  baseline (medians of 5: baseline 9.7–10.5 s, new 9.6–10.7 s).
* `python3 tests/run_tiles.py` — 20/20 exact, off-document tiles transparent,
  partial tiles equal to the crop.
* Extra, ad hoc: `--viewport` with `--zoom`, `--background`, `--width 0`,
  offsets of ±2·10^9, tiles of a 10^6 px wide image, and bad argument forms —
  no crash or hang, rc 2 for malformed arguments, rc 1 for a tile over the size
  caps.

### Not done / notes

* Nothing is committed.
* No culling (see the timings above).
* `Mat.translate` clamps the offset at `Fx.maxVal` (2^30 ≈ 4.19 M px), so a
  viewport offset beyond ~4.19 M px silently stops moving. It is far past the
  4096× zoom ceiling and the 16 Mpx tile cap; it only affects absurd inputs,
  which stay bounded and crash-free.
* `r2`'s square can exceed 63 bits — and fall back to Lean's bignum path, which
  is slower but still exact — for a nearly horizontal edge spanning most of a
  virtual image wider than ~10^6 px within a single scanline. Before this task
  the clip to the mask kept that product below 2^52; now it is bounded by the
  document width instead.
