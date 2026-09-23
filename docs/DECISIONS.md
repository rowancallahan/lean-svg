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

## The road to shipping (Rowan, 2026-09-23)

After items 1–3 above, in this order:

4. **Review pass.** Quick full run; Rowan looks at every file that is not
   close (a click-through gallery: reference | ours | diff) and marks each
   acceptable or not.
5. **Compressed PNG output.** Real DEFLATE instead of stored blocks. Keep
   the size bound (`proofs/SizeBound.lean`) true: a conforming encoder falls
   back to stored blocks, so the upper bound survives. Prefer a pure
   in-repo encoder, or lean-zip at proof time only (ROADMAP §4), so the
   shipped binary stays dependency- and FFI-free.
6. **Lock down behaviour.** Accept the current outputs as golden images
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
