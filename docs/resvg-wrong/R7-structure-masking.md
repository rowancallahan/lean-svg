# R7 — resvg-wrong research: structure and masking

Evidence gathered 2026-09-23 against resvg/usvg **0.48.1** (built from
`cargo install resvg --version 0.48.1 --locked`, same as the corpus gate),
the resvg-test-suite's own `results.csv` and reference PNGs, and headless
Chromium (`tests/render_chrome.py`, Playwright's bundled build). All
renders below are at 200 px wide. The resvg 0.48.1 source used for the
"Rust source is the spec" citations was cloned locally
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`).

The comparison sheet for all twelve files is
`docs/resvg-wrong/R7-structure-masking.png` (one row per file: resvg |
suite PNG | chrome | ours).

No shallow (class a) fixes were made. See the summary table for why: every
file is either a genuine usvg/resvg feature gap that also needs real work in
this renderer (class b), a case where rendering the "correct" output would
mean resolving a second file or a network URL, forbidden by `Prog`'s and
`Effect.lean`'s architecture (class c), or — one file — not actually wrong
against resvg 0.48.1 at all, despite what `results.csv` says.

---

## `masking/clip/simple-case.svg`

**What it tests.** `<title>Simple case</title>`. A single `<image>` with
the legacy CSS2 presentation attribute `clip="rect(10,10,10,10)"` (not
`clip-path`). Per CSS2.1 the four values of `rect(top,right,bottom,left)`
are offsets from the element's own edges, so this should clip the image to
a 10×10 square at its top-left corner.

**Renders.** resvg, Chromium and ours all render the full, unclipped 64×64
image (orange "SVG" logo). Only the suite's own reference PNG shows the
10×10 crop. `resvg vs suite` mean abs pixel diff 48.3 / 255; `resvg vs
chrome` 0.8 (near-identical); `ours vs resvg` 0.0 (byte-identical).

**Spec / evidence.** The `clip` property was deprecated by CSS Masking
Module Level 1 in favour of `clip-path`
(https://www.w3.org/TR/css-masking-1/, Appendix B lists `clip` as a legacy
alias with note "New content should use the `clip-path` property"), and per
the task's own reference table **chrome=2, firefox=2, safari=2** — all
three current engines already treat `clip` as unsupported/inert, matching
resvg and matching our own Chromium render here. The suite's reference PNG
predates that deprecation. `LeanSvg/Svg.lean`'s attribute list (§3.3,
`fill stroke fill-opacity ... visibility display style`) never parses
`clip`, so we already do the same thing resvg and every current browser do.

**Correct reference:** resvg / current Chromium (both live, both agree).
The suite PNG is stale w.r.t. what every renderer still shipping supports.
Confidence: high.

**Classification: (c)** — deliberately not supported. `clip` is a
deprecated CSS2 property with zero support in resvg 0.48.1 or any current
browser engine; implementing it would target a reference no live UA
follows. No related resvg issue found for this file specifically (searched
`linebender/resvg` and `RazrFalcon/resvg` for "clip" + "simple-case";
nothing on point) — this looks like a case the suite itself hasn't revisited
since browsers dropped `clip`.

---

## `masking/clipPath/circle-shorthand.svg`, `circle-shorthand-with-view-box.svg`, `circle-shorthand-with-stroke-box.svg`

**What they test.** `<title>Circle shorthand (SVG 2)</title>` /
`` `view-box` `` / `` `stroke-box` ``. `clip-path="circle()"`,
`"circle() view-box"`, `"circle() stroke-box"` on a `<rect>` — the CSS
Masking / CSS Shapes `<basic-shape> || <geometry-box>` grammar
(https://www.w3.org/TR/css-masking-1/#the-clip-path,
https://www.w3.org/TR/css-shapes-1/#basic-shape-functions), where `circle()`
with no radius defaults to `closest-side` from the box center, and the
optional keyword selects the reference box (default border-box; `view-box`
is the SVG-specific reference box CSS Masking Level 1 adds for SVG
content; `stroke-box` includes the stroke).

**Renders.** All three: resvg, and our renderer (byte-identical to resvg,
diff 0.0), render the **unclipped** shape — full rect, or full
rect-plus-stroke. The suite PNG and Chromium both render an actual circular
(or circle-clipped-rect) clip, and closely agree with each other:
- `circle-shorthand`: suite vs chrome diff 0.7/255 (near-identical circles).
- `circle-shorthand-with-view-box`: suite vs chrome diff 90.7 (chrome's
  clip is visibly rounder/more cut than the suite's, but both clip; only
  resvg/ours are a plain square).
- `circle-shorthand-with-stroke-box`: suite vs chrome diff 150.9 (chrome's
  circle radius reads larger than the suite's, both clearly clip to a
  circle around the stroke box; resvg/ours show the full unclipped
  stroked rect).

**Spec / evidence.** `resvg 0.48.1` source,
`crates/usvg/src/parser/clippath.rs`: the only path into a `ClipPath` is
`node.attribute::<SvgNode>(AId::ClipPath)`, which resolves strictly
`svgtypes`' `FuncIRI` (`url(#id)`) grammar. There is no CSS `<basic-shape>`
parsing anywhere in usvg's clip-path code, confirmed by
`resvg --skip-system-fonts ... circle-shorthand.svg` printing `Warning:
Failed to parse clip-path value: 'circle()'` and falling back to no clip —
exactly usvg's documented behaviour for an unparseable `clip-path`
("logs and treats the attribute as absent", per our own
`LeanSvg/Svg.lean:1882-1886`, which already mirrors this exactly). The
resvg CHANGELOG (`main` branch, fetched 2026-09-23) has no entry adding
`<basic-shape>` clip-path support through 0.48.1. This is a known, general
gap in the resvg/usvg family — see
https://github.com/jwmcglynn/donner/issues/1179 and
https://github.com/jwmcglynn/donner/issues/1249, filed against a different
Rust SVG renderer (`donner`) but describing exactly this missing feature
("clip-path accepts only the SVG 1.1 `url(#target)` reference syntax");
I found no resvg-specific tracking issue.

**Correct reference:** suite PNG and Chromium agree with each other and
with the CSS Shapes spec; both disagree with resvg. Confidence: high on
*whether* to clip; medium on the *exact* geometry for the `view-box` and
`stroke-box` variants, since the suite PNG and Chromium's own circles don't
match each other pixel-for-pixel (default `circle()` closest-side radius
computation against `view-box`/`stroke-box` reference boxes is the likely
source of the small disagreement — worth re-checking against the CSS Shapes
`closest-side` definition when this is implemented).

**Classification: (b)** — needs a feature: CSS `<basic-shape>` clip-path
values (`circle()` at minimum; the suite also has skipped fixtures for
`ellipse()`, `inset()`, `polygon()`, `path()` per the `donner` issues above,
though those aren't in this file set) plus the `<geometry-box>` keyword
(`border-box`/`fill-box`/`stroke-box`/`view-box`/`content-box`/`margin-box`)
that selects the reference box the shape is computed against. Size
estimate: a small CSS-value parser for `circle(<radius>? <at-position>?)` and
the box keywords, a reference-box resolver (bounding box or stroke bounding
box or the SVG viewport, each already computable here — `Box` machinery
exists in `LeanSvg/Svg.lean` §"objectBoundingBox unit square"), and turning
a resolved circle into a `Clip.Mask` the same way a `<clipPath>`'s children
already do. Rasterising a circle is not new work (four Bézier arcs, already
used for `<circle>`). Medium-small: a few hundred lines across parsing and
one new clip-mask constructor, not a new subsystem — but it changes
`parseClipRef`'s contract (currently `Option String`, an id) to also carry
inline shape geometry, which touches every call site.

---

## `masking/mask/color-interpolation=linearRGB.svg`

**What it tests.** `<title>color-interpolation=linearRGB</title>`. A
`<mask>` with `color-interpolation="linearRGB"` containing a rect filled
with a linear gradient from `white stop-opacity=0` to `black
stop-opacity=1`. Per SVG 1.1 §14.4 / the mask luminance formula, when a
mask's `color-interpolation` is `linearRGB` the R/G/B values feeding the
`0.2125·R + 0.7154·G + 0.0721·B` luminance-to-alpha formula must first be
converted from sRGB to linearRGB.

**Renders.** Byte-identical `ours` vs `resvg` (diff 0.0). Sampling the
horizontal gradient's composited alpha at y=100 (this gradient is
horizontal — no `x1/y1/x2/y2`, so it defaults to left-to-right, not
top-to-bottom): `resvg`/`ours` = `[1, 29, 49, 60, 64, 61, 48, 28, 0]`
(peaks at 64/255 around the middle); `suite`/`chrome` = `[1, 24, 34, 33,
27, 18, 9, 3, 0]` (`suite` vs `chrome` diff only 1.9/255 — they closely
agree) — a visibly different, lower-amplitude curve. This is exactly the
signature of an sRGB-vs-linearRGB luminance mismatch (linearRGB luminance
of a light, low-opacity color under-weights it relative to the naive sRGB
formula).

**Spec / evidence.** `resvg 0.48.1` source: `crates/usvg/src/parser/mask.rs`
parses only `MaskType` (`mask-type`: `luminance`/`alpha`) — grepping the
whole `usvg`/`resvg` crates for `ColorInterpolation`/`color-interpolation`
outside of `tests/` finds hits only in `filter.rs` /
`filter/mod.rs` (i.e. `color-interpolation-filters`, a different,
implemented attribute) and never in any mask-related file. resvg simply
never reads `color-interpolation` off a `<mask>` element, so it always
computes luminance in sRGB regardless. This matches this renderer:
`LeanSvg/Mask.lean`'s `lumaF32` (lines 123-146) hardcodes the sRGB luma
weights (`k1=0.2126, k2=0.7152, k3=0.0722`) directly against the canvas's
premultiplied sRGB pixels, with no linear conversion step, and
`LeanSvg/Svg.lean` never parses `color-interpolation` at all (only
`mask-type`, line 1951). We are knowingly mirroring a real usvg gap.

**Correct reference:** suite PNG and Chromium agree closely (diff 1.9/255).
Confidence: high.

**Classification: (b)** — needs a feature, but a small one: an
sRGB→linearRGB 8-bit lookup table already exists in this codebase
(`LeanSvg/FilterApply.lean:43`, `srgbToLin`, built for
`color-interpolation-filters`) and is directly reusable. The work is (1)
parse `color-interpolation` on `<mask>` (and its inheritance — SVG says it's
an inherited property, defaulting to `sRGB` per implementations though the
spec default is `linearRGB`; resvg/browsers commonly implement the sRGB
default, so match that unless testing shows otherwise), (2) thread a bool
into `MaskEntry` next to the existing `maskAlpha`/`mask-type` field, (3) in
`Mask.lumaF32`, unpremultiply, run r/g/b through `srgbToLin` before the
luma weights when the flag is set. `FilterApply.lean` and `Mask.lean` don't
currently share the table — it would need lifting to a common module (or a
small duplicate; the table is short). Small-to-medium: touches 3 files, no
new subsystem, and the hard part (the conversion table) already exists.

---

## `structure/image/embedded-svg-with-text.svg`

**What it tests.** `<title>Embedded SVG with text</title>`. An `<image>`
whose `xlink:href` is a `data:image/svg+xml;base64,...` URI — **not** an
external resource, the SVG bytes are inline in the document. The embedded
document has a `<path>` crosshair and a `<text>Text</text>` in
`font-family="Noto Sans"`.

**Renders.** `resvg` renders the frame + crosshair but not the "Text"
label (font-family mismatch warning: `No match for '"Noto Sans"'
font-family`, even with `--use-fonts-dir` pointed at the suite's bundled
fonts, which apparently doesn't include Noto Sans under that exact name).
The suite's own reference PNG shows the *same* thing — frame + crosshair,
no text — so the reference was almost certainly generated in an
environment with the same font gap, not because dropping unmatched text is
spec-correct. Chromium is the outlier: it renders "Text" in a fallback
serif font, which is correct per CSS font-matching (fall back to a generic
family) but a different-shaped disagreement from the crosshair-vs-no-text
question this file is actually testing. **Our renderer renders nothing
inside the image rectangle at all** — not even the crosshair — only the
outer frame `<rect>` survives (that's a sibling element, not part of the
embedded image). `embedded-svg-with-text.ours.png` is otherwise-blank
except the 1px black frame stroke.

**Spec / evidence.** `resvg 0.48.1` source,
`crates/usvg/src/parser/image.rs:65`: `"image/svg+xml" => load_sub_svg(&data,
opts)`, which calls `Tree::from_data_nested` (line 328) — a full recursive
sub-document render, the same category of machinery as `feImage`.
`LeanSvg/Image.lean` (`loadWith`, lines 252-263) only ever calls `PngDecode`
or `JpegDecode` on the href bytes; any other MIME (including
`image/svg+xml`) returns `none`, so the `<image>` element contributes no
shape at all — confirmed by the all-transparent-except-frame output above.
This is a real, supported resvg feature we don't have, not a resvg bug.

**Correct reference:** resvg's crosshair-without-text render is the closest
available oracle for what we should match (same font limitation, so a fair
comparison), with the caveat that the suite PNG and resvg may both be
suppressing text they shouldn't per strict CSS font-fallback (Chromium's
render suggests so). Confidence: high that we're missing the whole
sub-render; medium on whether font-fallback (rather than drop) is also
worth matching in the same pass.

**Classification: (b)** — needs a feature: recognize
`image/svg+xml`/`image/svg+xml;base64` (and non-base64 percent-encoded SVG
text, which `Image.lean`'s existing `dataUrl`/`percentDecode` machinery
already parses generically — it's only the MIME dispatch that's
PNG/JPEG-only) and render the decoded bytes as a sub-document into the
image's placed rectangle. This renderer already has the two building
blocks resvg's `load_sub_svg`/nested-tree render needs: `Filter/Image.lean`
+ `Filter/ImageRender.lean` already do "parse a second little SVG event
stream and `renderNodes` it into a region-sized canvas" for `feImage`, and
`Use.lean` already does bounded same-document sub-parsing. Wiring
`<image>` to reuse that sub-render path (with its own recursion-depth fuel,
matching `feImage`'s existing budget pattern) is a real but bounded
feature, not a new subsystem. Medium size.

---

## `structure/image/url-to-png.svg`, `structure/image/url-to-svg.svg`

**What they test.** `<title>URL to PNG</title>` / `<title>URL to SVG</title>`.
`<image xlink:href="https://upload.wikimedia.org/...">` — a **remote HTTPS
URL**, not a local path or a data URI.

**Renders.** resvg and ours both render nothing but the frame (both
byte-identical, diff 0.0) — resvg's own CLI prints `'https://...' is not a
path to an image` and drops the `<image>`. The suite PNG shows the actual
fetched content (a photo of dice; the SVG logo). Chromium in this sandbox
shows a broken-image placeholder icon, because outbound network fetches
from the headless browser here don't reach the real internet (not a useful
oracle for this file in this environment) — this is a sandbox artifact, not
evidence about correct behaviour.

**Spec / evidence.** `resvg 0.48.1` source,
`crates/usvg/src/parser/image.rs:26-28`: *"you can forbid access to local
files (which is allowed by default) or add support for resolving actual
URLs (usvg doesn't do any network requests)"* — this is upstream, by
design, not a bug: usvg's default string resolver treats any non-data-URI
`href` as a local file path and tries to open it; a `https://` string is
never a valid local path, so it silently fails to resolve on every
platform, always, independent of network availability. This matches our
own `Prog`/`Effect.lean` model directly (`DESIGN.md` §2: *"SSRF via remote
resources ... our defence: No code path resolves any reference; `Prog`
cannot open a second file"*).

**Correct reference:** not applicable — there is no "correct" render this
renderer could produce without a network fetch, which is out of scope by
construction (both ours and upstream resvg's).

**Classification: (c)** — conflicts with Rowan's safety rules (no external
resources; SSRF defence is one of `DESIGN.md`'s explicit threat-model
rows). Not fixable in resvg either, by design — the `results.csv` "wrong"
verdict here reflects a reference environment with real network access
generating the suite PNG, not a spec our own architecture could satisfy
without adding a network stack.

---

## `structure/style/external-CSS.svg`

**What it tests.** `<title>External CSS</title>`. `<style>@import
"../../../resources/green.css"</style>` overriding a red `<rect>` to
green, where `green.css` is a sibling file on disk (not a URL).

**Renders.** resvg and ours both render red (unaffected `fill="red"`),
byte-identical (diff 0.0) and byte-identical to Chromium's render too (also
red, diff 0.0) — in this sandbox, Chromium's `file://`-opened page also
can't `@import` a second `file://` stylesheet (browsers block
cross-file-URL loads by default without extra flags), so it isn't a useful
independent oracle here either, though it happens to land on the same
answer as resvg for a different reason. Only the suite PNG shows the
correct green result.

**Spec / evidence.** resvg's own CLI output: `Warning (in simplecss:298):
The @import rule is not supported. Skipped.` — `simplecss`, the crate usvg
uses for CSS, does not implement `@import` at all; this is a real usvg/CSS
library limitation, not something a network- or filesystem-capable resvg
build would fix differently. For us, though, this is architecturally closed
regardless of whether `@import` itself gets implemented some day: reading
`green.css` needs a second file read, and `Prog` (`LeanSvg/Effect.lean`)
has exactly three operations — `readInput`, `outputExists`, `writeOutput` —
with no constructor for reading any other path. `DESIGN.md` §1: *"There is
no constructor for any other effect, so the type checker rejects a program
that tries to do anything else."*

**Correct reference:** suite PNG (green) is very likely spec-correct
per CSS's `@import` semantics, but out of reach either way.

**Classification: (c)** — conflicts with Rowan's safety rules / the
`Effect.lean` invariant (this task's own text calls out `LeanSvg/Effect.lean`
as untouchable and "no IO outside `Effect.lean`"); reading a second file
from anywhere in the render pipeline is not a feature gap to close, it's
the thing the architecture is built to prevent.

---

## `structure/style/important.svg`

**What it tests.** `<title>\`!important\`</title>`. Two CSS rules for the
same `#rect1` selector, the first `fill: green !important`, the second
(later, lower in the cascade) `fill: red` without `!important`. Per CSS
cascade rules, `!important` wins regardless of declaration order, so the
correct result is green.

**Renders.** All four — resvg, suite PNG, Chromium, ours — render solid
green. `ours` is byte-identical to both `resvg` and `chrome` (diff 0.0
each); `resvg`/`ours`/`chrome` differ from the suite PNG by only 1.9/255
(the suite PNG is 500×500 downsampled to 200×200, so that's antialiasing
noise from the resize, not a real disagreement).

**Spec / evidence.** `LeanSvg/Svg.lean` already implements a four-layer
cascade with `!important` CSS as the highest-precedence layer
(`Css.matchingDeclsSplit` splitting `normalCss`/`importantCss`, `winning`
at lines 3368-3390) — this is exactly right per spec, and resvg 0.48.1
gets it right too.

**Correct reference:** all four agree; there is nothing to fix.

**Classification: not applicable — this file is not currently wrong.**
`results.csv`'s `resvg=2` (and `svgnet=0`, `qtsvg=2`) verdict does not
reproduce against resvg **0.48.1** specifically, the version this task and
the corpus gate are pinned to. Likely explanation: `results.csv` was
generated against a different (probably older) resvg version than 0.48.1,
where this `!important`-vs-declaration-order bug existed and was since
fixed upstream, or the reference commit predates a `simplecss` upgrade.
Flagged under "Questions for Rowan" below, since it means `results.csv`
can't be taken as automatically current for 0.48.1 without spot-checking.

---

## `structure/svg/not-UTF-8-encoding.svg`

**What it tests.** `<title>Not UTF-8 encoding</title>`. `<?xml
version="1.0" encoding="Windows-1251"?>` with the document body's `<text>`
content actually encoded in Windows-1251 (a single-byte Cyrillic codepage),
which is not valid UTF-8. Per the XML 1.0 spec (§4.3.3, "Character
Encoding in Entities"), a conforming XML processor must honour the
`encoding` pseudo-attribute and transcode accordingly before parsing.

**Renders.** Our local `resvg 0.48.1` **refuses to render at all**: `Error:
provided data has not an UTF-8 encoding.` (exit 1, no PNG produced) — this
is why the task table lists this file as `ref_failed` rather than a
pass/fail score: there is no resvg reference image to score against.
The suite PNG shows the correctly transcoded text, "Привет мир" ("hello
world" in Russian). Our headless Chromium render in this sandbox came out
as a degenerate 200×16 px strip (`img{height:auto}` computed against a
collapsed intrinsic size) — Chromium also appears to choke on this file
inside a plain `<img>` tag in this environment, so it isn't a usable
oracle here either, despite `results.csv` claiming `chrome=1` (a real
browser navigating directly to the SVG, rather than embedding it as an
`<img>`, likely behaves differently; not re-verified). **Our renderer**
does not error, but does not transcode either: it renders literal
tofu/replacement-box glyphs for the raw Windows-1251 bytes reinterpreted as
if they were UTF-8/Unicode code points — visibly wrong text, not a crash
(consistent with the "no panics, bounded, fails loudly only where
required" invariant: invalid UTF-8 doesn't panic here, it just produces
garbage glyphs where a real transcode step is missing).

**Spec / evidence.** `LeanSvg/Xml.lean` has no handling of the `encoding`
pseudo-attribute at all (grepped for `encoding`/`UTF`/`BOM`; the only hits
are the parser's own UTF-8 *output* encoding of numeric character
references, `Bytes.lean`/`Xml.lean` lines 85, 125 — there is no code path
that reads the prolog's declared `encoding` value or transcodes anything).
The suite's reference PNG and the `results.csv` majority (`chrome=1
firefox=1 safari=1 batik=1 inkscape=1 librsvg=1`, i.e. every renderer
except resvg, svgnet and qtsvg) agree that the correct behaviour is: parse
the `encoding` declaration, transcode Windows-1251 → UTF-8, then continue
parsing normally.

**Correct reference:** suite PNG, corroborated by the `results.csv`
majority across independent renderers. Confidence: high on *what* correct
looks like; the local Chromium render couldn't independently confirm it in
this sandbox, but the convergence of 6 other renderers plus the readable
suite PNG is strong enough on its own.

**Classification: (b)** — needs a feature: parse the `encoding="..."`
pseudo-attribute out of the XML prolog before the main scan (bounded,
already-parsed-adjacent text), match it case-insensitively against a short
alias list, and add at least a Windows-1251 (and plausibly ISO-8859-1/
KOI8-R, if Rowan wants broader legacy-encoding coverage rather than just
this one file) byte→Unicode table — 128 entries for the codepage's high
half (0x00-0x7F is already ASCII-identical to UTF-8), each byte producing a
fixed 1-3-byte UTF-8 sequence. This is a small, static, pure lookup —
easily bounded and total, fitting the "no unsafe indexing, no partial
functions" invariants — but it's a new parsing feature (prolog
`encoding=` support) plus at least one codepage table, not a one-line fix,
so (b) rather than (a). If Rowan only wants this exact test to stop
regressing (rather than general legacy-encoding support), the Windows-1251
table alone is the minimum scope.

---

## `structure/use/xlink-to-an-external-file.svg`

**What it tests.** `<title>xlink to an external file</title>`. `<use
xlink:href="../../../resources/simple-text.svg#text1" .../>` — a `<use>`
referencing a fragment (`#text1`) inside a **different, external SVG
document** on disk.

**Renders.** resvg and ours both render only the frame (`use` resolves to
nothing), byte-identical to each other and to Chromium (diff 0.0 across all
three) — Chromium also renders nothing for the external `<use>`, matching
the task's own reference table (`chrome=2 firefox=2 safari=2`: **every**
current browser engine already refuses this). Only the suite PNG shows the
expected green "Text" glyph pulled from the external document.

**Spec / evidence.** `LeanSvg/Use.lean` (lines 21, 59): *"Only `#id`
references are followed, and only into the same event array"* / *"Only a
same-document `#id` is a link."* SVG 2 itself deprecated external `<use>`
references for the same reason every browser engine has dropped them:
cross-document `use` was a security liability (leaking content across
origins) and was removed from the spec's normative behaviour — this is the
same category as `masking/clip/simple-case.svg` above (a legacy behaviour
no current UA implements), compounded by the fact that, architecturally,
resolving it here would need a second file read, same as
`external-CSS.svg`.

**Correct reference:** none of the four available oracles that matter
(resvg, all three real browsers per `results.csv`) implement this; the
suite PNG is the outlier, testing pre-SVG2 behaviour.

**Classification: (c)** — deliberately not supported, doubly so: it's both
a legacy/removed SVG behaviour (matching every current browser, like the
`clip` property) *and* would require a second file read, forbidden by
`Effect.lean`'s `Prog`. Strongest class-(c) case of the twelve — even resvg
and browsers converge with us here, only the suite's own reference
disagrees.

---

## Summary table

| file | class | correct reference | one-line cause |
|---|---|---|---|
| `masking/clip/simple-case.svg` | (c) | resvg / current Chromium (suite PNG is stale) | legacy CSS2 `clip` property, dropped by every current UA incl. resvg |
| `masking/clipPath/circle-shorthand.svg` | (b) | suite PNG + Chromium (agree) | usvg's `clip-path` parser only accepts `url(#id)`, no CSS `<basic-shape>` grammar |
| `masking/clipPath/circle-shorthand-with-view-box.svg` | (b) | suite PNG + Chromium (agree, minor geometry difference between them) | same as above, plus `view-box` reference-box keyword |
| `masking/clipPath/circle-shorthand-with-stroke-box.svg` | (b) | suite PNG + Chromium (agree, minor geometry difference between them) | same as above, plus `stroke-box` reference-box keyword |
| `masking/mask/color-interpolation=linearRGB.svg` | (b) | suite PNG + Chromium (agree) | usvg's `<mask>` never reads `color-interpolation`, always computes luminance in sRGB |
| `structure/image/embedded-svg-with-text.svg` | (b) | resvg's crosshair-without-text render (font gap shared with suite PNG) | we don't decode `image/svg+xml` at all in `<image>`; resvg recursively sub-renders it |
| `structure/image/url-to-png.svg` | (c) | none reachable (network fetch out of scope) | remote `https://` URL; no code path resolves any reference, in resvg or in us |
| `structure/image/url-to-svg.svg` | (c) | none reachable (network fetch out of scope) | remote `https://` URL; same as above |
| `structure/style/external-CSS.svg` | (c) | suite PNG (likely correct, unreachable) | `@import` of a second local file; blocked both by usvg's CSS engine and by `Prog`'s no-second-file-read invariant |
| `structure/style/important.svg` | **n/a — already correct** | resvg 0.48.1 / suite PNG / Chromium / ours (all agree, green) | `results.csv` doesn't reproduce against resvg 0.48.1; likely stale/older-version data |
| `structure/svg/not-UTF-8-encoding.svg` | (b) | suite PNG, corroborated by 6/9 `results.csv` renderers | no `encoding=` pseudo-attribute handling; Windows-1251 bytes rendered as raw (mis-)Unicode instead of transcoded |
| `structure/use/xlink-to-an-external-file.svg` | (c) | none reachable; also unsupported by every current browser | external-document `<use>`, removed from SVG2/browsers for the same reason as CORS; also a second-file-read |

**Files fixed this task: zero.** No file met the bar for a class-(a) shallow
fix ("a few lines, clear evidence, suite PNG and Chromium agree with each
other and with the spec") — the masking/clip-path items are real features
(b), the URL/file-reference items are architecturally out of scope (c), and
`important.svg` turned out not to be broken at all. The corpus gate
(`run_corpora.py` + `score_known.py`, `lake build`, `check-theorems.sh`,
`run_tests.py`, `run_adversarial.py`, `run_tiles.py`) was therefore not run
against a code change — there is no code change in this task.

## Questions for Rowan

1. **`structure/style/important.svg` doesn't reproduce against resvg
   0.48.1.** All four renders (resvg 0.48.1, suite PNG, Chromium, ours) agree
   on green — the `!important`-losing-to-declaration-order bug `results.csv`
   describes isn't present in the exact resvg version this project is pinned
   to. Should `results.csv` be treated as ground truth only after a
   per-file spot-check like this one, or is there a newer/matching
   `results.csv` cut against 0.48.1 specifically that I should have used
   instead?

2. **`masking/clipPath/circle-shorthand-with-view-box.svg` and
   `-with-stroke-box.svg`: suite PNG and Chromium clip to visibly different
   circle sizes** (diff 90.7/255 and 150.9/255 between them respectively,
   vs. near-identical on the plain `circle-shorthand.svg`, diff 0.7/255).
   Both clearly apply *some* circular clip, so the qualitative fix (b) is
   unambiguous, but which reference box computation (CSS Shapes'
   `closest-side` against exactly which box — the SVG viewport vs. the
   stroke bounding box vs. something else) should be the pixel-exact target
   if/when this gets built? I'd lean toward following the CSS Shapes /
   Masking spec text directly over either renderer, but flagging since the
   two "good" oracles disagree with each other here.

3. **`structure/image/embedded-svg-with-text.svg`: is font-fallback worth
   doing in the same pass as SVG-in-`<image>` support?** resvg (and the
   suite's own PNG) drop unmatched text entirely rather than falling back
   to a generic font family; Chromium falls back and renders "Text". Our
   `reference behaviour: match resvg/usvg 0.48.1` policy says match resvg's
   drop-on-no-match behaviour, which is also the simpler, narrower feature
   (just wire `<image>` to the existing sub-document render path used by
   `feImage`). Confirming that's the right scope before anyone picks this
   up, since "correct per CSS" and "correct per our resvg-matching policy"
   diverge here.

4. **Scope of the Windows-1251 fix, if picked up**: just enough to stop
   `not-UTF-8-encoding.svg` regressing (one codepage table), or should
   `encoding=` support be built more generally (e.g. also covering
   ISO-8859-1/Latin-1 and KOI8-R, the other common legacy SVG encodings)?
   The prolog-parsing part is the same either way; only the number of
   codepage tables changes.
