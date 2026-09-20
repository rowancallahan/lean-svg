# T7 — Blend speed: runs and fast paths in `Canvas.fillMask`

## Goal

T3 measured the per-pixel blend in `Canvas.fillMask` at ~94 ms per megapixel
per covering shape, the dominant cost at every large size (overdraw
multiplies it). Make it several times faster with **byte-identical output**.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T7` (branch `t7-blend`).
Only `MicroSvg/Canvas.lean` may change (`fillMask` and helpers it needs).

## What to change (in order of expected payoff; measure each)

1. **Opaque full-coverage fast path.** When `a8 == 255` and `cov8 == 255`,
   `blendLerp` returns exactly the packed source (`div255(x·255) = x`), so
   write a precomputed packed `Nat` directly, no arithmetic.
2. **Run skipping.** Iterate each mask row as runs: skip runs of `cov == 0`
   without touching `px`; handle runs of `cov == 65536` with the fast path.
   Reading `m.cov` once per pixel is fine; the win is not doing the blend.
3. **Hoist per-row work**: `row + m.x0` computed once per row; avoid recomputing
   `cov8` for the two constant cases.
4. If still hot, check whether `px.setIfInBounds` / `getD` are the cost by
   comparing against a version that uses `Array.uset`/`uget` with proofs
   (`i.toNat < px.size` derived from `idx < w*h` and `px.size = w*h`; you may
   need to carry `hsize : px.size = w * h` as a structure field or a hypothesis
   parameter). Only adopt it if it is a measurable win and stays panic-free.

Invariants in `tasks/README.md` apply.

## Measure

Baseline: build main as-is in the worktree; render the whole corpus at natural
size and `--width 1600` to a temp dir, sha256 each PNG; run
`python3 tests/run_sizes.py --widths 400,1600 --runs 3` and keep the net ms.
After each step: bytes must be identical for every file (assert it in a small
script and paste the result); report ms before/after per file at 1600 and the
median speedup. Adversarial must stay clean. Confirm `Effect.lean` is untouched
(`git diff --stat main -- MicroSvg/Effect.lean` empty).

## Done when

Byte-identical corpus, measurable speedup reported per step. Append
`## Report`. Do not commit.
