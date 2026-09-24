# T106 — More bundled fonts for common families; non-font chart bugs  (branch `claude/feat-more-fonts`)

Rowan's chart review (`tests/realworld_verdicts.csv`, notes): many charts ask
for fonts we do not embed, so we fall back to Noto Sans where Chromium uses
the real family: matplotlib (`DejaVu Sans`, mathtext), Graphviz (`Times`,
`Courier,monospace`), Vega, PlantUML, Mermaid. Rowan: add more fonts, math
fonts included, **permissively licensed only, keep size down** (total binary
budget 75 MB; today ~40 MB).

1. Add, via `tests/gen_font_module.py` (subset sensibly, T94 layout):
   - **Liberation Sans / Serif / Mono** (OFL, metric-compatible with
     Arial/Helvetica, Times/Times New Roman, Courier/Courier New);
   - **DejaVu Sans, DejaVu Sans Mono, DejaVu Serif** (Bitstream Vera licence,
     permissive; matplotlib's default and its mathtext `dejavusans` set);
   - a maths font: **STIX Two Math/Text** (OFL) and/or **CMU Serif/Sans/
     Typewriter** (Computer Modern Unicode, OFL) for Computer Modern / cm /
     stix requests.
   Record licences in `LeanSvg/Fonts/README.md` and `NOTICE`; list sizes.
   Rowan approves permissive licences; anything not clearly permissive: skip
   and list it.
2. Family matching like Chromium on Linux: exact family names first
   (case-insensitive, quoted lists), then aliases (Times/Times New Roman →
   Liberation Serif, Arial/Helvetica → Liberation Sans, Courier → Liberation
   Mono, DejaVu names → DejaVu), then generic `serif`/`sans-serif`/
   `monospace`/`cursive`/`fantasy` → Chromium's Linux defaults as far as we
   have them, then Noto Sans with a warning (T98). Symbol/maths fallback chain
   for codepoints missing from the chosen face (so no tofu when any bundled
   font has the glyph).
3. Non-font bugs Rowan flagged: `matplotlib-text/beta_binomial_update.svg`
   ("major issue with showing the prior here, must be fixed");
   `mpl-tests/test_mathtext/mathtext0_cm_03.svg` stray hyphen; anything else
   the triage file marks `real-bug` that is not font-related.

T105 (fonts embedded in the SVG) runs at the same time and touches font
selection too: keep the family-matching change in one clearly separated
function so the merge is easy. Measure the realworld corpus vs Chromium per
group before/after, and the resvg suite gate (resvg-correct must not drop
except files whose resvg reference used a font we now match better: list
them with Chromium/suite scores).

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

- **Fonts** (18 faces, 2,984,360 bytes of font data, 4,013,387 bytes of Lean
  source; binary 45.8 MB, budget 75 MB). Generated with
  `tests/gen_font_module.py --no-glyph-names` (T94 layout, hinting dropped,
  `kern` only); sizes, ranges, sources and licences in
  `LeanSvg/Fonts/README.md`, credits in `NOTICE`, licence texts in
  `LeanSvg/Fonts/LICENSE-{DejaVu,OFL-Croscore,OFL-STIXTwo,OFL-CMU}.txt`.
  - DejaVu Sans (Book, Bold, Oblique), Sans Mono, Serif 2.37 (Bitstream Vera
    / Arev licence, permissive). DejaVu Sans keeps symbols, arrows, maths
    operators and U+1D400-1D7FF (it is the first fallback).
  - **Arimo (400, 700), Tinos (Regular, Bold, Italic), Cousine** (OFL) in
    place of Liberation Sans/Serif/Mono: every Liberation download (GitHub
    release assets, `github.com/.../files`, releases.pagure.org) got 403 from
    this session's network policy. Liberation 2.x is built from these Chrome
    OS core fonts, with the same metrics. The names `Liberation Sans/Serif/
    Mono` are aliases to them.
  - STIX Two Math 2.12 (maths blocks) and STIX Two Text 2.13 Regular/Italic
    (OFL, from google/fonts).
  - CMU Serif Roman/Italic, CMU Sans Serif, CMU Typewriter Text 0.7.0 (OFL,
    SourceForge; CTAN got 403).
  - `tests/check_font.py <subset> --all --via-embedded <Module>`: 0 mismatches
    (glyph ids, advances, contours, kerning) for all 18.
- **Family matching**, `LeanSvg/FamilyMatch.lean` (one separate module, for
  the T105 merge; `Svg.resolveFontFamily` now calls `FamilyMatch.lookup` per
  list name, keeping its suite-only-family and digit rules). Per name, in
  list order: exact embedded family (case-insensitive), alias (Times/Times
  New Roman/Liberation Serif → Tinos; Arial/Helvetica/Liberation Sans →
  Arimo; Courier/Courier New/Liberation Mono → Cousine; Bitstream Vera and
  `DejaVu Sans Display` → DejaVu; STIX/STIXGeneral → STIX Two Text;
  STIXSize*/STIXNonUnicode/msam/msbm → STIX Two Math; `cmr*`/`cmsy*`/
  `cmex*`/`cmbx*` → CMU Serif, `cmmi*`/`cmti*` → CMU Serif Italic (face
  locked), `cmss*` → CMU Sans Serif, `cmtt*` → CMU Typewriter, "Computer
  Modern …"/"Latin Modern …" likewise), then unquoted generics as this
  container's Chromium resolves them (measured with a probe page):
  `serif`/`cursive`/`fantasy` → Tinos, `sans-serif` → Arimo, `monospace` →
  DejaVu Sans Mono, `system-ui` → DejaVu Sans. Nothing matched → Noto Sans
  with the T98 warning (unchanged). Chromium would use its standard font
  (Liberation Serif) there; kept as the task says.
  - `FamilyMatch.pick`: face by slant first, then `matchWeight` (fontdb's
    rule). Nothing synthesised: Times bold italic draws Tinos Italic.
  - Fallback: a T106 base font tries DejaVu Sans, then STIX Two Math, then
    `FontSet` order, per character (Chromium), not usvg's whole-chunk
    replacement. Suite fonts (index < 16) keep usvg's order and rule, so the
    resvg suite's fallback is unchanged. A character no font maps draws Noto
    Sans's `.notdef` (CMU's crossed box looked worse on dvisvgm PUA codes).
- **Non-font bugs**
  - `mpl-tests/test_mathtext/mathtext0_cm_03.svg` stray hyphen: matplotlib
    writes TeX-encoded `cmex10` code points, one of them U+00AD (soft
    hyphen). The unshaped layout drew its glyph. It now hides every
    default-ignorable character (`Shape.isDefaultIgnorable`: U+00AD, ZW*,
    U+2060…) as HarfBuzz does: space glyph, zero advance. Chromium draws
    nothing there either; the hyphen is gone.
  - `matplotlib-text/beta_binomial_update.svg`: the prior curve and legend
    already matched Chromium at baseline. The visible difference was the
    y label `p(θ ∣ y)`: Noto Sans lacks U+2223, so the fallback glyph's
    bearings pushed `∣` next to `y`. With DejaVu Sans (the file's family) it
    matches Chromium (+1.25 points within-8).
  - Triage `real-bug` entries marked fixed by T104, re-checked against
    Chromium at 500 px: `tikz/plot_pgf_3d_surface` (and `tikz-fonts/`)
    renders the full surface; `web-tikz/materials-informatics` shows every
    Coulomb-matrix cell and number; `mermaid/er_schema` and
    `mermaid/state_chain` show all labels. All match Chromium; nothing left
    to fix. `tikz-fonts/matrix_block` and `tikz-fonts/plot_pgf_posterior`
    (space is present now) depend on the file's own `@font-face` fonts: T105.
- Tests: `tests/svg/106_soft_hyphen.svg`, `tests/svg/106_font_families.svg`;
  `tests/check_warnings.py` now expects generics/aliases to match without a
  warning and an unknown family (`Foo`) to warn.

## Skipped (and why)

- Liberation itself (network 403, Arimo/Tinos/Cousine used instead).
- matplotlib's BaKoMa `cmr10.ttf`/`cmex10.ttf`: their licence forbids
  modification, and subsetting is modification. Not clearly permissive.
- Microsoft core fonts (Arial, Times New Roman, Verdana, Trebuchet MS,
  Georgia): not freely redistributable.
- For size: DejaVu Sans Bold Oblique, DejaVu Serif Bold/Italic, DejaVu Sans
  Mono Bold, Cousine Bold, Tinos Bold Italic and the other CMU faces. The
  nearest embedded face is drawn.
- No synthetic bold/oblique (Chromium synthesises them; resvg does not).
- The unmatched-list default stays Noto Sans (task rule); Chromium uses
  Liberation Serif there.
- TeX-encoded `cmex10`/`cmsy10` code points (matplotlib) and dvisvgm PUA
  codes only draw correctly with the real TeX fonts (T105). CMU draws the
  Latin-1 character, as Chromium does with its default font.

## Report

Commands as in the common rules (baseline at `b427351`, after at the head
of `claude/feat-more-fonts`).

**resvg suite gate** (`run_corpora.py --corpus resvg --route direct`):

| width | pass before | pass after | pass→fail | changed files |
|---|---:|---:|---:|---|
| 100 (`--fast`) | 1543 / 1679 | 1543 / 1679 | 0 | the 6 below |
| 200 | 1567 / 1679 | 1567 / 1679 | 0 | the 5 below (sans-serif.svg moves < 0.1) |

Only `text/font-family/*` generic-family files change. They fail before and
after: the local resvg reference has no font for the generic (`No match for
'serif' font-family`) and draws no text. Scores at 200 px (within-8,
composited on white):

| file | vs resvg before | after | vs Chromium before | after |
|---|---:|---:|---:|---:|
| text/font-family/sans-serif.svg | 97.93% | 97.91% | 97.82% | 98.88% |
| text/font-family/bold-sans-serif.svg | 96.97% | 97.30% | 97.80% | 98.94% |
| text/font-family/serif.svg | 97.93% | 98.36% | 97.63% | 98.98% |
| text/font-family/monospace.svg | 97.93% | 97.82% | 97.01% | 99.15% |
| text/font-family/cursive.svg | 97.93% | 98.36% | 97.63% | 98.98% |
| text/font-family/fantasy.svg | 97.93% | 98.36% | 97.63% | 98.98% |

**Realworld vs Chromium** (`run_corpora.py --corpus realworld --route
direct`, 200 px, pass = 99% within 8):

| group | files | pass before | pass after | mean within-8 before | after | mean abs diff before | after |
|---|---:|---:|---:|---:|---:|---:|---:|
| graphviz | 23 | 0 | 0 | 90.19% | 90.96% | 4.451 | 3.378 |
| matplotlib | 66 | 0 | 0 | 89.95% | 89.95% | 3.149 | 3.149 |
| matplotlib-text | 19 | 0 | 0 | 87.65% | 87.84% | 4.472 | 4.206 |
| mermaid | 8 | 0 | 0 | 81.63% | 81.92% | 2.346 | 1.967 |
| mpl-tests | 515 | 259 | 260 | 97.33% | 97.33% | 0.655 | 0.655 |
| plantuml | 8 | 0 | 0 | 91.84% | 92.52% | 2.570 | 1.813 |
| tikz | 64 | 0 | 0 | 92.74% | 92.74% | 2.005 | 2.005 |
| tikz-fonts | 64 | 0 | 0 | 92.08% | 92.43% | 2.384 | 2.150 |
| web-tikz | 50 | 0 | 0 | 88.32% | 88.32% | 2.362 | 2.362 |
| web-vega | 31 | 0 | 0 | 92.93% | 93.25% | 3.475 | 3.051 |
| **all** | 848 | 259 | 260 | 94.71% | 94.78% | 1.508 | 1.429 |

Largest gains: graphviz/dot_html_table +4.12, dot_class_hierarchy +2.14,
dot_flowchart +1.97, tikz-fonts/automaton_pushdown +1.35,
matplotlib-text/beta_binomial_update +1.25. Largest drops:
`mpl-tests/test_mathtext/mathtext0_cm_0{1,2,3,4}` −0.59…−0.86. That is
intended: Rowan asked for Computer Modern on `cm` requests, while this
Chromium has no CM font and draws them in Liberation Serif. Nothing else
drops by more than 0.23. Many 200 px text files still fail the 99% threshold
on anti-aliasing alone, so the pass count barely moves; the mean
difference falls in every group that has text.

Pinning `sans-serif` to Noto Sans (T98b) instead of Arimo was measured:
web-vega 92.93%, plantuml 91.96%, bold-sans-serif.svg worse vs resvg.
Chromium's Arimo was kept.

**Other gates**: `lake build` clean, no warnings; `check-theorems.sh`:
`invariants ok`, `theorems ok`; `run_tests.py`: 62/79, no existing file's
exact/within/within32 drops (new: `106_font_families` 90.8% vs resvg,
which lacks these families; `106_soft_hyphen` 98.5%, the same text
anti-aliasing gap as the plain word, the soft-hyphen line identical to it);
`run_adversarial.py` 159/159 clean; `run_tiles.py` 79/79 byte-identical;
`check_warnings.py` ok.

**For the T105 merge**: font selection changes are in `FamilyMatch.lean`
(new), the call in `Svg.resolveFontFamily`, `Text.baseFont` (one branch),
and `Text.assignFonts` (order, per-character rule, `.notdef` font). The
T106 fonts are appended at `FontSet` indices 16–33, and `FontSet.styles`
must grow with `entries` (checked by an `example` in `FamilyMatch.lean`).
@font-face families from T105 should be tried before `FamilyMatch.lookup`.
