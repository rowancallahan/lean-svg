# D-text — near-miss diagnosis

18 resvg-correct `text/*` files that render close to resvg (within-8 at
200 px between 0.912 and 0.970) but miss the ≥0.99 pass bar. Renders and
side-by-side diffs: `docs/near-miss/D-text.png` (resvg | ours | diff, ×4
gain, one row per file). No renderer code changed.

Reference: resvg/usvg 0.48.1 source, from the vendored crate sources at
`~/.cargo/registry/src/index.crates.io-*/{usvg,resvg,svgtypes}-0.48.1`
(installed by `scripts/cloud-setup.sh`) — `usvg-0.48.1/src/parser/text.rs`,
`usvg-0.48.1/src/text/layout.rs`, `svgtypes-0.16.1/src/font.rs`.

## Per-file diagnosis

### `text/text/zalgo.svg` (0.937), `text/text/rotate-with-multiple-values-and-complex-text.svg` (0.927)

**Cause.** Both strings use Unicode combining diacritical marks in NFD
form (`U+0300–036F`, e.g. `e` + `U+0301` for `é`). The embedded font
subset's Unicode ranges (`tests/gen_font_module.py:34`,
`DEFAULT_UNICODES = "U+0020-007F,U+00A0-00FF,U+0100-017F,U+2000-206F,U+20AC"`)
never include that block, so `pyftsubset` drops every combining-mark glyph
from `LeanSvg/Fonts/NotoSans.lean`. `Font.glyphId`'s cmap lookup
(`LeanSvg/Font.lean:275-279`) then returns `0` (`.notdef`) for each mark,
and `--notdef-outline` (already passed to `pyftsubset`,
`tests/gen_font_module.py:60-66`) draws that as a visible box — the tofu
squares in the gallery's "ours" column. usvg/rustybuzz, shaping against the
system-independent full font, finds real mark glyphs and positions them
over the base letter via the font's own zero/negative-advance design.

**Code.** `tests/gen_font_module.py:34` (`DEFAULT_UNICODES`); the generated
`LeanSvg/Fonts/NotoSans.lean` (and `NotoSansBold.lean`/`NotoSansItalic.lean`
if bold/italic combining marks are ever exercised).

**Fix.** Add `U+0300-036F` to `DEFAULT_UNICODES` and regenerate the three
font modules with the existing `tests/gen_font_module.py` command (see its
own docstring). No logic changes. Residual risk: this renderer has no
GPOS mark-to-base positioning (only `cmap` + `hmtx`, per `LeanSvg/Font.lean`'s
own header), so a mark still lands wherever the *font's own advance width*
puts it rather than at a HarfBuzz-computed anchor point — for Noto Sans
(advance 0 on combining marks, glyph outline pre-shifted left in the
design) this is usually close enough, but won't be pixel-identical to
resvg's rustybuzz output. **Size: trivial** (one line + regenerate;
mechanical, data-only, no `LeanSvg/*.lean` logic touched).

### `text/text-anchor/on-tspan-with-arabic.svg` (0.969), `text/text/x-and-y-with-multiple-values-and-arabic-text.svg` (0.959)

**Cause.** Both set `font-family="Amiri"` and Arabic text. This renderer
embeds exactly one family, "Noto Sans" (`LeanSvg/Text.lean:50-53`);
`resolveFontFamily` (`LeanSvg/Svg.lean:1701-1721`) treats any other name,
"Amiri" included, as a non-match and falls back to the same never-installed
default — which still resolves to `false` (`Svg.lean:1719-1721`), so
`Style.fontAvailable` is `false` for these spans. Whatever code gates glyph
emission on `fontAvailable` skips the run entirely rather than substituting
a fallback face, so the text renders as nothing (confirmed in the gallery:
the "ours" column is blank except for the crosshair). Separately, even with
a font that *had* Arabic glyphs, this renderer's layout is a plain
per-codepoint `cmap` walk (`LeanSvg/Text.lean`'s `Cluster`, one entry per
Unicode codepoint, `LeanSvg/Text.lean:463-482`) with no bidi reordering and
no Arabic contextual joining (init/medial/final letter forms), both of
which usvg gets from `unicode-bidi` + rustybuzz shaping
(`usvg-0.48.1/src/text/layout.rs:1466-1481`, `bidi_info.visual_runs`).

