# T15 — External SVG corpora: how close are we on real files?

## Goal

Measure lean-svg against resvg on SVG files we did not write, with pass
rates by category, so the fidelity work is steered by real inputs. Python
only; no Lean changes. Work in the main tree
`/Users/rowancallahan/pdf_renderer`; do not touch `.worktrees/`.

## Corpora (download into `tests/corpora/`, add that directory to `.gitignore`;
commit only the scripts)

1. **resvg-test-suite** — `git clone --depth 1 https://github.com/linebender/resvg-test-suite tests/corpora/resvg-test-suite`
   (MIT). `tests/*.svg` are 200×200 viewBox files organised by
   feature directory (`shapes/`, `painting/`, `structure/`, `text/`,
   `masking/`, `filters/`, `paint-servers/`, …). Reference PNGs exist but
   we compare against resvg's own render for consistency with our metric.
2. **simple-icons** — `git clone --depth 1 https://github.com/simple-icons/simple-icons tests/corpora/simple-icons`
   (CC0). `icons/*.svg`: ~3 000 single-`<path>` 24×24 icons, the purest
   micro-SVG content there is (fills only, nonzero and evenodd).
3. **feather** — `git clone --depth 1 https://github.com/feathericons/feather tests/corpora/feather`
   (MIT). `icons/*.svg`: ~290 stroke-based icons (round caps/joins,
   `stroke-width="2"`, 24×24), exercising the stroker.

If a clone fails (network), report it and continue with the others.

## Two render routes, both measured

- **direct**: feed the original file to lean-svg. Measures our own parser
  and subset support. Errors (exit 1) are counted as "unsupported", not
  as failures of the renderer.
- **via usvg**: pre-process with the usvg CLI into micro-SVG (text → paths,
  CSS resolved, `use` expanded, units resolved), then feed that to
  lean-svg. Install with `cargo install usvg` (Rust toolchain is at
  /opt/homebrew/bin/cargo; this may take a few minutes) or check whether
  `brew install resvg` already provides `usvg` (`which usvg`). If usvg
  cannot be installed, report why and do the direct route only.

Reference for both: `resvg -w W in.svg ref.png` on the *original* file.
Render size: `--width 200` for the test suite, `--width 96` for the icon
sets (they are 24 px and want a bit of area), with the same `-w` for resvg.

## Deliverable: `tests/run_corpora.py`

- Flags: `--corpus {resvg,simple-icons,feather,all}`, `--route
  {direct,usvg,both}`, `--limit N` (random sample with fixed seed, default
  all for the icon sets, all for the suite), `--tol 8`, `--threshold 0.99`,
  `--jobs N` (parallel subprocesses; default 4).
- Per file: lean-svg exit code and stderr (first line), resvg exit code,
  same-size check, metrics as in `tests/run_tests.py` (import them).
