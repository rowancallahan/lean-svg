# T18 — Local defs table + linear/radial gradients  [Opus]

FEATURES F3 + PLAN C20/C21/C22/C23/C24. Work ONLY in
`/Users/rowancallahan/pdf_renderer/.worktrees/T18` (branch `t18-gradients`).
Files: `MicroSvg/Svg.lean` (a defs pre-pass in `interpret`, `Paint`,
`parsePaint`, `Style`), a new `MicroSvg/Shader.lean` (gradient evaluation,
pure), `MicroSvg/Canvas.lean` (`fillMask` gains a per-pixel paint source; keep
the solid-colour fast path byte-identical), `MicroSvg/Render.lean`
(`drawShape` passes the paint). Another Opus agent (T36 text) is adding a
`text` branch to `interpret` and font fields to `Style`; a Sonnet agent (T34)
is adding `paint-order` to `drawShape` and `hsl()` to `parsePaint`. Keep your
edits in those functions local (a pre-pass, one new `match` arm, one new
`Paint` constructor) so a merge task can resolve them. Invariants in
`tasks/README.md`; `Effect.lean` untouched; `render`'s type unchanged; no
`partial`; no `Float`; every loop bounded. You may spawn Sonnet subagents for
mechanical sub-steps (test SVG generation, corpora runs, a Python oracle for
the gradient colour ramp) but keep the numeric design and the Lean in your
hands.

## Behaviour (match usvg/resvg; read `crates/usvg/src/parser/paint_server.rs`
and tiny-skia `src/shaders/{gradient,linear_gradient,radial_gradient}.rs`,
`src/pipeline/` gradient stages — shallow-clone both into scratch)

- **Defs table**: a bounded pre-pass over the event array collecting
  `linearGradient` / `radialGradient` elements by `id` (≤ 4096 entries, ≤ 256
  stops each, ids ≤ 256 bytes), wherever they appear (not only under `defs`).
  `href`/`xlink:href` inheritance of attributes and stops with fuel 8 and
  cycle-safe (a self or cyclic reference resolves as far as the fuel allows,
  as usvg does: it stops at the cycle). Only gradients are resolved in this
  task; the table shape should let T20/T21 (clipPath/mask) and T19 (use) add
  entries later — document it in the module doc.
- **Paint**: `parsePaint` accepts `url(#id)` with an optional fallback
  (`url(#id) red` / `none`); an unresolvable id uses the fallback, else
  `none` (usvg). New `Paint.gradient` referencing the table entry by index.
- **Gradient semantics**: `gradientUnits` objectBoundingBox (default) vs
  userSpaceOnUse; `gradientTransform`; `x1 y1 x2 y2` defaults (0 0 100% 0);
  `cx cy r fx fy fr` defaults (50% 50% 50%, fx=cx, fy=cy, fr=0); `spreadMethod`
  pad / reflect / repeat; stop `offset` (number or %, clamped, monotone as
  in usvg), `stop-color`, `stop-opacity` (and `style` on stops); zero stops →
  none, one stop → solid. Zero-length vector or zero radius → last stop
  colour (usvg's rules). objectBoundingBox uses the shape's **user-space**
  bounding box the way usvg computes it (check `bounding_box` /
  `object_bounding_box` in usvg: control-point vs tight bounds — match it);
  a bbox with zero width or height means the paint is `none`.
- **Evaluation**: per pixel in device space through the inverse of
  `ctm · bboxTransform · gradientTransform`, `t` in 16.16, colour ramp with
  the same interpolation and premultiplication order as tiny-skia
  (check whether it interpolates premultiplied or unpremultiplied and where
  it rounds); radial = two-point conical when focal ≠ centre (tiny-skia
  `RadialGradient` / `TwoPointConicalGradient`); `Nat.sqrt` on fixed point.
  The coverage mask pipeline stays as is: coverage × paint alpha, then the
  existing blend. Tiles must stay byte-identical (evaluate in absolute
  device coordinates, never tile-relative).

## Verify

- `lake build` clean. `git diff main -- MicroSvg/Effect.lean` empty.
- New `tests/svg/24_gradients.svg` (linear + radial, both unit systems, a
  transform, all three spreads, stop-opacity, a focal radial, a `url()` with
  fallback, an unresolved reference) — target ≥ 99% within 8 vs resvg.
- Corpora before/after at fast sizes, direct route, with `--compare`:
  `--dir paint-servers/linearGradient --dir paint-servers/radialGradient
  --dir paint-servers/stop --dir paint-servers/stop-color --dir paint-servers/stop-opacity
  --dir painting/fill --dir structure/defs`. Targets: linearGradient ≥ 28/38,
  radialGradient ≥ 30/45, stop ≥ 24/32; one line per remaining failure.
- `python3 tests/run_tests.py`: all 23 existing files byte-identical to main's
  binary (copy it to scratch first). `run_tiles.py` byte-identical including
  the new file. `run_adversarial.py` clean, plus new cases: 100 000 stops,
  4 096+1 gradients, `href` self-cycle and a 9-deep chain, a radius of 1e9,
  a gradient on a zero-area shape.
- Timing: 16_stress unchanged within noise; report ms for 24_gradients at
  natural size and `--width 800`.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.

## Report

Branch `t18-gradients`, merged with `main` at 2a819ed (T31 edge rounding, T32
gallery) before verification.  Started from the local agent's WIP commit
0cdc7f2, which already built; this session verified it against the spec,
fixed nothing in the Lean, and ran every item under `## Verify`.

### What changed

- `MicroSvg/Shader.lean` (new, 937 lines): the defs table (`Grad.RawDef`,
  `Grad.Defs.build`, hashed id lookup, `href` chain with fuel 8 that stops at
  a revisited node), usvg's resolution rules (`Grad.resolve`: same-type
  coordinate inheritance, common-attribute inheritance, monotone stops,
  `userSpaceOnUse` percentages against the root viewBox, the degenerate
  cases that collapse to first/last/average colour), the tight user-space
  bounding box (`Grad.tightBox`, cubic and quadratic extrema solved
  exactly), one composed 16.16 affine map inverted once per draw
  (`Grad.Aff`), the per-pixel evaluation (`Grad.paramAt`: linear, radial and
  two-point conical via `Nat.sqrt`; `spreadT` pad/reflect/repeat; `rampAt`
  with tiny-skia's `lowp` order: unpremultiplied lerp, `round(c·255)`, then
  `div255` premultiply), and `Canvas.fillMaskShader`.  The module doc
  records how T19/T20/T21 can add entry kinds to the table.
