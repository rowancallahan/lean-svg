# T61 — PNG decoder  (branch `claude/feat-png-decode`)

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

Replace the stub in `LeanSvg/PngDecode.lean` with a real decoder:
`decode : ByteArray → Option ImageData.Decoded`. Own files:
`LeanSvg/PngDecode.lean` and a new `LeanSvg/Inflate.lean` (zlib/DEFLATE
decoder: stored, fixed and dynamic Huffman blocks). Do not edit `Svg.lean`,
`Render.lean` or `LeanSvg/Image.lean` (T63 owns the element; it calls
`PngDecode.decode`).

Scope, matching what resvg 0.48.1 decodes (it uses the `png` crate via
`image`; check its transformations): all colour types (gray, RGB, palette,
gray+alpha, RGBA), bit depths 1/2/4/8/16 (16 → 8 by the same rounding the
crate uses), `tRNS`, Adam7 interlace, all five filters, multiple IDAT, CRC
and Adler checks (decide whether to verify them the way the crate does —
it may ignore CRC errors in ancillary chunks). Output RGBA8 straight alpha.

**Bounds (hard):** read IHDR first and reject `w*h > maxPixels` before
inflating; inflate with an output cap equal to the exact expected filtered
size, so a zip bomb stops at the cap; every loop bounded by the input size
or that cap.

**Proofs** (new `proofs/PngDecode.lean`, audited automatically by
`scripts/check-theorems.sh`): `decode_size`, the `ImageData` contract:
`decode b = some d → d.px.size = d.w * d.h * 4 ∧ 0 < d.w ∧ 0 < d.h ∧
d.w * d.h ≤ ImageData.maxPixels`. Structure the final assembly so this is
easy (e.g. the last step checks the size and returns `none` otherwise —
that is acceptable and honest). Optional stretch: round trip with our
encoder, `decode (Png.encode px w h) = some ⟨w, h, px⟩` for valid sizes.

**Tests:** a script `tests/check_png_decode.py` that decodes a corpus of
PNGs (PngSuite if you can fetch it: `https://github.com/glennrp/libpng`
contrib/pngsuite, or generate with Pillow across every colour type/depth/
interlace) through a small debug exe (like `fontdump`, not linked into
`lean-svg`) and compares to Pillow pixel-exact; fuzz 2000 mutated files
for clean `none`/`some` (no crash, no hang). Adversarial cases in
`tests/adversarial/` (zip bomb, huge IHDR, truncated) once T63's element
exists; until then via the debug exe.

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

`LeanSvg/PngDecode.lean` (`decode : ByteArray → Option ImageData.Decoded`) and
`LeanSvg/Inflate.lean` (`zlib : ByteArray → (cap : Nat) → Option ByteArray`).
The reference is resvg 0.48.1 → `tiny_skia::Pixmap::decode_png` (tiny-skia
0.12) → `png` 0.18.1 with `normalize_to_color8()` (EXPAND | STRIP_16), then
widened to RGBA8. Output is straight alpha; tiny-skia premultiplies, which is
T63's job.

* **Chunks.** Signature, then `IHDR` first (13 bytes; width/height > 0; valid
  colour type/depth pair; compression/filter 0; interlace 0/1). Only chunks
  before the first `IDAT` are read for metadata. The `IDAT` run is
  concatenated; the crate needs the following chunk's length and type to see
  the run end, so those 8 bytes must exist (a file cut right after the last
  `IDAT` is `none` in both). Nothing after that is read (`IEND` optional, as
  in the crate). `IEND`/unknown critical chunk/second `IHDR`/second `PLTE`
  before `IDAT` → `none`; `fdAT` before `IDAT` → `none`.
* **CRC.** Checked on every chunk read. Critical (`IHDR`, `PLTE`, `IDAT`)
  mismatch → `none`; ancillary mismatch → chunk skipped
  (`skip_ancillary_crc_failures = true`, the crate default).
* **Adler-32 not checked**: the crate default is `ignore_adler32 = true` and
  resvg does not change it.
* **zlib header** as `fdeflate` checks it: method 8, CINFO ≤ 7, no FDICT,
  FCHECK. DEFLATE: stored (LEN/NLEN), fixed and dynamic blocks; HLIT ≤ 286,
  HDIST ≤ 30, repeat-16 with no previous length, run past HLIT+HDIST,
  missing end-of-block code, over-subscribed trees, length symbols 286/287,
  distance codes 30/31, distance before the start → `none`.
* **Transforms** (from `png/src/decoder/transform.rs`, `palette.rs`,
  `stream.rs::parse_trns`): 16-bit → high byte; gray 1/2/4 → `v * 255/(2^d-1)`;
  palette index past the PLTE → opaque black; tRNS for palette ignored whole if
  longer than the palette, missing entries → 255; gray/RGB tRNS at depth ≤ 8
  compares the low byte(s) of each 16-bit key, at depth 16 compares all bytes
  (a tRNS of the wrong length never matches). tRNS on gray+alpha / RGBA, a
  second tRNS, a short one, or one before `PLTE` is ignored. Colour type 3
  with no `PLTE`, or a `PLTE` whose length is not a multiple of 3 (the crate
  panics on it), → `none`.
