# R5 — resvg-wrong research: text properties

Per-file research on the 14 text-related files where resvg's own test suite
(`tests/corpora/resvg-test-suite/results.csv`) marks resvg **wrong**
(`resvg` column = 2). Comparison sheet: `R5-text-props.png` (one row per
file: resvg | suite PNG | Chromium | ours, all at 200px wide, rendered
against the current commit's binary, i.e. **after** the two fixes below).

`results.csv` columns are `title,chrome,firefox,safari,resvg,batik,inkscape,
librsvg,svgnet,qtsvg` (1 = passes/correct, 2 = fails/wrong, 0 = untested,
3 = crash). All numbers below were verified by grepping the live file, not
copied from the task table. Renders were made with
`.lake/build/bin/lean-svg --width 200`, `resvg --skip-system-fonts
--use-fonts-dir tests/corpora/resvg-test-suite/fonts -w 200`, the suite's own
sibling PNG resized to 200px wide, and `python3 tests/render_chrome.py`
(headless Chromium via Playwright, local system fonts — see the per-file
caveats where that matters).

Two general facts that recur across many files below and are stated once
here rather than repeated: **(1)** the renderer embeds exactly one Latin-only
font family ("Noto Sans", `LeanSvg/Fonts/NotoSans.lean`); `resolveFontFamily`
(`LeanSvg/Svg.lean:1701-1721`) treats any `font-family` that doesn't
literally match it as unavailable, and an unavailable font draws nothing at
all (deliberately mirroring real usvg/resvg fontdb-miss behaviour — see
`LeanSvg/Svg.lean` ~3001-3003). **(2)** `LeanSvg/Text.lean:25` documents "one
glyph per character (no ligatures, no complex-script shaping, no BiDi
reordering)" as a standing design boundary, not an oversight.

---

## 1. `text/alignment-baseline/hanging-on-vertical.svg`

**results.csv**: `chrome=1 firefox=2 safari=1 resvg=2 batik=2 inkscape=2 librsvg=2 svgnet=0 qtsvg=2`

**What it tests.** `<text writing-mode="tb" alignment-baseline="hanging"
font-family="'Mplus 1p'" font-size="24">日本 Japan</text>` — the hanging
baseline anchored at the top of a vertical (`tb`) column, mixing CJK and
Latin text.

**Spec.** SVG2 `alignment-baseline: hanging` (https://www.w3.org/TR/SVG2/text.html#AlignmentBaselineProperty);
`writing-mode="tb"` maps to `vertical-rl` per CSS Writing Modes 3 (usvg's own
`parser/text.rs:875-897` collapses SVG1.1's `lr`/`lr-tb`/`rl`/`rl-tb` to
`horizontal-tb` and `tb`/`tb-rl` to `vertical-rl`, "because I have no idea how
exactly \[the direction distinction] should affect the rendering").

**Render observations.** Ours: fully blank. resvg: renders "日本"/"Japan" as
a tight vertical column, each Latin letter rotated 90°, CJK upright. Suite:
same layout but with visibly more spacing between characters (a real
difference, `max diff 255` against resvg — resvg likely under-advances in
vertical mode, out of scope here). Chrome (local): renders only "Japan",
missing the CJK glyphs and shifted — almost certainly a missing-CJK-fallback
artifact of this container's Chromium, not evidence of Chrome's real
behaviour (results.csv says `chrome=1`).

**Root-cause isolation.** A probe with the CJK replaced by plain ASCII
("Japan") *still* renders blank — proving the blank output is not a
CJK-glyph problem but `font-family="'Mplus 1p'"` failing `resolveFontFamily`
(not "Noto Sans"), which drops the whole run. A second probe with
`font-family="Noto Sans"` substituted renders **pixel-identical** to resvg's
equivalent — this isolates and confirms `alignment-baseline="hanging"` under
vertical writing-mode is already implemented correctly; the observed FAIL is
caused entirely by the font-availability gate, unrelated to baseline logic.
Separately, even with a matching font, `LeanSvg/Text.lean:513-517` documents
that the "upright CJK glyph" rotation branch was never implemented (dead
code, since the one embedded font has no CJK glyphs to exercise it) — so CJK
support is a second, independent gap.

**Verdict.** High confidence: the hanging-baseline/vertical-writing-mode
interaction under test is already correct. The visible mismatch is a
pre-existing, out-of-scope font/CJK-glyph gap, not a text-properties bug.

**Classification: (c) deliberately not supported.** No code change
recommended. If CJK support is ever undertaken as its own project, note (1)
`Text.lean:513-517`'s upright-glyph branch would need implementing against a
real `Vertical_Orientation`-style table, and (2) resvg's own vertical
character spacing should not be copied uncritically (see suite-vs-resvg
spacing difference above).

---

## 2. `text/direction/rtl.svg`

**results.csv**: `chrome=1 firefox=1 safari=1 resvg=2 batik=2 inkscape=1 librsvg=1 svgnet=2 qtsvg=2`

**What it tests.** `<text direction="rtl">اقرأ المزيد عن SVG أيضًا.</text>` —
plain paragraph-direction: the UA must run the Unicode Bidi Algorithm with
the paragraph base forced RTL, so the Arabic runs read right-to-left while
the embedded Latin "SVG" keeps its own internal left-to-right order.

**Spec.** CSS Writing Modes `direction` property + the Unicode Bidi
Algorithm (UAX #9), as applied to SVG text layout.

**Render observations.** Suite and Chrome (identical): the full sentence
renders correctly shaped, spanning most of the 200px width, with "SVG"
reading left-to-right in the middle of the RTL flow. resvg: renders only a
small two-glyph fragment at the right edge — this **matches resvg's own
bundled regression-test reference** (`crates/resvg/tests/tests/text/
direction/rtl.png`, fetched and compared), so it's resvg's accepted,
version-pinned baseline, not an artifact of this environment. Ours: four
`.notdef` tofu boxes at the same right-edge cluster.

**Root cause (two independent, stacking problems).** (1) `direction` is
parsed nowhere in `LeanSvg/Svg.lean` (confirmed by grep), so text always
lays out as `ltr`; with a ~25-character string starting at `x=170` in a
200px canvas, only the first few characters' worth of advance stays on
canvas. (2) The embedded font is Latin-only (no Arabic block), so every
Arabic character draws as `.notdef` regardless of position.

**resvg source, confirmed.** `crates/usvg/src/parser/text.rs` never reads
`AId::Direction`/`AId::UnicodeBidi` while building a `TextChunk`; `text/
layout.rs:1466` hardcodes `unicode_bidi::BidiInfo::new(text, Some(Level::ltr()))`
— the paragraph base level is always LTR, never taken from `direction`,
which explains resvg's own near-blank output. Corroborating open issues:
[resvg#475](https://github.com/linebender/resvg/issues/475) (2021, Hebrew
RTL + embedded LTR run wrong vs. Chrome) and
[resvg#447](https://github.com/linebender/resvg/issues/447) (2021, mixed
Arabic/Latin/number bidi-run granularity wrong; explicitly says Firefox
follows UAX#9 correctly and resvg doesn't) — both open, uncorrected, five
years old: a standing architectural gap in usvg's text pipeline, not a
one-off regression.

**Verdict.** High confidence: correct output is full bidi reordering per
Chrome/Firefox/Safari/suite (byte-identical to each other); resvg's near-
blank output has no plausible correct reading.

**Classification: (b) real feature / (d) needs Rowan's decision on scope.**
A naive "reverse the whole string" fix would be wrong (it would also flip
the embedded "SVG" run backwards, which no reference does) — correct
behaviour needs directional-run splitting (a simplified, bounded subset of
UAX#9: no multi-level embedding needed for this file), which is real,
bounded, pure work, not a few lines. Even done correctly, this specific test
would still show Arabic tofu (no Arabic glyphs embedded) — full visual
correctness needs a second, larger, separate feature (Arabic font +
contextual shaping). **Question for Rowan:** (1) implement bounded
run-splitting now (helps any Latin/mixed-direction case not needing a new
font), (2) implement it together with Arabic font+shaping as one feature so
this test class is fixed end-to-end, or (3) leave both unsupported and
promote `Text.lean`'s "no BiDi" comment from an implementation note to a
stated permanent boundary?

---

## 3. `text/font-size-adjust/simple-case.svg`

**results.csv**: `chrome=2 firefox=1 safari=1 resvg=2 batik=2 inkscape=2 librsvg=2 svgnet=2 qtsvg=2`

**What it tests.** `font-family="Noto Sans" font-size="64"` with
`font-size-adjust="0.3"` on the `<text>` — a font that **is** available (no
substitution involved), testing purely whether `font-size-adjust` shrinks
the rendered glyph size.

**Spec.** CSS Fonts Module Level 4, `font-size-adjust`: the number form
rescales the *used* font size unconditionally — `used-size = specified-size
* (target-aspect-value / font's-own-aspect-value)`, aspect value defaulting
to x-height/em. Noto Sans's x-height/em ratio (~0.53-0.55) is well above
0.3, so the correct effect is visibly *smaller* glyphs.

**Render observations.** Ours and resvg: identical, full-size unadjusted
"Text". Suite: noticeably smaller "Text" (~55-65% linear size), still
centered at the same anchor. Chrome (local, unreliable font substitution —
see general caveat) not usable for exact judgment, but results.csv says the
*real* Chrome is also wrong here (`chrome=2`); Firefox and Safari are
correct (`=1`).

**resvg source.** `font-size-adjust` is parsed as an inheritable
presentation attribute (`parser/svgtree/parse.rs:363`, `names.rs:210,553`)
but grepping `crates/usvg/src/text/*.rs` and `crates/resvg/src/*` finds zero
further uses — the value is stored and never read. Confirmed deliberate:
resvg's own `docs/unsupported.md` lists it explicitly.

**Our code.** Not implemented at all (`grep -rn "font-size-adjust"
LeanSvg/` is empty). `LeanSvg/Font.lean` already parses per-font `xHeight`
and `unitsPerEm` from the `OS/2` table (lines ~43, 56-59) — the metrics the
CSS Fonts 4 formula needs already exist, for an unrelated reason.

**Verdict.** High confidence on the spec direction; medium-high on the exact
suite-PNG magnitude (arithmetic not hand-verified against Noto Sans's exact
`sxHeight`, but direction and rough size match). Firefox/Safari corroborate;
resvg and (real) Chrome are wrong; we currently copy resvg's mistake.

**Classification: (b) needs a feature, but small and well-scoped** — not
(c): it doesn't conflict with any project invariant (closed-form arithmetic,
bounded, uses metrics already parsed), and the needed metrics already exist.
Estimated shape: a `fontSizeAdjust : Option Fx` cascade field next to
`fontWeight`/`fontSize` in `Svg.lean`, threaded into `SpanProps` in
`Text.lean`, multiplying the used size by `adjust / (xHeight / unitsPerEm)`
at the point the glyph-to-user-space scale is computed (guard `xHeight = 0`
by leaving unadjusted). This is a genuine divergence from resvg — the
project's stated reference — so whether to spend the budget on it is a
judgment call, not a pure bug fix. **Question for Rowan:** implement (diverge
from resvg, match Firefox/Safari/spec) or leave unimplemented (match resvg's
documented non-support)? If implementing, is defaulting the optional leading
keyword form to `ex-height` (this file's only tested form) acceptable?

---

## 4. `text/font-weight/650.svg` — **FIXED**

**results.csv**: `chrome=1 firefox=1 safari=1 resvg=2 batik=2 inkscape=2 librsvg=1 svgnet=1 qtsvg=1`

**What it tests.** Two lines, `font-weight="650"` vs. inherited `normal`
(400), against a fonts directory holding weights {100,300,400,700,900} —
purely a font-weight matching/fallback test (no exact 650 file exists).

**Spec.** CSS Fonts Module Level 4's font-matching algorithm: for a target
weight > 500, pick the nearest **installed** weight ≥ target first; here
700 is nearest to 650, so line 1 should render **bold**.

**resvg source, root cause found.** `crates/usvg/src/parser/text.rs:585`
(`resolve_font_weight`) matches only the literal strings `"normal"`,
`"bold"`, `"bolder"`, `"lighter"`, and `"100".."900"` in steps of 100; `"650"`
matches none of them and falls through to `_ => weight` (the **inherited**
value, silently discarding the number). `fontdb`'s own `find_best_match`
(fetched from `RazrFalcon/fontdb`, `src/lib.rs:1212-1338`) correctly
implements the CSS4 nearest-weight rule — the bug is entirely upstream, in
usvg's string parsing, not in the matching math.

**Our code (pre-fix), same bug.** `LeanSvg/Svg.lean`'s `parseFontWeight` was
a line-for-line mirror of usvg's restrictive match, falling through to
`else parent` for `"650"`. `Text.pickFace` (`weight ≥ 600 → bold`) was
already correct — only the parsed number was wrong.

**Verdict.** High confidence: six independent renderers (chrome, firefox,
safari, librsvg, svgnet, qtsvg) plus the suite PNG agree bold is correct.

**Classification: (a) shallow fix — done.** `parseFontWeight` now falls back
to `parseNumberAll` (already used elsewhere, e.g. `stroke-miterlimit`),
clamped to CSS Fonts 4's valid `[1, 1000]` range, when the value isn't one of
the recognized keywords/decade literals. Commit `6dc6d98`.

**Corpus gate result:** 0 newly-failing files among the 1522 where
`results.csv` marks resvg correct (1400/1522 before and after). Only this
file itself moved, from matching resvg's wrong output (99.985% similarity)
to differing from it (97.665%) — the intended change. This file now
**fails** against resvg in the fidelity harness (it did not before).

---

## 5. `text/font/simple-case.svg`

**results.csv**: `chrome=2 firefox=2 safari=2 resvg=2 batik=1 inkscape=2 librsvg=2 svgnet=2 qtsvg=2`

**What it tests.** `<text font="bold italic 64 Noto Sans">Text</text>` — the
CSS `font` **shorthand** given as a bare XML presentation attribute (not
inside `style=`).

**Render observations.** Ours and resvg: both fully blank, byte-identical.
Suite: large, bold *and* italic "Text". Chrome (local, unreliable font):
renders something (not blank) in a substitute face — structurally
consistent with browsers not sharing this specific parsing gap.

**resvg source, root cause found.** `parser/svgtree/parse.rs:346-415` only
expands the `font` shorthand (via `svgtypes::FontShorthand`) for
declarations from a `<style>` rule or a `style="..."` attribute — a bare
presentation attribute `font="..."` goes through a different path that
stores the raw string and never re-reads it. So `font-family` stays unset,
falls back to usvg's compiled-in default ("Times New Roman", not in the
fonts dir), and per resvg's own long-open
[issue #159](https://github.com/linebender/resvg/issues/159) ("no font
match → no text rendered"), the result is blank. Verified with a same-repo
control (`text/font/font-shorthand.svg`, shorthand *inside* `style=`,
`results.csv` says `resvg=1`) — resvg renders that one correctly, isolating
the bug precisely to the bare-attribute path.

**Our code.** The `font` shorthand isn't recognized in *either* form (bare
attribute or `style=`) — confirmed with the same control file, which we
also render blank. So our match with resvg here is **coincidental**: same
visible symptom, different root cause.

**Also separately:** resvg does no font synthesis at all
([issue #297](https://github.com/linebender/resvg/issues/297), open) and
neither do we (`Text.lean:61-66`: "bold wins over italic, no bold-italic
subset") — so even a full shorthand-parsing fix would produce bold,
non-italic "Text", not the suite's bold-*and*-italic, without also adding
font synthesis or a fourth embedded face.

**Verdict.** High confidence blank is wrong (every other renderer in the row
produces visible text; resvg's own issue #159 documents this as a known
rough edge). Medium confidence on reaching the suite's *exact* pixels
without also solving synthesis.

**Classification: (b) needs a feature**, in two independent layers: (1)
parse the `font` shorthand (bare attribute and/or `style=`) into its
longhand components — a self-contained shorthand tokenizer feeding the
existing per-property setters — moderate, not a one-liner; (2) bold+italic
synthesis or a fourth embedded face — separate, larger, pre-existing scope.
**Question for Rowan:** worth adding at all (only 2 files in the whole
corpus use this shorthand, one of them in scope here)? If yes, cover both
delivery forms in one pass or just the in-scope bare-attribute form? Is
bold-italic synthesis ever planned, or does "bold wins, drop italic" stay
permanent?

---

## 6. `text/glyph-orientation-horizontal/simple-case.svg`

**results.csv**: `chrome=2 firefox=2 safari=2 resvg=2 batik=1 inkscape=2 librsvg=2 svgnet=2 qtsvg=2`

**What it tests.** `glyph-orientation-horizontal="-90"` in default horizontal
writing-mode — SVG1.1 §10.9.3, per-glyph rotation while the run still
advances left-to-right.

**Render observations.** Ours, resvg, Chrome: all render plain unrotated
"Text" (attribute silently ignored by all three). Suite: each glyph
individually rotated 90° with wider gaps — the literal SVG1.1-specified
behaviour.

**resvg source.** `docs/unsupported.md:34` lists this property explicitly as
unsupported, "(removed in the SVG 2)"; the attribute name is recognized in
`svgtree/names.rs` but never read in `text/layout.rs`.

**Verdict.** High confidence this should **not** be implemented: every
currently-shipping renderer in the row (chrome, firefox, safari, resvg)
agrees with each other and disagrees with the suite; only Batik (old,
largely unmaintained) matches it. SVG2 formally removed the property.

**Classification: (c) deliberately not supported.** No code change. This is
a deprecated-and-removed (SVG2) property with zero modern-renderer support;
resvg's own maintainers explicitly declined it.

---

## 7. `text/glyph-orientation-vertical/simple-case.svg`

**results.csv**: `chrome=2 firefox=2 safari=1 resvg=2 batik=1 inkscape=2 librsvg=2 svgnet=2 qtsvg=2`

**What it tests.** `writing-mode="tb" glyph-orientation-vertical="0"` —
should force glyphs upright even though Latin defaults to rotated-90° in
vertical mode. Unlike `-horizontal`, SVG2 only **deprecates** (doesn't
remove) this property.

**Render observations.** Ours and resvg: visually identical, "Text" rotated
sideways (override ignored). Chrome: also ignores it (`chrome=2`,
consistent). Suite: "T","e","x","t" stacked upright, one per line (override
honored).

**resvg source.** `docs/unsupported.md:35` lists it unsupported,
"(deprecated in the SVG 2)"; `text/layout.rs:1044-1078`'s
`apply_writing_mode` implements only the Unicode `Vertical_Orientation`
(UAX #50) per-character default and never reads a
`glyph-orientation-vertical` override.

**Verdict.** Medium confidence — genuinely more contested than file 6: one
real modern browser (Safari) plus the suite reference honor it; Chrome,
Firefox, and resvg (our primary reference) all ignore it. The "correct"
answer depends on which reference the project wants to track.

**Classification: (d) needs a decision from Rowan.** **Question:** for
`glyph-orientation-vertical` specifically (unlike `-horizontal`, which is
unambiguously dead) — (a) match resvg/Chrome/Firefox and keep ignoring it
(keeps parity with our primary reference), or (b) implement the
deprecated-but-still-valid override since Safari + the suite honor it? Lean:
(a), given the project's resvg-compatibility default and this being a narrow
corner of an already-deprecated property — but if (b): small, bounded
feature (one `SpanProps` field, one parse function, one conditional in the
vertical rotation math in `Text.lean` ~492-540 / `Svg.lean` ~2838-3005) if
only "0" and unset need handling; larger if 90/180/270 must compose with the
existing rotation.

---

## 8. `text/kerning/10percent.svg`

**results.csv**: `chrome=2 firefox=2 safari=2 resvg=2 batik=1 inkscape=2 librsvg=2 svgnet=2 qtsvg=2`

**What it tests.** SVG1.1's (SVG2-removed) `kerning="10%"` — a `<length>`
value that per SVG1.1 should **disable** automatic kerning and substitute an
explicit inter-glyph spacing (here, 10% of the viewport diagonal = 20 user
units at `viewBox="0 0 200 200"`).

**Render observations.** Ours and resvg: identical, tightly-set "Text" (no
extra spacing). Suite: dramatically spread "T e x t". Chrome (local,
structurally trustworthy here even with font-substitution caveats): also
tightly-set, matching the *pattern* results.csv reports for real
Chrome/Firefox/Safari (all `=2`).

**resvg source.** `parser/text.rs:258-264` resolves `kerning` to a pure
**boolean** (`== 0.0` → disable automatic kerning; any nonzero value,
including `10%`, leaves it on) — the numeric override half of the spec is
never implemented. `docs/unsupported.md` lists this deliberately,
"(removed in the SVG 2)".

**Our code.** `LeanSvg/Svg.lean:2087-2088` is a direct, intentional port of
resvg's exact boolean-only semantics (comment says so explicitly).

**Verdict.** High confidence that matching resvg/Chrome/Firefox/Safari (the
simplified boolean behaviour) is the practically correct choice, even though
it stays "wrong" against a literal reading of the still-technically-current
SVG1.1 text and the suite's own PNG. Only Batik (legacy, frozen) implements
the full historical semantics.

**Classification: (c) deliberately not supported, flagged (leaning (d)).**
`kerning` was removed in SVG2 in favor of CSS `font-kerning` (which we do
support); every maintained renderer agrees with the simplified reading;
implementing the full spec would require real per-glyph advance-width
overrides in the text-layout pass, a real change, for one obscure corpus
file against an otherwise-abandoned legacy path. Not marked a clean (c)
because the suite (and this task's own premise) does score it a real
"resvg=2, wrong" case. **Question for Rowan:** leave the boolean-only
simplification (recommended), or is matching Batik's literal-spec reading
worth the layout-engine change?

---

## 9. `text/text-anchor/coordinates-list.svg` — **FIXED**

**results.csv**: `chrome=1 firefox=2 safari=1 resvg=2 batik=2 inkscape=1 librsvg=2 svgnet=2 qtsvg=2`

**What it tests.** Two structurally different ways of expressing the same
thing: a `<tspan>` that repositions only `y` (re-declaring
`text-anchor="middle"`), and a bare `y` attribute given as a **list** of
per-character values on a single `<text>`. Both split "T"/"ext" into two
independently-`text-anchor:middle`-anchored text chunks per SVG2's chunk
rule, and the file overlays the second (`text2`, black) exactly on top of
the first (`text1`, red) to check whether both position "ext" identically.

**Spec.** SVG2 §Text: "Each new absolute positioning adjustment (due to an
`x` or `y` attribute...) creates a new text chunk" and, critically,
"the \[chunk] positions are determined **before applying the `text-anchor`
property**" — i.e. the fallback pen handed to a later chunk with no explicit
`x` should be the chunk's *pre-anchor* advance, not its on-screen shifted
position. (Open ambiguity elsewhere in the spec on a related point:
[w3c/svgwg#518](https://github.com/w3c/svgwg/issues/518) — not the same
question this file tests, which the spec's literal wording above already
answers.)

**Render observations (pixel-measured).** Ours (pre-fix) and resvg: only 4px
differ across the whole canvas (sub-pixel AA), i.e. we reproduced resvg's
placement almost exactly. Both put "ext"'s ink-box center at x=106. Chrome
puts it at x=113. The suite's own reference PNG, measured directly at native
resolution and scaled to 200px terms, puts it at x=112.2 — agreeing with
Chrome, not resvg. `results.csv`'s renderer split (chrome/safari/inkscape=1
vs. firefox/resvg/batik/librsvg/svgnet/qtsvg=2) is consistent with two
distinct implementation schools, not noise.

**resvg source, root cause found.** `crates/usvg/src/text/layout.rs`'s
`resolve_clusters_positions` seeds the running pen with `let mut x: f32 =
x0` (the anchor shift) and carries that same shifted value forward as the
next chunk's fallback position — i.e. it uses the chunk's *post*-anchor
on-screen position, not the pre-anchor advance the spec calls for. Our
`Text.lean` (`layout`, ~line 790) ported this exactly.

**Verdict.** High confidence: three independent signals agree (spec's
literal "before applying text-anchor" wording, the suite's own reference PNG
measured directly, and Chrome's behaviour).

**Classification: (a) shallow fix — done**, per the task's own criterion
(suite PNG and Chromium agree with each other and the spec). `Text.lean`'s
`layout` now tracks a second accumulator, `adv`, that mirrors every update
`x` receives but starts at 0 instead of `x0`, and uses it (not `x`) for
`lastX`/`lastY`; only the primary/anchor-shiftable axis needed this (`y`
never receives `x0` in either writing-mode orientation). Commit `c1522c5`.

**Corpus gate result:** 0 newly-failing files among the 1522 where
`results.csv` marks resvg correct. This file itself stays a "pass" against
resvg in the fidelity harness (99.195%, was 99.990%) since it's still within
tolerance, but the ink now sits at the spec/Chrome/suite-correct position
(measured: "ext" center moved from 106 → 112).

**Note (pre-existing, not from this fix):** even after the fix, `text1`'s
red "ext" and `text2`'s black "ext" don't perfectly overlap (a faint
maroon fringe is visible in the comparison sheet) — this fringe is present
identically **before** this fix too (verified by rendering the pre-fix
binary), so it's an unrelated, pre-existing minor discrepancy (most likely a
small kerning/advance difference between the tspan-run and single-run
tokenizations of "ext"), not a regression from this change and not
investigated further here.

---

## 10. `text/text-decoration/style-resolving-4.svg`

**results.csv**: `chrome=2 firefox=1 safari=1 resvg=2 batik=2 inkscape=2 librsvg=0 svgnet=2 qtsvg=2`

**What it tests.** `<desc>Decoration can have it's own font properties.</desc>`
— an underline **declared** on a `font-size="200"` tspan, wrapping glyphs
actually **rendered** at `font-size="48"` (an inner tspan). Question: whose
font-size sets the underline's thickness/offset — the declaring ancestor's,
or the rendered glyph's?

**Spec / cross-browser reality.** Per `resvg`'s own CHANGELOG (found via
WebSearch, under "Nested Elements with Different Font Sizes"): the
web-platform answer is the underline is positioned for the span but at the
**thickness implied by the declaring parent** — matching Firefox/Safari and
the suite reference.

**resvg source, confirmed gap.** `crates/usvg/src/text/layout.rs` (~259-326,
`convert_decoration`) computes underline offset/thickness from `span.font_size`
— usvg's resolved **leaf** run (the innermost tspan), not the declaring
ancestor. This is a known, still-open upstream issue:
[resvg#411](https://github.com/linebender/resvg/issues/411) (opened 2021, no
fix as of v0.48.1).

**Our code, same gap.** `LeanSvg/Text.lean`'s `mkRun` (~913-919) uses
`c.props.size` — the current character's own (innermost) resolved
font-size — for `DecorRun.size`, never the declaring ancestor's. The
declaring ancestor's `Style` is separately looked up via `underlineIdx` etc.
but only for fill/stroke colour, not font-size.

**Render observations (pixel-measured).** Control case (`text2`, matched
sizes): ours/resvg/suite agree exactly (underline rows 164-165, thickness
2px). Test case (`text1`, mismatched sizes): ours/resvg put the underline at
rows 84-85 (2px thick, right under the 48px glyph); the suite reference puts
it at rows 95-99 (5px thick — both lower and thicker, consistent with a
font-size-200 metric). Checked: this is the *only* file in the whole
`text-decoration/` test directory with this mismatched-size-plus-declared-
decoration shape, so a fix would not be expected to regress any sibling
file in that directory (not run through the full corpus gate, since no fix
was attempted here).

**Verdict.** High confidence: resvg's own source confirms the mechanism,
resvg's own open issue names exactly this gap, two independent engines
(Gecko, WebKit) agree with the suite reference, and the pixel measurements
are unambiguous.

**Classification: (b) needs a real, if small, feature — not (a).**
`Text.lean`'s `layout` doesn't currently have access to the declaring
ancestor's font-size at the point it builds a `DecorRun`, only an opaque
style index used for colour. A correct fix needs: (1) in `Svg.lean`'s
`resolveDecor` (~2875), also capture `s.fontSize` for the declaring style and
thread it into `SpanProps`; (2) in `Text.lean`'s `mkRun`, use that
declaring-ancestor size instead of `c.props.size` for `DecorRun.size` and the
metrics lookup. Estimated a few new struct fields + ~10-20 changed lines
across two files — small in size but a genuine behavioural extension (new
data threaded through a path distinct from colour), shared by all three
decoration kinds, so it deserves its own dedicated test pass rather than
being folded into this task's shallow-fix budget. **Question for Rowan:**
proceed now (same "prefer spec/Firefox/Safari over resvg's acknowledged bug"
call as file 9), or bundle with file 9 as one deliberate policy decision
about diverging from resvg on text layout/decoration?

---

## 11. `text/text-rendering/geometricPrecision.svg`

**results.csv**: `chrome=2 firefox=1 safari=1 resvg=2 batik=2 inkscape=2 librsvg=2 svgnet=1 qtsvg=2`

**What it tests.** Two identical "Text" strings, one at
`text-rendering="auto"`, one at `text-rendering="geometricPrecision"` —
tests whether font hinting/grid-fitting is turned off for the latter,
producing a visible stem-width/spacing difference at the same nominal size.

**Render observations (pixel-measured).** The `ours`-vs-`resvg` diff (8px
total) has the *same* offset pattern on both text lines (Δy=40 between
matching diff coordinates) — i.e. whatever tiny rasterizer discrepancy
exists is generic AA rounding common to text rendering in general, not
something specific to the `geometricPrecision` line. Chrome (local):
identical structure to ours/resvg (both lines rendered the same way) —
consistent with `chrome=2`.

**resvg source.** `crates/usvg/src/text/flatten.rs`'s
`resolve_rendering_mode` maps **both** `auto`'s default and
`geometricPrecision` to the identical `ShapeRendering::GeometricPrecision` —
resvg has no font-hinting engine at all, unhinted outlines are used
regardless of this property. This is a general resvg limitation, not
specific to this test.

**Verdict.** High confidence this is correctly out of scope: distinguishing
`auto` from `geometricPrecision` requires an actual font-hinting engine
(TrueType `fpgm`/`prep` grid-fitting or an equivalent), a large, genuinely
different subsystem that even resvg — a mature, actively maintained renderer
— does not attempt. This matches the pre-existing code comment in
`LeanSvg/Svg.lean` (~3010): "we do not support that property, so glyphs stay
antialiased regardless."

**Classification: (c) deliberately not supported, already documented.** No
code change. We are not behind resvg here (resvg can't clear this bar
either) — only behind Firefox/Safari's real hinting support.

---

## 12. `text/tref/link-to-an-external-file-element.svg`

**results.csv**: `chrome=2 firefox=2 safari=2 resvg=2 batik=3 inkscape=1 librsvg=2 svgnet=1 qtsvg=2`

**What it tests.** A `<tref xlink:href="../../../resources/simple-text.svg#text1"/>`
— a `tref` pointing at an element **in a different file** (the sibling file
does exist on disk). If the external reference resolves, `text3`'s black
"Text" should completely cover an earlier red "Text" at the same
coordinates; if not, the red remains visible.

**Spec.** SVG 1.1 §10.6 types `tref`'s `href` as a full `<IRI>`, not
restricted to a local fragment — a strict letter-of-the-law reading permits
following a `path#fragment` into another file. **SVG2 removes `tref`
entirely** (not merely deprecated) — there is no live spec requiring
external-file resolution today.

**resvg/usvg source.** `parser/svgtree/text.rs`'s `resolve_tref_text` calls
`svgtypes::IRI::from_str`, which **only parses a bare local `#id`** — it has
no path/URL component at all, so `"../../../resources/simple-text.svg#text1"`
fails to parse and resolution returns `None`. This is a structural
limitation of resvg's own IRI type, not a documented policy choice, but the
net effect (unresolvable external tref → empty content) is identical to
what a deliberate local-only policy would produce.

**Render observations.** Ours and resvg: pixel-equivalent — red "Text"
visible, no black text (tref unresolved). Suite reference: black "Text"
fully covering the red (external fetch succeeded). Chromium, run via
`file://` with the real sibling file present (so it *could* follow the
reference without a CORS issue): still shows red/unresolved — real browsers
do not perform cross-document `tref` fetches at all (results.csv: every
browser fails every `tref/*.svg` test in the corpus, local or external).
Only Inkscape and SVG.NET (unrestricted local filesystem access) pass; Batik
crashes attempting it.

**Verdict.** High confidence: the correct target for this renderer is
"unresolvable → empty tref content" (reading shared by every browser, resvg,
librsvg, and qtsvg). The literal-SVG1.1 "fetch across files" reading is
achieved only by two filesystem-unrestricted desktop tools and crashes a
third; SVG2 has since removed the element outright.

**Classification: (c) deliberately not supported — cleanly, two independent
reasons.** (1) **Structural:** `LeanSvg/Effect.lean`'s three-effect model
(§1-2, `DESIGN.md`) proves this renderer can never open a second file — no
XXE, no external fetches, by construction — so the literal-SVG1.1 reading
could not be implemented here regardless of any correctness judgment. (2)
**Behavioural:** independent of (1), our unresolvable-case handling is
already correct — `stripFragmentId` (`Svg.lean:2763`) returns `none` for a
non-bare-`#id` href exactly as `svgtypes::IRI::from_str` does, and the
`tref`-turned-tspan then contributes zero glyphs, leaving the sibling red
text showing through — precisely what resvg and every browser produce.
There is no code change that would move us closer to the suite's canonical
PNG without violating the project's proven no-second-file safety invariant.

---

## 13. `text/unicode-bidi/bidi-override.svg`

**results.csv**: `chrome=1 firefox=1 safari=1 resvg=2 batik=1 inkscape=2 librsvg=1 svgnet=2 qtsvg=2`

**What it tests.** `unicode-bidi="bidi-override" direction="rtl"
font-family="Amiri"` on `This is "مرحبا العالم!" Arabic.` — `bidi-override`
means *skip* the Unicode Bidi Algorithm entirely and lay out literally every
character (Latin, Arabic, punctuation alike) in one strict RTL sequence per
`direction` alone.

**Render observations.** Chrome and suite (identical): the entire string
reversed end-to-end, character by character — exactly the spec's "ignore
the implicit algorithm" behaviour. resvg: renders the Latin portions in
normal reading order and only the Arabic clause reordered — i.e. resvg
applied ordinary *implicit* bidi and simply ignored `bidi-override`
altogether. Ours: completely blank.

**Root cause of our blank render — confirmed NOT a bidi bug.** Isolated with
probes: plain ASCII text, same `font-family="Amiri"`, no
direction/unicode-bidi attributes at all → still renders blank. Same text
with `font-family="Noto Sans"` → renders normally. The blank output is
caused entirely by `resolveFontFamily("Amiri") = false` (our one embedded
family is "Noto Sans"; "Amiri" doesn't match), which is the same deliberate,
documented "unavailable font → draw nothing" policy noted in the file-1
general facts above, confirmed to faithfully mirror real usvg's
`process_chunk` fontdb-miss behaviour (`layout.rs:862-927`, `None ⇒
continue`).

**resvg's separate bidi-override bug, confirmed at the source level.** Same
mechanism as file 2: `parser/text.rs` never reads `AId::UnicodeBidi`;
`text/layout.rs`'s bidi call hardcodes an LTR base regardless of `direction`
and has no code path for "skip the algorithm entirely" semantics — resvg
silently treats `bidi-override` as absent.

**Verdict.** High confidence on what should happen per spec and unanimous
browser (plus Batik) agreement. High confidence, separately, that our own
blank render is caused by the font gate (verified with isolated probes) and
that this gate's behaviour is a correct, intentional mirror of real usvg
semantics, not a latent bug.

**Classification: mixed, overall (d).** The blank-render defect is **(c)**
deliberately not supported as scoped (single-Latin-font policy, faithfully
reproducing real usvg's fontdb-miss behaviour — there is nothing shallow to
fix without embedding a new font and, per `Text.lean`'s own docstring,
without adding complex-script shaping for Arabic's contextual joining
forms). `unicode-bidi: bidi-override` itself, taken in isolation, is a
genuinely narrow **(b)**-unimplemented feature (a plain, mechanical
whole-chunk character reversal — no UAX#9 run-splitting needed, unlike file
2's plain `direction:rtl`) — but it is nearly worthless to implement alone
here, since the font gate blocks any visible output regardless of bidi
handling. **Question for Rowan:** this is really a font-scope decision that
gates everything else — (1) leave non-Latin-script font support as a
permanent non-goal (in which case `bidi-override` alone is low-value, skip
or defer it), or (2) invest in an Arabic-capable font + basic contextual
shaping as a real, separate, larger feature (in which case implementing the
narrow `bidi-override` mechanic becomes worthwhile as part of that effort).
Lean toward documenting this as a non-goal unless Arabic/non-Latin-script
support is independently on the roadmap.

---

## 14. `text/writing-mode/tb-and-punctuation.svg`

**results.csv**: `chrome=1 firefox=1 safari=2 resvg=2 batik=2 inkscape=1 librsvg=2 svgnet=2 qtsvg=2`

**What it tests.** `writing-mode="tb"` Japanese text with punctuation
(`「こんにちは、日本。」`), `font-family="Mplus 1p"` (**unquoted**, on the
root `<svg>`) — exercises vertical-mode placement of small punctuation marks
in the upper-right of their character cell (JLREQ / CSS Writing Modes 3
`text-orientation: mixed` rules).

**Render observations.** Ours and resvg: both fully blank except
crosshair/frame — pixel-diffing them gives `max diff = 2` over 320 pixels
(pure AA noise on the shared crosshair geometry), matching the "1.000000
similarity" figure. Suite: the full string typeset correctly top-to-bottom
with corner-shifted punctuation, fully legible. Chrome (local): mostly
correct but missing the final punctuation cluster — likely a font-
provisioning artifact of this container's Chromium (results.csv says the
real `chrome=1`).

**Root cause of the blank renders is different for each engine, and neither
is a writing-mode bug.** resvg's blank output is a **confirmed, unrelated
upstream parsing bug**: with verbose logging, `resvg` emits `Failed to
parse font-family value: 'Mplus 1p'. Falling back to Times New Roman.` —
`svgtypes`'s `parse_ident` rejects identifiers containing a digit (the "1"
in "Mplus 1p") when unquoted, so the whole family value is discarded. This
matches open resvg issue
[#804](https://github.com/linebender/resvg/issues/804) ("Font family with
number inside falls back to default font"), compounded by
[#159](https://github.com/linebender/resvg/issues/159) ("no font match → no
text rendered"). Our blank output is the same font-availability policy as
files 1 and 13 (`resolveFontFamily("Mplus 1p") = false` regardless of
quoting) — plus, independently, this text is 100% CJK/punctuation with no
Latin fallback to partially rescue it, unlike file 1's `"Japan"` portion.

**Verdict.** High confidence: the suite's reference PNG is correct here
(properly shows the punctuation-placement feature under test); Chrome
(properly provisioned, per the CSV) likely agrees. resvg's blank output is a
real, citable upstream bug, not a considered design choice, so "matching
resvg" on this file is coincidental bug-for-bug compatibility.

**Classification: (c) deliberately not supported**, for the same root
reason as file 1 — no CJK glyph coverage exists in this renderer, so the
punctuation-placement feature under test cannot be observed or fixed
independent of a large, separate, out-of-scope CJK font/shaping effort.
Nothing writing-mode-related needs to change; our font-family matching
happens to reproduce resvg's *correct* judgment here (unavailable font ⇒ no
text) via an entirely different, robust mechanism, not by inheriting
resvg's digit-in-identifier parsing bug.

---

## Summary table

| # | file | class | correct reference | one-line cause |
|---|---|---|---|---|
| 1 | `alignment-baseline/hanging-on-vertical.svg` | (c) not supported | n/a (logic already correct) | blocked on single-Latin-font policy + no CJK glyphs, pre-existing/out of scope |
| 2 | `direction/rtl.svg` | (b)/(d) | chrome/firefox/safari/suite | `direction` never parsed; needs bounded bidi run-splitting + Arabic font/shaping for full visual fix |
| 3 | `font-size-adjust/simple-case.svg` | (b) small feature | firefox/safari/suite/CSS Fonts 4 | property parsed nowhere; metrics already available in `Font.lean` |
| 4 | `font-weight/650.svg` | **(a) — FIXED** | chrome/firefox/safari/librsvg/svgnet/qtsvg/suite | `parseFontWeight` dropped non-decade numeric weights; now falls back to `parseNumberAll` |
| 5 | `font/simple-case.svg` | (b) feature | suite (structurally) | `font` shorthand unexpanded for bare presentation attributes (resvg: only one of two delivery forms; ours: neither) |
| 6 | `glyph-orientation-horizontal/simple-case.svg` | (c) not supported | n/a | SVG2-removed property, zero modern-renderer support |
| 7 | `glyph-orientation-vertical/simple-case.svg` | (d) Rowan decision | safari/suite vs. resvg/chrome/firefox | deprecated-not-removed property; genuine parity-vs-spec policy question |
| 8 | `kerning/10percent.svg` | (c) not supported, flagged | batik/suite only | `<length>` value booleanized in both resvg and us, matching every maintained renderer |
| 9 | `text-anchor/coordinates-list.svg` | **(a) — FIXED** | chrome/safari/inkscape/suite | chunk fallback pen carried the anchor-*shifted* position instead of the raw advance |
| 10 | `text-decoration/style-resolving-4.svg` | (b) small feature | firefox/safari/suite | decoration thickness/offset use the rendered glyph's font-size, not the declaring ancestor's |
| 11 | `text-rendering/geometricPrecision.svg` | (c) not supported, documented | firefox/safari/svgnet (need real hinting) | no font-hinting engine in us or resvg |
| 12 | `tref/link-to-an-external-file-element.svg` | (c) not supported | n/a (browsers/resvg agree with us) | cross-file fetch forbidden by the no-second-file safety invariant; unresolvable-case handling already correct |
| 13 | `unicode-bidi/bidi-override.svg` | (c)/(b)/(d) | chrome/firefox/safari/batik | blank due to font gate (c); `bidi-override` itself unimplemented (b) but low-value without a font decision (d) |
| 14 | `writing-mode/tb-and-punctuation.svg` | (c) not supported | suite (chrome likely) | resvg's blank is an unrelated font-family parsing bug (#804); ours is the same CJK-glyph gap as #1 |

**Fixed in this task (class (a), corpus-gate verified, 0 regressions on
`resvg`-correct files):**
- `font-weight/650.svg` — commit `6dc6d98`
- `text-anchor/coordinates-list.svg` — commit `c1522c5`

Both fixed files now render *differently* from resvg and will show as
"fail" against resvg in `tests/run_tests.py`/`tests/run_corpora.py`'s
resvg-fidelity scoring — this is the intended, documented consequence of no
longer copying resvg's own marked mistakes on these two files.

---

## Questions for Rowan

1. **`direction`/bidi (files 2, 13).** Implement bounded UAX#9-subset
   run-splitting now (helps mixed-direction text generally), bundle it with
   an Arabic font + shaping investment so the RTL test class is fixed
   end-to-end, or formally declare non-Latin bidi/scripts a permanent
   non-goal? `unicode-bidi: bidi-override` (file 13) is cheap in isolation
   but nearly worthless without a font decision.
2. **`font-size-adjust` (file 3).** Implement the real CSS Fonts 4 formula
   (diverges from resvg, matches Firefox/Safari/spec, cheap given existing
   font metrics) or leave unimplemented (matches resvg's documented
   non-support)?
3. **`font="..."` shorthand (file 5).** Worth adding, given only 2 files in
   the whole corpus use it? If yes, both delivery forms (bare attribute +
   `style=`) or just the in-scope bare-attribute form? Is bold-italic
   synthesis (or a fourth embedded face) ever planned, or does "bold wins,
   drop italic" stay permanent?
4. **`glyph-orientation-vertical` (file 7).** Match resvg/Chrome/Firefox
   (recommended) or Safari/suite/spec?
5. **`kerning="<length>"` (file 8).** Leave the boolean-only simplification
   (matches resvg/chrome/firefox/safari; recommended) or implement the full
   deprecated-spec length-override behaviour (matches only Batik, needs a
   real text-layout change)?
6. **`text-decoration` declaring-ancestor font-size (file 10).** Proceed now
   as a second "spec/Firefox/Safari over resvg's acknowledged bug" fix
   (same policy question as file 9, already done), or bundle both under one
   deliberate decision about diverging from resvg on text layout?

No further shallow fixes are recommended beyond the two already applied;
every other file above is blocked on either a real feature, a scope
decision, or a hard project invariant (no external resources).
