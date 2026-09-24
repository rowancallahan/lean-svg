# T108 — Pattern edge cases, 10 resvg-suite files  (branch `claude/fix-patterns-2`)

resvg-correct files that fail (within-8 at 200 px):

paint-servers/pattern/nested-objectBoundingBox.svg 95.8%
paint-servers/pattern/out-of-order-referencing.svg 98.9%
paint-servers/pattern/recursive-on-child.svg 92.7%
paint-servers/pattern/self-recursive-on-child.svg 91.2%
paint-servers/pattern/self-recursive.svg 91.2%
paint-servers/pattern/tiny-pattern-upscaled.svg 97.9%
paint-servers/pattern/transform-and-patternTransform.svg 90.6%
painting/context/with-pattern-and-transform-in-use.svg 98.9%
painting/context/with-pattern-objectBoundingBox-in-use.svg 93.4%

Follow usvg `paint_server.rs` (pattern resolution, recursion/self-reference
handling, objectBoundingBox content units, patternTransform composition) and
resvg's pattern rasterisation (tile size rounding, scale). Group the files by
cause, fix the causes that are small and clear. Note T104 made
`patternTransform` inherit along the href chain (Chromium/spec behaviour, not
usvg); keep that.

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

### Implemented

1. **Recursive pattern references** (`Svg.fixRecursivePatterns`): usvg's
   `svgtree/parse.rs::fix_recursive_patterns`, applied to the collected pattern
   content. For each pattern `p` in document order, a content shape whose fill
   names `p` becomes `none`. A shape that names another pattern `l` instead
   cuts every shape in `l`'s own content that names `p` back. The cut paint is
   `none`, not the `url()` fallback. Fill and stroke run as separate passes,
   ids are compared as in usvg, and the first pattern of a mutual pair keeps
   its reference. `patternFuel` still bounds longer cycles.
2. **Hairline strokes in pattern content** (`PatternRender.build`): a
   content stroke at most one tile pixel wide now takes `Raster.hairline`, as
   `Render.drawShape` does (`treat_as_hairline`). Before, it was outlined and
   filled, which lost the coverage tiny-skia folds into column 0 at the tile's
   left edge (191 vs 128). `hairCoverage` is copied from `Render.lean`, which
   imports this module.
3. **`patternContentUnits="objectBoundingBox"` precision**: if a resolved
   pattern with oBB content units and no `viewBox` uses a raw pattern's
   content, then that content's fill-only shapes (solid or oBB-gradient fill)
   are lexed on the 16.16 grid (`shapeCmds16`) with a 1/256 ctm factor. This
   is the same thing T49 does for mask content. Before, `0.1` at Fx's 1/256
   was 0.1016, a quarter pixel off on a 160-unit box.
4. **Sampling filter**: skew coefficients within 4/65536 of zero now count as
   zero when choosing nearest vs bicubic. `rotate(-30)` on the shape and
   `rotate(30)` as `patternTransform` cancel exactly in resvg's f32. In 16.16
   they left a unit or two, so we blurred with bicubic where resvg samples
   nearest.

`patternTransform` still inherits along the href chain (T104), unchanged.

### Numbers (resvg suite, direct route)

| run | before | after |
|---|---|---|
| 200 px pass | 1567 | 1574 (+7, 0 pass→fail) |
| 100 px (`--fast`) pass | 1543 | 1551 (+8, 0 pass→fail) |
| wall time 200 px / 100 px | 17.15 s / 11.7 s | 17.39 s / 11.0 s |

Target files, within-8 at 200 px:

| file | before | after |
|---|---|---|
| pattern/nested-objectBoundingBox | 95.75 | 99.62 pass |
| pattern/out-of-order-referencing | 98.91 | 100.00 pass |
| pattern/recursive-on-child | 92.72 | 100.00 pass |
| pattern/self-recursive-on-child | 91.22 | 99.60 pass |
| pattern/self-recursive | 91.22 | 99.60 pass |
| pattern/tiny-pattern-upscaled | 97.87 | 99.53 pass |
| pattern/transform-and-patternTransform | 90.64 | 99.73 pass |
| context/with-pattern-and-transform-in-use | 98.86 | 98.86 fail |
| context/with-pattern-objectBoundingBox-in-use | 93.45 | 98.56 fail |

Also moved: `patternContentUnits=objectBoundingBox` went from 99.13 to 100
(already passing at 200 px), and at 100 px `text-child` went from fail to
pass.

Other checks: `lake build` gives no warnings. `check-theorems.sh` prints
`theorems ok`. `run_tests.py` is 64/81; no score changed, and the new
`108_pattern_recursive` passes (100%). `run_adversarial.py` is 171/171
clean. `run_tiles.py` is 81/81 byte-identical.

### Not fixed (cause, proposed fix, size)

- **Both `painting/context/*-in-use` files: pattern-painted hairline
  strokes under a transform that cancels.** `<use transform="rotate(45)">`
  holds a `<g transform="rotate(-45)">`. Reduced case: a rect with
  `stroke="url(#p)"` (an opaque pattern) inside `rotate(45)` · `rotate(-45)`.
  resvg paints the hairline at about half alpha (67 and 60 on the two rows it
  touches), but at the full 127 and 128 when there is no transform, or when
  the paint is a solid colour or a gradient. We paint 127 and 128. So it is
  something in tiny-skia's hairline path together with the pattern shader,
  and probably with the bicubic choice, since the f32 matrix is not exactly
  axis-aligned. I have not found where. Next step: trace `anti_hair_line` →
  `blit_anti_h2` with a `RasterPipelineBlitter` for a pattern (`Repeat` +
  bicubic) shader. Size unknown, probably small once found; it is in
  `Render.drawShape`'s hairline branch, not in pattern code. The fill part of
  `with-pattern-objectBoundingBox-in-use` is fixed by item 3 (93.4 → 98.6).
- **General:** hairline strokes on rounded-rect corners differ in about 130
  px against resvg with no pattern involved (`rect rx=20 stroke=darkblue`).
  This is outside this task.
- **Pattern content lexed at Fx under large upscales.**
  `tiny-pattern-upscaled` now passes, but there is still a residual
  one-subsample error at circle edges. The 16.16 lexing from item 3 would
  remove it, but it is only exact when the tile matrix coefficients are
  multiples of 1/256, because `Mat` is 16.16 and the 1/256 factor eats 8 bits.
  So I did not turn it on for all pattern content. Fix: carry a per-shape
  "fine" flag and apply the 1/256 after the full matrix when mapping points.
  That touches `Svg.Shape` (shared), about 40 lines.

No reference in `criteria.csv` looks wrong for these files.
