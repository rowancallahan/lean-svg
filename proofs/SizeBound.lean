/-
# Output byte-array size bounds

These theorems concern the values returned by `Png.encode` and `render`.
The filesystem, operating system and IO interpreter are outside their scope.

The bound counts copied row bytes once, plus at most five header bytes per
fragment iteration. It needs no assumption about the input RGBA array length:
`copySlice` clamps short sources, and excess source bytes are never copied.

Public bounds:
* `Png.encode`: at most `5 * max(w, h)^2 + 132` bytes, without hypotheses.
* `render`: on success, at most `67452996` bytes under its current limits.

Check with `lake env lean proofs/SizeBound.lean`.
-/
import LeanSvg.Render

/-- The state carried by a `ForInStep`, whichever constructor it used. -/
def ForInStep.val {β : Type} : ForInStep β → β
  | .done b => b
  | .yield b => b

namespace LeanSvg.Png.SizeBound
open LeanSvg Png

/-! Reusable range-loop lemmas from the original proof attempt. The current
encoder proof below instead uses induction on its recursive helpers. -/

/-- **The workhorse.** Any predicate preserved by one step of a loop body
holds of the loop's result. Use this when the invariant relates several
components of the state. -/
theorem forIn_invariant {α β : Type} (P : β → Prop)
    (f : α → β → Id (ForInStep β))
    (hstep : ∀ a b, P b → P (f a b).val) :
    ∀ (l : List α) (init : β), P init → P (Id.run (forIn l init f)) := by
  intro l
  induction l with
  | nil => intro init h; exact h
  | cons a as ih =>
    intro init h
    have h1 := hstep a init h
    simp only [List.forIn_cons]
    cases hf : f a init with
    | done b =>
      simp only [hf, ForInStep.val] at h1
      show P b
      exact h1
    | yield b =>
      simp only [hf, ForInStep.val] at h1
      show P (Id.run (forIn as b f))
      exact ih b h1

/-- The simpler special case: if every step grows a measure by at most `k`,
the loop grows it by at most `k` per element. Useful for loops whose bodies have a flat per-step cost. -/
theorem forIn_measure_le {α β : Type} (sz : β → Nat) (k : Nat)
    (f : α → β → Id (ForInStep β))
    (hstep : ∀ a b, sz (f a b).val ≤ sz b + k) :
    ∀ (l : List α) (init : β),
      sz (Id.run (forIn l init f)) ≤ sz init + l.length * k := by
  intro l
  induction l with
  | nil =>
    intro init
    show sz init ≤ sz init + 0 * k
    omega
  | cons a as ih =>
    intro init
    have h1 := hstep a init
    have h2 := ih
    simp only [List.forIn_cons, List.length_cons, Nat.succ_mul]
    cases hf : f a init with
    | done b =>
      simp only [hf, ForInStep.val] at h1
      show sz b ≤ sz init + (as.length * k + k)
      omega
    | yield b =>
      simp only [hf, ForInStep.val] at h1
      have h3 := h2 b
      show sz (Id.run (forIn as b f)) ≤ sz init + (as.length * k + k)
      omega

/-- Copying `len` bytes into the end of `dest` grows it by at most `len`.

This is where "upper bound only" pays off. `copySlice`'s definition clamps
the copied range with `min len (src.size - srcOff)`, so the exact size
depends on whether `src` is long enough. The inequality does not care. -/
theorem size_copySlice_append_le (src dest : ByteArray) (srcOff len : Nat)
    (ex : Bool) :
    (src.copySlice srcOff dest dest.size len ex).size ≤ dest.size + len := by
  simp only [ByteArray.copySlice, ByteArray.size, Array.size_append,
    Array.size_extract]
  omega

/-- A stored-block header is exactly five bytes: it is five `push`es. -/
theorem size_blockHeader (out : ByteArray) (pos rawSize : Nat) :
    (blockHeader out pos rawSize).size = out.size + 5 := by
  simp only [blockHeader, ByteArray.size_push]

