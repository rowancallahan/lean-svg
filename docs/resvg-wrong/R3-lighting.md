# R3-lighting — resvg-wrong research: lighting and displacement

Branch `claude/research-r3-lighting`. Per-file findings for the seven files
`resvg`'s own `tests/corpora/resvg-test-suite/results.csv` marks resvg as
**wrong** on, where our renderer currently matches resvg's mistake (200 px
pass = 1.000000, or 0.999975 for one file). Renders are at 200 px wide unless
noted; a couple of comparisons were re-checked at 500 px (the suite PNGs'
native size) to rule out resize artefacts.

All renderer sources for the primary evidence: resvg/usvg **0.48.1** (cloned
`--depth 1 --branch v0.48.1` from `linebender/resvg` into a scratch dir), plus
`main`-branch fetches of specific files where noted, to check whether a bug is
still live upstream.

---

## `filters/feDiffuseLighting/complex-transform.svg`

**What it tests.** `<title>Complex transform</title>`. A `rect` filled with a
radial gradient (a soft white-to-transparent disc) gets `feDiffuseLighting`
with a `feDistantLight`, under `transform="skewX(30) rotate(30)"` — i.e. a
non-axis-aligned CTM (rotation *and* skew, not just scale/translate).

**results.csv:** resvg=2 (fail), chrome=2, firefox=1, safari=1 — only
Firefox and Safari pass resvg's own grading.

**What we see.** resvg and our renderer draw the lighting effect inside an
**axis-aligned rectangle** (the bounding box of the skewed/rotated rect),
with the diffuse-lit "torus" pattern itself *not* skewed to match the
element's transform. The suite PNG and a fresh Chromium render both show the
lighting effect properly warped into the **skewed parallelogram** the
transform actually produces, with the lit pattern skewed along with it.

**Root cause (confirmed via resvg's own source and a merged PR).**
`crates/resvg/src/filter/mod.rs::apply_inner` computes the filter region as
```rust
let region = filter.rect().transform(ts).map(|r| r.to_int_rect())...
```
— it transforms the filter rectangle's four corners by the full CTM `ts` and
then takes the **axis-aligned bounding box** of the result
(`to_int_rect`), discarding rotation/skew. Everything inside that primitive
is then computed directly in that axis-aligned device-pixel grid. This is a
real, acknowledged resvg limitation, not something specific to lighting:
linebender/resvg PR
[#1081](https://github.com/linebender/resvg/pull/1081) ("Fix feOffset/
feDropShadow under rotated or skewed transforms") fixed the *vector* part of
this for `feOffset`/`feDropShadow` specifically (their `dx`/`dy` used to go
through `scale_coordinates`, which drops rotation/skew), but its own
description says explicitly: *"the filter region is still clipped using the
axis-aligned bounding box of the (sheared or rotated) region rather than the
exact transformed rectangle"* — i.e. even post-fix, on the current resvg
`main`, the filter *region* itself (and everything computed inside it,
lighting included) stays axis-aligned. `feDiffuseLighting`/
`feSpecularLighting` were not touched by that PR at all.

Separately, resvg *does* correctly transform the **light source position**
through the full CTM (`transform_light_source` in `filter/mod.rs`, ported
faithfully as `Lighting.mapPt`/the `sz` scale in `LeanSvg/FilterApply.lean`
— confirmed by reading both the 0.48.1 source and our port side by side), so
the highlight is in roughly the right place in all four renders; what's
wrong is specifically the shape of the filter's raster space (a rectangle
instead of the true rotated parallelogram) and the per-pixel surface-normal
Sobel gradients being computed on that already-warped, axis-aligned raster
instead of in the element's own local (pre-CTM) space before the whole
filter result is warped onto the canvas as a unit.

**Correct output:** the suite PNG and Chromium (skewed parallelogram, lit
pattern skewed with it). High confidence — both agree with each other and
with the general SVG filter model (compute in local space, then transform
the raster like a texture), and resvg's own maintainers already describe
this exact discrepancy as a known limitation.

**Quantitative check (500 px, native suite-PNG size):** ours vs resvg mean
abs diff 0.018/255 (near pixel-identical: we faithfully reproduce resvg's
behaviour); ours vs suite PNG 34.7/255; Chromium vs suite PNG 5.2/255 (close
agreement, consistent with only anti-aliasing-level differences between two
independent, spec-following implementations).

**Class: (b), needs real work — large.** Fixing this means rendering the
filter's raster in the element's own local coordinate space (unaffected by
rotation/skew) and then compositing/warping that whole raster onto the
canvas through the full CTM, instead of computing filters directly in an
axis-aligned device-pixel window. That's a change to how *every* filter
primitive's region and per-pixel math work (`FilterApply.lean`'s `devRect`,
which is itself a faithful port of the very `NonZeroRect::transform(ts).
to_int_rect()` line quoted above), not something scoped to lighting. resvg
itself — a much more mature, actively maintained project — has only partially
fixed this (`feOffset`/`feDropShadow`'s vector math) and still has the
region itself un-fixed as of the PR above. Out of scope for a shallow fix.

---

## `filters/feDisplacementMap/simple-case.svg`

**What it tests.** `<title>Simple case</title>`, followed by a `<desc>`
that reads (verbatim): *"The `feDisplacementMap` support across all tested
applications is so bad, that it's basically non-existent. I can't even
create a test to show it. This is how bad it is. Every application produces
such different results that I can't figure out how it actually should
work."* The file's actual content, after that `<desc>`, is **just the
1×1 image-frame `<rect>`** — there is no `<feDisplacementMap>` element, no
`<filter>`, nothing else. It is a documentation stub, not a working test.

**results.csv:** resvg=2, and **every single renderer** in the row is 2
(chrome, firefox, safari, batik, inkscape, librsvg, svgnet, qtsvg) — nobody
passes, including resvg against its own suite.

**What we see.** All four renders (resvg, suite PNG, Chromium, ours) are
visually identical: a plain black 1 px frame on transparent background,
because that's the entire content of the file.

**Quantitative check.** At the suite PNG's native 500 px (to rule out
resize-interpolation artefacts from scaling a 500 px PNG down to 200), both
our renderer and resvg 0.48.1 match the suite's checked-in PNG almost
exactly: max channel diff 1/255, mean 0.001/255 (rounding noise from
antialiasing, not a real discrepancy). The 200 px comparison in the sheet
shows a slightly larger diff purely from downsizing the reference PNG with
Lanczos resampling versus rendering natively at 200 px — not a rendering bug.

