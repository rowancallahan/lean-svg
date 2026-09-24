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

---

## Report

### What was built

`tests/corpora/realworld/` — **848 SVGs, 23 MB, committed** (`.gitignore` now
ignores `tests/corpora/*` except `realworld/`). Groups (top-level dirs):

| group | files | how made | regenerate |
|---|---|---|---|
| `tikz` | 64 | own `.tex` in `src/tikz/` → latex → `dvisvgm --no-fonts` | `src/gen_tikz.sh` |
| `tikz-fonts` | 64 | same DVI → `dvisvgm --font-format=woff2` (embedded @font-face + `<text>`) | same |
| `matplotlib` | 66 | `src/gen_matplotlib.py`, glyphs as paths, 56 plots + 10 style variants | `python3 src/gen_matplotlib.py` |
| `matplotlib-text` | 19 | same, `svg.fonttype='none'` | same |
| `graphviz` | 23 | own `.dot` (dot, neato, fdp, circo, twopi) | `src/gen_graphviz.sh` |
| `mermaid` | 8 | own `.mmd`, mermaid-cli (container Chromium) | `src/gen_uml.sh` (needs `MMDC=`) |
| `plantuml` | 8 | own `.puml`, Ubuntu plantuml 1.2020.2 | same |
| `mpl-tests` | 515 | **all** of matplotlib's test-baseline SVGs at a pinned commit | `src/fetch_matplotlib_tests.sh` |
| `web-tikz` | 50 | TikZ figures from janosh/diagrams (MIT) | copied; URLs in SOURCES.csv |
| `web-vega` | 31 | Vega-Lite compiled statistical examples (BSD-3) | copied; URLs in SOURCES.csv |

TikZ covers commutative diagrams (tikz-cd), graphs, Bayesian nets/plates/HMM,
Feynman diagrams (tikz-feynman), geometry/3D, pgfplots (functions, shaded
normal, posterior, bars, 3D surface, log-log error bars, histogram, polar),
trees (forest, qtree), automata, neural nets, circuits, Venn, shadings,
patterns, arrow tips, flowchart, mindmap, knots. Sources use the `dvisvgm`
class option so pgf emits real SVG gradients/clips/opacity/patterns (the
default dvips driver's PostScript specials are dropped by dvisvgm without
Ghostscript). matplotlib covers posteriors/priors, credible intervals, MCMC
trace/autocorrelation/rank plots, corner and pair plots, forest plot, GP,
hist/KDE, contour/contourf, heatmaps, hexbin, ROC/PR, error bars, log axes,
box/violin, Q-Q, 3D, quiver/stream, mathtext; all seeded; `svg.hashsalt` and
`Date=None` make output byte-stable (verified by regenerating). `tikz-fonts`
is not byte-reproducible (dvisvgm stamps the time into the WOFF2 fonts).

matplotlib's Agg PNG baselines for 480 of the 515 `mpl-tests` files are
fetched by the same script into the gitignored
`tests/corpora/matplotlib-baseline-png/` (3.7 MB) for a third comparison.

**Web sources.** Wikimedia Commons (`commons.wikimedia.org`,
`upload.wikimedia.org`) is refused by this environment's egress policy (403),
so no Commons files. Instead: janosh/diagrams (MIT), vega/vega-lite (BSD-3),
matplotlib (PSF-based Matplotlib License), cloned sparse from GitHub at pinned
commits. Every downloaded file has a row in `SOURCES.csv` (file, raw URL at
the commit, author, licence, licence URL): 596 rows.

### Harness

- `tests/run_corpora.py`: corpus `realworld` (200 px, `--fast` 100 px); not
  included in `--corpus all`, so existing runs are unchanged; `--ref` now
  defaults per corpus (resvg, except chrome for realworld). Under `--ref
  chrome` a 1-row height difference is compared on the common rows with a
  note — Chromium lays the `<img>` out at a fractional height and rounds it
  differently. Checked: resvg fast pass before/after = 1679 unchanged, 0 moved.
- `tests/make_realworld_review.py`: static page, per file ours | Chromium |
  matplotlib PNG (mpl-tests), grouped, worst first; also `results.csv` and
  `summary.md`. Default out `tests/out/realworld_review/` (~3 min for all 848).
- No renderer code changed, so the Lean build/theorem/corpus verification
  steps have nothing to check beyond the harness delta above.

### Results (width 200, tol 8, reference Chromium; our timings sequential)

