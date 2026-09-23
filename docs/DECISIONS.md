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