**Why does results.csv still mark resvg as failing, then?** Given the
`<desc>` and the fact that literally nothing renderer-specific is being
tested (no `feDisplacementMap` element exists in the file), the all-2 row
reads as the suite author's deliberate annotation that this test is
*unusable as a pass/fail check* for `feDisplacementMap` — not a claim that
resvg mis-renders a frame rectangle. (For context, a currently-unrelated but
real resvg bug in `feDisplacementMap` itself was flagged as out of scope by
the same PR #1081: *"a pre-existing bug in feDisplacementMap where the
displacement comes out as `scale²`"* due to double-scaling — worth knowing
about for whenever `feDisplacementMap` is actually implemented/tested here,
but irrelevant to this specific file, which never invokes the primitive.)

**Correct output:** the plain frame, which is exactly what all four renders
already show. High confidence.

**Class: (c), deliberately nothing to fix.** The file doesn't exercise
`feDisplacementMap` at all; our renderer already matches both resvg and the
suite's own reference to within antialiasing noise. There is no feature gap
and no bug here to act on.

---

## `filters/fePointLight/complex-transform.svg`

**What it tests.** Same shape/idea as the diffuse-lighting file above, but
`feDiffuseLighting` with a `fePointLight`, again under
`transform="skewX(30) rotate(30)"`.

**results.csv:** resvg=2, chrome=2, firefox=1, safari=1 (same pattern as
`feDiffuseLighting/complex-transform.svg`).

**What we see / root cause:** identical bug family to
`feDiffuseLighting/complex-transform.svg` above — resvg (and our faithful
port) compute the filter in an axis-aligned bounding box of the skewed rect
instead of the true skewed parallelogram; the suite PNG and Chromium agree
with each other on the correctly-skewed shape. The point light's *position*
is correctly transformed by the full CTM in both resvg and our port (see the
previous entry), so this is specifically the filter-region/raster-space bug,
not a light-position bug.

**Quantitative check (500 px):** ours vs resvg 0.004/255 (near-identical —
faithful port of the same bug); ours vs suite PNG 20.8/255; Chromium vs
suite PNG 1.7/255 (close agreement).