| group | files | lean-svg errors | median within-8 | mean | files ≥ 99% | median ms | max ms |
|---|---|---|---|---|---|---|---|
| graphviz | 23 | 0 | 91.7% | 90.4% | 0 | 22 | 40 |
| matplotlib | 66 | 0 | 92.9% | 92.0% | 0 | 34 | 708 |
| matplotlib-text | 19 | 0 | 92.5% | 90.7% | 0 | 33 | 599 |
| mermaid | 8 | 0 | 14.6% | 16.3% | 0 | 27 | 39 |
| mpl-tests | 515 | 0 | 95.4% | 94.7% | 30 | 16 | 528 |
| plantuml | 8 | 0 | 90.3% | 89.5% | 0 | 117 | 947 |
| tikz | 64 | 1 | 95.0% | 93.6% | 2 | 19 | 88 |
| tikz-fonts | 64 | 1 | 94.5% | 92.8% | 1 | 19 | 78 |
| web-tikz | 50 | 0 | 92.1% | 91.2% | 0 | 24 | 87 |
| web-vega | 31 | 0 | 94.8% | 93.7% | 0 | 26 | 47 |
| **all** | 848 | 2 | 95.0% | 93.0% | 33 | 19 | 947 |

mpl-tests vs matplotlib's own PNG (479 comparable): median within-8 95.0%
(vs Chromium 95.5% on the same files). The PNG is Agg's render of the figure,
not of the SVG, so text hinting and AA differ by design.

Low within-8 is mostly antialiasing and text: Chromium uses system fonts
(Times/DejaVu/Liberation) where lean-svg has its one bundled face, and
Chromium's AA differs from resvg's. Only 1.1% of files reach 99% even where
the pictures look identical by eye; against resvg the same corpus passes 57.

**Failures (lean-svg errors/refusals):** `tikz/plot_pgf_3d_surface.svg` and
its `tikz-fonts` twin, exit 1 **with no message** on stderr. resvg also
refuses it ("nodes limit reached"); Chromium renders it.

**Chromium failures:** none. Not comparable (size off by 2 px, see below):
`graphviz/dot_ortho_splines.svg`, `web-tikz/torus-fundamental-domain.svg`.

**Slowest (ours, sequential, 200 px):** plantuml/state_sampler 947 ms,
plantuml/component_arch 904, matplotlib/pair_scatter 708 (5025 `<use>`
markers), matplotlib-text/pair_scatter 599,
mpl-tests/test_backends_rendering/blend_groups_svg 528,
…_rasterized 475, matplotlib/dirichlet_simplex 464 (3000 markers),
mpl-tests/test_usetex/rotation 396, image_colormap 383, heatmap_annot 383.
PlantUML's cost is a drop-shadow filter (feGaussianBlur, 300% region) over a
~200×1100 px canvas.

### Things that look wrong (renderer not changed; for follow-up tasks)

1. **Output height 1 px shorter than resvg in 226/848 files** (`--ref resvg`
   run: every size mismatch is ours = resvg − 1 in height, width equal; e.g.
   graphviz `dot_bayes_net_asia` 134 vs 135, `dot_ortho_splines` 387 vs 388,
   `tikz/patterns_fill` 129 vs 130). All have fractional `pt`/px sizes; likely
   the `--width` height computation floors where resvg rounds. Invisible on the
   resvg suite (mostly integer, square sizes). Highest-value fix here.
2. **`<pattern xlink:href>` attribute inheritance missing**: pgf emits
   `<pattern id=pgfupat1 xlink:href=#pgfpat3>` (children here) inheriting
   `width/height/patternUnits` from an empty template; ours draws nothing,
   resvg and Chromium draw the hatching (`tikz/patterns_fill`, 46% within-8).
3. **Root `background-color` style not painted**: Mermaid's
   `<svg style="background-color: white">` is painted by resvg and Chromium,
   ours stays transparent — every pixel differs in alpha, hence Mermaid's
   ~15% (`pie_budget` looks identical otherwise, 0.4% vs resvg).
4. **Mermaid labels are HTML in `<foreignObject>`**: not rendered (resvg does
   not either); flowcharts/state diagrams lose all their text.
5. **Refusal without a message** on `plot_pgf_3d_surface.svg` (see above): a
   refusal should say why.
6. **Embedded WOFF2 `@font-face` fonts ignored** (`tikz-fonts`): falls back to
   the bundled sans face; some math symbols (e.g. `\lrcorner`) become tofu.
   Expected under current policy, listed for completeness.
7. `mpl-tests/test_backends_rendering/blend_modes_svg` (67%): several
   `mix-blend-mode` cells differ from Chromium; `test_legend/hatching`,
   `matplotlib/hatch_bars`: hatch tiles offset/cropped differently from
   Chromium (look plausible). `web-tikz/materials-informatics`: Coulomb-matrix
   cells black in ours **and resvg**, coloured in Chromium — not ours alone.

### Not done / notes

- No Wikimedia Commons files (policy block above); ~80 web files from
  permissive GitHub repos instead, plus the full matplotlib baseline set that
  Rowan asked for mid-task.
- Mermaid/PlantUML output depends on tool versions (mermaid-cli latest from
  npm at generation time, PlantUML 1.2020.2); they are committed, so the
  corpus is fixed regardless.
- Byte-locking and benchmarking are left for the follow-up tasks; the
  `results.csv` timings are single sequential runs, not benchmarks.