**Code.** `LeanSvg/Svg.lean:1701-1721` (`resolveFontFamily`); whatever
consumes `Style.fontAvailable` to decide skip-vs-draw (not modified here,
diagnosis only); `LeanSvg/Text.lean`'s `Cluster`/layout loop (no shaping
stage at all).

**Fix.** Not small. Needs (a) an embedded Arabic-capable font (e.g. a
subsetted Amiri or Noto Sans Arabic), (b) a bidi pass (at minimum: detect
RTL runs and reverse logical→visual order — `unicode-bidi`'s algorithm,
not just "reverse the string"), and (c) Arabic contextual shaping (choosing
init/medial/final/isolated glyph forms, ideally via the font's own GSUB
`init`/`medi`/`fina`/`liga` features, which this renderer has no table
parser for at all). This is a new major feature, not a bug fix — closer in
scope to T25 (font parser) than to a one-file patch. **Size: large.**

### `text/font-weight/bolder-with-clamping.svg` (0.962), `text/font-weight/lighter-with-clamping.svg` (0.959), `text/font-weight/lighter-without-parent.svg` (0.959)

**Cause.** Confirmed by isolation: every *other* file in
`text/font-weight/` (`bold.svg`, `700.svg`, `650.svg`, `bolder.svg`,
`bolder-without-parent.svg`, `lighter.svg`, `normal.svg`, `inherit.svg`,
`invalid-number-1.svg`) scores ≥0.9994 at 200 px (measured directly, not
in the task's list), and `parseFontWeight` (`LeanSvg/Svg.lean:1675-1690`)
matches usvg's `resolve_font_weight`
(`usvg-0.48.1/src/parser/text.rs:585-627`) formula exactly (`bolder`:
+300 from 400, else +100, clamped 900; `lighter`: −200 from 400, else
−100, clamped 100) — a minimal repro of literal `font-weight="900"` vs.
`font-weight="bolder"` computed to 900 renders byte-identical
(`/tmp/w1.svg` vs `/tmp/w2.svg` in this session). So the *numeric*
resolution is right. The three near-miss files are exactly the ones whose
resolved weight is 900, 100 or 200 — the corpus's pinned font directory
(`tests/corpora/resvg-test-suite/fonts/`) actually ships five static Noto
Sans weights (`NotoSans-Thin.ttf` 100, `-Light.ttf` 300, `-Regular.ttf`
400, `-Bold.ttf` 700, `-Black.ttf` 900), and resvg's `fontdb` picks the
nearest-weight file per element. This renderer embeds only two non-italic
weights (`LeanSvg/Text.lean:50-53`, "Only the three embedded Noto Sans
subsets exist"), and `pickFace` (`LeanSvg/Text.lean:61-65`) is a single
600 threshold: 700 and 900 both draw with the same Bold outline, and
100/200/300 all draw with the same Regular outline. For weight 700 (or
anything that rounds to "closer to 700 than 400" in fontdb's own metric)
this coincides with resvg's Bold pick, which is why `bolder.svg` (600 vs.
700 — fontdb's nearest for 600 is still Bold, distance 100 vs. 200) and
`bolder-without-parent.svg` (700 vs. 700) both pass. For 900 vs. Black, and
100/200 vs. Thin, it does not: the gallery shows this plainly — in
`lighter-with-clamping`/`lighter-without-parent` resvg's reference is
visibly thin/gray-looking (Thin weight) while ours is full Regular-weight
black; `bolder-with-clamping`'s Black-vs-Bold gap is subtler (both dark)
but still enough stroke-width difference to miss the 8-tolerance band
around every glyph edge.

**Code.** `LeanSvg/Text.lean:44-53` (`Face`/embedded-subsets doc),
`LeanSvg/Text.lean:61-65` (`pickFace`), `LeanSvg/Text.lean:68-87`
(`Faces`/`loadFaces`).

**Fix.** Embed 2–3 more static weight subsets (Thin/Light and/or Black —
`tests/gen_font_module.py` already does the hex-encoding, just point it at
the corpus's own `NotoSans-Thin.ttf`/`-Light.ttf`/`-Black.ttf` or upstream
equivalents), widen `Face` from 3 cases to N non-italic weights × italic,
and change `pickFace` from a single 600 cutoff to "nearest of the embedded
weights" (mirroring fontdb's own nearest-match rule) instead of a binary
bold/regular split. Contained to `Text.lean`'s face-selection layer plus
new font assets; does not touch layout/geometry. **Size: medium**
(~40-60 lines in `Text.lean` + 2-3 new generated font modules + a
`loadFaces` arity change propagated to its one call site).

### `text/lengthAdjust/spacingAndGlyphs.svg` (0.957), `text/lengthAdjust/text-on-path.svg` (0.964), `text/lengthAdjust/vertical.svg` (0.957), `text/lengthAdjust/with-underline.svg` (0.955)

**Cause.** Already documented as a known approximation in the code itself.
`lengthAdjust="spacingAndGlyphs"` should rescale each glyph *outline*
horizontally (about a correspondingly-scaled pen position) so a run of
natural width `W` fits exactly in `textLength`, matching usvg's
`apply_length_adjust` (`usvg-0.48.1/src/text/layout.rs`, referenced from
`LeanSvg/Text.lean:734-745`'s own comment). This renderer instead always
takes the `"spacing"`-only path — redistributing the `textLength − W` slack
as extra advance between clusters (`LeanSvg/Text.lean:745-760`) — for
*both* `lengthAdjust` values, per the comment: "approximated here by the
same 'spacing' redistribution rather than left undone, since it reproduces
the dominant visual effect... even though the individual glyphs are not
rescaled." The run ends at the right total width, but every individual
glyph keeps its natural (unscaled) shape and inter-glyph gaps are uniformly
widened/narrowed instead — visible in the gallery as "T e x t" (wide gaps,
natural glyph width) in "ours" vs. resvg's "Text" (compressed/expanded
glyphs, natural gaps). `vertical.svg` and `with-underline.svg` inherit the
same gap through `writing-mode: tb` and the underline-rectangle path
respectively (the underline still spans the (correct) run width, but the
glyphs it underlines are shaped wrong the same way); `text-on-path.svg`
additionally runs this through `TextPath.normals`, which has no separate
bug — the same spacing-only gap is the entire discrepancy there too, per
the identical scores/diff pattern.

**Code.** `LeanSvg/Text.lean:719-761` (the whole `letter-spacing`/
`word-spacing`/`textLength` block; the `spacingAndGlyphs` branch is folded
into the same code as `"spacing"`, at `Text.lean:745-761`, rather than
being its own case).

**Fix.** As the existing comment already scopes: thread a per-run scale
factor (`target / natSum`, fixed-point) into (a) the pen-position
accumulation for the run (currently `c.adv` in the `x`/`nrm` accumulation,
`Text.lean:775-790` and `830-861`) and (b) `glyphCmds`/`glyphCmdsLin`'s own
outline transform, so the glyph's `x` scale is multiplied by that factor
about the run-start-relative pen position, not just about each glyph's own
origin. Needs care for the two callers (flat text and on-path) and for
`writing-mode: tb` (which swaps the scaled axis). **Size: medium** — the
comment already identifies exactly what is missing; call it ~80-120 lines
across the two `glyphCmds` call sites plus the accumulation change, plus
re-verification against the wider `lengthAdjust`/`textPath` suites since
both call sites are shared with plain (non-`spacingAndGlyphs`) runs.

### `text/alignment-baseline/middle-on-textPath.svg` (0.955), `text/alignment-baseline/two-textPath-with-middle-on-first.svg` (0.952), `text/textPath/m-L-Z-path.svg` (0.945)

**Cause.** `dominant-baseline`/`alignment-baseline`/`baseline-shift` are
resolved into `SpanProps` normally (`LeanSvg/Baseline.lean`,
`LeanSvg/Svg.lean:169-173`), but the per-glyph placement code only ever
calls `resolveBaseline16` in the *non-path* branch:
`LeanSvg/Text.lean:876-884` (`let bshift := resolveBaseline16 …`, inside
`else` at `Text.lean:857`). The `flow.isSome` branch just above it
(`Text.lean:834-853`, glyphs on a `textPath`) computes the glyph's rotation
and position purely from the arc-length normal (`n.x`/`n.y`), the tangent
(`n.cos`/`n.sin`), `dy` (accumulated into `y`, `Text.lean:840`) and
`rotate` — `bshift`/`resolveBaseline16` never appears in that branch at
all. So `alignment-baseline="middle"` and `baseline-shift="5"` are silent
no-ops for path text: measuring ink centroids at 400 px confirms it —
`middle-on-textPath.svg`'s text sits ~10.5 px higher (device px, i.e.
~5.2 px at 200 px) than resvg's, consistent with a missing `+xHeight/2`
downward shift (`AlignmentBaseline.shift16`'s `.middle` case,
`LeanSvg/Baseline.lean:82`) at font-size 24. usvg *does* apply this for
path text: `resolve_clusters_positions_path`
(`usvg-0.48.1/src/text/layout.rs:629-691`) reads each cluster's
`baseline_shift` (line 678) and folds `dy − baseline_shift` into the same
shift vector as `dy` (line 690-691). `m-L-Z-path.svg` sets
`baseline-shift="5"` directly on its one `<textPath>` and shows the same
signature (thin position-shifted outline in the diff, not a shape or
orientation error — the M-L-Z path's own direction-reversal on `Z` renders
correctly and identically in both, confirmed by inspecting the upside-down
second half of the alphabet at 600 px in both images).

**Code.** `LeanSvg/Text.lean:834-853` (the `flow.isSome` glyph-placement
branch that needs the same `resolveBaseline16` call the `else` branch
already has at `Text.lean:882`).

**Fix.** Compute `bshift` the same way as the non-path branch and fold it
into the perpendicular offset already being built from `n.cos`/`n.sin` and
`y` (the existing `dy` accumulator) — i.e. add it to `y` before the
`hw`/`y`-based position formula at `Text.lean:851-853`, the same place
`dy` already lands, since both are perpendicular-to-tangent shifts. Fully
localized to this one branch; `resolveBaseline16` and its inputs
(`pr.dominantBaseline`, `pr.alignmentBaseline`, `pr.baselineShiftPx`, etc.)
already exist and are already carried on `c.props` in this branch. **Size:
small** (~10-15 lines, one function call plus wiring its result into an
existing accumulator; no new state).

### `text/font-variant/inherit.svg` (0.961), `text/font-variant/small-caps.svg` (0.961)

**Cause.** `font-variant` does not exist anywhere in this codebase (no
`Style` field, no `applyProp` case, no mention in `LeanSvg/Text.lean`) —
confirmed by an exhaustive grep across `LeanSvg/*.lean`. `small-caps.svg`'s
diff shows exactly the expected shape: resvg's "TEXT" (small-caps: the
already-uppercase `T` unchanged, `ext` rendered as smaller capitals) vs.
this renderer's untouched "Text". `inherit.svg` behaves identically to
`small-caps.svg` for the same reason: nothing reads `font-variant` at all,
so `font-variant="inherit"` and `font-variant="small-caps"` are equally
inert. Note for whoever implements this: usvg's own inheritance for this
property is *not* the ordinary CSS walk — `resvg-0.48.1`'s
`small_caps: parent.find_attribute::<&str>(AId::FontVariant) ==
Some("small-caps")` (`usvg-0.48.1/src/parser/text.rs:290`) uses
`find_attribute`, which walks ancestors for the *nearest one that has the
attribute at all*; getting `inherit.svg` right needs that same walk (or an
equivalent ordinary-inherited `Style` field, which would get `inherit.svg`
right "for free" the way `dominant-baseline`/`alignment-baseline` already
do per `LeanSvg/Baseline.lean`'s header — simplest path: treat
`font-variant` as one more ordinary CSS-inherited field like those two).
usvg's rendering itself is real OpenType `smcp` glyph substitution via its
shaper (`usvg-0.48.1/src/text/layout.rs:1480-1484`,
`features.push(Feature::new(Tag::new(b"smcp"), 1, ..))`), not a synthetic
uppercase-and-shrink — this renderer has no GSUB table support at all
(confirmed under the zalgo/combining-marks finding above: `cmap`+`hmtx`
only), so an exact match isn't reachable without adding GSUB single-
substitution parsing.

**Code.** `LeanSvg/Svg.lean:1946+` (`applyProp`, needs a `"font-variant"`
case); `LeanSvg/Svg.lean:149-173`-style `Style` field; `LeanSvg/Text.lean`'s
`SpanProps` and the per-codepoint layout loop (for whichever synthesis
strategy is chosen).

**Fix.** Two parts, independently sizeable. (1) Plumbing: ordinary
inherited `Style` field + `applyProp` case + `SpanProps` field — small,
same shape as `alignmentBaseline` (`Svg.lean:169-173`, `2119-2132`). (2)
Rendering: without GSUB, the only approximation available is synthetic
small caps — for each lowercase ASCII/Latin-1 letter, substitute the
uppercase codepoint's glyph id and scale the resulting outline (commonly
~72-80% in browsers that lack real small-cap glyphs) about its own
baseline origin. That touches the per-codepoint glyph-emission step in
`LeanSvg/Text.lean` (`glyphCmds`/`glyphCmdsLin` call sites,
`Text.lean:851-853` and `882-884`) to conditionally remap the codepoint and
apply an extra uniform scale. **Size: medium** (~60-100 lines: field +
prop parsing + codepoint remap + scale plumbing); accuracy ceiling is
capped by not matching Noto Sans's real `smcp` glyph proportions, but
should land well inside the 8-tolerance band given the current gap is
100% (no shrinking at all).

