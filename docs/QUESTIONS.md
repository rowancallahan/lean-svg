# Open questions for Rowan

Collected from the research and audit docs (`docs/resvg-wrong/`, `docs/audit/`, `docs/near-miss/`). Each links back to its source doc.

## From [docs/resvg-wrong/R1-enable-background.md](resvg-wrong/R1-enable-background.md)

1. Confirm: since resvg 0.48.1 treats `enable-background` as fully inert and
   `BackgroundImage`/`BackgroundAlpha` as aliases for `SourceGraphic`, should
   `LeanSvg/Filter.lean` stay exactly as-is (matching resvg's substitution),
   or would you rather these inputs resolve to fully transparent black
   instead of `SourceGraphic`? Both keep every corpus file's score unchanged
   (none of the 20 exercise a case where the two choices differ, since a
   filter's first/only primitive reading `BackgroundImage` is always the
   element's own filter subregion), but the two choices diverge on a
   hypothetical file with unfiltered content painted right after the
   `enable-background="new"` boundary and before the filtered element, inside
   the *same* filter's subregion at a point `SourceGraphic` would also cover
   — resvg's current substitution is not exactly "transparent," it's "alias
   to whatever this element would have painted anyway." Low-stakes; no corpus
   file distinguishes the two.
2. Is there any interest in a from-scratch, bounded implementation of real
   background accumulation (e.g. capped to N immediately-preceding sibling
   subtrees, or capped by total painted area) purely to pass the suite PNG on
   these 20 files, given it would then disagree with resvg (dropping us from
   1.000000 to failing) and disagree with every browser? My read is no — the
   task brief's `results.csv` framing ("if we pass, we're copying resvg's
   mistake") reads as "match reality (resvg/browsers), not the SVG 1.1 text,"
   but confirming before anyone spends real time on it.

## From [docs/resvg-wrong/R2-filters.md](resvg-wrong/R2-filters.md)

1. **Root cause A (7 files)** is a real architectural gap versus the spec —
   filter regions and primitive geometry should live in the affine local
   frame of the element referencing the filter, not an axis-aligned
   device-space box. resvg has the same gap and there's no sign it plans to
   fix it. Is this worth a dedicated task (a new coordinate frame threaded
   through `FilterApply.lean`/`Render.lean`'s filter path), given it would
   both diverge from resvg's pixels on rotated/skewed filters and touch the
   tile-invariance/byte-identity guarantees `Render.lean` currently relies on
   for filter layers?
2. **`feFlood/partial-subregion.svg`** (class d): resvg's own source has an
   unexplained special case exempting `feOffset` from subregion clipping.
   Fixing it to match spec/chrome would mean re-clipping the *final* filter
   result to the union of all subregions after an offset, which risks
   changing output on other filter tests that currently pass against resvg.
   Worth a full corpus-gate run to scope, or leave as an accepted quirk?
3. **`feImage` `data:` URI decoding** (`feImage/with-subregion-5.svg`, class
   b): the PNG decoder already exists for `<image>` (T61/T63). Worth a
   follow-up task to wire it into `FeImage.dataCanvas`, or is this low
   enough value (one test file in the whole suite) to leave as a stub?
4. **`BackgroundImage`/`BackgroundAlpha`** (3 files, class c): these overlap
   `tasks/R1-enable-background.md`'s scope. Given resvg's own maintainers
   call it "not planed" and no current browser implements it, I'd suggest
   folding these three files into R1's decision rather than tracking them
   separately here — agree?
5. **Root cause B** (4 files, class c): small (≤11/255 mean, mostly ≤1%)
   pixel differences from resvg's box-blur and whole-pixel-offset
   approximations. These match `DESIGN.md`'s documented, intentional
   trade-offs. Confirming these don't need action — correct?

## From [docs/resvg-wrong/R3-lighting.md](resvg-wrong/R3-lighting.md)

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

## From [docs/resvg-wrong/R4-text-layout.md](resvg-wrong/R4-text-layout.md)

1. **Group A (emoji/CJK/Cyrillic glyph coverage).** Confirmed out of scope
   given the embedded-font-size constraint, but flagging explicitly: is
   "Latin-only, falls back silently" the policy we want long-term, or would
   a much smaller partial expansion (e.g. Cyrillic, which is a few hundred
   glyphs, not the tens of thousands CJK needs) ever be worth it? No action
   needed unless you want it.

2. **Groups C and D (`path` attribute, `side="right"`).** Both are real SVG
   2 features where **Firefox is the only renderer in the whole comparison
   set that gets it right** — not resvg, not Chromium, not Safari — and both
   are open items on resvg's own SVG 2 changelog (unchecked, no PR attached
   as of 0.48.1). Matching resvg/usvg is our stated reference behaviour
   (DESIGN.md §"Reference behaviour"), and implementing these would be a
   deliberate, permanent divergence from that reference for four files'
   worth of benefit, in exchange for matching a spec reading that only one
   browser bothers with. Worth doing, or worth leaving as documented known
   gaps (perhaps to revisit if/when resvg itself ships them)?

3. **Group B (layers for `tspan`/`textPath`).** This is the one place in
   this batch with a clean, uncontested correct answer (suite and Chromium
   agree on all five files), a tracked upstream admission that resvg is
   wrong here too (`svg2-changelog.md` line 157), and a clear, if not tiny,
   path to a fix (reuse the existing `groupBegin`/`groupEnd` layer machinery
   from inside `textShapes`, per Svg.lean:3006-3015 and the three existing
   call sites at Svg.lean:3050/3854/4107 that do the equivalent check for
   ordinary elements). Worth scheduling as a real task (fix-R4 or similar) even
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

## From [docs/resvg-wrong/R5-text-props.md](resvg-wrong/R5-text-props.md)

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

## From [docs/resvg-wrong/R6-shapes-paint.md](resvg-wrong/R6-shapes-paint.md)

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

## From [docs/resvg-wrong/R7-structure-masking.md](resvg-wrong/R7-structure-masking.md)

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

## From [docs/resvg-wrong/R8-unrated.md](resvg-wrong/R8-unrated.md)

1. **CSS Values 4 length units resvg 0.48.1 doesn't support (`ic`, `lh`,
   `rlh`, `vi`, `vb`, and `cap` by extension) — implement them anyway, diverging
   from resvg, or hold the line on resvg fidelity?**
   Five `shapes/rect/*-values.svg` files exercise these. Chromium supports
   all five and produces real, spec-consistent, often dramatically different
   (visible-content-vs-blank) output; resvg supports none of them and drops
   the whole attribute as invalid, same as we do today. We already
   byte-match resvg on all five (all blank except `cap-values.svg`, which
   is blank for an unrelated, coincidentally-identical reason). Fixing any
   of them would *improve* spec/Chrome fidelity while *regressing* our
   stated resvg-fidelity metric on that file. `ic` and `vi`/`vb` have small,
   scoped fixes ready to go (see their entries above) if the answer is
   "implement them"; `lh`/`rlh` additionally need a new `line-height`
   property in the style pipeline (half a day-ish) regardless of the answer
   to this question.

2. **`painting/stroke-width/negative.svg`: clamp negative `stroke-width` to
   0 (matches resvg, and the suite's own stated intent — "nothing should be
   rendered"), or treat the whole declaration as invalid-and-ignored,
   falling back to the initial value `1` (matches Chrome and current CSS
   Values-and-Units error-handling text)?** Same fidelity-vs-spec tension as
   (1), on a single, isolated attribute. Given the project's stated target
   is resvg specifically, the default answer is almost certainly "keep
   as-is" — flagging so the Chrome divergence is a documented, deliberate
   choice.

3. **Is broader font coverage (beyond the single embedded Latin Noto Sans)
   worth prioritizing?** Five files in the text batch fail or lose content
   entirely because the renderer has exactly one embedded typeface:
   `text/text/rotate-on-Arabic.svg` (needs Arabic contextual shaping + bidi,
   large, multi-week), `text/text/complex-grapheme-split-by-tspan.svg`
   (needs Cyrillic glyphs + combining-mark/GPOS attachment, large),
   `text/dominant-baseline/use-script.svg` (needs a Devanagari glyph table,
   medium — font already vendored), and
   `text/writing-mode/tb-with-rotate.svg` /
   `tb-with-rotate-and-underline.svg` (need a font-fallback mechanism that
   doesn't exist at all today, plus Amiri/Mplus1p glyph tables — both fonts
   are already vendored in `tests/corpora/resvg-test-suite/fonts`). Notably,
   the two `writing-mode/tb-with-rotate*.svg` files are mis-stated as
   "currently pass" in this task's own file table — they actually score
   0.978/0.972 and **fail** the harness's 0.99 threshold today, rendering
   fully blank where resvg (and Chrome) render real content. Recommend
   updating the task-generation tooling that produced this file's "our
   status vs resvg" column, since it undercounts real failures on sparse
   text renders (see also point 4).
4. **(Process note, not a decision needed now.)** The corpora harness's
   pixel-fraction pass metric is a poor proxy for "is the content there" on
   text-heavy, mostly-blank canvases: `text/dominant-baseline/use-script.svg`
   numerically "passes" at 0.9914 despite rendering a fully blank canvas
   where resvg/Chrome draw a real glyph, and the two `writing-mode`
   files above undercount similarly. Worth a follow-up task if sparse-text
   fidelity becomes a priority (e.g. a content-presence check alongside the
   pixel-fraction score).
5. **`filters/feTile/complex-transform.svg`: no action requested, but
   flagging the architecture boundary.** resvg computes filters (and tiling)
   on an axis-aligned filter-region raster, dropping skew/shear components
   of an element's transform; Chromium's tiling visibly follows the skew.
   Matching Chrome here would mean abandoning the axis-aligned filter-canvas
   architecture in `DESIGN.md` §3.11 for full affine resampling — a large
   change that would also move us *away* from resvg fidelity, since resvg
   has the same limitation. Not recommending any change; noting it since
   it's the kind of gap that could resurface if the project's target ever
   shifts from "match resvg" to "match the spec ideal."
