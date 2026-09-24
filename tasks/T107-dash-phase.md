# T107 — Dash pattern and offset, 12 resvg-suite files at ~98.8%  (branch `claude/fix-dash-phase`)

These resvg-correct files all fail narrowly (within-8 about 98.1–98.9% at
200 px), which suggests one shared cause in dashing (phase start, rounding of
dash lengths, or how a dash crossing a subpath start/closepath is split):

painting/stroke-dasharray/{comma-ws-separator,em-units,mm-units,odd-count,ws-separator}.svg
painting/stroke-dashoffset/{default,em-units,mm-units,negative-value,percent-units,px-units}.svg
shapes/path/M-C-S.svg and shapes/path/M-S-S.svg (check whether they share the cause; if not, leave them)

Compare with tiny-skia's `dash.rs` (resvg 0.48.1 → tiny-skia) and find where
our dashes differ (diff images at 400 px). Fix the shared cause. Also check
`mpl-tests/test_axes/dash_offset.svg` and `mpl-tests/test_lines/line_collection_dashes.svg`
against Chromium before/after.

## Spec implemented

- **Dash ends are square to the curve's tangent** (`LeanSvg/DashSeg.lean`,
  `Geom.dashSegs`/`finishDash`). tiny-skia dashes the curve itself
  (`ContourMeasure::push_segment` extracts sub-Béziers) and caps each dash
  along the curve's tangent there. Ours cut the *flattened* polyline, so each
  dash end was square to the chord it fell on, tilted by up to half the chord's
  angle. On the test circles (r=70, stroke 10) that moved a butt end by
  about 0.5 px at 400 px. `flattenSegs` flattens exactly as `flatten` does
  (same `segCount`, same points) and also records the curve's derivative at
  both ends of every chord. `dashSegs` (the old `dashPoly` loop, unchanged
  except for walking `DSeg`s) interpolates that derivative at each dash boundary.
  `finishDash` then adds one point a short step (≤ ¼ unit, ≤ ⅓ of the end
  chord, skipped below ⅛ unit or at a cusp) in from each dash end along the
  tangent, so `strokePoly`'s cap follows it. Straight segments carry no tangent
  and are untouched. `dashPoly` is kept as the tangent-free wrapper.
- Only dashed strokes take the new path: `Render.drawShape` calls
  `dashPath … ctm s.cmds` instead of `dashPolys` on the already-flattened polys.

## Skipped: the shared cause is the curve stroker, not dashing

The dash phase itself was fine: our dash starts match resvg's. After the
tangent fix, the dash ends at 400 px match resvg pixel for pixel (checked on the
start-point dash of `ws-separator.svg`). The remaining ~1.1 % of bad pixels in
all 11 dashed files are **along the sides of every dash**: one coverage level
(~26/255) off along the whole curved edge. An **undashed** copy of the same
circle (`ws-separator.svg` with the dasharray removed) scores **98.14 %** within-8 at
200 px, worse than the dashed file's 98.8 % because it has more edge.
`shapes/path/M-C-S.svg` and `M-S-S.svg` (undashed open curves) show the same
whole-edge pattern. So they share this cause, and it is not a dashing cause.

Cause: `strokePoly` offsets the *flattened chords* of the centre curve.
tiny-skia's `PathStroker` offsets the *curve* (`cubic_stroke`/`quad_stroke`
approximate each side with quads, subdivided by its tangent-ray tolerance
tests), and the rasterizer then flattens those offset quads with its own
`QuadraticEdge` subdivision. The outline vertices therefore sit at different
places, about 0.1 px apart. Tuning flattening density does not fix it: doubling
curve segments moves the undashed circle from 98.14 % to 98.40 % at 200 px but
makes it worse at 400 px (1224 → 1503 bad px).