### `text/font/font-shorthand.svg` (0.970)

**Cause.** The CSS `font` shorthand (`style="font: 50px 'Noto Sans'"`) is
not implemented: `applyProp` (`LeanSvg/Svg.lean:1946+`) has no `"font"`
case (confirmed by grep — no `"font"` literal anywhere in `Svg.lean`), so
it falls through to the default no-op arm. The parent `<g>`'s own longhand
declarations (`font-weight: bold`, `font-size: 200px`,
`font-family: 'Times New Roman'`, `font-kerning: none`) are therefore never
overridden on `text1`, which per ordinary CSS inheritance keeps them all.
`resolveFontFamily` (`Svg.lean:1701-1721`) doesn't match "Times New Roman"
(the corpus's only other name it special-cases is "Source Sans Pro"), so
`fontAvailable` is `false` and — same mechanism as the Arabic files above —
the whole `<text>` renders nothing. The gallery confirms this exactly:
"ours" is blank; resvg's reference shows small black "AVA" (50px, Noto
Sans, normal weight — the shorthand's own values, with weight/variant/style
correctly *reset* to initial rather than inherited, per CSS shorthand
semantics).

**Code.** `LeanSvg/Svg.lean:1946+` (`applyProp`, missing `"font"` case);
`svgtypes-0.16.1/src/font.rs:119-` (`FontShorthand`, the grammar to match:
optional `style variant weight stretch`, mandatory `size[/line-height]`,
mandatory `family` list, in that order, first token containing a digit or
matching a CSS `<absolute-size>`/`<length>` keyword ends the leading
keyword run).

