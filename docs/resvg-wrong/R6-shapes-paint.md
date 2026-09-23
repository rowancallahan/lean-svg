# R6 — resvg-wrong research: shapes and paint

Per-file investigation of the 11 files resvg-test-suite's own `results.csv`
marks resvg **wrong** on, from `paint-servers/`, `painting/` and
`shapes/rect/`. For each file: what's correct and why, how confident, and a
classification. Setup, method and file conventions are in
`tasks/R6-shapes-paint.md`.

All four references (ours, resvg 0.48.1, the suite's own PNG resized to
200 px, Chromium via `tests/render_chrome.py`) are in
`docs/resvg-wrong/R6-shapes-paint.png`, one row per file, columns
`resvg | suite | chrome | ours`. "ours" in that sheet is the renderer
*after* the two commits below (`git log` on this branch).

`results.csv` columns quoted below are `chrome,firefox,safari,resvg,batik,
inkscape,librsvg,svgnet,qtsvg` (1 pass, 2 fail, 0 untested, 3 crash), in that
column order, against the suite's own idea of "correct" — not necessarily
ground truth, see individual sections.

---

## `paint-servers/radialGradient/fr=0.2.svg` and `fr=0.7.svg`

`results.csv`: `1,1,1,2,2,1,1,0,2` — chrome/firefox/safari/inkscape/librsvg
pass, resvg/batik/qtsvg fail.

Both files put a black-to-white `radialGradient` with `fr` (SVG 2 focal
radius) set on a rect, `cx/cy/r` left at their defaults (50%, 50%, 50%,
concentric with the focal circle). `fr=0.2` is the ordinary case
(`fr < r`); `fr=0.7` has `fr > r`, an inner focal circle bigger than the
outer circle — a valid two-point-conical gradient (SVG 2 removed the
SVG 1.1 requirement that `fr < r`), just an inverted one (the "cone" narrows
as `t` grows instead of widening).

Rendered at matching resolution (resvg at `-w 500` vs. the suite's own
500×500 PNG, no resampling either side) the two differ by **at most 1 level
on any channel**, spread over ~11% (`fr=0.2`) / ~3.7% (`fr=0.7`) of pixels —
not concentrated at the frame stroke or any edge, but throughout the
gradient's own fill. `results.csv` evidently scores on some tighter
tolerance than the ≤8-level, ≥99% used by `tests/run_tests.py`; every other
`radialGradient` test in the suite that exercises the *concentric* case
(`default-attributes`, `focal-point-correction`, `gradientUnits=...`) scores
resvg=1, so this 1-level drift is specific to `fr≠0` — i.e. specific to
tiny-skia's `GradientType::Radial{radius1, radius2}` branch
(`radial_gradient.rs`, concentric-centers path with `ApplyConcentricScaleBias`),
which only ever runs when the focal circle's radius is nonzero.

**Correct output:** the visual result (a normal/inverted radial cone) is not
in dispute — every renderer agrees on it, including resvg. What's "wrong" is
a ≤1/255 rounding difference in exactly how the color-stop `t` is computed
along the concentric radii, inherited from tiny-skia (resvg's rasterizer),
not from usvg's `fr` parsing (`crates/usvg/src/parser/paint_server.rs:95`
just clamps `fr` to `PositiveF32`, no special-casing; `crates/resvg/src/
path.rs:143` hands `fx,fy,fr,cx,cy,r` straight to `tiny_skia::RadialGradient::
new`). Confidence: **high** that this is real and this small — verified by
direct pixel diff against the suite's own reference PNG, not just against
resvg.

