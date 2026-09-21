# T34 — `paint-order` and `hsl()/hsla()/rgba()` colours  [Sonnet]

Two small painting items (PLAN C18, C03). Work ONLY in
`/Users/rowancallahan/pdf_renderer/.worktrees/T34` (branch `t34-paint-order`).
Files: `LeanSvg/Svg.lean` (`Style` one new field, `applyProp` one case, the
colour parser used by `parsePaint`) and `LeanSvg/Render.lean` (`drawShape`
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
  rendered as a solid `<rect>` by both lean-svg and resvg at 4×4 px, centre
  pixel equal (exact); report the count.
- `python3 tests/run_tests.py` all 23 byte-identical to main's binary;
  `run_adversarial.py` clean; `git diff main -- LeanSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.

## Report

Branch `t34-paint-order`, main merged in first (`4172f64` → main `2a819ed`, no conflicts).
Oracle: resvg 0.48.1 (`cargo install`), which embeds svgtypes 0.16.1 and usvg 0.48.1;
every "svgtypes does X" claim below was checked against that crate source in the cargo
registry and against the compiled binary. Lean 4.34.0 (`release.lean-lang.org` is blocked
in this sandbox; the same tarball from the lean4 GitHub release was linked into elan).
The corpus in current `linebender/resvg` lives at `crates/resvg/tests`, not `tests`; the
`tests/corpora/resvg-test-suite` symlink points there.

### What changed

- `LeanSvg/Svg.lean`
  - `Style.strokeFirst : Bool` (inherited like every other paint property).
  - `applyProp "paint-order"` → `strokeBeforeFill`, a transcription of svgtypes
    `PaintOrder::from_str` (`src/paint_order.rs`): up to three idents, `normal` and any
    unknown ident → default, trailing data → default, missing kinds appended in
    `fill stroke markers` order, duplicates among the resolved three → default. usvg then
    reduces the triple to `StrokeAndFill` iff `stroke` precedes `fill`
    (`converter.rs: svg_paint_order_to_usvg`), which is the one bit stored.
  - `parsePaint`: `hsl(`/`hsla(` → `parseHslFunc`; `rgb(`/`rgba(` component parsing
    reworked (`compOf`, `compNumOnly`, `compIsPercent`, `alphaOf`) to match svgtypes
    0.16.1 exactly instead of approximately.
  - `hslToRgb`: svgtypes `hsl_to_rgb`/`hue_to_rgb` in exact integer arithmetic on the
    grid `60 · opacityOne`.
- `LeanSvg/Render.lean`: `drawShape` splits the fill and stroke passes into two closures
  and runs them stroke-first when `st.strokeFirst`. No other change.
- `tests/check_hsl.py`: new random oracle check (2 000 strings, 4×4 rect, centre pixel).

### Rounding matched (svgtypes 0.16.1 `src/color.rs`)

- `rgb()/rgba()` mode is chosen by the *red* component alone. Percent mode: every
  component is `parse_number_or_percent` then `(x · 255).round() as u8`, so a plain
  number there is multiplied by 255 (`rgb(50%, 2, 0)` → green 255). Plain mode: green
  and blue must be plain numbers (`rgb(0, 50%, 0)` is invalid → fill falls back to
  black); value is `x.round() as u8`. `as u8` saturates both ways, so negatives → 0 and
  > 255 → 255. Percent rounding is done in one division on the 1/256 grid as
  `(v·255 + 12800) / 25600` (halves up), which fixes main's two-step floor
  (`18.4%` → 47, main gave 46).
- Alpha (4th argument of all four functions) is `parse_number` only, `(a · 255).round()
  as u8`; a `%` suffix is invalid in 0.16.1 (`rgba(0,127,0,50%)` → black), and negatives
  → 0. usvg then `split_alpha()`s it back to `a/255` and multiplies it into
  `fill-opacity` / `stroke-opacity` (`style.rs:193-253`); we do the same via
  `opacityToU8 c.a fillOp groupOp`. Oracle-confirmed exact with `fill-opacity`,
  `stroke-opacity` and `opacity` stacked on top.
- HSL: hue is a plain number (no `deg`/`grad`/`turn` in 0.16.1; those make the whole
  colour invalid → black, and we match that), reduced with a true modulus into
  `[0, 360)`; saturation/lightness are number-or-percent clamped to `[0, 1]`
  (`f64_bound`). `hsl_to_rgb` runs in `f32`; here every intermediate is an exact
  rational over `60·opacityOne` with `hueRound` (nearest, halves away from zero, the
  same as `f32::round`) for the seven divisions and the final `(x·255).round() as u8`.
  No divergence from the `f32` path was observed in 2 000 + 800 samples.
- CSS Color 4 space-separated lists work because svgtypes' list separator is optional
  (`rgb(255 0 0)`, `hsl(120 100% 50%)`), but the `/ alpha` slash and angle units are
  *not* accepted by 0.16.1, so `rgb(255 0 0 / 50%)` and `hsl(120deg 100% 50%)` are
  invalid on both sides (fill → black, stroke → none). Both oracle-checked exact.

### Verify

- `lake build`: clean, no warnings.
- `python3 tests/check_hsl.py 2000` (seed 1): **OK: 2000/2000 exact**.
- Corpora, direct route, `--fast` (width 100), `--dir painting/paint-order --dir painting/fill --dir painting/color`, `--compare` against main's binary:
  78 files, pass 48 → **56**, newly passing 8, newly failing 0, unchanged 66.
  - `painting/fill`, now passing (all were 36.0% within-8, now 100%):
    `hsl-120-100percent-25percent`, `hsl-120-200percent-25percent`,
    `hsl-360-100percent-25percent`, `hsl-999-100percent-25percent`, `hsl-with-alpha`,
    `hsla-with-percentage-s-and-l-values`, `rgba-0-127-0-50percent`,
    `rgba-0-50percent-0-0.5`. Still failing, none for colour notation:
    `funcIRI-*` / `*-FuncIRI-*` (6, `url()` + fallback), `linear-gradient-on-shape`,
    `radial-gradient-on-shape`, `pattern-on-shape`; `painting/color/recursive-nested-context`.
  - `painting/paint-order`: 2/14 → 2/14 pass at the 99 % threshold. The ≥ 10/14 target is
    not reachable: **all 12 non-text files use `marker-start/mid/end`** (`duplicates`,
    `fill`, `fill-markers-stroke`, `invalid`, `markers`, `markers-stroke`, `normal`,
    `stroke`, `stroke-invalid`, `stroke-markers`, `stroke-markers-fill`, `trailing-data`);
    only `on-text` and `on-tspan` are marker-free and both pass. The four files whose order
    puts stroke first moved 90.4–91.2 % → 96.0–97.4 % within-8 (the remaining diff is the
    marker squares). Substitute measurement: the same 14 files with the three `marker-*`
    attributes stripped, at width 200, vs resvg on the stripped file: main's binary
    10/14, this branch **14/14, all 100 % within-8** (`stroke`, `markers-stroke`,
    `stroke-markers`, `stroke-markers-fill` go 95.29 % → 100 %).
  - Ad-hoc oracle cases, all 100 % exact: `paint-order` inherited from `<g>`, overridden
    back to `normal` on the child, set via `style=""`, set via a `<style>` rule,
    `paint-order="markers"` alone (fill still first).
- `python3 tests/run_tests.py`: 19/23 vs resvg, same as main; all 23 outputs
  byte-identical to main's binary at natural size and at `--width 800` (46/46 PNGs `cmp`).
- `python3 tests/run_adversarial.py`: 42/42 clean.
- `git diff main -- LeanSvg/Effect.lean`: empty.

### Not done / caveats

- The 10/14 paint-order corpus target needs markers (out of scope); see above.
- Mixed separators inside one list (`rgb(1, 2 3)`) are accepted by svgtypes and rejected
  here (the parser splits on comma, or on space only when there is no comma); the
  generator does not produce them and no corpus file uses them.
