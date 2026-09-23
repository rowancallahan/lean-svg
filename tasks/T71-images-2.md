# T71 — images round 2 (branch `claude/feat-images-2`)

The `<image>` element (T63), PNG (T61) and JPEG (T62) decoders and
`feImage` for same-document references (T67) have landed; read their task
reports first. Remaining resvg-correct failures are below. Triage each by
cause (decoder mismatch vs resvg's `image` crate/zune-jpeg, sampling filter,
placement, a format we do not decode yet such as GIF/WebP/nested SVG
`data:image/svg+xml`, `feImage` with a `data:` href — T67 left a single
marked call site to wire to `Image`). Nested SVG images: usvg parses and
renders them as a sub-document; if you implement that, it must reuse
`render`'s pure pipeline with the existing depth/element budgets, and a
nested SVG image must not itself load images (bound the recursion depth to 1
or match usvg). GIF: a small LZW decoder is in scope if it keeps every rule
below (total, `Option`, size contract theorem in `proofs/`). Rowan's image
conditions from `tasks/T61-png-decode.md` apply unchanged (embedded data
only, pure, halting, `none` on failure, locality, other theorems unchanged).

Remaining resvg-correct failures at 200 px (from `tests/score_known.py` split):

- `filters/feImage/embedded-png.svg` (fail, within-8 0.481600)
- `filters/feImage/preserveAspectRatio=none.svg` (fail, within-8 0.740800)
- `filters/feImage/simple-case.svg` (fail, within-8 0.481600)
- `filters/feImage/svg.svg` (fail, within-8 0.481900)
- `filters/feImage/with-subregion-1.svg` (fail, within-8 0.910000)
- `filters/feImage/with-subregion-2.svg` (fail, within-8 0.910000)
- `filters/feImage/with-subregion-3.svg` (fail, within-8 0.750000)
- `filters/feImage/with-subregion-4.svg` (fail, within-8 0.750000)
- `painting/image-rendering/on-feImage.svg` (fail, within-8 0.481600)
- `painting/image-rendering/optimizeSpeed-on-SVG.svg` (fail, within-8 0.360575)
- `structure/image/embedded-gif.svg` (fail, within-8 0.360100)
- `structure/image/embedded-svg-without-mime.svg` (fail, within-8 0.360575)
- `structure/image/embedded-svg.svg` (fail, within-8 0.360575)
- `structure/image/embedded-svgz.svg` (fail, within-8 0.360575)
- `structure/image/external-gif.svg` (fail, within-8 0.360100)
- `structure/image/external-jpeg.svg` (fail, within-8 0.360000)
- `structure/image/external-png.svg` (fail, within-8 0.360000)
- `structure/image/external-svg-with-transform.svg` (fail, within-8 0.804050)
- `structure/image/external-svg.svg` (fail, within-8 0.360575)
- `structure/image/external-svgz.svg` (fail, within-8 0.360575)
- `structure/image/no-height.svg` (fail, within-8 0.360000)
- `structure/image/no-width-and-height.svg` (fail, within-8 0.360000)
- `structure/image/no-width.svg` (fail, within-8 0.360000)
- `structure/image/preserveAspectRatio=none-on-svg.svg` (fail, within-8 0.804600)
- `structure/image/preserveAspectRatio=xMaxYMax-meet-on-svg.svg` (fail, within-8 0.804350)
- `structure/image/preserveAspectRatio=xMaxYMax-slice-on-svg.svg` (fail, within-8 0.610300)
- `structure/image/preserveAspectRatio=xMidYMid-meet-on-svg.svg` (fail, within-8 0.804350)
- `structure/image/preserveAspectRatio=xMidYMid-slice-on-svg.svg` (fail, within-8 0.590400)
- `structure/image/preserveAspectRatio=xMinYMin-meet-on-svg.svg` (fail, within-8 0.804350)
- `structure/image/preserveAspectRatio=xMinYMin-slice-on-svg.svg` (fail, within-8 0.610300)
- `structure/image/raster-image-and-size-with-odd-numbers.svg` (fail, within-8 0.395650)
- `structure/image/recursive-2.svg` (fail, within-8 0.968800)
- `structure/image/width-and-height-set-to-auto.svg` (fail, within-8 0.360000)

Target: every file above passing at both widths, where achievable without breaking the invariants.

---

## Common rules (every lean-svg agent)

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
