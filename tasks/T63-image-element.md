# T63 — the `<image>` element and its locality proof  (branch `claude/feat-image`)

## Rowan's conditions for images (hard, all of them)

1. **Embedded only.** The only image source is `href`/`xlink:href` with a
   `data:` URI inside the SVG itself (base64 or percent-encoded). Any other
   href (a path, `file:`, `http(s):`, anything) is ignored exactly as today:
   nothing is loaded, nothing is drawn. There is no code path from an image
   to a file or a URL, and `LeanSvg/Effect.lean` is not touched.
2. **Pure and halting.** Decoding and drawing are plain total Lean functions
   of the bytes (no `partial`, no `IO`, no unbounded recursion; fuel where
   recursion is needed). The CI invariants script (`scripts/check-theorems.sh`)
   enforces this and must pass.
3. **Failure is an `Option`, never a crash.** Malformed, truncated,
   unsupported or over-budget data yields `none`; the renderer then draws
   nothing for that element (as resvg does) and carries on. No error
   propagates out of `render` because of an image.
4. **Stays inside its box.** Drawing an image writes only pixels inside its
   destination rectangle (after `preserveAspectRatio`, viewport clip and any
   `clip-path`). Proved in `proofs/` (see T63).
5. **Other theorems unchanged.** All existing theorems keep holding with the
   same axioms; `render` stays pure, so the effect theorems cover images
   for free.

The interface is fixed in `LeanSvg/ImageData.lean` (read it). Decoders
return `Option ImageData.Decoded`; the size contract there is a theorem each
decoder proves.

## Task

Implement `<image>` as resvg 0.48.1 does (`crates/usvg/src/parser/image.rs`,
`crates/resvg/src/image.rs`). Target: `structure/image` (43/49 failing),
plus `painting/image-rendering`. Two other agents write the decoders
concurrently (T61 PNG, T62 JPEG) behind the fixed interface in
`LeanSvg/ImageData.lean`; **do not edit** `PngDecode.lean`/`JpegDecode.lean`
(they are stubs returning `none` on your branch). To test end-to-end before
they land, write your own tiny test-only decoder for our own encoder's
output (stored-block PNG) in a *test* helper, or temporarily patch the stub
locally without committing it.

Own files: new `LeanSvg/Image.lean` (data-URI parsing: `data:[mime][;base64],`
with base64 and percent-decoding, format sniffing by magic bytes like usvg,
dispatch to `PngDecode.decode`/`JpegDecode.decode`; GIF/WebP/SVG images →
`none` for now), the element hook in `Svg.lean`/`Render.lean` kept small.

Rendering: `x`/`y`/`width`/`height` (auto-size from the image when
missing, as usvg), `preserveAspectRatio` (reuse `LeanSvg/Viewport.lean`'s
helper), clip to the viewport box when slicing, `opacity`/`transform`/
`clip-path`/`mask` via the existing group-layer machinery,
`image-rendering` (`optimizeSpeed`/`pixelated` → nearest, else resvg's
filter quality — find which one tiny-skia uses for image patterns and match
its sampling, bilinear or bicubic, in fixed point). Draw through a mask and
a shader-like per-pixel sampler so the existing band/tile machinery applies
(`run_tiles.py` must stay byte-identical).

**Proof (hard requirement):** in `proofs/` (extend `proofs/Locality.lean`
or a new `proofs/ImageLocality.lean`), prove that the image draw function
changes no pixel outside its destination rectangle, in the same style as
`fillMask_local`/`fillMaskShader_local` already there. If the draw goes
through `fillMaskShader` with an image shader, the existing theorem may
already give this — then state the image-specific corollary explicitly.

**Adversarial:** add cases to `tests/adversarial/` and make sure
`run_adversarial.py` covers them: `href` to a file path, `file://`,
`http://` (must render identically to no image at all); malformed base64;
a data URI of 30 MB; a PNG header claiming 100000×100000; a truncated PNG.
All must render without error.

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
3. Full corpus with delta table:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/NN_<feature>.svg` exercising the feature
   if it fits the local corpus style (pick an unused number; collisions with
   other agents are resolved by the integrator).

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.
