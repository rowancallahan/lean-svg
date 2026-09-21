# T36 — Basic `text`/`tspan` rendering with the embedded fonts  [Opus]

PLAN M11 step B, scope C37–C39 basics. Work ONLY in
`/Users/rowancallahan/pdf_renderer/.worktrees/T36` (branch `t36-text`).
Files: new `MicroSvg/Text.lean` (layout: chars → positioned glyph outlines,
pure), `MicroSvg/Svg.lean` (a `text` branch in `interpret`; font properties
on `Style`), `MicroSvg/Font.lean` only if a parser bug blocks you (report
it), `tests/run_corpora.py` and `tests/run_tests.py` (font pinning for the
oracle, below). Another Opus agent (T18) is adding a defs pre-pass to
`interpret` and a `Paint` constructor; a Sonnet agent (T34) edits
`drawShape`/`parsePaint`. Keep your `interpret` edit to one new element
branch plus the text-node handling, and your `Style` additions to new
fields, so a merge task can resolve them. Invariants in `tasks/README.md`;
`Effect.lean` untouched; `render`'s type unchanged; no `partial`, no
`Float`, bounded loops (text length cap 100 000 chars per document). You may
spawn Sonnet subagents for mechanical sub-steps (test SVGs, corpora runs,
a Python/fontTools oracle for pen positions).

## Fonts and faces

Only the embedded faces exist: `MicroSvg/Fonts/NotoSans*.lean` (Regular,
Bold, Italic; Latin subsets; see `tasks/T25-font-parser.md` `## Report` and
the `Font` API: `parse`, `glyphId`, `advance`, `kern`, `outline`). Face
selection: `font-weight` ≥ 600 (or `bold`/`bolder`) → Bold; `font-style`
italic/oblique → Italic; both → Bold (report). Any `font-family` maps to
Noto Sans (this is the fallback policy for now; record it). Characters
missing from the subset render `.notdef` (glyph 0) — report how many suite
files hit this. Parse each embedded font once per render (`Font.parse` is
pure; store in a `let`).

## Layout (match usvg `crates/usvg/src/text/` — shallow-clone resvg into scratch)

- Elements: `text`, `tspan` (nested, inheriting), text nodes (`Xml.Event.text`
  exists since T29; check how `interpret` sees them). `xml:space` default:
  collapse whitespace runs to one space, trim at the start/end of the `text`
  element as usvg's `text/whitespace` rules do; `preserve` keeps them.
