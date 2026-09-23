# T92 — newer CSS units and CSS basic shapes  (branch `claude/feat-css-units-shapes`)

Rowan's decision: implement **all** of them.

**Units** everywhere lengths are parsed (`Svg.lean` `parseTextLen`/
`parseLengthOrPercent`/`parseDashLengthAll` and friends): `vw`, `vh`,
`vmin`, `vmax`, `ch`, `ic`, `lh`, `rlh` (plus any other CSS Values 4 length
unit resvg lacks: `cap`, `rcap`, `rch`, `rex`, `ric`, `vi`, `vb`, and the
`sv*`/`lv*`/`dv*` viewport variants). Where the spec leaves a choice for a
standalone renderer (what "the viewport" is for `vw`; which font metrics
`ch`/`ic`/`lh` use), **follow Chromium** (`tests/render_chrome.py`) and
write the choice into `DESIGN.md`. `rem` already exists (T-R6).

**CSS basic shapes** for `clip-path` (and anywhere else SVG 2 accepts them):
`circle()`, `ellipse()`, `inset()` (with `round`), `polygon()` (with fill
rule), `path()`, `rect()`, `xywh()`, and the reference box keywords
(`fill-box`, `stroke-box`, `view-box`, …). Bounded like everything else
(point count caps). Research: `docs/resvg-wrong/R7-structure-masking.md`
(circle-shorthand files) and `R6-shapes-paint.md` (units).

**Scoring:** these are mostly features resvg does not implement, so the
reference is Chromium (and the suite PNG where it exists and agrees). Guard
rail: zero pass→fail on resvg-correct files at both widths against live
resvg. Add `tests/svg/92_*.svg` files covering each unit and shape, and
report their Chromium scores.

---

## Common rules (every lean-svg agent)


