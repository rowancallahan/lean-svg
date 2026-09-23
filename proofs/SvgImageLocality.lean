/-
# Locality of an SVG image (T84)

An `<image>` of an SVG document renders its sub-document into a layer that is
the image viewport's device box (`SvgImage.devBox`, whole pixels rounded
outwards) cut to the window being painted (`SvgImage.layerBox`), and
`SvgImage.composite` puts that layer back at its place.  Whatever the
sub-document draws, the layer is all that is composited, so no pixel outside
the viewport's device box changes: `svgImage_in_box`.

The argument is `compositeNormal_local` of `proofs/Locality.lean` (repeated
here since proof files do not import each other), sharpened by the loop's own
`x ≥ w` break so that it speaks of pixel coordinates rather than flat indices.

Check with `lake env lean proofs/SvgImageLocality.lean`.
-/
import LeanSvg.SvgImage

/-- The state carried by a `ForInStep`, whichever constructor it used. -/
def ForInStep.val {β : Type} : ForInStep β → β
  | .done b => b
  | .yield b => b

namespace LeanSvg.SvgImageLocality

open LeanSvg

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

/-- Row and column of a flat index are unique on a row of width `w`. -/
theorem rowcol {w a b c d : Nat} (hb : b < w) (hd : d < w) (h : a * w + b = c * w + d) :
    a = c ∧ b = d := by
  have hm : (a * w + b) % w = (c * w + d) % w := by rw [h]
  have hq : (a * w + b) / w = (c * w + d) / w := by rw [h]
  have hw : 0 < w := by omega
  rw [Nat.mul_comm a, Nat.mul_comm c, Nat.mul_add_mod, Nat.mul_add_mod,
    Nat.mod_eq_of_lt hb, Nat.mod_eq_of_lt hd] at hm
  rw [Nat.mul_comm a, Nat.mul_comm c, Nat.mul_add_div hw, Nat.mul_add_div hw,
    Nat.div_eq_of_lt hb, Nat.div_eq_of_lt hd] at hq
  omega

/-- `SvgImage.composite` changes no pixel `(X, Y)` of `cv` outside the layer's
rectangle `[ox, ox + layer.w) × [oy, oy + layer.h)`. -/
theorem composite_local (cv layer : Canvas) (ox oy X Y : Nat) (hX : X < cv.w)
    (hout : ¬ (ox ≤ X ∧ X < ox + layer.w ∧ oy ≤ Y ∧ Y < oy + layer.h)) :
    (SvgImage.composite cv layer ox oy).px.getD (Y * cv.w + X) 0 =
      cv.px.getD (Y * cv.w + X) 0 := by
  unfold SvgImage.composite Canvas.compositeNormal
  simp only [Id.run, bind, pure]
  apply forIn_range_invariant
    (fun (s : Array Nat) => s.getD (Y * cv.w + X) 0 = cv.px.getD (Y * cv.w + X) 0) layer.h
  · intro ly hly s hs
    split
    · simp only [ForInStep.val]; exact hs
    · simp only [ForInStep.val]
      apply forIn_range_invariant
        (fun (s' : Array Nat) => s'.getD (Y * cv.w + X) 0 = cv.px.getD (Y * cv.w + X) 0) layer.w
      · intro lx hlx s' hs'
        repeat' split
        all_goals simp only [ForInStep.val]
        all_goals first
          | exact hs'
          | (rw [getD_setIfInBounds_ne]
             · exact hs'
             · intro heq
               have ⟨h1, h2⟩ := rowcol (by omega) hX heq
               exact hout ⟨by omega, by omega, by omega, by omega⟩)
      · exact hs
  · rfl

/-- `layerBox` lies inside the device box it was cut from, and inside the
window. -/
theorem layerBox_sub {b : Int × Int × Int × Int} {cx0 cy0 cx1 cy1 x0 y0 x1 y1 : Nat}
    (h : SvgImage.layerBox b cx0 cy0 cx1 cy1 = some (x0, y0, x1, y1)) :
    b.1 ≤ x0 ∧ b.2.1 ≤ y0 ∧ (x1 : Int) ≤ b.2.2.1 ∧ (y1 : Int) ≤ b.2.2.2 ∧
      cx0 ≤ x0 ∧ cy0 ≤ y0 ∧ x1 ≤ cx1 ∧ y1 ≤ cy1 ∧ x0 < x1 ∧ y0 < y1 := by
  obtain ⟨bx0, by0, bx1, by1⟩ := b
  unfold SvgImage.layerBox at h
  simp only at h
  split at h
  · cases h
  · rename_i hne
    simp only [Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl, rfl, rfl⟩ := h
    simp only [Bool.or_eq_true, decide_eq_true_eq, not_or, Int.not_le] at hne
    dsimp only
    omega

/-- **An SVG image stays in its box.**  `SvgImage.draw` is what the renderer
calls with the rendered layer `L`, the box `layerBox` gave for the image
viewport's device box `b`, and the position `(ox, oy)` of the canvas painted.
A pixel `(X, Y)` of that canvas whose position `(X + ox, Y + oy)` lies outside
`b` does not change, whatever `L` holds. -/
theorem svgImage_in_box (cv L : Canvas) (b : Int × Int × Int × Int)
    (cx0 cy0 cx1 cy1 x0 y0 x1 y1 ox oy X Y : Nat)
    (hb : SvgImage.layerBox b cx0 cy0 cx1 cy1 = some (x0, y0, x1, y1))
    (hX : X < cv.w)
    (hout : ¬ (b.1 ≤ (X + ox : Nat) ∧ ((X + ox : Nat) : Int) < b.2.2.1 ∧
               b.2.1 ≤ (Y + oy : Nat) ∧ ((Y + oy : Nat) : Int) < b.2.2.2)) :
    (SvgImage.draw cv L (x0, y0, x1, y1) ox oy).px.getD (Y * cv.w + X) 0 =
      cv.px.getD (Y * cv.w + X) 0 := by
  have hs := layerBox_sub hb
  unfold SvgImage.draw
  simp only
  split
  · rename_i hc
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
    obtain ⟨⟨⟨hw, hh⟩, hox⟩, hoy⟩ := hc
    apply composite_local cv L _ _ X Y hX
    intro ⟨h1, h2, h3, h4⟩
    apply hout
    omega
  · rfl

end LeanSvg.SvgImageLocality

-- Public theorem audit: only standard Lean axioms, never `sorryAx`.
#print axioms LeanSvg.SvgImageLocality.composite_local
#print axioms LeanSvg.SvgImageLocality.layerBox_sub
#print axioms LeanSvg.SvgImageLocality.svgImage_in_box
