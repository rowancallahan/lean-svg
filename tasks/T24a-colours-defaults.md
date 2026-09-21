# T24a — All CSS named colours, `color`/`currentColor`, default image size  [Sonnet]

Three mechanical items from FEATURES F8, each checkable by the build and a
script. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T24a`
(branch `t24a-basics`). Files: `LeanSvg/Svg.lean` (only the `namedColors`
list, `parsePaint`, the `color` property in `applyProp`/`Style`) and
`LeanSvg/Render.lean` (only `canvasSetup`'s size fallback). Other agents
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
  binary (`/Users/rowancallahan/pdf_renderer/.lake/build/bin/lean-svg`),
  except none should change at all; report.
- Corpora: `python3 tests/run_corpora.py --corpus resvg --route direct
  --dir painting/color --dir structure/svg` before/after (copy the script
  with an output-dir override if `--out/--dir` are missing); report pass
  counts. `painting/color` should go from 1/4 to 4/4.
- `python3 tests/run_adversarial.py` clean; `git diff main -- LeanSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.

## Report

Files changed:

- `LeanSvg/Svg.lean` — `namedColors` replaced with the full 148-entry CSS
  Color Level 4 table (extended keywords + `rebeccapurple`, no
  `transparent`); added `PaintSpec` (`none | solid c | currentColor`) as
  `parsePaint`'s return type, with `currentcolor` now a distinct marker
  instead of hard-coded black; added `Style.color : Rgba` (default black);
  added `resolvePaint`/`parseColor`; `applyProp` gained a `"color"` case and
  `"fill"`/`"stroke"` now resolve `PaintSpec` through `resolvePaint st`;
  `applyAttrs` now resolves `color` (style wins over the presentation
  attribute, matching the existing CSS-wins rule) *before* folding in every
  other property, so `currentColor` always sees the element's own final
  `color` regardless of attribute order.
- `LeanSvg/Render.lean` — `canvasSetup` gained a `none, none, none => pure
  (Fx.ofNat 100, Fx.ofNat 100)` arm (100×100 px default, matching usvg's
  `Size::from_wh(100.0, 100.0)` in `resolve_svg_size`/`Options::default_size`);
  the non-positive-size check right after is unchanged, so negative/zero
  sizes still fail.
- `tests/check_colors.py` — new script; regexes `("name", 0xRRGGBB)` pairs
  out of `namedColors` and diffs them against `PIL.ImageColor.colormap`.

Verification:

1. **`lake build`** — clean, no errors, no new warnings (26/26 jobs).

2. **Named colours** — `python3 tests/check_colors.py`:
   ```
   OK: 148/148 Pillow names present with matching values
   ```
   No missing names, no value mismatches, `transparent` confirmed absent
   from the list (it stays a `parsePaint`-only special case). Manually
   spot-checked case-insensitivity (`fill="RED"`, `fill="ReBeccaPurple"`)
   against `resvg` — matches on `RED`; the installed `resvg` 0.48.1 itself
   fails to parse `rebeccapurple` in *any* case ("Fallback to black"), which
   is exactly why the task specifies Pillow, not resvg, as the oracle for
   this item.

3. **Byte-identity vs main** — no built-in script does a binary-vs-binary
   byte diff, so I wrote one (ad hoc, `run` from the worktree, not
   committed) that renders all 21 `tests/svg/*.svg` with both
   `.lake/build/bin/lean-svg` (this worktree) and
   `/Users/rowancallahan/pdf_renderer/.lake/build/bin/lean-svg` (main) and
   compares PNG bytes:
   - natural size: **21/21 identical**
   - `--width 800`: **21/21 identical**
   None of the 21 built-in tests exercise `color`/`currentColor` or the
   missing-size fallback, so this is expected and confirms no regression.
   (`python3 tests/run_tests.py` also still reports the same 17/21 vs.
   resvg as main, tol=8/threshold=0.99 — the same 4 pre-existing
   non-regressions: `12_badge`, `14_flower_transforms`, `15_spiral_stroke`,
   `16_stress_2000`.)

4. **Corpora** — `tests/run_corpora.py` has no `--dir`/`--out`, so I copied
   it (scratch dir, not committed) adding both flags (`--dir` filters to
   files whose corpus-relative path starts with the given prefix, OR'd;
   `--out` redirects CSV/worst output away from the shared `tests/out/`).
   Ran `--corpus resvg --route direct --dir painting/color --dir
   structure/svg` with `--bin` pointing at main's binary (before) and this
   worktree's (after):

   | dir | before | after |
   |---|---|---|
   | painting/color | 1/4 | **3/4** |
   | structure/svg | 6/42 | 6/42 (no regression) |

   `painting/color` detail: `simple-case.svg` (`fill="currentColor"
   color="green"`) and `inherit.svg` (`<g color="green"><rect
   fill="currentColor" color="inherit"/></g>`) now pass exactly (both were
   failing before — currentColor resolved to hard-coded black).
   `recursive-nested-context-without-color.svg` already passed (no visible
   paint either way). `recursive-nested-context.svg` still fails: verified
   against a fresh `resvg -w 200` render that it needs actual `<use>` +
   `context-fill`/`context-stroke` resolution (dominant colours in the
   reference are solid green fill / blue stroke, confirming resvg resolves
   the nested `<use>` chain) — `<use>` is a reference kind this renderer
   deliberately never follows (see `Svg.lean`'s module doc), and touching it
   is out of scope for this task's three items, so **painting/color lands
   at 3/4, not the 4/4 the task predicted**. Flagging this as the one
   "could not do."
   `structure/svg`: `no-size.svg` moved from a hard error
   (`unsupported`/`cannot determine image size`) to rendering at the
   correct 200×200 output size, but still scores `fail` on pixel fidelity —
   confirmed against `crates/usvg/src/parser/converter.rs` that real usvg
   additionally re-fits the *reported* document size to the content's
   bounding box (`calculate_svg_bbox`, triggered by its `restore_viewbox`
   path) whenever width/height/viewBox are all absent, rather than staying
   at the flat 100×100 the task asks for; implementing that bbox-refit is a
   separate, larger feature and out of scope here. `negative-size.svg` and
   `zero-size.svg` are unaffected (both still fail with "image size must be
   positive"; resvg itself also fails on them, so they show as
   `ref_failed` in the corpus run either way).

5. **Adversarial** — `python3 tests/run_adversarial.py`: **38/38 clean, 0
   violations**.

6. **`git diff main -- LeanSvg/Effect.lean`** — empty.

What I could not do:

- `painting/color/recursive-nested-context.svg` does not pass; it needs
  `<use>`/`context-fill`/`context-stroke` support, which is out of scope
  for this task's three items (and for this renderer's stated design —
  `Svg.lean`'s module doc: "There is no code that follows a reference of
  any kind"). Confirmed via a fresh `resvg` render that this is genuinely
  what the file exercises, not something the `color`/`currentColor` work
  could incidentally fix.
- `structure/svg/no-size.svg` renders at the right size but isn't
  pixel-exact against resvg, because resvg's actual fallback additionally
  refits the document's reported size to the content bounding box; the
  task's literal ask (100×100, cited from usvg's own default) is
  implemented as specified, but that extra refit step is a separate,
  larger feature left undone.