**Branches (Rowan's rule).** Push only to the one branch this task names.
The integrator merges it into `claude/beautiful-brown-nd2o1h` and then
deletes it, so do not create any other branch, tag or pull request. You may
use subagents inside your own session for research or parallel work; they
must not push anywhere; you collect their work into your branch.

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

## Spec implemented

**Units** (`LeanSvg/Units.lean`, hooked into `Svg.parseTextLen`, so every
geometry length, text `x/y/dx/dy`, `stroke-width`, dashes, `rx/ry`, plus
`font-size` and `letter-/word-spacing` via `Svg.applyNewUnit`):
`vw vh vmin vmax vi vb` and all `sv*`/`lv*`/`dv*` variants; `ch ic cap lh`;
`rch ric rcap rlh rex` (`rem`, `Q` already existed). Choices, all measured
against Chromium through `tests/render_chrome.py` and written into
`DESIGN.md` §3.12:

- viewport = the **output canvas in px**, taken as user units (Chromium's
  `<img>` viewport: `vw-and-vh-values.svg` at width 100 puts `5vw` at 5 user
  units, at width 400 at 20). Computed by `Render.outSize` from the root
  before `interpret` (`SubCfg.outSize`); natural size when the root has no
  usable size or for nested SVG images;
- font metrics from embedded Noto Sans regular: `ch` = advance of `0`,
  `ic` = `1em` (no `水` in the subset), `cap` = `sCapHeight`, `lh` =
  Chromium's rounded `LineSpacing` (`line-height` property not read), `rex`
  = x-height; `ex` stays usvg's `0.5em` for resvg compatibility.
  `Style.rootFontSize` became a `Units.RootLen` (root size + canvas) instead
  of adding a parameter to every parser (no renames).

**Basic shapes** (`LeanSvg/BasicShape.lean`) in `clip-path`: `circle()`,
`ellipse()`, `inset()`, `rect()`, `xywh()` (with `round` radii incl. `/`),
`polygon()` and `path()` (with fill rule), box keyword alone, reference boxes
`fill-box`/`stroke-box`/`view-box` and the CSS aliases
(`content`/`padding` → fill, `border`/`margin`/default → stroke). Each use
becomes a synthetic one-child `ClipEntry` built at the end of `interpret`
(like T48's viewport clips), so `Clip.lean` is unchanged. `stroke-box` is the
exact stroked-outline bounds (`Geom.strokePoly`), tracked in a new
`Frame.sbox` only while a stroke-box shape is in force; groups union their
children. Caps: 10 000 polygon points, 100 000 path commands. Grammar details
(unitless numbers ok, case-insensitive, 3-value positions / two box keywords /
negative radii invalid → no clip) were each probed in Chromium.

## Skipped, and why

- Units in context-free parsers (`parseLengthOrPercent`: root/nested `svg`,
  `image`, marker/pattern geometry): they have no style context; the root's
  own `width="50vw"` is circular anyway. Unchanged behaviour (skip).
- `line-height` property for `lh`/`rlh`: only `normal` exists here.
- Per-weight/italic metrics for `ch`/`cap`: regular face only.
- Default font size stays usvg's 12 px (Chromium 16 px), so `em`-based shape
  lengths differ from Chromium only where no `font-size` is set.
- Basic shapes outside `clip-path` (`shape-outside`, `offset-path`): not an
  SVG renderer feature. A basic shape as a `<clipPath>` element's *own*
  `clip-path` is ignored (as before).
- `calc()` and the newer `shape()` function.

## Report

Files: `LeanSvg/Units.lean` (new), `LeanSvg/BasicShape.lean` (new),
`LeanSvg/Svg.lean`, `LeanSvg/Render.lean` (`outSize`), `LeanSvg/Marker.lean`
(one constructor), `LeanSvg.lean`, `proofs/SizeBound.lean` (the case split
follows `render`'s `interpretWith` call; statement unchanged),
`tests/svg/92_css_units.svg`, `tests/svg/92_basic_shapes.svg`,
`tests/UnitsTests.lean` (`#guard`s; `lake env lean tests/UnitsTests.lean`
prints nothing), `DESIGN.md` §3.12.

Checks: `lake build` no warnings; `check-theorems.sh` → `theorems ok`;
`run_adversarial.py` 137/137 clean; `run_tiles.py` 61/61 byte-identical;
`run_tests.py` 55/61 (was 55/59): no existing file's score changed, the two
new `92_*` files fail against resvg only because resvg lacks the features.

Corpus vs live resvg (`--route direct`):

| width | pass before | pass after | resvg-correct before → after | pass→fail |
|---|---|---|---|---|
| 100 (`--fast`) | 1553 | 1543 | 1418/1522 → 1418/1522 | 10, none resvg-correct |
| 200 | 1578 | 1568 | 1440/1522 → 1440/1522 | 10, none resvg-correct |

The 10 movers (same set at both widths) are exactly the target files, where
resvg draws nothing / no clip: `shapes/rect/{ch,ic,lh,rlh,vi-and-vb,
vmin-and-vmax,vw-and-vh}-values.svg` (resvg "known wrong"/unrated) and
`masking/clipPath/circle-shorthand{,-with-view-box,-with-stroke-box}.svg`.
Zero pass→fail on resvg-correct files at either width.

Chromium scores (within-8, same width; Chromium given the real Noto Sans via
an injected `@font-face` because this container has none):

| file | 100 px | 200 px |
|---|---|---|
| `vw-and-vh`, `vmin-and-vmax`, `vi-and-vb`, `ic`, `lh`, `rlh`, `cap` | 99.96 | 99.99 |
| `ch-values` | 98.31 | 98.34 |
| `circle-shorthand` | 97.66 | 99.00 |
| `circle-shorthand-with-view-box` | 99.48 | 99.76 |
| `circle-shorthand-with-stroke-box` | 98.06 | 99.28 |
| `tests/svg/92_css_units.svg` | 96.19 | 97.21 (98.30 at natural size) |
| `tests/svg/92_basic_shapes.svg` | 97.03 | 98.67 (99.22 at natural size) |

The remaining Chromium differences are rasterization, not geometry: `ch-values`
has the rect edge exactly at x = 18.304 in both, but our (resvg-compatible)
4× supersampling gives coverage 0.75 where Chromium gives 0.70;
`circle-shorthand` differs from Chromium by the same ~375 px as a plain
`<circle r=80>` does; the `92_*` files add glyph rasterization. Unit values
match Chromium-with-Noto to within 0.1 px (`10ch` 57.25/57.2, `10cap`
71.5/71.4, `10lh` 140/140, `10rlh` 270/270, `10rex` 107.25/107.2), and every
basic-shape probe's clip bbox matched Chromium to within 1 px.
Against the suite PNGs `circle-shorthand.svg`, `ch-values`, `cap-values`,
`vw`/`vmin` pass; `ic`/`lh`/`rlh`/`vi-and-vb` and the two circle box variants
disagree with the suite PNG, which itself disagrees with Chromium there
(R6/R7 notes).
