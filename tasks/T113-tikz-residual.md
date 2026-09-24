# T113 — TikZ / PGF residual bugs vs Chromium  (branch `claude/fix-tikz-residual`)

After T104–T106, find what still differs visibly from Chromium in
`tests/corpora/realworld/{tikz,tikz-fonts,web-tikz}` (render at 1000 px,
compare side by side, white-composited), ignoring the known sub-pixel height
offset (Chromium lays out at fractional heights) and pure anti-aliasing.
Known leads:
- `tikz-fonts/plot_pgf_posterior`: the MAP stem is red in ours, black in
  Chromium.
- `tikz-fonts/plot_pgf_bar` (86.6%) and `tikz-fonts/timeline_calendar`
  (82.7%): the lowest in the group; find out why.
- `tikz/knot_trefoil` and `tikz-fonts/knot_trefoil`: T105 found the corpus
  source draws a circle traced twice (five points 144° apart with Hobby
  curves). If a TeX toolchain is available offline or already installed,
  change the source to the knots-manual trefoil and regenerate both SVGs
  exactly as T103 did (`tests/corpora/realworld/src/`); otherwise document
  the corrected source and leave the SVGs.
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

## Report

**Outcome: no renderer bug of ours found in the three tikz groups; no code
changed.** Every remaining difference against Chromium traces to Chromium's
own layout of the `pt`-sized image (integer layout sizes → a slightly
different scale and a 0.3–1 px offset of the whole drawing), which the
harness cannot remove. Our output matches resvg on these files.

### Method

- `run_corpora.py --corpus realworld --ref chrome --width 1000 --keep-renders`,
  all 178 files of `tikz`, `tikz-fonts`, `web-tikz`, white-composited.
- Side-by-side ref | ours | diff for every file below 99.5 % within-32
  (after the best vertical shift of −3..3 px).
- To separate real differences from drift: resize ours to Chromium's size,
  Gaussian-blur both (σ 4 px at 1000 px), flag pixels differing > 40.
  Top 30 flagged files inspected by eye (shading_gradients, venn_even_odd,
  patterns_fill, bayesnet_regression_dag, sierpinski, posterior, bar,
  cd_adjunction, feynman_*, petersen, torus-fundamental-domain, …). Every
  flag sits on an edge that moved by a pixel or on the last row (height
  rounding); no missing, extra or wrongly coloured element anywhere.

### Leads

- **`tikz-fonts/plot_pgf_posterior`, red MAP stem**: does not reproduce.
  Chromium draws the stem red too (1000 px render), and the source says
  `\addplot[red, ycomb, mark=*]`, so red is correct. The SVG has
  `<g fill='#f00' stroke='#f00'><path d='M113.10583 0V52.39197' fill='none'/>`.
  The lead is stale (probably from before T105/T106).
- **`plot_pgf_bar` (86.6 %) and `timeline_calendar` (82.7 %)**: Chromium's
  layout offset, not ours. The 200 px renders look the same by eye; the
  diff is every horizontal edge. Measured on `timeline_calendar` at 200 px:
  the axis line's ink is at row 33 in ours **and in resvg** (alpha
  `110, 10` vs `110, 9`), but at row 32 in Chromium (ink centroid 0.87 px
  higher). Chromium sizes the `<img>` from the `pt` intrinsic size
  (454.6 × 96.4 px) with layout-unit rounding, so its viewBox scale and
  vertical placement differ slightly from the exact `viewBox` mapping. On a
  43-px-tall picture made of hairlines and small text, a sub-pixel shift
  moves most ink pixels past tolerance. Against resvg the same files score
  **98.4 %** (`tikz/timeline_calendar`) and **99.5 %** (`tikz/plot_pgf_bar`)
  at 200 px. The canvas sizes match resvg exactly (e.g. bar 1000×744,
  timeline 1000×211, pushdown 1000×210); Chromium gives 742 / 213 / 212.
  These are the same "sub-pixel height offset" class the task says to
  ignore, but visible as a *scale* drift too (≈ 1 px at x ≈ 690 on the
  1000 px bar chart).
  - Rowan's `fail` verdicts on the `tikz-fonts` versions complain about
    fonts. At 1000 px the embedded CM fonts now render like Chromium
    (glyphs, positions and kerning match up to the drift above). If those
    verdicts were given before T105 merged, they may be worth re-judging.
    I did not change `realworld_verdicts.csv`.
  - **Reference note**: for these tikz files resvg is a better reference
    than Chromium (resvg is correct here and the Chromium comparison is
    dominated by its layout rounding). For `tikz-fonts`, resvg skips
    `@font-face`, so it cannot be the reference for text; Chromium plus
    Rowan's eye is the only option there.
- **`knot_trefoil`**: no TeX toolchain in this container (`pdflatex`,
  `lualatex`, `dvisvgm`, `kpsewhich` all missing) and installing one is
  outside this task's network scope, so the SVGs and `.tex` are left
  unchanged (changing only the `.tex` would make source and SVG disagree).
  Corrected source (the knots-manual trefoil: three outer points, three
  inner points, Hobby curves), to replace the `\strand` line in
  `tests/corpora/realworld/src/tikz/knot_trefoil.tex`:
  ```tex
  \strand[very thick, blue] ([closed]90:2)
    foreach \k in {1,2,3} { .. (-30+\k*240:.5) .. (90+\k*240:2) } ;
  ```
  with `\begin{knot}[consider self intersections=true, flip crossing=2,
  clip width=4]` unchanged. Regenerate both SVGs with
  `tests/corpora/realworld/src/gen_tikz.sh` as T103 did.

### Other observations (not bugs, no fix)

- `patterns_fill` (88 % within-32 at 1000 px): pattern tiles are placed
  identically; the diff is the same scale drift, which accumulates over
  many thin periodic lines.
- `tikz/knot_trefoil` takes ~880 ms at 1000 px (slowest tikz file). Noted
  for the speed phase; not touched (round 7: no speed work).

### Numbers (baseline; unchanged since no code changed)

| run | result |
|---|---|
| resvg suite, fast 100 px | pass 1543 / 1679 (91.9 %), 11.9 s |
| resvg suite, 200 px | pass 1567 / 1679 (93.3 %), 24.3 s |
| `run_tests.py` | 63 / 80 |
| realworld vs Chromium, 200 px, `tikz` | 64 files, mean within-8 92.74 % |
| `tikz-fonts` | 64 files, mean within-8 92.58 % |
| `web-tikz` | 50 files, mean within-8 90.13 % |

No test SVG added: no feature was implemented. Build, theorems, adversarial
and tiles are untouched by this branch (only this file changed).
