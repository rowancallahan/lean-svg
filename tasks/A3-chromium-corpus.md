# A3 — Chromium as a whole-corpus reference  (branch `claude/audit-a3-chromium`)

Rowan wants Chromium as a second oracle across the entire resvg suite, not
only on the files resvg gets wrong. `tests/render_chrome.py` renders SVGs with
the container's headless Chromium.

1. Add `--ref {resvg,chrome,suite}` to `tests/run_corpora.py` (default
   `resvg`, unchanged behaviour). `chrome` renders the reference with
   Chromium; batch many files per browser launch so the whole suite takes
   minutes, not hours (one page reused, or a pool across `--jobs`). Keep the
   external-resource rule: for `chrome`, strip external hrefs from the copy
   exactly as the resvg path does, so the browser does not load them either.
   (Another agent may add `suite` concurrently; if so, keep both and make the
   option shared.)
2. Run the whole suite at 200 px with `--ref chrome` and write
   `docs/audit/A3-chromium.md`:
   - ours vs Chromium, resvg vs Chromium, ours vs resvg: pass counts overall
     and per feature directory;
   - the files where **ours ≠ resvg but ours = Chromium**, and where
     **ours = resvg ≠ Chromium** (those are the interesting ones), with
     `results.csv`'s resvg rating for each;
   - systematic differences that make Chromium a poor oracle for some areas
     (text antialiasing/hinting, fonts, filters colour space, etc.): measure,
     don't guess, and say which directories Chromium is and is not a trusted
     reference for.
3. A comparison sheet `docs/audit/A3-chromium.png` for the 20 most
   interesting disagreements (resvg | Chromium | ours).

Commit often; push to your branch only; no PR. Do not change the renderer.

## Rules

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

## Report

**Files changed:**
- `tests/render_chrome.py` — rewritten around `render_batch()`/`render_batch_async()`
  (async Playwright, one browser launch, a page pool sized by `--jobs` pulling
  from a shared queue), an in-process entry point for callers that need
  collision-free output names. The CLI keeps its old `OUT WIDTH file...`
  contract and `<stem>.chrome.png` naming, gains `--jobs`. Fixed a real bug
  along the way: a literal `#` in a filename (8 files, all
  `painting/fill/*.svg`) was truncating the `<img src>` at the fragment, so
  Chromium silently rendered nothing for those files — now percent-encoded.
- `tests/run_corpora.py` — added `--ref {resvg,chrome,suite}` (default
  `resvg`, byte-for-byte unchanged). `chrome` prerenders every selected
  file's Chromium reference once per corpus/route batch
  (`prerender_chrome_refs`, external hrefs stripped first via the same
  `strip_external_refs` the resvg path already used) before the per-file
  scoring pass, instead of a subprocess per file. `suite` reads the
  resvg-test-suite's bundled PNG next to each SVG, resizing to the render
  width with PIL when it isn't already that size. Threaded `ref_mode`/
  `chrome_ref` through `render_one`, `run_corpus_route` and
  `write_worst_composites`; added `--ref` to the summary.md header.
- `tests/resvg_as_bin.py` (new) — adapts resvg's CLI to lean-svg's
  `bin SRC DST --width N` contract, so `run_corpora.py --bin
  tests/resvg_as_bin.py --ref chrome` scores resvg itself against Chromium
  through the *same* code path as scoring lean-svg — no separate "resvg vs
  the reference" plumbing needed for the third leg of the comparison.
- `tests/gen_a3_report.py` (new) — joins the three run CSVs plus the suite's
  `results.csv` into `docs/audit/A3-chromium.md` and builds the 20-file
  `resvg | Chromium | ours` comparison sheet; run commands are in its
  docstring.
- `docs/audit/A3-chromium.md`, `docs/audit/A3-chromium.png` (new) — the audit.

**Numbers** (whole resvg-test-suite corpus, 1679 files, direct route, 200 px):

| comparison | pass | pass% |
|---|---|---|
| ours vs resvg (default) | 1542/1679 | 91.8% |
| ours vs Chromium | 991/1679 | 59.0% |
| resvg vs Chromium | 1002/1679 | 59.7% |

ours-vs-Chromium tracks resvg-vs-Chromium (59.0% vs 59.7%), not ours-vs-resvg
(91.8%) — Chromium disagrees with both renderers in roughly the same places,
consistent with the disagreement being Chromium's, not lean-svg's distance
from a shared ground truth. Set A (ours≠resvg, ours=Chromium) is **empty**:
every file lean-svg disagrees with resvg on, it also disagrees with Chromium
on, at nearly the same within-8 — real lean-svg defects, not resvg-specific
interpretation differences. Set B (ours=resvg≠Chromium) is 551 files,
dominated by `text/*` (font hinting/rasterization: several subdirectories at
0% resvg-vs-Chromium agreement) plus real corners in filters (subregion
clipping, `feGaussianBlur`/`feSpotLight` edge parameters), masking
(`display:none` inside a referenced element), and a few `painting`/
`paint-servers` invalid-value-fallback cases. Cross-checked against the
suite's own manual `results.csv` chrome rating: 63.3% agreement with our
pixel metric over the 1618 rated files — full per-subdirectory numbers and
the false-positive breakdown (text 268, filters 97, structure 54, painting
39, masking 24, shapes 23, paint-servers 15) are in the doc. Both fidelity
harnesses are unaffected by these changes: `run_adversarial.py` 116/116
clean, `run_tests.py` 46/50 (baseline, no renderer code touched).

**Not done / left for Rowan:**
- `--ref suite` is implemented (bundled-PNG reference, resized with
  `Image.LANCZOS`) but not exercised at scale or validated against A1's
  intended use — A1 (`claude/audit-a1-pass-rules`, not yet pushed when this
  branch started) owns that investigation; this branch only had to keep the
  three-way `--ref` interface shared, per the task's note that another agent
  might add `suite` concurrently.
- The per-feature-directory tables cover the resvg-test-suite corpus only
  (`--corpus resvg`), not `simple-icons`/`feather` — those have no feature
  directories or suite PNGs, and are outside "the whole resvg suite" the
  task asks for.
- `--route usvg` was not run through `--ref chrome` (direct route only, to
  keep the audit to two Chromium batches' worth of wall-clock instead of
  four); the reference render for `usvg` route is on the original file
  either way (same as the `resvg` reference), so a rerun with `--route both`
  needs no code change, just time.

