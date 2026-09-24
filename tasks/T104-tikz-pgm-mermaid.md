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

## Addendum (integrator, Rowan's requirement)

The foreignObject HTML subset must keep every theorem and the file
behaviour exactly as it is: one input file read, at most the PNG and (with
`--warnings`) the warnings file written, nothing on stdout/stderr, and no
external resource ever loaded (no `img`, `link`, `iframe`, `object`,
`embed`, `video`, CSS `url()`/`@import`). `tests/run_adversarial.py` now
has `foreignobject_refs_inert`, which the merge gate runs.

---

## Report

One commit per item (roll back per commit). All on `claude/fix-diagrams`, after
merging `origin/claude/feat-realworld-corpus` (T103).

### Items

1. **Notch atop TikZ circles** (`LeanSvg/Raster.lean`). Not the path's
   start or its closepath. It was the anti-hairline scan converter:
   tiny-skia's oblique blitters clamp an upper pixel of `-1` to `0`
   (`max(i,1)-1`) and pin `fy` at the image top, so a hairline grazing row 0
   moves down one pixel. The top of a circle that touches the canvas edge
   (every TikZ figure has a tight bounding box) then shows a gap in the
   middle. resvg does the same; Chromium does not. Fix: the oblique flavours
   drop the `-1` pixel (as `HLine` already does) and `fy` is not pinned.
   `VLine` keeps its clamp: removing it moved `text/font-size/named-value`
   pass→fail (the suite's 1 px frame at `--width 100`). No pixel changes on
   the resvg suite at 100 or 200 px.
2. **pgf patterns** (`Svg.lean`, `Pattern.lean`). `href` inheritance already
   worked. The real cause: pattern content skipped `<use>`, and pgf's content
   is `<use xlink:href="#pgfsym3"/>` of a `<symbol>`. `Use.expand` has
   already copied the target inside the `use`, so pattern content now treats
   `use` as a `g` with its `x`/`y` translate. The symbol's generated viewport
   clip is ignored, like every clip-path inside pattern content (existing
   gap). `patternTransform` is now also inherited along the `href` chain, as
   SVG and Chromium do (usvg doesn't; no suite file tests it). Cycles stay
   bounded by the existing `chainOf` fuel. Test:
   `tests/svg/104_pattern_use_symbol.svg` (99.43% vs resvg).
3. **Height 1 px short** (`Render.canvasSetup`). resvg's CLI rounds the SVG
   size to integers, then `H = ⌈W·baseH/baseW⌉` (`IntSize::scale_to_width`),
   and scales each axis by `new/base` (`fit_to_transform`, non-uniform). We
   now do the same. Realworld vs resvg: size mismatches 226 → 0, passes
   57 → 505. Trade-off against Chromium: Chromium's size is uniform
   `W·h/w` (not rounded first), e.g. 460.8×345.6 pt → 150 rows there, 151 in
   resvg and ours, and resvg's y-stretch shifts content by up to a row at the
   bottom. That is the "worse > 0.5" column vs Chromium in matplotlib/tikz
   below. A uniform scale with resvg's size was measured and is worse on
   both references (realworld vs resvg 56 passes; vs Chromium median 94.9%
   vs 96.9%), so the resvg behaviour stays.
4. **Root `background-color`** (`Svg.rootBackground`). As usvg's
   `convert_doc`: a plain colour from attribute, `style=`, or CSS (winning
   layer) fills the viewBox, or the root size when there is no viewBox. It is
   placed before the root's own layer, so root opacity/clip/mask/filter don't
   apply. Test: `tests/svg/104_root_background.svg` (100% vs resvg).
   `mermaid/pie_budget` vs resvg 0.4% → 97.2%.
5. **Mermaid HTML labels** (`Xml.lean`, new `LeanSvg/ForeignObject.lean`).
   `Xml.parse` now delivers an XHTML subtree whose root is a child of an SVG
   `foreignObject`, as `html:<name>` elements plus text. Nothing else in the
   pipeline recognises those names. Any non-XHTML element inside it is still
   dropped with its subtree. `ForeignObject.rewrite` (after `use` expansion)
   turns each such `foreignObject` into a `<g>` of SVG `<text>` lines:
   - elements: `div`/`p` (blocks), `span`/`b`/`strong`/`i`/`em`, `br`;
   - CSS (inline + `<style>`, matched on the full element chain, inherited
     from SVG ancestors): `color`, `font-size`, `font-weight`, `font-style`,
     `font-family`, `text-align`, `line-height`, `white-space`,
     `display:none`, plus `background-color` on `div`/`p` (Mermaid's
     edge-label boxes, which also hide the edge behind the text);
   - layout: whitespace collapse, greedy word wrap at the box width (advances
     from the embedded face, no kerning), CSS half-leading baseline from the
     face's ascent/descent.

   The output is bounded by `Xml.maxElements`. Left out, and documented in
   the module: margins, padding, borders, inline backgrounds, the
   foreignObject clip, mixed font sizes on one line, bidi, and preserved
   spaces under `pre`. A `foreignObject` that is a direct child of `switch`
   is left alone, so switch fallbacks behave as before. Mermaid vs Chromium:
   median 14.6% → 93.6%. No `tests/svg` file: resvg (the local oracle) draws
   none of this.
6. **`plot_pgf_3d_surface` refused.** The cause is `Xml.maxDepth = 64`: the
   file nests 1164 groups, one per pgfplots patch. This is a SPEC resource
   bound that no proof depends on, and output size doesn't depend on it. The
   parser and interpreter use array stacks, not recursion. The one per-element
   cost that grows with depth is CSS descendant matching, which is linear in
   depth: 200k rects under 2040 groups with 2 descendant rules take 35 s,
   against 7.4 s at depth 60. Without `<style>` it is 9.7 s. Raised the cap
   to 2048 and updated SPEC, DESIGN and the adversarial suite (3000 rejected;
   60, 2000, and 2000 under CSS accepted; 155/155 clean). The file now
   renders like Chromium (resvg still refuses it). The CLI stays silent on
   refusal by design (T98b: no stdout/stderr); the missing message T103
   reported is not a bug.
7. **Survey**: every file in `tikz`, `tikz-fonts`, `web-tikz`, `graphviz`,
   `mermaid` and `plantuml` checked ours | Chromium, worst first. One more
   defect of ours was fixed: CSS Color 4 **`oklab()`** colours (new
   `LeanSvg/Oklab.lean`). `web-tikz/materials-informatics`'s Coulomb-matrix
   cells were black (usvg treats oklab as invalid). The implementation is
   exact `Int` oklab → linear sRGB, then an 8-bit encode by counting 255
   precomputed midpoint thresholds (round, clip, no floats). It matches
   Chromium exactly on six in-gamut, out-of-gamut and alpha samples. No
   resvg suite file uses it.

### Left as is (causes)

- **Font substitution**, everywhere in `graphviz` (Times), `tikz-fonts`
  (embedded WOFF2 `@font-face` is ignored) and Mermaid (trebuchet): we embed
  Noto Sans only. This accounts for most of the remaining within-8 gap in
  these groups; the pictures otherwise match.
- `mermaid/gantt_project` grid ticks: `shape-rendering: crispEdges` on
  sub-pixel lines. We match resvg (aliased; some ticks drop out), while
  Chromium anti-aliases them. The resvg suite covers crispEdges, so no
  change.
- `tikz/patterns_fill` at ≤ 400 px: hatch lines are a little heavier than
  resvg's (72.7% within-8 vs resvg at 400 px, 96% at 1600 px). This is
  pre-existing pattern-tile hairline rendering, not item 1 (verified by
  rebuilding with the old `Raster.lean`: identical). Visually it matches
  both references.
- Two files whose size Chromium rounds differently from resvg's model can't
  be compared at 200 px (`mermaid/er_schema` 633 vs 635,
  `web-tikz/torus-fundamental-domain` 289 vs 287). Both look right.
- Mermaid labels are wider in our font than in Chromium's, so a few
  overhang their boxes a little. Those boxes are sized by Chromium's font
  metrics.
- `mpl-tests/test_backends_rendering/blend_modes_svg`: not in this task's
  groups (T103 item 7).

### Numbers

resvg suite (`--route direct`, before → after, compare CSVs): **fast 100 px:
1543 → 1543 pass, 0 files moved; 200 px: 1567 → 1567 pass, 0 files moved**
(checked after every item). `run_tests.py`: 60/75 → 62/77 (the two new
T104 files pass; `16_stress_2000` 97.480 → 97.516; nothing dropped).
`run_adversarial.py` 155/155 clean. `run_tiles.py` 77/77 byte-identical.
`check-theorems.sh`: theorems ok. `lake build`: no warnings.

Realworld vs **Chromium** (`--ref chrome`, 200 px, median/mean within-8):

| group | files | median before | median after | mean before | mean after | errors before | errors after | improved >0.5 | worse >0.5 |
|---|---|---|---|---|---|---|---|---|---|
| graphviz | 23 | 90.5 | 90.9 | 86.5 | 90.2 | 0 | 0 | 7 | 9 |
| matplotlib | 66 | 92.9 | 91.1 | 92.0 | 90.0 | 0 | 0 | 20 | 36 |
| matplotlib-text | 19 | 92.5 | 89.8 | 90.7 | 87.6 | 0 | 0 | 4 | 12 |
| mermaid | 8 | 14.6 | 93.6 | 16.3 | 81.6 | 0 | 0 | 7 | 1 |
| mpl-tests | 515 | 95.4 | 99.0 | 94.7 | 97.3 | 0 | 0 | 395 | 55 |
| plantuml | 8 | 90.3 | 92.3 | 89.5 | 91.8 | 0 | 0 | 5 | 2 |
| tikz | 64 | 95.0 | 94.0 | 92.1 | 92.7 | 1 | 0 | 11 | 34 |
| tikz-fonts | 64 | 94.5 | 93.7 | 91.3 | 92.1 | 1 | 0 | 11 | 30 |
| web-tikz | 50 | 92.1 | 91.7 | 89.3 | 88.3 | 0 | 0 | 18 | 21 |
| web-vega | 31 | 94.8 | 93.3 | 93.7 | 92.9 | 0 | 0 | 14 | 15 |
| all | 848 | 95.0 | 96.9 | 92.6 | 94.7 | 2 | 0 | 492 | 215 |

Files ≥ 99% vs Chromium: 33 → 259. The "worse" column is almost all item 3
(resvg's non-uniform y-scale against Chromium's uniform one, see above); the
`mermaid` "worse" file is `er_schema`, now incomparable on size.

Realworld vs **resvg** (`--ref resvg`): passes 57 → 505, size mismatches
226 → 0, all 848 files are at least as good (744 improved > 0.5 points, 0
worse). Median within-8 94.7% → 99.3% (the "before" medians of 0 in the
tikz/matplotlib rows are size-mismatched files scored 0).

### Files

`LeanSvg/Raster.lean` (1), `LeanSvg/Pattern.lean`, `LeanSvg/Svg.lean` (2, 4,
hooks for 5 and 7), `LeanSvg/Render.lean` (3), `LeanSvg/Xml.lean` (5, 6),
new `LeanSvg/ForeignObject.lean` (5), new `LeanSvg/Oklab.lean` (7),
`LeanSvg.lean` imports, `SPEC.md`/`DESIGN.md`/`tests/run_adversarial.py`
(6), `tests/svg/104_pattern_use_symbol.svg`, `tests/svg/104_root_background.svg`.
