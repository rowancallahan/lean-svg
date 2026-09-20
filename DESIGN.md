# microsvg — design

## 1. What is claimed, and what is not

**Claimed and machine-checked** (see `MicroSvg/Effect.lean`):

- The top-level program is a value of `Prog (Except String Unit)`. `Prog` is a
  free monad with exactly two operations, `readInput` and `writeOutput`.
  There is no constructor for any other effect, so the type checker rejects a
  program that tries to do anything else.
- Against a model file system `FS := String → ByteArray`:
  - `runFS_frame`: running any `Prog` leaves every path except the output
    path unchanged.
  - `runFS_input_only`: the result depends only on the input path's contents.
  - `renderProgram_spec`: the renderer program's run equals
    `match render input with | ok png => (ok, fs[out ↦ png]) | error e => (error e, fs)`.
  - Corollaries: on error nothing is written; on success the output path holds
    exactly `render input`.
- `#print axioms` on all of these: `propext` only. No `sorry`, no `Classical`.

**Claimed by construction** (enforced by the language, checked by grep):

- Termination: no `partial`, no `unsafe`. Every loop is `for _ in [a:b]` with
  a bound derived from the input size or a constant, so every function is
  total and Lean accepts it without a termination proof.
- Memory safety: no FFI, no `@[extern]`, no `panic!`, no `!`-indexing. All
  array access is `getD` / `setIfInBounds` or proof-carrying.
- No floats anywhere.
- Bounded resources: output canvas ≤ 16384 px per side and ≤ 2^24 px; every
  parsed number clamped to ±2^22 px; XML depth ≤ 64; elements ≤ 10^6.

**Not claimed:** pixel-level correctness. SVG has no formal rendering
semantics. Fidelity is measured against resvg (`tests/run_tests.py`).

**Trusted:** the Lean compiler and runtime (C), the C compiler, the OS,
`Prog.execIO` (6 lines mapping the two ops to `IO.FS.readBinFile` /
`writeBinFile`), and `Main.lean` (argument parsing, stderr message).

## 2. Threat model

An attacker controls the input file completely. Goals we defend against:

| Attack | Where it lives in other renderers | Our defence |
|---|---|---|
| Entity expansion (billion laughs) | XML DTD | DOCTYPE with `[` rejected; only 5 predefined entities decoded |
| External entities / local file read (XXE, librsvg CVE-2023-38633, Inkscape CVE-2026-4980) | DTD, `href`, XInclude | No code path resolves any reference; `Prog` cannot open a second file |
| SSRF via remote resources (Batik) | `href`, `url()` | same |
| Script execution | `<script>`, event attrs | skipped as unknown elements |
| Stack exhaustion via nesting (librsvg CVE-2019-20446) | recursive parser/renderer | parser is iterative with a stack array; depth cap 64 |
| Memory exhaustion via dimensions | canvas alloc | dimension and pixel caps checked before allocation |
| CPU exhaustion via numbers (`1e999999999`, megabytes of digits) | number parsing, big-int math | 18 significant digits kept, exponent saturates at 10^5 and clamps at ±60, result clamped |
| Malformed input crashes | parser | every read past the end returns 0; every array op is bounds-checked |
| Writing somewhere unexpected | I/O layer | `runFS_frame` |

Remaining cost bound, not a vulnerability: rendering is O(shapes × visible
area of each shape). A file with 10^6 full-canvas shapes at 16 Mpx is slow.
That is inherent to rendering; cap with `--width` or lower `Xml.maxElements`.

## 3. Pipeline

```
ByteArray ──Xml.parse──▶ Array Event ──Svg.interpret──▶ Doc (root info, Array Shape)
   │                                                       │
   │        Render.canvasSetup: size, viewBox transform, zoom
   ▼                                                       ▼
 for each Shape: flatten (user space) ──▶ [fill] map ctm ──▶ Raster.rasterize ──▶ Canvas.fillMask
                                       └▶ [stroke] strokePoly ──▶ map ctm ──▶ rasterize ──▶ fillMask
                                                                                   │
                                                              Canvas.toRgbaBytes ──▶ Png.encode ──▶ ByteArray
```

### 3.1 Fixed point

