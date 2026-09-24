# T116 — Synthetic bold and oblique where a family lacks the face (Chromium)  (branch `claude/feat-synthetic-styles`)

T106 skipped several faces for size (DejaVu Sans Bold Oblique, DejaVu Serif
Bold/Italic, DejaVu Sans Mono Bold, Cousine Bold, Tinos Bold Italic, other
CMU faces) and draws the nearest embedded face. Chromium synthesises: bold
by emboldening outlines (Skia's fake bold: outset by a size-dependent
amount), oblique by a skew of about 20° (Skia uses -1/4 skew), when the
matched face lacks weight ≥ 600 or italic.
Implement this for **real-world (non-resvg-suite) fonts only**, following
Skia/Chromium's rule for when to synthesise and by how much; the resvg suite
path (usvg never synthesises) must not change at all. Keep it small: skew in
the glyph transform, bold as an extra stroke of the glyph outline. Check
matplotlib/Graphviz/Vega files that ask for bold italic before/after vs
Chromium.

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

## Spec implemented

`LeanSvg/Synth.lean` (new) plus small hooks in `Text.lean` / `Svg.lean`.

- **When:** only for the T106 fonts (`FontSet` indices `FamilyMatch.first ..
  count`), the glyph's own font index decides. Bold when the requested weight
  ≥ 600 and that face's weight < 600; oblique when italic/oblique is requested
  and the face is upright (Blink `FontPlatformData`: `setEmbolden`,
  `setSkewX(-1/4)`). The suite's fonts (Noto Sans etc.) and `@font-face`
  fonts never synthesise.
- **Face pick:** italic text in a T106 family now picks its face by the
  requested weight (`SpanProps.weight`/`italic`, new), so `Arial` bold italic
  is Arimo Bold + skew (was Arimo Regular). Upright picks are unchanged.
- **Oblique:** `x' = x − y/4` (y down) in the glyph's linear part, about the
  glyph origin; shaped-glyph offsets are not skewed. Measured in this
  container's Chromium (IPAGothic, DejaVu Serif at 200 px): slope 7.5 px / 30
  px = 0.25, anchored at the baseline origin.
- **Bold:** glyph outlines of a synthetic-bold cluster are also emitted as a
  `Placed` with `boldSize`, drawn *under* the run as a stroke in the fill's
  paint (miter 4, butt, no dash), width Skia's `kStdFakeBoldInterp`:
  size/24 at ≤ 9 device px, size/32 at ≥ 36, linear between (device size from
  the text's CTM scale). Measured in Chromium: symmetric outset, ≈ size/32
  per full width at 100–200 px; advances unchanged.

## Skipped / known limits

- A stroked-only glyph is stroked along the original outline, not the
  emboldened one (Chromium strokes the emboldened outline); the bold stroke
  uses the fill paint, so with `fill="none"` there is no emboldening.
- Semi-transparent fills darken where the bold stroke overlaps the fill (two
  paints, not one path). A proper outline offset is the fix (~150 lines).
- Fallback glyphs in a T106 run synthesise from their own face (e.g. DejaVu
  Sans regular for bold); Chromium would pick the fallback family's real bold.

## Report

Verification (all run on this branch, after the change):

- `lake build`: no errors, no new warnings. `check-theorems.sh`: `theorems ok`
  (and `invariants ok`).
- resvg suite, direct, fast (100 px) and default (200 px): 0 newly passing,
  0 newly failing, and **every CSV row identical** (exact/within/mean/max) at
  both widths: 1543/1679 pass at 100 px, unchanged. The suite path does not
  change.
- Timing: fast 10.5 s → 10.5 s, 200 px 16.9 s → 16.5 s, realworld 307 s →
  302 s.
- `run_adversarial.py`: 171/171 clean. `run_tiles.py`: 81/81 byte-identical.
- Real-world vs Chromium (`--ref chrome`, direct): 260/848 pass before and
  after. Only one file's numbers change: `plantuml/class_model.svg` (sans-serif
  italic → Arimo + skew) within-8 87.25 → 87.19, still failing; Chromium here
  draws it with the installed real Liberation Sans Italic, which we don't
  embed. No matplotlib/Graphviz/Vega file in the corpus asks for a face we
  lack: matplotlib's italic is DejaVu Sans Oblique (embedded), Graphviz's
  `Times,serif` italic is Tinos Italic (embedded), bold faces exist for DejaVu
  Sans/Arimo/Tinos.
- `tests/run_tests.py` (resvg reference): 63 pass before and after; new
  `116_synthetic_styles` fails vs resvg (90.08; resvg never synthesises and
  lacks these fonts). **One score drops:** `106_font_families` 90.81 → 90.50.
  Its own comment says resvg's reference has none of these families; the
  change is the "Times bold italic" line (Tinos Italic, now + fake bold).
  Against Chromium the two local files score (within-8, composited on white):

  | file | before | after |
  |---|---|---|
  | 106_font_families | 92.14 | 92.02 |
  | 116_synthetic_styles | 89.08 | 89.50 |

  The 106 drop happens because Chromium in this container has a real
  Liberation Serif **Bold Italic**, with wider advances than Tinos Italic;
  synthetic bold keeps the italic advances, so the extra ink lands off the
  reference glyphs. That is the rule working as specified: Chromium would
  synthesise the same way on a system without the Bold Italic face. The fix
  is to embed Tinos Bold Italic (Apache-2.0, ~400 KB), which T106 skipped
  for size. Not done here: it's a font decision, not synthesis.
- References: I don't think any `criteria.csv` reference is wrong. Chromium
  references for real-world files are rendered with this container's fonts,
  which include real faces we synthesise (DejaVu Serif Bold, DejaVu Sans Mono
  Bold, Liberation Mono Bold, Liberation Sans/Serif all styles) and lack faces
  we embed (DejaVu Sans Oblique: Chromium synthesises it here). Scores for
  styled text against those references measure face availability, not
  synthesis.
