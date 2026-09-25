/-
# Locality of the per-shape compositing loops

`ROADMAP.md` §3b, "the cheap half": `Canvas.fillMask`, `Shader.fillMaskShader`,
`Canvas.compositeNormal` and `Canvas.compositeBlend` never write outside a
rectangle determined by their arguments — the mask's rectangle for the first
two, the layer's rectangle for the last two. Every write in all four goes
through `Array.setIfInBounds` at an index built as `(y0 + row) * stride +
(x0 + col)` with `row`/`col` bounded by the loop's own range, so the shape of
the argument below (`inRect`) always holds of a written index.

Check with `lake env lean spec/Locality.lean`.
-/
import LeanSvg.Canvas
import LeanSvg.Shader

/-- The state carried by a `ForInStep`, whichever constructor it used
(`SizeBound.lean`'s definition, repeated here since proof files do not
import each other). -/
def ForInStep.val {β : Type} : ForInStep β → β
  | .done b => b
  | .yield b => b

namespace LeanSvg

/-- The flat index `i` sits inside the `rw × rh` rectangle whose top-left
corner is `(x0, y0)`, on a canvas of row stride `stride`. Every write in the
four loops below is at such an index, with `x`/`y` the loop variables that
produced it. -/
def inRect (x0 y0 rw rh stride i : Nat) : Prop :=
  ∃ x y, x < rw ∧ y < rh ∧ i = (y0 + y) * stride + (x0 + x)

/-! ## A `for`-loop invariant, scoped to the list actually walked

`Std.Legacy.Range.forIn_eq_forIn_range'` (a core `simp` lemma) rewrites
`forIn r init f` — what `for a in [s:t] do ...` compiles to — into `forIn
(List.range' r.start r.size r.step) init f`, a plain `List.forIn`. This plays
the role of `SizeBound.lean`'s `forIn_invariant`, but with the step
hypothesis scoped to `a ∈ l` rather than universally quantified: every loop
below needs to know its index is below the range's bound (to place the
written pixel in the rectangle), and that only holds for members of the list
actually walked, not for every `Nat`. It also has to hold for `.done` as much
as for `.yield` (`compositeNormal`/`compositeBlend` `break` out of both
loops), which `ForInStep.val` handles uniformly: whichever way a step ends
the loop, it is the invariant on the *carried state* that matters. -/
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

/-- Specialised to `[0:n]` (a `Std.Legacy.Range` with `start = 0`, `step = 1`,
which is what every loop below is): the step property only needs to hold
below `n`, matching what a reader of the `for` loop already knows about its
own variable. -/
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

/-- A write at any index other than `i` leaves `i` alone, whether or not the
write was in bounds. This is the one fact that makes every branch of every
loop below trivial: none of them ever reads back what colour was written,
only *whether* index `i` was touched. -/
theorem getD_setIfInBounds_ne {xs : Array Nat} {idx i : Nat} (h : idx ≠ i) (v : Nat) :
    (xs.setIfInBounds idx v).getD i 0 = xs.getD i 0 := by
  simp [Array.getD_eq_getD_getElem?, Array.getElem?_setIfInBounds_ne h]

/-! ## The four loops -/

/-- `Canvas.fillMask` never writes outside the mask's rectangle. -/
theorem fillMask_local (cv : Canvas) (m : Raster.Mask) (c : Rgba) (a i : Nat)
    (hi : ¬ inRect m.x0 m.y0 m.w m.h cv.w i) :
    (Canvas.fillMask cv m c a).px.getD i 0 = cv.px.getD i 0 := by
  unfold Canvas.fillMask
  simp only [Id.run, bind, pure]
  split
  · rfl
  · apply forIn_range_invariant (fun (s : Array Nat) => s.getD i 0 = cv.px.getD i 0) m.h
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

/-- `Shader.fillMaskShader` never writes outside the mask's rectangle. Same
proof as `fillMask_local`: the gradient lookup only changes *what* colour is
written, never *whether* index `i` is, and the `none` case from `Grad.paramAt`
is a `continue` just like `fillMask`'s low-coverage skip. -/
theorem fillMaskShader_local (cv : Canvas) (m : Raster.Mask) (sh0 : Grad.Rt) (i : Nat)
    (hi : ¬ inRect m.x0 m.y0 m.w m.h cv.w i) :
    (Canvas.fillMaskShader cv m sh0).px.getD i 0 = cv.px.getD i 0 := by
  unfold Canvas.fillMaskShader
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

