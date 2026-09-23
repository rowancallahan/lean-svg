# T78 — embedded GIF images  (branch `claude/fix-gif`)

The `<image>` element supports PNG/JPEG `data:` URIs. This needs a GIF (LZW) decoder behind `LeanSvg/ImageData.lean`, in a new `LeanSvg/GifDecode.lean`, with the same contract and a `decode_size` theorem in `proofs/GifDecode.lean`. Rowan's image conditions in `tasks/T61-png-decode.md` apply in full. Match what resvg's `image`/`gif` crate outputs (first frame only).

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

- `structure/image/embedded-gif.svg` (0.360)

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

## Diagnosis

`.lake/build/bin/lean-svg` drew nothing for `structure/image/embedded-gif.svg`
(fully transparent where resvg shows the decoded photo): `LeanSvg/Image.lean`
had a `Fmt.other` catch-all for anything that wasn't PNG/JPEG, and GIF
(sniffed or declared `image/gif`) fell into it — the element decoded to
`none` and drew nothing, exactly as its own doc comment said it would "for
now". Root cause was simply: no GIF decoder existed yet, confirmed against
`crates/resvg/src/image.rs::raster_images::decode_gif` (uses the `gif`
0.14.1 crate with `ColorOutput::RGBA`, `read_next_frame()` once) and
`crates/usvg/src/parser/image.rs` (MIME `image/gif` or sniffed magic bytes
`GIF8` → `ImageKind::GIF`). The fix was a full decoder plus wiring it into
`Image.lean`'s format dispatch (`Fmt`, `sniff`, `fmtOf`, `loadWith`/`load`),
which was small enough to do outright rather than just write up.

## Spec implemented

`LeanSvg/GifDecode.lean`: `decode : ByteArray → Option ImageData.Decoded`,
matching resvg 0.48.1 → `gif` 0.14.1 with `ColorOutput::RGBA`, first frame
only (`decoder.read_next_frame()` once, like `decode_gif`). Own new file,
plus the minimal wiring T78 needed in `LeanSvg/Image.lean` (a `.gif` `Fmt`
case beside the existing `.png`/`.jpeg`, its magic-byte sniff, its MIME
match, and a third decoder argument to `loadWith`/`load`) since nothing
called a GIF decoder before this landed.

* **Header and screen.** `GIF87a`/`GIF89a` signature, logical screen
  descriptor (only read for the global colour table's size/position — the
  screen's own width/height, and the frame's `left`/`top`, are never
  consulted: `decode_gif` builds `tiny_skia::Pixmap::new(w, h)` sized to the
  *frame*, not the screen, and fills it from the frame buffer at `(0, 0)`).