**Class: (c), not fixing.** The renderer's whole approach to gradients (and
everything else) is matching resvg 0.48.1's actual pixels (`DESIGN.md` §3,
`SPEC.md` §4). This is a real, tiny (documented-as-acceptable-elsewhere,
§3.9's "within 1 of 255") quirk in resvg's own dependency, engaged only by
the `fr≠0` code path. Reproducing whatever exact-precision stop
interpolation Chrome/Firefox/Safari/Inkscape/librsvg use instead would mean
deliberately diverging from resvg's math on every gradient with a nonzero
focal radius, for a sub-percent, sub-level difference nobody can see. Not
worth the risk of regressing the (currently exact-matching) common case.

---

## `painting/fill/rgba-0-127-0-50percent.svg`

`results.csv`: `1,1,1,2,2,2,1,0,2` — chrome/firefox/safari/librsvg pass,
resvg/batik/inkscape fail.

`fill="rgba(0, 127, 0, 50%)"` — CSS Color 4's percentage `<alpha-value>`.
resvg 0.48.1 embeds svgtypes 0.16.1, whose four colour-function parsers
(`rgb`/`rgba`/`hsl`/`hsla`) read the alpha argument with `parse_number`
(plain 0..1), not `parse_number_or_percent`, so a trailing `%` invalidates
the whole paint value and usvg falls back to black — confirmed against the
compiled resvg 0.48.1 binary before this task (the old comment on
`alphaOf` in `LeanSvg/Svg.lean` recorded exactly this, since we were
deliberately matching it). Chromium (own render, `render_chrome.py`), the
suite's bundled PNG, and `results.csv`'s firefox/safari all render
translucent green instead. `grep` over the whole `resvg-test-suite/tests`
tree finds exactly one file using a percentage alpha — this one.

**Correct output:** translucent green (`rgba(0,127,0)` at ~50% over the
white canvas), per CSS Color 4, which every browser already implements and
which a newer (unreleased at 0.48.1) svgtypes also accepts. **Confidence:
high** — this is a plain, unambiguous spec reading with three independent
browser engines and the suite's own reference all agreeing, and it is a
verified version-pinned bug in resvg's exact dependency, not a rendering
judgement call.

**Class: (a), fixed.** `alphaOf` now accepts a trailing `%`, scaling the
decimal by 1/100 before the same `scaleDecimal` call the plain form uses
(the same pattern `hslFracOf` already used for `hsl()`'s S/L arguments).
Commit `7464e3b`. Corpus gate: only this file moves pass→fail against resvg
(intentional — see the summary table); zero other files touched, matching
the `grep` above.

---

## `painting/fill/valid-FuncIRI-with-a-fallback-ICC-color.svg`

`results.csv`: `2,2,2,2,1,1,2,2,1` — only batik/inkscape/qtsvg pass;
**chrome, firefox, safari and resvg all fail together.**

`fill="url(#lg1) green icc-color(acmecmyk, 0.11, 0.48, 0.83, 0.00)"` — a
valid `url()` gradient reference, with an SVG 1.1-style fallback color *and*
a legacy CSS2 `icc-color()` annotation appended to that fallback. Since
`#lg1` resolves, SVG 1.1's `<paint>` grammar says the fallback (and its
`icc-color()`) should never even be consulted — the gradient should just be
used, which is what the suite's bundled PNG shows (the `lg1` white→black
gradient).

Every actual browser disagrees with that: `resvg`'s own `parseUrlPaint`
comment (pre-existing, `LeanSvg/Svg.lean`) already documents that svgtypes'
CSS-facing `Paint` grammar has no grammar production for `icc-color(…)` at
all — so the entire attribute value fails to parse as *any* recognized
paint (not just the fallback half), and the property is dropped back to its
inherited/initial value, black. I rendered this file with Chromium directly
(`render_chrome.py`) and got the same solid black resvg (and our renderer)
produce, matching `results.csv`'s chrome=2/firefox=2/safari=2. `icc-color()`
is an SVG 1.1/CSS2 relic that no engine still parses as part of a `<paint>`
value; the suite's reference PNG looks like a leftover from when it did (or
from a spec reading no shipping engine ever implemented).

**Correct output: black**, matching resvg, us, Chromium, Firefox and Safari
(per `results.csv`) all at once. **Confidence: high** on "don't change this
— it already matches every real engine"; lower (but irrelevant to the
recommendation) on *why* the suite's PNG shows the gradient instead.

**Class: (c), not fixing.** We already produce what every tested browser
produces. The suite's own reference PNG is the outlier here, not resvg.

---

## `painting/marker/on-ArcTo.svg`

