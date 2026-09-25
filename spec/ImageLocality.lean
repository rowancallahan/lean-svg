/-
# Locality of the `<image>` draw (T63)

An `<image>` is drawn by `Canvas.fillMaskImage`: its coverage mask is the
rasterized destination rectangle (the placed view box under the CTM, clipped
to the document window, the layer and any `clip-path`), and the paint is the
image sampler.  This file proves that the draw changes no pixel outside the
mask's rectangle, and — the image-specific corollary — none outside any
rectangle that contains the mask's, so an image never paints outside its
destination box.  Same argument as `fillMaskShader_local` in
`spec/Locality.lean` (repeated here since proof files do not import each
other): the sampler only decides *what* colour is written, never *where*.

Check with `lake env lean spec/ImageLocality.lean`.
-/
import LeanSvg.Image

/-- The state carried by a `ForInStep`, whichever constructor it used. -/
def ForInStep.val {β : Type} : ForInStep β → β
  | .done b => b
  | .yield b => b

namespace LeanSvg.ImageLocality

open LeanSvg

/-- The flat index `i` lies inside the `rw × rh` rectangle at `(x0, y0)` on a
canvas of row stride `stride` (`Locality.lean`'s `inRect`). -/
def inRect (x0 y0 rw rh stride i : Nat) : Prop :=
  ∃ x y, x < rw ∧ y < rh ∧ i = (y0 + y) * stride + (x0 + x)

theorem forIn_invariant_mem {α β : Type} (P : β → Prop) (l : List α)
    (f : α → β → Id (ForInStep β))
    (hstep : ∀ a ∈ l, ∀ b, P b → P (f a b).val) :
    ∀ init, P init → P (Id.run (forIn l init f)) := by
  induction l with
  | nil => intro init h; exact h
  | cons a as ih =>
    intro init h
    have h1 := hstep a List.mem_cons_self init h
    simp only [List.forIn_cons]
    cases hf : f a init with
    | done b =>
      simp only [hf, ForInStep.val] at h1
      show P b
      exact h1
    | yield b =>
      simp only [hf, ForInStep.val] at h1
      show P (Id.run (forIn as b f))
      exact ih (fun a' ha' => hstep a' (List.mem_cons_of_mem a ha')) b h1

theorem forIn_range_invariant {β : Type} (P : β → Prop) (n : Nat)
    (f : Nat → β → Id (ForInStep β))
    (hstep : ∀ a, a < n → ∀ b, P b → P (f a b).val) :
    ∀ init, P init → P (Id.run (forIn ([0:n] : Std.Legacy.Range) init f)) := by
  intro init h
  have hl : ([0:n] : Std.Legacy.Range).size = n := by simp [Std.Legacy.Range.size]
  rw [Std.Legacy.Range.forIn_eq_forIn_range', hl]
  apply forIn_invariant_mem _ _ f _ init h
  intro a ha b hb
  have h2 := List.mem_range'_1.1 ha
  have h3 : ([0:n] : Std.Legacy.Range).start = 0 := rfl
  exact hstep a (by omega) b hb

theorem getD_setIfInBounds_ne {xs : Array Nat} {idx i : Nat} (h : idx ≠ i) (v : Nat) :
    (xs.setIfInBounds idx v).getD i 0 = xs.getD i 0 := by
  simp [Array.getD_eq_getD_getElem?, Array.getElem?_setIfInBounds_ne h]

/-- `Canvas.fillMaskImage` never writes outside the mask's rectangle. -/
theorem fillMaskImage_local (cv : Canvas) (m : Raster.Mask) (sh : Image.Rt) (i : Nat)
    (hi : ¬ inRect m.x0 m.y0 m.w m.h cv.w i) :
    (Canvas.fillMaskImage cv m sh).px.getD i 0 = cv.px.getD i 0 := by
  unfold Canvas.fillMaskImage
  simp only [Id.run, bind, pure]
  apply forIn_range_invariant (fun (s : Array Nat) => s.getD i 0 = cv.px.getD i 0) m.h
  · intro y hy s hs
    simp only [ForInStep.val]
    apply forIn_range_invariant (fun (s' : Array Nat) => s'.getD i 0 = cv.px.getD i 0) m.w
    · intro x hx s' hs'
      have hidx : (m.y0 + y) * cv.w + m.x0 + x ≠ i := by
        intro heq
        exact hi ⟨x, y, hx, hy, by omega⟩
      repeat' split
      all_goals simp only [ForInStep.val]
      all_goals first | exact hs' | (rw [getD_setIfInBounds_ne hidx]; exact hs')
    · exact hs
  · rfl

/-- The image-specific corollary: if the mask's rectangle lies inside a
destination rectangle `(bx, by, bw, bh)`, no pixel outside that rectangle
changes.  `Render.drawShape` only ever hands `fillMaskImage` a mask that the
rasterizer built from the placed image rectangle and then `clipMask`/
`Clip.applyChain` narrowed (never widened), so this is "the image stays in its
box". -/
theorem fillMaskImage_in_box (cv : Canvas) (m : Raster.Mask) (sh : Image.Rt)
    (bx bY bw bh : Nat)
    (hsub : bx ≤ m.x0 ∧ bY ≤ m.y0 ∧ m.x0 + m.w ≤ bx + bw ∧ m.y0 + m.h ≤ bY + bh)
    (i : Nat) (hi : ¬ inRect bx bY bw bh cv.w i) :
    (Canvas.fillMaskImage cv m sh).px.getD i 0 = cv.px.getD i 0 := by
  apply fillMaskImage_local
  intro ⟨x, y, hx, hy, he⟩
  have ey : bY + (m.y0 - bY + y) = m.y0 + y := by omega
  have ex : bx + (m.x0 - bx + x) = m.x0 + x := by omega
  exact hi ⟨m.x0 - bx + x, m.y0 - bY + y, by omega, by omega, by rw [ey, ex]; exact he⟩

/-- At most `m.w * m.h` pixels change under `fillMaskImage`. -/
theorem fillMaskImage_count (cv : Canvas) (m : Raster.Mask) (sh : Image.Rt) :
    ∃ l : List Nat, l.length = m.w * m.h ∧
      ∀ i, (Canvas.fillMaskImage cv m sh).px.getD i 0 ≠ cv.px.getD i 0 → i ∈ l := by
  refine ⟨(List.range m.h).flatMap
    (fun y => (List.range m.w).map (fun x => (m.y0 + y) * cv.w + (m.x0 + x))), ?_, ?_⟩
  · simp only [List.length_flatMap, List.length_map, List.length_range, List.map_const',
      List.sum_replicate_nat]
    rw [Nat.mul_comm]
  · intro i hne
    apply Classical.byContradiction
    intro hn
    apply hne (fillMaskImage_local cv m sh i _)
    intro ⟨x, y, hx, hy, he⟩
    apply hn
    simp only [List.mem_flatMap, List.mem_map, List.mem_range]
    exact ⟨y, hy, x, hx, he.symm⟩

end LeanSvg.ImageLocality

-- Public theorem audit: only standard Lean axioms, never `sorryAx`.
#print axioms LeanSvg.ImageLocality.fillMaskImage_local
#print axioms LeanSvg.ImageLocality.fillMaskImage_in_box
#print axioms LeanSvg.ImageLocality.fillMaskImage_count
