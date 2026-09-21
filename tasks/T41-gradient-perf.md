# T41 — Gradient fill is ~150x slower per pixel than resvg  [Opus]

## The measurement

`--width 2000` (2.6 Mpx), median of five runs, 8-core arm64. Per-pixel cost of
a single full-canvas `<rect>`:

| fill | ours | resvg | ours ns/px |
|---|---|---|---|
| flat colour | 93 ms | 15 ms | 36 |
| linear, 2 stops | 874 ms | 19 ms | 336 |
| linear, 8 stops | 870 ms | 25 ms | 335 |
| radial, 2 stops | 1353 ms | 35 ms | 520 |
| radial with focal point | 1826 ms | 32 ms | 702 |

Gradient fill adds **300 ns/px** over a flat fill; resvg adds about 2 ns/px.
On the README's `confetti` image this is the whole story: removing its two
gradients takes it from 1435 ms to 545 ms, while removing its layers saves
73 ms and its clip 93 ms.

**Eight stops cost the same as two**, so `Grad.findStop`'s binary search is not
the bottleneck. The cost is the fixed per-pixel work.

## The cause

`Grad.lerpCh` (`LeanSvg/Shader.lean:691`) runs once per colour channel per
pixel and each call performs an `Int.ediv`:

```lean
let v := 2 * ((cl : Int) * den + ((cr : Int) - (cl : Int)) * num) + den
let q := Int.ediv v (2 * den)
```

For any gradient whose stops differ in all three channels, that is three or
four integer divisions per pixel, plus the premultiply. `Int.ediv` is a real
division instruction, tens of cycles, and the operands are `Int` rather than
`Nat` (see `tasks/README.md` invariant 4 — the hot loop in `fillMaskShader`
was written carefully to stay unboxed, but `lerpCh` and `paramAt` were not
given the same treatment).

The blit loop itself (`fillMaskShader`, line ~905) is already well optimised:
row constants are hoisted and the hi/lo split keeps the affine evaluation in
the unboxed range. Do not rewrite it; the win is underneath it.

## What to do

Two independent changes. Measure each separately.

1. **Precompute the colour ramp, removing the per-pixel divisions.** This is
   what Skia and tiny-skia do. Build the ramp once per resolved gradient in
   `Grad.build` and make `rampAt` a lookup.
   - **Exactness is the constraint.** A 256- or 1024-entry table quantises the
     ramp and *will* move pixels. Two ways to avoid that, in order of
     preference:
     - a full table indexed by the 16.16 parameter (65537 entries of four
       `Nat`s, built once per gradient) — bit-exact and division-free, but
       cap the number of live tables (build lazily, only for gradients a draw
       actually references) and state the memory bound in the report;
     - or keep the formula and replace `Int.ediv v (2 * den)` with a
       precomputed reciprocal multiply-and-shift, since `den` is constant per
       stop pair. This is exact if you carry enough bits; prove the bound on
       the range of `v` and pick the shift accordingly.
   - If neither lands cleanly, a quantised table is acceptable **only** if the
     corpora numbers below do not move at all; say so explicitly in the report.
2. **Move the per-pixel arithmetic to `Nat`** in `lerpCh` and `paramAt` where
   the values are provably non-negative and fit 63 bits, per invariant 4.
   Report the measured effect on its own, since it may be small once the
   divisions are gone.

Radial costs 184 ns/px more than linear and the focal case another 182 ns/px.
After the ramp work, check whether `Nat.sqrt` is the remaining cost there and
report; do not optimise it in this task.

## Verify

- `lake build` clean; `git diff origin/main -- LeanSvg/Effect.lean` empty.
- **Fidelity must not move.** Corpora at `--width 200`, direct route, against a
  same-width baseline you generate from main's binary first (never compare
  across widths): `--dir paint-servers --dir painting/fill`. Required:
  `linearGradient` 38/38, `radialGradient` 45/45, `stop` 32/32, `stop-color`
  1/1, `stop-opacity` 2/2, and `painting/fill` not below main.
- `python3 tests/run_tests.py`: all 27 files byte-identical to main's binary,
  including `24_gradients`. If the ramp is quantised, this is the check that
  must still pass; a single changed pixel means the approach is rejected.
- `run_tiles.py` byte-identical; `--threads 4` byte-identical to `--threads 1`
  on `24_gradients` at 800 px; `run_adversarial.py` clean.
- **Report the timing table above, re-measured**, plus `confetti` and `stress`
  at `--width 2000` before and after.

