# T46 — rewrite `zlibStoredRows` as explicit recursion, then close the size bound

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
