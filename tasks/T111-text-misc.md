# T111 — Remaining resvg-suite text failures  (branch `claude/fix-text-misc`)

resvg-correct files that fail (within-8 at 200 px):

text/letter-spacing/non-ASCII-character.svg 98.4%
text/text-decoration/underline-with-rotate-list-4.svg 98.6%
text/text-rendering/optimizeSpeed.svg 98.9%, text/text-rendering/with-underline.svg 98.5%
text/text/real-text-height.svg 98.9%
text/textPath/dy-with-tiny-coordinates.svg 94.1% (Rowan asked for this one earlier)
text/textPath/writing-mode=tb.svg 96.2%
text/writing-mode/japanese-with-tb.svg 94.0% (Rowan: Japanese must not be rotated in tb)

Diagnose each against usvg/resvg 0.48.1 (`crates/usvg/src/text/*`,
`crates/resvg/src/text.rs` era code in usvg), fix those that are small and
local, and report cause + proposed fix for the rest.

---

## Round 7 rules (read with the common rules below)

- **Short task, hard timebox: about 2 hours of work.** Fix what is clearly
  ours and bounded; for anything bigger, write down the cause, the fix you
  would make and its size in the report, push, and end. Do not start
  rewrites.
- **No speed work.** Do not optimise or restructure hot paths; Rowan will
  run the speed phase later. A fix must not slow the suite down noticeably
  (`scratchpad`-style timing: `run_corpora.py` wall time within ~5%).
- **Pass criteria** (`tests/criteria.csv`, `docs/DECISIONS.md`): a file's
  reference is resvg where resvg is correct, Chromium where resvg is wrong
  and Chromium is right, otherwise Rowan's verdict. Do not change
  `criteria.csv` or `realworld_verdicts.csv`; if you believe a file's
  reference is wrong, say so in the report with evidence.
- **Behaviour that must not change:** one input file read; at most the PNG
  and (with `--warnings`) `<out>.warnings.txt` written, no-clobber; nothing
  on stdout/stderr; exit codes as in `docs/DECISIONS.md`; no external
  resource ever loaded. `tests/run_adversarial.py` must stay all clean.
- **Real-world corpus vs Chromium:**
  `python3 tests/run_corpora.py --corpus realworld --ref chrome --out /tmp/rw --no-worst`
  (Chromium is preinstalled; `tests/render_chrome.py` renders references).
  When you look at our PNGs, composite them on white first: they are
  transparent, and an image viewer shows transparency as black.
- Fonts: only permissively licensed fonts (OFL, Apache, Bitstream Vera or
  equally permissive), verified upstream, licence text in `LeanSvg/Fonts/`,
  credits in `NOTICE` and README "Licensing and credits". Keep the binary
  under 75 MB (now ~46 MB).

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

### Fixed (4 of 8 targets, plus 5 other files)

1. **`text-rendering`** (`LeanSvg/Svg.lean`). New inherited `Style.textCrisp`
   is set by `text-rendering: optimizeSpeed` and cleared by
   `auto`/`optimizeLegibility`/`geometricPrecision`. An invalid value keeps the
   inherited one. Text runs take `crisp` from the `<text>` element's style, as
   in usvg `text/flatten.rs::resolve_rendering_mode`
   (OptimizeSpeed → CrispEdges). Before this, text was always antialiased.
   Decorations are text runs, so they follow the same flag. Fixes
   `text-rendering/optimizeSpeed.svg` and `text-rendering/with-underline.svg`.
2. **`objectBoundingBox` paint on text** (`Svg.lean`, `Render.lean`). The new
   field `Shape.paintBox : Option Box` (default `none`) overrides the box that
   `Render.paintSpace` passes to `Grad.build`/`Pat.build`. Every text run
   carries its `<text>` element's font-metric box (`mbox` from `Text.layout`,
   the box T81 already uses for filters and masks). This matches usvg
   `paint_server.rs`, where the fill, stroke and decorations of every span use
   `text.bounding_box`, not the glyph outlines. Before, each run used the
   bounds of its own outline. Fixes `text/real-text-height.svg` and
   `text-decoration/underline-with-rotate-list-4.svg`, and also fixes
   `painting/{fill,stroke}/radial-gradient-on-text.svg`,
   `text/tspan/tspan-bbox-{1,2}.svg` and `text/tspan/bidi-reordering.svg`. This
   is the fix T55 described but did not make. It needed only one optional
   field and a one-line change in `paintSpace`, not a change to
   `Shader.build`. Only runs with plain paint use `outK > 1`, so `mbox` and
   the run's CTM are always in the same user space.
3. Test `tests/svg/111_text_misc.svg` covers both fixes: 99.83 % pass vs resvg.

### Not fixed: resvg 0.48.1's reference is blank (3 files, reference questionable)

