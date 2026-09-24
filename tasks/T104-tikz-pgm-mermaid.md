# T104 — Make TikZ, PGM (Bayesian network) and Mermaid diagrams render right  (branch `claude/fix-diagrams`)

**First:** `git merge origin/claude/feat-realworld-corpus` into your branch
(T103's corpus `tests/corpora/realworld/` and its harness: `run_corpora.py
--corpus realworld`, reference Chromium; `tests/make_realworld_review.py`).
Read T103's report in `tasks/T103-real-world-corpus.md`.

Rowan wants every diagram in the corpus to look right next to Chromium
before we freeze output bytes. Fix, one commit per item (Rowan rolls back
per commit):

1. **Notch at the top of TikZ circles/ellipses** (`tikz/bayesnet_*`,
   `tikz-fonts/*`, `web-tikz/*`): ours shows a small gap where the stroked
   circle starts/closes; Chromium draws a closed outline. Find the cause
   (dvisvgm path shape: arcs/curves ending near but not at the start, the
   closepath join, or a cap drawn at the start) and fix it for the general
   case, keeping resvg-suite stroke files passing.
2. **`<pattern xlink:href>` inheritance**: pgf emits patterns that inherit
   `width`/`height`/`patternUnits`/`patternContentUnits`/`patternTransform`/
   `viewBox`/children from the referenced pattern; ours draws nothing
   (`tikz/patterns_fill`). Implement per spec, bounded (cycle-safe).
3. **Output height 1 px short** in 226 realworld files with fractional
   sizes: match resvg/Chromium's rounding of the output size.
4. **Root `background-color`** (`<svg style="background-color: white">`,
   Mermaid): paint it like resvg and Chromium.
5. **Mermaid labels in `<foreignObject>`**: render a minimal, bounded HTML
   text subset so Mermaid flowcharts, sequence, state, class, ER, gantt and
   mindmap labels appear like Chromium: text content of
   `div`/`span`/`p`/`b`/`i`/`br` (+ `<br/>` line breaks), inline and
   `<style>` CSS for `color`, `font-size`, `font-weight`, `font-style`,
   `font-family`, `text-align`/centering within the foreignObject box,
   `line-height`, simple word wrapping at the box width. Anything else in
   foreignObject stays skipped. No scripting, no external resources.
6. **`tikz/plot_pgf_3d_surface.svg`** is refused (resvg: "nodes limit
   reached"; Chromium renders it). If our limit is a resource bound, see
   whether it can be raised within the size/time theorems; otherwise document.
7. **Survey the rest**: go through every file in `tikz`, `tikz-fonts`,
   `web-tikz`, `graphviz`, `mermaid`, `plantuml` side by side with Chromium
   (the review page) and fix further visible defects that are ours (not font
   substitution: we embed Noto Sans only, and Times/Computer Modern requests
   fall back to it with a warning). List what you leave, with causes.

Keep everything that passes against resvg on the resvg suite passing
(`scratchpad`-style gate: `run_corpora.py --corpus resvg` before/after, zero
resvg-rated-correct pass→fail); `run_corpora.py --corpus realworld --ref
chrome` before/after table per group. Theorems and invariants stay green.

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
