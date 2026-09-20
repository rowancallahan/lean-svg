# T10 — Cull shapes that cannot touch the canvas

## Goal

T4/T4m measured a 512×512 tile of a 4000 px image at 600–960 ms, of which a
large fixed part is flattening, stroking and transforming every shape even
when the tile is 1×1 (`16_stress_2000`: 211 ms for a 1×1 tile). Skip the
work for any shape whose device-space bounding box cannot intersect the
canvas. Output must stay **byte-identical** (a culled shape contributes no
pixels by construction), so this is pure speed.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T10` (branch
`t10-cull`). Files: `MicroSvg/Render.lean` (`drawShape`), and a small helper
in `MicroSvg/Geom.lean` if cleaner. Do not touch `Raster.lean`, `Canvas.lean`,
`Png.lean` (other agents own them).

## What to change

In `Render.drawShape`, before `flatten`:

1. Compute the bounding box of the shape's control points in device space:
   every `Pt` inside every `PathCmd` (moveTo/lineTo points, both cubic
   control points and the end point), mapped through `ctm`. By the convex
   hull property a cubic lies inside the hull of its four control points, so
   this box contains the flattened fill.
2. If the shape has a stroke, inflate the box by a conservative bound on the
   stroke's device-space reach: `hw · (|a| + |c|)/65536 + 1` in x and
   `hw · (|b| + |d|)/65536 + 1` in y (with `hw = strokeWidth/2` in `Fx`),
   multiplied by `max(1, miterLimit/256)` to cover miter tips, plus one extra
   pixel for rounding. Round caps/joins never exceed `hw`, square caps never
   exceed `hw·√2 < 2·hw`; use `2·hw` for caps to be safe.
3. If the (inflated) box does not intersect `[0, W·256) × [0, H·256)`, return
   the canvas unchanged. Otherwise proceed exactly as today.
4. Everything must satisfy `tasks/README.md`; the bbox loop is a `for` over
   `cmds`.

## Measure

- sha256 of the whole corpus rendered in the four CLI modes used by T4m
  (default, `--width 800`, `--width 1600 --background white`, `--zoom 2.5`)
  and the `run_tiles.py` suite: all identical before/after.
- `python3 tests/run_tiles.py` 20/20.
- Tile timings (median of 5): 1×1 tile and 512×512 tile at `--width 4000`
  for `12_badge`, `16_stress_2000`, `18_rose_lissajous`, before/after. Also
  a 64×64 tile, which is the size a viewer would actually use for
  incremental rendering.
- `python3 tests/run_tests.py` unchanged; adversarial clean.

## Done when

Byte-identical output, tile timings reported, `## Report` appended. Do not
commit.
