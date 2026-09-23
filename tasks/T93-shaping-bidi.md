# T93 — Arabic, Hebrew and Devanagari: bidi and shaping  (branch `claude/feat-shaping`)

Rowan wants these scripts to render correctly. T91 (read its report in
`tasks/T91-fonts.md`) embedded fonts for many scripts but stopped at these
three because they need:

1. **Bidi (RTL)** for Arabic and Hebrew: a bounded, total implementation of
   the Unicode Bidirectional Algorithm subset that SVG text needs (UAX #9:
   resolve levels per paragraph = per text chunk, the `direction` and
   `unicode-bidi` properties, mirroring of paired brackets). Match usvg/
   rustybuzz behaviour where resvg renders these correctly, else Chromium.
   Also covers `text/direction/rtl.svg` and `text/unicode-bidi/*`.
2. **Arabic shaping:** joining forms (isolated/initial/medial/final) and
   the mandatory lam-alef ligatures, driven by the font's `GSUB` (`init`,
   `medi`, `fina`, `isol`, `rlig`) with the Unicode joining-type table.
   Mark positioning via `GPOS` mark-to-base if the font needs it.
3. **Devanagari (Indic) shaping:** the minimum for recognisably correct
   text: pre-base matra reordering (e.g. `ि`), reph, conjuncts/half forms via
   the font's `GSUB` (`akhn`, `rphf`, `half`, `pres`, `abvs`, `blws`, `psts`).
   Follow HarfBuzz's Indic shaper behaviour; a subset is fine, document it.

Fonts: Noto Sans Arabic (or Amiri from the suite), Noto Sans Hebrew, Noto
Sans Devanagari: OFL only, `glyf` builds, added the same way T91 added fonts
(`tests/gen_font_module.py`, `LeanSvg/Fonts/README.md`, `NOTICE`, licences).

**Ownership, to keep merges clean** (another agent, T94, is changing how
fonts are embedded and loaded concurrently): put your code in new modules,
`LeanSvg/Bidi.lean`, `LeanSvg/Shape.lean` (GSUB/GPOS lookups beyond the
existing pair kerning) and small hooks in `Text.lean`/`Font.lean`. Do not
change `LeanSvg/Fonts/*` embedding or `Font.base64Decode`; add your font
modules with the existing generator exactly as T91 did.

Everything total and bounded (lookup recursion depth, glyph-sequence growth
cap per run, fuzz the new GSUB/GPOS parsing like `tests/fuzz_font.py`).
Measure: the resvg suite's text directories plus new `tests/svg/93_*.svg`
files for each script, against resvg where resvg is rated correct, else
Chromium. If a piece turns out to be very large, finish the others, push,
and write up what remains and why.

---

## Common rules (every lean-svg agent)