/-- `Canvas.compositeNormal` never writes outside the layer's rectangle
(`ox`, `oy`, `layer.w`, `layer.h`). The `break`s that stop each loop once it
runs past `cv`'s edge (`oy + ly ≥ cv.h`, `ox + lx ≥ cv.w`) end the loop with
`ForInStep.done`, which `forIn_range_invariant` treats exactly like
`ForInStep.yield`: `.val` extracts the carried array either way, and a `break`
before any write in that iteration is a no-op on the array — same as
`fillMask`'s `continue`. -/
theorem compositeNormal_local (cv layer : Canvas) (ox oy opQ i : Nat)
    (hi : ¬ inRect ox oy layer.w layer.h cv.w i) :
    (Canvas.compositeNormal cv layer ox oy opQ).px.getD i 0 = cv.px.getD i 0 := by
  unfold Canvas.compositeNormal
  simp only [Id.run, bind, pure]
  apply forIn_range_invariant (fun (s : Array Nat) => s.getD i 0 = cv.px.getD i 0) layer.h
  · intro ly hly s hs
    split
    · simp only [ForInStep.val]; exact hs
    · simp only [ForInStep.val]
      apply forIn_range_invariant (fun (s' : Array Nat) => s'.getD i 0 = cv.px.getD i 0) layer.w
      · intro lx hlx s' hs'
        have hidx : (oy + ly) * cv.w + (ox + lx) ≠ i := fun heq => hi ⟨lx, ly, hlx, hly, heq.symm⟩
        repeat' split
        all_goals simp only [ForInStep.val]
        all_goals first | exact hs' | (rw [getD_setIfInBounds_ne hidx]; exact hs')
      · exact hs
  · rfl

/-- `Canvas.compositeBlend` never writes outside the layer's rectangle.
Same shape as `compositeNormal_local`; the `srcTab`/`byteTab` tables hoisted
above the loop are opaque to this proof (only the write index matters, not
the colour), so the walk is single-`split` at the row level, same as
`compositeNormal`. -/
theorem compositeBlend_local (cv layer : Canvas) (ox oy : Nat) (opacity : F32) (mode : BlendMode)
    (i : Nat) (hi : ¬ inRect ox oy layer.w layer.h cv.w i) :
    (Canvas.compositeBlend cv layer ox oy opacity mode).px.getD i 0 = cv.px.getD i 0 := by
  unfold Canvas.compositeBlend
  simp only [Id.run, bind, pure]
  apply forIn_range_invariant (fun (s : Array Nat) => s.getD i 0 = cv.px.getD i 0) layer.h
  · intro ly hly s hs
    split
    · simp only [ForInStep.val]; exact hs
    · simp only [ForInStep.val]
      apply forIn_range_invariant (fun (s' : Array Nat) => s'.getD i 0 = cv.px.getD i 0) layer.w
      · intro lx hlx s' hs'
        have hidx : (oy + ly) * cv.w + (ox + lx) ≠ i := fun heq => hi ⟨lx, ly, hlx, hly, heq.symm⟩
        repeat' split
        all_goals simp only [ForInStep.val]
        all_goals first | exact hs' | (rw [getD_setIfInBounds_ne hidx]; exact hs')
      · exact hs
  · rfl

/-! ## The counting corollary