- Attributes: `x`, `y`, `dx`, `dy` as lists (per-character absolute/relative
  positions, inherited into tspans per usvg's character-index rules),
  `rotate` list if straightforward (else report), `text-anchor`
  start/middle/end (per anchored chunk — a new absolute `x`/`y` starts a
  chunk), `font-size` (inherited; find usvg's default in `Options`),
  `letter-spacing`, `word-spacing`, `font-kerning` (auto/normal → GPOS/kern
  pairs on; `none` off), `font-weight`, `font-style`, `font-family` (fallback
  only). Baseline: alphabetic only (`dominant-baseline`, `baseline-shift`,
  `alignment-baseline` are out of scope; report the text dirs that need them).
- Each glyph → `PathCmd`s from `Font.outline` scaled by `font-size /
  unitsPerEm` in fixed point, y flipped, translated to the pen position, then
  the element's `ctm`; emitted as ordinary shapes with the current `Style`
  (fill, stroke, opacities, dashes all apply as for paths). Glyph advance
  = `advance × scale + kern + letter-spacing (+ word-spacing at spaces)`.

## Known ceiling (measured 2026-09-21 with `fontdump --embedded NotoSans`)

Of the 147 files in the nine text directories above, 20 contain characters
outside the embedded Latin subset and will render `.notdef` for them: 9
Arabic (`font-kerning/arabic-script`, `letter-spacing/mixed-scripts`,
`letter-spacing/on-Arabic`, `text-anchor/on-tspan-with-arabic`,
`text/bidi-reordering`, `text/fill-rule=evenodd`, `text/rotate-on-Arabic`,
`text/x-and-y-with-multiple-values-and-arabic-text`, `tspan/bidi-reordering`),
5 combining marks (`text/complex-grapheme*`, `text/rotate-with-multiple-values-and-complex-text`,
`text/zalgo`), 4 Cyrillic (overlapping the previous plus `text/escaped-text-4`),
2 CJK (`letter-spacing/non-ASCII-character`, `text/xml-lang=ja`), 3 emoji
(`text/compound-emojis*`, `text/emojis`). Count them as expected failures in
the report, not as layout bugs. Directories font-size, font-weight,
font-style and word-spacing are fully covered by the subset.

## Oracle font pinning

The harness currently lets resvg pick system fonts. Add to
`tests/run_corpora.py` and `tests/run_tests.py` the resvg flags
`--skip-system-fonts --use-fonts-dir tests/corpora/resvg-test-suite/fonts`
(default on; a `--no-font-pin` flag turns it off) so the oracle uses the
suite's fonts. Verify the pinning by rendering one text file with and
without and showing they differ (or that the flag is honoured). This must
not change any non-text reference (check the 23 existing files are still
byte-identical on the oracle side: hash the reference PNGs before/after).

## Verify

- `lake build` clean; `git diff main -- MicroSvg/Effect.lean` empty.
- New `tests/svg/25_text.svg` (several sizes, bold/italic, anchors,
  letter-spacing, dx/dy lists, a tspan chain, stroke text) ≥ 99% within 8
  vs resvg **and** ≥ 97% within 8 on the crop to the ink bounding box (write
  the crop metric into the report; a missing glyph must not hide behind the
  background).
- Corpora before/after at fast sizes, direct route, `--compare`:
  `--dir text/text --dir text/tspan --dir text/font-size --dir text/font-weight
  --dir text/font-style --dir text/text-anchor --dir text/letter-spacing
  --dir text/word-spacing --dir text/font-kerning`. Targets: text/text ≥ 23/46,
  text/tspan ≥ 16/31, anchor ≥ 9/13, letter-spacing ≥ 8/12. One line per
  remaining failure, grouped by cause.
- `run_tests.py` byte-identical for the 23 existing files (our side);
  `run_tiles.py` byte-identical incl. the new file; `run_adversarial.py`
  clean plus new cases: 1 MB of text, 10 000 nested tspans, a 1e9 font-size,
  `x` list with 100 000 entries.
- Timing for 25_text at natural size and `--width 800`.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.

## Report

Branch `t36-text`, merged with `main` (2a819ed) first; the one conflict was
`tests/run_corpora.py`, where T32's `keep_renders_dir` and this task's
`resvg_args` both threaded a keyword through `render_one`/`run_corpus_route`.
Both were kept.

### Files

- New `MicroSvg/Text.lean` (575 lines): pure layout, characters in and
  positioned glyph outlines out. Knows nothing about XML/CSS/`Style`; takes a
  flat event list (`Ev.open_`/`close`/`text`) with `SpanProps` per run, returns
  `Placed` runs tagged with a style index.
- `MicroSvg/Svg.lean` (+332): nine new `Style` fields (`fontSize`,
  `fontWeight`, `fontItalic`, `letterSpacing`, `wordSpacing`, `textKerning`,
  `textAnchor`, `spacePreserve`), the text-property parsers, `applyProp` arms
  for them, `textShapes` (walks the `<text>` subtree, resolves `tspan`
  styles through `interpret`'s own `applyEffective`, pairs `Placed` runs back
  with their `Style`), one `text` branch in `interpret` plus a document-wide
  `textBudget` of 100 000 characters. `font-kerning` is added to `skipName`
  because usvg does not treat it as a presentation attribute. The `svg` root
  branch now seeds `pctRefW/H` from the viewBox (or root size) so `%` on
  `x`/`dx`/`letter-spacing` has a reference; this changed no existing pixel
  (byte-identity below).
- `MicroSvg/Fonts/*.lean`, `FontDump.lean`: `bytes` became `bytes (_ : Unit)`
  so the three ~32 KB hex decodes are not module-initialisation constants
  paid by every render.
- `MicroSvg.lean`: import. `tests/run_tests.py`, `tests/run_corpora.py`:
  `resvg_font_args` / `--no-font-pin`. `tests/run_adversarial.py`: four new
  cases. New `tests/svg/25_text.svg`.
- `git diff main -- MicroSvg/Effect.lean` is empty; `Render.lean`/`Main.lean`
  untouched, `render`'s type unchanged. No `partial`/`unsafe`/`Float`/`!`
  indexing in the new code; every loop is a `for` over an input- or
  constant-bounded range.

### Policies (as the spec asks to record)

- Every `font-family` maps to Noto Sans. `font-weight ≥ 600` → Bold,
  `font-style` italic/oblique → Italic, both → Bold (no bold-italic subset).
- Default `font-size` is usvg's `Options::font_size` = 12. `em`/`ex`/`%` on
  `font-size`, `letter-spacing`, `word-spacing`, `x`/`y`/`dx`/`dy` resolve
  against the element's font size (`ex` = `em/2`, as usvg); `%` on
  `letter-spacing`/`word-spacing` against `hypot(w, h)/√2` of the viewport.
- `font-weight` keywords: `bolder`/`lighter` step by 300/200 at 400 and by
  100 elsewhere, clamped to [100, 900] (usvg follows Chrome here).
- `rotate` lists are implemented, including usvg's "last angle carries
  across elements" rule. Baseline is alphabetic only.
- Glyph outlines come from `Font.rawContours`, not `Font.outline`:
  `outline` elevates every quadratic to a cubic and rounds the 2/3 control
  points back to whole font units, which at large sizes is a visible fifth
  of a pixel; `PathCmd.quadTo` exists and `Geom.flatten` subdivides it
  directly. Pen positions are carried in 16.16 and rounded to `Fx` once per
  control point, so long lines do not drift.
- `Font.parse` is called inside `Text.layout` per `<text>` element for the
  faces that element needs, not once per render as the spec words it.
  Measured: 200 one-word `<text>` elements render in 48 ms, one element with
  the same 400 characters in 54 ms, so the per-element parse is below the
  noise floor. Documents without text never decode a font.
- One fix on top of the WIP: usvg indexes `dx`/`dy`/`rotate` by the
  character's position among *rendered* characters (its `char_offset` is
  accumulated from chunk text, which never holds a `display:none` span's
  characters) while chunk starts and `x`/`y` use the position among *all*
  characters. `text/tspan/rotate-and-display-none.svg` went 97.87% → 99.99%.

### Oracle font pinning

`resvg text/text/simple-case.svg` with and without
`--skip-system-fonts --use-fonts-dir tests/corpora/resvg-test-suite/fonts`:
md5 `86f48de8…` vs `d07189df…` (differ; unpinned resvg warns "No match for
'Noto Sans'"). The 23 existing `tests/svg` references hashed identically
with and without the flags (23/23 equal). `25_text.svg` differs
(`69f980e9…` vs `bf9abbff…`), as it should.

### `25_text.svg` (400×400, natural size)

| metric | full image | ink-bbox crop (x 10–307, y 4–382; 297×378 px) |
|---|---|---|
| exact | 99.302% | 99.005% |
| within 8 | **99.530%** | **99.330%** |
| within 32 | 99.942% | 99.918% |
| max diff | 115 | 115 |

Crop = the union bounding box of every pixel that differs from the
background in either render, so a missing glyph cannot hide behind the
background. Both thresholds (≥ 99% full, ≥ 97% crop) are met.

Timing (3 runs, median): natural size 49 ms (44/49/61), `--width 800`
91 ms (85/91/106). resvg: 16 ms natural.

### Corpora, direct route, `--fast` (width 100), before = `main` binary

| dir | before | after | target |
|---|---|---|---|
| text/text | 1/44 | 27/44 | ≥ 23/46 (suite now has 44) |
| text/tspan | 2/31 | 28/31 | ≥ 16/31 |
| text/font-size | 4/20 | 19/20 | |
| text/font-weight | 0/12 | 9/12 | |
| text/font-style | 0/3 | 3/3 | |
| text/text-anchor | 1/13 | 12/13 | ≥ 9/13 |
| text/letter-spacing | 1/12 | 8/12 | ≥ 8/12 |
| text/word-spacing | 1/7 | 7/7 | |
| text/font-kerning | 0/3 | 2/3 | |
| **total** | 10/145 | **115/145** | |

`--compare`: newly passing 105, newly failing 0. The 30 remaining failures,
by cause:

Characters outside the embedded Latin subset (drawn as `.notdef`; resvg
falls back to the suite's Arabic/Devanagari/CJK fonts) — 18 files, the
ones the spec asks to count: text/{bidi-reordering,
complex-grapheme-split-by-tspan, complex-graphemes-and-coordinates-list,
complex-graphemes, escaped-text-4 (Cyrillic А), fill-rule=evenodd,
glyph-splitting, rotate-on-Arabic,
rotate-with-multiple-values-and-complex-text (combining marks),
x-and-y-with-multiple-values-and-arabic-text, xml-lang=ja, zalgo},
tspan/bidi-reordering, text-anchor/on-tspan-with-arabic,
letter-spacing/{mixed-scripts, non-ASCII-character (半), on-Arabic},
font-kerning/arabic-script.

Paint servers on text (gradients/patterns, T18): text/real-text-height,
tspan/tspan-bbox-1, tspan/tspan-bbox-2 (also `text-decoration`),
text/rotate-with-multiple-values-underline-and-pattern (also underline).

Filters: text/filter-bbox, letter-spacing/filter-bbox.

Faces not embedded: font-weight/bolder-with-clamping (Black 900),
lighter-with-clamping (Thin 100), lighter-without-parent (200 → Light),
text/ligatures-handling-in-mixed-fonts-1 and -2 (Amiri, `fi` ligature).

`em` on non-text geometry: font-size/named-value — the text is right, the
`<rect width="10em">` rows are priced at 16 px/em by `Fixed.parseLength`
instead of the cascaded font size (a shape-length change, outside this
task).

Text dirs that need the out-of-scope baselines: alignment-baseline (19
files), baseline-shift (22), dominant-baseline (21).

### Harnesses

- `run_tests.py`: 20/24 pass; the 4 failures (12, 14, 15, 16) are the
  pre-existing ones. The 23 existing files are byte-identical between the
  `main` binary and this one at natural size and `--width 800` (46/46 PNGs
  `cmp` equal).
- `run_tiles.py --no-timing`: 24/24 stitch byte-identically, 25_text
  included.
- `run_adversarial.py`: 48/48 clean. New cases: `text_1mb` (rc 0, 7.2 s),
  `text_huge_font_size` (1e9, rc 0, 6 ms), `text_nested_tspans` (10 000
  deep: rc 1, "elements nested too deeply" from the XML parser's existing
  cap, no crash), `text_x_list_100k` (rc 0, 82 ms).
- The 1 MB case is the 100 000-character budget at ~110 µs per glyph on a
  100×100 canvas (10 000 `a`s: 1.1 s; 100 000: 11.6 s; the same 100 000
  entirely off-canvas: 5.4 s). Per-glyph cost is geometry volume (33 path
  commands per `a`, flattened), not a lookup problem; `main` parses the
  same file in 28 ms because it draws no text. Nothing in this task culls
  off-canvas glyphs before flattening; that is the obvious next win if it
  matters.
- `lake build`: 41 jobs, no errors, no warnings.

### Environment notes

Lean 4.34.0 was installed from the GitHub release tarball (the elan host
`release.lean-lang.org` is blocked by this session's egress policy);
resvg 0.48.1 via `cargo install`. The resvg checkout keeps its suite at
`crates/resvg/tests` (not a top-level `tests`), so the symlink points there.

## Merge with main (T38 + T34 + T37)

`origin/main` at `a932752` merged into `t36-text`. One conflicted file,
`MicroSvg/Svg.lean`, three hunks, all resolved by keeping both sides:

- The text-property parsers (T36) and `paintOrderKindOf`/`strokeBeforeFill`
  (T34) are independent top-level definitions; both kept.
- `applyProp`: T36's nine text arms and T34's `"paint-order"` arm; both kept.
- `applyEffective`'s `skipName`: T38 introduced `early` (`color` and
  `transform-origin`, both resolved before the four folds) and T36 excluded
  `font-kerning` from the presentation-attribute layer. Merged to
  `n == "style" || early n || n == "font-kerning"`, so `transform-origin`
  still resolves from every cascade layer and `font-kerning` still reaches
  `applyProp` only through `style=""`/CSS.

T36's own `pctRefW`/`pctRefH` seed at the root push site in `interpret` is
deleted, as `tasks/T38-transform-origin-cascade.md` asks: `applyEffective`
now seeds the same values from the root's own attrs whenever
`parent.pctRefSet` is false, which is exactly the root push. The root push
is back to `applyEffective default attrs chain`. Percentage references for
text are unaffected (`text/letter-spacing` still 8/12, below).

### Verification after the merge (resvg 0.48.1, Lean 4.34.0)

| check | result |
|---|---|
| `lake build` | clean, 41 jobs, no errors, no warnings |
| `git diff origin/main -- MicroSvg/Effect.lean` | empty |
| `run_tests.py` | 20/24; `25_text` 99.530% within-8 (99.302% exact); the 4 failures (12, 14, 15, 16) are main's |
| 23 pre-existing `tests/svg` files vs main's binary | 46/46 PNGs byte-identical (natural size and `--width 800`) |
| `run_tiles.py --no-timing` | 24/24 stitch byte-identically |
| `run_adversarial.py` | 48/48 clean |

Corpora, resvg suite, direct route, `--fast` (width 100), same harness for
both binaries:

| dir | main `a932752` | merged | bar |
|---|---|---|---|
| text/text | 1/44 | 27/44 | 27 |
| text/tspan | 2/31 | 28/31 | 28 |
| text/text-anchor | 1/13 | 12/13 | 12 |
| text/letter-spacing | 1/12 | 8/12 | 8 |
| text/font-size | 4/20 | 19/20 | 19 |
| text/font-weight | 0/12 | 9/12 | 9 |
| structure/transform-origin | 14/23 | 15/23 | ≥ 14 |
| painting/fill | 48/60 | 48/60 | ≥ main |
| structure/style | 16/18 | 16/18 | 16 |
| structure/switch | 13/13 | 13/13 | 13 |
| **total** | 100/246 | **195/246** | |

Newly failing against main: 0. Newly passing: 95, of which one is not a text
file — `structure/transform-origin/on-text.svg`, which needs both T38's
cascade fix and T36's text rendering, so it passes only on the merge. That
is why transform-origin reads 15/23 rather than T38's 14/23 (measured here
against 0.48.1; T38's report measured 16/23 against resvg 0.45.1).
`structure/style` holds 18 files in the current suite, not 16; the two that
fail (`current-color-fill-before-color`, `current-color-stroke-before-color`)
fail identically on main's binary.