- `MicroSvg/Svg.lean`: `Paint.gradient idx`; `PaintSpec.url id fallback`;
  `parsePaint` split into `parseSolidColor` + `parseUrlPaint` (quoted ids,
  `none` / colour / `currentColor` fallbacks); `resolvePaint` looks the id
  up in `Style.defs`; a bounded pre-pass (`gradRawDefs`, `gradPctRef`) in
  `interpret` that builds the table once and hands it to the root `Style`.
  `interpret` itself changed by four lines.
- `MicroSvg/Render.lean`: `Clip` carries the `--viewport` origin;
  `drawShape` routes fill and stroke through one `paintMask` helper that
  calls `Grad.build` for `.gradient`; solid paints take the unchanged
  `fillMask` path.  `render`'s type is unchanged.
- `MicroSvg/Canvas.lean` untouched: the shader blitter lives in
  `Shader.lean` as `Canvas.fillMaskShader`, so the solid fast path is
  byte-identical by construction and the file stays free for T22/T20.
- `tests/svg/24_gradients.svg` (new), `tests/run_adversarial.py` (+6 cases).
- `MicroSvg/Effect.lean`: `git diff main -- MicroSvg/Effect.lean` is empty.

### Verify

- `lake build`: clean, no warnings (forced rebuild of the three touched
  modules).
- `24_gradients.svg` vs resvg 0.48.1: 99.993% within 8, 92.145% exact,
  max delta 16 (target ≥ 99%).
- Corpora, `--fast` (width 100), direct route, main's binary → this branch:

  | directory | before | after |
  |---|---|---|
  | paint-servers/linearGradient | 5/40 | 39/40 |
  | paint-servers/radialGradient | 2/45 | 44/45 |
  | paint-servers/stop | 0/32 | 31/32 |
  | paint-servers/stop-color | 0/1 | 1/1 |
  | paint-servers/stop-opacity | 0/2 | 2/2 |
  | painting/fill | 43/60 | 51/60 |
  | structure/defs | 2/7 | 6/7 |

  Nothing newly fails.  The suite in the current resvg checkout has 40/45/32
  files in the three gradient directories (the spec's 38 was an older
  count).  Re-run at `--width 300`: same pass set, every passing file
  ≥ 99.95% within 8.  Remaining failures, one line each:
  - `linearGradient/hsla-color`, `radialGradient/hsla-color`,
    `stop/hsla-color`: `hsla()` stop colours, T34's `parsePaint` change.
  - `painting/fill/hsl-*` (6 files), `hsla-with-percentage-s-and-l-values`:
    `hsl()`/`hsla()` fill colours, T34.
  - `painting/fill/rgba-0-127-0-50percent`, `rgba-0-50percent-0-0.5`:
    percentage channels in `rgba()`, pre-existing on main.
  - `painting/fill/pattern-on-shape`: `<pattern>`, out of scope.
  - `structure/defs/style-inheritance`: `<use>`, T19.
- `python3 tests/run_tests.py`: 20/24 pass; the 4 failures (12, 14, 15, 16)
  are main's.  All 23 pre-existing files are byte-identical to main's
  binary at natural size and `--width 800` (`cmp` on the PNGs).
- `run_tiles.py`: 24/24 stitch byte-identically, including `24_gradients`.
  `--threads 4` on `24_gradients` at 800 px is byte-identical to serial.
- `run_adversarial.py`: 50/50 clean, including the six new cases
  (`grad_100k_stops`, `grad_4097_defs`, `grad_href_self_cycle`,
  `grad_href_chain_9`, `grad_huge_radius`, `grad_zero_area_shape`).  Against
  resvg, the self-cycle and zero-area cases are pixel-exact; the other four
  differ where the spec's caps bite (256 stops kept of 100 000, entry 4097
  dropped so the fallback colour shows, a 9-link chain exceeds fuel 8 so the
  paint is `none`, and coordinates of 1e9 clamp at `Fx.maxVal`).
- Timing, median of 3, this machine:

  | file | main | branch |
  |---|---|---|
  | 16_stress natural | 232 ms | 238 ms |
  | 16_stress `--width 800` | 793 ms | 797 ms |
  | 16_stress `--width 1600` | 2581 ms | 2565 ms |
  | 24_gradients natural (360×240) | — | 41 ms |
  | 24_gradients `--width 800` | — | 199 ms |

### Not done / deviations

- No Python oracle for the colour ramp was written; the corpus and the
  side-by-side composites were sufficient to confirm the `lowp` model.
- A focal (two-point conical) radial uses the same `lowp` ramp as the rest;
  tiny-skia switches to `highp` there.  Differences are within tolerance
  on every focal test in the suite.
- `drawShape`'s fill and stroke arms now go through a shared `paintMask`
  closure rather than one added `match` arm each, so T34's `paint-order`
  edit will touch the same lines; the closure is self-contained and the
  order of the two blocks is unchanged.
