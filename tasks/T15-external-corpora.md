# T15 — External SVG corpora: how close are we on real files?

## Goal

Measure microsvg against resvg on SVG files we did not write, with pass
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

- **direct**: feed the original file to microsvg. Measures our own parser
  and subset support. Errors (exit 1) are counted as "unsupported", not
  as failures of the renderer.
- **via usvg**: pre-process with the usvg CLI into micro-SVG (text → paths,
  CSS resolved, `use` expanded, units resolved), then feed that to
  microsvg. Install with `cargo install usvg` (Rust toolchain is at
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
- Per file: microsvg exit code and stderr (first line), resvg exit code,
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
