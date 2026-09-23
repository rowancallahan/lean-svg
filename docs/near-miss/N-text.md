# N-text — text near-misses (97–99% within-8 at 200px)

Diagnosis only; no renderer code was changed. All 25 files rendered with
`resvg`/`usvg` 0.48.1 (fonts pinned to `tests/corpora/resvg-test-suite/fonts`)
and `.lake/build/bin/lean-svg`, both at `--width 200`, then diffed at
tolerance 8 the same way `tests/run_tests.py` does. Contact sheet:
`docs/near-miss/N-text.png` (resvg | ours | diff, diff gain ×4, one row per
file). Numbers below reproduce the task list's scores exactly, confirming the
render/oracle setup matches.

Two prior tasks (`tasks/T55-text-misc.md`, `tasks/T72-text-3.md`) already
triaged a much larger failing set down to this one; several groups below
reconfirm and sharpen their "not attempted"/"out of scope" notes with actual
pixel evidence, and two (font-family's exact fallback interaction, and a
chunk-anchor bug) are new.

## Per-file

### `text/font-family/font-list.svg` (0.98222) and `text/font-family/source-sans-pro.svg` (0.98222)

Byte-identical diffs (same 711 differing pixels, same bbox `(66,73)–(133,100)`
— confirmed by direct comparison). Both name `"Source Sans Pro"` first, and
the resvg-test-suite's pinned fonts directory *does* ship
`SourceSansPro-Regular.ttf`, so resvg draws the word "Text" in real Source
Sans Pro glyphs; we draw nothing at all (the whole diff region is the missing
word). **Cause:** `Text.resolveFontFamily` (`LeanSvg/Svg.lean:1716`) only
recognises two names — "Noto Sans" (available) and "Source Sans Pro"
(deliberately hard-coded `false`, since we do not embed it) — everything else
falls through to `false` too. This is a known, intentional simplification
(see the function's own doc comment and `tasks/T55-text-misc.md`'s report,
point 1), not a bug: it draws nothing where resvg draws a font we do not
have. **Code:** `LeanSvg/Svg.lean:1716` (`resolveFontFamily`), `LeanSvg/
Text.lean:55-87` (`Face`/`Faces`/`loadFaces`, only three faces exist).
**Fix:** embed a Source Sans Pro Latin subset the same way `NotoSansBold`/
`NotoSansItalic` are embedded (`LeanSvg/Fonts/*.lean`, `tests/
gen_font_module.py`), add a fourth `Face` case, and make
`resolveFontFamily`/`pickFace` select it for `"Source Sans Pro"`. **Size:**
medium — one more embedded font module (comparable to the existing
`NotoSansBold`/`NotoSansItalic` cost) plus a few lines of face selection.
**Risk:** low. `"Source Sans Pro"` appears nowhere else in the whole
resvg-test-suite (`grep -rl "Source Sans Pro" tests/` returns exactly these
two files), so the change cannot touch any other file's score.

### `text/font-kerning/arabic-script.svg` (0.98110)

Whole word gone: reference draws "الويب" in Amiri, ours draws nothing (crosshair
and frame are the only pixels that match). See the Arabic/CJK group below —
`font-kerning:none` (the feature under test) never gets exercised because the
font itself is unavailable first.

### `text/font-stretch/extra-condensed.svg`, `inherit.svg`, `narrower.svg` (0.97395 each)

