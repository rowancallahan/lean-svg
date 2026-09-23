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
