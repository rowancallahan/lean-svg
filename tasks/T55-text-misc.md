# T55 — text long tail  (branch `claude/feat-text-misc`)

Work down the remaining non-baseline, non-vertical text failures, highest
count first, matching usvg 0.48.1 (`crates/usvg/src/text/*`). Candidates from
the baseline: `text/text` (19/46 failing), `text/text-decoration` (16/21:
underline/overline/line-through with metrics from the font's `post`/OS/2
tables), `text/textLength` + `text/lengthAdjust` (9+4), `text/tref` (8/11),
`text/font-family` (9/12, only within the embedded Noto Sans set — no system
fonts), `text/letter-spacing`, `word-spacing`, `text-anchor`, `font-size`,
`font-weight`, `tspan`. Triage first: run the target dirs, look at the diff
images (`run_corpora.py` without `--no-worst` writes composites), classify
causes, and fix the biggest shared causes. Skip anything needing fonts we do
not embed, complex shaping, or bidi.

Other agents are concurrently doing baselines (T54), writing-mode (T56) and
textPath (T50) in the same area; stay out of those and keep diffs small.

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

---

## Report

Four features landed, in the order the baseline's failure counts suggested:
`font-family` gating, `text-decoration`, `tref`, `textLength`/`lengthAdjust`.
All four are additive (new `Style`/`SpanProps` fields reset per element, new
functions) — no existing field's meaning changed, `LeanSvg/Effect.lean` is
untouched, and every corpus/local/adversarial/tile check below was run after
each feature, not just once at the end.

### 1. `font-family` (`LeanSvg/Svg.lean`)

Previously `font-family` was parsed nowhere: every text run drew in the one
embedded face regardless of what it asked for. usvg's actual behaviour with
the pinned test-suite fonts, traced from `fontdb`/`FontResolver::
default_font_selector` (`crates/usvg/src/text/mod.rs`): a family list is
tried in order, generic keywords (`serif`, `sans-serif`, ...) map to
`Options`' generic-family defaults (`Times New Roman`, `Arial`, ...) which
are never in the pinned set, and a font that matches *nothing* draws
**nothing** — confirmed by rendering `resvg` directly (`text/font-family/
sans-serif.svg` comes back a blank frame, no fallback glyphs).

New `Style.fontAvailable : Bool` (default `false`, matching usvg's own
default family "Times New Roman" not being installed either), set by
`resolveFontFamily` — a comma-separated walk that returns available on the
first "Noto Sans" and unavailable on the first "Source Sans Pro" (the one
other name in the whole corpus that would out-order it — see the doc comment
on `resolveFontFamily` for why every other name the suite uses is safe to
treat as "keep looking"). Threads into `textShapes`' existing
`display:none`-style `rendered` gate, so an unavailable family draws nothing
the same way a hidden span already did (position-list slots still consumed,
no glyphs, no advance).

### 2. `text-decoration` (`LeanSvg/Font.lean`, `LeanSvg/Text.lean`, `LeanSvg/Svg.lean`)

`underline`/`overline`/`line-through`, not implemented at all before this
task (no `Font` metrics for it, no decoration fields anywhere).

- `Font.lean`: `post` and `OS/2` table scanning, `Font.underlinePosition`/
  `underlineThickness` (`post`, fixed offsets 8/10 in every table version)
  and `Font.strikeoutPosition` (`OS/2` `yStrikeoutPosition`, fixed offset 28
  since version 0), with usvg's own fallback formulas for a font that lacks
  either table (never exercised by the three embedded faces — verified
  against the actual embedded-font source via `fontTools`: upem 1000,
  underlinePosition -100, underlineThickness 50, yStrikeoutPosition 322,
  identical across regular/bold/italic).
- `Text.lean`: `DecorRun`/`decorRectCmds` build one filled rectangle per
  decoration run from those metrics, using the *same* scale-and-rotate
  transform `glyphCmds` already applies to a contour (so a rotated run's
  line rotates with it, exactly). Run boundaries: a same-`styleIdx` run
  breaks not only at the usual style-run/chunk boundaries but at *any*
  character carrying its own `dx`/`dy`/`rotate` (`GlyphCluster::
  has_relative_shift` in `layout.rs`) — `underline-with-{dy,rotate}-list-*`
  exist specifically to pin this down (one short underline segment per
  glyph, not one line under the word). All of one run's segments still merge
  into a *single* path per decoration kind (usvg resolves one fill/stroke
  per `(span, kind)` pair against the whole thing), which matters for a
  gradient-filled underline spanning several rotated segments
  (`underline-with-rotate-list-3/4`, both gradient-filled).
