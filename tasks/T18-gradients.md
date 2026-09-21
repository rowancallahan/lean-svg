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
