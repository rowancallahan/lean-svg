# R4 — resvg-wrong: text layout (`textPath`, `text`, `tspan`)

16 files where resvg 0.48.1 itself is marked wrong in
`tests/corpora/resvg-test-suite/results.csv`. For each: what the four
references show at 200 px wide (ours, resvg, the suite's own PNG, headless
Chromium), what the correct output is and why, and a classification.

Render commands used throughout:

```
.lake/build/bin/lean-svg FILE OUT --width 200
resvg --skip-system-fonts --use-fonts-dir tests/corpora/resvg-test-suite/fonts -w 200 FILE OUT
python3 tests/render_chrome.py OUT_DIR 200 FILE
# suite PNG: tests/<...>.png next to the SVG, resized to 200 wide with Pillow/LANCZOS
```

Two root causes explain 13 of the 16 files; the other 3 are independent.

---

## Group A — no glyph coverage beyond Latin (class c, all 5)

The renderer embeds three subsets of Noto Sans (regular/bold/italic), Latin
only (DESIGN.md §"Faces": "font-family selects nothing: every family falls
back to Noto Sans"). Any codepoint outside that subset has no glyph and
becomes an empty `.notdef` outline — the character takes its advance width
but paints nothing. There is no code bug to fix: this is the documented
fallback policy, and none of these five files are readable by our layout
algorithm regardless of glyph lookup logic, because the required glyphs
(Cyrillic, CJK, colour emoji) do not exist in the binary.

Embedding a colour-emoji font (COLR/CPAL or bitmap strikes) or a CJK face
would multiply the binary size by orders of magnitude (Noto Sans CJK alone is
tens of MB; Noto Color Emoji likewise) for a renderer whose whole footprint
is deliberately small and dependency-free. Treated as out of scope unless
Rowan says otherwise (see Questions).

### `text/text/emojis.svg`

`font-family="Noto Color Emoji"`, four emoji codepoints (`😀😁😂🤣`),
`text-anchor="middle"`. resvg, the suite PNG and Chromium all render the four
emoji in full colour (chrome=1, firefox=1, safari=1 in `results.csv` — every
browser agrees, resvg is the outlier). Ours renders nothing: none of the four
codepoints are in the Latin subset. **Class (c).**

### `text/text/compound-emojis.svg`

One compound emoji, `🏳️‍🌈` (rainbow flag = white flag + ZWJ + rainbow,
a compound grapheme cluster from four codepoints). resvg/suite/chrome all
render the composed rainbow-flag glyph. Ours renders nothing (no coverage,
and no ZWJ-sequence composition either — moot here since there's no glyph
data to compose in the first place). **Class (c).**

### `text/text/compound-emojis-and-coordinates-list.svg`

`😁🦀🏳️‍🌈` with a 4-entry `x`/`y` coordinate list (one entry per grapheme
cluster: smiley, crab, and the compound flag). resvg/suite/chrome place three
clusters along the baseline with y-jitter (90, 111, 130 — the list has a
4th value, 150, which is unused since there are only 3 clusters). Ours
renders nothing, same as above. **Class (c).**

### `text/text/xml-lang=ja.svg`

Three copies of `刃直海角骨入`ac (Han-unification test: default,
`xml:lang="ja"`, `xml:lang="zh-HANT"` — glyph shapes for some of these
characters legitimately differ between Japanese and Chinese type). resvg,
suite and Chromium each render three visually-distinct rows (subtly, since
this is a Han-unification nuance — see the referenced
`your-code-displays-japanese-wrong` article in the file's `<desc>`). Ours
renders six `.notdef` boxes per row (no CJK glyphs at all, and no
`xml:lang`-based font-selection logic either, which would only matter once
CJK glyphs exist). **Class (c).**

### `text/text/complex-graphemes-and-coordinates-list.svg`

One character, encoded as **two codepoints**: U+0438 CYRILLIC SMALL LETTER I
followed by U+0306 COMBINING BREVE (this is the decomposed form of "й", not
the precomposed U+0439). `x="87" y="100 120"` — two `y` values for what is
one grapheme cluster. The `<desc>` states the point of the test: *"y=120
should be ignored, because coordinate lists affect only grapheme start
positions, even though coordinate lists specified per code point."*

resvg and Chromium render something close to "И" with the breve merged in
oddly (both apparently split the `y` list per-codepoint too, which is
arguably why resvg itself is marked wrong here — chrome=2, safari=2, only
firefox=1 in `results.csv`). The suite PNG renders a clean "Й"-looking glyph,
one grapheme, ignoring the second `y`. Ours renders two `.notdef` boxes,
offset vertically from each other by the `y` list (100 vs 120): our Latin
subset has no Cyrillic glyphs (root cause, same as Group A), **and**
`LeanSvg/Text.lean`'s per-character layout has no concept of a grapheme
cluster — `dx`, `dy`, `rotate` position lists are matched to codepoints per
`Text.layout`'s docstring ("no complex-script shaping"), not to
Unicode-grapheme-cluster boundaries, so even with a Cyrillic glyph present
the second `y` would still wrongly apply to the combining mark alone.

Primary cause is missing glyph coverage — **class (c)**, same as the rest of
Group A. The secondary gap (no grapheme-cluster-aware position lists) is
real and would also affect Latin combining-diacritic sequences (e.g. `e` +
U+0301 COMBINING ACUTE ACCENT) if the corpus ever exercises one; it doesn't
today, so it's flagged as a question rather than scoped in.

---

## Group B — `clip-path`/`filter`/`mask`/`opacity` on `tspan`/`textPath` are parsed but never promoted to a layer (class b, 5 files)

All five of these files apply one of SVG 2's per-element compositing
properties directly to a `<tspan>` or `<textPath>`, not to the `<text>`
element. `LeanSvg/Svg.lean`'s `textShapes` does resolve these onto the
tspan's `Style` (`applyEff` at Svg.lean:2913 runs the same attribute parser
used everywhere else, so `Style.ownOpacity`/`clipRef`/`maskRef`/`filterRaw`
are all set correctly — confirmed by grep, nothing outside `Svg.lean` even
reads these fields, so the *parsing* is not the gap).

The gap is downstream: `textShapes` turns each `Text.Placed` run straight
into a bare `Shape` (Svg.lean:3006-3014, `out := out.push ⟨p.cmds, { st with
... }, false, none⟩`) with no `groupBegin`/`groupEnd` wrapper. Every other
element that carries one of these four properties gets promoted into its own
compositing layer first (`Group::should_isolate`, DESIGN.md §3.9 — see
Svg.lean:3050/3854/4107 for the three other places that same
`ownOpacity != 1 || blend != normal || isolate || clipRef.isSome ||
filterRaw.isSome` check runs and pushes a `.groupBegin`/`.groupEnd` pair). A
tspan/textPath run never goes through that check, so its `ownOpacity`
sits unread, `clipRef`/`maskRef` are never turned into a `Clip.Mask`, and
`filterRaw` is never resolved by `Filter.resolve`. The glyphs paint exactly
as if the property weren't there.

resvg has the identical bug (usvg does not isolate a `tspan`/`textPath`
either — `results.csv` marks it wrong on all five), which is why our score
against resvg is high (0.994–0.9998) despite being visibly wrong against the
suite PNG and Chromium, which agree with each other on all five.

**Not a shallow fix**: making a `tspan`/`textPath` run promotable to a layer
needs `textShapes` (or its caller around Svg.lean:3868) to detect a
non-default style on a run and emit `Node.groupBegin`/`Node.groupEnd` around
that run's one `Shape`, the same construction already used for `<rect
opacity="0.5">`. That's a plumbing change (the function currently returns
`Array Shape`, not `Array Node`) rather than a few lines, so it's real
feature work. Estimate: moderate — the layer machinery, clip masks, and
filter resolution already exist and are reused as-is; the work is entirely
in getting one `Shape` in and out of that machinery from inside text layout
instead of from the main element walk.

### `text/tspan/with-opacity.svg`

`<tspan opacity="0.5">long</tspan>` inside "Some long text". Suite and
Chromium both render "long" visibly lighter gray; resvg and ours render all
three words in uniform black. **Class (b).**

### `text/tspan/with-clip-path.svg`

`<tspan clip-path="url(#clip1)">` with a clip rect `y="0" height="80"`
against `font-size="64"` text baselined at `y="100"` — the clip should cut
off the lower portion of the glyphs. Suite and Chromium both show "Text"
with its lower halves clipped away (looks like a truncated, italic-leaning
"Text"); resvg and ours both show the full, unclipped word. **Class (b).**

### `text/tspan/with-mask.svg`

`<tspan mask="url(#mask1)">` with a mask whose content is a
`fill="gray"` rect (≈50% luminance → ≈50% effective opacity). Suite and
Chromium both render "Text" visibly greyed; resvg and ours both render it
solid black, mask ignored. **Class (b).**

### `text/tspan/with-filter.svg`

`<tspan filter="url(#filter1)">` with `feGaussianBlur stdDeviation="4"`.
Suite and Chromium both render a blurred "Text"; resvg and ours both render
it crisp, filter ignored. **Class (b).**

### `text/textPath/with-filter.svg`

Same bug, on `textPath` rather than `tspan`: two `<textPath>` children of one
`<text>`, only the second carries `filter="url(#filter1)"` (the same
`feGaussianBlur`). Suite and Chromium both render the first line crisp and
the second visibly blurred (blur radius differs a little between the two —
expected, Gaussian-blur implementations aren't bit-identical across
renderers — but both agree qualitatively). resvg renders something visibly
*wrong* rather than merely unfiltered: a dark, blob-like smear across both
lines, suggesting it computes some filter region incorrectly here (out of
scope to chase further for this file, since our own bug is the simpler
"filter ignored entirely," same as the tspan case). Ours renders both lines
crisp, filter ignored. **Class (b).**

---

## Group C — `path` attribute on `textPath` (SVG 2) is not implemented at all (class b, 3 files)

SVG 2 lets `<textPath>` carry a `path` attribute with inline path data,
instead of (or with fallback from) `xlink:href`/`href` to a separate
`<path>` element. `LeanSvg/Svg.lean`'s `textPathHref` (Svg.lean:2685) and
`textPathTables` (Svg.lean:2698) only ever look at `href`/`xlink:href`; there
is no code path that reads a `path` attribute on `textPath` at all. resvg
(usvg 0.48.1) doesn't implement it either — confirmed by usvg's own stderr
warnings during these renders ("Failed to parse href value: 'path1'" /
`'path2'`, because those `xlink:href` values are missing the leading `#`
that would make them local IRI references — see per-file notes below) and by
`results.csv` marking resvg wrong on all three.

