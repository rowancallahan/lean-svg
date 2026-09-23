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
