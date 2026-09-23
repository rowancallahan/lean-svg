# T56 — vertical text (`writing-mode`)  (branch `claude/feat-writing-mode`)

Implement `writing-mode` (`tb`, `tb-rl`, `vertical-rl`, `vertical-lr`, and
the `lr`/`rl` aliases) and the related `glyph-orientation-vertical`/
`-horizontal` and `text-orientation` behaviour as usvg 0.48.1 does
(`crates/usvg/src/text/*`, search `writing_mode`, `is_vertical`, upright vs
rotated glyphs). Target: `text/writing-mode` (16/23 failing) plus the
`glyph-orientation-*` and `direction` files if they fall out. Vertical
metrics: use whatever usvg uses (vhea/vmtx if present, else its fallback —
Noto Sans subsets probably lack vmtx, so the fallback path matters).

Other agents are concurrently working in `Text.lean` (T54 baselines, T55
misc, T50 textPath). Keep your changes isolated (new functions, one branch
point in layout) so the integrator can merge.

---

## Common rules (every lean-svg agent)

You are one of ~15 agents working in parallel on lean-svg, a total, float-free
SVG→PNG renderer in Lean 4 whose output is compared against resvg 0.48.1.
An integrator merges all branches afterwards, so **keep your diff small and
local**: prefer new functions/new modules (`LeanSvg/<Feature>.lean`, imported
from `LeanSvg.lean`) over rewriting shared code in `Svg.lean` / `Render.lean`.
No drive-by refactors, renames or reformatting of code you do not need.

**Setup (first thing):** `bash scripts/cloud-setup.sh` then
`export PATH=$HOME/.elan/bin:$PATH`. It installs Lean from the GitHub release,
resvg/usvg 0.48.1, numpy/pillow and the resvg test suite under
`tests/corpora/resvg-test-suite`, and builds. Read `tasks/README.md`,
`DESIGN.md` and the relevant parts of `SPEC.md` before editing.

**Invariants (hard, from tasks/README.md):** no `partial`, `unsafe`,
`@[extern]`, `panic!`, `!`-indexing, `Float`; loops over finite ranges or
structurally decreasing fuel; hot loops in `Nat`; no new build warnings;
`LeanSvg/Effect.lean` untouched unless your task is about it; no IO outside
`Effect.lean`. Code should fail loudly rather than silently: prefer
rejecting/asserting over swallowing errors, but a feature that is not
supported should degrade exactly as it does today (skip), not error.

