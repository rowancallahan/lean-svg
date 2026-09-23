# T77 — feImage with embedded `data:` images  (branch `claude/fix-feimage-data`)

T67 (feImage) left a single marked call site for `data:` hrefs to be wired to `LeanSvg/Image.lean` (T63), which has since landed with the PNG/JPEG decoders. Probably a wiring job; Rowan's image conditions in `tasks/T61-png-decode.md` apply.

## How to work (research first)

1. **Diagnose first (keep it short).** Render each file below with
   `.lake/build/bin/lean-svg` and with `resvg -w 200`, look at both PNGs and a
   diff, find the root cause in our code, and find how resvg/usvg 0.48.1
   handles it in the Rust source.
2. **If the fix is small and safe**, implement it, verify it with the rules
   below, and push.
3. **If it is not**, do not force it: write the diagnosis (root cause, the
   relevant usvg/resvg code, the proposed fix and its risks, rough size) into
   your task file's `## Report`, and push only that.
Either way the report must name the root cause of every file below.

Files (within-8 at 200 px):

- `filters/feImage/embedded-png.svg` (0.482)
- `filters/feImage/preserveAspectRatio=none.svg` (0.741)
- `filters/feImage/with-subregion-3.svg` (0.750)
- `filters/feImage/with-subregion-4.svg` (0.750)
- `painting/image-rendering/on-feImage.svg` (0.482)

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

---

## What was implemented

The one marked call site, `FeImage.dataCanvas` (`LeanSvg/Filter/Image.lean`),
wired to T63's `LeanSvg.Image` decoders — the whole gap was that stub always
returning `none` (the dummy primitive), so every `data:` `feImage` rendered
transparent.

* **`Job` (`LeanSvg/Filter/ImageRender.lean`)** gained `uw`/`uh`: the
  primitive subregion's own width/height in *user* units (`p.sub.w`/`.h`,
  already computed for `devRect`), alongside the existing device-pixel
  `sx`/`sy`/`sw`/`sh`. `preserveAspectRatio`'s fit depends on the subregion's
  *aspect ratio*, which is `uw`/`uh`'s, not necessarily `sw`/`sh`'s — they
  only agree when the filter's `ts` scale is uniform (`sx == sy`), the
  ordinary case, but can differ under an anisotropic ancestor `transform`.
* **`FeImage.Spec` gained `quality`**: `image-rendering` read directly off
  the `feImage` element (`Image.parseRendering`, defaulting to bicubic), the
  same attribute `<image>` itself uses. usvg's `find_attribute` would also
  walk the `feImage`'s *document* ancestors (`filter`, `defs`, …) when the
  attribute is absent there, which this does not do; every corpus case sets
  it on `feImage` itself when it matters (`painting/image-rendering/on-feImage`).
* **`FeImage.dataCanvas`** now: decodes `uri` with `Image.load` (T63); fits it
  into `(0, 0, uw, uh)` — usvg's `image::convert_inner` with
  `filter_subregion.translate_to(0, 0)` — via `Image.place`, which returns
  the rectangle, the placed image, and (for a `slice` aspect) a clip rect,
  all still in that local user space; flattens the rectangle and maps it
  through `mat` (the caller's `Job.mat parent.fts`, resvg's
  `apply_image`/`[sx 0 0 sy subregion.x subregion.y]` — the exact transform
  the `href="#id"` link case already renders with) to rasterize it onto the
  `rw × rh` region canvas; builds the device-space sampler with
  `Image.build placed mat 0 0` and composites with `Canvas.fillMaskImage`,
  the same primitives `<image>` itself uses. A `slice` clip is intersected
  with a small local `clipToRect` (duplicates `Render.clipMask`'s ~10 lines;
  this module is one of `Render`'s own dependencies and cannot import it
  back). `none` — the dummy primitive — for anything `Image.load`/`place`
  already treats that way: undecodable bytes, an empty viewport, a singular
  `mat`.
* **Budget.** `Render.lean`'s `groupEnd` now charges the `.data` branch
  exactly like the `.elem` branch it sits beside: `renders += 1` against
  `maxMaskRenders` (`"feImage budget"`), and the region canvas against
  `livePixels`/`maxLayerPixels` (`"layer budget"`), before decoding. Each
  individual decode is already capped at `ImageData.maxPixels` (T61/T63); this
  bounds how many times one filter with an embedded image can be replayed
  (e.g. applied to many elements via `use`), the same risk `feimage_many_links`
  covers for links.

## Skipped, and why

* **`image-rendering` inherited from a document ancestor of `feImage`**
  (rather than only the element's own attribute) — no corpus case needs it,
  and `feImage`'s ancestors (`filter`, `defs`) are never otherwise styled.
* **Anisotropic filter scale** (`sx != sy` in `FilterApply.scaleOf`):
  `preserveAspectRatio`'s fit uses `uw`/`uh` (correct, per above) but the
  *rounding* of the placed rectangle back to device pixels goes through
  `Mat.apply`'s ordinary floor, same as every other primitive's geometry —
  not specifically checked against resvg's `f32` here. No corpus file
  exercises a `feImage` under a non-uniform scale.

## Report

Baseline commit `a5d147b`. `run_corpora.py --fast --corpus resvg --route direct`
(width 100) and the headline `--width 200` pass, before → after (identical
delta at both widths):

| corpus | file | within-8 before | within-8 after |
|---|---|---|---|
| filters/feImage/embedded-png.svg | 48.160% | 100.000% |
| painting/image-rendering/on-feImage.svg | 48.160% | 100.000% |
| filters/feImage/preserveAspectRatio=none.svg | 74.080% | 100.000% |
| filters/feImage/with-subregion-3.svg | 75.000% | 100.000% |
| filters/feImage/with-subregion-4.svg | 75.000% | 100.000% |
| filters/feImage/with-subregion-5.svg | 84.000% | 100.000% |
| filters/feImage/with-subregion-1.svg | 91.000% | 100.000% |
| filters/feImage/with-subregion-2.svg | 91.000% | 100.000% |

All 5 files named in this task now pass, plus 3 more `with-subregion` files
that were failing for the identical reason (not in the task's list, but the
same stub). Whole suite (1679 files): width 100 pass 1521 → 1529, width 200
pass 1542 → 1550; **newly passing 8, newly failing 0** at both widths.

Other checks, all on the final tree:

* `lake build`: no errors, no new warnings.
* `scripts/check-theorems.sh`: `theorems ok`.
* `tests/run_tests.py`: 47/51 pass (was 46/50; the 4 pre-existing failures
  are unchanged and unrelated — `12_badge`, `14_flower_transforms`,
  `15_spiral_stroke`, `16_stress_2000`). No file's score dropped; new
  `77_feimage_data` (default fit, `preserveAspectRatio="none"` +
  `image-rendering="optimizeSpeed"`, a percentage subregion, and the
  no-href/non-data-href dummy cases) 100.000% within 8, PASS.
* `tests/run_adversarial.py`: 117/117 clean (was 116; the new test file adds
  one budget/parse case for free).
* `tests/run_tiles.py`: 51/51 byte-identical, `77_feimage_data` included.
