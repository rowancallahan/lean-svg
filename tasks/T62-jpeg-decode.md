# T62 — JPEG decoder  (branch `claude/feat-jpeg-decode`)

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

Replace the stub in `LeanSvg/JpegDecode.lean` with a real decoder:
`decode : ByteArray → Option ImageData.Decoded`. Own file(s):
`LeanSvg/JpegDecode.lean` (split into `LeanSvg/Jpeg/*.lean` if large). Do
not edit `Svg.lean`, `Render.lean` or `LeanSvg/Image.lean` (T63 owns the
element; it calls `JpegDecode.decode`).

Match resvg 0.48.1, which decodes JPEG with `zune-jpeg` (check the version
in its Cargo.lock): its IDCT (integer, which variant), its chroma upsampling,
its YCbCr→RGB rounding, and its handling of EXIF orientation (probably none
— check). Target within 8 levels on the resvg suite's JPEG files; exact is
better. Scope: baseline and progressive, Huffman, 8-bit, 1 and 3 components
(and CMYK/Adobe if zune supports it and it is cheap), all common sampling
factors, restart markers. Arithmetic coding and 12-bit: `none`.

**Bounds (hard):** reject `w*h > maxPixels` from SOF before allocating;
every loop bounded by input size or the frame size; malformed Huffman data
yields `none`, never an out-of-range read (use `getD`).

**Proofs** (`proofs/JpegDecode.lean`, audited automatically):
`decode_size`, the `ImageData` contract (see T61 for phrasing and the
acceptable final-check structure).

**Tests:** `tests/check_jpeg_decode.py` with a debug exe (not linked into
`lean-svg`), compared against the reference (build a tiny Rust program
with the same zune-jpeg version if Pillow's libjpeg differs, which it will);
fuzz 2000 mutated files for clean results.

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

## Spec implemented

`LeanSvg/JpegDecode.lean` (+ `LeanSvg/Jpeg/Huffman.lean`, `LeanSvg/Jpeg/Idct.lean`):
`decode : ByteArray → Option ImageData.Decoded`, a total port of zune-jpeg
**0.5.15** (pinned by resvg 0.48.1's Cargo.lock), as resvg calls it (RGBA out).

- **Scope:** sequential (SOF0/1) and progressive (SOF2) Huffman, 8-bit, 1
  component (gray) or 3 (YCbCr); every sampling layout zune decodes
  correctly; restart intervals; DHT/DQT/DRI between scans; 16-bit quant tables.
- **IDCT:** zune's scalar integer IDCT (`idct_int`, jidctint-style, 12-bit
  constants, +128 folded into the rounding), in `Int32`, so wrapping matches.
  zune's 1x1/4x4 shortcuts and AVX2 path give the same values (the 4x4 is the
  same polynomial; AVX2 = scalar was checked on the whole corpus).
- **Upsampling:** zune's "fancy" triangle filter `(3a + b + 2) >> 2`, for 2x
  horizontal, vertical and both (vertical pass first). Edges are replicated at
  the MCU-padded plane edge, not at the image edge (libjpeg uses the image
  edge). Other ratios (4x1, 1x4, ...) use nearest neighbour, as zune does.
- **Colour:** BT.601 full range, 14-bit coefficients, rounding `2^13 - 1`,
  clamped. Gray is replicated to RGB. Alpha is 255.
- **EXIF orientation:** ignored, like zune and resvg.
- **Limits (checked at SOF, before any allocation):** each side ≤ 16384
  (zune's limit) and `w*h ≤ maxPixels`. At most 100 scans (zune's limit, applied
  to sequential files too, which caps work at 100 passes). Every loop is a `for`
  over the input size, the frame's block count or a constant. Every read uses
  `getD`/`byteAt`.
- **`none` on:** a bad marker or segment length, a missing table, an invalid
  Huffman table (all-ones code, over-full length, DC symbol > 15), a bit
  pattern that is no code, a coefficient index past the band, entropy data
  that runs out (`pos > 8 * size` after any MCU), a wrong number of restart
  intervals, no EOI (except a sequential image whose first scan covers every
  component, where zune stops reading too), arithmetic/lossless/hierarchical
  SOFs, DAC/DNL, CMYK/YCCK/RGB-tagged/2-component data.