* All five filters, Adam7 (empty passes skipped), multiple `IDAT`s.

**Bounds.** `w * h > maxPixels` → `none` straight after the chunk walk,
before inflating. The inflater's cap is the exact filtered-stream size (sum
over passes of `rows * (1 + rowBytes)`); it stops once the cap is reached and
fails if the stream ends before. Loops: chunk walk and `IDAT` run by
`size / 12 + 1` fuel; blocks by `8 * input.size + 1` (each block header is
≥ 3 bits); symbols by `cap + 1` per block; code lengths by `HLIT + HDIST + 1`;
everything else `for` over ranges bounded by the cap or `w * h`. No
`partial`, no `IO`, no `!`-indexing.

**Proof.** `proofs/PngDecode.lean`: `decode_size`, the `ImageData` contract.
`decode` checks it on `decodeRaw`'s result and returns `none` otherwise, so the
proof is that check read back. Axioms: `propext`, `Quot.sound`.

**Debug exe.** `pngdump` (`PngDump.lean`, own `lean_exe`, not linked into
`lean-svg`): `pngdump <out-dir|-> <file.png>...` prints `<path> <w> <h>` or
`<path> none` and optionally writes raw RGBA.

**Tests.** `tests/check_png_decode.py`:
* PngSuite (all 175 PNGs, fetched into `tests/corpora/pngsuite` from
  image-rs/image-png, the `png` crate's own copy; the schaik.com tarball is
  blocked here) + 122 generated PNGs (every colour type × depth × interlace,
  random per-row filters, split `IDAT`s, tRNS, zlib level 0/1/6/9 and
  fixed/Huffman-only/RLE/filtered strategies, two larger ones) + two PNGs
  written by `lean-svg` (stored blocks > 64 KiB, round trip through our
  encoder). Compared byte-exact with Pillow's samples after applying the
  crate's rules above. Pillow drops the low bytes of 16-bit RGB, so that one
  tRNS key is checked against a small zlib+unfilter reader in the script. The
  14 `x*.png` must give `none`.
* 15 adversarial cases through `pngdump`: 16×16 IHDR over a ~200 MB zero
  stream (decodes, stopped at the cap), the same stream under 100000² and
  4097×4096 IHDRs, 4096² with a tiny IDAT, zero width, 8 truncations, no IEND
  (decodes) and a cut right after the last IDAT (`none`).
* 2000 mutants (bit flips, byte sets, deletions, insertions, truncation; half
  with CRCs repaired so the damage reaches the inflater and unfilter).
* The harness is sensitive: a one-character change to the Paeth tie-break
  gave 28 mismatches.

## Skipped / differences

* **Round-trip theorem** (`decode (Png.encode ...) = ...`) not attempted; it
  would mean proving the inflater and unfilter correct. The round trip is
  tested instead (the `leansvg_*` corpus entries).
* **Streaming quirks not copied.** `fdeflate` decodes as each `IDAT` arrives,
  so it can fail on corrupt data *after* the last needed byte if that data
  is in the same chunk; this decoder stops reading at the cap. Incomplete
  Huffman trees are accepted and fail only if an unassigned code is read;
  `fdeflate`'s exact rules for incomplete trees were not copied.
* **APNG** (`acTL`/`fcTL`) is ignored; the default image from `IDAT` is
  decoded. The crate treats a malformed `fcTL` as fatal; here it is skipped.
* `tests/svg/NN_*.svg`: none added. `<image>` is not rendered until T63
  lands, so an SVG using it would test nothing here. Adversarial cases for
  `tests/adversarial/` wait on T63 too; for now they run through `pngdump`.
* Speed: 2000×2000 RGBA (514 KB file) decodes in 0.78 s in `pngdump`.

## Report

Files: `LeanSvg/Inflate.lean` (new), `LeanSvg/PngDecode.lean` (stub
replaced), `LeanSvg.lean` (+`import LeanSvg.Inflate`), `PngDump.lean` +
`lakefile.toml` (`pngdump` exe), `proofs/PngDecode.lean`,
`tests/check_png_decode.py`.

| check | before | after |
|---|---|---|
| `lake build` | ok | ok, no warnings |
| `scripts/check-theorems.sh` | theorems ok | theorems ok (+`decode_size`) |
| resvg corpus, direct, `--fast` | 1046/1679 pass (62.3%) | 1046/1679; 0 newly failing, 0 moved > 0.1 pt |
| `tests/run_tests.py` | 30/34 | 30/34, per-file scores identical |
| `tests/run_adversarial.py` | — | 77/77 clean |
| `tests/run_tiles.py` | — | 34/34 byte-identical |
| `tests/check_png_decode.py` | — | 299 files 0 mismatches; 15/15 adversarial (0.01 s); 2000 fuzz: 80 some / 1920 none, 0 bad |

Nothing calls `PngDecode.decode` from `render` yet (T63), so the render
numbers cannot move.
