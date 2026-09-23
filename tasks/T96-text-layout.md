# T96 — Text layout bugs: textPath, vertical text, rotate  (branch `claude/fix-text-layout`)

Rowan reviewed the failure report and wants these fixed. Reference: resvg
where `results.csv` rates it correct (all of these), Chromium as a sanity check.

Files (`tests/corpora/resvg-test-suite/tests/`):
- `structure/transform-origin/on-text-path.svg`: the text should sit on the
  path. The path's own rendering honours `transform-origin` but the textPath
  layout does not, so the text is moved off-canvas.
- `text/textPath/dy-with-tiny-coordinates.svg`: the glyph placement drifts
  (fixed-point precision at tiny scales). Keep integer arithmetic; widen or
  rescale intermediates so tiny user units keep enough precision.
- `text/writing-mode/mixed-languages-with-tb.svg`: in vertical text the
  Japanese characters must stand upright (not rotated) per the
  `text-orientation: mixed` rules usvg applies; Latin runs rotate.
- `text/writing-mode/mixed-languages-with-tb-and-underline.svg`,
  `text/writing-mode/tb-with-rotate-and-underline.svg`: the underline must
  follow the vertical column, not be one long horizontal line.
- `text/text/rotate-with-multiple-values-and-complex-text.svg`: a cluster
  renders as a garbled blob; check how the `rotate` list is indexed for
  clusters with combining marks (usvg indexes per character/cluster).

`LeanSvg/Text.lean` is shared with T97 (font styles) running at the same
time: keep your changes local to the layout/decoration/textPath code and
avoid reformatting. Add `tests/svg/96_*.svg` cases.

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

## Spec implemented

- **textPath and `transform-origin`** (`Svg.textPathTables`): the linked
  shape's `transform` is wrapped with its own `transform-origin`
  (`wrapTransformOrigin`, same viewport rect as everywhere else), as usvg's
  `resolve_text_flow` → `resolve_transform` does.
- **Vertical text, upright clusters** (`LeanSvg/VertOrient.lean`, new):
  the `Vertical_Orientation=U` ranges of the `unicode-vo` 0.1.0 crate usvg
  uses (123 merged ranges, checked to have no conflicting overlaps). In
  `Text.layout` an upright cluster gets usvg's `path_transform`
  `T(w/2,0)·R(-90)·T(-w/2,h)`: linear part `R(rotate)`, origin at
  `(x,y) + R(rotate)·(w/2+h, w/2)` before the column turn; its metric box is
  `width` tall and centred. Everything else (Latin, Arabic, `Tu`/`Tr`) keeps
  the sideways branch.
- **Vertical decorations**: a run starts at the cluster's own transform
  (with the `(ascent+descent)/2` shift for sideways clusters, without it for
  upright ones), turned 90° with the column; underline/overline sit at
  ±`(ascent−descent)/2`, line-through at 0 (usvg's `TopToBottom` offsets).
- **Combining marks** (unshaped path only): a character of bidi class NSM
  joins the preceding cluster (same font and style), so it uses that
  cluster's `rotate`/`dx`/`dy` slot and turns with it. With no GPOS anchors
  in the embedded Noto Sans, the mark is centred horizontally over the base
  glyph's point extents (HarfBuzz's fallback mark position, x only).
- **Tiny user units under a large scale**: when the `<text>` CTM scale is
  ≥ 16 and every run paint is solid/none, `Text.layout` emits outlines and
  decorations at `outK` (power of two ≤ scale, ≤ 256) times user space and
  the shapes are drawn through `ctm · scale(1/outK)` (stroke width and dashes
  scaled by `outK`). Pen positions were already 16.16; this removes the
  1/256-user-unit rounding of every outline point.

## Skipped / not fixed

