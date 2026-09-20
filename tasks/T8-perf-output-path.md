# T8 — Output path speed: RGBA export, CRC/Adler, PNG assembly

## Goal

T3 measured a fixed ~55–60 ms per megapixel even for an empty canvas:
`Canvas.new` + `Canvas.toRgbaBytes` + `Png.encode` (row copies, Adler-32 and
CRC-32 over ~4 bytes/pixel). Make this several times faster with
**byte-identical output**.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T8` (branch `t8-output`).
Files allowed: `MicroSvg/Png.lean`, and in `MicroSvg/Canvas.lean` only
`toRgbaBytes` and `new` (T7 is editing `fillMask` in parallel; do not touch it).

## Suspects (measure, then fix what matters)

- `Png.adler32` folds with a **tuple accumulator**, allocating a pair per byte.
  Rewrite as a `for` loop with two `let mut` `Nat`s; also defer the `% 65521`
  to every 5552 bytes (the standard trick; keep it exact).
- `Png.crc32` calls a closure per byte through `ByteArray.foldl` with
  `crcTable.getD` and `UInt32` conversions. A `for` loop over indices with
  `Nat`-typed table lookups may be faster; measure.
- `Png.encode` builds `raw` by `push 0` + `extract` + `++` per row: that copies
  every row twice and reallocates. Build the filtered rows directly into one
  pre-sized `ByteArray` in `toRgbaBytes` (have it emit the filter byte per row,
  or add `Canvas.toPngRows`), so `encode` does one Adler pass and one CRC pass.
- `zlibStored` copies again per 65535-byte block via `extract` + `++`; write
  block headers and copy slices with `ByteArray.copySlice` into a pre-sized
  buffer.
- `toRgbaBytes`: four `push` calls per pixel; consider `emptyWithCapacity` +
  `push` is fine, but the `unpremul` division per channel only when `a ∉ {0,255}`
  (for `a = 255` the channel is unchanged) is a real win on opaque content.

Invariants in `tasks/README.md` apply. Keep the PNG byte layout identical
(same chunk sizes, same stored-block boundaries) so that a later size theorem
(PLAN.md M3) can still be stated as a closed form.

## Measure

Baseline and after: render the corpus at natural size and `--width 3200` to a
temp dir, sha256 each PNG (must be identical), and time an empty
`<svg width="3200" height="3200"/>` render (median of 5) plus
`python3 tests/run_sizes.py --widths 3200 --runs 3 --filter 01_` for a real
file. Adversarial must stay clean. Confirm `Effect.lean` untouched.

## Done when

Byte-identical output, empty-canvas time at 3200² reported before/after with
the per-suspect breakdown. Append `## Report`. Do not commit.
