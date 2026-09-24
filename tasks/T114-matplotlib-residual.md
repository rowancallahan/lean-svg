# T114 — matplotlib / mathtext residual bugs vs Chromium  (branch `claude/fix-mpl-residual`)

After T106 (DejaVu, STIX Two, CMU bundled), survey the 30 lowest-scoring
files vs Chromium in `tests/corpora/realworld/{matplotlib,matplotlib-text,mpl-tests}`
at 1000 px (white-composited, side by side), ignoring pure anti-aliasing.
Rowan's notes to re-check: `matplotlib-text/streamplot_field` ("fonts need to
be fixed to fancy math"), `mpl-tests/test_mathtext/mathtext0_dejavusans_05`
(needs more math glyphs), `matplotlib-text/mathtext_showcase`. Also note:
matplotlib names `cmr10`/`cmex10` etc.; Chromium here has no Computer Modern,
so for those it substitutes; we now draw CMU, which is what the author meant
(this is intended; do not "fix" it toward Chromium).
Fix clear bugs of ours (missing glyphs we have in a bundled font but fail to
reach, wrong fallback, placement); report the rest with cause. If a glyph
set needs another font, name font, licence and size; do not add it.

---

## Round 7 rules (read with the common rules below)

- **Short task, hard timebox: about 2 hours of work.** Fix what is clearly
  ours and bounded; for anything bigger, write down the cause, the fix you
  would make and its size in the report, push, and end. Do not start
  rewrites.
- **No speed work.** Do not optimise or restructure hot paths; Rowan will
  run the speed phase later. A fix must not slow the suite down noticeably
  (`scratchpad`-style timing: `run_corpora.py` wall time within ~5%).
- **Pass criteria** (`tests/criteria.csv`, `docs/DECISIONS.md`): a file's
  reference is resvg where resvg is correct, Chromium where resvg is wrong
  and Chromium is right, otherwise Rowan's verdict. Do not change
  `criteria.csv` or `realworld_verdicts.csv`; if you believe a file's
  reference is wrong, say so in the report with evidence.
- **Behaviour that must not change:** one input file read; at most the PNG
  and (with `--warnings`) `<out>.warnings.txt` written, no-clobber; nothing
  on stdout/stderr; exit codes as in `docs/DECISIONS.md`; no external
  resource ever loaded. `tests/run_adversarial.py` must stay all clean.
- **Real-world corpus vs Chromium:**
  `python3 tests/run_corpora.py --corpus realworld --ref chrome --out /tmp/rw --no-worst`
  (Chromium is preinstalled; `tests/render_chrome.py` renders references).
  When you look at our PNGs, composite them on white first: they are
  transparent, and an image viewer shows transparency as black.
- Fonts: only permissively licensed fonts (OFL, Apache, Bitstream Vera or
  equally permissive), verified upstream, licence text in `LeanSvg/Fonts/`,
  credits in `NOTICE` and README "Licensing and credits". Keep the binary
  under 75 MB (now ~46 MB).

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

## Report

Survey: `run_corpora.py --corpus realworld --ref chrome --width 1000`, the 45
lowest within-8 files of `matplotlib`, `matplotlib-text` and `mpl-tests`,
composited on white next to Chromium. Two bugs of ours fixed; the rest are
listed below with their causes.

### Fixed

1. **A combining mark that starts its own positioned `<tspan>` was drawn on
   the previous character** (`LeanSvg/Text.lean`). matplotlib writes mathtext
   accents as `<tspan x=".." y="..">&#x302;</tspan>` (the hat of β̂ in
   `matplotlib-text/mathtext_showcase`). T102's per-grapheme rule cleared a
   nonspacing mark's own `x`/`y`/`dx`/`dy`, so the hat joined the preceding
   `,`. usvg starts a new chunk at any character with an absolute
   coordinate (`collect_text_chunks`), and Chromium places the mark there
   too. Now the rule is skipped when the mark is the first character of an
   element that sets its own positions. `complex-graphemes-and-coordinates-list.svg`
   (T102's case: the mark's `y` comes from a list inside one text node) is
   unchanged. New local test: `tests/svg/114_mark_tspan_x.svg` (99.72 %,
   pass).
2. **Emoticons U+1F600–1F64F were missing from the DejaVu Sans subset**
   (`LeanSvg/Fonts/DejaVuSans.lean`, README). matplotlib draws them from
   DejaVu Sans (`mpl-tests/test_backend_svg/multi_font_aspath` shows its
   outlines). We drew .notdef boxes for them in `multi_font_astext`. This is
   the same source font (2.37) and the same generator. The cmap is the old
   one plus 64 code points. Font data is +19,255 bytes (303,681) and Lean
   source +25,716 bytes. The binary is 46.7 MB. The outlines of all
   previously mapped code points are unchanged (checked glyph by glyph).

### Not fixed (cause, and the fix I would make)

