# T46 — rewrite `zlibStoredRows` as explicit recursion, then close the size bound

**Completed.** See the report below and `proofs/SizeBound.lean`. The original
handoff follows for context. Its description of L5 as a complete proof meant
an unelaborated candidate; only the replacement has been checked by Lean.

Hand-off task. Everything needed is already written; what is missing is a
restructure of one function so that Lean can actually check the proof.

## Why

`proofs/SizeBound.lean` proves the PNG container layer and all the leaf
lemmas. `proofs/L5-wip.lean` contains a **complete proof** of the remaining
piece — no `sorry`, no unsolved mathematical goals. Lean will not finish
elaborating it.

Measured on an M-series laptop, 2026-09-21:

| heartbeat limit | result | wall time |
|---|---|---|
| 200 000 (default) | timeout at `whnf` | ~2 s |
| 1 000 000 | timeout at `whnf` | 30 s |
| 4 000 000 | timeout at `whnf` | 118 s |
| unlimited | no result | > 400 s |

Each increase gets further, so nothing is diverging. `zlibStoredRows`
(`LeanSvg/Png.lean:187`) inlines two nested `for` loops over mutable state,
so every tactic step traverses the whole expression and the inner `split`
has to whnf a conditional whose branches are the entire loop body. Extra
cores do not help — Lean parallelises across declarations, not within one.

## The change

Rewrite `LeanSvg/Png.lean`'s `zlibStoredRows` as explicit structural
recursion with `termination_by`, replacing the nested `for`/`let mut`. This
is what `PLAN.md` M3 step 4 has recommended from the start.

Constraints:

1. **Byte-identical output.** This is an encoder. Not "close", identical.
2. **No slower.** The current version is on the hot path. Tail recursion
   should compile to the same loop, but measure, do not assume.
3. All invariants in `tasks/README.md` apply. In particular no `partial`,
   which is why it needs `termination_by` rather than well-founded hand-
   waving.
4. Do not touch `LeanSvg/Effect.lean`.

Keep the same decomposition the loop has now: outer over `h` rows, inner over
`pieces = rowBytes / 65535 + 2` fragments, carrying `(out, pos, off)`.

## Then the proof

Port `proofs/L5-wip.lean` onto the new definition and append it to
`proofs/SizeBound.lean`, replacing the `sorry` in `zlibStoredRows_size_le`.
The strategy is already validated and should survive the restructure almost
unchanged:

- `forIn_measure_le` becomes ordinary induction on the recursion's `Nat`
  argument, which is the point of the change.
- Keep supplying the measure explicitly (`fun s => s.1.size`). That is what
  keeps unification first-order.
- Leaves are `size_copySlice_append_le`, `size_blockHeader` and
  `ByteArray.size_push`, all already proved.
- Two gotchas worth not rediscovering: `Id`'s bind needs a local `rfl`
  helper, it is not a simp lemma; and `[:h].size = h` needs
  `simp [Std.Legacy.Range.size]`, not `rfl`.

The bound to prove is the loose one, which is deliberate — Rowan asked for a
cap that stops runaway output, not a tight number:

```
(zlibStoredRows out rgba rowBytes h).size
  ≤ out.size + 11 + h * (6 + (rowBytes / 65535 + 2) * 65540)
```

`encode_size_le` and `encode_size_le_const` already derive from it and
compile.

## Acceptance

1. `lake build` clean, no new warnings.
2. `python3 tests/run_tests.py` — byte-identical at natural size and
   `--width 800`. Any pixel difference fails the task.
3. `python3 tests/run_adversarial.py` — 61/61.
4. Timings at `--width 1600`, median of 3, against the current binary. A
   regression beyond noise fails the task.
5. `lake env lean proofs/SizeBound.lean` — **zero `sorry` warnings**, and it
   must finish in well under five minutes.
6. Axioms checked and reported, for every theorem in the file:

   ```
   #print axioms LeanSvg.Png.SizeBound.zlibStoredRows_size_le
   #print axioms LeanSvg.Png.SizeBound.encode_size_le
   #print axioms LeanSvg.Png.SizeBound.encode_size_le_const
   ```

   Expect `[propext, Quot.sound]`. Any `sorryAx` means the task is not done.
   `Quot.sound` is standard and comes from core's `List.forIn_cons` and
   `Array.size_append`.