`Fx := Int` in 1/256 px. Matrices `a b c d` in 16.16, `e f` in `Fx`.
Composition `m.mul n` applies `n` first (SVG's `transform="A B"` = `A.mul B`).
`rotate` and `skew` use a 16.16 `sinCos16` with quadrant reduction and a
7th-order series; error < 2^-16.

Lean runtime detail that shaped the code: unboxed `Int` is 31-bit on 64-bit
hosts (`LEAN_MAX_SMALL_INT = INT_MAX`), unboxed `Nat` is 63-bit. So the
per-pixel loops are written in `Nat`; geometry that reaches outside the mask
is shifted into `Nat` by a whole number of pixels rather than cut down to it
(§3.5).

### 3.2 XML subset

Flat event stream (`open_ name attrs` / `close`), iterative parser with an
explicit stack of open names. Accepted: prolog, comments, CDATA (skipped),
DOCTYPE without internal subset, elements, quoted attributes, the five
predefined entities and numeric char refs. Everything else is an error.
Text content is never interpreted.

### 3.3 SVG subset

Elements: `svg g path rect circle ellipse line polygon polyline`. Unknown
elements and `defs`, `use`, `text`, `image`, `style`, gradients, clip paths,
masks, filters are skipped with their subtrees. Attributes: `fill stroke
fill-opacity stroke-opacity opacity fill-rule stroke-width stroke-linecap
stroke-linejoin stroke-miterlimit transform visibility display style`.
Paint: `none`, `#rgb[a]`, `#rrggbb[aa]`, `rgb()`/`rgba()`, ~70 named colours,
`transparent`; `url(...)` renders as none. Path data: all of
`M L H V C S Q T Z` absolute and relative; `A` stops parsing (spec: render up
to the error). Quadratics are degree-elevated exactly.

This is a superset of usvg's *micro SVG* output (`svg g path` with absolute
`M L C Z` and `matrix()` transforms), so any full SVG can be pre-processed
with `usvg` and rendered here; text becomes paths on the way.

Known deviations: group opacity is multiplied into children (wrong when
children overlap); no dashes; nested `<svg>` skipped; `rx`/`ry` handled.

### 3.4 Flattening

Cubics are sampled at `k/n` with `n = clamp(√(2·L_px) + 1, 1, 100)` where
`L_px` is the device-space control-polygon length. Evaluation is the exact
integer Bernstein form divided by `n³`. Circles are four cubics with
κ = 36195/65536.

### 3.5 Rasterizer

Signed-area accumulation (font-rs / stb_truetype). For an edge piece inside
one pixel row with vertical extent `dy` and horizontal extent `[xl, xr]`
(all in 1/256 px), the coverage of column `c` is

    cov_c = dy · (R(c+1) − R(c)) / 256,   R(k) = ∫₀¹ max(0, k − x(t)) dt

with `x(t)` linear from `xl` to `xr`. `R` has the closed form 0 / quadratic /
linear on the three ranges of `k`, and `512·R` is an exact integer, so
`cov_c = dy · ΔR2 / 512` in `Nat`. The accumulator stores `cov_c − cov_{c−1}`
so a prefix sum along the row gives each pixel's coverage, in units where
65536 = full. Nonzero: `min(|sum|, 65536)`. Even-odd: fold `|sum| mod 131072`
as a triangle wave.

Edges are clipped to the **document rectangle**: vertically (discard outside),
horizontally by splitting at its left and right edge and clamping the outside
pieces onto the boundary, which preserves winding for every visible pixel.

They are *not* clipped to the mask, which covers only the shape's bounding box
∩ canvas and so is a different rectangle for a tile than for the whole image
(§3.8). Instead `accumPiece` visits only the rows and columns the mask holds,
interpolating `x` at each row boundary from the piece's own endpoints; `R` is
already 0 for a column left of the piece and full for one to its right, so
leaving columns out loses nothing. Coverage of a pixel is therefore the same
whatever the mask boundary is. Each piece is shifted right and down by whole
pixels first, which makes every coordinate a non-negative `Nat` and moves row
and column indices by a constant that is subtracted back when indexing; `R`
and the interpolation are invariant under a common shift.

