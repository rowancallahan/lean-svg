# T12 — Hairline strokes (device width ≤ 1 px)

## Goal

T1 found that resvg does not use the supersampling scan converter for thin
strokes: `painter.rs::treat_as_hairline` routes any stroke whose device-space
width is ≤ 1 to `scan::hairline_aa` (Skia's anti-aliased hairline, a
Wu-style line rasterizer), with the coverage scaled by the width when it is
below 1. A 1 px diagonal of length 200 gets ~160 px² of ink from resvg versus
our geometrically correct ~200 px², and that is most of `17_koch_snowflake`'s
miss and part of `16_stress_2000`'s. Port the hairline path.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T12` (branch
`t12-hairline`). Files: `MicroSvg/Raster.lean` (add a `hairline` function
producing a `Mask`; do not change `rasterize`), `MicroSvg/Render.lean`
(`drawShape`: route strokes to it). Do not touch `Geom.lean` (T11 owns the
stroker).

## Reference

tiny-skia `src/scan/hairline_aa.rs` (and `hairline.rs` for the non-AA
structure it shares), plus `painter.rs::treat_as_hairline` for the exact
condition and the coverage scaling (`stroke_path` computes `coverage` for
widths < 1 and multiplies the paint alpha). Clone or reuse
`/private/tmp/claude-501/-Users-rowancallahan-website/73d6fcc2-0699-487e-b5c3-96bdc24e9f1d/scratchpad/tiny-skia`.
Write the exact scheme into the report before coding: the fixed-point
formats (FDot6/FDot16), how the major axis is chosen, the per-step coverage
split between the two pixels, the endpoint handling, and the alpha
modulation for width < 1. Note also what tiny-skia does with caps and joins
for hairlines (it draws each flattened segment independently; overlapping
pixels are blended by `max`/`add`? read `hairline_aa.rs`'s blitter use and
reproduce it).

## What to change

- `Raster.hairline (W H : Nat) (polys : Array (Array Pt)) (closed : Array Bool)
  (alpha256 : Nat) : Option Mask` (or similar): rasterize each polyline
  segment with the ported algorithm into one `Mask` covering the union
  bounding box, accumulating coverage the way tiny-skia's hairline blitter
  does across overlapping segments. Coverage in the existing `[0, 65536]`
  convention, scaled by the width factor.
- `Render.drawShape`: compute the device-space stroke width as tiny-skia does
  (`treat_as_hairline`: transform the width by the matrix's scale; read the
  exact test) and, when ≤ 1 px, skip `strokePoly` and use `hairline` on the
  flattened polylines mapped through `ctm`, with the paint alpha scaled for
  widths < 1. Otherwise unchanged.
- Invariants in `tasks/README.md`: all loops bounded by the segment's
  major-axis length in pixels (≤ canvas size after clipping) and the number
  of segments; no `Float`.

## Measure

Not byte-identical by design. `python3 tests/run_tests.py` before/after:
`within%` must not decrease on any file and should rise on 17_koch and
16_stress; report per-file numbers. Add `tests/svg/21_hairlines.svg` (thin
lines at many angles, widths 0.25/0.5/1.0, a thin polyline with joins, a
thin circle) and report its numbers. Tiles 20/20, adversarial clean,
`Effect.lean` untouched.

## Done when

Koch and stress improve, nothing regresses, `21_hairlines` ≥ 99% within 8 or
a precise account of what differs. Report appended. Commit on the branch.

## Report

### The tiny-skia hairline scheme, as read from the source

Written before any code was touched, from
`src/painter.rs` (`treat_as_hairline`, `stroke_path`, `stroke_hairline`),
`src/scan/hairline.rs` (`stroke_path_impl`, `extend_pts`) and
`src/scan/hairline_aa.rs` (`anti_hair_line_rgn`, `do_anti_hairline`, the four
`AntiHairBlitter`s), plus `src/fixed_point.rs`.

**1. Dispatch and the width factor** (`painter.rs:544`). The translation is
dropped from the CTM and the two vectors `(w, 0)` and `(0, w)` are mapped
through the linear part, giving `p0 = (a·w, b·w)` and `p1 = (c·w, d·w)` in
device space.  Each is measured with the octagonal norm
`fast_len(p) = max(|x|,|y|) + min(|x|,|y|)/2`.  If **both** `len0 ≤ 1` and
`len1 ≤ 1` the stroke is a hairline and the returned coverage is
`(len0 + len1)/2`; a zero-width stroke returns coverage `1`.  The paint is then
modulated once: `scale = ⌊coverage·256⌋`, `newAlpha = (255·scale) >> 8`,
`shader.apply_opacity(newAlpha/255)`, i.e. the paint alpha is multiplied by
`newAlpha/255`.  `coverage = 1` leaves the paint alone.  Nothing else changes:
the *geometry* drawn is always a one-sample-per-major-axis-step hairline, which
is why a 200 px diagonal gets 160 px² of ink instead of 200 px².

