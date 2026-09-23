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

