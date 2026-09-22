/-
# WIP: the loose size bound — complete proof, does not finish elaborating

Append this to `SizeBound.lean` to run it. It has **no `sorry`**: both
branches are written out in full and there are no unsolved mathematical
goals. The problem is purely that Lean does not finish checking it.

Measured on an M-series laptop, 2026-09-21:

  | heartbeat limit | result                        | wall time |
  |-----------------|-------------------------------|-----------|
  | 200 000 (default) | timeout at `whnf`           | ~2 s      |
  | 1 000 000       | timeout at `whnf`             | 30 s      |
  | 4 000 000       | timeout at `whnf`             | 118 s     |
  | unlimited       | no result                     | > 400 s   |

More budget gets further each time, so nothing is stuck in a loop — it is
just quadratic-feeling traversal. `zlibStoredRows` inlines two nested loops,
so every tactic walks the whole expression, and the inner `split` has to
whnf a conditional whose branches are the entire loop body.

Extra cores do not help: Lean parallelises across declarations, not within
one.

## The strategy is correct and should be kept

  - `Std.Legacy.Range.forIn_eq_forIn_range'` turns the range loops into list
    loops.
  - `Id`'s bind needs a local `rfl` helper to reduce; it is not a simp lemma.
  - `[:h].size = h` needs `simp [Std.Legacy.Range.size]`, not `rfl`.
  - `forIn_measure_le` applies to the outer loop with the measure given
    **explicitly** as `fun s : ByteArray × Nat => s.1.size`. Supplying it is
    what keeps unification first-order, and it also means the duplicated
    `.snd` component is never examined.
  - Inside the per-iteration obligation, the same lemma applies to the inner
    loop with `fun s : ByteArray × Nat × Nat => s.1.size` and `k = 65540`.
  - The leaves are `size_copySlice_append_le`, `size_blockHeader` and
    `ByteArray.size_push`, all proved in `SizeBound.lean`.

## The fix

Rewrite `zlibStoredRows` as explicit recursion with `termination_by`, as
`PLAN.md` has recommended from the start. Terms stay small, `split` stops
normalising a giant conditional, and this proof should then go through
quickly. See `tasks/T46-recursive-zlib-rows.md`.
-/