Commit with author Rowan Callahan <rowan.l.callahan@gmail.com> and a message
ending `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`, push, and open
a pull request against main whose description is the report and ends with
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do not merge.

## Report

`LeanSvg/Shader.lean` only.  All numbers below were re-taken on this machine
(4-core Intel Xeon @ 2.10 GHz, x86-64, Linux, Lean 4.34.0, resvg 0.48.1), both
before and after, because the table in the task was measured on 8-core arm64.
The bench files are a 1000x1000 `<svg>` with one full-canvas `<rect>`, so
`--width 2000` is 4.0 Mpx (the task's own file was 2.6 Mpx); medians of five,
interleaved run-to-run, and the container's noise is about +/-10%.

### What changed

Three changes, measured one at a time.  Each column below is a separate
binary; `main` is `ee4ea4b`.

1. **`ramp`** — the four `Int.ediv`s per pixel are gone.  `RtStop` carries
   `den` (the segment's width) and `recip = ⌊2^44 / 2·den⌋ + 1`, both filled
   once per built gradient in `Grad.build`; `lerpCh` became a multiply and a
   shift.  Exact, not approximate: with `2^k = M·D − e` and `0 < e ≤ D`,
   `⌊v·M / 2^k⌋ = ⌊v / D⌋` whenever `v·e < 2^k`, and here `den ≤ 65536`,
   `|num| ≤ 65536` give `v < 2^27`, so `v·e ≤ v·D < 2^44`.  Clamping to
   `[0, 255]` before the multiply also bounds `v·M` by `510·2^43 < 2^52`, so
   the product stays unboxed.  Checked against the division form over
   19 914 336 cases covering the whole reachable domain (exhaustive in the two
   channels for every corner `den`/`num`, exhaustive in `num` for `den < 64`,
   3M random elsewhere): no disagreement, widest product `2^51`.
2. **`+Nat`** — `RtStop.off`, `findStop`, `spreadT` and the whole ramp moved
   from `Int` to `Nat` (invariant 4).  Offsets are parsed into `[0, 65536]`
   and made monotone, so the conversion is exact.  `num` is signed only where
   the ramp extrapolates to the left of its first stop, which is now its own
   branch (`lerpDown`) instead of an `Int` carried through the common path.
   `paramAt`'s radial arm got `hypot16`, the `norm2`-then-`sqrt16` pair with
   no `Int` built in between.
3. **`+table`** — the task's preferred option, gated.  A draw whose mask
   bounding box is at least `rampArea = 262144` pixels evaluates the ramp once
   per 16.16 parameter value into four `Array Nat` (`withRamp`) and then only
   reads it; a smaller draw keeps the per-pixel formula.  The table *is*
   `rampCalc` entry by entry, so the two paths cannot disagree, and which one
   a draw takes — including a draw cut into tiles or thread bands — cannot
   move a pixel.  **Memory: 65537 entries x 4 arrays x 8 bytes ≈ 2.1 MB, one
   table at a time, built inside `fillMaskShader` and dropped when the draw
   ends.**  `Grad.build` never builds one, so a gradient a draw does not
   reference costs nothing.

`fillMaskShader`'s loop was not rewritten: it gained the three lines that
decide whether to build the table.  `Canvas.fillMask` (the solid path) and
`LeanSvg/Effect.lean` are untouched.

### Timings, `--width 2000`, median of 5 (ms)

| fill | main | ramp | +Nat | +table | resvg | main ns/px | +table ns/px |
|---|---|---|---|---|---|---|---|
| flat colour | 325 | 267 | 255 | 251 | 61 | 81 | 63 |
| linear, 2 stops | 1637 | 1482 | 1466 | 1168 | 108 | 409 | 292 |
| linear, 8 stops | 1634 | 1579 | 1536 | 1191 | 165 | 409 | 298 |
| radial, 2 stops | 2226 | 2212 | 2202 | 1866 | 152 | 557 | 467 |
| radial with focal point | 3369 | 3009 | 2893 | 2595 | 138 | 842 | 649 |
| confetti | 1738 | 1724 | 1617 | 1449 | 115 | — | — |
| stress | 4067 | 3896 | 3953 | 3873 | 489 | — | — |

`flat colour` and `stress` contain no gradient and no code on their path
changed; their spread is the machine's noise, which is the scale to judge the
1-3% steps by.  Linear gradients are 29% faster, radial 17-23%, `confetti`
17%.  Small renders do not regress: `24_gradients` at 800 px is 178 ms on main
and 177 ms after (medians of 9, interleaved), `confetti` at 800 px 286 -> 248.

### Where the time actually goes

The task's diagnosis does not hold up here: the divisions were real but small.
Four controls, all at `--width 2000`, 4.0 Mpx:

| control | main | +table |
|---|---|---|
| flat opaque fill (`Canvas.fillMask` fast path) | 325 | 251 |
| flat **translucent** fill — same read-modify-write blit | 1093 | 1102 |
| gradient, two **identical** stops (no channel interpolated) | 1378 | 1132 |
| gradient, two different stops | 1637 | 1168 |

A flat *translucent* fill — which reads, blends and writes each pixel exactly
as the shader loop does — already costs 1093 ms.  So of the ~328 ns/px the
task attributes to "gradient fill", about 192 ns/px is the generic
read-modify-write blit that any non-opaque fill pays, and only ~136 ns/px was
gradient-specific.  Of that, the whole channel interpolation — the four
divisions included — was ~65 ns/px (1637 vs 1378 for identical stops), and
removing the divisions recovered ~39 ns/px of it.  That is why change 1 alone
moved linear by 9%.

After all three, the gradient-specific cost is ~17 ns/px (1168 vs 1102): a
linear gradient now costs what a translucent flat colour costs.  Two further
experiments, kept out of the commit: replacing `paramAt` with a constant saves
40 ms on linear (so the affine evaluation is not the cost), and packing
`rampAt`'s four channels into one `Nat` made it 650 ms *slower*, so the tuple
return is not costing allocations.

The remaining gap to resvg (1168 vs 108 ms) is therefore no longer the
gradient: it is the blit loop and the rasterizer underneath it, which is
outside this task.

### Radial

`radial, 2 stops` costs 698 ms more than `linear, 2 stops` after the change
(175 ns/px), and the focal case another 729 ms.  Replacing `paramAt` with a
constant collapses the radial case to the linear one (1422 vs 1491 ms on the
`ramp` binary), so effectively all of the radial's extra cost is `paramAt`,
i.e. `hypot16`'s `Nat.sqrt` — plus, for the focal case, the quadratic's second
`Nat.sqrt` and its `mul16`/`div16`s.  Not optimised here, per the task.

### Why not the unconditional table

Built for every draw, the table is a large regression on documents with many
small gradient-filled shapes: `24_gradients` at 800 px (13 gradient draws)
goes 177 -> 273 ms, i.e. ~7.4 ms per build, while a 4 Mpx fill saves ~300 ms.
Gating on the mask's area gets both, and the gate is set at about three times
the analytic break-even (~80 000 painted pixels) because the mask's bounding
box over-counts a sparse shape.  A large, sparsely covered shape can still pay
~7 ms for a table it barely uses; that is the one case where this is a loss,
bounded at one build per draw.

A quantised table was never needed: both the reciprocal and the full table are
bit-exact.

### Verification

- `lake build`: clean, no errors, no warnings.
- `git diff origin/main -- LeanSvg/Effect.lean`: empty.
- `python3 tests/run_tests.py`: 23/27 pass; the 4 failures (12, 14, 15, 16)
  are main's own and unchanged.  **All 27 outputs are byte-identical to main's
  binary**, at natural size and at `--width 800` (`cmp` on the PNGs),
  `24_gradients` included (99.993% within 8, 92.145% exact — T18's numbers to
  the digit).
- Corpora, `--width 200`, direct route, against a same-width baseline from
  main's binary: `linearGradient` 40/40, `radialGradient` 45/45, `stop` 32/32,
  `stop-color` 1/1, `stop-opacity` 2/2, `painting/fill` 57/60 — every one of
  them exactly main's count, and the harness reports `0 file(s) moved by more
  than 0.1 points of within-8`, `newly failing 0`, `unchanged 211`.  (The
  task's expected 38/38 is the older suite; this checkout has 40 files, as
  T18's report already noted.)
- The `--width 200` corpora run is below `rampArea`, so it does not exercise
  the table.  As a direct check of that path, all 151 `paint-servers` files
  were rendered at `--width 600` with both binaries: **151/151 byte-identical**.
- `run_tiles.py`: 27/27 stitch byte-identically.
- `--threads 4` on `24_gradients` at 800 px is byte-identical to `--threads 1`
  and to main's binary.
- `run_adversarial.py`: 61/61 clean, 0 violations.