Identical diffs across all three (1042 pixels, bbox `(62,71)–(137,100)`):
resvg draws "Text" visibly narrower (it substitutes
`NotoSans-ExtraCondensed.ttf`, also pinned in the fonts dir, for
`font-stretch: extra-condensed`/`condensed`-via-inherit/`narrower`), we draw
the same glyphs at normal width, so the diff is a ghosted double-exposure of
the word at two different widths. **Cause:** `font-stretch` is not parsed
anywhere in `LeanSvg/Svg.lean` and `Text.Face` has no condensed variant — the
value is silently ignored (already noted, unfixed, in `tasks/T55-text-
misc.md`'s "Not attempted" list and `tasks/T72-text-3.md`). **Code:**
`LeanSvg/Text.lean:55-87` (`Face`, `pickFace`), no `"font-stretch"` case in
`Svg.lean`'s `applyProp`. **Fix:** embed the condensed Noto Sans subset(s)
pinned in the test fonts dir and add a stretch axis to `Face`/`pickFace`,
parsing `font-stretch`'s keyword or percentage. **Size:** medium-large — CSS
`font-stretch` has nine keywords; matching resvg exactly needs at least the
`extra-condensed` face (these three files) and ideally the others usvg's own
`aspect_ratio`-style substitution can reach. **Risk:** low — `font-stretch`
is used nowhere else in the suite (`grep -rl font-stretch tests/` returns
only these three files).

### `text/letter-spacing/mixed-scripts.svg` (0.98620) and `text/letter-spacing/on-Arabic.svg` (0.98715)

Both fully blank (no glyphs at all, only crosshair/frame pixels match).
`mixed-scripts.svg` sets `font-family="Amiri"` on the root `<svg>`, inherited
by the whole `<text>` — so even the plain-Latin "Hello" half of "Hello مرحبا."
is dropped, not just the Arabic half. Arabic/CJK group, see below.

### `text/text-decoration/underline-with-rotate-list-4.svg` (0.98625)

Visually near-identical (dashed green/white gradient-filled rotated "Text"
with two underline segments); the diff is a faint, roughly-uniform tint over
almost the whole glyph+underline area rather than a sharp edge or a missing
region — consistent with a small, global colour-stop miscalculation rather
than a shape or position error. `tasks/T55-text-misc.md`'s report already
flags this exact file as "visually correct... off by what looks like
sub-pixel rounding in the composite bbox; not chased further" (98.2% then,
98.625% now). Having also found `real-text-height.svg`'s cause (see the
gradient-bbox group below) — a text gradient's `objectBoundingBox` should
come from font metrics (ascent/descent), not the tight glyph-outline
bbox `Shader.build` uses for every shape — the two are plausibly the same
root cause: a rotated, gradient-filled, multi-glyph run has a
per-character-height-dependent tight bbox that differs subtly from usvg's
uniform per-run box, smearing colour-stop placement everywhere at once
rather than only at one tall glyph (this file has no ascender outlier the
way `real-text-height.svg`'s "T" is). Not proven identical, but should be
re-examined together with that group before being treated as separate.
**Code/fix/size/risk:** see "Gradient/pattern bbox for text" below.

### `text/text-rendering/optimizeSpeed.svg` (0.98930) and `text/text-rendering/with-underline.svg` (0.98513)

Both diffs are thin outlines tracing the glyph edges only (no missing
region, no shift) — the signature of an anti-aliasing mismatch, not a
layout one. `optimizeSpeed.svg` has two "Text" labels stacked; only the top
one's edges differ. **Cause:** confirmed directly in the code, not inferred:
`LeanSvg/Svg.lean:3010-3013`'s own comment states "`text-rendering`, not
`shape-rendering`, decides glyph antialiasing... we do not support that
property, so glyphs stay antialiased regardless of an ambient
`shape-rendering`", and line 3014 hard-codes `crisp := false` on every text
shape. Meanwhile `shape-rendering: crispEdges`/`optimizeSpeed` is fully
wired for ordinary shapes: parsed at `LeanSvg/Svg.lean:2051-2054` into
`Style.crisp` (`LeanSvg/Svg.lean:100-106`), and `LeanSvg/Render.lean:294-297`
already swaps in `Raster.rasterizeCrisp` (`LeanSvg/Raster.lean:319-365`,
non-antialiased fill) whenever `st.crisp` is set. **Code:** `LeanSvg/
Svg.lean:3014` (hard-coded `crisp := false`); no `"text-rendering"` case
anywhere in `applyProp`. **Fix:** add a `text-rendering` `Style`/`SpanProps`
field (parsed the same way as `shape-rendering` at line 2051, mapping
`optimizeSpeed`/`crispEdges`-equivalent to non-AA — usvg's
`resolve_rendering_mode` in `text/flatten.rs` is the exact spec), and use it
in place of the hard-coded `false` at line 3014. No rasterizer work needed:
`Raster.rasterizeCrisp` already exists and is exactly what a non-AA glyph
outline needs. **Size:** small — mirrors an existing, working code path.
**Risk:** very low — new `Style` field, purely additive; does not touch
`shape-rendering`'s own field or behaviour (`painting/shape-rendering/
optimizeSpeed-on-text.svg`, which pins down that `shape-rendering` must
*not* affect text, stays correct either way since the two properties get
independent fields).

### `text/text/bidi-reordering.svg` (0.98242)

Fully blank; the whole line "…اقرأ المزيد عن SVG أيضًا" (Latin "SVG" mixed into
Arabic) never draws — same font-unavailable cause, see the Arabic/CJK group.

### `text/text/complex-graphemes.svg` (0.98078)

Reference draws "Й" (Cyrillic, base + combining breve, composed into one
glyph); ours draws two `.notdef` tofu boxes side by side at normal advance,
neither stacked nor omitted. **Cause:** the embedded `NotoSans*` subsets
(`LeanSvg/Fonts/NotoSans.lean` etc.) are Latin-only — `Font.glyphId`
(`LeanSvg/Font.lean:277`) correctly returns `0` for an unmapped codepoint,
the parser is not at fault, the *subset* just does not include the Cyrillic
block. Separately, even with Cyrillic coverage, a combining mark needs zero
advance and to stack over the preceding base glyph (Unicode's General
Category `Mn`/`Mc`/`Me`); `Text.layout`'s advance computation
(`LeanSvg/Text.lean:704-720`) has no such case and always calls
`Font.advance`, so a combining mark — even a *found* one — would still be
drawn beside its base rather than on top of it. **Code:** `LeanSvg/
Fonts/NotoSans.lean` (subset data), `LeanSvg/Text.lean:704-720` (advance
loop, no combining-mark check). **Fix:** regenerate the embedded Noto Sans
subset with the Cyrillic block included (`tests/gen_font_module.py`, a
data-only change), plus a small Unicode general-category table (or a
compact combining-mark range list) so `Text.layout` zeroes a combining
mark's own advance and does not start a new decoration/style run for it.
**Size:** small (subset regen) + small (combining-mark check). **Risk:**
low, additive; a combining-mark check only changes behaviour for codepoints
no test currently exercises correctly (they are all `.notdef` today).

### `text/text/escaped-text-4.svg` (0.97665)

Isolated the same coverage gap directly: `<text fill="red">А</text>` (Cyrillic
U+0410, visually identical to Latin "A") should be completely covered by a
black `&#x410;` on top of it. Reference shows solid black "A" (no red
showing); ours shows a `.notdef` box that does not fully cover the red glyph
underneath. Same cause and fix as `complex-graphemes.svg` above (Cyrillic not
in the embedded subset) — no combining-mark aspect here, just plain coverage.

