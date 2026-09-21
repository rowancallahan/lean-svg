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