- **STIXSize{One..Five}Sym delimiters are too small**
  (`mathtext0_dejavusans_03/04`, `mathtext0_cm_*`, `mathtext0_stix*`). These
  fonts encode larger ⟨ { ( √ ∑ at the ordinary code points. We map them to
  STIX Two Math, whose encoded glyphs are base size. Its size variants are
  unencoded (MATH table `MathVariants`, which the subset dropped). Chromium
  has no STIXSize* and falls back to DejaVu Sans, which is also base size
  but a bit larger than STIX's. Fix: keep STIX Two Math's `MathVariants`
  glyphs in the subset (`pyftsubset --glyphs` for the `*.s1`–`*.s5`
  variants) and add a table from (STIXSizeN, code point) to variant glyph id
  that `FamilyMatch` uses when the family is a STIXSize name. Size: about
  100–150 lines plus a font regeneration (roughly +40–60 KB). This is
  more than the timebox allows.
- **`DejaVu Sans Display`** (the ∫ and ∑ of `mathtext_showcase`): this is a
  matplotlib-only font with a few display-size glyphs. We alias it to DejaVu
  Sans (T106), which is closer to the author's intent than Chromium's
  fallback (a thinner, smaller ∑). Left as is, like `cmr10` → CMU.
- **STIXNonUnicode private-use code points** (U+E23A, U+E156 in
  `mathtext_showcase`: calligraphic/blackboard letters): no bundled font maps
  them. We draw .notdef, as resvg does for a glyph missing from every font
  (`layout.rs`: missing glyphs are only warned about). Chromium draws
  nothing. Fix: a small PUA → Unicode table for matplotlib's STIXNonUnicode
  code points, pointing into STIX Two Math's U+1D4xx letters. Needs
  matplotlib's `_mathtext_data` mapping (about 30 entries used in practice).
  Not done.
- **`cmr10, DejaVu Sans` in `multi_font_astext`**: matplotlib's cmr10 has
  only ASCII, so matplotlib draws accented Latin in DejaVu Sans (see
  `multi_font_aspath`). CMU covers them, so we draw them in CMU. Chromium
  draws everything in DejaVu Sans (it has no cmr10). This follows directly
  from the intended cmr10 → CMU choice. Matching matplotlib would mean
  limiting the TeX names' coverage to the TeX encoding (cmr10 = OT1 table).
  That is a policy choice for Rowan, not a clear bug.
- **Hatch patterns** (`mpl-tests/test_legend/hatching`, `test_artist/hatching`,
  `matplotlib/hatch_bars`): the hatch line phase inside the pattern tile
  differs from Chromium in some shapes. This is pattern tiling, T108's area,
  so I did not touch it.
- **Image size / 1 px offset**: 11 files are `size_mismatch` (for example
  `confusion_matrix` 960 vs 962 rows) and 84 more have heights that differ
  by 1 row (compared on the overlap). Cause: Chromium rounds the root's
  `pt` size to whole CSS pixels before scaling (234.85 pt × 225.44 pt →
  313 × 301 px → 962 rows at 1000 wide). We and resvg keep the exact ratio
  (959.9 → 960). This comes from the reference, not from us. Rows below the
  first differing one are shifted by up to a pixel, which costs 1–8 points
  on dense plots (`mcmc_trace*`, `pair_scatter`, `rank_plot`,
  `streamplot_field`, `line_collection_dashes`, `wireframe_3d`). Side by
  side they look identical. I suggest comparing these files against resvg,
  or scaling Chromium to our height. That is a harness decision; I left
  `criteria.csv` alone.
- **Rowan's notes:** `streamplot_field` and `mathtext0_dejavusans_05` look
  identical to Chromium since T106. The `?` glyphs are literal `?` in the
  source, and the remaining gap is anti-aliasing plus the 1 px row offset.
  `mathtext_showcase`: see items 1 and 2 above and the Display/PUA notes.

### Numbers

matplotlib dirs vs Chromium at 1000 px (`--dir`, 600 files): before
matplotlib 0/66 pass, matplotlib-text 0/19, mpl-tests 361/515. After: the
same, and no file moved by more than 0.1 point of within-8 (the whole
realworld corpus, 848 files). Individual files: `matplotlib-text/mathtext_showcase`
97.099 → 97.108 %, `multi_font_astext` 82.782 → 82.794 %. Both fixes are
visible, but the 1 px row shift and the font choice dominate the metric.

resvg suite, direct route, within-8 pass:

| run | before | after | pass→fail |
|---|---|---|---|
| fast (100 px) | 1543/1679 | 1543/1679 | 0 |
| default (200 px) | 1567/1679 | 1567/1679 | 0 |

The only drop is `text/text/emojis.svg` (fail → fail; −0.53 points vs resvg,
−0.55 vs its criteria reference, Chromium). It asks for "Noto Color Emoji".
Before this change we drew .notdef boxes; now 😀😁😂 fall back to DejaVu
Sans's monochrome outlines, where Chromium draws colour bitmaps. Emoji
remains "not now" (`docs/DECISIONS.md`).
`compound-emojis-and-coordinates-list.svg` +0.12.

`tests/run_tests.py`: 64/81 (63/80 before plus the new file); no file's
score dropped. `run_adversarial.py`: 171/171 clean. `run_tiles.py`: 81/81
byte-identical. `check-theorems.sh`: `theorems ok`. `lake build`: no
warnings. Wall time: realworld 1000 px render 60.5 s → 60.8 s; resvg fast
11.9 s → 11.6 s.