- Output: `tests/out/corpora/<corpus>_<route>.csv` with every file, and a
  Markdown summary `tests/out/corpora/summary.md`:
  - per corpus and route: files, rendered, unsupported (exit 1, with the
    top 10 error messages and counts), size mismatches, pass rate at
    ≥ 99% within 8, median within-8, median exact;
  - for resvg-test-suite: the same **per feature directory**, sorted by
    pass rate, so unsupported features (`filters`, `masking`,
    `paint-servers`, `text` on the direct route) are visible as such;
  - the 20 worst rendered files per corpus (lowest within-8) with their
    numbers, and composites for them in `tests/out/corpora/worst/`
    (reuse `run_tests.py`'s composite function).
- Runtime: keep the default run under ~15 minutes on this machine by
  sampling if needed (`--limit 600` for simple-icons is fine; say so in
  the summary).

## Report

Append `## Report` with the summary tables pasted in, the top error
messages on the direct route, and your reading of what the worst files
have in common (e.g. arcs, `use`, gradients, text). Do not change any
Lean source or `tests/svg/`. Do not commit.

---

Python only. Added `tests/run_corpora.py`; no Lean source and nothing under
`tests/svg/` was touched, and nothing was committed by this task. (The main
session has since committed the harness at `c0d4fe4` and is extending it for
T15b; see "Notes" below.)

### What was done

- Cloned all three corpora into `tests/corpora/` - already listed in
  `.gitignore`, so no `.gitignore` change was needed: `resvg-test-suite`
  1679 `tests/**/*.svg`, `simple-icons` 3461 `icons/*.svg`, `feather` 287
  `icons/*.svg`. All three clones succeeded.
- `usvg` did **not** need `cargo install`: the Homebrew `resvg` formula
  already ships it. `which usvg` -> `/opt/homebrew/bin/usvg`, version
  0.48.1, matching `resvg`. Both routes were measured.
- New file `tests/run_corpora.py` with flags `--corpus`, `--route`,
  `--limit`, `--tol`, `--threshold`, `--jobs`, plus `--bin` and
  `--no-worst`. Metrics (`compare`) and the composite writer
  (`write_composite`, `over_white`, `diff_panel`, `load_rgba`) are imported
  from `tests/run_tests.py`, so the numbers mean exactly what they mean
  there.
- Outputs in `tests/out/corpora/`: six CSVs (one per corpus x route, every
  file with exit codes, first stderr line, size check and metrics),
  `summary.md`, and 120 `ref | ours | diff` composites under `worst/`.

### Run configuration

Binary `.lake/build/bin/lean-svg` as built by the main session, repo at
commit `f02dad9` at the start of the final run. `resvg`/`usvg` 0.48.1. tol
8, threshold 0.99, jobs 4 - all defaults.

**No sampling was needed.** The full default run (`python3
tests/run_corpora.py`: all 5427 files x both routes, ~16k subprocesses)
takes **65 s** on this machine, far inside the ~15 minute budget, so
`--limit` defaults to the whole of every corpus rather than the suggested
`--limit 600` for simple-icons. `--limit N` is still available for quick
iteration and samples with a fixed seed (20240915).

Render widths: 200 for the test suite, 96 for the icon sets, same `-w` for
resvg. The reference is always `resvg -w W` on the **original** file for
both routes, so the two routes are directly comparable.

### Per corpus and route

| corpus | route | files | rendered | unsupported | usvg err | size mism. | ref err | pass | pass% (all) | pass% (rendered) | med within-8 | med exact |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| resvg | direct | 1679 | 1671 | 5 | 0 | 0 | 3 | 408 | 24.3% | 24.4% | 94.720% | 93.947% |
| resvg | usvg | 1679 | 1676 | 0 | 0 | 0 | 3 | 960 | 57.2% | 57.3% | 99.614% | 99.037% |
| simple-icons | direct | 3461 | 3461 | 0 | 0 | 0 | 0 | 609 | 17.6% | 17.6% | 80.078% | 80.078% |
| simple-icons | usvg | 3461 | 3461 | 0 | 0 | 0 | 0 | 1533 | 44.3% | 44.3% | 98.872% | 98.872% |
| feather | direct | 287 | 287 | 0 | 0 | 0 | 0 | 88 | 30.7% | 30.7% | 94.206% | 94.206% |
| feather | usvg | 287 | 287 | 0 | 0 | 0 | 0 | 144 | 50.2% | 50.2% | 99.013% | 98.991% |

`pass% (all)` divides by every file attempted (unsupported counts against
it); `pass% (rendered)` divides by the files that produced a comparable
image. `ref err` = resvg itself refused the file (3 files:
`structure/svg/` negative-size, zero-size, not-UTF-8-encoding), excluded
from `rendered`. **Zero size mismatches anywhere** - viewBox/width/height
resolution agrees with resvg on all 5427 files on both routes.

The headline: routing through usvg roughly **doubles** the pass rate on
every corpus (24.3 -> 57.2, 17.6 -> 44.3, 30.7 -> 50.2) and lifts the
median within-8 from 80-95% to 98.9-99.6%. Most of that gap is our own path
parser and element support, not the rasteriser.

### Top error messages, direct route

Only **5 of 1679** suite files and **0 of 3748** icon files make lean-svg
exit non-zero:

| count | first stderr line |
|---|---|
| 4 | `lean-svg: error: DTD internal subset is not allowed` |
| 1 | `lean-svg: error: cannot determine image size: need width and height, or a viewBox` |

This is the most important caveat in the report: "unsupported" is almost
invisible as an exit code. lean-svg parses filters, masks, gradients, text
and arcs without complaint and then silently omits them, so unsupported
features surface as wrong pixels, not as errors. The `pass% (all)` column,
not the error count, is the honest measure of coverage. The usvg route
produces zero lean-svg errors and zero usvg errors across all 5427 files.

### Split by elliptical arcs in the source path data

| corpus | route | has arcs | files | pass | pass% | med within-8 | med exact |
|---|---|---|---|---|---|---|---|
| resvg | direct | yes | 20 | 1 | 5.0% | 96.190% | 96.188% |
| resvg | direct | no | 1659 | 407 | 24.5% | 94.385% | 93.747% |
| resvg | usvg | yes | 20 | 18 | 90.0% | 99.693% | 99.681% |
| resvg | usvg | no | 1659 | 942 | 56.8% | 99.611% | 99.031% |
| simple-icons | direct | yes | 2405 | 6 | 0.2% | 67.665% | 67.643% |
| simple-icons | direct | no | 1056 | 603 | 57.1% | 99.192% | 99.192% |
| simple-icons | usvg | yes | 2405 | 852 | 35.4% | 98.698% | 98.698% |
| simple-icons | usvg | no | 1056 | 681 | 64.5% | 99.338% | 99.338% |
| feather | direct | yes | 146 | 0 | 0.0% | 82.080% | 82.069% |
| feather | direct | no | 141 | 88 | 62.4% | 99.316% | 99.306% |
| feather | usvg | yes | 146 | 56 | 38.4% | 98.725% | 98.660% |
| feather | usvg | no | 141 | 88 | 62.4% | 99.349% | 99.316% |

### resvg-test-suite by feature directory - direct route

Top level:

| corpus | route | files | rendered | unsupported | usvg err | size mism. | ref err | pass | pass% (all) | pass% (rendered) | med within-8 | med exact |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| shapes | direct | 133 | 133 | 0 | 0 | 0 | 0 | 107 | 80.5% | 80.5% | 100.000% | 99.995% |
| painting | direct | 304 | 304 | 0 | 0 | 0 | 0 | 119 | 39.1% | 39.1% | 98.250% | 97.894% |
| structure | direct | 247 | 239 | 5 | 0 | 0 | 3 | 63 | 25.5% | 26.4% | 77.935% | 77.933% |
| filters | direct | 397 | 397 | 0 | 0 | 0 | 0 | 70 | 17.6% | 17.6% | 64.183% | 43.750% |
| masking | direct | 93 | 93 | 0 | 0 | 0 | 0 | 8 | 8.6% | 8.6% | 11.680% | 11.680% |
| text | direct | 356 | 356 | 0 | 0 | 0 | 0 | 30 | 8.4% | 8.4% | 97.594% | 97.055% |
| paint-servers | direct | 149 | 149 | 0 | 0 | 0 | 0 | 11 | 7.4% | 7.4% | 36.000% | 35.998% |

By feature directory, sorted by pass rate then median within-8 so the
bottom of the table is genuinely the worst rather than alphabetically last
among the 0% rows. Top five, then bottom five; the full 107-row table is in
`tests/out/corpora/summary.md`:

| corpus | route | files | rendered | unsupported | usvg err | size mism. | ref err | pass | pass% (all) | pass% (rendered) | med within-8 | med exact |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| filters/feDisplacementMap | direct | 1 | 1 | 0 | 0 | 0 | 0 | 1 | 100.0% | 100.0% | 100.000% | 99.997% |
| painting/fill-rule | direct | 2 | 2 | 0 | 0 | 0 | 0 | 2 | 100.0% | 100.0% | 100.000% | 99.997% |
| painting/stroke-miterlimit | direct | 5 | 5 | 0 | 0 | 0 | 0 | 5 | 100.0% | 100.0% | 100.000% | 99.997% |
| shapes/polygon | direct | 5 | 5 | 0 | 0 | 0 | 0 | 5 | 100.0% | 100.0% | 100.000% | 99.997% |
| shapes/polyline | direct | 5 | 5 | 0 | 0 | 0 | 0 | 5 | 100.0% | 100.0% | 100.000% | 99.997% |
| … 97 more rows in `summary.md` … | | | | | | | | | | | | |
| filters/feDistantLight | direct | 4 | 4 | 0 | 0 | 0 | 0 | 0 | 0.0% | 0.0% | 7.840% | 7.838% |
| filters/fePointLight | direct | 4 | 4 | 0 | 0 | 0 | 0 | 0 | 0.0% | 0.0% | 7.840% | 7.838% |
| filters/feSpotLight | direct | 12 | 12 | 0 | 0 | 0 | 0 | 0 | 0.0% | 0.0% | 7.840% | 7.838% |
| filters/flood-color | direct | 7 | 7 | 0 | 0 | 0 | 0 | 0 | 0.0% | 0.0% | 7.840% | 7.838% |
| filters/flood-opacity | direct | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0.0% | 0.0% | 7.840% | 7.838% |

### resvg-test-suite by feature directory - usvg route

Top level:

| corpus | route | files | rendered | unsupported | usvg err | size mism. | ref err | pass | pass% (all) | pass% (rendered) | med within-8 | med exact |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| shapes | usvg | 133 | 133 | 0 | 0 | 0 | 0 | 131 | 98.5% | 98.5% | 100.000% | 99.995% |
| text | usvg | 356 | 356 | 0 | 0 | 0 | 0 | 334 | 93.8% | 93.8% | 99.760% | 99.093% |
| painting | usvg | 304 | 304 | 0 | 0 | 0 | 0 | 210 | 69.1% | 69.1% | 99.963% | 99.891% |
| structure | usvg | 247 | 244 | 0 | 0 | 0 | 3 | 166 | 67.2% | 68.0% | 100.000% | 99.997% |
| masking | usvg | 93 | 93 | 0 | 0 | 0 | 0 | 21 | 22.6% | 22.6% | 20.365% | 20.365% |
| filters | usvg | 397 | 397 | 0 | 0 | 0 | 0 | 77 | 19.4% | 19.4% | 64.410% | 48.157% |
| paint-servers | usvg | 149 | 149 | 0 | 0 | 0 | 0 | 21 | 14.1% | 14.1% | 36.000% | 35.998% |

Top five and bottom five by feature directory:

| corpus | route | files | rendered | unsupported | usvg err | size mism. | ref err | pass | pass% (all) | pass% (rendered) | med within-8 | med exact |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| filters/feDisplacementMap | usvg | 1 | 1 | 0 | 0 | 0 | 0 | 1 | 100.0% | 100.0% | 100.000% | 99.997% |
| painting/color | usvg | 4 | 4 | 0 | 0 | 0 | 0 | 4 | 100.0% | 100.0% | 100.000% | 99.997% |
| painting/fill-rule | usvg | 2 | 2 | 0 | 0 | 0 | 0 | 2 | 100.0% | 100.0% | 100.000% | 99.997% |
| painting/stroke-miterlimit | usvg | 5 | 5 | 0 | 0 | 0 | 0 | 5 | 100.0% | 100.0% | 100.000% | 99.997% |
| painting/stroke-width | usvg | 5 | 5 | 0 | 0 | 0 | 0 | 5 | 100.0% | 100.0% | 100.000% | 99.997% |
| … 97 more rows in `summary.md` … | | | | | | | | | | | | |
| filters/feDistantLight | usvg | 4 | 4 | 0 | 0 | 0 | 0 | 0 | 0.0% | 0.0% | 7.840% | 7.838% |
| filters/fePointLight | usvg | 4 | 4 | 0 | 0 | 0 | 0 | 0 | 0.0% | 0.0% | 7.840% | 7.838% |
| filters/feSpotLight | usvg | 12 | 12 | 0 | 0 | 0 | 0 | 0 | 0.0% | 0.0% | 7.840% | 7.838% |
| filters/flood-color | usvg | 7 | 7 | 0 | 0 | 0 | 0 | 0 | 0.0% | 0.0% | 7.840% | 7.838% |
| filters/flood-opacity | usvg | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0.0% | 0.0% | 7.840% | 7.838% |

### What the worst files have in common

Four distinct causes, in order of cost:

1. **Elliptical arc commands (`A`/`a`) are dropped, and they take the rest
   of the path with them.** By far the biggest single defect, and it
   dominates both icon sets. A minimal
   `d="M4 4 L10 4 A6 6 0 0 1 16 10 L16 20"` renders only the first `L`
   segment; everything from the arc onward is discarded. On a **filled**
   path the truncated contour usually closes across the whole viewBox, so
   the icon becomes a solid black square - `simple-icons/processon` at
   2.2% within-8 with `mean_abs` ~61
   (`worst/simple-icons_direct__processon_cmp.png`). On a **stroked** path
   the tail simply vanishes
   (`worst/feather_direct__paperclip_cmp.png`,
   `worst/feather_direct__folder_cmp.png`). The cross-tab is unambiguous:
   files containing an arc pass 0.2% (simple-icons) and 0.0% (feather) on
   the direct route, versus 57.1% and 62.4% for files without one - and 69%
   of simple-icons and 51% of feather contain arcs. The resvg suite has
   only 20 arc files, so its own tables hide this completely; the icon sets
   are what exposed it.

2. **Whole feature subsystems are ignored rather than approximated**, and
   these are equally bad on both routes because usvg does not remove them:
   `masking` (8.6% / 22.6%), `paint-servers` (7.4% / 14.1%), `filters`
   (17.6% / 19.4%). The failure mode is "paint the source object at full
   opacity, ignore the modifier": `masking/mask/simple-case` renders a
   solid green square where the reference is a faded gradient wash, 0.000%
   within-8 (`worst/resvg_usvg__masking__mask__simple-case_cmp.png`), and
   `clipPath` behaves the same way - which is why 12 of the 20 worst
   direct-route suite files are `masking/clipPath/*` at exactly 0.000%.
   Gradients degenerate to a flat colour, which is why every
   `paint-servers/stop*` directory sits at exactly 36.000% median. The
   bottom five directories on **both** routes are the filter light sources
   and `flood-*`, all 0% pass and 7.840% median within-8 - a filter region
   we leave unpainted over ~92% of the canvas.

3. **Text does not exist on the direct route.** `text` is 8.4% pass but
   with a 97.6% median within-8: we render a blank canvas and glyphs only
   cover 2-3% of a 200x200 test, so the metric barely notices while every
   single `text/*` directory sits at 0% pass. usvg's text-to-path
   conversion fixes this almost entirely - `text` jumps to **93.8%**, the
   largest single-feature win in the report. Similarly `structure`
   25.5 -> 67.2% (`use` expansion, CSS, units) and `shapes` 80.5 -> 98.5%.

4. **Residual usvg-route failures are antialiasing on curves, not
   geometry.** The worst usvg-route icons are all circles and round strokes
   (feather dribbble, globe, target, eye, disc, map-pin) at 94-96%
   within-8 but **99.2-99.7% within-32**, `mean_abs` ~0.25, `max_d` 64;
   `simple-icons/elsevier` is a speckle of single-pixel edge differences
   over dense line art (`worst/simple-icons_usvg__elsevier_cmp.png`). Those
   files are geometrically correct and fail only because a thin fringe of
   edge pixels differs in coverage by up to ~64/255. Across simple-icons on
   the usvg route the 1928 failures have a median within-8 of 98.25% and a
   median within-32 of 99.95%, i.e. most of them are this, just under the
   bar. Straight-edged content is clean by contrast: `structure/transform`,
   `shapes/polygon`, `shapes/polyline` and `painting/stroke-miterlimit` all
   sit at 100.000% median exact on both routes.

Short version for steering: fix arcs first - one path-data feature worth
roughly 40 points of pass rate on real icon content - then `clipPath` and
`mask`, then gradients. Text and `use` can be deferred for as long as a
usvg pre-pass is acceptable. Curve antialiasing is the last few points and
the least urgent.

### Notes

- Nothing was committed by this task. The main session independently
  committed `tests/run_corpora.py` at `c0d4fe4` and is now extending it for
  T15b (`--fast`, `--dir`, `--out`, `--failing-from`, `--compare`). The
  final measurement run was therefore made from a pristine copy of the
  `c0d4fe4` harness in a scratch directory, so those in-progress edits
  could not affect it; the numbers above reproduce with `python3
  tests/run_corpora.py`.
- One real bug in the harness was found while running it and fixed in
  place: scratch PNG filenames were recycled as `i mod (jobs * 4)`, so a
  slow file (`filters/feMorphology/huge-radius.svg`, where resvg takes
  seconds) let later indices catch up and clobber its output, producing
  roughly one spurious `unreadable_png` row per 10k renders. Slots are now
  unique per file. The numbers above come from a clean run with that fix
  and contain no `unreadable_png` rows.
- `tests/out/` is gitignored, so the CSVs, `summary.md` and the composites
  are local artefacts of this run and are not committed.