**Fix.** Add a `"font"` case to `applyProp` that parses the shorthand
grammar above and, on success, applies `font-style`/`font-variant`/
`font-weight`/`font-stretch` (defaulting each to its initial value when
absent from the shorthand — the part that makes this different from an
ordinary longhand set) plus `font-size` and `font-family` exactly as their
own longhand cases already do (reuse `parseFontSize`/`parseFontWeight`/
`resolveFontFamily`, `Svg.lean:2058-2060`). Depends on `font-style` already
existing (`Svg.lean:2071`) and, once implemented, on `font-variant`
(previous finding) for full correctness — this specific file only
exercises size/family/weight-reset, so it's fixable independently of
`font-variant` support. **Size: small-medium** (~40-60 lines: a shorthand
tokenizer plus wiring into 4-5 existing longhand setters).

### `text/textPath/dy-with-tiny-coordinates.svg` (0.939)

**Cause.** Not the same class of bug as the others — this is a
fixed-point precision limit, and the file's own `<desc>` names the
upstream resvg issue this shape once triggered
(`github.com/RazrFalcon/resvg/pull/291`). The path lives inside
`<g transform="scale(100)">` with sub-unit coordinates (`0.20`, `0.73`,
`1.08`, stroke-width `0.01`, …). `parseNumber` (`LeanSvg/Fixed.lean:142-148`)
parses every plain coordinate — including path `d` data — onto the `Fx`
grid of 1/256 px *before* any transform is applied, so `0.20` already loses
~0.002 px of precision at parse time; after the ancestor `scale(100)` CTM,
that becomes ~0.2 px per coordinate, and `TextPath.Seg.mk'`
(`LeanSvg/TextPath.lean`) builds its arc-length table directly from these
already-quantized control points. `LeanSvg/Fixed.lean:151-165` documents
this *exact* failure mode already, for a different case: `parseNumber16`
exists specifically because "for the linear part of a transform matrix...
quantizing to 1/256 amplifies that quantization by whatever the
coefficient multiplies" (citing `T31`'s `scale(0.072...)` finding, a 2.3%
error). Plain shape/path coordinates still go through the coarser
`parseNumber`, so the identical amplification hits a path sitting under a
large ancestor scale instead of a small `scale()` coefficient. The visual
effect is subtle — both renders are close (both textPaths, both `dy`
shifts, matching layout) — consistent with a compounding sub-pixel arc-
length error across "Some long text" rather than a gross placement bug.

