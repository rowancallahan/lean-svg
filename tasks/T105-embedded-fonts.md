# T105 — Fonts embedded in the SVG (`@font-face` with `data:` URIs)  (branch `claude/feat-embedded-fonts`)

Rowan reviewed the real-world corpus (`tests/realworld_verdicts.csv`,
`tests/realworld_triage.json`); the `tikz-fonts/*` group fails almost
everywhere on fonts: dvisvgm embeds the exact TeX fonts (Computer Modern and
its maths fonts) as WOFF2 in `<style>@font-face{src:url(data:...)
format('woff2')}` and lean-svg ignores them, so text falls back to Noto Sans
and maths symbols become tofu boxes.

Implement fonts embedded **in the file itself**:
- CSS `@font-face` in `<style>` (and the SVG `font-face`-less equivalents
  dvisvgm emits) with `src: url(data:...)` only. **Any non-`data:` URL is
  ignored** (external resources are never loaded; Rowan's rule). Formats:
  TrueType/OpenType (glyf), WOFF 1.0 (zlib: reuse our inflate), WOFF 2.0
  (Brotli decoder + WOFF2 table reconstruction, incl. transformed `glyf`/`loca`
  and `hmtx`). CFF outlines if they occur in the corpus (check `tikz-fonts`
  and `mpl-tests`), otherwise document as unsupported.
- `font-family` matching against the declared `@font-face` families first,
  then the embedded Noto/other fonts as today. `font-weight`/`font-style`
  descriptors as far as the corpus needs.
- Everything total and bounded: caps on decoded size (e.g. 16 MB per font,
  64 MB total), Brotli window/size limits, recursion/iteration fuel. Fuzz the
  new decoders like `tests/fuzz_font.py`. No proof statement may weaken; the
  effect layer is untouched (the font comes from the one input file).
- Add adversarial cases (malformed/huge/zip-bomb-like WOFF2) to
  `tests/run_adversarial.py`.

Then re-check the `tikz-fonts` fails Rowan noted (see the CSV notes), in
particular: tofu boxes in `cd_adjunction`, `cd_pullback`,
`flowchart_algorithm` (prime before theta), `venn_even_odd` (delta, omega);
square root drawing in `nn_attention`; `riemann_sums`; `lattice_subgroups`;
`matrix_block` (stretchy brackets); `plot_pgf_posterior` (overlapping density
label, missing space); `plot_pgf_loglog_errors` and `plot_pgf_bar` kerning;
`timeline_calendar`. Report before/after vs Chromium per file with images.
`tikz-fonts/knot_trefoil`: Rowan says neither renderer draws a trefoil;
check whether the SVG itself is wrong (corpus generation) and say so.

Measure: `run_corpora.py --corpus realworld --ref chrome` (group table before/
after), resvg suite gate (zero resvg-correct pass→fail).

---

## Common rules (every lean-svg agent)

### Conduct (Rowan's rules for every agent, read first)

- **One app.** The whole job is making lean-svg good. Work only inside this
  repository's checkout. Anything outside it is a red flag: do not read,
  write or delete files elsewhere except the scratch/tool dirs the setup
  script uses (`~/.elan`, `~/toolchains`, cargo/pip caches, `/tmp`).
- **Network: only what the task needs.** Cloning the resvg source/test suite,
  installing the pinned toolchain and packages, and reading documentation or
  GitHub issues is fine. Nothing else: no SSH, no uploading data anywhere, no
  contacting services the task does not need, no account or credential use.
- **Git: your branch only.** Commit often (small commits make rollback easy)
  and push only to the one branch your task names. No force-push, no pushing
  to `main` or any other branch, no deleting branches, no pull requests
  unless your task says so.
- **No drastic actions.** Editing files in this repo that are committed and
  can be rolled back is fine. Big or irreversible commands are not: no
  `rm -rf` outside your own build/output dirs, no system changes, no killing
  processes you did not start, no changing CI or repo settings unless the
  task says so. If something gets really difficult or seems to need a
  drastic step, stop, write down what you would need and why in your task
  file's report, push that, and end: the integrator will ask Rowan.


You are one of ~15 agents working in parallel on lean-svg, a total, float-free
SVG→PNG renderer in Lean 4 whose output is compared against resvg 0.48.1.
An integrator merges all branches afterwards, so **keep your diff small and
local**: prefer new functions/new modules (`LeanSvg/<Feature>.lean`, imported
from `LeanSvg.lean`) over rewriting shared code in `Svg.lean` / `Render.lean`.
No drive-by refactors, renames or reformatting of code you do not need.

**Setup (first thing):** `bash scripts/cloud-setup.sh` then
`export PATH=$HOME/.elan/bin:$PATH`. It installs Lean from the GitHub release,
resvg/usvg 0.48.1, numpy/pillow and the resvg test suite under
`tests/corpora/resvg-test-suite`, and builds. Read `tasks/README.md`,
`DESIGN.md` and the relevant parts of `SPEC.md` before editing.

**Invariants (hard, from tasks/README.md):** no `partial`, `unsafe`,
`@[extern]`, `panic!`, `!`-indexing, `Float`; loops over finite ranges or
structurally decreasing fuel; hot loops in `Nat`; no new build warnings;
`LeanSvg/Effect.lean` untouched unless your task is about it; no IO outside
`Effect.lean`. Code should fail loudly rather than silently: prefer
rejecting/asserting over swallowing errors, but a feature that is not
supported should degrade exactly as it does today (skip), not error.

**Reference behaviour:** match resvg/usvg 0.48.1. The Rust source is the spec
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`
into a scratch dir; `crates/usvg/src/parser/*` and `crates/resvg/src/*`).

**Baseline first, before any edit:**
```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/base --no-worst
python3 tests/run_tests.py
```

**Verification before you push (all must hold):**
1. `lake build` — no errors, no new warnings.
2. `bash scripts/check-theorems.sh` prints `theorems ok`. Note
   `proofs/SizeBound.lean` reasons about `render`; if your change breaks it,
   fix the proof, do not delete or weaken it.
3. Full corpus with delta table (the fast 100 px pass), and ALSO the default
   200 px pass that is the headline number: run the same command without
   `--fast` into `/tmp/base200` before editing and `/tmp/after200` after, and
   compare. Zero pass→fail at either width.
   Fast:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/<task number>_<feature>.svg` (use your
   task number as the file number, e.g. `71_image_gif.svg`, so files never
   collide) exercising the feature
   if it fits the local corpus style 

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.

---

## Spec implemented

**Sources.** CSS `@font-face` rules in any `<style>` element (the same
`combinedCss` the stylesheet parser sees; comments stripped), scanned by
`LeanSvg/FontFace.lean` with its own quote- and parenthesis-aware splitter:
`Css.scanValueEnd` would cut `url(data:…;base64,…)` at its `;`. Descriptors
read: `font-family` (quotes stripped, ASCII case-insensitive), `font-weight`
(keyword or number; for a range, the first number), `font-style`
(`italic`/`oblique`), and `src`. From `src`, the first entry that is
`url(data:…)` and decodes to a readable font is used. A `format()` hint
other than `woff2`/`woff`/`truetype`/`opentype` skips its entry.
**Anything that is not a `data:` URL is ignored** (relative paths, `http:`,
`file:`, `local()`): nothing outside the input file is ever read. `data:`
payloads can be base64 (whitespace skipped) or percent-encoded.

**Formats** (`LeanSvg/Woff.lean` → plain sfnt → the existing `Font.parse`):
- TrueType/OpenType with `glyf` outlines: used as is.
- WOFF 1.0: stored or zlib tables (`Inflate.zlib`, exactly `origLength`).
- WOFF 2.0: one Brotli stream (`LeanSvg/Brotli.lean`, full RFC 7932: static
  dictionary and 121 transforms, context modelling, block switching;
  `LeanSvg/BrotliData.lean` generated by `tests/gen_brotli_data.py` from the
  brotli 1.2.0 sources). Undoes the `glyf`/`loca` transform (triplets, bbox
  bitmap, composites, instructions, overlap bitmap tolerated) and the `hmtx`
  transform (lsb from `xMin`). Output is a fresh sfnt with a long `loca`
  (and `head.indexToLocFormat` patched to 1).
- **CFF (`OTTO`) is not supported**: `Font.parse` rejects it, so the face is
  skipped. Checked: no CFF font occurs in the corpus. All 161 `@font-face`
  fonts in `tikz-fonts` are WOFF 2.0 over TrueType with transformed
  `glyf`/`loca` (160 distinct), and `mpl-tests` has no `@font-face` at all.
- Font collections (`ttcf`) are rejected.

**Matching** (Chromium's behaviour; usvg 0.48.1 ignores `@font-face`):
`Svg.resolveFontFamily` walks the `font-family` list in order and checks
each name against the document's families before the embedded fonts.
Document faces sit at font index `FontSet.count + k` (`Style.docFaces`, set
at the root and inherited). Among a family's faces, `FontFace.select`
prefers the requested style, then applies `Text.matchWeight`. A character a
document font lacks falls back through the embedded fonts only
(`Text.assignFonts` and the shaper's fallback never pick a document font
that was not named). Not done: synthetic bold/oblique, `unicode-range`,
`font-stretch`, and SVG `<font>`/`<font-face>` elements (dvisvgm's SVG-font
mode; not in the corpus).

**Bounds.** Every font is capped at 16 MB (compressed input, declared table
total, reconstructed `glyf`, rebuilt sfnt, `Font.parseSized`). Brotli
decodes to the exact declared size and fails the moment a meta-block would
pass it. The first meta-block header of a bomb is enough to reject it. A
64 MB work budget is charged before decoding: each `data:` font tried pays
its *declared* decoded size (`Woff.declaredSize`), whether or not it loads,
so repeating a bomb 1000 times costs four decodes. At most 256 faces. Every
loop is a `for` over a declared count already checked against its backing
bytes, or over input bits (the Brotli meta-block and command loops use
`8 * size` bits plus output-size fuel). No `partial`, `!`, `Float` or IO.
`Effect.lean` is untouched. `render` stays pure: fonts come from the one
input file.

## Report

### Files
- New: `LeanSvg/Brotli.lean`, `LeanSvg/BrotliData.lean` (generated),
  `LeanSvg/Woff.lean`, `LeanSvg/FontFace.lean`, `LeanSvg/LICENSE-brotli.txt`,
  `tests/gen_brotli_data.py`, `tests/fuzz_woff.py`,
  `tests/svg/105_font_face.svg`, `docs/t105/*.png` (Chromium / before /
  after at 600 px).
- Changed (small, local): `LeanSvg/Svg.lean` (`Style.docFaces`,
  `resolveFontFamily` doc families first, `spanPropsOf` face selection,
  `interpretWith` scans the faces, `textShapes` passes them to
  `Text.layout`), `LeanSvg/Text.lean` (`layout` takes the document fonts;
  fallback limited to `FontSet`), `LeanSvg.lean` (imports), `FontDump.lean`
  (reads WOFF/WOFF2; `--sfnt`, `--brotli` dump modes),
  `tests/run_adversarial.py`, `NOTICE`.

### Correctness checks
- All 160 distinct corpus WOFF2 fonts, decoded by `fontdump --sfnt`, match
  fontTools exactly: cmap, hmtx, maxp and hhea compile identically, and
  every glyph has the same coordinates, contour ends, on-curve flags and
  bbox. A WOFF2 with transformed `hmtx` (a Noto Serif subset) matches too.
- Brotli round trip against Python `brotli`: qualities 0/1/5/9/11, windows
  10–24, text/font/generic modes, inputs up to 1.7 MB (random, text,
  dictionary words, Lean source). All byte-identical. A size one byte off
  either way is rejected. Speed is about 0.6–0.9 s per 1.7 MB, including
  process start.
- `tests/svg/105_font_face.svg` (WOFF2 with transformed glyf/loca/hmtx,
  WOFF1, TrueType bold as a second weight of the same family, a non-`data:`
  source that must be ignored). It embeds subsets of the resvg suite's own
  Noto fonts under new family names, so resvg's fallback draws the same
  glyphs: 99.806% within-8, PASS. That includes Noto Serif, which lean-svg
  cannot draw otherwise.

### Measurements (all runs on the same container)
| check | before | after |
|---|---|---|
| resvg suite `--fast` (100 px) | 1543 pass | 1543 pass; 0 files moved > 0.1 pt; 0 pass→fail |
| resvg suite 200 px | 1567 pass | 1567 pass; 0 files moved > 0.1 pt; 0 pass→fail |
| `run_tests.py` | 62/77 | 63/78 (new 105 passes; every other row identical) |
| `run_adversarial.py` | 147 + checks | all clean, incl. 10 new generated cases + `font_face_refs_inert` |
| `run_tiles.py` | — | 78/78 byte-identical |
| `check-theorems.sh` / `check_invariants.py` | ok | ok / ok |
| `lake build` | — | no errors, no new warnings |

`run_corpora.py --corpus realworld --ref chrome` (200 px), per group:

| group | files | pass before | pass after | median within-8 before | after |
|---|---|---|---|---|---|
| graphviz | 23 | 0 | 0 | 90.923% | 90.923% |
| matplotlib | 66 | 0 | 0 | 91.127% | 91.127% |
| matplotlib-text | 19 | 0 | 0 | 89.762% | 89.762% |
| mermaid | 8 | 0 | 0 | 93.916% | 93.916% |
| mpl-tests | 515 | 259 | 259 | 99.000% | 99.000% |
| plantuml | 8 | 0 | 0 | 92.281% | 92.281% |
| tikz | 64 | 0 | 0 | 93.977% | 93.977% |
| tikz-fonts | 64 | 0 | 0 | 93.717% | 94.009% |
| web-tikz | 50 | 0 | 0 | 91.972% | 91.972% |
| web-vega | 31 | 0 | 0 | 93.265% | 93.265% |

Exactly the 50 `tikz-fonts` files that use `@font-face` moved: all up, by
+0.16 to +2.42 points. Nothing else moved. None crosses the 99% line. The
residual in every tikz file is spread along *every* edge, glyph or not
(e.g. `cd_square`: 3.6% of pixels, all edges). Chromium lays these pages
out at a fractional height (152.13 px against our 152), so every row is
offset by a sub-pixel amount. That is the Chrome-harness rounding already
noted in `run_corpora.py`, not a font problem. The within-8 metric at
200 px therefore understates the change; the images below are the real
before/after.

### Rowan's `tikz-fonts` notes, per file
Images: `docs/t105/<file>.png`, three panels top to bottom: Chromium,
lean-svg before, lean-svg after (600 px).

| file | within-8 before | after | verdict |
|---|---|---|---|
| `cd_adjunction` | 94.982% | 95.837% | ⊥ tofu fixed; CM italic and calligraphic letters as in Chromium |
| `cd_pullback` | 95.216% | 95.692% | pullback corner ⌟ (was tofu) fixed; ×_C, ∃! correct |
| `flowchart_algorithm` | 91.303% | 92.097% | prime in θ′ (was tofu) fixed; CM Roman/italic throughout, spacing as Chromium |
| `venn_even_odd` | 92.401% | 92.739% | △ (the "delta", was tofu) and Ω fixed |
| `nn_attention` | 90.041% | 90.661% | √ drawn with the cmsy radical and rule as in Chromium; d_k subscript fixed |
| `riemann_sums` | 94.314% | 94.822% | ∫ and ∑ (both were tofu) fixed; whole formula matches |
| `lattice_subgroups` | 95.121% | 96.562% | ⟨ ⟩ (tofu) and blackboard ℤ (msbm10) fixed |
| `matrix_block` | 89.924% | 92.342% | stretchy parentheses (cmex10, were tofu stacks) fixed; a_ij/b_ij/0 in CM as Chromium |
| `plot_pgf_posterior` | 88.527% | 89.229% | "density" no longer overlaps itself; "prior Beta" / "posterior Beta" spaces back. **Not a font issue, left as is:** the MAP stem is red in ours, black in Chromium (also before T105) |
| `plot_pgf_loglog_errors` | 88.626% | 89.163% | CM fonts; 10^−1 exponents and N^−1/2 kerned as Chromium |
| `plot_pgf_bar` | 86.312% | 86.597% | CM digits; legend "2023"/"2024" no longer collide with the swatches |
| `timeline_calendar` | 81.535% | 82.674% | rotated CM labels as Chromium ("Bayes' essay" apostrophe fixed) |
| `knot_trefoil` | 96.267% | 96.267% | **the SVG is wrong, not either renderer** (below) |

**`knot_trefoil`**: the corpus source
`tests/corpora/realworld/src/tikz/knot_trefoil.tex` is
`\strand ([closed]90:2) foreach \a in {1,...,5} { .. (90+144*\a:2) };`
with Hobby curves. That puts five points on one circle, each 144° after
the last. By symmetry Hobby's algorithm makes each tangent perpendicular
to the radius, so the curve is a circle traced twice. Sampling the path
dvisvgm wrote confirms it: radius 91.0–91.5 user units throughout, winding
number 2.0. The knot library's crossing clips then land on coincident
strands. Chromium and lean-svg both draw exactly what the file says. The
fix belongs in the corpus generator: points that alternate radius, or the
knots-manual trefoil (three lobes), then regenerate the SVG.

### Fuzzing (`tests/fuzz_woff.py`, via `fontdump`)
0 violations in all runs (every exit 0/1, no timeout, no panic marker):
- Noto Serif subset WOFF2 (transformed glyf/loca/hmtx): 2000 iterations,
  seed 1.
- A corpus `cmmi10` WOFF2: 2000 iterations, seed 3. By mutator:
  glyf-transform 235 (86 decoded), hmtx 268, directory lengths 244, header
  sizes 253, stream flips 246, flips 229, truncation 215, raw Brotli 310.
- The WOFF 1.0 subset: 1000 iterations, seed 4.

### Adversarial (`run_adversarial.py`)
New generated cases, all clean. The Brotli streams are hand-encoded, so CI
needs no Brotli library.

| case | time |
|---|---|
| 45-byte Brotli bomb inflating to 256 MiB, ×1000 rules | 0.2 s |
| same bomb declared small, ×200 | 0.06 s |
| a *real* 16 MiB stream ×1000 (budget → 4 decodes) | 2.5 s |
| 2^32−1 declared sizes | 0.03 s |
| 100 garbage/truncated WOFF2 files | 0.07 s |
| WOFF1 zlib bomb ×50 | 4.5 s |
| 2000 faces / 500 families / 2000 texts | 4.6 s |
| hostile transformed `glyf` tables (32767 contours per glyph, 4 GiB stream claims, endless composite flags, 65535 glyphs, a rebuild past 16 MiB) | 3.8 s |
| `font_face_refs_inert`: non-`data:` sources render byte-identically to no `<style>` | — |

### Not done / for the integrator
- CFF/CFF2 outlines, `unicode-range`, synthetic bold/oblique, SVG fonts:
  none of them occur in the corpus; documented above.
- The Chromium comparison's sub-pixel height rounding keeps every tikz file
  under 99%. That needs a harness or root-size fix (not font work).
