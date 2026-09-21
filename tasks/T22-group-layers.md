# T22 — Group opacity as a compositing layer; `mix-blend-mode`; `isolation`  [Opus]

PLAN C12, C29. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T22`
(branch `t22-layers`). Files: `MicroSvg/Svg.lean` (`Doc` gains group
begin/end nodes carrying opacity, blend mode and isolation instead of folding
group `opacity` into children — `interpret` emits them), `MicroSvg/Render.lean`
(`renderRgba`/`renderBands`: a bounded layer stack), `MicroSvg/Canvas.lean`
(layer allocation, composite-with-opacity, blend modes). Invariants in
`tasks/README.md`; `Effect.lean` untouched; `render`'s type unchanged.

## Behaviour (usvg `crates/usvg/src/parser/converter.rs` group conversion
and resvg `crates/resvg/src/render.rs`; tiny-skia `src/blend_mode.rs` and the
pipeline blend stages)

- A `g` (or any container) with `opacity < 1`, or a `mix-blend-mode` other
  than normal, or `isolation: isolate`, becomes a layer: children render
  into a fresh transparent canvas covering the group's device bounding box
  (∩ canvas/band), then the layer is composited onto the parent with the
  group opacity and the blend mode. usvg also creates a layer for
  `clip-path`/`mask`/`filter` on a group — leave hooks for T20/T21 (a layer
  with a post-multiply mask) but do not implement clip/mask here. Shapes
  keep the existing per-shape opacity path (byte-identical when no layer is
  involved).
- Blend modes: all 16 CSS modes as tiny-skia implements them on
  premultiplied u8 (separable: multiply, screen, overlay, darken, lighten,
  color-dodge, color-burn, hard-light, soft-light, difference, exclusion;
  non-separable: hue, saturation, color, luminosity). Match tiny-skia's
  lowp/highp choice for each: report which path resvg actually takes for
  8-bit canvases and port that one exactly (integer only). `isolation`
  affects only whether a new backdrop starts.
- **Bounds**: nesting depth ≤ 10 (deeper groups: opacity/blend applied as a
  plain group without a layer, i.e. degraded, and counted in a stats field
  if one exists; do not error); total live layer pixels ≤ 4 × `maxPixels`
  else `.error "layer budget"` (safe rejection). Layers are per band under
  `--threads N`, so bands stay independent and byte-identical to the
  single-thread result (compositing is per pixel).

## Verify

- `lake build` clean; `git diff main -- MicroSvg/Effect.lean` empty.
- New `tests/svg/26_layers.svg` (overlapping shapes under group opacity,
  nested groups, each blend mode on a coloured backdrop, isolation) ≥ 99%
  within 8 vs resvg.
- Corpora at fast sizes, direct route, `--compare`: `--dir painting/opacity
  --dir painting/mix-blend-mode --dir painting/isolation --dir structure/g`.
  Targets: opacity ≥ 8/9, mix-blend-mode ≥ 16/20, isolation 2/2.
- `run_tests.py`: 07_opacity and 08_group_inherit may change (report the
  before/after); all others byte-identical. `run_tiles.py` byte-identical
  incl. the new file; `--threads 4` byte-identical to `--threads 1` on the
  new file at 800 px; `run_adversarial.py` clean plus: 100 000 nested groups
  with opacity, a group opacity on a 16384×16384 canvas (must hit the budget
  cleanly), 10 000 sibling layers.
- Timing: 16_stress unchanged; report 26_layers at natural and 800 px.
- Commit (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.