* **Blocks before the frame.** Extensions are walked generically (their
  sub-blocks concatenated, `subBlocks`) until the first Image Descriptor;
  only the most recently read Graphic Control Extension's transparent index
  survives, exactly as the crate's `read_control_extension` overwrites the
  pending frame's fields. A malformed control extension (its data not
  exactly 4 bytes) fails the whole decode, an unknown block type is `none`
  (`allow_unknown_blocks = false`, the crate's default), and the Trailer
  with no Image Descriptor is `none`.
* **The frame.** Local colour table if present, else global; neither is
  `none` ("no color table available for current frame"). `w * h >
  maxPixels` is `none` right after the descriptor, before any LZW work.
* **LZW** (`weezl`, `BitOrder::Lsb`, min code size `1..11`): literal codes
  `0..clear-1`, `clear = 1 <<< min_code_size` resets the table and code size
  to `min_code_size + 1`, the `end` code (`clear + 1`) stops early. A new
  table entry (`dict[prev] ++ [firstByteOfCurrent]`) is added after *every*
  code but the first one following a Clear — including the ordinary
  table-hit case, not only the `code == nextCode` (`KwKwK`) case, which is
  the standard LZW rule and the bug the first pass of this decoder had (see
  below). The table freezes at 4096 entries (`weezl`'s `MAX_ENTRIES`) rather
  than erroring, and code size bumps when `nextCode` reaches `2^codeSize`
  (`bump_post_initial_code_size`, `is_tiff = false` so no early-change
  offset). Decoding stops as soon as `w * h` indices are out, even if the
  bitstream has not reached its own `end` code, matching
  `converter.rs::fill_buffer`'s early return once its output slice is full.
* **Pixels.** `idx`'s palette entry (`3 * idx` into the chosen table) as
  straight-alpha RGBA8, transparent where `idx` is the Graphic Control
  Extension's index; an index past the palette is `(0, 0, 0, 0)` — the RGBA
  buffer's zero-init that `converter.rs::fill_buffer` never overwrites when
  `palette.get` fails (unlike PNG, where an out-of-range index is opaque
  black — a real, separate rule, not a mistake).
* **Interlace.** GIF's four-pass row interlacing (0 step 8, 4 step 8, 2 step
  4, 1 step 2) deinterlaced the way `converter.rs`'s `InterlaceIterator`
  orders rows; the decoded index stream stays row-major within each pass.
* **Bit reading** reuses `LeanSvg.Inflate.peek` (already generic 24-bit
  LSB-first bit reading, not DEFLATE-specific) instead of a second copy.
* **Bounds.** Block/extension walks by `b.size + 1` fuel (every block or
  sub-block consumes ≥ 1 byte); the LZW loop by `8 * data.size + 1` (every
  step consumes ≥ 2 bits, since `min_code_size ≥ 1`); every symbol's output
  is clipped to leave exactly `w * h` total, so `out.size` never overshoots
  the frame regardless of a pathological dictionary. No `partial`, no `IO`,
  no `!`-indexing.
* **Proof.** `proofs/GifDecode.lean`: `decode_size`, the same `ImageData`
  contract and proof shape as `PngDecode`'s — `decode` checks it on
  `decodeRaw`'s result and returns `none` otherwise, so the proof is that
  check read back.

## Skipped / differences

* **Only the one target file was hand-verified pixel-exact**; there is no
  `tests/check_gif_decode.py` fuzz/PngSuite-style harness (T61's is scoped
  to PNG). `tests/svg/78_image_gif.svg` (added) exercises a plain-palette
  GIF, one with a transparent index, and the same image saved interlaced,
  cross-checked against `resvg` directly (100% within-8, max channel diff 2,
  rounding only) before being folded into the corpus-style test.
* **`bump_initial_code_size`** (`weezl`): when `clear + 2` alone already
  needs a wider code than `min_code_size + 1` gives (only possible for a
  degenerate `min_code_size` of 1 or 2), `weezl` bumps the code size once
  *before* the first code is read. Not implemented — the reset path here
  only ever sets code size to `min_code_size + 1`. Does not affect any file
  in scope (`min_code_size` here is 7); a GIF encoded with `min_code_size ≤
  2` (1–4 colours) that relies on this could decode wrong.
* **APNG-style multi-frame GIFs**: only the first frame is decoded, matching
  resvg/`decode_gif` exactly (it calls `read_next_frame()` once); later
  frames, disposal methods and loop counts are never read.
* GIF, unlike PNG, has no CRC — nothing to verify/skip there.

## Report

Files: `LeanSvg/GifDecode.lean` (new), `proofs/GifDecode.lean` (new),
`LeanSvg.lean` (+`import LeanSvg.GifDecode`), `LeanSvg/Image.lean` (`.gif`
`Fmt` case, sniff, MIME match, `loadWith`/`load` take a third decoder),
`tests/ImageTests.lean` (updated its two hand-rolled decoder stand-ins and
one `fmtOf "image/gif"` assertion for the new arity/behaviour — it predates
T63 and isn't run by any script, but keeping it compiling was a 4-line
mechanical fix, not a refactor), `tests/svg/78_image_gif.svg` (new).

The bug worth naming: the first working version of the LZW loop only added
a new dictionary entry in the `code == nextCode` (`KwKwK`) branch, not the
ordinary `code < nextCode` table-hit branch — standard LZW adds an entry
after *every* code but the first. That produced garbage after a handful of
codes (`nextCode` never advancing past `clear + 2`, so a real code from
later in the stream read as "invalid, `code > nextCode`"). Found by tracing
a `dbg_trace`-instrumented copy of `run` against a hand-written Python
reference decoder over the target file's real LZW stream side by side.

| check | before | after |
|---|---|---|
| `lake build` | ok | ok, no warnings |
| `scripts/check-theorems.sh` | theorems ok | theorems ok (+`decode_size`) |
| target file (`structure/image/embedded-gif.svg`), within-8 @ 200px | 36.0% | 100.0% (max channel diff 1) |
| resvg corpus, direct, `--fast` (100px) | 1521/1679 (90.6%) | 1522/1679 (90.6%); 1 newly passing (`embedded-gif.svg`, +64.0 pts), 0 newly failing, 1678 unchanged |
| resvg corpus, direct, 200px (headline) | 1542/1679 (91.8%) | 1543/1679 (91.9%); 1 newly passing (+64.0 pts), 0 newly failing |
| `tests/run_tests.py` | 46/50 | 47/51 (added `78_image_gif`, 100.000% within-8); the 4 pre-existing failures and every other file's score unchanged |
| `tests/run_adversarial.py` | 116/116 clean | 117/117 clean (scales with the new `tests/svg` file) |
| `tests/run_tiles.py` | 50/50 byte-identical | 51/51 byte-identical |