**2. Fixed-point formats.** Device coordinates enter as **FDot6** (26.6,
`(x_px·64)` truncated toward zero).  The running cross-axis position and the
slope are **FDot16** (16.16).  `to_fdot16(n) = n << 10`.  The slope is
`fast_div(Δminor, Δmajor) = (Δminor << 16) / Δmajor`, a *truncating* divide, and
`|slope| ≤ 1` always because the major axis is the larger one.  Per-pixel
alphas are plain `u8`; the per-step scaling is
`small_scale(v, d6) = (v·d6) >> 6` with `d6 ∈ [0,64]`.

**3. Major axis.** `|x1-x0| > |y1-y0|` → "mostly horizontal", otherwise
"mostly vertical" (so an exactly diagonal segment is vertical-major, and a
zero-length segment is dropped).  The segment is then oriented along the major
axis (`x0 > x1` → swap both endpoints).  With `i` the major coordinate:
`istart = floor6(major0)`, `istop = ceil6(major1)`,
`fstart = to_fdot16(minor0) + ((slope·(32 - (major0 & 63)) + 32) >> 6)` — that
last term re-centres the sample on the *centre* of column `istart`.
The degenerate sub-cases are `minor0 == minor1` (slope 0, the `HLine`/`VLine`
blitters) and everything else (`Horish`/`Vertish`).

**4. Per-step coverage split.** One step per major-axis pixel `i`, with a
running `fy = fstart + 0x8000` clamped at `0` (persistently) at the top of each
step:

```
ly  = fy >> 16                      -- "lower" minor pixel
a   = (fy >> 8) & 0xFF              -- its share, 0..255
emit (i, ly)     with (a       · mod64) >> 6
emit (i, ly - 1) with ((255-a) · mod64) >> 6      -- "upper", index clamped ≥ 0
fy += slope
```

So each step lays down a total of 255 units of alpha split between two adjacent
minor pixels — one sample per major step, never a 1 px-wide quad.  `Horish`
uses `blit_anti_v2` and always emits both pixels (upper row index clamped by
`max(ly,1)-1`); `HLine`/`VLine` skip a zero alpha and skip the upper pixel
entirely when it would be index `-1` (`checked_sub`).

**5. Endpoints (`mod64`).** `draw_cap` is `draw_line` with a `mod64 < 64`:
if `istop - istart == 1` the whole segment is inside one major pixel, so
`scale_start = major1 - major0` (0..64) and `scale_stop = 0`; otherwise
`scale_start = 64 - (major0 & 63)` and `scale_stop = major1 & 63`.  Column
`istart` uses `scale_start`, column `istop-1` uses `scale_stop` when that is
non-zero (and is simply not drawn when `scale_stop = 0`, because the ceil
already excluded it), every column between uses 64.  The integral clip only
ever *skips* columns and forces `mod64 = 64` at a clipped start / `scale_stop =
0` at a clipped stop, advancing `fstart` by `slope·n` exactly — so it never
changes a pixel that is inside the clip.

**6. Caps and joins.** There are none.  `stroke_path_impl` walks the path and
hands every flattened segment to the line proc *independently*; the blitter is
the real pixmap blitter, so two segments that share an end pixel are
**composited twice** (src-over), not `max`-ed and not added.  The only cap
handling is `extend_pts`: for `round`/`square` the first point of the first
segment of a subpath and the last point of the segment before a `Move`/`Close`/
end are pushed out along the unit tangent by `cap_outset` = `0.5` (square) or
`π/8 ≈ 0.3927` (round).  A `Close` segment itself is never extended (unless the
subpath is a degenerate `moveTo`+`close`), but it is closed back to the
*extended* first point.  Joins are not drawn at all.

### How that maps onto our `Mask`

Our architecture blits a shape once, through `Canvas.fillMask m c a8`.  Two
src-over blits of the *same* colour at coverages `c1` and `c2` with paint alpha
`a` are exactly one blit at `c1 + c2 - a·c1·c2`, so overlapping hairline
segments are accumulated with that rule (in the `[0, 65536]` convention,
`c1 + c2 - a8·c1·c2/(255·65536)`, saturated at 65536).  And because the paint
is premultiplied by `a8` before the coverage is applied, multiplying the paint
alpha by `newAlpha/255` is identical to multiplying every coverage by it, so
the width factor is folded into the mask instead of into `a8`, which keeps 16
bits of it rather than 8.