**Class: (b), needs real work — large.** Same underlying architectural gap
as `feDiffuseLighting/complex-transform.svg`: fixing it requires the same
local-space-then-warp redesign of the filter pipeline, not a lighting-specific
patch. See that entry for the full root-cause explanation (not repeated here
to avoid duplicating the PR #1081 citation and source quotes).

---

## `filters/fePointLight/primitiveUnits=objectBoundingBox.svg` — **fixed**

**What it tests.** `<title>primitiveUnits=objectBoundingBox</title>`.
`<filter primitiveUnits="objectBoundingBox">` containing
`feDiffuseLighting`/`fePointLight x="0.5" y="0.8" z="0.2"`, lighting a rect
`x="20" y="20" width="160" height="160"` (bbox 20,20,160,160 in the 200×200
viewBox).

**results.csv:** resvg=2, chrome=2, firefox=1, safari=1, librsvg=1.

**What we saw (before the fix).** resvg and our renderer produced a mostly
black image with a faint patch in the upper-left corner. The suite PNG and
Chromium both show a bright, well-formed radial highlight roughly centred
around (100, 148) in the 200×200 viewBox — i.e. where `(0.5, 0.8)` maps to
once treated as a *fraction of the element's bounding box*
(`bbox.x + 0.5·bbox.w, bbox.y + 0.8·bbox.h = 20+80, 20+128 = (100, 148)`).

**Root cause (confirmed against resvg 0.48.1 *and* the current `main`
branch).** `crates/usvg/src/parser/filter.rs::convert_light_source` reads
`fePointLight`'s/`feSpotLight`'s `x`/`y`/`z` (and `feSpotLight`'s
`pointsAtX/Y/Z`) as plain raw numbers:
```rust
Some(EId::FePointLight) => Some(LightSource::PointLight(PointLight {
    x: child.attribute(AId::X).unwrap_or(0.0),
    y: child.attribute(AId::Y).unwrap_or(0.0),
    z: child.attribute(AId::Z).unwrap_or(0.0),
})),
```
with **no `primitiveUnits`/bounding-box scaling applied at all** — unlike
every *other* primitive attribute that goes through `primitiveUnits`
(`feOffset`'s `dx`/`dy`, `feGaussianBlur`'s `stdDeviation`,
`feMorphology`'s `radius`, all of which our own `Filter.lean` already scales
by `scx`/`scy`). I fetched `convert_light_source` from `linebender/resvg`'s
current `main` branch (well past 0.48.1) and it is unchanged — this is a
long-standing, still-live upstream bug, not something fixed later that we
were simply behind on.

Per the SVG spec's `primitiveUnits="objectBoundingBox"` semantics
(SVG 1.1 §15.7.4 / SVG2 "Coordinate Systems, Transformations and Units"):
axis-specific coordinates (`x`, `y`) scale by the bbox's width/height and
shift by its origin; a length that "applies equally to both axes" (here,
the light's `z` depth, and `pointsAtZ`) scales by the bbox's **normalized
diagonal**, `sqrt((w² + h²) / 2)`.

**Fix applied.** `LeanSvg/Filter/Lighting.lean`: added `obbXY`/`obbZ`
(`x' = bbox.x + x·bbox.w`, `z' = z·sqrt((bbox.w² + bbox.h²)/2)`), applied to
`fePointLight`'s `x/y/z` and `feSpotLight`'s `x/y/z`/`pointsAtX/Y/Z` in
`lightOf`/`convert`. Threaded the bbox origin/size (`bbx bby scx scy`, as
`F32`) down from `LeanSvg/Filter.lean`'s `convertUrl` (which already computes
`scx = bbox.w, scy = bbox.h` for `primitiveUnits` on every other primitive,
just wasn't passing bbox origin through for lighting) through `convertPrim`.
Identity (`bbx = bby = 0, scx = scy = 1`) for the default
`userSpaceOnUse` case, an exact no-op in `f32` arithmetic (`×1.0`, `+0.0`),
so no other file's output changes.

**Verification.**
- `grep`ped the entire test corpus (`tests/corpora/`) for
  `primitiveUnits="objectBoundingBox"` combined with any light source or
  lighting element: only these two files (this one and the `feSpotLight`
  equivalent below) match, so the blast radius is exactly the two target
  files.
- Native-200px diff to the suite PNG dropped from mean 71.8/255 (before) to
  3.2/255 (after); diff to a fresh Chromium render dropped to 0.40/255 —
  near pixel-identical to Chromium, strong confirmation the fix is right.
- Corpus gate (`tests/run_corpora.py --corpus resvg --route direct`,
  compared to a pre-fix baseline): exactly 2 files move pass→fail — this
  file and the `feSpotLight` equivalent — 0 regressions anywhere else
  (1677 unchanged, 0 newly failing besides the two intended). `tests/
  score_known.py`: "resvg correct" bucket unchanged at 1400/1522 (92.0%);
  "resvg known wrong" bucket drops from 86/96 to 84/96 (these two files no
  longer copy resvg's bug).
- `lake build`: clean, no new warnings. `scripts/check-theorems.sh`: all
  theorems/invariants still hold. `tests/run_tests.py`: 46/50, same 4
  pre-existing failures (`12_badge`, `14_flower_transforms`,
  `15_spiral_stroke`, `16_stress_2000`) confirmed unrelated by re-running
  against a stashed pre-fix build. `tests/run_adversarial.py`: 116/116
  clean. `tests/run_tiles.py`: 50/50 byte-identical tile stitching.

**Class: (a), shallow fix — done, committed.** Commit
`61dd783` on `claude/research-r3-lighting`.

---

## `filters/feSpotLight/complex-transform.svg`

**What it tests.** `feDiffuseLighting`/`feSpotLight x="140" y="150" z="40"
limitingConeAngle="20"`, again under `transform="skewX(30) rotate(30)"`.

**results.csv:** resvg=2, chrome=2, firefox=2, safari=2 — nobody but resvg's
own idea of "correct" here (interesting: all three browsers fail resvg's
grading on this one, unlike the diffuse/point-light complex-transform
files where Firefox/Safari passed).

**What we see / root cause:** identical filter-region bug family as the two
complex-transform entries above (axis-aligned bbox raster vs the true
skewed parallelogram) — resvg and our port match each other closely; the
suite PNG and Chromium both show the properly skewed parallelogram and agree
with each other. Even though results.csv marks Chrome as failing here too,
Chrome and the suite PNG visually and quantitatively agree closely with each
other on the property actually under test (the transform being honoured),
which is what matters for judging "correct" per the task's own guidance that
`results.csv`'s other-renderer columns are hints, not verdicts.

**Quantitative check (500 px):** ours vs resvg 0.003/255-ish (near-identical
— max diff 81/255 only at a few edge pixels of the hard cone cutoff, see the
`limitingConeAngle` entry below for why that specific edge is noisy); ours
vs suite PNG 20.4/255; Chromium vs suite PNG 0.9/255 (very close agreement).

**Class: (b), needs real work — large.** Same underlying gap as the other
two `complex-transform` files; see `feDiffuseLighting/complex-transform.svg`
for the full root-cause citation. Not scoped to lighting or to spotlights
specifically.

---

## `filters/feSpotLight/limitingConeAngle-anti-aliasing.svg`

**What it tests.** `<title>limitingConeAngle anti-aliasing</title>` —
specifically probes whether the cone-boundary cutoff of `feSpotLight`'s
`limitingConeAngle` is anti-aliased. No transform on the element here
(`x="20" y="20" width="160" height="160"`, no `transform=`), so this is
*not* the same bug family as the three `complex-transform` files.

**results.csv:** resvg=2, chrome=2, firefox=2, safari=1 — only Safari
passes resvg's grading.

**What we see.** Cropping to the cone-edge region: resvg and our renderer
both draw a distinctly **harder-edged, slightly jagged** cutoff at the cone
boundary. The suite PNG and Chromium both draw a visibly **softer,
gradually-fading** edge over a few pixels.

**Root cause.** `crates/resvg/src/filter/lighting.rs::light_color`, the
`feSpotLight` cone check:
```rust
if let Some(limiting_cone_angle) = light.limiting_cone_angle {
    if minus_l_dot_s < limiting_cone_angle.to_radians().cos() {
        return Color::black();
    }
}
```
— a hard binary threshold on the cosine of the light-vector angle, computed
independently per output pixel with no supersampling or smoothing at all
(confirmed identical in our `LeanSvg/Filter/Lighting.lean` port, which is
why our `ours vs resvg` diff for the `complex-transform` file above spiked
to 81/255 at a handful of pixels — exactly at this cutoff edge).

The SVG spec (Filter Effects §"light source elements") does say implementers
*should* apply "a smoothing technique such as anti-aliasing" at the cone
boundary — but it is explicitly non-normative ("should", not "must") and
**does not specify a technique**. This was flagged as underspecified on the
W3C FXTF mailing list itself ("Clarify 'smoothing technique' for
feSpotLight's limitingConeAngle"). Real user agents disagree on the
approach: per public discussion of this exact test, Firefox anti-aliases
only the pixels right at the edge (operating directly in filter space, like
resvg does structurally, just with an added AA pass), while Chrome/Safari
reportedly render the lighting pass at reduced internal resolution and then
upscale with bilinear filtering, which incidentally softens the cone edge as
a side effect rather than through an explicit smoothing formula.

**Correct output:** softer/smoother than resvg's, per the suite PNG,
Chromium and the spec's informative guidance — the *direction* of the fix is
clear. Medium confidence on that much. Low confidence on any *specific*
formula, since the spec leaves the technique unspecified and even Chrome and
Firefox reportedly arrive at their softened edges through structurally
different mechanisms (resolution/upscale vs. per-pixel edge AA) that
wouldn't bit-match each other, let alone resvg's architecture (single-sample
per output pixel, computed once, no notion of "render smaller and upscale").

**Class: (d), needs a decision from Rowan.** Options:
1. **Leave it matching resvg's hard cutoff** (status quo). Simple, but
   knowingly diverges from the spec's own (non-normative) recommendation and
   from what most real UAs do.
2. **Add a smoothstep over a fixed device-pixel width** at the cone boundary
   (e.g. ramp `minus_l_dot_s` from the cutoff cosine over some small
   angular/pixel band instead of a hard `<`). Cheap, bounded, keeps the
   existing single-sample-per-pixel architecture — but the width/falloff
   curve would be invented by us, matching no specific reference exactly
   (not resvg, not any one browser), only "softer than today, in the same
   direction as the suite/Chromium".
3. **Supersample the whole lighting pass** (e.g. 2×2 or 4×4 subpixel
   sampling of the alpha/normal/light-vector computation, averaged down).
   Closer in spirit to what Chrome/Safari's low-res-then-upscale approach
   achieves and would naturally anti-alias *any* hard edge in lighting
   output, not just this one, but multiplies the per-pixel cost of every
   lighting primitive (turns this from "shallow" into a real feature — more
   like class (b) than (a)), which needs sign-off given the project's
   bounded-work goals.

The question for Rowan: is it worth deviating from resvg 0.48.1 on an
explicitly underspecified spec corner, given no option here would bit-match
a specific reference — and if so, which of the above (or something else)?

---

## `filters/feSpotLight/primitiveUnits=objectBoundingBox.svg` — **fixed**

**What it tests.** `<filter primitiveUnits="objectBoundingBox">` containing
`feDiffuseLighting`/`feSpotLight x="0.5" y="0.8" z="0.3" pointsAtX="0.6"
pointsAtY="0.3" pointsAtZ="0.1"`, lighting the same 20,20,160,160-bbox rect
as the `fePointLight` equivalent above.

**results.csv:** resvg=2, chrome=2, firefox=2, safari=1, librsvg=1.

**What we saw (before the fix).** resvg and our renderer rendered
**completely black** — no visible light at all. The suite PNG and Chromium
both show a proper spotlight cone with a soft bloom.

**Root cause:** the exact same `convert_light_source` bug as the
`fePointLight` entry above (no `primitiveUnits` scaling applied to `x`/`y`/
`z`/`pointsAtX/Y/Z`), but here the effect is total failure rather than
"dim and in the wrong place": with `x/y/z` taken as raw user-space numbers
`(0.5, 0.8, 0.3)` and `pointsAt` as `(0.6, 0.3, 0.1)`, the light and its
target point end up almost coincident right at the origin, at a height
(`z`) far too small relative to `surfaceScale`/the 200×200 canvas, and the
light direction ends up pointing almost straight into the surface at an
angle outside the effective cone for nearly every pixel — hence solid
black. Confirmed against the same `main`-branch fetch of
`convert_light_source` cited above.

**Fix applied:** the same `obbXY`/`obbZ` change described under
`fePointLight/primitiveUnits=objectBoundingBox.svg`, which already covers
`feSpotLight`'s `x/y/z` and `pointsAtX/Y/Z` (all six coordinates go through
the same bbox transform in `lightOf`).

**Verification:** native-200px diff to the suite PNG dropped from mean
49.8/255 (before) to 2.0/255 (after); diff to a fresh Chromium render
dropped to 0.36/255. Same corpus gate, `score_known.py`, `lake build`,
`check-theorems.sh`, `run_tests.py`, `run_adversarial.py` and `run_tiles.py`
runs as the `fePointLight` entry (both fixes are one commit) — see that
entry for the full numbers; both target files are the only two in the
corpus affected.

**Class: (a), shallow fix — done, committed.** Same commit `61dd783`.

---

## Summary table

| file | class | correct reference | one-line cause |
|---|---|---|---|
| `feDiffuseLighting/complex-transform.svg` | (b) large | suite PNG, Chromium | filter region computed as an axis-aligned device-pixel bbox instead of following the element's rotate+skew transform (resvg-wide limitation, PR #1081 confirms it's still open) |
| `feDisplacementMap/simple-case.svg` | (c) nothing to fix | suite PNG (already matched) | file contains no `feDisplacementMap` element at all — a documentation stub; we already match the reference to antialiasing noise |
| `fePointLight/complex-transform.svg` | (b) large | suite PNG, Chromium | same filter-region-transform bug as the diffuse-lighting entry |
| `fePointLight/primitiveUnits=objectBoundingBox.svg` | (a) **fixed** | suite PNG, Chromium | `fePointLight`'s `x/y/z` weren't scaled by `primitiveUnits="objectBoundingBox"` (resvg bug, still on `main`); now fixed in `Filter/Lighting.lean` |
| `feSpotLight/complex-transform.svg` | (b) large | suite PNG, Chromium | same filter-region-transform bug |
| `feSpotLight/limitingConeAngle-anti-aliasing.svg` | (d) decision needed | suite PNG, Chromium (direction only) | resvg's cone cutoff is a hard per-pixel threshold with no AA; spec says implementations "should" smooth it but doesn't say how, and real UAs disagree on the technique |
| `feSpotLight/primitiveUnits=objectBoundingBox.svg` | (a) **fixed** | suite PNG, Chromium | same `primitiveUnits` bug as the point-light entry, total black output instead of just mispositioned; now fixed |

Two files fixed and committed (`61dd783`, pushed to
`claude/research-r3-lighting`); three files need the same large filter-region
architecture work (tracked once, not three times — fixing the region
transform would very likely fix all three simultaneously, plus any other
`resvg-wrong` file that turns out to share the same complex-transform
pattern in the other R-task docs); one file needs a decision from Rowan;
one file needed nothing.

## Questions for Rowan

1. **Filter-region-under-transform work (affects 3 of these 7 files, likely
   more elsewhere).** Properly supporting rotated/skewed transforms on
   filtered elements means rendering the filter's raster in the element's
   own local space and warping the whole result onto the canvas afterward,
   instead of computing directly in an axis-aligned device-pixel window (as
   resvg itself does, and as `FilterApply.lean`'s `devRect` — a deliberate,
   faithful port of resvg's `NonZeroRect::transform(ts).to_int_rect()` —
   currently does too). This is a real redesign of the filter pipeline, not
   scoped to lighting, and resvg's own maintainers have only partially
   chipped away at it (`feOffset`/`feDropShadow`'s vector math, per PR
   #1081) while leaving the region itself unfixed. Worth scoping as its own
   task before assigning fix work on any "complex-transform" file in any of
   the R-task docs (R2 in particular, since it's specifically about filter
   regions)?
2. **`limitingConeAngle` anti-aliasing.** The spec leaves the smoothing
   technique unspecified, and real UAs differ (Firefox: per-pixel edge AA;
   Chrome/Safari: reportedly render small and upscale). No fix here would
   bit-match a specific reference, only move from "hard edge, matches
   resvg" toward "soft edge, roughly matches everyone else." Worth doing,
   and if so, plain smoothstep-at-the-cutoff (cheap, single-sample) or
   supersampling the lighting pass (more principled, more expensive, closer
   to class (b) than (a))? See the full options list in that file's section
   above.
3. Given the `feDisplacementMap/simple-case.svg` file, is `feDisplacementMap`
   itself in scope for a future task at all? The suite's own `<desc>` says
   real-world implementations disagree so much on it that the suite author
   couldn't even write a meaningful test — worth knowing before anyone
   scopes a `feDisplacementMap` task expecting a clean reference to fix
   against. (Not urgent — just flagging it since it came up here.)