**Code.** `LeanSvg/Fixed.lean:142-148` (`parseNumber`, the 1/256 grid used
for path/shape coordinates) vs. `Fixed.lean:151-165` (`parseNumber16`, the
finer grid already used only for transform linear coefficients);
`LeanSvg/TextPath.lean`'s `Seg.mk'` (arc-length table built from the
already-quantized points).

**Fix.** Not small, and not local. The narrow read (give path-command
coordinates the finer 16.16 grid the way transform coefficients already
have) means widening `PathCmd`'s own coordinate type, which is the shared
representation for fill, stroke, clipping, markers and this arc-length
table alike — every consumer of `PathCmd` would need auditing for the
wider range/rounding behavior, well beyond this one feature area. A
narrower-scoped alternative (build `TextPath.Table` from higher-precision
coordinates resolved specifically for that one path, independent of the
shared `PathCmd` type) avoids the blast radius but still means carrying a
second, higher-precision path representation from `Svg.lean`'s node walk
through to `TextPath.build`. Either way this is an architectural
precision decision, not a contained patch. **Size: large.**

## Files grouped by shared cause (largest first)

| Cause | Files | Size |
|---|---|---|
| `lengthAdjust="spacingAndGlyphs"` approximated as spacing-only, glyphs never rescaled (`Text.lean:719-761`) | `lengthAdjust/spacingAndGlyphs.svg`, `lengthAdjust/text-on-path.svg`, `lengthAdjust/vertical.svg`, `lengthAdjust/with-underline.svg` | medium |
| `alignment-baseline`/`dominant-baseline`/`baseline-shift` never applied to text on a `textPath` (`Text.lean:834-853` missing the `resolveBaseline16` call `Text.lean:882` already has) | `alignment-baseline/middle-on-textPath.svg`, `alignment-baseline/two-textPath-with-middle-on-first.svg`, `textPath/m-L-Z-path.svg` | small |
| Only 2 static font weights embedded (Regular/Bold); resvg's pinned corpus fonts have 5 (Thin/Light/Regular/Bold/Black) and `fontdb` nearest-matches per element (`Text.lean:61-87`) | `font-weight/bolder-with-clamping.svg`, `font-weight/lighter-with-clamping.svg`, `font-weight/lighter-without-parent.svg` | medium |
| Combining diacritical marks (`U+0300–036F`) excluded from the embedded font subset's Unicode ranges (`tests/gen_font_module.py:34`) | `text/zalgo.svg`, `text/rotate-with-multiple-values-and-complex-text.svg` | trivial |
| No Arabic-capable font embedded and no bidi/contextual-shaping support at all (`Svg.lean:1701-1721`, `Text.lean`'s per-codepoint `Cluster` layout) | `text-anchor/on-tspan-with-arabic.svg`, `text/x-and-y-with-multiple-values-and-arabic-text.svg` | large |
| `font-variant` unimplemented (no field, no `applyProp` case, no small-caps synthesis) | `font-variant/inherit.svg`, `font-variant/small-caps.svg` | medium |
| CSS `font` shorthand unimplemented in `applyProp` (`Svg.lean:1946+`) | `font/font-shorthand.svg` | small-medium |
| Path coordinates quantized to 1/256 px before a large ancestor scale is applied, unlike transform coefficients which already use a finer grid (`Fixed.lean:142-165`) | `textPath/dy-with-tiny-coordinates.svg` | large |

Total: 4+3+3+2+2+2+1+1 = 18.

No file in this list overlaps with concurrent work known at diagnosis time
(`tasks/D-paint.md`, `D-structure.md`, `D-filters-images.md` target
different corpus directories entirely); another agent may independently be
fixing some of these `text/*` files, but every file above was diagnosed
against the current `main`-equivalent state of this branch regardless.