Fix I would make: port tiny-skia's curve stroking (`stroker.rs`:
`cubic_to`/`quad_to`, `cubic_stroke`, `quad_stroke`, `compare_quad_*`,
`intersect_ray`, `points_within_dist`) as a new `LeanSvg/StrokeCurve.lean` that
emits offset quads. Each quad would be flattened with `segCountQuad`/`quadAt` into
the outline `strokePoly` builds today for its curve runs. Size: roughly
400–600 lines of Lean plus Render wiring. It touches every stroked curve in the
suite, so it needs a full regression pass. That is a multi-day stroker task and
over this round's 2-hour box, so it is not started.

## Report

Numbers are resvg-suite within-8 (%), direct route.

| file (200 px) | before | after |
|---|---|---|
| `stroke-dasharray/comma-ws-separator.svg` | 98.89 | 98.90 |
| `stroke-dasharray/em-units.svg` | 98.68 | 98.69 |
| `stroke-dasharray/mm-units.svg` | 98.15 | 98.18 |
| `stroke-dasharray/odd-count.svg` | 98.86 | 98.86 |
| `stroke-dasharray/ws-separator.svg` | 98.84 | 98.85 |
| `stroke-dashoffset/default.svg` | 98.84 | 98.85 |
| `stroke-dashoffset/em-units.svg` | 98.84 | 98.85 |
| `stroke-dashoffset/mm-units.svg` | 98.87 | 98.91 |
| `stroke-dashoffset/negative-value.svg` | 98.88 | 98.89 |
| `stroke-dashoffset/percent-units.svg` | 98.93 | 98.94 |
| `stroke-dashoffset/px-units.svg` | 98.88 | 98.89 |
| `path/M-C-S.svg` (not dashed) | 98.99 | 98.99 |
| `path/M-S-S.svg` (not dashed) | 98.96 | 98.96 |

None of the 13 target files passes yet; the remaining gap is the stroker issue above.

- **Whole suite, 200 px:** pass 1567/1679 before and after; newly passing 0,
  newly failing 0. 13 files changed within-8, all up (the 11 above plus
  `even-count`, `on-a-circle`, `percent-units` in stroke-dasharray).
- **Whole suite, 100 px (`--fast`):** pass 1543/1679 before and after; 0 → fail.
  14 files changed: 13 up and `stroke-dasharray/percent-units.svg` 98.73 → 98.72
  (1 px).
- **Wall time:** `run_corpora.py` fast 12.3 s → 12.4 s, 200 px 20.1 s → 19.4 s
  (noise). Only dashed shapes flatten a second time.
- **`tests/run_tests.py`:** 63/80 pass before and after. `23_dashes`,
  `35_painting_tail` and `25_text` (within-8) up. `92_css_units` 88.983 → 88.982:
  3 pixels changed on its dashed `r="1lh"` circle, which resvg does not draw at all
  (the reference is blank there, since resvg lacks those CSS units). New
  `tests/svg/107_dash_tangent.svg` (wide butt/square dashes on circle, ellipse,
  quad and cubic paths) scores 97.78 → 97.92 % within-8. It stays below
  threshold because of the stroker cause above.
- `lake build` clean, no warnings. `check-theorems.sh`: `theorems ok`.
  `run_adversarial.py`: 170/170 clean. `run_tiles.py`: 80/80 byte-identical.
- **Real-world vs Chromium (200 px):** direct 260/848 pass before and after; 0
  newly passing or failing. 10 files moved by at most 0.09 points (5 up, 5 down, largest
  `web-tikz/cylinder-to-plane` +0.09, `tikz/graph_grid_torus` −0.03).
  `mpl-tests/test_axes/dash_offset.svg` (90.16 %) and
  `mpl-tests/test_lines/line_collection_dashes.svg` (75.13 %) are unchanged
  (straight dashes, no tangent involved). Against resvg we score 99.05 % and 99.82 %
  on them, and resvg itself scores 90.8 % vs Chromium on `dash_offset`. Their
  Chromium gap is resvg vs Chromium stroking and antialiasing, not our dashing.
- References: no evidence that any target file's reference is wrong.

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
