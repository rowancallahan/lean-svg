# Decisions (Rowan)

## 2026-09-23, after PR #13

State at merge: resvg suite 1578/1679 at 200 px; 1440/1522 (94.6%) of the
files resvg renders correctly, 98.2% counting the 49 near-misses at 97–99%.
Open items in `docs/QUESTIONS.md`; diagnoses in `docs/resvg-wrong/`,
`docs/near-miss/`, `docs/audit/`.

**Next session, in order:**

1. **Class (b) resvg-wrong fixes** (~30 files, ~5 root causes; see the
   `docs/resvg-wrong/R*.md` summary tables): text layers for
   `opacity`/`clip-path`/`mask`/`filter` on `tspan`/`textPath`; filter
   regions under rotation/skew; `textPath` `path=` and `side=`; the rest by
   group. Use the suite PNG, and Chromium where `results.csv` rates it
   correct, as the reference, not resvg.
2. **Fonts: yes.** Up to 10–50 MB of additional embedded fonts is fine,
   **same licence as the current ones (OFL)** only. Priority: broad script
   coverage (Cyrillic, Greek, CJK, Arabic/Hebrew, Devanagari, …). Emoji:
   not now. The "font paths / text element" redesign: later, discuss first.
3. **Newer CSS units and shapes: yes, all of them.** `vw`/`vh`/`vmin`/
   `vmax`, `ch`, `ic`, `lh`/`rlh`, and CSS basic shapes in `clip-path`
   (`circle()`, `ellipse()`, `inset()`, `polygon()`, `path()`). Where the
   spec leaves a choice (e.g. the viewport for `vw` in a standalone
   renderer), follow Chromium and write the choice down.

**Not now:** `enable-background` (deprecated), emoji, legacy CSS `clip`.
**Still open (ask Rowan):** DTD internal entities, legacy encodings,
bidi/RTL scope, `textPath` Chromium-vs-suite disagreements.

## To do when parity is reached: a feature-support survey (Rowan, 2026-09-23)

Survey the whole feature corpus (the resvg suite's feature directories plus
the features it does not test) and decide, feature by feature: supported /
not supported / supported differently. For each, write down the rule that
defines "correct" for it (resvg, the suite PNG, Chromium, the spec, or our
own policy such as no external resources) so the pass criterion is explicit
per feature rather than "match resvg". This becomes part of `spec/`.

## To do after the current merges: a `spec/` folder (Rowan, 2026-09-23)

Readers will not read the Lean code or the proofs, only the theorem
statements and their explanations. So:

- Move every theorem into a `spec/` folder: the effect-layer theorems
  (`LeanSvg/Effect.lean`), `proofs/*` (size bound, locality, decoder
  contracts, gzip cap, image locality) and the axiom/invariant audit.
  Proofs may live beside them, but `spec/` is what people read.