`inRect x0 y0 rw rh stride` is witnessed by a pair `(x, y)` ranging over
`rw * rh` combinations, so the set of indices it can hold of embeds into a
list of that length — regardless of whether distinct `(x, y)` pairs collide
into the same flat index (they can, if the rectangle overflows a row of the
canvas), which only makes the *actual* count of changed pixels smaller, never
larger. This is the "at most `rw * rh` pixels change" bound in a form that
needs no `Finset`/`Fintype` machinery, matching this repository's "no
dependencies, Lean core only" rule (`lakefile.toml`). -/
theorem inRect_count (x0 y0 rw rh stride : Nat) :
    ∃ l : List Nat, l.length = rw * rh ∧ ∀ i, inRect x0 y0 rw rh stride i → i ∈ l := by
  refine ⟨(List.range rh).flatMap
    (fun y => (List.range rw).map (fun x => (y0 + y) * stride + (x0 + x))), ?_, ?_⟩
  · simp only [List.length_flatMap, List.length_map, List.length_range, List.map_const',
      List.sum_replicate_nat]
    rw [Nat.mul_comm]
  · intro i hi
    obtain ⟨x, y, hx, hy, rfl⟩ := hi
    simp only [List.mem_flatMap, List.mem_map, List.mem_range]
    exact ⟨y, hy, x, hx, rfl⟩

/-- At most `m.w * m.h` pixels change under `fillMask`. -/
theorem fillMask_count (cv : Canvas) (m : Raster.Mask) (c : Rgba) (a : Nat) :
    ∃ l : List Nat, l.length = m.w * m.h ∧
      ∀ i, (Canvas.fillMask cv m c a).px.getD i 0 ≠ cv.px.getD i 0 → i ∈ l := by
  obtain ⟨l, hlen, hmem⟩ := inRect_count m.x0 m.y0 m.w m.h cv.w
  refine ⟨l, hlen, fun i hne => hmem i (Classical.byContradiction fun hn => hne (fillMask_local cv m c a i hn))⟩

/-- At most `m.w * m.h` pixels change under `fillMaskShader`. -/
theorem fillMaskShader_count (cv : Canvas) (m : Raster.Mask) (sh0 : Grad.Rt) :
    ∃ l : List Nat, l.length = m.w * m.h ∧
      ∀ i, (Canvas.fillMaskShader cv m sh0).px.getD i 0 ≠ cv.px.getD i 0 → i ∈ l := by
  obtain ⟨l, hlen, hmem⟩ := inRect_count m.x0 m.y0 m.w m.h cv.w
  refine ⟨l, hlen, fun i hne => hmem i (Classical.byContradiction fun hn => hne (fillMaskShader_local cv m sh0 i hn))⟩

/-- At most `layer.w * layer.h` pixels change under `compositeNormal`. -/
theorem compositeNormal_count (cv layer : Canvas) (ox oy opQ : Nat) :
    ∃ l : List Nat, l.length = layer.w * layer.h ∧
      ∀ i, (Canvas.compositeNormal cv layer ox oy opQ).px.getD i 0 ≠ cv.px.getD i 0 → i ∈ l := by
  obtain ⟨l, hlen, hmem⟩ := inRect_count ox oy layer.w layer.h cv.w
  refine ⟨l, hlen, fun i hne =>
    hmem i (Classical.byContradiction fun hn => hne (compositeNormal_local cv layer ox oy opQ i hn))⟩

/-- At most `layer.w * layer.h` pixels change under `compositeBlend`. -/
theorem compositeBlend_count (cv layer : Canvas) (ox oy : Nat) (opacity : F32) (mode : BlendMode) :
    ∃ l : List Nat, l.length = layer.w * layer.h ∧
      ∀ i, (Canvas.compositeBlend cv layer ox oy opacity mode).px.getD i 0 ≠ cv.px.getD i 0 → i ∈ l := by
  obtain ⟨l, hlen, hmem⟩ := inRect_count ox oy layer.w layer.h cv.w
  refine ⟨l, hlen, fun i hne =>
    hmem i (Classical.byContradiction fun hn => hne (compositeBlend_local cv layer ox oy opacity mode i hn))⟩

end LeanSvg

-- Public theorem audit: only standard Lean axioms, never `sorryAx`.
#print axioms LeanSvg.fillMask_local
#print axioms LeanSvg.fillMaskShader_local
#print axioms LeanSvg.compositeNormal_local
#print axioms LeanSvg.compositeBlend_local
#print axioms LeanSvg.fillMask_count
#print axioms LeanSvg.fillMaskShader_count
#print axioms LeanSvg.compositeNormal_count
#print axioms LeanSvg.compositeBlend_count
