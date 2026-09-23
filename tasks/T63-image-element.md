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

---

## What was implemented

`<image>` as usvg 0.48.1 `parser/image.rs` + resvg `image.rs`, for embedded
PNG/JPEG only. Files: new `LeanSvg/Image.lean`; hooks in `LeanSvg/Svg.lean`
(one `Shape` field, one `Style` field, one element branch, `imageShape`) and
`LeanSvg/Render.lean` (one `match` in `drawShape`'s `paintMask`);
`LeanSvg/Effect.lean`, `PngDecode.lean`, `JpegDecode.lean` untouched.

* **href.** Only `data:` URIs. `href` wins over `xlink:href`. Anything else
  (path, `file:`, `http(s):`) returns `none` from `Image.dataUri`, so it draws
  nothing. No code path leads to a file or URL.
* **`data:` parsing** follows the `data_url` crate: trim, strip tab/LF/CR,
  split at the first `,`, drop `#fragment`, `;base64` suffix (any case,
  spaces allowed), MIME essence lowercased (`text/plain` when missing or
  invalid), percent-decoding, WHATWG forgiving base64.
* **Format.** Chosen as in usvg's `default_data_resolver`: `image/png` goes to
  `PngDecode.decode`, `image/jpeg`/`image/jpg` to `JpegDecode.decode`, and
  `text/plain` sniffs the magic bytes. GIF, WebP and SVG give `none`.
* **Decoder output** is re-checked against the `ImageData` contract (a
  violation is `none`), then premultiplied with tiny-skia's `premultiply_u8`.
* **Placement.** `x`/`y`/`width`/`height` use `convert_user_length` rules.
  A missing or unparseable (`auto`) size is taken from the image; if only one
  side is given, the other keeps the aspect ratio. A zero or negative
  viewport draws nothing. `preserveAspectRatio` follows `fit_view_box` +
  `aligned_pos` (`Viewport.posOff`). The image is filled through its view-box
  rectangle, as an ordinary shape. `slice` adds a synthetic one-rect clip on
  the viewport, the same mechanism as T48 (usvg's clipped outer group). It is
  placed under the element's own `clip-path` use so the layer pop still works.
* **Sampling** (`Image.build`, `Image.sampleAt`, `Canvas.fillMaskImage`).
  `Aff.invert` of the CTM, taken about the whole image with the tile/layer
  offset folded in like `Grad.build`, is composed with the view-box →
  image-pixel scale. That gives a per-pixel image coordinate in 16.16 at the
  absolute device pixel centre. Filters are tiny-skia's highp `Gather` /
  `Bilinear` / `Bicubic` (B = C = 1/3 weights `bicubic_near`/`bicubic_far`),
  with `Pad`, `Clamp0` + `ClampA`, in fixed point. A pure-translation map
  downgrades to nearest, as `Pattern::push_stages` does. Blending is
  `fillMaskShader`'s non-opaque path (a pattern is never opaque to tiny-skia).
  A tiny bias (2^-16 image px) on the constant term makes exact pixel-edge
  ties resolve like f32 does; without it `optimizeSpeed` was off by one column.
* **`image-rendering`** is an inherited `Style` field. `optimizeSpeed` /
  `crisp-edges` / `pixelated` → nearest, `smooth` → bilinear, anything else
  → bicubic. The attribute form of the four CSS-only values is dropped, as
  in usvg `svgtree/parse.rs` (resvg really does render
  `image-rendering="pixelated"` smooth).
* **opacity / transform / clip-path / mask / visibility / display / `use`**
  come free through the shape path: layers, clip chains, mask content,
  culling, `nodeBox`. The image is not a valid `clipPath` child, and nothing
  is decoded outside render mode.
* **Budget.** `Image.maxTotalPixels` (= 2 × `ImageData.maxPixels`) caps the
  decoded pixels one document keeps. A few KB of deflate can decode to
  16 Mpx, so without it many URIs, or `use` copies of one, could hold
  unbounded memory. Past the budget further images are not decoded. The first
  image that overruns it spends the rest, so at most one decode is wasted.
  This deviates from resvg, which would draw them all. Checked locally: 40
  copies of a 1000² image draw 33.

### Skipped, and why

* GIF, WebP and SVG-in-`<image>` (`embedded-svg*`, `external-svg*`,
  `*-on-svg`, `recursive-2`, `optimizeSpeed-on-SVG`) → `none`, per the task.
* External hrefs (`external-*`, `no-width*`/`no-height*`/
  `preserveAspectRatio=*`… that reference `image.png`) never draw, by
  condition 1. Those files stay failing permanently.
* `on-feImage` needs filters.
* `maskContentUnits="objectBoundingBox"` mask content: the image does not take
  the 16.16 "fine" path that shapes take there, so it is `Fx`-quantized.
* An image under a group past `maxLayerDepth` ignores the folded group
  opacity (`Style.opacity`). The shape path folds it into the paint alpha;
  the image sampler has no alpha input.

## Proof

`proofs/ImageLocality.lean` contains three theorems, all using only the
standard axioms, and `scripts/check-theorems.sh` discovers and audits them:

* `fillMaskImage_local`: no pixel outside the mask's rectangle changes.
* `fillMaskImage_in_box`: the image-specific corollary. For any rectangle
  containing the mask's, no pixel outside that rectangle changes. The mask
  `drawShape` passes is the rasterized view-box rectangle after `clipMask` and
  the clip chain, both of which only narrow it.
* `fillMaskImage_count`: at most `m.w * m.h` pixels change.

`render` stays pure, so the effect theorems cover images unchanged.
`SizeBound.lean` still checks.

## Tests

* `tests/ImageTests.lean` (`#guard`s, elaborated by CI's `tests/*.lean`
  loop):
  * forgiving base64 and `data:` edge cases, MIME dispatch and sniffing;
  * size-contract rejection;
  * placement for meet, slice, width-only, auto and invalid sizes;
  * bicubic weights summing to one;
  * an end-to-end draw: `Png.encode` → base64 `data:` URI →
    `Image.loadWith StoredPng.decode` → `fillMaskImage` on a 4×4 canvas,
    pixels exact and nothing outside the mask touched.

  `StoredPng` is a test-only decoder for stored-deflate PNGs.
* `tests/svg/46_image.svg` (stored-block PNG, so any real decoder reads it)
  covers bicubic scaling, slice + `pixelated` (CSS-only value, so smooth),
  `opacity` + `clip-path`, `mask` + `none`, a rotated
  `style="image-rendering:smooth"`, `use` of a `defs` image with
  `optimizeSpeed`, a path href, and malformed base64.
* `tests/adversarial/`: `image_refs.svg` (relative path, a path to a real PNG
  in the repo, `/etc/passwd`, `file://`, `http://`, `https://`, `data-not:`,
  `text/html`, no href), `image_bad_base64.svg`, `image_png_100k.svg` (IHDR
  100000×100000), `image_png_truncated.svg` (a valid PNG cut at seven points).
* `run_adversarial.py` adds:
  * generated `image_data_30mb.svg` (a 30 MB `data:` URI, 1.9 s);
  * generated `image_bomb_uses.svg` (65 KB PNG → 4096² × 300 `use`s);
  * the check `image_refs_inert`: `image_refs.svg` must render byte-identical
    to itself with every `<image>` removed.

## Report

All numbers were measured on this branch, where `PngDecode`/`JpegDecode` are
still the stubs.

| check | result |
|---|---|
| `lake build` | ok, no warnings |
| `scripts/check-theorems.sh` | `theorems ok` (incl. 3 new theorems) |
| `tests/*.lean` | all elaborate |
| resvg corpus (`--fast`, direct, 1679 files) | before 1046 pass / after 1046 pass; **0 newly failing, 0 files moved > 0.1 pt** |
| `structure/image` | 6/49 pass before and after (stub decoders: every embedded image is still `none`) |
| `painting/image-rendering` | 0/3 before and after (same reason) |
| `run_tests.py` | 30/34 → 30/35; no existing file's score changed; the new `46_image` fails (51.7 %) until T61 lands |
| `run_adversarial.py` | 85/85 clean (77 before + 8 new: 4 checked-in, `image_data_30mb`, `image_bomb_uses`, `truncated_46_image`, `image_refs_inert`) |
| `run_tiles.py` | 35/35 byte-identical |

**Projection with a real decoder.** Measured locally with the PNG stub
temporarily replaced by the test decoder (never committed). Every `<image>`
in the two target directories was re-embedded as a stored-block PNG (JPEG,
GIF and external rasters converted with Pillow). Each file was then compared
with resvg 0.48.1 rendering the same converted file, at `-w 100` and
`-w 500`:

* All 16 files that embed PNG/JPEG data (14 in `structure/image` plus
  `embedded-jpeg-without-mime`, and `painting/image-rendering/optimizeSpeed`)
  come out ≥ 0.99 within-8 at both widths. Most are max Δ ≤ 8; the exceptions
  are:
  * `with-transform`: 72 anti-aliased edge pixels of low alpha;
  * `embedded-16bit-png`: faint-alpha pixels from my own 16→8-bit conversion;
  * `image-with-float-size-scaling`: the stroked frame, which scored the same
    before.
* `46_image.svg` vs resvg: max Δ 3.
* Tiles stay byte-identical with images actually drawn.

Once T61 (PNG) and T62 (JPEG) land, those 16 files should flip to passing;
nothing else in the corpus can change.