`text/letter-spacing/non-ASCII-character.svg`,
`text/writing-mode/japanese-with-tb.svg` and `text/textPath/writing-mode=tb.svg`
all use unquoted `font-family="Mplus 1p"`. resvg 0.48.1 logs `Failed to parse
font-family value: 'Mplus 1p'. Falling back to Times New Roman.` and then
**draws no text at all**, so the reference contains only the crosshair/path
and the frame. Our score of 94–98 % is simply the glyph area; the only way to
pass is to draw nothing. Our output matches the suite's own PNGs, compared at
500 px, the suite's size:

| file | ours vs resvg 0.48.1 (200 px) | ours vs suite PNG (500 px) | glyph bbox vs suite (200 px) |
|---|---|---|---|
| letter-spacing/non-ASCII-character | 98.43 % | 98.60 % | identical |
| writing-mode/japanese-with-tb | 94.03 % | 97.96 % | 1 px higher |
| textPath/writing-mode=tb | 96.15 % | 97.28 % | ≤ 1 px |

- `japanese-with-tb`: the glyphs are upright, not rotated, as Rowan asked.
- `non-ASCII-character`: `letter-spacing` is correctly not applied, because
  usvg skips the last cluster, and 半 is centred as in the suite.
- The remaining differences from the suite are about 1 px of glyph position
  and weight (antialiasing and hinting of the suite renderer). They are
  sub-pixel and not worth chasing.
- **Proposal:** switch these three rows in `criteria.csv` from `resvg` to
  `suite` (or `human`). The suite marks resvg "correct" only because an older
  resvg parsed the family; 0.48.1 regressed. Not edited here, per the rules.
  T102 already flagged `writing-mode=tb` for the same reason.
  `tests/corpora/resvg-test-suite/tests` has 9 files that use `Mplus 1p`, and
  the other six may be affected the same way.

### Not fixed: `text/textPath/dy-with-tiny-coordinates.svg` (94.1 %)

T96 diagnosed this and nothing has changed since. Inputs are rounded to 1/256
user unit at parse time, and the file draws inside `scale(100)`:

- `font-size="0.24"` → 61/256, which is −0.7 % and accumulates along the path.
- `dy` and the path points are also rounded.
- `stroke-width="0.01"` → 3/256, 17 % too thick. The two gray strokes alone
  cap the file at about 98.5 %.

Fix I would make: carry 16.16 precision for font size, position lists and
the textPath path parse (`Svg.lean` cascade `applyProp "font-size"`,
`elemPosOf`, `textPathTables`), and use a finer stroke width
renderer-wide. **Size:** shared-cascade and renderer-wide changes of several
hundred lines touching every shape's stroke. That is too big for this
round's timebox, so I did not start it.

### Numbers

`run_corpora.py --corpus resvg --route direct` (ref resvg):

| | before | after |
|---|---|---|
| fast (100 px) | 1543 / 1679 pass | 1552 / 1679 (+9, 0 newly failing) |
| default (200 px) | 1567 / 1679 pass | 1573 / 1679 (+6, 0 newly failing) |
| `text/**` at 200 px | 328 / 371 | 332 / 371 |
| `text/**` at 100 px | 325 / 371 | 332 / 371 |
| 200 px wall time | 17.5 s | 17.3 s |

Only the 9 files listed under "Fixed" moved by more than 0.1 points of
within-8, and all of them went up.

Target files, 200 px within-8:

| file | before | after |
|---|---|---|
| text-rendering/optimizeSpeed | 98.93 % fail | 99.99 % pass |
| text-rendering/with-underline | 98.51 % fail | 99.98 % pass |
| text/real-text-height | 98.86 % fail | 99.98 % pass |
| text-decoration/underline-with-rotate-list-4 | 98.63 % fail | 99.97 % pass |
| letter-spacing/non-ASCII-character | 98.4 % fail | unchanged (blank reference) |
| writing-mode/japanese-with-tb | 94.0 % fail | unchanged (blank reference) |
| textPath/writing-mode=tb | 96.2 % fail | unchanged (blank reference) |
| textPath/dy-with-tiny-coordinates | 94.09 % fail | unchanged |

Other checks:

- `lake build`: clean, no warnings.
- `check-theorems.sh`: `invariants ok`, `theorems ok`.
- `run_tests.py`: 64/81, was 63/80. The new file passes; no existing file's
  score changed.
- `run_adversarial.py`: 171/171 clean.
- `run_tiles.py`: 81/81 byte-identical.
- Real-world corpus vs Chromium, before and after binaries: 260/848 direct
  and 261/848 usvg both times; no file's within-8 moved by more than 0.1
  points. Wall time 5 m 3 s before, 5 m 7 s after.

Commits: `text-rendering: optimizeSpeed …`, `text: objectBoundingBox paint …`,
`tests: 111_text_misc …`, and this report.
