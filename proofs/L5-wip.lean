/-
WIP: the loose size bound, strategy verified, blocked on elaborator cost.

Append this to `SizeBound.lean` to run it. The proof is structurally complete
for the `rawSize == 0` branch: there are no logic errors and no unsolved
mathematical goals. Every tactic times out instead, at `whnf`, because
`zlibStoredRows` inlines two nested loops and every tactic has to traverse
the whole term. 4,000,000 heartbeats and two minutes were not enough.

The strategy is confirmed correct and is the one to keep:

  - reduce the range loops with `Std.Legacy.Range.forIn_eq_forIn_range'`,
  - reduce `Id`'s bind with a local `rfl` helper,
  - apply `forIn_measure_le` to the outer loop with the measure supplied
    explicitly as `fun s : ByteArray x Nat => s.1.size`, which keeps
    unification first-order and dodges the duplicated `.snd` component,
  - inside the per-iteration obligation, apply it again to the inner loop
    with `fun s : ByteArray x Nat x Nat => s.1.size` and k = 65540,
  - discharge the leaves with `size_copySlice_append_le`, `size_blockHeader`
    and `ByteArray.size_push`.

What defeats it is term size, not difficulty. The fix is the restructure
`PLAN.md` has recommended all along: rewrite `zlibStoredRows` as explicit
recursion with `termination_by`. Terms then stay small, `split` stops
whnf-ing a giant `if`, and this same proof should go through quickly. That
is a change to real encoding code and needs the byte-identity harness.

namespace LeanSvg.Png.SizeBound
set_option maxRecDepth 8000 in
set_option maxHeartbeats 1000000 in
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
        (6 + (rowBytes / 65535 + 2) * 65540) _ ?step _ _) 5) 4) ?fin
    case fin => simp only [List.length_range', hrs, ByteArray.size_push]; omega
    case step =>
      intro a b
      split
      · refine Nat.le_trans (forIn_measure_le
          (fun s : ByteArray × Nat × Nat => s.1.size) 65540 _ ?is _ _) ?if1
        case if1 =>
          simp only [List.length_range', hrp, ByteArray.size_push, size_blockHeader]
          omega
        case is =>
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
          (fun s : ByteArray × Nat × Nat => s.1.size) 65540 _ ?is2 _ _) ?if2
        case if2 =>
          simp only [List.length_range', hrp, ByteArray.size_push]
          omega
        case is2 =>
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
  · sorry
end LeanSvg.Png.SizeBound
