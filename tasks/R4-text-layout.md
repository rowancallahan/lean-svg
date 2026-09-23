# R4-text-layout — resvg-wrong research: text layout: textPath, text, tspan  (branch `claude/research-r4-text-layout`)

## Why

resvg's own `results.csv` marks resvg as **wrong** on the files below. Our
harness scores against live resvg, so where we "pass" we are copying resvg's
mistake. Rowan does not want that. Before anyone fixes these, we need a
written, per-file understanding of what the correct output is, so later fix
work (Opus agents, and decisions with Rowan) goes quickly.

This task is mainly **information gathering and review**. It is not a
feature task.

## What to do, per file

1. Render four ways at 200 px wide: ours (`.lake/build/bin/lean-svg f out
   --width 200`), resvg (`resvg --skip-system-fonts --use-fonts-dir
   tests/corpora/resvg-test-suite/fonts -w 200`), the suite's own PNG next to
   the SVG (resize to 200 wide if needed), and Chromium
   (`python3 tests/render_chrome.py OUT 200 file.svg`).
2. Read the SVG: its `<title>`, comments and structure say what it tests.
   Read the relevant spec section (SVG 1.1/2, Filter Effects, CSS). Search
   the resvg GitHub issues/changelog for the test or feature
   (`https://github.com/linebender/resvg`); note links.
3. Decide what the **correct** output is and why, and which reference(s) show
   it (suite PNG, Chromium, spec reasoning). Say how confident you are.
   Browsers can be wrong too; the `results.csv` columns for other renderers
   are hints (1 = passes, 2 = fails, 0 = untested, 3 = crash).
4. Classify it: **(a)** shallow fix (a few lines, clear evidence), **(b)**
   needs a feature or real work (estimate size), **(c)** deliberately not
   supported (deprecated, or conflicts with Rowan's safety rules: no external
   resources, pure total functions, bounded work), **(d)** needs a decision
   from Rowan (write the question and the options).

## Deliverables

- `docs/resvg-wrong/R4-text-layout.md`: one section per file with the above, then a
  summary table (file, class, correct reference, one-line cause), then a
  "Questions for Rowan" list.
- `docs/resvg-wrong/R4-text-layout.png`: one comparison sheet, a row per file:
  resvg | suite PNG | Chromium | ours, labelled. Keep it under 2 MB.
- **Shallow fixes (class a) are allowed** only when the suite PNG and
  Chromium agree with each other and with the spec. Put each fix in its own
  commit with the evidence in the message. The fix must keep every file resvg
  renders correctly passing: run the corpus gate below and report zero
  pass→fail on files where `results.csv` says resvg=1. (Those fixed files
  will now "fail" against resvg in our harness; list them in the doc.)

Commit early and often (the doc can be pushed in pieces); push to your branch
only. No pull request.

## Files (16)

| file | our status vs resvg (200 px) | other renderers |
|---|---|---|
| `text/text/complex-graphemes-and-coordinates-list.svg` | fail 0.980875 | chrome=2 firefox=1 safari=2 |
| `text/text/compound-emojis-and-coordinates-list.svg` | fail 0.925575 | chrome=2 firefox=1 safari=2 |
| `text/text/compound-emojis.svg` | fail 0.976550 | chrome=1 firefox=1 safari=1 |
| `text/text/emojis.svg` | fail 0.902475 | chrome=1 firefox=1 safari=1 |
| `text/text/xml-lang=ja.svg` | fail 0.858025 | chrome=1 firefox=1 safari=2 |
| `text/textPath/method=stretch.svg` | pass 0.997250 | chrome=2 firefox=2 safari=2 |
| `text/textPath/side=right.svg` | pass 0.997250 | chrome=2 firefox=1 safari=2 |
| `text/textPath/spacing=auto.svg` | pass 0.997250 | chrome=2 firefox=2 safari=2 |
| `text/textPath/with-filter.svg` | pass 0.994500 | chrome=1 firefox=2 safari=1 |
| `text/textPath/with-invalid-path-and-xlink-href.svg` | pass 0.999950 | chrome=2 firefox=2 safari=2 |
| `text/textPath/with-path-and-xlink-href.svg` | pass 0.999950 | chrome=2 firefox=1 safari=2 |
| `text/textPath/with-path.svg` | pass 0.999950 | chrome=2 firefox=1 safari=2 |
| `text/tspan/with-clip-path.svg` | pass 0.999750 | chrome=1 firefox=2 safari=1 |
| `text/tspan/with-filter.svg` | pass 0.999750 | chrome=1 firefox=2 safari=1 |
| `text/tspan/with-mask.svg` | pass 0.999750 | chrome=1 firefox=2 safari=1 |
| `text/tspan/with-opacity.svg` | pass 0.999825 | chrome=1 firefox=1 safari=1 |

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


**Corpus gate for any code change:** `python3 tests/run_corpora.py --corpus resvg --route direct --out /tmp/after --no-worst --compare <baseline csv>` (make the baseline first without your change) and `python3 tests/score_known.py /tmp/after/resvg_direct.csv`; plus `lake build`, `bash scripts/check-theorems.sh`, `tests/run_tests.py`, `tests/run_adversarial.py`, `tests/run_tiles.py`.