### What changed

* `MicroSvg/Raster.lean` — new only, `rasterize` untouched: `toFDot6`,
  `divRound`, `hairPx` (the src-over accumulator), `hairSeg`
  (`do_anti_hairline` for one segment) `capExtend` (`extend_pts` for one end)
  and `hairline` (segment building, bounding box, mask), plus a module section
  describing the scheme.
* `MicroSvg/Render.lean` — `hairCoverage` (`treat_as_hairline`) and a two-way
  branch in `drawShape`'s stroke arm.  The fill arm, the culling and `clipMask`
  are unchanged, and the non-hairline stroke is the same code as before.
* `tests/svg/21_hairlines.svg` — new corpus file: three 12-line fans (one per
  width 1.0 / 0.5 / 0.25) covering every octant and both major axes, exact
  horizontal/vertical/near-axis lines for the `HLine`/`VLine` blitters, two
  thin polylines whose vertices exercise the overlap rule, three concentric
  thin circles, a round and a square cap, a closed thin rect, and a
  `rotate(24) scale(2)` group whose 0.5 user-space width is exactly 1 device
  pixel.
* `MicroSvg/Effect.lean` untouched.  No `partial`, `unsafe`, `panic!`,
  `!`-indexing or `Float`; every loop is a `for` over the segment list or over
  the segment's major axis *after* the clip, so it is bounded by the mask's
  width or height.  `lake build`: no errors, no new warnings.

### Numbers

`python3 tests/run_tests.py`, `within%` (tol 8), natural size:

| file | before | after | Δ |
|---|---|---|---|
| 01_triangle | 100.000 | 100.000 | — |
| 02_rect_circle | 99.502 | 99.502 | — |
| 03_curves | 99.172 | 99.172 | — |
| 04_stroke | 99.960 | 99.960 | — |
| 05_transform | 99.812 | 99.812 | — |
| 06_evenodd | 100.000 | 100.000 | — |
| 07_opacity | 99.853 | 99.853 | — |
| 08_group_inherit | 99.815 | 99.815 | — |
| 09_viewbox | 99.753 | 99.753 | — |
| 10_polygon_star | 99.792 | 99.792 | — |
| 11_style_attr | 99.692 | 99.692 | — |
| 12_badge | 97.659 | 97.659 | — |
| 13_gear_evenodd | 99.365 | 99.365 | — |
| 14_flower_transforms | 97.608 | 97.608 | — |
| 15_spiral_stroke | 97.149 | 97.149 | — |
| **16_stress_2000** | 95.832 | **96.118** | **+0.286** |
| **17_koch_snowflake** | 96.903 | **99.222** | **+2.319**, FAIL → PASS |
| 18_rose_lissajous | 99.680 | 99.680 | — |
| 19_sierpinski | 100.000 | 100.000 | — |
| 20_function_plot | 99.647 | 99.647 | — |
| **21_hairlines** (new) | 92.887 | **99.627** | **+6.740**, FAIL → PASS |

Nothing decreased; every file that has no hairline in it is byte-for-byte what
it was.  17_koch also drops from `max_d` 101 to 41 and `mean_abs` 0.494 to
0.121, and 16_stress from `mean_abs` 0.588 to 0.555.  20_function_plot is
unchanged *because* the port is right: its `stroke-width="1"` grid lines are
axis-parallel on half-pixel centres, where the hairline walker and the
supersampling converter produce the same 128/127 split.

Faster, too, since a hairline skips the stroker and the scan converter:
17_koch 19.6 → 15.6 ms, 16_stress 195.5 → 193.4 ms, 21_hairlines 362.6 → 14.7 ms.

`python3 tests/run_tiles.py`: **21/21** files, quadrant tiles stitch
byte-identically to the full render at `--width 800`; off-document and partial
tiles clear.  `python3 tests/run_adversarial.py`: **38/38 cases clean, 0
violations** (37 before — the run generates one truncated case per corpus file,
so the new file adds exactly one).

### Is the port exact?

The T1 probe — `<path d="M 20 40 L 180 160" stroke-width="1">`, which scored
98.995 % with 402 bad pixels and 200.31 px² of ink against resvg's 160.00 — is
now **byte-identical**, ink 160.00 both sides.  Probes at 200×200:

| probe | within8% | max_d | what it isolates |
|---|---|---|---|
| width 1 diagonal | 100.000 | 0 | the walker, `mod64`, both caps |
| width 1 diagonal, fractional ends | 100.000 | 0 | `scale_start` / `scale_stop` |
| width 1 polyline, 3 joins | 100.000 | 0 | the src-over overlap rule |
| width 1 closed rect | 100.000 | 0 | closing segment, `HLine`+`VLine` |
| width 1, `linecap="square"` | 100.000 | 0 | `extend_pts`, 1/2 px |
| width 0.5 diagonal | 100.000 | 1 | the width factor |
| width 0.25 diagonal | 100.000 | 1 | ditto |
| width 1, `linecap="round"` | 100.000 | 4 | `extend_pts`, π/8 |

So the converter itself is exact, and the three residues are all quantisation
of an input, not of the algorithm: the width factor reaches `Canvas.fillMask`
as an 8-bit coverage (±1 level), and a cap outset lands on our 1/256 px
coordinate grid before being truncated to `FDot6`, which can move it by one
1/64 px step and one step is worth `255/64 ≈ 4` levels.

### What 21_hairlines' remaining 0.373 % is

336 pixels over tolerance, 37 of them over 32.  Two causes, neither of them the
hairline converter:

* **Curve flattening (≈ 290 px, all of the `> 32`).** The three concentric
  circles account for it: alone they score 99.769 / 99.964 / 100.000 %.  Handing
  *the same circles* to both renderers as an explicit 400-gon scores
  **100.000 %, `max_d` 4, zero bad pixels**, at both radii — so this is entirely
  `Geom.segCount`'s `√(2·L)+1` chord error (T1's finding 2), which a hairline
  shows off badly because a 0.08 px radius error moves the sample by 5 `FDot6`
  units.  It is also radius-dependent and not monotone: `r=70` (16 segments per
  quadrant) is clean at `max_d` 1 while `r=46`, `r=60` and `r=30` (13, 15 and 11)
  are not.
* **`rotate(24)` (≈ 24 px).** The transformed group differs by `max_d` 28.  This
  is `Geom.sinCos16`, not the hairline: the *same* group drawn at a 4 px device
  width, i.e. through the old stroker + supersampling path, differs by the same
  `max_d` 32 on 17 pixels, and the group with the rotation removed
  (`scale(2)` only, still exactly 1 device px) is byte-identical.

Both belong to `Geom.lean`, which T11 owns and this task may not touch.

### Deliberate deviations, and why

1. **No float pre-clip.**  `anti_hair_line_rgn` chops each segment against the
   clip outset by 1 px before converting to `FDot6`; that moves the endpoints,
   so it changes the slope and the end `mod64` — and it is not invariant under
   the whole-pixel translation a `--viewport` tile applies, which would break
   the byte-identical tile guarantee.  The segment is clipped integrally
   instead, exactly as `do_anti_hairline`'s own clip does (skip major columns,
   advance `fstart` by `slope·n`, `contribution_64` for a one-column result),
   which provably never changes a pixel inside the clip.  Consequence: a segment
   that crosses the edge of the canvas can differ from resvg in the one or two
   pixels at the crossing.
2. **No 511 px halving.**  `do_anti_hairline` recurses on `(x0>>1)+(x1>>1)`,
   which it calls "less precise" itself and which exists only to keep i32
   intermediates from overflowing.  `Int` does not overflow, and the split point
   is not translation-invariant either.  Consequence: a thin stroke longer than
   511 device px can differ from resvg.  Nothing in the corpus at natural size
   is that long.
3. **Overlap saturates at full coverage.**  The `c₁ + c₂ - a·c₁·c₂` rule is
   exact, but for a *translucent* stroke two overlapping segments genuinely need
   `cov > 1` to reproduce two blends, which a single `Mask` cannot express.  The
   accumulator saturates at 65536, so a self-overlapping translucent hairline is
   very slightly lighter than resvg's.  (16_stress has 585 such paths, which is
   part of why it gains 0.29 and not more.)
4. **Caps on a bare `moveTo`.**  A subpath of one point draws nothing; tiny-skia
   with a non-butt cap would draw a dot.
5. **Curve flattening is ours, not `hair_quad`/`hair_cubic`'s** — see above.

`Render.shapeOnCanvas` was left alone.  Its margin is `strokeReach·scale + 258`
`Fx`, and a hairline reaches at most 1 px (the walker) plus 1/2 px (a square
cap) past the control box, so the margin covers every width down to about
0.05 px; below that a shape lying 1.1–1.5 px off the canvas with a square cap
could in principle be culled while still owning an edge pixel.  Nothing in the
corpus is near it.