/-! ## The container layer — fully proved

These reduce `encode` to its zlib stream. Everything outside the IDAT payload
is a fixed 57 bytes, so the whole question is how big the stream is.
-/

theorem size_be32 (n : Nat) : (be32 n).size = 4 := by
  simp only [be32, ByteArray.size_push]; rfl

theorem size_chunk (t : String) (d : ByteArray) :
    (chunk t d).size = 8 + t.toUTF8.size + d.size := by
  simp only [chunk, ByteArray.size_append, size_be32]; omega

/-- **Proved.** Whatever bound `C` holds for the zlib stream, `encode` is
within `57 + C`. The 57 is signature 8, IHDR 25, IDAT length 4, IDAT type 4,
IDAT CRC 4 and IEND 12.

This is the half of the problem that does not involve a loop, and it is
done. -/
theorem encode_size_le' (w h : Nat) (rgba : ByteArray) (C : Nat)
    (H : ∀ out : ByteArray, (zlibStoredRows out rgba (w * 4) h).size ≤ out.size + C) :
    (encode w h rgba).size ≤ 57 + C := by
  have hpure : ∀ x : ByteArray, ByteArray.size (pure x : Id ByteArray) = x.size :=
    fun _ => rfl
  simp only [encode, Id.run, hpure, ByteArray.size_append, size_be32, size_chunk]
  have hb := H (ByteArray.emptyWithCapacity (8 + 25 + (12 + zlibLen (w * 4) h) + 12)
      ++ signature ++ chunk "IHDR" (be32 w ++ be32 h ++ ⟨#[8,6,0,0,0]⟩)
      ++ be32 (zlibLen (w * 4) h) ++ "IDAT".toUTF8)
  simp only [ByteArray.size_append, size_be32, size_chunk] at hb
  have e1 : signature.size = 8 := rfl
  have e2 : (ByteArray.emptyWithCapacity (8 + 25 + (12 + zlibLen (w*4) h) + 12)).size = 0 := rfl
  have e3 : "IDAT".toUTF8.size = 4 := rfl
  have e4 : "IHDR".toUTF8.size = 4 := rfl
  have e5 : (⟨#[8,6,0,0,0]⟩ : ByteArray).size = 5 := rfl
  have e6 : "IEND".toUTF8.size = 4 := rfl
  have e7 : ByteArray.empty.size = 0 := rfl
  simp only [e1, e2, e3, e4, e5, e6, e7] at hb ⊢
  omega

/-- Each fragment consumes its requested bytes from the remaining row budget.
Only the five-byte header is charged per iteration. -/
theorem storedPieces_size_le (rgba : ByteArray) (rawSize stop fuel : Nat)
    (out : ByteArray) (pos off : Nat) :
    (storedPieces rgba rawSize stop fuel out pos off).1.size
      ≤ out.size + (stop - off) + 5 * fuel := by
  induction fuel generalizing out pos off with
  | zero => simp only [storedPieces]; omega
  | succ fuel ih =>
    rw [storedPieces]
    split
    · rename_i h
      let o := if pos % 65535 == 0 then blockHeader out pos rawSize else out
      let n := Nat.min (65535 - pos % 65535) (stop - off)
      have ho : o.size ≤ out.size + 5 := by
        dsimp [o]
        split
        · rw [size_blockHeader]; omega
        · omega
      have hn : n ≤ stop - off := Nat.min_le_right _ _
      have hc := size_copySlice_append_le rgba o off n false
      have hi := ih (rgba.copySlice off o o.size n false) (pos + n) (off + n)
      change (storedPieces rgba rawSize stop fuel
        (rgba.copySlice off o o.size n false) (pos + n) (off + n)).1.size ≤ _
      omega
    · simp only []; omega

/-- One row adds its pixel bytes, one filter byte, and conservative header costs. -/
theorem storedRows_size_le (rgba : ByteArray) (rowBytes rawSize pieces fuel y : Nat)
    (out : ByteArray) (pos : Nat) :
    (storedRows rgba rowBytes rawSize pieces fuel y out pos).size
      ≤ out.size + fuel * (rowBytes + 6 + 5 * pieces) := by
  induction fuel generalizing y out pos with
  | zero => simp only [storedRows]; omega
  | succ fuel ih =>
    rw [storedRows]
    let o := if pos % 65535 == 0 then blockHeader out pos rawSize else out
    let row := storedPieces rgba rawSize (y * rowBytes + rowBytes) pieces
      (o.push 0) (pos + 1) (y * rowBytes)
    have ho : o.size ≤ out.size + 5 := by
      dsimp [o]
      split
      · rw [size_blockHeader]; omega
      · omega
    have hr := storedPieces_size_le rgba rawSize (y * rowBytes + rowBytes) pieces
      (o.push 0) (pos + 1) (y * rowBytes)
    have hi := ih (y + 1) row.1 row.2
    change (storedRows rgba rowBytes rawSize pieces fuel (y + 1) row.1 row.2).size ≤ _
    change row.1.size ≤ _ at hr
    simp only [ByteArray.size_push] at hr
    rw [Nat.succ_mul fuel]
    omega

/-- Stream bound, including zlib framing and the possible empty block. -/
theorem zlibStoredRows_size_le (out rgba : ByteArray) (rowBytes h : Nat) :
    (zlibStoredRows out rgba rowBytes h).size
      ≤ out.size + 11 + h * (rowBytes + 16 + 5 * (rowBytes / 65535)) := by
  have hr := storedRows_size_le rgba rowBytes (h * (rowBytes + 1))
    (rowBytes / 65535 + 2) h 0 ((out.push 0x78).push 0x01) 0
  simp only [ByteArray.size_push] at hr
  simp only [zlibStoredRows, ByteArray.size_append, size_be32]
  split
  · rw [size_blockHeader]
    have he : rowBytes + 6 + 5 * (rowBytes / 65535 + 2) =
        rowBytes + 16 + 5 * (rowBytes / 65535) := by omega
    rw [he] at hr
    omega
  · have he : rowBytes + 6 + 5 * (rowBytes / 65535 + 2) =
        rowBytes + 16 + 5 * (rowBytes / 65535) := by omega
    rw [he] at hr
    omega

/-- A rectangular bound with all overhead explicit; valid even for short RGBA input. -/
theorem encode_size_le (w h : Nat) (rgba : ByteArray) :
    (encode w h rgba).size ≤ 68 + h * (4 * w + 16 + 5 * (4 * w / 65535)) := by
  have hb := encode_size_le' w h rgba
    (11 + h * (w * 4 + 16 + 5 * (w * 4 / 65535)))
    (fun out => by have := zlibStoredRows_size_le out rgba (w * 4) h; omega)
  rw [Nat.mul_comm w 4] at hb
  omega

/-- Conservative row accounting fits five bytes per pixel of the enclosing
square, with 64 extra bytes covering the small dimensions. -/
theorem square_budget (n : Nat) :
    n * (4 * n + 16 + 5 * (4 * n / 65535)) ≤ 5 * n * n + 64 := by
  by_cases hn : 16 ≤ n
  · have hc : 4 * n + 16 + 5 * (4 * n / 65535) ≤ 5 * n := by omega
    have hm := Nat.mul_le_mul_left n hc
    have he : n * (5 * n) = 5 * n * n := by ac_rfl
    rw [he] at hm
    omega
  · have hs : n = 0 ∨ n = 1 ∨ n = 2 ∨ n = 3 ∨ n = 4 ∨ n = 5 ∨
        n = 6 ∨ n = 7 ∨ n = 8 ∨ n = 9 ∨ n = 10 ∨ n = 11 ∨
        n = 12 ∨ n = 13 ∨ n = 14 ∨ n = 15 := by omega
    rcases hs with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
      rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide

/-- The public bound: 1.25 times the RGBA bytes of the enclosing square,
plus exactly 132 bytes. No hypotheses on dimensions or RGBA length. -/
theorem encode_size_le_square (w h : Nat) (rgba : ByteArray) :
    (encode w h rgba).size ≤ 5 * (max w h) * (max w h) + 132 := by
  have hb := encode_size_le w h rgba
  have hw : w ≤ max w h := Nat.le_max_left _ _
  have hh : h ≤ max w h := Nat.le_max_right _ _
  have hd : 4 * w / 65535 ≤ 4 * max w h / 65535 := by omega
  have hm := Nat.mul_le_mul hh
    (show 4 * w + 16 + 5 * (4 * w / 65535) ≤
      4 * max w h + 16 + 5 * (4 * max w h / 65535) by omega)
  have hs := square_budget (max w h)
  omega

end LeanSvg.Png.SizeBound

namespace LeanSvg

/-- Every successful render returns a byte array bounded by its checked canvas.
The witnesses are the dimensions passed to the encoder, including for tiles
and parallel renders. No filesystem behavior is part of this statement. -/
theorem render_output_size_bound (opts : Options) (input png : ByteArray)
    (hr : render opts input = .ok png) :
    ∃ w h : Nat, w ≤ maxDim ∧ h ≤ maxDim ∧ w * h ≤ maxPixels ∧
      png.size ≤ 68 + h * (4 * w + 16 + 5 * (4 * w / 65535)) ∧
      png.size ≤ 5 * (max w h) * (max w h) + 132 := by
  unfold render at hr
  simp only [bind, Except.bind, pure, Except.pure] at hr
  cases hp : Xml.parse input with
  | error e => simp [hp] at hr
  | ok events =>
    simp only [hp] at hr
    cases hd : Svg.interpret events with
    | error e => simp [hd] at hr
    | ok doc =>
      simp only [hd] at hr
      -- T52: `render` expands markers (a pure `Doc → Doc` transform that
      -- leaves `root` untouched) between `Svg.interpret` and `canvasSetup`.
      cases hs : Render.canvasSetup (Marker.expand doc).root opts with
      | error e => simp [hs] at hr
      | ok setup =>
        rcases setup with ⟨w, h, mat, clip⟩
        simp only [hs] at hr
        split at hr
        · simp at hr
        · split at hr
          · simp at hr
          · rename_i hdim
            split at hr
            · simp at hr
            · rename_i hpixels
              have hw : w ≤ maxDim := by
                simp only [Bool.or_eq_true, decide_eq_true_eq, not_or] at hdim
                omega
              have hh : h ≤ maxDim := by
                simp only [Bool.or_eq_true, decide_eq_true_eq, not_or] at hdim
                omega
              have ha : w * h ≤ maxPixels := by omega
              split at hr <;> split at hr <;> simp at hr
              all_goals
                subst png
                exact ⟨w, h, hw, hh, ha, Png.SizeBound.encode_size_le w h _,
                  Png.SizeBound.encode_size_le_square w h _⟩

/-- The current dimension and pixel limits imply an explicit universal cap
of 67,452,996 bytes for every successful pure render. -/
theorem render_size_le_const (opts : Options) (input png : ByteArray)
    (hr : render opts input = .ok png) : png.size ≤ 67452996 := by
  obtain ⟨w, h, hw, hh, ha, hb, _⟩ := render_output_size_bound opts input png hr
  simp only [maxDim, maxPixels] at hw hh ha
  have hd : 4 * w / 65535 ≤ 1 := by omega
  have hm := Nat.mul_le_mul_left h (show 4 * w + 16 + 5 * (4 * w / 65535) ≤
    4 * w + 21 by omega)
  have he : h * (4 * w + 21) = 4 * (w * h) + 21 * h := by
    rw [Nat.mul_add]
    ac_rfl
  rw [he] at hm
  omega

end LeanSvg

-- Public theorem audit: only standard Lean axioms, never `sorryAx`.
#print axioms LeanSvg.Png.SizeBound.encode_size_le_square
#print axioms LeanSvg.render_output_size_bound
#print axioms LeanSvg.render_size_le_const