- `spec/` gets its own small static website (HTML) to read through.
- Each theorem gets a plain-language statement and an explanation of why it
  holds and what it rules out; Rowan writes the long-form essay and the
  walkthrough (expected to be several times longer than today's SPEC.md).
- Keep the checks (`scripts/check-theorems.sh`, CI) pointing at the new
  locations.

## The road to shipping (Rowan, 2026-09-23)

After items 1–3 above, in this order:

4. **Review pass.** Quick full run; Rowan looks at every file that is not
   close (a click-through gallery: reference | ours | diff) and marks each
   acceptable or not.
5. **Compressed PNG output: use lean-zip.** The size theorem only needs a
   loose bound: the compressed output is no bigger than the stored
   (uncompressed) encoding, which `proofs/SizeBound.lean` already bounds.
   The goal is only that output can never grow without bound.
6. **Lock down behaviour (our own bytes).** Accept the current outputs as golden images
   (byte hashes of our own PNGs for the whole corpus plus the local tests),
   and make any change to a locked output fail CI unless explicitly
   re-blessed. After this point regressions are caught exactly, not by a
   tolerance.
7. **Extreme optimisation pass.** Profile and optimise with the golden
   images as the safety net (outputs must stay byte-identical). Measure
   against resvg; it may already be fast enough.
8. **Theorems.** Rowan reorganises and reviews every theorem; each gets a
   plain-language statement.
9. **Introduction and docs.** A complete introduction: what is proved, what
   is trusted, what is tested, how to use it.
10. **Tests in Lean.** Long term, move the Python harness to Lean.
11. **Ship** as a safe SVG rendering backend. The summary lists the CVE
    classes (and specific CVEs) in other SVG renderers that this design
    rules out, and says for each which property (effect confinement,
    totality, bounds, no external resources, no FFI) does it. Start from
    DESIGN.md §2's threat model and ROADMAP's CVE mentions
    (librsvg CVE-2023-38633, CVE-2019-20446, Inkscape CVE-2026-4980).

## Rotated filters: resvg is wrong, local tests follow Chromium (2026-09-23)

T90 renders filters in the element's local (rotated) frame. Three local tests
now differ from resvg but match Chromium better (within-8 vs Chromium, 400 px):

| file | resvg | before T90 | now |
|---|---|---|---|
| 40_feimage | 0.966 | 0.958 | 0.969 |
| 44_turbulence | 0.356 | 0.350 | 0.475 (noise; visually the same field as Chrome) |
| 90_filter_rotate | 0.902 | n/a | 0.975 |

resvg rasterises the filter region axis-aligned and does not rotate
turbulence or blur with the element. `tests/run_tests.py` still scores these
three against resvg, so they show as failing there; this is expected.

## T93 merged: `text/direction/rtl.svg` stops matching resvg (2026-09-23)

resvg is rated wrong on this file. Before T93 we drew tofu boxes (which
happened to score 0.984 vs the suite PNG); now the Arabic is shaped and
right-to-left, in Amiri, while the suite PNG uses Noto Sans Arabic (0.980).
Visually correct; the remaining gap is the font. Follow-up option: embed Noto
Sans Arabic (OFL, ~0.2 MB subset) for the "Noto Sans Arabic" family.

## To think about (Rowan): exit codes and output destinations (2026-09-23)

Current direction (T98b): no stdout/stderr; the output files and the exit
code are the only effects. Open for Rowan to decide later:

- **Which exit codes**, and how many distinct failure codes.
- **Outputs as explicit destinations.** On Linux stdout and stderr are just
  files (fd 1 and 2). Idea: the user names each output, and may name stdout
  or stderr instead of a path (e.g. PNG to stdout for piping, warnings to
  stderr). Nothing is written anywhere the user did not pick, and each
  output goes to exactly one place. The theorems would then be about the
  chosen destinations rather than fixed paths.

## T99 follow-ups decided (Rowan, 2026-09-23)

- `enable-background`, `BackgroundImage`, `BackgroundAlpha`: stay unsupported
  (SVG 2 removed them; no major browser implements them).
- External files (linked PNG/SVG, external CSS, external `tref`, `xlink` to
  another file): stay blocked. The renderer reads exactly one input file.

Still open from T99: spotlight cone edge, box blur vs Gaussian, legacy
features Chromium ignores, `xml:lang` font selection.

## T99 questions answered (Rowan, 2026-09-24)

- **Spotlight cone edge:** follow the suite's soft fade at the
  `limitingConeAngle` edge (Skia), not resvg's hard edge. Files resvg is rated
  correct on that change are then judged against the suite PNG.
- **Blur:** keep resvg's three-box-blur approximation for now.
  **Reminder / to do:** move to a true Gaussian later (Chromium's behaviour);
  every blur file will need re-judging when that happens.
- **Legacy features Chromium also ignores** (`clip` property, `icc-color`,
  `glyph-orientation-*`, `kerning=<length>`): keep ignoring; excluded in
  `tests/criteria.csv` where resvg is not the reference.
- **`xml:lang`:** choose the fallback font for Han characters by language tag
  (`ja` → Mplus 1p, `ko` → Noto Sans KR, else Noto Sans SC), as Chromium does.

## Human review of the 76 no-reference files (Rowan, 2026-09-24)

Verdicts are in `tests/human_verdicts.csv` (66 pass, 10 fail after the
three SVG 2 unit files were confirmed against Chromium). Follow-ups:

- **Fix (T102):** invalid (singular) `gradientTransform`/`patternTransform`
  draws nothing, like Chromium (linear, radial, pattern); markers on a path
  with several subpaths follow Chromium (`target-with-subpaths-2`);
  `textPath/complex` (vertical text on a path) draws the text;
  `rtl-with-vertical-writing-mode` placed like Chromium (centred on the
  column); `complex-graphemes-and-coordinates-list` follows the suite PNG;
  `fePointLight` with `primitiveUnits=objectBoundingBox` lighter, like the
  suite; negative `font-size` draws nothing and reports a warning.
- **Fix (T101, running):** `feSpotLight` soft cone edge
  (`complex-transform`, `limitingConeAngle-anti-aliasing`).
- **To think about (Rowan):** `feDisplacementMap/simple-case` draws nothing
  today, which is accepted for now.
- **Later:** emoji (`compound-emojis-and-coordinates-list`: a rainbow flag is
  one grapheme, so three boxes, not more).
- **Noted:** `feColorMatrix type=saturate` with a large coefficient looks less
  saturated than Chromium's, but Chromium has banding; ours is accepted.

## Next phases (Rowan, 2026-09-24)

1. After T101/T102: render our images for every example and re-review.
2. **Real-world corpus** (T103): diagrams, TikZ output, mathematical plots,
   Bayesian/statistics figures, from the web (openly licensed) and generated
   locally; Rowan reviews ours vs Chromium side by side.
3. **Lock it:** once those look good, record our current output for the whole
   corpus (resvg suite, local tests, real-world corpus) and require
   byte-identical output from then on, alongside all theorems.
4. **Optimise:** speed work under that lock; every change must keep the
   bytes identical and the theorems passing.
5. **Speed baseline at the lock (Rowan, 2026-09-24):** when the bytes are
   frozen, also record the three-way timing on the whole real-world corpus
   at 1000 px: lean-svg, resvg and Chromium (scratchpad `bench.py`: CLI wall
   time for lean-svg and resvg, warm-browser decode + raster for Chromium).
   Commit the numbers next to the manifest; the speed phase measures against
   them. Known at T119: `23_dashes` about 25% slower since T107's
   tangent-aligned dash ends.
6. **A proved-equivalent Rust renderer (Rowan, 2026-09-24; future, large):**
   after the lock, rewrite the inner rendering function in safe Rust, extract
   it to Lean with [Aeneas](https://github.com/AeneasVerif/aeneas), and
   prove the extracted Rust equal to the Lean renderer. The Rust version
   then carries the same guarantees (totality, the size and effect theorems,
   byte-identical output), and optimisation can continue entirely in safe
   Rust, each step re-proved equivalent.
   - Work piecemeal by **SVG subset**: define a fragment of the language
     (first, paths with solid fills and strokes; then transforms, gradients,
     clipping, masks, filters, text…) as a predicate on the parsed document,
     prove equivalence for documents in that fragment, and grow it feature
     by feature.
   - The hard part is the fragment definition itself: a precise,
     checkable statement of which features a proof covers, so each proof
     is partial but exact.
   - The frozen byte manifest doubles as a cross-check: the Rust build must
     pass `freeze.py check` too.

## Possible tool: FloatLib (Rowan, 2026-09-24; no changes made)

https://github.com/lean-dojo/FloatLib — proved IEEE binary32/64 in software
(Lean 4.34.0, requires Mathlib). Assessment: not a speed win (proved binary64
is ~140–330 ns/op vs ~1 ns for our integer ops; the fast host-FPU path is
explicitly unchecked, the same trust as `Float`, and risks byte-identical
output across platforms). Possible later uses: bit-exact emulation of
resvg's f32 arithmetic on specific paths (AA coverage, curve flattening) to
close "edge smoothing only" differences; real-number error-bound theorems.
Both would add Mathlib as a dependency.

## T102 merged (2026-09-24)

Six files stop matching resvg, all intended: the three invalid-transform
files (draw nothing, like Chromium), `rtl-with-vertical-writing-mode` and
`textPath/complex` (Chromium's placement), and `textPath/writing-mode=tb`,
where live resvg 0.48.1 draws nothing but the suite PNG shows the text along
the path with upright CJK, which is now what we draw (the suite's resvg=1
rating predates 0.48.1's behaviour).

## XML nesting depth (Rowan, 2026-09-24)

`tikz/plot_pgf_3d_surface.svg` nests 1,164 `<g>` deep (pgfplots leaves each
patch's group open), past our 64-level parser cap, so it is refused (resvg
also refuses: "nodes limit reached"). Decision: allow nesting up to ~2,000–2,500
levels if it stays fast and costs nothing when unused; deep processing must
not recurse on the native stack (iterative or fuel-bounded), and the size and
time theorems must keep holding.
- Also to revisit: the filter work budget refuses PlantUML's drop shadow
  (300% filter region) on tall diagrams rendered at 1000 px wide
  (1000 × 5,500 px); they render at 600 px. Chromium has no such cap.

## Font licensing rule (Rowan, 2026-09-24)

Only highly open, well-permissioned fonts may be bundled (SIL OFL 1.1 or
equally permissive, e.g. the Bitstream Vera / DejaVu licence). A font merges
only when: its licence is verified against the upstream project, the full
licence text is in `LeanSvg/Fonts/`, `NOTICE` credits it, and the README
"Licensing and credits" table lists it with version, copyright and licence.
Fonts embedded in an input SVG (T105) are used only to render that file and
are never redistributed by lean-svg; the README says so.

## Byte freeze (T117, 2026-09-24; tooling only, nothing frozen yet)

`tests/freeze.py` implements phase 3 ("Lock it") above. `record OUT.json`
renders the resvg suite at 100 and 200 px, `tests/svg/*.svg` at native size,
and the real-world corpus at 1000 px (all files since T115), storing per file and width the exit code,
SHA-256 of the PNG and, with `--warnings`, SHA-256 of the warnings file.
`check OUT.json` re-renders with the manifest's settings and lists every
difference; it exits 1 on any. Order is sorted and `--jobs` does not change
the result.

How it will be used: when Rowan declares correctness done, record one
manifest with `--warnings` from that commit and commit it (e.g.
`tests/freeze.json`). From then on every change (speed work above all) must
pass `freeze.py check` with zero differences, alongside the theorems. A
deliberate output change is a separate, reviewed commit that re-records the
manifest and says which files changed and why. No manifest is committed yet:
the bytes still change.