namespace LeanSvg.Png.SizeBound
set_option maxRecDepth 8000 in
set_option maxHeartbeats 0 in
theorem zlib_le (out rgba : ByteArray) (rowBytes h : Nat) :
    (zlibStoredRows out rgba rowBytes h).size
      ≤ out.size + 11 + h * (6 + (rowBytes / 65535 + 2) * 65540) := by
  have hbind : ∀ {γ : Type} (e : Id (ByteArray × Nat)) (k : ByteArray × Nat → Id γ),
      (e >>= k) = k e := fun _ _ => rfl
  have hpure : ∀ x : ByteArray, ByteArray.size (pure x : Id ByteArray) = x.size :=
    fun _ => rfl
  have hrs : [:h].size = h := by simp [Std.Legacy.Range.size]
  have hrp : [:rowBytes / 65535 + 2].size = rowBytes / 65535 + 2 := by
    simp [Std.Legacy.Range.size]
  unfold zlibStoredRows
  simp only [Id.run, hbind, Std.Legacy.Range.forIn_eq_forIn_range']
  split
  · simp only [hpure, ByteArray.size_append, size_be32, size_blockHeader]
    refine Nat.le_trans (Nat.add_le_add_right (Nat.add_le_add_right
      (forIn_measure_le (fun s : ByteArray × Nat => s.1.size)
        (6 + (rowBytes / 65535 + 2) * 65540) _ ?step1 _ _) 5) 4) ?fin1
    case fin1 => simp only [List.length_range', hrs, ByteArray.size_push]; omega
    case step1 =>
      intro a b
      split
      · refine Nat.le_trans (forIn_measure_le
          (fun s : ByteArray × Nat × Nat => s.1.size) 65540 _ ?isA _ _) ?ifA
        case ifA =>
          simp only [List.length_range', hrp, ByteArray.size_push, size_blockHeader]
          omega
        case isA =>
          intro x s
          split
          · split
            · exact Nat.le_trans (size_copySlice_append_le _ _ _ _ _)
                (by rw [size_blockHeader]
                    have : (65535 - s.snd.fst % 65535).min
                        (a * rowBytes + rowBytes - s.snd.snd) ≤ 65535 :=
                      Nat.le_trans (Nat.min_le_left _ _) (by omega)
                    omega)
            · exact Nat.le_trans (size_copySlice_append_le _ _ _ _ _)
                (by have : (65535 - s.snd.fst % 65535).min
                        (a * rowBytes + rowBytes - s.snd.snd) ≤ 65535 :=
                      Nat.le_trans (Nat.min_le_left _ _) (by omega)
                    omega)
          · omega
      · refine Nat.le_trans (forIn_measure_le
          (fun s : ByteArray × Nat × Nat => s.1.size) 65540 _ ?isB _ _) ?ifB
        case ifB =>
          simp only [List.length_range', hrp, ByteArray.size_push]
          omega
        case isB =>
          intro x s
          split
          · split
            · exact Nat.le_trans (size_copySlice_append_le _ _ _ _ _)
                (by rw [size_blockHeader]
                    have : (65535 - s.snd.fst % 65535).min
                        (a * rowBytes + rowBytes - s.snd.snd) ≤ 65535 :=
                      Nat.le_trans (Nat.min_le_left _ _) (by omega)
                    omega)
            · exact Nat.le_trans (size_copySlice_append_le _ _ _ _ _)
                (by have : (65535 - s.snd.fst % 65535).min
                        (a * rowBytes + rowBytes - s.snd.snd) ≤ 65535 :=
                      Nat.le_trans (Nat.min_le_left _ _) (by omega)
                    omega)
          · omega
  · simp only [hpure, ByteArray.size_append, size_be32]
    refine Nat.le_trans (Nat.add_le_add_right
      (forIn_measure_le (fun s : ByteArray × Nat => s.1.size)
        (6 + (rowBytes / 65535 + 2) * 65540) _ ?step2 _ _) 4) ?fin2
    case fin2 => simp only [List.length_range', hrs, ByteArray.size_push]; omega
    case step2 =>
      intro a b
      split
      · refine Nat.le_trans (forIn_measure_le
          (fun s : ByteArray × Nat × Nat => s.1.size) 65540 _ ?isA _ _) ?ifA
        case ifA =>
          simp only [List.length_range', hrp, ByteArray.size_push, size_blockHeader]
          omega
        case isA =>
          intro x s
          split
          · split
            · exact Nat.le_trans (size_copySlice_append_le _ _ _ _ _)
                (by rw [size_blockHeader]
                    have : (65535 - s.snd.fst % 65535).min
                        (a * rowBytes + rowBytes - s.snd.snd) ≤ 65535 :=
                      Nat.le_trans (Nat.min_le_left _ _) (by omega)
                    omega)
            · exact Nat.le_trans (size_copySlice_append_le _ _ _ _ _)
                (by have : (65535 - s.snd.fst % 65535).min
                        (a * rowBytes + rowBytes - s.snd.snd) ≤ 65535 :=
                      Nat.le_trans (Nat.min_le_left _ _) (by omega)
                    omega)
          · omega
      · refine Nat.le_trans (forIn_measure_le
          (fun s : ByteArray × Nat × Nat => s.1.size) 65540 _ ?isB _ _) ?ifB
        case ifB =>
          simp only [List.length_range', hrp, ByteArray.size_push]
          omega
        case isB =>
          intro x s
          split
          · split
            · exact Nat.le_trans (size_copySlice_append_le _ _ _ _ _)
                (by rw [size_blockHeader]
                    have : (65535 - s.snd.fst % 65535).min
                        (a * rowBytes + rowBytes - s.snd.snd) ≤ 65535 :=
                      Nat.le_trans (Nat.min_le_left _ _) (by omega)
                    omega)
            · exact Nat.le_trans (size_copySlice_append_le _ _ _ _ _)
                (by have : (65535 - s.snd.fst % 65535).min
                        (a * rowBytes + rowBytes - s.snd.snd) ≤ 65535 :=
                      Nat.le_trans (Nat.min_le_left _ _) (by omega)
                    omega)
          · omega
end LeanSvg.Png.SizeBound