### `text/text/fill-rule=evenodd.svg` (0.97108)

Fully blank (`font-family="Amiri"`, root-level, single run). The test's own
point — `fill-rule` must be ignored on text — is moot for us since nothing
draws at all. Arabic/CJK group, see below.

### `text/text/ligatures-handling-in-mixed-fonts-1.svg` (0.98862)

`<text font-family="Noto Sans">final <tspan font-family="Amiri">final</tspan>
</text>`. First "final" (Noto Sans, available) draws correctly and matches;
only the second "final" (Amiri tspan) is missing, a small, localised diff
right of centre. Because the *available* span comes first, the `<text>`
element's own `x`/`y` lands on a rendered character and the chunk anchors
correctly — this file does **not** hit the chunk-anchor bug below, unlike its
sibling. Cause, code, fix: Arabic/CJK group (embedding Amiri would fix the
remainder). Listed separately from the group's file count because the
*visible* effect here is "one word missing", not "everything missing".

### `text/text/ligatures-handling-in-mixed-fonts-2.svg` (0.97277)

Same markup as `-1.svg` with the two font-families swapped: `<text
font-family="Amiri" x="32" y="100">final <tspan font-family="Noto
Sans">final</tspan></text>`. Reference draws "final final" (Amiri, then Noto
Sans); ours draws **nothing at all** — not even the Noto-Sans-available
second word. Isolated and confirmed with a minimal repro
(`<text font-family="Amiri" x="10" y="100">X <tspan font-family="Noto
Sans">final</tspan></text>` also renders fully blank, with only 4 stray
antialiasing pixels at row 0 — i.e. the text lands off the top edge of the
canvas). **Cause, found fresh (not in either prior text task's report):**
usvg's position lists (`x`/`y`/`dx`/`dy`/`rotate`) are indexed by a
character's position **among all characters of the chunk, rendered or not**
— our own docstring says as much (`LeanSvg/Text.lean:824-828`, "chunk
starts and `x`/`y` use position among *all* characters"), and the position-
assignment code (`LeanSvg/Text.lean:635-657`) does this correctly: `<text
x="10" y="100">` assigns `x`/`y` to absolute character index 0, which here
is the *first* character of the unavailable-font span. But the chunk-anchor
lookup at `LeanSvg/Text.lean:773-775` —
```
let p0 := pos.getD (rend.getD a 0) {}
let chunkX : Int := match p0.x with | some v => v * 256 | none => lastX
let chunkY : Int := match p0.y with | some v => v * 256 | none => lastY
```
— reads the position belonging to `rend.getD a 0`, i.e. the index of the
*first rendered* character of the chunk (`a` indexes into `rend`, the
already-filtered array of renderable character indices, built at
`LeanSvg/Text.lean:670-673`). When the chunk's first character is
*unrendered* (unavailable font-family, or `display:none`), its `x`/`y` was
correctly recorded at that character's own absolute index, but nothing ever
reads it — position index 0 is simply skipped, `p0.x`/`p0.y` come back
`none`, and `chunkX`/`chunkY` silently fall back to `lastX`/`lastY`
(initialised to `(0, 0)` for the first chunk in the element). The whole run,
rendered characters included, ends up anchored at `(0, 0)` instead of
`(10, 100)`, which for a baseline-`y` of `0` puts every glyph's ink entirely
above row 0. **Code:** `LeanSvg/Text.lean:773-775` (chunk anchor), in the
context of the chunking loop starting `LeanSvg/Text.lean:690`. **Fix:** the
chunk-start test needs the position entry of the chunk's first character in
*document* order (rendered or not), not `rend`-order — e.g. track, alongside
`a` (an index into `rend`), the absolute character index the chunk actually
starts at (the first index `i` with `cSeg`/depth consistent with the current
chunk, before `rend`-filtering), and look `pos` up by that. This also needs
the *next*-chunk-boundary test (`LeanSvg/Text.lean:697-700`, which already
correctly reads `pos.getD (rend.getD q 0) {}` to detect a *later* explicit
`x`/`y` starting a new chunk) to be consistent with wherever the fix lands,
so a hidden character's own explicit position, if it is not the chunk's
first character, is not spuriously treated as starting a new chunk either.
**Size:** small-medium — one function, but touching how every chunk boundary
in every text file is computed. **Risk:** medium: this exact code path runs
for every `<text>` in the whole corpus, so a fix here is not purely additive
like the other groups and needs the full corpus + `tests/run_tests.py` +
`tests/run_adversarial.py` re-run, not just the affected file, before it can
be trusted not to regress a currently-passing file that also has a hidden
leading span (e.g. any `display:none`-prefixed chunk with its own `x`/`y` —
`rotate-and-display-none.svg`, cited in the neighbouring doc comment, is the
one file already known to probe this area and should be re-checked first).

### `text/text/real-text-height.svg` (0.98858)

Gradient-filled "Text" (green→red vertically by font metrics in the
reference). Reference: uniform green across all four glyphs. Ours: identical
except the top of the "T" ascender is red — the one glyph whose outline
reaches near the top of our (tighter, per-glyph) bounding box, picking up the
gradient's other end. `tasks/T55-text-misc.md`'s "Not attempted" section
diagnosed this exact cause already (usvg computes a text element's
`objectBoundingBox` from font metrics — `NonZeroRect(0, -ascent, advance,
ascent-descent)` per cluster, unioned per span — not from the tight glyph
outline every other shape uses) but did not have pixel evidence; this
confirms it precisely (only the ascender-height outlier differs, exactly as
the metrics-vs-outline explanation predicts). **Code:** `LeanSvg/
Shader.lean:941` (`Shader.build`, takes `cmds : Array PathCmd` and derives
`objectBoundingBox` from it — shared by every shape kind, not text-specific);
`LeanSvg/Svg.lean:3014`'s `Shape` construction for text has no bbox override
to give it something else. **Fix:** thread an optional bbox override through
`Shape` → `Render.lean`'s `paintMask` → `Shader.build`/`Grad.build`, and have
`Svg.lean`'s text path compute one from font metrics
(`Font.ascent`/`descent` already resolved, `LeanSvg/Font.lean:50-53`) per
span, unioned across the run, instead of leaving it `none` (→ current
tight-outline behaviour) for every other shape kind. **Size:** medium — the
override plumbing touches three shared modules, though as an *optional*
field it does not change behaviour for anything that does not supply one.
**Risk:** medium — `Shader.build`/`paintMask` are used by every gradient-
or pattern-painted shape in the renderer; must confirm the override stays
`None` (i.e. inert) for every non-text caller, then re-run the whole corpus.

### `text/textLength/arabic.svg` (0.98058) and `text/textLength/arabic-with-lengthAdjust.svg` (0.97070)

Fully blank, `font-family="Amiri"` at root. Arabic/CJK group.

### `text/textPath/with-underline.svg` (0.97960)

Reference: "Some long text" following a wavy path, underline curving with
it. Ours: the glyphs correctly follow the curve (that part matches), but the
underline is a single straight bar running across the very top of the
canvas, nowhere near the text. **Cause:** `Text.layout`'s per-character loop
sets `ox`/`oy` (the anchor every `DecorRun` captures, via `mkRun` at
`LeanSvg/Text.lean:913-919`) from `chunkX + x`/`chunkY + y` unconditionally
(`LeanSvg/Text.lean:832-833`), *before* branching on `flow.isSome`. Inside
the `flow.isSome` (on-path) branch (`LeanSvg/Text.lean:834-856`), the glyph
outline itself is correctly transformed using the path-mapped point and
tangent (`n.x`, `n.y`, `n.cos`, `n.sin`) — but `ox`/`oy` are never updated to
match, and `x`/`y` (the linear pen position `chunkX`/`chunkY` are offset by)
never advance in that branch either (they are only mutated in the `else`
branch, `LeanSvg/Text.lean:857-887`), so every on-path character's decoration
anchor stays at the chunk's raw start position — for `textPath` text, that is
wherever the (unrelated) linear default of `(chunkX, chunkY)` happens to be,
which for this file is near `(0, 0)`, explaining the bar sitting at the top
edge. This is exactly the gap `tasks/T50-textpath.md` and `tasks/T55-text-
misc.md` both flagged as future work ("`with-underline` (decoration, T55)"),
now pinned to the specific lines. **Code:** `LeanSvg/Text.lean:832-833`
(`ox`/`oy` initial assignment), `:834-856` (`flow.isSome` branch, no
equivalent update), `:913-919` (`mkRun`, consumes whatever `ox`/`oy`/`p.rot`
were left at). **Fix:** inside `flow.isSome`, recompute `ox`/`oy` from the
same path point `n` (and derive an effective rotation from `n.cos`/`n.sin`,
combined with `p.rot` the way the glyph transform already does at
`:850-855`) before `mkRun` runs, instead of leaving them at the chunk-linear
values. **Size:** small — localized to the one branch, reusing math already
present two lines away for the glyph outline. **Risk:** low — decoration on
`textPath` text draws incorrectly today in every case that reaches this
branch (there is no currently-passing file combining the two, since
text-decoration was only implemented in T55 after T50's textPath work), so
this cannot turn a pass into a fail.

### `text/tspan/bidi-reordering.svg` (0.97750)

Fully blank (`font-family="Amiri"` at root, no font-family switch between
the plain and gradient-filled tspans — confirmed the chunk-anchor bug above
does *not* apply here). Arabic/CJK group.

### `text/writing-mode/arabic-with-rl.svg` (0.98085), `text/writing-mode/mixed-languages-with-tb-and-underline.svg` (0.98448), `text/writing-mode/mixed-languages-with-tb.svg` (0.97977)

All fully blank. `tasks/T56-writing-mode.md`'s report already attributed
`arabic-with-rl.svg` to "missing Arabic glyph coverage (`font-family="Amiri"`,
unsupported...) and the lack of BiDi reordering, both pre-existing and out
of scope" and `mixed-languages-with-tb-and-underline.svg` similarly (plus,
at the time, missing `text-decoration`, since fixed by T55). This pixel
evidence adds one correction: the dominant effect is not "wrong glyph order"
but "zero glyphs" — resvg has real Amiri (and, for `mixed-languages-with-
tb.svg`, Mplus 1p) outlines to place via harfrust/rustybuzz shaping, we have
none, so 100% of the text vanishes rather than merely reordering. Arabic/CJK
group.

## Groups by shared cause, largest first

### 1. Arabic/CJK font-family names are "available" to resvg's pinned fonts dir but not to us (12 files)

`text/font-kerning/arabic-script.svg`, `text/letter-spacing/mixed-scripts.svg`,
`text/letter-spacing/on-Arabic.svg`, `text/text/bidi-reordering.svg`,
`text/text/fill-rule=evenodd.svg`, `text/text/ligatures-handling-in-mixed-
fonts-1.svg` (partial — only the Amiri half), `text/textLength/arabic.svg`,
`text/textLength/arabic-with-lengthAdjust.svg`, `text/tspan/bidi-
reordering.svg`, `text/writing-mode/arabic-with-rl.svg`, `text/writing-mode/
mixed-languages-with-tb-and-underline.svg`, `text/writing-mode/mixed-
languages-with-tb.svg`.

**Cause:** every one of these names `Amiri` (11 files) or `'Mplus 1p',
Amiri` (`mixed-languages-with-tb.svg`) as `font-family`, at the root `<svg>`
or the `<text>` element, inherited by the whole run. Both fonts are present
in `tests/corpora/resvg-test-suite/fonts/` (`Amiri-Regular.ttf`,
`MPLUS1p-Regular.ttf`), so resvg draws real, shaped, BiDi-reordered glyphs.
`Text.resolveFontFamily` (`LeanSvg/Svg.lean:1716`) treats any name that is
not literally `"Noto Sans"` as unavailable, so we draw **nothing** for the
whole element — not "wrong order", not "wrong glyph shapes", a blank canvas
except for whatever crosshair/frame decoration the file also draws. This is
architecturally the same fallback-policy simplification as the "Source Sans
Pro" group below, just with 6x the blast radius and, unlike that group, a
much bigger tail even if the font were embedded.

**Code:** `LeanSvg/Svg.lean:1716` (`resolveFontFamily`); even with a face to
select, `Text.layout`'s docstring (`LeanSvg/Text.lean:20-29`) states the
renderer does "one glyph per character (no ligatures, no complex-script
shaping, no BiDi reordering — every run is left to right)", which is
necessary for Arabic (contextual joining forms: isolated/initial/medial/
final glyph variants selected by `GSUB`, not implemented — `Font.lean`'s own
module docstring at lines 24-29 lists only `cmap`/`kern`/`GPOS`-pair tables
as read, no `GSUB`) and for correct visual order (`unicode-bidi`/UAX#9, not
implemented anywhere in `Svg.lean`).

