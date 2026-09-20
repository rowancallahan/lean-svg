# T24a — All CSS named colours, `color`/`currentColor`, default image size  [Sonnet]

Three mechanical items from FEATURES F8, each checkable by the build and a
script. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T24a`
(branch `t24a-basics`). Files: `MicroSvg/Svg.lean` (only the `namedColors`
list, `parsePaint`, the `color` property in `applyProp`/`Style`) and
`MicroSvg/Render.lean` (only `canvasSetup`'s size fallback). Other agents
are editing `parsePathData` (T16) and `drawShape` (T23): do not touch
those functions. Invariants in `tasks/README.md`.

1. **Named colours.** Replace `namedColors` with the complete CSS Color
   Level 4 list (148 names incl. `rebeccapurple`; `transparent` stays a
   special case). Verify with Python: Pillow's `PIL.ImageColor.colormap`
   has every name → hex; write a script `tests/check_colors.py` that
   extracts the Lean list by regex and asserts every Pillow name is present
   with the same value (and reports extras). Lookup must stay
   case-insensitive (`lower` is already applied).
2. **`color` and `currentColor`.** Add `color : Rgba` to `Style`
   (inherited, default black); `applyProp "color"` parses a colour (not
   `none`/`url`); `parsePaint` must return a marker for `currentcolor` that
   `applyProp "fill"`/`"stroke"` resolve to the *current* `color` at apply
   time (order matters: resolve against the style after the element's own
   `color` attribute has been applied; usvg resolves `currentColor` with the
   element's own `color`, inherited if absent). Also `stroke`/`fill` set
   before a later `color` on the same element: follow SVG (the `color` on
   the same element applies), i.e. apply `color` first, then paints.
3. **Default size.** In `Render.canvasSetup`, when neither `width`/`height`
   nor a usable `viewBox` exists, use 100×100 px (resvg's behaviour; check
   `usvg` if unsure: `crates/usvg/src/parser/converter.rs`, default
   `Size::from_wh(100.0, 100.0)`), instead of failing. Keep failing for
   non-positive sizes.

## Verify

- `lake build` clean.
- `python3 tests/check_colors.py` passes.
- `python3 tests/run_tests.py`: all 21 files byte-identical to main's
  binary (`/Users/rowancallahan/pdf_renderer/.lake/build/bin/microsvg`),
  except none should change at all; report.
- Corpora: `python3 tests/run_corpora.py --corpus resvg --route direct
  --dir painting/color --dir structure/svg` before/after (copy the script
  with an output-dir override if `--out/--dir` are missing); report pass
  counts. `painting/color` should go from 1/4 to 4/4.
- `python3 tests/run_adversarial.py` clean; `git diff main -- MicroSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.
