import LeanSvg.Png
open LeanSvg Png

def ForInStep.val {β : Type} : ForInStep β → β
  | .done b => b
  | .yield b => b

theorem forIn_measure_le {α β : Type} (sz : β → Nat) (k : Nat)
    (f : α → β → Id (ForInStep β))
    (hstep : ∀ a b, sz (f a b).val ≤ sz b + k) :
    ∀ (l : List α) (init : β),
      sz (Id.run (forIn l init f)) ≤ sz init + l.length * k := by
  intro l
  induction l with
  | nil => intro init; show sz init ≤ sz init + 0 * k; omega
  | cons a as ih =>
    intro init
    have h1 := hstep a init
    have h2 := ih
    simp only [List.forIn_cons, List.length_cons, Nat.succ_mul]
    cases hf : f a init with
    | done b =>
      simp only [hf, ForInStep.val] at h1
      show sz b ≤ sz init + (as.length * k + k); omega
    | yield b =>
      simp only [hf, ForInStep.val] at h1
      have h3 := h2 b
      show sz (Id.run (forIn as b f)) ≤ sz init + (as.length * k + k); omega

-- what does the goal look like after unfolding + range->list?
example (out rgba : ByteArray) (rowBytes h : Nat) : True := by
  have : (zlibStoredRows out rgba rowBytes h).size ≤ 0 := by

theorem size_blockHeader (out : ByteArray) (pos rawSize : Nat) :
    (blockHeader out pos rawSize).size = out.size + 5 := by
  simp only [blockHeader, ByteArray.size_push]
theorem size_be32' (n : Nat) : (be32 n).size = 4 := by
  simp only [be32, ByteArray.size_push]; rfl

example (out rgba : ByteArray) (rowBytes h : Nat) :
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
  simp only [Id.run, hbind, hpure, Std.Legacy.Range.forIn_eq_forIn_range',
    ByteArray.size_append, size_be32', size_blockHeader, List.length_range', hrs, hrp]
  split <;>
  · refine Nat.le_trans (Nat.add_le_add_right ?hs _) ?fin
    case hs =>
      exact forIn_measure_le (fun s : ByteArray × Nat => s.1.size)
        (6 + (rowBytes / 65535 + 2) * 65540) _ ?step _ _
    case fin => simp only [ByteArray.size_push]; omega
    case step => sorry