**Reference behaviour:** match resvg/usvg 0.48.1. The Rust source is the spec
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`
into a scratch dir; `crates/usvg/src/parser/*` and `crates/resvg/src/*`).

**Baseline first, before any edit:**
```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/base --no-worst
python3 tests/run_tests.py
```

**Verification before you push (all must hold):**
1. `lake build` — no errors, no new warnings.
2. `bash scripts/check-theorems.sh` prints `theorems ok`. Note
   `proofs/SizeBound.lean` reasons about `render`; if your change breaks it,
   fix the proof, do not delete or weaken it.
3. Full corpus with delta table:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/NN_<feature>.svg` exercising the feature
   if it fits the local corpus style (pick an unused number; collisions with
   other agents are resolved by the integrator).

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.

## Report

### What was implemented

`writing-mode` resolves exactly as usvg 0.48.1's `convert_writing_mode`
does: a new `Style.writingMode : Bool` field (`LeanSvg/Svg.lean`), set by an
`applyProp` case on `"writing-mode"` — `true` for `tb`/`tb-rl`/
`vertical-rl`/`vertical-lr`, `false` for anything else including no
attribute at all, `lr-tb`/`lr`/`rl-tb`/`rl`/`horizontal-tb`, or an invalid
value (`invalid-value.svg`). Like every other text property it is a
plain inherited `Style` field, so a `<g writing-mode="tb">` ancestor works
(`inheritance.svg`); `Svg.textShapes` reads it exactly once, off the
`<text>` element's own resolved style, the same way usvg only ever consults
`text_node.ancestors()` (which starts at the `<text>` node itself, not its
`tspan` descendants) — so a `writing-mode` on a `tspan` has no effect
(`on-tspan.svg`, and the "stays vertical" `tspan` in the new local test).
Per usvg's own doc comment on `convert_writing_mode`, `vertical-lr` is not
distinguished from `vertical-rl`, nor `tb` from `tb-rl`: all four collapse
to the same boolean.

`LeanSvg/Text.lean`'s `layout` gains a `vertical : Bool` parameter (one new
function boundary, no rewritten control flow) threaded in from
`textStyle.writingMode`. usvg's own implementation lays a `TopToBottom`
chunk out *exactly* like a horizontal one (same anchor math, same
`dx`/`dy`/`rotate` per character) in a local frame where the pen still
advances along its own `x`, then rotates the whole chunk 90° about the
chunk's real anchor point (`layout.rs`'s `text_ts.pre_rotate_at(90.0, x,
y)`). This renderer computes each glyph's absolute position and rotation
directly (there is no intermediate `Transform` object to build and later
rotate — `glyphCmds` already takes one angle and one pen position), so the
90° is folded in at the point each glyph is placed rather than applied as a
separate pass:

* `dx`/`dy` swap axes when accumulating a chunk's running pen (`y -= dx; x
  += dy`, usvg's `resolve_clusters_positions_horizontal`) — local `x` stays
  the advance axis, local `y` the perpendicular one, regardless of which
  screen axis they end up on after the rotation;
* every glyph is shifted `(ascender + descender) / 2` along local `y`
  before the rotation — usvg's `apply_writing_mode` ("could not find a spec
  that explains this... how other applications are shifting the rotated
  characters"), using the span's own font's `hhea` ascender/descender
  (`LeanSvg/Font.lean` already parsed these; nothing else read them before
  this task) scaled by that glyph's font size, matching usvg's
  `font.ascent(font_size)`/`descent(font_size)`;
* the local point `(x, y)` a glyph would sit at in horizontal layout maps to
  `(chunkX - y, chunkY + x)` — `(x, y)` rotated 90° about the origin
  (`rotate(90)`: `x' = -y, y' = x`, same convention `glyphCmds`'s own
  rotation already uses) then translated by the chunk's real anchor;
  the glyph's own explicit `rotate` attribute additionally gets +90°
  composed in (two rotations in the same direction just add), which is what
  makes a Latin glyph appear sideways rather than merely repositioned;
* the running pen position that seeds the *next* chunk's fallback anchor
  (when it has no `x`/`y` of its own) carries over *swapped, not rotated*
  — `lastX := chunkX + y; lastY := chunkY + x` — because usvg's own
  `layout_text` does a plain `std::mem::swap` on the chunk's final pen
  position there rather than applying the same 90° every glyph gets. This
  is a real asymmetry in upstream usvg, not a simplification on this
  renderer's part; `tb-with-dx-on-second-tspan.svg` and the new local
  test's `A`/`B` chunk exercise exactly this path, which is why it matters
  to reproduce it exactly rather than "fix" it.

### What was skipped, and why

* **`Vertical_Orientation=Upright` glyphs** (usvg's `apply_writing_mode`
  counter-rotates a CJK-style character back to standing upright inside a
  vertical column, via the Unicode TR50 `Upright`/`Rotated`/`Tu`/`Tr`
  property looked up per codepoint). Not implemented: every codepoint the
  `unicode-vo` table lists as `Upright` is outside Basic Latin (its lowest
  entry is U+00A7), and the three embedded Noto Sans subsets are Latin-only
  — `Font.glyphId` never returns a real outline for a CJK codepoint, so no
  character this renderer can ever place reaches the `Upright` branch. Every
  glyph that *can* render behaves as `Rotated`, which is fully implemented.
  Adding a codepoint-range table with no character able to exercise it
  would be dead code against this task's "keep your diff small and local"
  rule. `japanese-with-tb.svg` and the CJK portions of
  `mixed-languages-with-tb*.svg`/`tb-and-punctuation.svg` are affected by
  this gap exactly as they already were before this task (no glyph, same as
  the existing font-fallback policy) — this is a pre-existing limitation,
  not a regression.
* **`glyph-orientation-horizontal`/`-vertical` and `text-orientation`.**
  Checked against usvg 0.48.1 source directly
  (`crates/usvg/src/parser/svgtree/{mod,names}.rs`): these three are
  recognised as valid/inheritable attribute names (so a document using them
  does not error) but are never read anywhere else in the crate — they have
  *zero* effect on usvg 0.48.1's own output. There is nothing to port; this
  renderer already ignores unrecognised attribute names via `applyProp`'s
  `_ => st` fallback, which is the same behaviour.
* **`text-decoration` (underline/overline/line-through).** Not implemented
  at all in this renderer, in either writing mode — a pre-existing gap, out
  of scope for this task. `mixed-languages-with-tb-and-underline.svg` and
  `tb-with-rotate-and-underline.svg` fail for this reason (and, for the
  first, missing Arabic/CJK glyph coverage too), independent of the
  writing-mode work itself.
* **Arabic (`arabic-with-rl.svg`, part of `mixed-languages-with-tb*.svg`)
  and BiDi reordering.** `writing-mode="rl"` is correctly *not* one of the
  vertical keywords (matches usvg exactly — its own doc comment notes only
  Batik treats `rl`/`rl-tb` specially, and usvg deliberately does not), so
  this file needed no writing-mode change at all; it still fails on
  missing Arabic glyph coverage (`font-family="Amiri"`, unsupported, falls
  back to Noto Sans) and the lack of BiDi reordering, both pre-existing
  and out of scope.
* **`tb-with-rotate.svg`/`tb-with-rotate-and-underline.svg`** are titled
  "(UB)" by the test suite itself (mixing an explicit per-character
  `rotate` with `writing-mode="tb"` is undefined behaviour); not a target.
* **`direction`** was not touched beyond what fell out for free:
  `text/direction/rtl-with-vertical-writing-mode.svg` now passes because it
  combines `writing-mode="tb"` with `direction: rtl` (unimplemented,
  pre-existing) on a chunk which this renderer already lays out
  left-to-right regardless of `direction` — the vertical-layout fix alone
  was enough for that particular file's pixels to line up.

### Verification

```
lake build                             # clean, no new warnings
bash scripts/check-theorems.sh         # theorems ok
python3 tests/run_tests.py             # 24/28 (was 23/27; new 28_writing_mode.svg passes at 99.94%)
python3 tests/run_adversarial.py       # 61/61 clean
python3 tests/run_tiles.py             # 27/27 byte-identical
```

`text/writing-mode` (target directory), before -> after:

```
pass 7/23 (30.4%) -> pass 16/23 (69.6%)   [matches the task's "16/23 failing" framing exactly]
newly passing: tb, tb-rl, vertical-rl, vertical-lr, inheritance,
  tb-with-alignment, tb-with-dx-on-tspan, tb-with-dx-on-second-tspan,
  tb-with-dy-on-second-tspan  (9 files, all Latin-only content)
newly failing: none
```

Still failing (all for the reasons above, unrelated to writing-mode
geometry): `arabic-with-rl`, `japanese-with-tb`, `mixed-languages-with-tb`,
`mixed-languages-with-tb-and-underline`, `tb-and-punctuation`,
`tb-with-rotate`, `tb-with-rotate-and-underline` — every one of these moved
in the direction of the reference (within-8 score up), just not across the
0.99 pass threshold; `japanese-with-tb` moved slightly the other way
(98.14% -> 96.52%, still fail before and after) because its CJK text is
still unrenderable but now also being placed by the vertical pen model
instead of the horizontal one it fell back to before.

Whole `resvg` corpus (`--route direct`), before -> after:

```
pass 835/1679 (49.7%) -> pass 846/1679 (50.4%)
newly passing (11): the 9 above, plus
  text/glyph-orientation-vertical/simple-case.svg,
  text/direction/rtl-with-vertical-writing-mode.svg
newly failing: none (zero files moved pass -> fail)
```

One already-passing file moved (`text/textPath/complex.svg`, 99.85% ->
99.49%, still pass): its `<text writing-mode="tb">` wraps a `<textPath>`
(dropped whole, unsupported — see `Text.lean`'s module docstring) followed
by plain CJK text outside the `textPath`; that text now lays out under the
new vertical pen model instead of the old horizontal fallback. The file is
itself titled "(UB)" by the test suite and stays well above the pass
threshold either way.

Local suite (`tests/run_tests.py`): unchanged 23/27 on the pre-existing 27
files (identical scores to the baseline, confirming no regression on
non-text or horizontal-text renders), plus the new `28_writing_mode.svg`
at 99.94% within-8.

### Files changed

* `LeanSvg/Svg.lean` — `Style.writingMode` field, `applyProp` case for
  `"writing-mode"`, one extra argument at the `Text.layout` call site.
* `LeanSvg/Text.lean` — `layout` gains the `vertical` parameter; the
  per-character position/rotation computation and the end-of-chunk
  `lastX`/`lastY` carry each gain one `if vertical then ... else ...`
  branch. No other function's signature or behaviour changed.
* `tests/svg/28_writing_mode.svg` — new local regression test: `tb` and
  `vertical-rl` columns, a non-vertical `lr` alias (no effect), inheritance
  from a `<g>`, a `tspan` whose own `writing-mode` is correctly ignored,
  per-character `dx`/`dy` in vertical mode, and a `tspan` chain whose second
  run has no `x` of its own (exercises the swap-not-rotate chunk carry).
  99.94% within-8 against `resvg`.
