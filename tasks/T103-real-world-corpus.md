# T103 — Real-world corpus: diagrams, TikZ, maths, Bayesian plots  (branch `claude/feat-realworld-corpus`)

Rowan wants a large corpus of real-world SVGs, mostly mathematical, to check
lean-svg against Chromium by eye, and later to lock output bytes and
benchmark speed. Build `tests/corpora/realworld/` with a few hundred files
(aim for ~300; quality and variety over count):

- **TikZ / LaTeX output:** diagrams compiled with `dvisvgm` (install a
  minimal TeX Live + dvisvgm if feasible; write the `.tex` sources yourself:
  commutative diagrams, graphs, Feynman-style diagrams, geometry, plots with
  pgfplots, trees, automata, neural-network diagrams). Keep the `.tex`
  sources and a script that regenerates the SVGs. dvisvgm output embeds
  glyph paths or fonts; prefer `--no-fonts` (glyphs as paths) plus a second
  variant with fonts if it works.
- **Mathematical and statistical plots:** matplotlib SVGs you generate:
  Bayesian posteriors and priors, credible intervals, MCMC trace plots,
  corner/pair plots, histograms, contour and density plots, heatmaps,
  forest plots, ROC curves, error bars, log axes, LaTeX-style mathtext
  labels. Also a few with `svg.fonttype='none'` (real `<text>`) and the
  default (glyph paths). Keep the generating script; seed all randomness.
- **Diagrams:** Graphviz (`dot`, `neato`) flowcharts/DAGs/Bayesian networks,
  and if feasible Mermaid or PlantUML output.
- **From the web:** openly licensed SVGs only (e.g. Wikimedia Commons files
  in categories of mathematical diagrams, TikZ-made figures, statistics
  charts, Bayesian networks). Record source URL, author and licence for every
  downloaded file in `tests/corpora/realworld/SOURCES.csv`; skip anything
  without a clear free licence. No scraping beyond what is needed.

Then:
- Run lean-svg and Chromium (`tests/render_chrome.py`) on every file; report
  failures (lean-svg errors or refusals), timing (slowest files), and the
  within-8 score vs Chromium, grouped by source type.
- Write `tests/make_realworld_review.py`: a static HTML page, ours | Chromium
  side by side per file (same style as `tests/make_human_review.py`), so the
  integrator can publish it for Rowan to judge.
- Hook the corpus into `tests/run_corpora.py` as corpus `realworld` if it
  fits cleanly (reference: Chromium).
- Do not change renderer code in this task; list anything that looks wrong,
  with a one-line cause if obvious, in your report.

Repository size: commit the generated SVGs only if the total is modest
(< ~30 MB); otherwise commit sources + scripts and a fetch/generate script.
Network use is limited to installing the tools above and downloading the
openly licensed SVGs.

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