**Branches (Rowan's rule).** Push only to the one branch this task names.
The integrator merges it into `claude/beautiful-brown-nd2o1h` and then
deletes it, so do not create any other branch, tag or pull request. You may
use subagents inside your own session; they must not push anywhere.

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

## Report

### What was implemented

All three parts, plus `direction`/`unicode-bidi` and `lengthAdjust="spacingAndGlyphs"`.

**Fonts.** They were added with `tests/gen_font_module.py` as T91 did. The generator has a new `--layout-features` option (default `kern`, as before). The three shaped fonts keep every GSUB, GPOS and GDEF feature.
- **Amiri 000.109**: the resvg test suite's copy (535,420 bytes). It is the suite's only Arabic font, so the resvg references use it.
- **Noto Sans Devanagari 2.003**: the suite's copy (190,080 bytes).
- **Noto Sans Hebrew 3.001**: from google/fonts, instanced at wght=400, wdth=100 (46,560 bytes). The suite has no Hebrew font.

All are SIL OFL 1.1 with no Reserved Font Name. They are recorded in `LeanSvg/Fonts/README.md`, `NOTICE`, `README.md` and the `LICENSE-OFL*` files, and appended to the `FontSet` fallback order. Embedded font data went from 19.07 MB to 19.84 MB, and the `lean-svg` binary from 36.8 MB to 39.2 MB. `tests/check_font.py --all --via-embedded` and `--metrics` found 0 mismatches on all three.

**`LeanSvg/Shape.lean`: the OpenType engine.** This is a port of harfrust 0.12.0, the HarfBuzz port that resvg 0.48.1 links.
- **Feature map:** features, stages and pauses, dedup, masks, and the required feature.
- **GDEF:** glyph classes, mark attachment classes and mark filtering sets.
- **Skipping iterator:** lookup flags, and auto-ZWJ/ZWNJ handling.
- **Ligature component bookkeeping:** `match_input` and `ligate_input`.
- **Buffer operations:** `merge_clusters`, `delete_glyph`, `move_to`, and nested `apply_lookup` with match-position fix-up.
- **GSUB, every lookup type:** 1 single, 2 multiple, 3 alternate (the first alternate), 4 ligature, 5/6 context and chained context (all three formats), 7 extension, 8 reverse chaining.
- **GPOS, every lookup type:** 1 single, 2 pair (formats 1 and 2), 3 cursive (with harfrust's chain reversal), 4 mark-to-base (with harfrust's `accept` rule), 5 mark-to-ligature, 6 mark-to-mark, 7/8 context, 9 extension.

**`LeanSvg/ShapeRun.lean`: shaping one run.** This follows the harfrust pipeline.
- **Unicode setup:** Unicode properties, grapheme clusters, and `ensure_native_direction` (harfrust's rule: a run with no script has no native direction, unlike HarfBuzz C).
- **Normalisation:** mirroring in RTL runs, then `_hb_ot_shape_normalize` (decompose; reorder by modified combining class, with the Arabic modifier-mark and Hebrew reorderings; recompose).
- **Default shaper.**
- **Arabic shaper:** the joining state machine over harfrust's joining-type table; `isol`/`fina`/`fin2`/`fin3`/`medi`/`med2`/`init` each in its own stage; `rlig`; `calt`; the `rclt` pause rule.
- **Hebrew shaper:** GPOS only under `hebr`; its compose and mark rules.
- **Indic shaper (Devanagari configuration):**
  - the `indic_syllable_machine` grammar, run as longest-match regular expressions;
  - vowel-constraint and broken-cluster dotted circles;
  - consonant positions from `would_substitute` over `blwf`/`vatu`/`pstf`/`pref`;
  - initial reordering: reph, base consonant, stable position sort, pre-base matras, cluster merging, feature masks, ZWNJ;
  - the eleven basic-feature stages;
  - final reordering: pre-base matra after the last halant, reph before post-base forms;
  - `liga` disabled.
- **Positioning:** GPOS, zero-width marks, attachment offsets, the final RTL reversal, and default ignorables replaced by the space glyph.

**`LeanSvg/ShapeData.lean`.** These are harfrust's own tables, dumped from the cargo-registry sources by `tests/gen_shape_data.py`: general category, modified combining class, script, Arabic joining type, Indic category and position, and decompositions/compositions.

**`LeanSvg/Bidi.lean`.** A pure port of unicode-bidi 0.3.18, the crate usvg uses. It covers X1–X10, W1–W7, N0 bracket pairs, N1–N2, I1–I2, L1 and L2, including the crate's deviations from the letter of UAX #9. The mirror table comes from harfrust. Tables are generated by `tests/gen_bidi_tables.py`.

**`LeanSvg/ShapeText.lean` and the hooks in `Text.lean`.**
- **What goes to the shaper:** a chunk that contains strongly right-to-left characters or bidi controls, or that uses one of the three shaped fonts, is shaped as usvg's `process_chunk` does:
  - the chunk is one bidi paragraph, and each visual run is shaped in its own direction;
  - per span, `shape_text`'s font fallback is reproduced exactly: replace all glyphs, fill the `.notdef`s, or stop when the glyph count differs;
  - later spans overwrite glyphs with usvg's UTF-8 byte-length cluster bookkeeping, which gives `ligatures-handling-in-mixed-fonts-*`;
  - clusters are built with `form_glyph_clusters`.
- **What stays on the old path:** every other chunk keeps the one-glyph-per-character layout. This is why all Latin, CJK and other text is byte-identical to before.
- **Changes in `Text.lean`:**
  - `Cluster` gains `off` (so `x`/`dx`/`rotate` are read at the cluster's first character) and `glyphs` (per-glyph font and offset, drawn by `clusterCmds` in both the linear and `textPath` branches);
  - `letter-spacing` skips cursive scripts (`script_supports_letter_spacing`).

**Where resvg is known wrong, Chromium is followed (horizontal text only).**
- `direction="rtl"` makes the paragraph level 1 and makes `text-anchor` start/end name the right/left edge.
- `unicode-bidi="bidi-override"` (or `isolate-override`) on the element lays the chunk out as one run in that direction, split by script as Chromium itemises it.
- `Svg.lean` parses `direction` (inherited) and `unicode-bidi` (per element).
- Vertical text keeps usvg's behaviour of ignoring both (w3c/svgwg#618).

**`lengthAdjust="spacingAndGlyphs"`.** This now does what usvg does: each cluster, pen position and outline, is scaled along the chunk's x axis by `target / natural width`, with the scale outside the glyph's own rotation. Before, it was approximated by redistributing spacing. The approximation had made `textLength/arabic-with-lengthAdjust.svg` worse, and replacing it also fixed the four `text/lengthAdjust` files.

### Bounds (all fixed and total)
- Nested lookups: fuel `maxNesting` = 16 (harfrust allows 64).
- Context matching length: 64.
- Glyph-sequence growth cap per run: `16 n + 256` glyphs.
- Operation budget: `4096 n + 65536` per shaping call.
- Every buffer pass is a `for` over a fixed range.
- Attachment propagation, decomposition and the Indic regular expressions all use fuel or input-bounded loops.
- Bidi: embedding stack 125, bracket stack 63.

### Checks
- **Shaping vs HarfBuzz:** `tests/check_shape.py` compares `shapedump` with uharfbuzz (HarfBuzz C) on the exact embedded font bytes, checking glyph id, cluster, advance and offsets. Result: 19,816/19,816 runs identical across Amiri, Noto Sans Hebrew and Noto Sans Devanagari (hand-written words plus 20,000 random strings per seed). The 262 skipped runs are runs with no script in RTL, where harfrust (resvg) and HarfBuzz C disagree by design.
- **Bidi vs unicode-bidi:** `tests/check_bidi.py` compares with python-bidi 0.6.11, which bundles unicode-bidi 0.3.18. Result: 0 mismatches — classes over all 1,112,064 codepoints, paragraph levels and visual order over about 325,000 cases.
- **Fuzzing:**
  - `tests/fuzz_shape.py` mutates GSUB/GPOS/GDEF (byte flips, extreme u16 values, lookup types and counts, nested lookup records pointed at arbitrary lookups, truncation): 1,000 mutants per font with seed 93, 0 violations (no timeout, crash, or growth past the cap).
  - `tests/fuzz_font.py` on the three new fonts: 300 each, 0 violations.
- **Hebrew by hand:** Hebrew cannot be in `tests/svg`, because the resvg oracle has no Hebrew font. With Noto Sans Hebrew added to resvg's font directory, a Hebrew test page scored 99.80% within-8 against resvg.
- **Speed:** shaped test files render in 20–50 ms.

### Verification (all on the final code)
- `lake build`: no errors, no warnings. `bash scripts/check-theorems.sh`: `invariants ok`, `theorems ok`.
- `python3 tests/run_tests.py`: 58/62 pass. That is the same 4 old failures, and no existing file's score changed. The new `93_arabic` passes at 99.76% and `93_devanagari` at 99.91%.
- `python3 tests/run_adversarial.py`: 138/138 clean. `python3 tests/run_tiles.py`: 62/62 byte-identical.

**Corpus (resvg suite, direct route):**

| | 100 px pass | 200 px pass | `text/*` at 200 px |
|---|---:|---:|---:|
| before | 1558 / 1679 | 1583 / 1679 | 309 / 356 |
| after | 1576 / 1679 | 1600 / 1679 | 326 / 356 |

By resvg's rating in the suite's `results.csv`, at 200 px:
- "resvg correct" files: 1442 → 1459.
- "resvg known wrong" files: 83 → 82.

**Newly passing at 200 px (18):**
- Arabic and bidi: `text/bidi-reordering`, `tspan/bidi-reordering`, `x-and-y-with-multiple-values-and-arabic-text`, `rotate-on-Arabic`, `fill-rule=evenodd`.
- Font mixing: `ligatures-handling-in-mixed-fonts-1` and `-2`.
- Spacing, kerning and anchoring: `font-kerning/arabic-script`, `letter-spacing/on-Arabic`, `letter-spacing/mixed-scripts`, `text-anchor/on-tspan-with-arabic`.
- Text length: `textLength/arabic`, `textLength/arabic-with-lengthAdjust`, `lengthAdjust/spacingAndGlyphs`, `lengthAdjust/vertical`, `lengthAdjust/with-underline`, `lengthAdjust/text-on-path`.
- Vertical: `writing-mode/arabic-with-rl`.

At 100 px, `dominant-baseline/hanging` and `use-script` (Devanagari, previously blank) also go from fail to pass. At 200 px they were already passing: they were blank, but a small glyph is only a small share of the canvas (the metric blind spot noted in R8).

**One pass→fail, intended:** `text/direction/rtl.svg`, 99.53% → 98.58% against resvg. Its `results.csv` rates resvg as failing this file (chrome=1, resvg=2; see `docs/resvg-wrong/R5-text-props.md` §2). resvg ignores `direction`, and its reference shows two glyphs at the right edge. We now lay the sentence out right to left the way Chromium and the suite reference do. Against `--ref chrome` it scores 97.6% and against `--ref suite` 98.0%; Chromium draws with its own Noto Sans Arabic rather than Amiri, and that is the remaining difference. This is a deliberate exception to the "zero pass→fail" rule, as the task asks for Chromium where resvg is wrong. **For the integrator:** if the rule must hold, the only change needed is to drop the `rtlPara` anchor swap and paragraph level in `Text.lean`.

`unicode-bidi/bidi-override.svg` stays a failure against resvg (98.61% → 97.89%, as it now matches Chromium's reversal instead of resvg's implicit bidi). Against Chromium it scores 97.4%, again limited by the font.

### Not done, and why
- **`writing-mode/mixed-languages-with-tb*` and `tb-with-rotate*`** still fail. They need upright CJK glyphs in vertical text (`unicode_vo`, the `Upright` branch in `Text.lean`), which is outside this task. Their Arabic part is now drawn.
- **Fallback positioning for fonts without GPOS** (harfrust's `ot_shape_fallback`): mark positioning from glyph extents, and fallback kerning. It matters only when a shaped chunk falls back to a font without GPOS for combining marks. Example: Hebrew with niqqud in a Noto Sans chunk falls back to Mplus 1p, which covers Hebrew, before Noto Sans Hebrew — resvg does the same — and the marks differ slightly.
- **Not implemented (none of the embedded fonts need them):** Arabic `stch`, the fraction features (`frac`/`numr`/`dnom`, used only around U+2044), `rand`, `FeatureVariations`, device/variation deltas, anchor contour points, the Indic `pref` reordering and old-spec (`deva`) halant moves, the Universal Shaping Engine, and emoji ZWJ sequences as one grapheme.
- **`direction` on a `tspan`, and tspan-level `unicode-bidi` embeddings** are not modelled. The chunk's first character decides the paragraph direction and override. The suite only tests `<text>`-level cases.
- **Name table:** the Noto Sans Hebrew instance's name table still says "Thin" (the instancer does not rename without STAT). `FontSet` registers it as "Noto Sans Hebrew", so rendering is unaffected.

### Files
- **New:** `LeanSvg/{Shape,ShapeRun,ShapeText,ShapeData,Bidi}.lean`, `LeanSvg/Fonts/{Amiri,NotoSansHebrew,NotoSansDevanagari}.lean`, `LeanSvg/Fonts/LICENSE-OFL-Amiri.txt`, `LeanSvg/LICENSE-{harfrust,unicode-bidi}.txt`, `ShapeDump.lean` (the `shapedump` oracle executable in `lakefile.toml`), `tests/{gen_shape_data,gen_bidi_tables,check_shape,check_bidi,fuzz_shape}.py`, `tests/svg/93_{arabic,devanagari}.svg`.
- **Changed:** `LeanSvg/Text.lean` (the shaping hook, `Cluster.off`/`glyphs`/`sx`, `clusterCmds`, RTL anchor, spacingAndGlyphs, cursive letter-spacing), `LeanSvg/Svg.lean` (`direction`, `unicode-bidi`), `LeanSvg/FontSet.lean` (three entries appended), `tests/gen_font_module.py` (`--layout-features`), `LeanSvg/Fonts/README.md`, `LeanSvg/Fonts/LICENSE-OFL-NotoScripts.txt`, `NOTICE`, `README.md`, `ROADMAP.md`.
