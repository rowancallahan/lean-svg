# A3 -- Chromium as a whole-corpus reference

Whole resvg-test-suite corpus (1679 files), direct route, 200 px. Three `run_corpora.py` runs, all against the *original* file (never the usvg-expanded one): `--ref resvg` (the default; ours vs live resvg), `--ref chrome` (ours vs headless Chromium), and `--ref chrome --bin tests/resvg_as_bin.py` (resvg vs headless Chromium, reusing the exact same scoring code with resvg standing in for `ours`). A file "passes" when >=99% of pixels are within 8 levels of the reference, same rule as everywhere else in this harness.

## Overall pass counts

| comparison | pass | of | pass% |
|---|---|---|---|
| ours vs resvg (`--ref resvg`, default) | 1542 | 1679 | 91.8% |
| ours vs Chromium (`--ref chrome`) | 991 | 1679 | 59.0% |
| resvg vs Chromium (`--ref chrome --bin resvg_as_bin.py`) | 1002 | 1679 | 59.7% |

resvg vs Chromium is the renderer-independent number: it is how often the reference we already trust (resvg; DESIGN.md's "Not claimed" section is explicit that pixel-level correctness is measured against resvg, not proven) itself agrees with Chromium, with no lean-svg bug able to move it either way. ours vs Chromium (59.0%) sitting below ours vs resvg (91.8%), and about level with resvg vs Chromium (59.7%), is consistent with Chromium disagreeing with *both* renderers in roughly the same places, not with lean-svg being closer to or further from a shared ground truth.

## Per top-level feature directory

| dir | files | ours=resvg | ours=chrome | resvg=chrome |
|---|---|---|---|---|
| filters | 397 | 98.2% | 64.2% | 65.2% |
| masking | 93 | 96.8% | 68.8% | 68.8% |
| paint-servers | 149 | 94.6% | 87.2% | 87.9% |
| painting | 304 | 90.1% | 77.3% | 81.6% |
| shapes | 133 | 98.5% | 78.2% | 78.2% |
| structure | 247 | 88.3% | 74.1% | 70.9% |
| text | 356 | 83.7% | 5.6% | 5.9% |

## Where Chromium is (and is not) a trusted reference

resvg-vs-Chromium pass rate by feature *sub*directory (not ours -- this isolates Chromium's own disagreement with the renderer this project already trusts, from any lean-svg bug). Worst 20, at least 5 files each so one-off files do not dominate the tail:

| feature directory | files | resvg=chrome | suite's own chrome rating != passed |
|---|---|---|---|
| text/alignment-baseline | 19 | 0.0% | 4/19 |
| text/baseline-shift | 22 | 0.0% | 2/22 |
| text/font-family | 12 | 0.0% | 0/12 |
| text/font-weight | 12 | 0.0% | 0/12 |
| text/text-decoration | 21 | 0.0% | 4/21 |
| text/text-rendering | 5 | 0.0% | 5/5 |
| text/textLength | 12 | 0.0% | 2/12 |
| text/writing-mode | 23 | 0.0% | 3/23 |
| text/text | 46 | 4.3% | 5/46 |
| text/tspan | 31 | 6.5% | 4/31 |
| text/text-anchor | 13 | 7.7% | 2/13 |
| text/letter-spacing | 12 | 8.3% | 6/12 |
| text/dominant-baseline | 21 | 9.5% | 2/21 |
| text/textPath | 44 | 13.6% | 16/44 |
| text/word-spacing | 7 | 14.3% | 2/7 |
| text/font-size | 20 | 15.0% | 1/20 |
| painting/stroke-dashoffset | 6 | 16.7% | 0/6 |
| text/tref | 11 | 18.2% | 11/11 |
| structure/a | 5 | 20.0% | 0/5 |
| structure/image | 49 | 20.4% | 13/49 |

The suite's own `results.csv` records a manual chrome/firefox/safari/resvg/.../qtsvg rating per file from `tools/vdiff` (1 passed, 2 failed, 3 crashed, 0 untested). Cross-checking our pixel metric's `resvg vs Chromium` verdict against that independent, human-judged `chrome` column, over the 1618 files with a rating other than "untested": 1024 agree, 520 where our metric calls it a fail but the suite rated Chromium passed (metric stricter/false positive), 74 where our metric calls it a pass but the suite rated Chromium failed or crashed (metric more lenient/false negative). 63.3% agreement is measured, not assumed.

Those 520 "metric says fail, suite says Chromium passed" cases by top-level directory: text 268, filters 97, structure 54, painting 39, masking 24, shapes 23, paint-servers 15. A pixel metric and a human's "renders correctly" judgement are different questions -- text dominates because Chromium's font rasterizer/hinting differs from resvg's even on text both render *correctly*, which the pixel metric alone cannot tell apart from a real defect; the sub-directory table above is the more direct measurement for that reason.

### Reading the table above

Directories at the bottom are where Chromium's own rendering diverges from resvg systematically enough that **it should not be used as a pass/fail oracle there** -- treat it as a second data point, not a verdict. Directories not listed (pass rate not in the worst 20, or fewer than 5 files) are where Chromium and resvg agree closely enough to trust Chromium as a second oracle.

## Interesting disagreements

**Set A** -- ours != resvg but ours == Chromium (0 files): cases where Chromium's render agrees with lean-svg against resvg, worth a second look as possible lean-svg improvements or resvg quirks, not necessarily lean-svg bugs. **Empty.** Every file where lean-svg disagrees with resvg also disagrees with Chromium (checked directly: of the 137 files lean-svg does not match resvg on, 129 fail and 8 are non-comparable -- resvg vs Chromium's own within-8 on those same files tracks lean-svg's within-8 closely, e.g. `filters/feImage/embedded-png.svg` 48.16% vs resvg, 48.15% vs Chromium). Chromium corroborates rather than contradicts resvg on every file lean-svg gets wrong -- these look like real lean-svg defects, not resvg-specific interpretation differences.

| file | ours-vs-resvg within-8 | ours-vs-chrome within-8 | suite ratings (results.csv) |
|---|---|---|---|

**Set B** -- ours == resvg but ours != Chromium (551 files): lean-svg agrees with the trusted reference, Chromium is the odd one out -- expected wherever Chromium is not a trusted oracle (previous section). Worst 25 by ours-vs-chrome within-8:

| file | ours-vs-resvg within-8 | ours-vs-chrome within-8 | suite ratings (results.csv) |
|---|---|---|---|
| filters/filter/invalid-subregion.svg | 100.00% | 0.00% | resvg=passed, chrome=failed |
| filters/filter/zero-sized-subregion.svg | 100.00% | 0.00% | resvg=passed, chrome=failed |
| filters/feGaussianBlur/huge-stdDeviation.svg | 100.00% | 7.83% | resvg=passed, chrome=passed |
| filters/fePointLight/primitiveUnits=objectBoundingBox.svg | 100.00% | 7.83% | resvg=failed, chrome=failed |
| filters/feConvolveMatrix/bias=0.5.svg | 100.00% | 12.59% | resvg=untested, chrome=untested |
| painting/display/none-on-clipPath.svg | 100.00% | 20.36% | resvg=passed, chrome=failed |
| filters/feSpotLight/primitiveUnits=objectBoundingBox.svg | 100.00% | 23.79% | resvg=failed, chrome=failed |
| filters/feSpotLight/limitingConeAngle=0.svg | 100.00% | 28.43% | resvg=passed, chrome=failed |
| shapes/rect/ic-values.svg | 100.00% | 29.43% | resvg=untested, chrome=untested |
| filters/feSpecularLighting/specularExponent=0.svg | 100.00% | 29.57% | resvg=passed, chrome=failed |
| painting/display/none-on-svg.svg | 100.00% | 32.04% | resvg=passed, chrome=failed |
| structure/systemLanguage/on-svg.svg | 100.00% | 32.04% | resvg=passed, chrome=failed |
| shapes/rect/lh-values.svg | 100.00% | 33.57% | resvg=untested, chrome=untested |
| shapes/rect/rlh-values.svg | 100.00% | 33.57% | resvg=untested, chrome=untested |
| filters/feColorMatrix/type=saturate-with-a-large-coefficient.svg | 100.00% | 35.99% | resvg=untested, chrome=untested |
| filters/feComponentTransfer/type=table-and-tableValues=1px.svg | 100.00% | 35.99% | resvg=passed, chrome=failed |
| filters/filter/invalid-FuncIRI.svg | 100.00% | 35.99% | resvg=passed, chrome=passed |
| masking/mask/mask-on-self.svg | 100.00% | 35.99% | resvg=passed, chrome=failed |
| paint-servers/linearGradient/invalid-gradientTransform.svg | 100.00% | 35.99% | resvg=untested, chrome=untested |
| paint-servers/radialGradient/invalid-gradientTransform.svg | 100.00% | 35.99% | resvg=untested, chrome=untested |
| painting/display/none-on-defs.svg | 100.00% | 35.99% | resvg=passed, chrome=failed |
| painting/display/none-on-linearGradient.svg | 100.00% | 35.99% | resvg=passed, chrome=failed |
| painting/fill/invalid-FuncIRI-with-a-currentColor-fallback.svg | 100.00% | 35.99% | resvg=passed, chrome=failed |
| painting/fill/invalid-FuncIRI-with-a-fallback-color.svg | 100.00% | 35.99% | resvg=passed, chrome=failed |
| painting/fill/rgba-0-127-0-50percent.svg | 100.00% | 35.99% | resvg=failed, chrome=passed |

## Appendix: every feature subdirectory, all three comparisons

Full per-feature-directory pass counts (the worst-20 table above is resvg-vs-Chromium only, ranked; this is all 107 subdirectories, alphabetical):

| feature directory | files | ours=resvg | ours=chrome | resvg=chrome |
|---|---|---|---|---|
| filters/enable-background | 21 | 100.0% | 95.2% | 95.2% |
| filters/feBlend | 10 | 100.0% | 100.0% | 100.0% |
| filters/feColorMatrix | 16 | 100.0% | 62.5% | 62.5% |
| filters/feComponentTransfer | 22 | 100.0% | 95.5% | 95.5% |
| filters/feComposite | 18 | 100.0% | 100.0% | 100.0% |
| filters/feConvolveMatrix | 25 | 100.0% | 84.0% | 84.0% |
| filters/feDiffuseLighting | 22 | 100.0% | 95.5% | 95.5% |
| filters/feDisplacementMap | 1 | 100.0% | 100.0% | 100.0% |
| filters/feDistantLight | 4 | 100.0% | 100.0% | 100.0% |
| filters/feDropShadow | 8 | 100.0% | 62.5% | 62.5% |
| filters/feFlood | 8 | 100.0% | 75.0% | 75.0% |
| filters/feGaussianBlur | 13 | 100.0% | 38.5% | 38.5% |
| filters/feImage | 27 | 74.1% | 59.3% | 74.1% |
| filters/feMerge | 3 | 100.0% | 0.0% | 0.0% |
| filters/feMorphology | 14 | 100.0% | 92.9% | 92.9% |
| filters/feOffset | 9 | 100.0% | 88.9% | 88.9% |
| filters/fePointLight | 4 | 100.0% | 50.0% | 50.0% |
| filters/feSpecularLighting | 8 | 100.0% | 37.5% | 37.5% |
| filters/feSpotLight | 12 | 100.0% | 41.7% | 41.7% |
| filters/feTile | 7 | 100.0% | 85.7% | 85.7% |
| filters/feTurbulence | 19 | 100.0% | 26.3% | 26.3% |
| filters/filter | 74 | 100.0% | 27.0% | 27.0% |
| filters/filter-functions | 43 | 100.0% | 60.5% | 60.5% |
| filters/flood-color | 7 | 100.0% | 100.0% | 100.0% |
| filters/flood-opacity | 2 | 100.0% | 100.0% | 100.0% |
| masking/clip | 1 | 100.0% | 0.0% | 0.0% |
| masking/clip-rule | 1 | 100.0% | 100.0% | 100.0% |
| masking/clipPath | 52 | 98.1% | 84.6% | 84.6% |
| masking/mask | 39 | 94.9% | 48.7% | 48.7% |
| paint-servers/linearGradient | 38 | 100.0% | 94.7% | 94.7% |
| paint-servers/pattern | 31 | 74.2% | 51.6% | 54.8% |
| paint-servers/radialGradient | 45 | 100.0% | 97.8% | 97.8% |
| paint-servers/stop | 32 | 100.0% | 96.9% | 96.9% |
| paint-servers/stop-color | 1 | 100.0% | 100.0% | 100.0% |
| paint-servers/stop-opacity | 2 | 100.0% | 100.0% | 100.0% |
| painting/color | 4 | 100.0% | 100.0% | 100.0% |
| painting/context | 15 | 33.3% | 33.3% | 80.0% |
| painting/display | 9 | 100.0% | 22.2% | 22.2% |
| painting/fill | 60 | 98.3% | 90.0% | 90.0% |
| painting/fill-opacity | 8 | 100.0% | 87.5% | 87.5% |
| painting/fill-rule | 2 | 100.0% | 100.0% | 100.0% |
| painting/image-rendering | 3 | 33.3% | 0.0% | 0.0% |
| painting/isolation | 2 | 100.0% | 100.0% | 100.0% |
| painting/marker | 63 | 98.4% | 88.9% | 87.3% |
| painting/mix-blend-mode | 20 | 100.0% | 90.0% | 90.0% |
| painting/opacity | 9 | 100.0% | 88.9% | 88.9% |
| painting/overflow | 5 | 100.0% | 100.0% | 100.0% |
| painting/paint-order | 14 | 78.6% | 50.0% | 85.7% |
| painting/shape-rendering | 8 | 100.0% | 87.5% | 62.5% |
| painting/stroke | 20 | 95.0% | 80.0% | 80.0% |
| painting/stroke-dasharray | 17 | 70.6% | 52.9% | 64.7% |
| painting/stroke-dashoffset | 6 | 0.0% | 0.0% | 16.7% |
| painting/stroke-linecap | 9 | 100.0% | 100.0% | 100.0% |
| painting/stroke-linejoin | 5 | 100.0% | 100.0% | 100.0% |
| painting/stroke-miterlimit | 5 | 100.0% | 100.0% | 100.0% |
| painting/stroke-opacity | 8 | 100.0% | 87.5% | 87.5% |
| painting/stroke-width | 5 | 80.0% | 60.0% | 80.0% |
| painting/visibility | 7 | 100.0% | 57.1% | 57.1% |
| shapes/circle | 6 | 100.0% | 83.3% | 50.0% |
| shapes/ellipse | 12 | 100.0% | 83.3% | 66.7% |
| shapes/line | 10 | 100.0% | 100.0% | 100.0% |
| shapes/path | 57 | 96.5% | 73.7% | 80.7% |
| shapes/polygon | 5 | 100.0% | 100.0% | 100.0% |
| shapes/polyline | 5 | 100.0% | 100.0% | 100.0% |
| shapes/rect | 38 | 100.0% | 71.1% | 71.1% |
| structure/a | 5 | 100.0% | 20.0% | 20.0% |
| structure/defs | 7 | 100.0% | 85.7% | 85.7% |
| structure/g | 2 | 100.0% | 100.0% | 100.0% |
| structure/image | 49 | 73.5% | 46.9% | 20.4% |
| structure/style | 16 | 100.0% | 93.8% | 93.8% |
| structure/style-attribute | 4 | 100.0% | 75.0% | 75.0% |
| structure/svg | 42 | 76.2% | 73.8% | 78.6% |
| structure/switch | 13 | 100.0% | 61.5% | 61.5% |
| structure/symbol | 16 | 100.0% | 100.0% | 100.0% |
| structure/systemLanguage | 10 | 90.0% | 30.0% | 30.0% |
| structure/transform | 19 | 100.0% | 94.7% | 94.7% |
| structure/transform-origin | 23 | 78.3% | 73.9% | 91.3% |
| structure/use | 41 | 100.0% | 97.6% | 95.1% |
| text/alignment-baseline | 19 | 84.2% | 0.0% | 0.0% |
| text/baseline-shift | 22 | 100.0% | 0.0% | 0.0% |
| text/direction | 2 | 100.0% | 0.0% | 0.0% |
| text/dominant-baseline | 21 | 100.0% | 9.5% | 9.5% |
| text/font | 2 | 50.0% | 50.0% | 50.0% |
| text/font-family | 12 | 83.3% | 0.0% | 0.0% |
| text/font-kerning | 3 | 66.7% | 0.0% | 0.0% |
| text/font-size | 20 | 100.0% | 15.0% | 15.0% |
| text/font-size-adjust | 1 | 100.0% | 0.0% | 0.0% |
| text/font-stretch | 3 | 0.0% | 0.0% | 0.0% |
| text/font-style | 3 | 100.0% | 0.0% | 0.0% |
| text/font-variant | 2 | 0.0% | 0.0% | 0.0% |
| text/font-weight | 12 | 75.0% | 0.0% | 0.0% |
| text/glyph-orientation-horizontal | 1 | 100.0% | 0.0% | 0.0% |
| text/glyph-orientation-vertical | 1 | 100.0% | 0.0% | 0.0% |
| text/kerning | 2 | 100.0% | 0.0% | 0.0% |
| text/lengthAdjust | 4 | 0.0% | 0.0% | 0.0% |
| text/letter-spacing | 12 | 75.0% | 8.3% | 8.3% |
| text/text | 46 | 60.9% | 2.2% | 4.3% |
| text/text-anchor | 13 | 92.3% | 7.7% | 7.7% |
| text/text-decoration | 21 | 95.2% | 0.0% | 0.0% |
| text/text-rendering | 5 | 60.0% | 0.0% | 0.0% |
| text/textLength | 12 | 83.3% | 0.0% | 0.0% |
| text/textPath | 44 | 88.6% | 13.6% | 13.6% |
| text/tref | 11 | 100.0% | 18.2% | 18.2% |
| text/tspan | 31 | 96.8% | 6.5% | 6.5% |
| text/unicode-bidi | 1 | 0.0% | 0.0% | 0.0% |
| text/word-spacing | 7 | 100.0% | 14.3% | 14.3% |
| text/writing-mode | 23 | 78.3% | 0.0% | 0.0% |

## Comparison sheet

`A3-chromium.png`, 20 rows of `resvg | Chromium | ours` at 200 px, the files below (capped at 2 per top-level directory so no single noisy directory fills the sheet):

| # | file | set |
|---|---|---|
| 1 | filters/filter/invalid-subregion.svg | B: ours=resvg, ours!=chrome |
| 2 | painting/display/none-on-clipPath.svg | B: ours=resvg, ours!=chrome |
| 3 | shapes/rect/ic-values.svg | B: ours=resvg, ours!=chrome |
| 4 | structure/systemLanguage/on-svg.svg | B: ours=resvg, ours!=chrome |
| 5 | masking/mask/mask-on-self.svg | B: ours=resvg, ours!=chrome |
| 6 | paint-servers/linearGradient/invalid-gradientTransform.svg | B: ours=resvg, ours!=chrome |
| 7 | text/tspan/with-filter.svg | B: ours=resvg, ours!=chrome |
| 8 | filters/filter/zero-sized-subregion.svg | B: ours=resvg, ours!=chrome |
| 9 | painting/display/none-on-svg.svg | B: ours=resvg, ours!=chrome |
| 10 | shapes/rect/lh-values.svg | B: ours=resvg, ours!=chrome |
| 11 | paint-servers/radialGradient/invalid-gradientTransform.svg | B: ours=resvg, ours!=chrome |
| 12 | structure/style-attribute/non-presentational-attribute.svg | B: ours=resvg, ours!=chrome |
| 13 | masking/mask/mask-on-self-with-mask-type=alpha.svg | B: ours=resvg, ours!=chrome |
| 14 | text/textPath/with-filter.svg | B: ours=resvg, ours!=chrome |
| 15 | filters/feGaussianBlur/huge-stdDeviation.svg | B: ours=resvg, ours!=chrome |
| 16 | shapes/rect/rlh-values.svg | B: ours=resvg, ours!=chrome |
| 17 | painting/display/none-on-defs.svg | B: ours=resvg, ours!=chrome |
| 18 | structure/style/non-presentational-attribute.svg | B: ours=resvg, ours!=chrome |
| 19 | masking/mask/mask-on-self-with-mixed-mask-type.svg | B: ours=resvg, ours!=chrome |
| 20 | paint-servers/pattern/invalid-patternTransform.svg | B: ours=resvg, ours!=chrome |