- **Proof:** `proofs/JpegDecode.lean` `decode_size` states the `ImageData`
  contract (`px.size = w*h*4 ∧ 0 < w ∧ 0 < h ∧ w*h ≤ maxPixels`). It holds
  because `decode` ends with exactly that check (T61's structure). Axioms:
  `propext`, `Quot.sound`.

## Divergences from resvg/zune, and why

- **Corrupt/truncated data → `none`.** zune fills the rest of the image with
  grey (128) and returns it. Rowan's condition 3 requires `none`.
- **CMYK/YCCK → `none`.** zune's CMYK→RGBA path writes pixels with a stride
  of 3 into a 4-byte buffer (`worker.rs`, `chunks_exact_mut(3)`), which gives
  garbage colours and random alpha. RGB-tagged files (ids `R`,`G`,`B`, or
  Adobe transform 0 with 3 components) fail in zune with "Unimplemented
  colorspace mapping", so resvg draws nothing and neither do we.
- **Sequential 4x2 / 1x4 / 2x4, and 4x1 with restarts:** zune 0.5.15 garbles
  these (mean error ~110 levels against libjpeg). Ours stays within 4 levels
  of libjpeg (Pillow). I kept the correct decode rather than copying the bug.
  The progressive versions of the same layouts match zune byte for byte.
- **Sampling layouts where zune sizes planes from a running maximum**
  (component 0 not carrying the maximum factors), a vertically upsampled
  component with `v > 1`, or nearest ratios mixed with vertical triangles →
  `none`. zune's streaming upsampler gives stale or garbage rows for these;
  none appears in any encoder's normal output.
- **Non-interleaved sequential multi-scan files:** decoded to the spec (every
  block of every scan). zune's buffered path decodes only `mcu_y` block rows
  per scan there. Rare; not in any test corpus.
- APP14 transforms after the first SOS are ignored (zune would re-read them at
  colour conversion).

## Tests

`tests/check_jpeg_decode.py`: builds `jpegdump` (new debug exe `JpegDump.lean`,
not linked into `lean-svg`) and `tests/jpeg_ref` (Rust: `jref` = resvg's
`decode_jpeg` on zune-jpeg =0.5.15; `jgen` = jpeg-encoder, for sampling
layouts Pillow can't write). It compares on a generated corpus and then
fuzzes. Needs `cargo` (crates.io access for the first build).
`tests/svg/39_jpeg_image.svg`: three embedded JPEGs (4:2:0 baseline,
progressive gray, 4:4:4 with RST), drawn once T63 lands.

## Report

Files: `LeanSvg/JpegDecode.lean` (stub replaced), `LeanSvg/Jpeg/Huffman.lean`,
`LeanSvg/Jpeg/Idct.lean` (new), `proofs/JpegDecode.lean`, `JpegDump.lean` +
`jpegdump` target in `lakefile.toml`, `tests/check_jpeg_decode.py`,
`tests/jpeg_ref/`, `tests/svg/39_jpeg_image.svg`. `Svg.lean`, `Render.lean`,
`Image.lean` and `Effect.lean` are untouched.

Decoder vs zune (`python3 tests/check_jpeg_decode.py`):

| set | files | result |
|---|---|---|
| Pillow: gray/4:4:4/4:2:2/4:2:0 × baseline/progressive/optimized/RST × q5–100 × 10 sizes (1x1 … 257x3) | 680 | all byte-identical |
| jpeg-encoder: 1x1,2x1,1x2,2x2,4x1,4x2,1x4,2x4 × prog × RST, plus gray, 5 sizes | 180 | 155 byte-identical; 25 = zune bug above (ours ≤ 4 from libjpeg) |
| resvg suite `image.jpg` + embedded JPEGs (suite and `tests/svg`) | 5 | all byte-identical |
| CMYK, RGB-tagged | 2 | `none` (expected) |
| zune AVX2 vs scalar | 867 | identical on every file |
| fuzz: 2000 mutants (flips, truncation, junk, deletions, header fields, duplicated spans) | 2000 | all clean exits; 626 decoded (602 identical to zune), 1374 `none`; every decode has `w*h*4` bytes |

Resources: 2000x1500 noisy photo-like image, 1.3 s baseline / 2.0 s
progressive (byte-identical to zune). A 3 KB file whose SOF claims
4096x4096 → `none` in 0.7 s (zune returns a mostly grey 4096x4096 image).
Side 16385 → `none` at once.

Verification:
- `lake build`: OK, no warnings. `bash scripts/check-theorems.sh`: `theorems ok`
  (`LeanSvg.JpegDecode.decode_size`: propext, Quot.sound).
- resvg suite, direct, `--fast`: 1046/1679 pass before and after; 0 files
  moved, 0 newly failing. `render` does not call the decoder yet (T63 wires
  it in), so the two `structure/image/embedded-jpeg-*` files do not change
  until then.
- `tests/run_tests.py`: 30/34 → 30/35. No existing file's score changed. The
  new `39_jpeg_image` fails (55.7%) until T63 draws `<image>`.
- `tests/run_adversarial.py`: 78/78 clean. `tests/run_tiles.py`: 35/35
  byte-identical.

Not done: adversarial SVG cases in `tests/adversarial/` need T63's element;
until then, the decoder's are covered by the fuzz and bomb cases above.
