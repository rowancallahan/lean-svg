# T109 — Mixed resvg-suite failures: masks, spot light cone, markers, systemLanguage, gradient on text  (branch `claude/fix-misc-resvg`)

resvg-correct files that fail (within-8 at 200 px):

masking/mask/with-opacity-1.svg 95.2%, masking/mask/with-opacity-3.svg 88.8%
filters/feSpotLight/limitingConeAngle=-30.svg and =30.svg 98.6% (keep the T101 soft fade decision; see docs/DECISIONS.md)
painting/marker/marker-on-circle.svg 98.5%
structure/systemLanguage/on-tspan.svg 95.2%
painting/fill/radial-gradient-on-text.svg 94.6%, painting/stroke/radial-gradient-on-text.svg 94.4%

Diagnose each against usvg/resvg 0.48.1 source; fix those whose cause is
small and local. For each file left, one or two sentences in the report:
cause, and the fix you would make.

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

### What changed

1. **`systemLanguage` / `requiredFeatures` / `requiredExtensions` on `tspan`, `tref`, `a`, `textPath`**
   (`LeanSvg/Svg.lean`, `textShapes`). usvg's `collect_text_chunks` checks
   `is_visible_element` (display *and* `is_condition_passed`) on each text
   node's parent; we only checked `display`. A failing span now keeps its
   characters' position slots but draws no glyphs, same as `display:none`.
2. **Group-opacity composite ties** (`LeanSvg/Canvas.lean`, `compositeNormal`).
   The integer `normal` composite (T44) rounds an exact half to even; tiny-skia's
   f32 pipeline (`Gather` has no lowp stage, so `draw_pixmap` is highp) lands an
   ulp either side. Every odd layer alpha at `opacity="0.5"` is a tie, so a
   masked layer was one alpha level off on half its pixels, which becomes ~10
   levels of colour after un-premultiplying. Only a channel on an exact tie is
   now recomputed with `blendPixel`'s f32 arithmetic (`blendOverScaledT`);
   non-tie pixels take the same path as before. Opacity passed as
   `F32.ofRat opQ opGrid` (exact for every opacity that is a multiple of 1/255,
   1/256 and common decimals, since `opGrid = 2^8·255`), so `compositeNormal`'s
   signature and its locality proof are unchanged.
3. **Paint servers on text use the `<text>` font-metric bbox**
   (`LeanSvg/Svg.lean`, `.render` branch of `<text>`). usvg's
   `node_to_user_coordinates` gives every path in `Text::flattened` the text's
   `bounding_box` (T81's metric box, `(0,-ascent)..(advance,-descent)` per
   cluster), not the run's glyph outlines. The run shapes now point at a
   `ctxUses` slot holding `mbox` and the text's `ctm` (the mechanism
   `Marker.expand` already uses for a shape's own box). Paints already tied to
   a `use` (`context-*`) keep their slot. Also fixes `text/tspan/tspan-bbox-*`,
   `text/text/real-text-height.svg`, `bidi-reordering.svg`,
   `underline-with-rotate-list-4.svg`.
4. Tests: `tests/svg/109_text_paint_lang.svg`, `tests/svg/109_mask_opacity.svg`.

### Target files (within-8, 200 px, vs resvg)

| file | before | after |
|---|---|---|
| masking/mask/with-opacity-1.svg | 95.20 | **100.00** |
| masking/mask/with-opacity-3.svg | 88.80 | **100.00** |
| structure/systemLanguage/on-tspan.svg | 95.19 | **99.98** |
| painting/fill/radial-gradient-on-text.svg | 94.64 | **99.97** |
| painting/stroke/radial-gradient-on-text.svg | 94.43 | **99.70** |
| filters/feSpotLight/limitingConeAngle=±30.svg | 98.59 | 98.59 (by decision, see below) |
| painting/marker/marker-on-circle.svg | 98.51 | 98.51 (not fixed, see below) |

### Left, with cause and proposed fix

- **feSpotLight limitingConeAngle=±30** — the whole difference is the T101 soft
  cone edge vs resvg's hard edge, kept as instructed. Against the suite PNG
  (`--ref suite`, `filters/feSpotLight`) both score **100.000%** and all 12
  files in the directory pass. **Reference looks wrong:** `tests/criteria.csv`
  lists both as `resvg`, but `docs/DECISIONS.md` (T99 answers) says files
  affected by the soft-fade change are judged against the suite PNG. Not
  changed here (criteria.csv is off limits); the integrator should set these
  two to `suite` (`limitingConeAngle=0.svg` passes either way).
- **marker-on-circle** — the markers are pixel-identical; the miss is the
  1 px green circle, and the plain circle without markers misses the same way.
  A 1 px stroke at scale 1 is a tiny-skia hairline, and `hairline::
  stroke_path_impl` flattens curves its own way: `hair_cubic` splits each cubic
  into `2^k` uniform-t lines (`compute_cubic_segments`, tol 1/8 ×4 per level;
  16 lines per quarter here), after `chop_cubic_at_max_curvature` when
  `quick_cubic_niceness_check` fails; quads use `compute_quad_level`. Since
  hairline segments are blended independently (no joins), the vertex positions
  show. `Render.drawStroke`'s hairline branch feeds `Raster.hairline` our
  general flattener's polylines instead. Fix: a hairline-only flattener over
  device-space path commands implementing those three rules (the niceness
  check is four dot products; the max-curvature chop needs a cubic solve).
  Size: ~150 lines in a new module plus plumbing the commands to that branch;
  it changes every hairline in both corpora, so it needs its own task and a
  full re-check against Chromium.

### Verification

- `lake build`: no errors, no new warnings. `check-theorems.sh`: `theorems ok`
  (invariants ok).
- resvg suite, fast 100 px: pass 1543 → **1553**, newly passing 10, newly
  failing 0.
- resvg suite, 200 px: pass 1567 → **1574**, newly passing 7, newly failing 0;
  11 files moved, all up. Wall time 17.6 s → 16.6 s.
- `run_tests.py`: 63/80 → 65/82 (the two new files pass); no file dropped;
  exact-match improved on `104_root_background` (81.5 → 99.98), `26_layers`
  (96.5 → 99.98), `34_filters`, `84_svg_image`.
- `run_adversarial.py`: 172/172 clean. `run_tiles.py`: 82/82 byte-identical.