### 3.6 Stroking

Per subpath: one quad per segment, one wedge per join on the outer side
(miter with limit test `(512·hw)² ≤ limit²·|n₁+n₂|²`, bevel, or round as a
polygon circle), caps (butt/square/round). Every polygon is emitted with
non-negative orientation so the nonzero fill computes their union. Stroking
happens in user space and the outline is transformed afterwards, so
non-uniform scales stroke correctly.

### 3.7 Compositing and PNG

Canvas: premultiplied RGBA8 packed into one `Nat` per pixel. Source-over with
`div255(x) = (x + 127) / 255`. Output: straight alpha, 8-bit RGBA, filter 0,
zlib stream of stored DEFLATE blocks, CRC-32 and Adler-32 computed in Lean.
PNG size is therefore a closed-form function of `(w, h)`; see PLAN M3.

### 3.8 Viewport (tiles)

`Options.viewport = (x, y, w, h)` renders only that window of the zoomed image:
`canvasSetup` returns `w × h` as the canvas size and composes
`translate(−x, −y)` after the zoom, so `maxDim` / `maxPixels` bound the tile
rather than the virtual image it is a window of. It also returns the document
rectangle in canvas pixels — `(0, 0, W, H)` normally, `(−x, −y, W−x, H−y)` for
a tile, i.e. the same rectangle of the document either way, which is what keeps
clipping tile-independent (§3.5). A tile is byte-identical to that window of
the full render (`tests/run_tiles.py`). Maximum zoom is 4096×, where
`Mat.linMax` clamps the 16.16 linear part.

## 4. Fidelity results (M0 corpus, natural size, vs resvg 0.48.1)

| file | exact | ≤ 8 | ≤ 32 | max d |
|---|---|---|---|---|
| 01_triangle | 99.00% | 100.00% | 100.00% | 3 |
| 02_rect_circle | 98.58% | 99.25% | 99.92% | 255 |
| 03_curves | 98.36% | 99.05% | 99.88% | 255 |
| 04_stroke | 96.77% | 99.28% | 99.55% | 255 |
| 05_transform | 98.04% | 99.10% | 99.88% | 255 |
| 06_evenodd | 97.91% | 99.24% | 99.91% | 255 |
| 07_opacity | 62.64% | 99.81% | 99.91% | 255 |
| 08_group_inherit | 96.52% | 99.64% | 99.96% | 255 |
| 09_viewbox | 99.03% | 99.71% | 100.00% | 28 |
| 10_polygon_star | 92.41% | 98.19% | 99.75% | 255 |
| 11_style_attr | 97.55% | 99.49% | 99.91% | 255 |

`max d = 255` pixels are single anti-aliasing seam pixels where one renderer
puts a partially covered pixel and the other does not (tiny-skia supersamples
4× vertically; we compute exact area). `07_opacity` exact is low because
large translucent areas differ by 1 level from rounding in premultiply /
unpremultiply; within-8 is 99.8%.

Render time per 200×200 file: 28–43 ms including process start.

## 5. File map

| file | role |
|---|---|
| `MicroSvg/Effect.lean` | `Op`, `Prog`, model FS, theorems, `execIO` (trusted) |
| `MicroSvg/Bytes.lean` | byte scanning helpers, all bounded |
| `MicroSvg/Fixed.lean` | `Fx`, number and length parsing with cost bounds |
| `MicroSvg/Geom.lean` | `Pt`, `Mat`, trig, `PathCmd`, `flatten`, stroker |
| `MicroSvg/Raster.lean` | accumulation rasterizer → coverage mask |
| `MicroSvg/Canvas.lean` | premultiplied canvas, blending, RGBA export |
| `MicroSvg/Png.lean` | CRC-32, Adler-32, stored zlib, PNG chunks |
| `MicroSvg/Xml.lean` | event-based XML subset parser with caps |
| `MicroSvg/Svg.lean` | paints, transforms, path data, shapes, style stack |
| `MicroSvg/Render.lean` | `Options`, caps, `canvasSetup`, `drawShape`, `render` |
| `Main.lean` | CLI (trusted shell) |
| `tests/svg/` | fidelity corpus; `tests/adversarial/` hostile inputs |
