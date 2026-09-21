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