**Chromium doesn't implement `path` either** — it renders no text in all
three cases, same as resvg and ours. Per `results.csv`, only Firefox is
correct on these three (chrome=2, safari=2, firefox=1 in every row). Per the
task rules, a shallow fix needs the suite PNG *and* Chromium to agree, and
they don't here, so this is not eligible for a class-(a) fix even though the
suite PNG's behaviour is clearly spec-correct (SVG 2 §`text-path`). See
Questions.

### `text/textPath/with-path.svg`

`<textPath path="M 20 100 C 35 135 85 135 100 100 C 115 65 165 65 180 100">`,
no `href` at all. Suite PNG: text follows the curve. resvg/Chromium/ours: no
text at all (nothing to fall back to, since we — and Chromium, and resvg —
never read `path`). **Class (b)**, blocked from class (a) by Chromium
disagreeing with the suite reference.

### `text/textPath/with-path-and-xlink-href.svg`

Both a valid `path` attribute (the same long curve) and `xlink:href="path2"`
(a short straight line, `id="path2"` in `<defs>`) — testing that `path` wins
over `href` when both are present (SVG 2 §`text-path`, `path` takes
precedence). Note `xlink:href="path2"` has no leading `#`, so it fails
usvg's own IRI parsing regardless (usvg logs "Failed to parse href value:
'path2'"); our `textPathHref` has the identical `#`-required rule
(Svg.lean:2691, `at' t 0 == 35`), so we'd fail to resolve that `href` too,
even if we did implement `path`. Suite PNG: text on the long curve (i.e.
`path` used, as intended). resvg/Chromium/ours: no text (no `path` support,
and the `href` doesn't parse either, so there is truly nothing to fall back
to on our side or resvg's). **Class (b)**, same blocker as above.

### `text/textPath/with-invalid-path-and-xlink-href.svg`

`path="q"` (deliberately invalid path data) and `xlink:href="path1"`
(also missing the leading `#`) — testing the SVG 2 fallback rule stated in
the file's own `<desc>`: *"If the `path` attribute contains an error, the
`href` attribute must be used."* Suite PNG: text follows `path1`'s curve
(the fallback happened). resvg logs the same "Failed to parse href value:
'path1'" warning as above and renders no text; Chromium renders no text too;
ours renders no text (we don't read `path` and would also reject the
`#`-less `href`). Firefox is the only reference renderer that gets this
right per `results.csv`. **Class (b)**, and also the file with the shakiest
test data: even fixing `path` support wouldn't be enough here on our current
`href` parsing, since `xlink:href="path1"` (no `#`) fails our rule the same
way it fails usvg's. Making this file pass would need *both* `path` support
*and* a decision about whether unprefixed `href` values should be treated as
local ids (see Questions — that would be a behaviour change affecting every
other `href`/`xlink:href` use in the renderer, not just `textPath`).

---

## Group D — `side="right"` on `textPath` is parsed as an attribute but never applied (class b, 1 file)

### `text/textPath/side=right.svg`

SVG 2's `side` property flips text to the other side of the path (mirrors it
across the path's tangent, "upside-down" for a path this shape). Suite PNG:
text is flipped/mirrored below the path, reading right-to-left along it.
resvg, Chromium and ours all render it identically to the default
`side="left"` case — `side` has no effect. `results.csv`: chrome=2,
safari=2, firefox=1, resvg=2 — again only Firefox is correct.

Implementing `side="right"` itself would be small (negate the offset along
the path normal and reverse the per-glyph rotation sign in
`LeanSvg/TextPath.lean`'s placement math — the "T(n) · R(tangent) ·
T(-width/2, dy) · R(rotate)" composition in `Text.lean`'s `layout` already
has the normal vector `n` available per glyph). But the same "suite and
Chromium must agree" rule blocks a class-(a) fix: Chromium doesn't implement
`side` either. **Class (b)**, small, but blocked from (a) by the evidence
rule, same reasoning as Group C.

---

## Group E — `method="stretch"` / `spacing="auto"` on `textPath`: already close, Chromium is the outlier (class b, low priority, 2 files)

SVG 1.1 defines two axes `textPath` can vary independently: `method`
(`align`, the default — glyphs are rotated to follow the path tangent but
not distorted; or `stretch` — glyphs are additionally scaled/sheared to fit
the path segment exactly) and `spacing` (`exact` — glyphs positioned at
their nominal advance along the path; or `auto`, the default — the renderer
may adjust spacing slightly for better fit). We only implement the default
pair (`align`/`auto`-as-`exact`, effectively); `method="stretch"` and an
explicit `spacing="auto"` are both accepted as attributes but have no effect
on layout beyond what the defaults already do.

For both files, **resvg, the suite PNG and ours are visually close** (a
pixel diff between resvg's own render and the suite PNG at natural size —
`method=stretch.svg` — shows only 2.2% of pixels differing at all, 1.3% by
more than 30/255, concentrated on anti-aliased glyph edges along the curve).
Chromium is the outlier on both: its text runs measurably shorter along the
path (visibly more compressed), suggesting Chrome's own handling of one of
`method`/`spacing` differs from what resvg/the suite/us happen to already
agree on. Because Chromium disagrees with the suite reference, neither file
is eligible for a class-(a) fix under the task rule even though our output
is already close to correct.

### `text/textPath/method=stretch.svg`

`results.csv`: chrome=2, firefox=2, safari=2, resvg=2 — every renderer here
is marked wrong, including the suite's own presumed-correct value; the
"correct" `stretch` rendering (each glyph individually sheared/scaled to the
exact path segment under it) may not be implemented by *any* renderer in the
comparison set. **Class (b)**, low priority: the gap between our output and
the reference is already small, and implementing true per-glyph stretch
(shear + scale transform per glyph tied to local path curvature, threaded
through `Text.layout`'s `nrm`/`TextPath.normals` machinery) is real
geometry work for a visually marginal difference.

### `text/textPath/spacing=auto.svg`

Same pattern as `method=stretch`: resvg/suite/ours agree closely, Chromium
is the outlier (chrome=2, firefox=2, safari=2, resvg=2 — same "everyone's
marked wrong" pattern as above). **Class (b)**, low priority, same reasoning.

---

## Summary table

| file | class | correct reference | one-line cause |
|---|---|---|---|
| `text/text/emojis.svg` | c | resvg + suite + chrome (all agree) | no colour-emoji glyphs (Latin-only embedded font) |
| `text/text/compound-emojis.svg` | c | resvg + suite + chrome | no colour-emoji glyphs |
| `text/text/compound-emojis-and-coordinates-list.svg` | c | resvg + suite + chrome | no colour-emoji glyphs |
| `text/text/xml-lang=ja.svg` | c | resvg + suite + chrome | no CJK glyphs |
| `text/text/complex-graphemes-and-coordinates-list.svg` | c | suite PNG | no Cyrillic glyphs; also no grapheme-cluster-aware position lists (latent) |
| `text/tspan/with-opacity.svg` | b | suite + chrome | `opacity` on `tspan` parsed but never promoted to a layer |
| `text/tspan/with-clip-path.svg` | b | suite + chrome | `clip-path` on `tspan` parsed but never promoted to a layer |
| `text/tspan/with-mask.svg` | b | suite + chrome | `mask` on `tspan` parsed but never promoted to a layer |
| `text/tspan/with-filter.svg` | b | suite + chrome | `filter` on `tspan` parsed but never promoted to a layer |
| `text/textPath/with-filter.svg` | b | suite + chrome | `filter` on `textPath` parsed but never promoted to a layer |
| `text/textPath/with-path.svg` | b | suite PNG (Firefox only among renderers) | `path` attribute on `textPath` (SVG 2) not implemented |
| `text/textPath/with-path-and-xlink-href.svg` | b | suite PNG (Firefox only) | `path` not implemented; `href` also fails our (and usvg's) `#`-required rule |
| `text/textPath/with-invalid-path-and-xlink-href.svg` | b | suite PNG (Firefox only) | `path`-invalid→`href`-fallback not implemented; `href` also fails the `#`-required rule |
| `text/textPath/side=right.svg` | b | suite PNG (Firefox only) | `side="right"` parsed but never applied |
| `text/textPath/method=stretch.svg` | b, low priority | none cleanly (all renderers marked wrong incl. resvg) | `method="stretch"` not implemented; existing output already close |
| `text/textPath/spacing=auto.svg` | b, low priority | none cleanly (all renderers marked wrong incl. resvg) | `spacing="auto"` not implemented; existing output already close |

No class-(a) shallow fixes were made. Every file that has a clear-cut,
spec-agreed correct answer (Groups B) needs the same non-trivial plumbing
change (layers for `tspan`/`textPath`); every file with a smaller potential
fix (Group D's `side="right"`) is blocked from the class-(a) bar by
Chromium disagreeing with the suite reference, per the task's own evidence
rule. The corpus gate was not run because no code changed.

---

## Questions for Rowan

1. **Group A (emoji/CJK/Cyrillic glyph coverage).** Confirmed out of scope
   given the embedded-font-size constraint, but flagging explicitly: is
   "Latin-only, falls back silently" the policy we want long-term, or would
   a much smaller partial expansion (e.g. Cyrillic, which is a few hundred
   glyphs, not the tens of thousands CJK needs) ever be worth it? No action
   needed unless you want it.

2. **Groups C and D (`path` attribute, `side="right"`).** Both are real SVG
   2 features where **Firefox is the only renderer in the whole comparison
   set that gets it right** — not resvg, not Chromium, not Safari. Matching
   resvg/usvg is our stated reference behaviour (DESIGN.md §"Reference
   behaviour"), and implementing these would be a deliberate, permanent
   divergence from that reference for four files' worth of benefit, in
   exchange for matching a spec reading that only one browser bothers with.
   Worth doing, or worth leaving as documented known gaps?

3. **Group B (layers for `tspan`/`textPath`).** This is the one place in
   this batch with a clean, uncontested correct answer (suite and Chromium
   agree on all five files) and a clear, if not tiny, path to a fix (reuse
   the existing `groupBegin`/`groupEnd` layer machinery from inside
   `textShapes`, per Svg.lean:3006-3015 and the three existing call sites at
   Svg.lean:3050/3854/4107 that do the equivalent check for ordinary
   elements). Worth scheduling as a real task (fix-R4 or similar) even
   though it isn't a "few lines"?

4. **`with-invalid-path-and-xlink-href.svg`'s `href` values lack the leading
   `#`** (`xlink:href="path1"`, not `"#path1"`) — this looks like it could
   be a typo in the upstream resvg-test-suite fixture rather than a
   deliberate test of unprefixed-IRI handling, since usvg itself logs a
   parse warning on it. Not proposing we change our `#`-required rule to
   work around one test file's typo (that rule is shared by every other
   `href`/`xlink:href` use in the renderer and changing it has a much wider
   blast radius than this one file) — just flagging that even a full
   `path`-attribute fix (Group C, Question 2) would not make this
   particular file pass without also touching that rule.