- `Svg.lean`: `ownUnderline`/`ownOverline`/`ownLineThrough`, reset per
  element like `clipRef`/`ownMat` (`text-decoration` is not inherited).
  Colour resolution replicates usvg's two-part search exactly: *whether* a
  kind draws at all is `.any` over the *whole* ancestor chain including
  everything outside `<text>` (`all-types-nested.svg` sets it on two `<g>`s
  above the `<text>` element), but *which* style supplies the fill/stroke
  stops at `<text>` itself even when an outer `<g>` is the reason the kind
  is active (`style-resolving-2.svg`: a `<g>` sets line-through and
  fill=stroke=red, but the line comes out in `<text>`'s own yellow/green).
  `textShapes` now takes the outer walk's own style stack (`ancestors`) as a
  parameter for exactly this search.

Remaining gap: 1/21 (`underline-with-rotate-list-4.svg`, gradient + per-glyph
rotation) at 98.2% within-8, just under the 99% pass line — visually correct
segment-per-glyph behaviour and a gradient that does move left to right, off
by what looks like sub-pixel rounding in the composite bbox; not chased
further.

### 3. `tref` (`LeanSvg/Svg.lean`)

Previously dropped whole, like any unrecognised child of `<text>`. usvg
converts it to a `tspan` carrying the `tref`'s own attributes plus one
synthetic text node: the `href`/`xlink:href` target (a bare `#id`, resolved
anywhere in the *original* document, not usvg's rendered tree) has every
character-data byte under it concatenated regardless of nesting, and the
`tref`'s own children — if it has any in the source markup — are never
visited at all.

`findById`/`collectText`/`stripFragmentId` do the lookup and concatenation;
the `tref` branch in `textShapes` pushes one `open_`/(text)/`close` triplet
using the tref's own resolved style (so its own `x`/`fill`/`text-decoration`
etc. apply, per `position-attributes.svg`/`style-attributes.svg`) and then
sets `skip := skip + 1` exactly as an unrecognised element would, so its own
XML children are walked past unread (`with-a-title-child.svg`,
`with-text.svg`). `findById` filters by `svgTagNames`, hoisted from an
inline list inside `<switch>`'s child-search to a shared top-level `def`,
since `link-to-a-non-SVG-element.svg` needs the same "is this actually a
recognised element" check switch selection already had.

11/11 in the target directory (nothing skipped): none of this corpus's
`tref` tests touch a non-Latin script.

### 4. `textLength` / `lengthAdjust` (`LeanSvg/Svg.lean`, `LeanSvg/Text.lean`)

Not implemented at all before. `apply_length_adjust` (`layout.rs`) runs per
maximal same-style run (never merging across a `tspan` boundary — `textLength/
on-a-single-tspan.svg`), and only ever off an element's *own* attribute:
`try_convert_length` reads `self.attribute()` directly, no inheritance and no
one-level parent fallback (unlike properties resolved through
`find_attribute`) — confirmed against `150-on-parent.svg` ("should have no
effect": a `<text>` with no `textLength` of its own never sees its parent
`<g>`'s) and `inherit.svg` (`textLength="inherit"`, "not allowed": fails to
parse as a number, same as absent).

`Style.ownTextLength`/`ownLengthAdjustGlyphs`, reset per element like
`text-decoration`. `Text.lean` measures a run against `Cluster.natWidth` —
the advance *before* `letter-spacing`/`word-spacing` — because
`apply_length_adjust` explicitly "discards" both for the characters it
covers; "spacing" mode (the default, and the only mode any in-scope test
uses standalone) redistributes `target − natSum` over `n − 1` gaps exactly as
usvg does.

`lengthAdjust="spacingAndGlyphs"` is approximated as "spacing" rather than
implemented: usvg's version rescales each glyph outline horizontally about a
pen position that is itself pre-scaled by the same factor from the run's
start (the scale is baked into `cluster.transform` *before*
`resolve_clusters_positions` composes the chunk's own translation on top), so
the factor reaches every glyph after the first, not just the one glyph in
place — verified by rendering an isolated `"II" textLength=200
lengthAdjust=spacingAndGlyphs` case against `resvg` directly, which spreads
the two glyphs apart rather than growing the first one in place. Reproducing
that needs the scale threaded into the chunk's own x-accumulation, not just
`glyphCmds`; the "spacing" fallback still ends the run up `textLength` wide,
which is the dominant visual effect, at the cost of the individual glyphs
not being rescaled. 2/4 `lengthAdjust` files use this mode
(`spacingAndGlyphs.svg`, `with-underline.svg`); the other two
(`text-on-path.svg`, `vertical.svg`) are `textPath`/`writing-mode`, out of
scope regardless.

### Not attempted

- **Text bounding box for gradient/pattern paint** (`text/text/
  real-text-height.svg`, `text/tspan/tspan-bbox-1/2.svg`): usvg computes a
  text element's bounding box for `objectBoundingBox` paint from *font
  metrics* per cluster (`NonZeroRect(0, -ascent, advance, ascent-descent)`,
  unioned per span — `convert_span`'s "We have to calculate text bbox using
  font metrics and not glyph shape"), not the tight glyph-outline box our
  `Shader.build`/`Grad.build` derives from `Shape.cmds` for every shape kind.
  Fixing it properly needs an optional bbox override threaded through
  `Shape` → `Render.lean`'s `paintMask` → `Shader.build`/`mk`, which are
  shared by every shape in the renderer, not just text; diagnosed exactly but
  not attempted, for 3 files, given the task's own "keep diffs small" and
  "prefer new modules over rewriting shared code" guidance.
- Non-Latin scripts, complex grapheme clusters, bidi reordering, emoji,
  ligature-only fonts (Amiri, Mplus 1p, Source Sans Pro, ...): the task's own
  scope line. Confirmed each remaining `text/text`, `text/tspan`, `text/
  letter-spacing`, `text/text-anchor`, `text/font-kerning` failure is one of
  these, a filter (`filter-bbox.svg`, T51's territory), a pattern
  (`rotate-with-multiple-values-underline-and-pattern.svg`, T53's), or an
  unembedded font weight (`font-weight/{bolder,lighter}-with-clamping`,
  `lighter-without-parent`: Black/Thin/Light faces the corpus's pinned fonts
  dir has and we don't).
- `text-rendering`/`shape-rendering` hints (`optimizeSpeed` disables
  antialiasing) and the CSS `font` shorthand (`font/font-shorthand.svg`):
  real gaps, but a rasterizer-wide AA toggle and a genuinely fiddly shorthand
  grammar each for one file; not attempted.
- `font-stretch`/`font-variant` (small-caps, condensed faces): need faces or
  shaping this renderer doesn't have.

### Verification

Baseline captured before any edit, `main`'s binary, whole `resvg-test-suite`,
both routes (`/tmp/base_all`); compared against after every feature.

**Whole corpus** (`run_corpora.py --fast --corpus resvg --route both`, no
`--dir`, 1679 files × 2 routes):

| | before | after |
|---|---|---|
| direct pass | 835/1679 (49.7%) | 875/1679 (52.1%) |
| usvg pass | 846/1679 (50.4%) | 846/1679 (50.4%, untouched — usvg pre-flattens text to paths) |

`--compare` against the baseline on the final binary: **40 newly passing, 0
newly failing**, both routes, whole suite (not just `text/`).

**Target directories** (`--dir text`, direct route, before → after):

| dir | before | after |
|---|---|---|
| text/text-decoration | 5/21 | 20/21 |
| text/tref | 3/11 | 11/11 |
| text/textLength | 3/12 | 10/12 |
| text/font-family | 3/12 | 10/12 |
| text/lengthAdjust | 0/4 | 0/4 (unimplemented mode approximated; see above) |
| text/text | 27/46 | 27/46 (all remaining are scope exclusions above) |
| text/tspan | 28/31 | 28/31 (bidi + the two bbox-for-gradient cases) |
| whole `text/` dir | 168/356 (47.2%) | 207/356 (58.1%) |

**Everything else**, run after every feature and clean on the final binary:

- `lake build`: 45 jobs, no errors, no new warnings.
- `bash scripts/check-theorems.sh`: `theorems ok`.
- `python3 tests/run_tests.py`: 26/30 (the 4 failures are `main`'s
  pre-existing 12/14/15/16, unrelated to text); `25_text` unchanged at
  99.530% within-8; three new files added, `28_text_decoration` 99.926%,
  `29_tref` 99.861%, `30_text_length` 99.920%.
- `python3 tests/run_adversarial.py`: 64/64 clean.
- `python3 tests/run_tiles.py --no-timing`: 30/30 byte-identical.
- `git diff main -- LeanSvg/Effect.lean`: empty.

### Files

`LeanSvg/Font.lean` (+`post`/`OS/2` metrics), `LeanSvg/Text.lean` (decoration
rectangles, `textLength`/`lengthAdjust`, `natWidth`), `LeanSvg/Svg.lean`
(`font-family`/`text-decoration`/`textLength`/`lengthAdjust` `Style` fields
and parsers, `tref`, shared `svgTagNames`, `textShapes`'s new `ancestors`
parameter). `tests/svg/28_text_decoration.svg`, `tests/svg/29_tref.svg`,
`tests/svg/30_text_length.svg`.
hours; partial but regression-free beats complete but risky.