- `text/textPath/dy-with-tiny-coordinates.svg` still fails (91.1→91.4 % at
  100 px, 93.9→94.1 % at 200 px). Measured causes:
  - the remaining glyph drift (up to 0.8 px along the path, 0.3 px across)
    comes from *inputs* rounded to 1/256 user unit at parse time:
    `font-size="0.24"` → 61/256 (−0.7 %, which accumulates over the
    advances), `dy`, and the path's own points. With all inputs made exactly
    representable, our positions match usvg to < 0.07 px;
  - even then the file can't pass: the two gray path strokes alone score
    98.5 % (`stroke-width="0.01"` → 3/256, 17 % too thick), and text only
    with exact inputs reaches 98.3 %.
  Fixing the inputs needs a finer font size in `Style` (e.g. a 16.16 value
  alongside `fontSize`, set in the `font-size` branch of `applyProp`),
  16.16 position lists in `elemPosOf`, and a 16.16 path parse for
  `textPathTables`. All of that is shared `Svg.lean` cascade code, and T97
  (font styles) is editing font-size handling at the same time, so I left it
  for the integrator/Rowan to decide. Stroke-width precision is renderer-wide
  and outside text layout.
- Upright clusters ignore `lengthAdjust="spacingAndGlyphs"`'s scale (no
  corpus case).
- Mark folding only covers the unshaped path and marks drawn from the same
  font as their base. Shaped fonts (Amiri, Hebrew, Devanagari) already cluster
  through the shaper.

## Report

Files: `LeanSvg/Svg.lean` (textPath `transform-origin`, `outK` in
`textShapes`), `LeanSvg/Text.lean` (upright branch, vertical decorations,
mark folding, `outK` parameter), `LeanSvg/VertOrient.lean` (new),
`LeanSvg.lean` (import), `tests/svg/96_text_layout.svg` (new).

Target files (within-8, resvg reference):

| file | 100 px before | 100 px after | 200 px before | 200 px after |
|---|---|---|---|---|
| `structure/transform-origin/on-text-path.svg` | 94.90% fail | 99.45% pass | 96.18% fail | 99.70% pass |
| `text/textPath/dy-with-tiny-coordinates.svg` | 91.13% fail | 91.40% fail | 93.94% fail | 94.09% fail |
| `text/writing-mode/mixed-languages-with-tb.svg` | 98.64% fail | 99.92% pass | 98.91% fail | 99.92% pass |
| `text/writing-mode/mixed-languages-with-tb-and-underline.svg` | 98.30% fail | 99.95% pass | 98.65% fail | 99.92% pass |
| `text/writing-mode/tb-with-rotate-and-underline.svg` | 96.09% fail | 99.76% pass | 97.25% fail | 99.91% pass |
| `text/text/rotate-with-multiple-values-and-complex-text.svg` | 97.15% fail | 99.00% pass | 97.74% fail | 99.33% pass |

Also newly passing at both widths: `text/writing-mode/tb-with-rotate.svg`,
`text/alignment-baseline/hanging-on-vertical.svg`. Improved but still
failing: `text/text/zalgo.svg` (+0.4 / +0.3). Improved and still passing:
`complex-graphemes.svg`, `complex-grapheme-split-by-tspan.svg`.

Directories (pass count): `text/writing-mode` 19→23 / 23,
`structure/transform-origin` 22→23 / 23, `text/text` 40→41 / 46,
`text/textPath` 37→37 / 44, all of `text/` 313→319 (100 px), 316→322 (200 px)
/ 356.

Whole suite (`run_corpora.py --corpus resvg --route direct`):
- 100 px (`--fast`): pass 1543 → 1550; 7 newly passing, **0 newly failing**,
  no file's within-8 dropped by more than 0.1.
- 200 px: pass 1567 → 1574; 7 newly passing, **0 newly failing**, no drops.

Other checks: `lake build` no warnings; `check-theorems.sh` prints
`invariants ok` / `theorems ok`; `run_tests.py` 58/67 (was 57/66 plus the new
`96_text_layout` at 99.26 %), no file dropped (`91_fonts` 99.862 → 99.872);
`run_adversarial.py` 143/143 clean; `run_tiles.py` 67/67 byte-identical.
