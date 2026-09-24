# T102 — Fixes from Rowan's human review  (branch `claude/fix-review`)

Rowan judged the 76 files with no trusted reference
(`tests/human_verdicts.csv`, notes included; docs/DECISIONS.md "Human
review"). Fix these, each against the reference named (Chromium via
`tests/render_chrome.py` / `run_corpora.py --ref chrome`, suite PNG via
`--ref suite`):

1. **Invalid (singular) transforms draw nothing**, like Chromium:
   `paint-servers/{linearGradient,radialGradient}/invalid-gradientTransform.svg`,
   `paint-servers/pattern/invalid-patternTransform.svg` (`matrix(0 0 0 0 0 0)`).
   The paint becomes `none` (the shape's stroke still draws).
2. **Markers on multi-subpath paths:** `painting/marker/target-with-subpaths-2.svg`
   — follow Chromium (which vertices get start/mid/end markers when a subpath
   is closed and another starts; ours puts a dark-blue start marker where
   Chromium shows the mid marker blended over it). Keep `painting/marker/*`
   resvg-correct files passing.
3. **`text/textPath/complex.svg`:** vertical (`writing-mode="tb"`) Japanese
   text on a circular `textPath` with `startOffset=-10`, overline and
   letter-spacing: draw it along the path like Chromium; today almost nothing
   shows.
4. **`text/direction/rtl-with-vertical-writing-mode.svg`:** place the text
   like Chromium (centred on the column at x=100); today it is shifted and
   runs off the canvas.
5. **`text/text/complex-graphemes-and-coordinates-list.svg`:** follow the
   suite PNG (x/y lists apply per grapheme cluster).
6. **`filters/fePointLight/primitiveUnits=objectBoundingBox.svg`:** the lit
   circle should be lighter, like the suite PNG (check how `x/y/z` resolve
   under objectBoundingBox, including `z`).
7. **Negative `font-size`** (`text/font-size/negative-size.svg`): keep
   drawing nothing, and report a warning through T98/T98b's warnings
   mechanism.

T101 (spotlight soft edge, `xml:lang` fonts) runs concurrently and edits the
lighting code: keep item 6 local and small. After fixing, rerun
`tests/score_criteria.py` (human verdicts included) and report which of the
10 `fail` verdicts you believe are now fixed, with images, so Rowan can
re-review; do not edit `tests/human_verdicts.csv` yourself. Add
`tests/svg/102_*.svg` cases.

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

### What was implemented (one commit per item)

1. **Invalid paint transforms draw nothing** (`LeanSvg/Svg.lean`,
   `singularMat`). A `gradientTransform`/`patternTransform` with a
   zero-length column now becomes the zero matrix (it used to become the
   identity, as in usvg). `Grad.build` and `Pat.build` already skip a
   singular matrix, so the fill is `none`. The stroke still draws.
   Matches Chromium on all three files.
2. **Markers on multi-subpath paths** (`LeanSvg/Marker.lean`). A closepath
   directly followed by a `moveTo` is now a mid vertex at its subpath's
   start, as in Chromium. usvg skips it. Its `orient="auto"` angle bisects
   the closing line and the subpath's first segment (`subpathFirstOut`).
   Repeated closes (`M L L Z Z Z`) stay skipped, so
   `orient=auto-on-M-L-L-Z-Z-Z.svg` is unchanged. All 62 other
   `painting/marker/*` files are unchanged at 200 px.
3. **Vertical text on a `textPath`** (`Svg.lean`, `Text.lean`). A
   `textPath` under a vertical `writing-mode` was dropped whole. It is now
   laid out along the path:
   - An upright cluster (CJK, `VertOrient.isUpright`) turns −90° against
     the path direction and is centred on the path.
   - A sideways cluster sits like horizontal path text, shifted onto the
     column centre by usvg's `(ascent + descent) / 2`.

   Decorations on any path text are now drawn as one piece per cluster,
   in that cluster's frame on the path (`decorRectOn`). Before, path text
   drew one straight run from the chunk origin. That run was the stray
   black line at the top-left in `textPath/with-underline.svg`. Side
   effect: `with-underline.svg` goes from fail to pass against resvg.
4. **`rtl` with vertical `writing-mode`** (`Text.lean`). `direction: rtl`
   now swaps `start` and `end` in vertical text too. So a `start`-anchored
   vertical run ends at its `y`, as in Chromium: centred on x=100 and
   ending at y=150. Glyphs still run top to bottom. Bidi reordering stays
   horizontal-only.
5. **Coordinate lists per grapheme** (`Text.lean`). A nonspacing mark's
   own `x`/`y`/`dx`/`dy` entries are cleared. They are ignored, not
   shifted onto the next character. The mark therefore stays in its base's
   chunk and cluster. `complex-graphemes-and-coordinates-list.svg` now
   matches the suite PNG (й on the crosshair, y=120 ignored).
6. **`fePointLight` with `primitiveUnits=objectBoundingBox`: no code
   change.** `x`, `y` and `z` already resolve correctly (`z` × the
   normalised bbox diagonal: 0.2 × 160 = 32). A Chromium render with the
   equivalent user-space light (`x=100 y=148 z=32`) matches ours. Swapping
   in z = 45, 64, 100 or 160 moves it far from the suite PNG.
   - The difference Rowan saw is scale. The suite PNG is 500 px, and
     lighting surface normals are computed per device pixel. At 200 px the
     alpha slope per pixel is 2.5× steeper, so the ring looks darker.
   - Rendered at 500 px, ours matches the suite PNG (mean |Δ| 0.02 on
     0–255). Chromium at 500 px is further off (mean |Δ| 2.5). See
     `T102/fePointLight_obb_at_500px.png`.
7. **Negative `font-size`** (`Svg.lean`, `Warn.lean`). The text is still
   not drawn. It now also adds the warning `negative font-size; text not
   drawn` (exit code 2, and a line in `<out>.warnings.txt` under
   `--warnings`). `tests/check_warnings.py` has a case for it.

Tests: `tests/svg/102_invalid_paint_transform.svg` (items 1, 2) and
`tests/svg/102_vertical_text.svg` (items 3, 4, 5, 7). Both follow
Chromium or the suite, not resvg, so `run_tests.py` scores them as fail
against resvg by design, like `99_feoffset_subregion.svg`.

### The 10 `fail` verdicts: status for re-review

Images are in `tasks/T102/<dir>_<file>.png`. Each shows lean-svg after
T102, then Chromium, then the suite PNG, all at 200 px.

| file | status |
|---|---|
| `paint-servers/pattern/invalid-patternTransform.svg` | **fixed**: fill is none, stroke drawn, same as Chromium |
| `paint-servers/radialGradient/invalid-gradientTransform.svg` | **fixed**: draws nothing, same as Chromium |
| `painting/marker/target-with-subpaths-2.svg` | **fixed**: the start vertex now also gets the mid marker blended over it, same as Chromium |
| `text/direction/rtl-with-vertical-writing-mode.svg` | **fixed**: centred on the x=100 column, ends at y=150, same as Chromium. Chromium's glyphs are smaller because it fell back to a serif face |
| `text/text/complex-graphemes-and-coordinates-list.svg` | **fixed**: matches the suite PNG |
| `text/textPath/complex.svg` | **fixed, differs in detail**: the text is drawn along the circle with an overline along the path. Chromium hides the first two glyphs (startOffset −10) and puts "スト。" on the left, where we continue it down from the path's end. Chromium also colours the overline red from the `<g>`, while ours and resvg use the text's black (a separate, existing difference, also in horizontal text) |
| `filters/fePointLight/primitiveUnits=objectBoundingBox.svg` | **not changed, needs Rowan**: correct at the suite's own 500 px (see item 6). Please re-judge at 500 px or keep |
| `filters/feSpotLight/complex-transform.svg` | T101's (not touched here) |
| `filters/feSpotLight/limitingConeAngle-anti-aliasing.svg` | T101's (not touched here) |
| `text/text/compound-emojis-and-coordinates-list.svg` | emoji, "later" per DECISIONS (not touched) |

Also: `paint-servers/linearGradient/invalid-gradientTransform.svg` (was a
`pass` with a doubt) now draws nothing too, and `text/font-size/negative-size.svg`
(`pass`) now reports the warning.

### Numbers

`run_corpora.py --corpus resvg --route direct --ref resvg`:

| | before | after |
|---|---|---|
| fast (100 px) | 1552 / 1679 pass | 1547 / 1679 pass |
| default (200 px) | 1576 / 1679 pass | 1571 / 1679 pass |

The same 10 files moved at both widths. Nothing else moved by more than
0.1 points.

| file | 200 px within-8 | resvg status | reference in criteria.csv |
|---|---|---|---|
| linearGradient/invalid-gradientTransform | 100.0 → 36.0 | pass → fail | human (intended, Chromium) |
| radialGradient/invalid-gradientTransform | 100.0 → 36.0 | pass → fail | human (intended, Chromium) |
| pattern/invalid-patternTransform | 99.6 → 68.1 | pass → fail | human (intended, Chromium) |
| direction/rtl-with-vertical-writing-mode | 99.98 → 93.3 | pass → fail | human (intended, Chromium) |
| textPath/complex | 99.4 → 95.1 | pass → fail | human (intended, Chromium) |
| **textPath/writing-mode=tb** | 99.995 → 96.2 | **pass → fail** | **resvg** (see below) |
| text/complex-graphemes-and-coordinates-list | 99.99 → 99.6 | pass → pass | human (suite) |
| marker/target-with-subpaths-2 | 100.0 → 99.65 | pass → pass | human (Chromium) |
| textPath/with-underline | 97.96 → 99.69 | fail → **pass** | resvg |
| text/compound-emojis-and-coordinates-list | 91.6 → 91.7 | fail → fail | human |

**The one pass→fail on a resvg-reference file: `text/textPath/writing-mode=tb.svg`.**
- resvg 0.48.1 has no vertical text on a path, so its reference is blank
  (`criteria.csv` lists it as resvg=1 "correct").
- Item 3 now draws the text, and it matches the suite's own PNG more
  closely than before: `--ref suite` within-8 96.77 → 97.19%, and the
  image `T102/text_textPath_writing-mode=tb.png` shows the same shape.
  Chromium draws it differently, with sideways, overlapping glyphs.
- This is unavoidable with item 3: the SVG structure is the same as
  `textPath/complex.svg`.
- Item 3 is its own commit ("vertical text on a textPath"). If Rowan
  prefers resvg's blank output there, reverting that one commit restores
  both files, and `with-underline`'s gain goes with it.
- Otherwise, `criteria.csv` could switch this file's reference to `suite`
  or `human`. That is Rowan's call, so it is not edited here.

`tests/score_criteria.py` (`--resvg-csv` 200 px, `--chrome-csv` a
`--ref chrome` run over the chrome/human files, `--local-json`):

- resvg bucket: 1528 / 1587 before and after (`writing-mode=tb` fail and
  `with-underline` pass cancel out).
- chrome bucket: 19 / 45 after.
- human bucket: 66 pass / 10 fail. It is scored from
  `tests/human_verdicts.csv`, which T102 does not edit, so it only changes
  once Rowan re-reviews the files above.
- Overall: 1613 pass / 95 fail, the same before and after.

Other checks:
- `lake build`: clean, no warnings.
- `bash scripts/check-theorems.sh`: `invariants ok`, `theorems ok`
  (`proofs/SizeBound.lean` untouched).
- `run_tests.py`: 60/73. It was 60/71; the two new files are the
  `102_*` cases above. No existing file's score dropped.
- `run_adversarial.py`: 149/149 clean.
- `run_tiles.py`: 73/73 byte-identical.
- `check_warnings.py`: `warnings ok`.

### Not done / notes

- Item 6 has no code change (above). It needs Rowan to re-judge at
  500 px.
- For the text after a vertical `textPath`, we continue from the path's
  end, as horizontal text does. Chromium puts it somewhere else again. Left
  as is.
- The decoration fill from an ancestor `<g>` (red in Chromium, black in
  resvg and ours) is unchanged. It is resvg-consistent and out of scope.