**Proposed fix, in order of payoff:** (1) embed Amiri (and, lower priority,
Mplus 1p) as new `Face`s, the same mechanism as the Source Sans Pro fix
below — this alone fixes nothing visually for Arabic since one-codepoint-
per-isolated-glyph Arabic is illegible/wrong-shaped, but is a prerequisite;
(2) implement basic Unicode BiDi reordering (at least the common case: one
paragraph embedding level, no explicit `direction`/`unicode-bidi` overrides)
so a chunk's rendering order matches logical-to-visual reordering; (3)
implement Arabic contextual shaping (a compact table mapping each Arabic
letter's four joining-context glyph variants, keyed off cmap/GSUB, without a
full HarfBuzz-equivalent engine). **Size:** large — (1) is medium alone,
(2)+(3) are a substantial new subsystem, well beyond "diagnose" scope and
likely deserving its own task. **Risk if attempted:** BiDi reordering and
per-character shaping are not additive the way every other group here is —
they change the fundamental "one glyph per character, left to right"
assumption `Text.layout`'s docstring states as this renderer's scope, so any
implementation must be gated to only affect scripts that need it (Arabic/
Hebrew ranges) to avoid regressing the Latin-text majority of the corpus;
needs a full-corpus re-run, not just this file list. **Could a fix touch
currently-passing files?** Only if scoped incorrectly. `Amiri` is also named
in 7 further resvg-test-suite files not in this list (`grep -rl Amiri
tests/`: `text-anchor/on-tspan-with-arabic.svg`, `text/x-and-y-with-
multiple-values-and-arabic-text.svg`, `unicode-bidi/bidi-override.svg`,
`writing-mode/tb-with-rotate.svg`, `writing-mode/tb-with-rotate-and-
underline.svg`, plus this list's own two `ligatures-handling` files) — all
of them already fail outright (well below the 97% near-miss bar, some
explicitly marked "(UB)" by the suite itself), so none can regress from
"pass" to "fail"; they would simply move together with whatever this group's
fix achieves.

### 2. `font-stretch` unimplemented (3 files)

`text/font-stretch/extra-condensed.svg`, `inherit.svg`, `narrower.svg`. See
per-file entry above. **Size:** medium-large. **Risk:** low, isolated (no
other corpus file uses `font-stretch`). **Could touch passing files?** No.

### 3. `"Source Sans Pro"` is available to resvg, not to us (2 files)

`text/font-family/font-list.svg`, `text/font-family/source-sans-pro.svg`.
See per-file entry above. **Size:** medium (one embedded font). **Risk:**
low, isolated (no other corpus file uses the name). **Could touch passing
files?** No.

### 4. `text-rendering` (glyph antialiasing) unimplemented (2 files)

`text/text-rendering/optimizeSpeed.svg`, `text/text-rendering/with-
underline.svg`. See per-file entry above; the fix reuses existing,
already-correct `shape-rendering`/`crisp` machinery verbatim. **Size:**
small. **Risk:** very low — new field, does not alter `shape-rendering`'s
own behaviour (`painting/shape-rendering/optimizeSpeed-on-text.svg`, which
specifically checks that `shape-rendering` must *not* affect text, keeps
passing under either implementation since the two stay independent fields).
**Could touch passing files?** No — additive field with a default that
reproduces today's always-antialiased behaviour.

### 5. Embedded font is Latin-only: no Cyrillic, no combining-mark handling (2 files)

`text/text/complex-graphemes.svg`, `text/text/escaped-text-4.svg`. See
per-file entries above. **Size:** small (subset regen) + small
(combining-mark advance fix). **Risk:** low, additive. **Could touch
passing files?** Unlikely — would only change output for codepoints that
are `.notdef` today (drawn as tofu boxes), which by definition cannot be
part of any currently-*passing* file's matched pixels.

### 6. Gradient/pattern bbox for text uses the tight glyph-outline box, not usvg's font-metrics box (1-2 files)

`text/text/real-text-height.svg` confirmed; `text/text-decoration/
underline-with-rotate-list-4.svg` plausible same cause, not proven — see its
per-file entry. **Size:** medium (shared bbox-override plumbing). **Risk:**
medium — touches `Shader.build`/`paintMask`, used by every gradient/pattern-
painted shape; must stay inert (`None` override) for every non-text caller.
**Could touch passing files?** Only text shapes painted with a gradient or
pattern under `objectBoundingBox` are affected at all; a careful,
opt-in-only override should leave every other shape (the vast majority of
the corpus) untouched, but this is the one group here where that must be
verified with a full-corpus run rather than assumed.

### 7. `textPath` text-decoration is anchored to the linear pen, not the path (1 file)

`text/textPath/with-underline.svg`. See per-file entry above. **Size:**
small. **Risk:** low — this combination (`textPath` + `text-decoration`)
draws wrong in 100% of cases that reach it today, so there is no passing
baseline to regress. **Could touch passing files?** No.

### 8. Explicit `x`/`y` on a hidden character is lost, dropping the whole chunk to `(0,0)` (1 file)

`text/text/ligatures-handling-in-mixed-fonts-2.svg`. See per-file entry
above — the newest and, per-file, highest-impact finding (a total loss of
position, not a subtle pixel drift). **Size:** small-medium. **Risk:**
medium — the affected function runs for every `<text>` element in the
corpus, so unlike every other group here a fix is not purely additive and
needs a full `tests/run_tests.py` + whole-corpus re-run, with particular
attention to `rotate-and-display-none.svg` (the one existing test already
probing "does a hidden character's own position-list slot get consumed
correctly"). **Could touch passing files?** Possibly, if not scoped
carefully — flagged as the one group here that most needs the "before/after,
zero pass→fail" corpus check any future task on it must run.
