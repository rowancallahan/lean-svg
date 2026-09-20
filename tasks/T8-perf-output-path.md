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

## Report

### Files changed

* `MicroSvg/Png.lean` — rewritten output path (all five suspects).
* `MicroSvg/Canvas.lean` — `toRgbaBytes` only. `new` was already a single
  `Array.replicate`, so there was nothing to take off it; `fillMask` and its
  helpers are main's (T7's), untouched.
* `git diff main -- MicroSvg/Effect.lean` is empty. `lake build` is clean, no
  errors and no new warnings.

### Method

`main` was rebuilt from its own sources inside this worktree; the resulting
binary is sha256-identical to the one at `.lake/build/bin/microsvg`
(`b7dd26e5e508fe15…`), so "before" really is main and the build is
reproducible. Each suspect was then measured by *ablation*: one binary per
suspect, reverting that suspect alone and keeping the other four, so each
number is what that change is worth in the presence of the rest. Every
ablation binary was checked to be byte-identical to main before it was timed.

Timings are medians of 9–11 round-robin runs (each round runs every binary
once, so drift hits them alike), minus a 1×1-render process floor of ~4.3 ms.
The machine was not quiet — load average 2.2–3.1 — so run-to-run spread is
reported with each figure; the per-suspect batch had 1.5–2 % spread and the
noisier batches 7–9 %. Differences below ~5 ms should not be read as real.

### Empty canvas, 3200×3200 — before/after

| | net median | spread |
|---|---|---|
| main (before) | 579–614 ms | 1.7–8.4 % |
| this branch (after) | 131–137 ms | 1.9–4.2 % |

**≈4.4× faster** (three separate batches gave 4.42×, 4.50×, 4.51×). The PNG is
40 966 393 bytes either way.

### Per-suspect breakdown (empty 3200², net ms; revert one, keep the rest)

| ablation | net | cost of reverting |
|---|---|---|
| none (final) | 133–137 | — |
| `adler32` → tuple accumulator + `% 65521` per byte | 506 | **+369 ms** |
| `crc32` → no slicing-by-4 (byte at a time) | 214 | **+81 ms** |
| `crc32` → `ByteArray.foldl` closure per byte | 211 | **−3 ms (no win)** |
| `encode`/`zlibStored` → main's row+block copies | 148 | **+15 ms** |
| …of which stored blocks via `extract`+`++` (suspect D) | 137 | +11 ms |
| …of which materialising `raw` first (suspect C) | — | +4 ms |
| `toRgbaBytes` → no alpha fast paths | — | 0 on an empty canvas |

Adler-32 dominates, so it was broken down further (same batch, 1.5–1.9 %
spread):

| adler shape | net |
|---|---|
| tuple accumulator, `%` per byte (main) | 506 ms |
| `for` loop, two `let mut` `Nat`s, deferred `%` | 282 ms |
| tail-recursive `adlerChunk`, byte at a time | 160 ms |
| `adlerChunk4`, four bytes per step (final) | 137 ms |

So deferring the `%` is worth ~224 ms, the tail-recursive shape a further
~122 ms, and the 4-way unroll ~23 ms. Note the middle row: the `for` loop with
two `let mut` `Nat`s that this task suggested is **1.8× slower** than the
tail-recursive helper, because two accumulators get boxed into a `Prod` that is
stored and reloaded every byte. That is why `adlerChunk` is written the way it
is, and the doc comment now records the measurement.

`toRgbaBytes` does not show up on an empty canvas (every pixel has `a = 0`, a
branch both versions share), so it was measured on a 3200² *solid background*,
which skips rasterisation entirely:

| background | before | after | win |
|---|---|---|---|
| opaque white (`a = 255`) | 209 ms | 140 ms | **+68 ms** |
| `rgba(0,128,255,0.5)` (`a = 128`) | 234 ms | 187 ms | **+47 ms** |

The translucent case never takes the `a = 255` path, so its 47 ms is the
per-pixel closure removal alone; skipping the three divisions on opaque pixels
is the remaining ~22 ms. Both parts are real wins and both were kept.

### One suspect reverted

The CRC's *tail-recursive* shape was not a measurable win: 211 ms for a
`ByteArray.foldl` closure per byte against 214 ms for a fuel loop, i.e. the
fold is if anything marginally faster and the gap is inside the spread. A
single `UInt32` accumulator stays unboxed either way — unlike Adler-32's pair.
The whole CRC win is the slicing-by-4 (`crcTable1/2/3` via `crcAdvance`), which
turns one dependent load per byte into four independent ones.

So `crcRun` was dropped for `crcBytes`, a three-line `ByteArray.foldl` over a
range, used both for the ≤3-byte remainder and as `crcRun4`'s fallback. This
also removes the fuel parameter and the "read 0 past the end" convention.
Re-measured after the change: 138.9 ms vs 139.1 ms, i.e. free, and still
byte-identical. The doc comments on `crcBytes` and `adlerChunk` now state what
was measured rather than what was assumed.

### Byte-identity

20 corpus files × {natural size, `--width 3200`} = **40/40 sha256-identical**
between main's binary and this branch's. The eight intermediate ablation
binaries were also checked against main on a 4-file subset (8/8) so that every
timing above compares implementations of the same bytes.

### Harnesses

* `python3 tests/run_tests.py` — 15/20 passed, 5 failed, 0 render errors.
  Re-run with main's binary via `--bin`: the per-test metrics (`exact%`,
  `within%`, `within32%`, `mean_abs`, `max_d`) are **identical on all 20
  tests**, 0 differences; only the timings move.
* `python3 tests/run_tiles.py` — 20/20 files, quadrant tiles stitch
  byte-identically to the full render.
* `python3 tests/run_adversarial.py` — 37/37 cases clean, 0 violations.
* Real file, `01_triangle.svg --width 800`: 99.7 ms → 66.8 ms net (1.46×);
  smaller than the empty-canvas factor because rasterisation, which this task
  does not touch, is most of that render.

### Not done / notes

* `run_sizes.py --widths 3200` was not run: the verification loop was shortened
  mid-task (invariant 9) and `01_triangle --width 800` was timed instead.
* Invariant 7 says not to commit, but this task was handed over with an
  explicit instruction to commit the finished work on `t8-output`; that is what
  the accompanying commit does. `main` was not touched.