## Stop rule

If the restructure cannot be made byte-identical, or costs measurable speed,
stop and report rather than trading either away. The bound is worth having
but not at the cost of the encoder.

## Afterwards

Update `SPEC.md` section 4: the output-size entry moves from "not
established" to section 1, stated as an upper bound on the `ByteArray` that
`Png.encode` returns, and explicitly **not** a claim about the file on disk.

## Report

Implemented two structural-recursion helpers in `LeanSvg/Png.lean`, keeping
stored-block bytes unchanged. The inner helper can stop once the row is
exhausted; all remaining iterations of the original loop were no-ops.
`LeanSvg/Effect.lean` is untouched. No dependencies or additional axioms added.

`proofs/SizeBound.lean` now has checked proofs with no holes. It counts the
remaining row bytes once, plus five header bytes per fragment iteration.
This improves the old loose candidate to:

- Encoder rectangular bound: `68 + h * (4*w + 16 + 5*(4*w / 65535))`.
- Encoder square bound: `5 * max(w,h)^2 + 132`, for all dimensions and any
  source array length, including empty or short sources.
- Successful pure `render`: at most **67,452,996 bytes**, using both the
  existing edge and area limits. Covers serial, parallel and tile output.

These are function-output bounds only. The filesystem, OS and IO interpreter
are outside their scope. `SPEC.md`, `README.md` and `ROADMAP.md` now reflect
this; the superseded L5 file is a historical note rather than unchecked code.
The generic loop lemmas from the earlier attempt remain available.

Validation:

- `lake build`: success, no new warnings.
- Size proof plus axiom audit: about 1.3 seconds, default heartbeat limit.
  Encoder bounds use `[propext, Quot.sound]`; renderer bounds use
  `[propext, Classical.choice, Quot.sound]`; no `sorryAx`.
- 54/54 corpus byte comparisons with the saved pre-change executable:
  all 27 images at natural size and at width 800.
- 8/8 additional byte comparisons: 1x1, 1x16384, 16384x1, 16383x2,
  16384x2, 255x257, 256x256, 800x800.
- `lake env lean --run tests/PngSizeTests.lean`: 256/256 writer comparisons
  with the original loop implementation, covering zero dimensions, empty,
  short and oversized sources, nonempty destinations, and 65535-byte block
  boundaries (including rows spanning more than two blocks).
- Fidelity harness: 23/27, the same four existing failures (badge, flower,
  spiral, stress); byte identity establishes no regression.
- Adversarial harness: 61/61 clean. Harness output redirected under
  `/tmp/lean-svg-size-bound`; existing `tests/out` was not modified.
- Interleaved whole-render timings, width 1600, median of three (ms):

  | image | before | after |
  |---|---:|---:|
  | confetti | 229.83 | 230.75 |
  | stress | 691.96 | 698.83 |
  | gradients | 343.53 | 343.43 |

  Changes range from -0.03% to +0.99%; no clear regression in this short
  measurement. No commits made.

### Follow-up: tighten the square coefficient

Reduced the square bound from `8 * max(w,h)^2 + 100` to
`5 * max(w,h)^2 + 132` using only arithmetic on the existing rectangular
bound. No renderer or encoder implementation changes. The public theorem
and renderer connection check in 1.49 seconds with the same standard axioms
and no proof holes. A coefficient of three with a small constant cannot
cover arbitrary squares: uncompressed RGBA already requires four bytes per
pixel before framing.

Quick recheck: build clean; 256/256 writer regressions and 15/15 byte
comparisons against the pre-refactor binary for serial, parallel and viewport
renders. The current executable SHA256 stayed unchanged throughout this
proof-only tightening.

Width-1600 median-of-three timing changes were +0.70% confetti, +3.36%
stress and +0.10% gradients. Because stress was above the earlier noise
range, it was rechecked after warmup with seven alternating pairs:
696.70 ms before versus 700.30 ms after (+0.52% by medians; +0.76% median
paired change). The larger initial change did not persist; no clear
performance regression was detected. These timings compare the previous
encoder refactor to its baseline, not a runtime change in this follow-up.
