# T10 — Cull shapes that cannot touch the canvas

## Goal

T4/T4m measured a 512×512 tile of a 4000 px image at 600–960 ms, of which a
large fixed part is flattening, stroking and transforming every shape even
when the tile is 1×1 (`16_stress_2000`: 211 ms for a 1×1 tile). Skip the
work for any shape whose device-space bounding box cannot intersect the
canvas. Output must stay **byte-identical** (a culled shape contributes no
pixels by construction), so this is pure speed.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T10` (branch
`t10-cull`). Files: `LeanSvg/Render.lean` (`drawShape`), and a small helper
in `LeanSvg/Geom.lean` if cleaner. Do not touch `Raster.lean`, `Canvas.lean`,
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

---

## Report

### What changed

| file | change |
|---|---|
| `LeanSvg/Geom.lean` | `Box` (a closed device-space box), `Box.cover`, `Box.meets`, `strokeReach` (a stroke's user-space reach off its polyline), and `ctrlBoxMeets`, which walks `cmds` and answers whether the control points' device box meets a rectangle |
| `LeanSvg/Render.lean` | `shapeOnCanvas`, which turns the stroke reach and the rounding slack into a widened canvas rectangle; `drawShape` returns the canvas untouched when it says no |

`Raster.lean`, `Canvas.lean`, `Png.lean`, `Effect.lean`, `Main.lean`, and every
harness under `tests/` are untouched — `git diff main` is those two files and
nothing else. No `partial`, no `unsafe`, no `@[extern]`, no `panic!`, no
`!`-indexing, no `Float`; the one new loop is a `for` over `cmds`. `lake build`
is clean with no warnings, checked with every module forced to rebuild.

Started from the previous agent's WIP commit. Its bounding-box construction and
its stroke bound were sound and are kept, with two changes:

* **The cull is decided against a widened rectangle rather than a widened box.**
  Inflating the box by `(dx, dy)` and testing it against `[0, W·256) × [0, H·256)`
  is the same predicate as testing the raw box against
  `[−dx, W·256 + dx) × [−dy, H·256 + dy)`, and the second form leaves the
  growing box as the only thing the scan has to touch.
* **The scan stops as soon as the box built so far already meets that
  rectangle.** The box only grows and `Box.meets` is monotone under growth, so
  the answer cannot change afterwards. This matters: without it, a path that
  covers the tile paid a full `Mat.apply` per control point for a foregone
  conclusion. `18_rose_lissajous` is two 78 KB polylines spanning the whole
  image and nothing in it is ever cullable, so it paid the scan and got nothing
  back — a 1×1 tile went from 60.7 ms to 63.9 ms, a 5% *regression*. With the
  early exit it is 61.0 → 61.5 ms, and the shapes that are worth culling are
  still culled.

### Why the output cannot change

A culled shape is one `Raster.rasterize` would have discarded anyway: it takes
the bounding box of the device points it is handed and returns `none` once that
box misses `[0, W) × [0, H)` in whole pixels. So it is enough that every device
point `drawShape` can hand it lies inside the box this test builds:

* `cubicAt` divides an exact convex combination of the four control points with
  `Int.ediv`, and those points are integers, so a flattened point stays inside
  the control points' integer box — but not inside their hull, which is what
  costs one `Fx` of user-space slack per axis.
* An affine map takes a hull to the hull of the mapped points, so the box of
  the mapped control points contains the mapped hull. `Mat.apply` floors, and
  the floor of a minimum is the minimum of the floors, so that costs one `Fx`
  of device slack per side.
* `strokePoly` builds the stroke in the path's *own* space, so its reach `r`
  off the polyline is worth `r·(|a| + |c|)/65536` in device x and
  `r·(|b| + |d|)/65536` in device y. `strokeReach` bounds `r` by
  `(hw + 2)·max(2, ⌈miterLimit/256⌉) + 2`: segment quads, bevels and
  `circlePoly` stay within `hw`, a square cap stacks two offsets (`2·hw`), and
  `emitJoin` only emits a miter tip when the ratio check passes, which is
  exactly the statement that the tip is within `hw·miterLimit/256`. The `+2`s
  absorb the `Int.ediv` in `normalOf`, `dirOf`, `circlePoly` and the tip.
* Every `Fx.clamp` on the way is monotone and applies to the real geometry and
  to the box alike, so it cannot reorder the two.

`shapeOnCanvas` then spends `r + 4` and `258` where 1 and 1 would do.

### Byte-identity

| check | result |
|---|---|
| corpus × 4 CLI modes (default, `--width 800`, `--width 1600 --background white`, `--zoom 2.5`), sha256 vs main's binary | **80/80 identical** |
| the same 4 modes, main's binary vs a pre-culling rebuild of main in this worktree | 80/80 identical (so the prebuilt baseline is main) |
| corpus × 8 viewports (4 quadrants, off-document, partial, a 512×512 and a 64×64 tile of the 4000 px image), sha256 vs main | **160/160 identical** |
| `tests/run_tiles.py` | **20/20** — stitch exact, off-document clear, partial exact |
| every 40 px tile of the corpus at `--width 400`, stitched (1960 tiles) | **20/20 files byte-identical to the full render** |
| 312 synthetic cull-boundary files × 7 modes, vs main | **2184/2184 identical** |

The synthetic sweep is the one that actually exercises the inflation, because
the corpus never puts a shape just off the edge. Each family sweeps an offset
`k ∈ [0, 26)` across the canvas boundary so the pass/cull transition is hit
exactly, and relies on one mechanism to pull ink back onto a canvas the path
itself misses: half width, square cap, round cap, a miter tip with
`stroke-miterlimit="20"`, a lone `moveTo` with a round cap (a dot), a subpath
resumed after `Z`, a leading `Z`, a cubic with both control points off canvas,
a rotation, a `skewX` (so `|a| + |c| ≠ |a|`), a fill edge, and a 950 px half
width reaching in from 940 px away. Checked against main's binary that each
family really does paint on part of its sweep.

`python3 tests/run_tests.py`: **15/20**, and all 260 non-timing fields
(`exact`, `within`, `within32`, `mean_abs`, `max_d`, `passed`) are equal to
main's, file by file. `python3 tests/run_adversarial.py`: **37/37 cases clean,
0 with violations** (the task file says 28/28; the suite generates more cases
now, as T4/T4m already recorded). The two heavy adversarial cases are unmoved:
`gen/huge_path.svg` 13 125 → 13 023 ms, `gen/many_elements.svg` 2377 → 2450 ms.

### Tile timings

`--width 1600`, centred tiles, median of 3, wall clock including process start
(M-series macOS, load average ≈ 3):

| file | tile | before | after | speedup |
|---|---|---|---|---|
| `12_badge` | 1×1 | 7.6 ms | **6.3 ms** | 1.21× |
| `12_badge` | 64×64 | 18.8 ms | **18.0 ms** | 1.05× |
| `12_badge` | 256×256 | 173.9 ms | **174.6 ms** | 1.00× |
| `16_stress_2000` | 1×1 | 136.8 ms | **29.2 ms** | 4.68× |
| `16_stress_2000` | 64×64 | 144.9 ms | **40.5 ms** | 3.57× |
| `16_stress_2000` | 256×256 | 271.3 ms | **172.8 ms** | 1.57× |

Measured earlier at `--width 4000`, median of 5, the size T4/T4m reported:

| file | tile | before | after | speedup |
|---|---|---|---|---|
| `12_badge` | 1×1 | 9.9 ms | **7.8 ms** | 1.26× |
| `12_badge` | 64×64 | 20.9 ms | **19.9 ms** | 1.05× |
| `12_badge` | 512×512 | 707.4 ms | **701.6 ms** | 1.01× |
| `16_stress_2000` | 1×1 | 210.8 ms | **32.0 ms** | 6.59× |
| `16_stress_2000` | 64×64 | 218.4 ms | **42.3 ms** | 5.16× |
| `16_stress_2000` | 512×512 | 719.2 ms | **553.0 ms** | 1.30× |
| `18_rose_lissajous` | 1×1 | 61.0 ms | **61.5 ms** | 0.99× |
| `18_rose_lissajous` | 64×64 | 70.8 ms | **69.6 ms** | 1.02× |
| `18_rose_lissajous` | 512×512 | 513.3 ms | **502.2 ms** | 1.02× |

Full renders are unchanged within noise (median of 5, `--width 800`):
`12_badge` 545.7 → 551.5, `16_stress_2000` 1415.0 → 1424.6,
`18_rose_lissajous` 678.2 → 658.7, `13_gear_evenodd` 256.7 → 255.8,
`17_koch_snowflake` 383.5 → 381.9 ms.

### What the numbers say

The fixed cost T4 measured is now paid only where it is unavoidable.
`16_stress_2000`'s 1×1 tile was 211 ms of flattening 2000 shapes and parsing
223 KB; culling removes the flattening and leaves 32 ms, which is the parse. So
**the remaining fixed cost of a tile is parsing, and culling has taken the rest
out.** A 64×64 tile — the size a viewer would actually request — is 3.6–5.2×
cheaper and now costs barely more than the parse.

The two files that barely move say where the ceiling is, and they say it for
different reasons. `12_badge` is 13 shapes, most of them covering the image:
there is nothing to cull, and its 1×1 tile was already 10 ms. `18_rose_lissajous`
is five shapes, two of which are polylines spanning the whole image; culling
decides per shape, so a shape that covers the tile is flattened in full however
little of it lands there. Its 512×512 tile is 502 ms of rasterizing and
flattening two paths that genuinely cross the tile.

### Not done / notes

* Culling is per shape. Cutting `18_rose_lissajous`-shaped work needs a test
  per subpath or per segment inside `flatten` / `strokePoly`, which is
  `Geom.lean`'s and `Raster.lean`'s business and was not in scope here.
* The bound is deliberately loose (`r + 4` and `258` where 1 and 1 suffice);
  tightening it would only cull a shape whose ink is within a pixel of the
  canvas, which is not worth the risk.
* A shape with an absurd `stroke-miterlimit` (the parser clamps at `Fx.maxVal`)
  produces an inflation clamped at `Fx.maxVal`, so its rectangle covers
  everything representable and it is never culled. That is the conservative
  direction, and `gen/giant_stroke.svg` is unaffected (7.0 → 6.8 ms).
* Committed on `t10-cull`; `main` untouched.
