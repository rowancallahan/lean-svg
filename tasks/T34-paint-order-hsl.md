# T34 — `paint-order` and `hsl()/hsla()/rgba()` colours  [Sonnet]

Two small painting items (PLAN C18, C03). Work ONLY in
`/Users/rowancallahan/pdf_renderer/.worktrees/T34` (branch `t34-paint-order`).
Files: `MicroSvg/Svg.lean` (`Style` one new field, `applyProp` one case, the
colour parser used by `parsePaint`) and `MicroSvg/Render.lean` (`drawShape`
order only). Two Opus agents are editing `interpret`, `Paint`, `parsePaint`'s
`url()` handling and `drawShape`'s paint plumbing in parallel: keep each edit
to a few lines in place so merges are trivial. Invariants in `tasks/README.md`.

1. **`paint-order`** (presentation attribute and style property): values
   `normal` | any order of `fill`, `stroke`, `markers` (missing ones appended
   in default order). We have no markers, so the only effect is: when
   `stroke` precedes `fill`, draw the stroke first, then the fill. Inherited.
   Check usvg `crates/usvg/src/parser/style.rs` for how it parses the value.
2. **Colour notation**: `rgb(r,g,b)`, `rgba(r,g,b,a)` (a as 0–1 or %),
   `hsl(h, s%, l%)`, `hsla(...)`, including the CSS Color 4 space-separated
   forms (`rgb(255 0 0 / 50%)`, `hsl(120deg 100% 50%)`) if the `svgtypes`
   crate (used by usvg) accepts them — match `svgtypes`' `Color` parser
   exactly, fixed point only (HSL→RGB with integer arithmetic, rounding as
   `svgtypes` does: check its `hsl_to_rgb` and `f64→u8` conversion, and
   report the exact rounding you matched). The alpha from `rgba`/`hsla`
   multiplies into the paint's opacity the way usvg does (it folds it into
   `fill-opacity`; confirm).

## Verify

- `lake build` clean.
- Corpora before/after at fast sizes, direct route, `--compare`:
  `--dir painting/paint-order --dir painting/fill --dir painting/color`.
  Targets: paint-order ≥ 10/14 (the rest need markers: list them);
  painting/fill: every file whose only issue was `hsl`/`rgba` notation now
  passes (list them); nothing regresses.
- A Python check `tests/check_hsl.py`: 2 000 random `hsl()`/`rgba()` strings
  rendered as a solid `<rect>` by both microsvg and resvg at 4×4 px, centre
  pixel equal (exact); report the count.
- `python3 tests/run_tests.py` all 23 byte-identical to main's binary;
  `run_adversarial.py` clean; `git diff main -- MicroSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.
