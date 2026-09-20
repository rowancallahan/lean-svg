# T24b — `transform-origin`, percent lengths on the root  [Sonnet]

Two F8 items. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T24b`
(branch `t24b-transform-origin`). Files: `MicroSvg/Svg.lean` (`Style`,
`applyProp`, `applyAttrs`, and the place where an element's `transform` is
composed into `ctm`), `MicroSvg/Render.lean` (`canvasSetup` only). Do not
touch `interpret` (T27/T29 are editing it), `parsePathData`, the flatten
section of `Geom.lean` (T30), `drawShape` (T23). Invariants in
`tasks/README.md`.

1. **`transform-origin`** (presentation attribute and `style` property).
   Value: one or two lengths/percentages/keywords (`left|center|right`,
   `top|center|bottom`; one value → second is `center`). Percentages are
   relative to the element's *bounding box* in SVG 2, but usvg resolves
   them against the **viewport** for the root and uses the bounding box
   for others; read `crates/usvg/src/parser/converter.rs` (grep
   `transform-origin` / `TransformOrigin`) and match it exactly, including
   which elements it applies to and the composition order
   `translate(ox,oy) · transform · translate(-ox,-oy)`. If usvg needs the
   object bounding box for percentages and we cannot compute it at parse
   time, implement lengths and keywords fully and percentages only where
   usvg uses the viewport; report what is left.
2. **Percent lengths on the root** `width`/`height` (`structure/svg`):
   usvg resolves a percentage root size against the `viewBox` when present
   (e.g. `width="50%"` with `viewBox="0 0 200 100"` → 100 px) and against
   the 100×100 default otherwise; check `crates/usvg/src/parser/converter.rs`
   (`get_svg_size` / `Units`) and match it. Keep failing for non-positive results.

## Verify

- `lake build` clean.
- Before/after at fast sizes with `--compare` (the *before* from the main
  binary `/Users/rowancallahan/pdf_renderer/.lake/build/bin/microsvg`,
  copied to scratch first):
  ```
  python3 tests/run_corpora.py --fast --no-worst --corpus resvg --route direct \
    --dir structure/transform-origin --dir structure/svg --dir structure/transform --out <scratch>/before
  ```
  Targets: `structure/transform-origin` to ≥ 80% of its files (report the
  exact count); `structure/svg` up by every file that failed only for a
  percent size (list them); `structure/transform` unchanged. One line per
  remaining failure in the first two directories.
- `python3 tests/run_tests.py`: all 22 byte-identical to the main binary.
- `python3 tests/run_adversarial.py` clean; `git diff main -- MicroSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.