`results.csv`: `1,1,2,2,1,1,1,2,2` — chrome/firefox/batik/inkscape/librsvg
pass, safari/resvg/svgnet/qtsvg fail. Our score vs. resvg: 0.9998 (nearly
exact, not exact).

A single `M`+`A` (elliptical arc) path with `marker-start`/`marker-mid`/
`marker-end` all pointing at the same auto-oriented arrow marker. Only two
vertices exist (a 2-point path has no interior `marker-mid` target); the
question is the arrow's rotation at each end, which `orient="auto"` derives
from the path's tangent direction there.

Direct pixel diff (500 px, composited over white so transparent-background
convention differences between the suite's PNG — opaque white, alpha 0 —
and ours/resvg — black, alpha 0 — don't register as spurious diffs):

| vs. suite PNG | pixels differing >8/255 (of 250,000) | max diff |
|---|---|---|
| Chromium (native 500 px render) | 570 | 83 |
| resvg | 1,461 | 191 |
| ours | 1,585 | 195 |

Chromium is markedly closer to the suite's reference than resvg is; ours
tracks resvg (as intended — 99.98% match) and so inherits nearly the same
small divergence from Chromium/the suite. At 200 px (the sheet) the four
renders are visually indistinguishable — this is a few-degree rotation on a
small triangular marker, not a gross error.

**Likely cause:** `LeanSvg/Marker.lean`'s `orientMat`/`calcAngle4`/
`bisector16` are a faithful port of usvg's own `calc_line_angle`/
`calc_angle` (bisector of the two adjacent segment vectors, at the
*flattened* polyline's vertex, not the analytic arc tangent). Our `A`→cubic
flattening (`Geom.lean`, elliptical arc → 1–4 cubics) and resvg/usvg's own
arc flattening are independent implementations of the same conversion, and
they only need to agree to the precision of the *end-of-arc tangent
direction*, not the whole curve, for a marker's bisector angle to match — a
narrower target than the fidelity metric usually cares about, so a small,
real disagreement here doesn't show up as a shape-fill error anywhere else.

**Correct output:** the browsers'/suite's orientation (Chromium closest to
the suite PNG), not resvg's. **Confidence: medium** — the pixel evidence is
solid, but I have not isolated the exact tangent-vector formula
Chrome/Firefox use for an elliptical arc endpoint to confirm the fix.

**Class: (b), needs real work — not fixed.** This is not a "few lines":
getting it right means either computing the arc's analytic end-tangent
directly for marker orientation (bypassing the flattened polyline) or
matching resvg's own arc-to-Bézier subdivision bit-for-bit, and verifying it
doesn't move any of the other `36_markers`/`painting/marker/*` fidelity
numbers. Left as-is; estimate small-medium (isolated to `Marker.lean` and
possibly `Geom.lean`'s arc flattening).

---

## `painting/stroke-dasharray/n-0.svg`

`results.csv`: `2,2,1,2,1,2,2,0,1` — only safari/batik/qtsvg pass;
**chrome, firefox and resvg all fail together** (differently from the ICC
case above — see below).

`<rect x=40 y=40 width=120 height=120 stroke-width=20
stroke-dasharray="40 0">` — dash 40, gap **0**. The rect's perimeter (480)
is an exact multiple of the dash cycle (40), so *every* corner
(0/120/240/360 along the perimeter) lands exactly on a dash-cycle boundary.

At native 500 px, diffed against the suite's PNG, resvg and the suite/
Chromium (I re-rendered Chromium myself: **exact** 0-diff match to the
suite PNG) disagree in exactly one small region — the top-left corner,
which is the path's start/close point. There: resvg (and our renderer,
which matches it here) renders a clean mitred bracket; the suite/Chromium
render a **notch** — the same "independent butt caps, no shared join" look
every *other* zero-length-gap dash boundary already gets on this same
rectangle (e.g. the boundary at perimeter-position 120, the top-right
corner, which is notched in *all four* renderers identically, resvg
included — I checked no other region of the diff mask exists outside the
top-left one).

**Root cause, precisely:** `Geom.lean`'s `dashPoly` is a documented,
line-by-line port of Skia's `SkDashPath::InternalFilter` as tiny-skia
implements it (see the function's own doc comment, and the two other tests
it cites: `multiple-subpaths.svg`, `0-n-with-*-caps.svg`) — including one
specific optimization: when a **closed** subpath's dash walk starts inside
an "on" run with positive length left, that initial dash is deferred and
re-joined with the subpath's final dash, so the *closing* point gets an
ordinary path join instead of two independent dash caps (without this,
`dashPoly`'s own comment notes, a plain dashed `<rect>` is visibly missing
geometry at its top-left corner in the common case). That heuristic
("does this position start inside an on-run with a positive remainder")
does not distinguish *genuinely straddling* a dash (nonzero remainder,
needs the join to avoid an artificial gap) from *coincidentally landing
exactly on* a cycle boundary at the closure (here: dash 40 divides the
perimeter 480 exactly, and the gap is 0, so there is no straddling dash at
all — the wrap-around point is already a clean boundary, and Skia's own
`initialDashLength > 0` condition doesn't know that). It fires anyway,
uniquely merging the closure boundary that every other implementation
(Chrome, Firefox, and per `results.csv` most other renderers) leaves
notched like all the others.

**Correct output:** the notch, matching Chromium (which I confirmed matches
the suite PNG byte-for-byte at 500 px) and the browser majority.
**Confidence: high** on what's different and why; **medium** on "notch is
correct" specifically, since it is at bottom an SVG-spec-underdetermined
question of whether a zero-length gap should visually behave exactly like
no gap at all (which is arguably the more intuitive reading, and is what
resvg/Skia deliver) — the spec text just says "generate dashes", with no
special case for a zero-length one, and browsers apparently choose to
insert independent caps there regardless.

**Class: (b), needs real work — not fixed.** `dashPoly` is a carefully
verified, well-tested port of a real graphics library's actual dashing
algorithm (Skia's), reused correctly across (per the file's own comments)
several other corpus tests. A surgical fix needs to distinguish "the
deferred dash's remainder is nonzero because it genuinely straddles the
closure" from "the walk happens to restart exactly on a cycle boundary",
without breaking the general (and currently correct, well-tested) deferral
this file's own neighbours rely on — not a one-line change, and the payoff
is one degenerate corpus file (perimeter an exact multiple of the dash
cycle *and* a zero gap). Recommend leaving this to resvg/Skia upstream, or
a dedicated task if ever prioritized.

---

## `shapes/rect/q-values.svg`

`results.csv`: `1,1,1,2,3,2,2,0,2` — chrome/firefox/safari pass; resvg
fails; batik **crashes** (3).

`<rect x="30Q" y="30Q" width="150Q" height="150Q">` — the SVG 2 `Q`
(quarter-millimetre) length unit. resvg's warning (`usvg::parser::
svgtree:306: Failed to parse width value: '150Q'`) confirms usvg's length
parser has no `Q` branch at all; the rect's `width` fails to parse, and per
usvg's own rule an invalid `width` skips the whole shape (blank canvas,
matching our pre-fix output exactly).

**Correct output:** `1Q = 1/40 cm = 96/(2.54·40) px = 120/127 px` exactly, a
green square. Verified directly: Chromium's own render (200 px) has the
square at bbox `x:[29,169] y:[29,169]`; the suite PNG, rescaled from its
native 500 px, lands at `x:[28.4,169.6]` — the same bbox to sub-pixel
resampling noise. **Confidence: high** — three independent browsers and the
bundled reference all agree, and the conversion factor is a fixed
CSS-spec constant, not a judgement call.

**Class: (a), fixed.** Added a `Q` branch to `Svg.lean`'s `parseTextLen`
(the length parser every shape geometry attribute goes through —
`x`/`y`/`width`/`height`/`cx`/`cy`/`r`/`rx`/`ry`/`x1`/`y1`/`x2`/`y2`), commit
`54b9aad`. Verified our render's bbox now matches Chromium's exactly:
`x:[29,169] y:[29,169]`.

---

## `shapes/rect/rem-values.svg`

`results.csv`: `1,1,1,2,3,2,2,0,2` — same pattern as `q-values.svg`.

```
<svg font-family="Noto Sans" font-size="32">
  <!-- font-size="64" should be ignored, because `rem` references the root element -->
  <rect font-size="64" x="1rem" y="1rem" width="4.3rem" height="4.3rem" fill="green"/>
```

usvg's length parser has no `rem` branch either (same "Failed to parse"
warning, same blank-canvas result pre-fix). Per SVG 2/CSS Values, `rem`
always resolves against the *root* element's own font-size, regardless of
any closer ancestor's (or the element's own) `font-size` — which is exactly
what this file's own comment calls out and tests (the rect's local
`font-size="64"` must be ignored).

**Correct output:** `1rem = 32px` (the root `<svg>`'s own `font-size`),
`4.3rem = 137.6px`. Chromium's render (200 px) has the square at bbox
`x:[32,168] y:[32,168]`; the suite PNG rescaled lands at `x:[32.0,169.2]` —
matching. **Confidence: high**, same reasoning as `q-values.svg`.

**Class: (a), fixed.** Added `Style.rootFontSize`, set once in
`interpret`'s `applyEffective` when it resolves the root `<svg>` element
itself (the same `parent.pctRefSet == false` hook that already establishes
`pctRefW`/`pctRefH` there), inherited unchanged by every descendant
afterward (unlike `pctRefW`/`pctRefH`, never rescoped by a nested `<svg>` —
SVG 2's `rem` always means the *document* root). Threaded alongside
`fontSize` through `parseTextLen` and its ~10 call sites. Commit `54b9aad`
(same commit as `Q`). Verified bbox now matches Chromium's exactly:
`x:[32,168] y:[32,168]`.

---

## `shapes/rect/ch-values.svg`

`results.csv`: `1,2,1,2,3,2,2,0,2` — chrome/safari pass; **firefox fails
too**; resvg fails; batik crashes.

```
<svg font-family="Noto Sans" font-size="32">
  <rect x="1ch" y="1ch" width="9ch" height="9ch" fill="green"/>
```

`ch` is the advance width of the `"0"` glyph in the element's current font
at its current size — font-metric-dependent, unlike `Q`/`rem`. usvg has no
`ch` branch either (same failure mode as the other two).

Measured bbox (200 px canvas): Chromium (my own render) `x:[16,159]
y:[16,159]`, width 144. The suite's bundled PNG, rescaled from 500 px:
`x:[18.4,182.4]`, width 164.4 — **chrome and the suite reference disagree
by ~20px**, well outside resampling noise. `results.csv` independently
confirms an engine split: chrome/safari agree with *something*, firefox
disagrees with *both of them*.

**Correct output: unclear.** The three-way disagreement (chrome≈safari per
`results.csv`, but chrome ≠ suite PNG by a wide margin, and firefox ≠
everyone) means `ch`'s exact value is sensitive to the specific font
build/version/hinting used to measure `"0"`'s advance width, which none of
my four references can settle definitively without the exact Noto Sans
build each engine shipped when its reference was captured. **Confidence:
low** on any specific numeric answer; **high** that this is genuinely
font-metric-sensitive rather than a simple missing-unit bug like `Q`/`rem`.

**Class: (b) and (d).** (b): needs a feature — computing `ch` requires
reading the `"0"` glyph's advance width out of the embedded Noto Sans data
(`LeanSvg/Font.lean`/`Fonts/NotoSans.lean`) at parse time, for whichever
`font-family`/`font-size` context the shape attribute inherits, which
`parseTextLen`'s current signature (a plain `Fx` `fontSize`) doesn't carry
a font handle for. (d): needs a decision — which reference to target, since
the three "correct" answers on the table (chrome@144px, suite-PNG@164px,
firefox's own unknown value) don't agree, and matching any one of them
exactly depends on font-rendering specifics outside this project's control.
Not fixed.

---

## `shapes/rect/vmin-and-vmax-values.svg` and `vw-and-vh-values.svg`

`results.csv` (both files, identically): `1,1,2,2,3,2,2,0,2` —
chrome/firefox pass; **safari fails**; resvg fails; batik crashes.

```
<rect x="5vmin" y="5vmax" width="30vmin" height="30vmax" fill="green"/>   <!-- vmin/vmax file -->
<rect x="5vw"   y="5vh"   width="30vw"   height="30vh"   fill="green"/>   <!-- vw/vh file -->
```

`viewBox="0 0 200 200"` (square), so `vmin`≡`vmax`≡`vw`≡`vh` for this
document — both files should render identically. usvg has no branch for
any of the four units (same failure as `Q`/`rem`/`ch`).

I rendered Chromium two ways to rule out a testing-methodology artifact:
(1) the usual `<img>` embed at 200 px CSS width, (2) navigating directly to
the SVG file with the browser viewport itself set to exactly 200×200 (ruling
out the well-known quirk where an `<img>`-embedded SVG can resolve viewport
units against the *outer page's* viewport instead of its own rendered box).
**Both methods agree exactly:** green square at bbox `x:[10,69] y:[10,69]`
(both files, identically, as expected) — `5% of 200 = 10`, `30% of 200 =
60`, exactly the literal spec reading.

The suite's bundled PNG, rescaled from 500 px native, gives bbox
`x:[25.2,174.4]`, width ≈150 — **75% of the canvas, not 30%.** That's not a
resampling artifact (width off by 2.5×); the suite's own reference is
computing `vw`/`vh`/`vmin`/`vmax` as something else entirely (a stale or
simply incorrect implementation from whatever tool produced it).

**Correct output:** the literal spec reading — `x:[10,69] y:[10,69]`,
matching Chromium (both methods) and, per `results.csv`, Firefox.
**Confidence: high** on the numeric answer (two independent measurement
methods, two independent browser engines, and the arithmetic is
unambiguous); the suite's own PNG is the outlier and should not be trusted
here. Safari's failure (`results.csv`) and the crashing `batik` entry are
unexplained but consistent with `vw`/`vh`/`vmin`/`vmax` being one of the
less-implemented corners of SVG-in-non-browser-engines generally.

**Class: (d), needs a decision — not fixed**, *despite* Chromium and spec
agreeing (chrome and firefox agree with each other and with spec math) —
because the task's own gate for an unattended shallow fix is "suite PNG and
Chromium agree", and here they do not (150px vs. 60px, no ambiguity about
which is which). I'm confident the suite PNG is simply wrong for these two
files, but implementing `vw`/`vh`/`vmin`/`vmax` support is also the least
contained of the unit fixes: unlike `Q`/`rem` (context-free / root-only),
`vw`/`vh` are supposed to track the *document's own* viewport specifically
(not the current nested viewport `%` uses), which needs a new, separate
"root viewport size" concept threaded the same way `rootFontSize` now is —
doable, but real work, and I'd rather have Rowan confirm "trust
spec+Chrome+Firefox over the suite's PNG here" before spending it. See
"Questions for Rowan" below.

---

## Summary table

| file | class | correct reference | one-line cause |
|---|---|---|---|
| `paint-servers/radialGradient/fr=0.2.svg` | (c) not fixing | resvg itself (≤1/255 noise vs. suite PNG) | tiny-skia's concentric two-point-conical gradient stop interpolation, ≤1 level, only when `fr≠0` |
| `paint-servers/radialGradient/fr=0.7.svg` | (c) not fixing | resvg itself (≤1/255 noise vs. suite PNG) | same as `fr=0.2` |
| `painting/fill/rgba-0-127-0-50percent.svg` | (a) **fixed** (`7464e3b`) | suite PNG, Chromium, `results.csv` firefox/safari | resvg 0.48.1's pinned svgtypes 0.16.1 rejects `%` alpha; only 1 corpus file affected |
| `painting/fill/valid-FuncIRI-with-a-fallback-ICC-color.svg` | (c) not fixing | resvg itself, Chromium, `results.csv` chrome/firefox/safari | suite PNG is a stale SVG1.1 `icc-color()`-fallback reading no engine implements |
| `painting/marker/on-ArcTo.svg` | (b) not fixed | Chromium (closest to suite PNG) | arc→cubic flattening's end tangent feeds the marker bisector; ours/resvg's flattening differs slightly from Chrome's analytic tangent |
| `painting/stroke-dasharray/n-0.svg` | (b) not fixed | Chromium (exact match to suite PNG) | Skia's (ported) closed-path dash-deferral heuristic wrongly merges a closure that coincidentally lands exactly on a cycle boundary with a zero-length gap |
| `shapes/rect/q-values.svg` | (a) **fixed** (`54b9aad`) | Chromium, firefox, safari, suite PNG (all agree) | usvg has no `Q` unit; added 120/127 px ratio |
| `shapes/rect/rem-values.svg` | (a) **fixed** (`54b9aad`) | Chromium, firefox, safari, suite PNG (all agree) | usvg has no `rem` unit; added `Style.rootFontSize` |
| `shapes/rect/ch-values.svg` | (b)+(d) not fixed | unclear — chrome≈safari, suite PNG and firefox both disagree | needs font-metric plumbing *and* a decision on which reference to target |
| `shapes/rect/vmin-and-vmax-values.svg` | (d) not fixed | Chromium (both methods), firefox, spec | usvg has no `vmin`/`vmax`; suite PNG itself looks wrong (75% not 30%), fails the auto-fix gate |
| `shapes/rect/vw-and-vh-values.svg` | (d) not fixed | Chromium (both methods), firefox, spec | usvg has no `vw`/`vh`; same suite-PNG discrepancy as `vmin`/`vmax` |

## Questions for Rowan

1. **`vw`/`vh`/`vmin`/`vmax`** (2 files): Chromium (verified two independent
   ways) and Firefox agree exactly with the literal spec reading (30% of a
   200-unit viewport = 60), but the suite's own bundled reference PNG shows
   ~75% instead, and Safari also disagrees. I'm confident the suite PNG is
   simply wrong here, but the task's shallow-fix gate ("suite PNG and
   Chromium agree") isn't met, so I didn't implement it. Should I trust
   spec + Chrome + Firefox over the suite's PNG and implement `vw`/`vh`/
   `vmin`/`vmax` (needs a new "document root viewport size" concept, since
   these must NOT track a nested `<svg>`'s viewport the way `%` does)?

2. **`ch` values** (1 file): font-metric-dependent, and my three references
   (Chromium, the suite PNG, `results.csv`'s firefox column) don't agree
   with each other at all (144px / 164px / unknown-but-≠chrome). Worth
   building at all, given no available reference is trustworthy enough to
   verify against? If so, which one should the implementation target?

3. **`painting/stroke-dasharray/n-0.svg`**: our dash-deferral logic is a
   faithful, well-tested port of Skia's actual `SkDashPath::InternalFilter`
   (the same algorithm resvg's own tiny-skia dependency runs), and it's
   only wrong in one narrow, coincidental case (dash cycle divides the
   perimeter exactly *and* the gap is zero). Worth a dedicated task to
   special-case it, given the payoff is one corpus file?

4. **`painting/marker/on-ArcTo.svg`**: confirmed Chromium is measurably
   closer to the suite's reference than resvg is, but I haven't derived the
   exact analytic arc-tangent formula that would close the gap. Worth
   pursuing, or leave as a documented, sub-visual (≤0.6% of pixels, few
   degrees) known gap?

## Corpus gate (both applied fixes together)

`python3 tests/run_corpora.py --corpus resvg --route direct --out /tmp/after
--no-worst --compare <pre-fix baseline>`: exactly 3 files move pass→fail
against resvg — `rgba-0-127-0-50percent.svg`, `q-values.svg`,
`rem-values.svg` (all three listed above, all intentional). 0 newly passing,
1676/1679 corpus files byte-for-byte unchanged, resvg-correct bucket
unchanged at 1400/1522 (`tests/score_known.py`). `lake build`,
`scripts/check-theorems.sh`, `tests/run_tests.py` (46/50, same 4
pre-existing unrelated failures with or without these commits — verified by
`git stash`), `tests/run_adversarial.py` (116/116) and `tests/run_tiles.py`
(50/50) all pass. Full evidence and commands are in each commit message
(`54b9aad`, `7464e3b`).
