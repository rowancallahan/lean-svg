# T105 — Fonts embedded in the SVG (`@font-face` with `data:` URIs)  (branch `claude/feat-embedded-fonts`)

Rowan reviewed the real-world corpus (`tests/realworld_verdicts.csv`,
`tests/realworld_triage.json`); the `tikz-fonts/*` group fails almost
everywhere on fonts: dvisvgm embeds the exact TeX fonts (Computer Modern and
its maths fonts) as WOFF2 in `<style>@font-face{src:url(data:...)
format('woff2')}` and lean-svg ignores them, so text falls back to Noto Sans
and maths symbols become tofu boxes.

Implement fonts embedded **in the file itself**:
- CSS `@font-face` in `<style>` (and the SVG `font-face`-less equivalents
  dvisvgm emits) with `src: url(data:...)` only. **Any non-`data:` URL is
  ignored** (external resources are never loaded; Rowan's rule). Formats:
  TrueType/OpenType (glyf), WOFF 1.0 (zlib: reuse our inflate), WOFF 2.0
  (Brotli decoder + WOFF2 table reconstruction, incl. transformed `glyf`/`loca`
  and `hmtx`). CFF outlines if they occur in the corpus (check `tikz-fonts`
  and `mpl-tests`), otherwise document as unsupported.
- `font-family` matching against the declared `@font-face` families first,
  then the embedded Noto/other fonts as today. `font-weight`/`font-style`
  descriptors as far as the corpus needs.
- Everything total and bounded: caps on decoded size (e.g. 16 MB per font,
  64 MB total), Brotli window/size limits, recursion/iteration fuel. Fuzz the
  new decoders like `tests/fuzz_font.py`. No proof statement may weaken; the
  effect layer is untouched (the font comes from the one input file).
- Add adversarial cases (malformed/huge/zip-bomb-like WOFF2) to
  `tests/run_adversarial.py`.

Then re-check the `tikz-fonts` fails Rowan noted (see the CSV notes), in
particular: tofu boxes in `cd_adjunction`, `cd_pullback`,
`flowchart_algorithm` (prime before theta), `venn_even_odd` (delta, omega);
square root drawing in `nn_attention`; `riemann_sums`; `lattice_subgroups`;
`matrix_block` (stretchy brackets); `plot_pgf_posterior` (overlapping density
label, missing space); `plot_pgf_loglog_errors` and `plot_pgf_bar` kerning;
`timeline_calendar`. Report before/after vs Chromium per file with images.
`tikz-fonts/knot_trefoil`: Rowan says neither renderer draws a trefoil;
check whether the SVG itself is wrong (corpus generation) and say so.

Measure: `run_corpora.py --corpus realworld --ref chrome` (group table before/
after), resvg suite gate (zero resvg-correct pass→fail).

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
