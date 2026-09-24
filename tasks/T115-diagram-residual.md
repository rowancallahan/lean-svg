# T115 — Graphviz / PlantUML / Mermaid / Vega residual bugs vs Chromium  (branch `claude/fix-diagram-residual`)

After T104–T106, survey `tests/corpora/realworld/{graphviz,plantuml,mermaid,web-vega}`
against Chromium at 1000 px (white-composited, side by side), ignoring pure
anti-aliasing. Rowan's notes: Graphviz "small font issue" on many files;
`graphviz/dot_class_hierarchy` should use a monospace font where the SVG asks
for one; `plantuml/timing_gantt` fonts slightly off; `web-vega/area_density_stacked`
"we should have this font too"; `mermaid/pie_budget` font.
Also: `plantuml/component_arch` and `plantuml/state_sampler` exceed the
filter work budget at 1000 px width (they render at 600). Find what the
budget is, why these hit it, and whether it can be raised within the size
and time theorems (`proofs/`) without slowing other files; if not, report.
Fix clear bugs of ours; report the rest with cause.

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

- **Filter work budget** (`LeanSvg/Render.lean`, non-rotated filter path).
  Budget: `maxFilterWork = 2^25` (primitive cost × layer pixels, per filter
  group) and `maxFilterTotal = 2^26` (summed per render); neither appears in
  `proofs/` (only `SizeBound.lean` on output size, untouched). Cause:
  PlantUML gives every node a drop shadow with a 300% region
  (`x=-1 width=300%`). At 1000 px, component_arch's package polygon
  (144×475 user units, ×5) makes a 2160×7125 px region (15.4 Mpx, under
  `maxFilterPixels`, so the existing canvas crop did not fire) × 4
  primitives = 61.6 M > 2^25, so the whole render failed "filter budget".
  Fix: when `nprims × region > maxFilterWork`, the region is intersected
  with the **whole image** (same frame as the `max_filter_bbox` limits, so
  tiles stay byte-identical; a tile-local crop failed `run_tiles`) before
  the budget check. The budgets themselves are unchanged, so the time
  bound still holds. Only files that used to fail the budget are affected.
- Test: `tests/svg/115_filter_budget_crop.svg` (800×400, 14-primitive
  shadow with a 300% region; refused before, 99.97% vs resvg now).

## Findings, not fixed (cause and proposed fix)

- **Fonts named by Rowan are already right.** A Chromium probe in this
  container: `Courier,monospace` and `Courier` → Liberation Mono (we use
  Cousine, same metrics), `Serif`/`serif` → Liberation Serif (Tinos),
  `sans-serif` → Liberation Sans (Arimo), mermaid's
  `"trebuchet ms",verdana,arial,sans-serif` → Liberation Sans (Arimo, via
  `arial`). Side-by-side crops of dot_class_hierarchy, timing_gantt,
  area_density_stacked and pie_budget show the same faces as Chromium; T106
  (merged after Rowan's notes) fixed these. `dot_class_hierarchy` is
  monospace in both.
- **The remaining "small font"/offset differences on Graphviz and PlantUML
  come from `--width` sizing, not fonts.** `Render.canvasSetup` follows the
  resvg CLI (T104): base size rounded to integers, then each axis scaled by
  `new/base`. Chromium scales uniformly by `W / exact width`. Graphviz sizes
  are in pt (`290pt` = 386.67 px → base 387), so everything is 0.09% small:
  a line at x=341.38 in Chromium is at 341.0 in ours, and the right edge
  loses a column. PlantUML timing_gantt (370×66 px) gets H = ⌈178.4⌉ = 179
  and a y scale 0.35% too large, shifting text ~0.5 px down. resvg 0.48.1
  draws exactly what we draw (checked with a probe), so the resvg suite
  reference depends on this rule. Proposed fix (small, ~15 lines in
  `canvasSetup`, but a policy decision for Rowan): a Chromium-fit mode (or
  make it the default for the realworld corpus) that uses
  `zoom = W·65536 / wFx` for both axes and `H = round(hFx·zoom)`. Not done:
  it changes the resvg-suite comparison. A quick test via `--zoom` was
  inconclusive because `--zoom` is quantised to 1/256.
- Everything else I looked at in these groups is anti-aliasing: tiny-skia
  style quarter-pixel coverage versus Skia's analytic coverage (e.g. a
  3.448 px line: Chromium 0.345/1/1/1/0.10, ours 0.25/1/1/1/0.25).
- `state_sampler` renders at 98.98% vs Chromium (threshold 99%); I did not
  look into the rest.
- The PlantUML files are slow: 9 s for state_sampler at 600 px, 11–14 s at
  1000 px (the drop-shadow blurs over large regions). Speed-phase work.

## Report

Baseline `13cac51`, after `0e0fea6` (+ this report).

| gate | before | after |
|---|---|---|
| resvg suite, 100 px (`--fast`) | 1543/1679 | 1543/1679, 0 pass→fail, 0 changed |
| resvg suite, 200 px | 1567/1679 | 1567/1679, 0 pass→fail, 0 changed |
| `run_tests.py` | 63/80 | 64/81 (new file passes; no other score changed) |
| `run_adversarial.py` | – | 171/171 clean |
| `run_tiles.py` | – | 81/81 byte-identical |
| `check-theorems.sh` | – | theorems ok |
| `lake build` | – | no errors, no new warnings |

Real-world vs Chromium, 1000 px, direct: pass 374 → 375, unsupported 2 → 0.
`plantuml/component_arch` unsupported → **pass 99.61%**;
`plantuml/state_sampler` unsupported → fail 98.98%. No other file changed.

Timing (A/B with both binaries, realworld direct at 1000 px, 4 jobs): wall
58.2 s → 64.3 s (+10%). All of it comes from the two files that now render
(11.1 s + 14.5 s CPU; they used to fail fast). Every other file: 202.7 s →
204.4 s CPU (+0.8%, noise). Above the ~5% wall rule, but only because two
files now render instead of failing; Rowan's call. The second A/B round
did not finish before shutdown. Per-group scores for the other target files
are in `/tmp/rw/realworld_direct.csv` (not committed); none changed.
