/-
# Output size upper bound — working file

## STATUS: NOT PROVED. DO NOT CITE THIS AS A GUARANTEE.

**One hole remains: `zlibStoredRows_size_le`.** It is `sorry`, reports
`sorryAx` and establishes nothing. `encode_size_le` and
`encode_size_le_const` are now *derived* from it rather than being separate
holes, so they inherit that one `sorryAx` and nothing else.

Proved and hole-free: `forIn_invariant`, `forIn_measure_le`,
`size_copySlice_append_le`, `size_blockHeader`, `size_be32`, `size_chunk`,
and `encode_size_le'` — the whole PNG container layer, which is the half of
the problem with no loop in it. These report `[propext, Quot.sound]`, or
`[propext]` where no list or array lemma is used. `Quot.sound` is one of
Lean's three standard axioms and arrives from core's `List.forIn_cons` and
`Array.size_append`; it is not a hole.

Check for yourself:

    lake env lean proofs/SizeBound.lean          -- expect exactly 1 sorry warning

The statements below also need reading by a human against what they ought to
say. A correct proof of the wrong statement is worth nothing, and the bound
here was already wrong once in a way the kernel would never have caught: an
earlier version claimed `6 * raw`, which is true but six times looser than
the encoder deserves. See "The bound" below.

## Scope

The theorems are about the `ByteArray` that `Png.encode` returns. They say
nothing about the file on disk. What the operating system does with those
bytes is outside the model, and deliberately so.

Not part of the `LeanSvg` library, so `lake build` does not see it and the
`sorry` below does not break invariant 5. Check it with:

    lake env lean proofs/SizeBound.lean

## What is being proved, in English

The renderer cannot produce an arbitrarily large file. The size of the PNG it
writes is bounded by a function of the canvas dimensions alone, and the
canvas dimensions are already checked at runtime. So a bounded input cannot
turn into an unbounded output.

Only the **upper bound** is wanted, not the exact size. That decision makes
this much easier, in two specific ways that are worth naming:

1. `ByteArray.copySlice` clamps its length with `min` against the source's
   size. For an exact size you would have to prove `rgba` is long enough,
   which means carrying the canvas-size invariant all the way down. For a
   bound the `min` is free — it only ever helps.
2. The number of stored DEFLATE blocks is `⌈raw/65535⌉`, and an exact size
   has to get that count right. The bound below still has to count them, but
   only up to the slack the invariant already carries, which is easier.

**The bound must stay tight, and an earlier draft of this file did not.** It
charged each 5-byte block header against a *single* data byte rather than
against the 65535 bytes a block actually covers, giving `6 * raw`. That 6x
was an artifact of the proof, not of the encoder. The encoder writes each
pixel exactly once — four bytes per pixel, plus one filter byte per row —
which is the tautological minimum for an uncompressed still image. A bound
that exceeds it by a constant factor is measuring the proof, not the code.

## The bound

`zlibStoredRows` appends, to `out`:

  - 2 bytes of zlib header,
  - one byte per byte of `raw = h * (rowBytes + 1) = 4*w*h + h`, which is
    every pixel once plus one filter byte per row,
  - 5 bytes per stored-block header, and there are `⌊raw/65535⌋ + 1` of them,
  - 5 more if `raw = 0`, for the empty-stream block,
  - 4 bytes of Adler-32.

so at most `out.size + 16 + raw + 5 * (raw / 65535)`. Wrapping that in the
PNG container adds 8 signature, 25 IHDR, 4 IDAT length, 4 IDAT type, 4 IDAT
CRC and 12 IEND, which is 57. Total `73 + raw + 5 * (raw / 65535)`, where the
division term is under 0.008% of `raw`.

There is no animation case to exclude. The encoder emits a single IDAT
stream for one static frame; it has no APNG path, so nothing here can repeat
a pixel across frames.

## Empirical check

Rendering `tests/svg/12_badge.svg` at 800x800 gives, in bytes:

  | quantity                        | value     |
  |---------------------------------|-----------|
  | `raw` (every pixel once + filter) | 2 560 800 |
  | actual file                     | 2 561 063 |
  | bound above                      | 2 561 068 |

Five bytes of slack. The 263 bytes between `raw` and the actual file are 57
of container framing, 2 of zlib header, 4 of Adler-32 and forty 5-byte block
headers. A bound that is not within a hair of `raw` is a broken bound.

## Status

The four supporting lemmas below are **proved**. The final assembly is not —
see the note on `encode_size_le` for exactly what is left and why.
-/

import LeanSvg.Png

/-- The state carried by a `ForInStep`, whichever constructor it used. -/
def ForInStep.val {β : Type} : ForInStep β → β
  | .done b => b
  | .yield b => b

namespace LeanSvg.Png.SizeBound

open LeanSvg Png

/-! ## Generic loop reasoning

Lean has no automation for `for` loops over ranges, so these two lemmas are
the reusable core. Both reduce a loop to a single obligation about its body.
They are stated over `List` because `Std.Legacy.Range.forIn_eq_forIn_range'`
rewrites a range loop into a list loop.
-/

/-- **The workhorse.** Any predicate preserved by one step of a loop body
holds of the loop's result. Use this when the invariant relates several
components of the state, which is the case here: the bound on `o.size`
depends on `pos`. -/
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
the loop grows it by at most `k` per element. Not strong enough for
`zlibStoredRows`, where the useful invariant ties size to position, but it is
the right tool for a loop whose body has a flat per-step cost. -/
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

/-! ## Leaf lemmas about the two writing primitives -/

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

/-! ## The target -/

/-- `zlibStoredRows` appends at most `11 + 6 * raw` bytes, where
`raw = h * (rowBytes + 1)` is the filtered-scanline size.

**Not proved yet.** The invariant to feed `forIn_invariant` is

  `P (o, pos) := o.size ≤ base + 2 + pos + 5 * (pos / 65535 + 1) ∧ pos ≤ raw`

for the outer loop, and the same with the inner loop's three-component state
`(o, pos, off)`. The `5 * (pos / 65535 + 1)` term is what keeps the bound
tight, and it is preserved because the slack arrives exactly when it is
needed:

  - A data byte grows `o.size` by 1 and `pos` by 1, and the bound grows by 1.
  - A header is emitted only when `pos % 65535 = 0`. Just before it, `k`
    headers have been written and `pos / 65535 = k`, so the bound allows
    `5 * (k + 1)` against an actual `5 * k` — exactly 5 bytes of slack, which
    the header consumes.
  - Between headers `pos / 65535` is constant, so the slack is not
    replenished until `pos` reaches the next multiple, which is precisely
    when the next header is due.
  - A `copySlice` of `n` bytes advances `pos` by the same `n`
    (`size_copySlice_append_le`), so it is the data-byte case `n` times.

**The obstacle is not the mathematics, it is the term.** Unfolding
`zlibStoredRows` shows that do-notation destructuring duplicates the entire
inner `forIn` expression — once to project `.fst` and once for `.snd` — so
the outer loop's body contains two copies of a large term that have to be
kept in sync through the proof.

`PLAN.md` already recommends rewriting `zlibStoredRows` as explicit recursion
with `termination_by` before proving anything about it. Having now seen the
goal, that recommendation is right and this is the concrete reason for it.
That rewrite is behaviour-preserving but must be checked byte-identical
against the corpus, so it is a task in its own right rather than something to
fold into this file. -/
theorem zlibStoredRows_size_le (out rgba : ByteArray) (rowBytes h : Nat) :
    (zlibStoredRows out rgba rowBytes h).size
      ≤ out.size + 16 + h * (rowBytes + 1)
          + 5 * (h * (rowBytes + 1) / 65535) := by
  sorry

/-- The `ByteArray` that `encode` returns is bounded by a function of the
canvas dimensions: 73 bytes of fixed overhead, plus `raw = 4*w*h + h` for the
pixels themselves, plus one 5-byte block header per 65535 bytes.

This is the statement that should look tautological, and does: `raw` is every
pixel written exactly once, and everything else is sub-percent.

**This is about the returned `ByteArray`, not about a file.** What the
operating system does with those bytes is outside the model.

No longer an independent hole: it now derives from `encode_size_le'` (proved)
and `zlibStoredRows_size_le` (the one remaining `sorry`). -/
theorem encode_size_le (w h : Nat) (rgba : ByteArray) :
    (encode w h rgba).size
      ≤ 73 + h * (w * 4 + 1) + 5 * (h * (w * 4 + 1) / 65535) := by
  have := encode_size_le' w h rgba
      (16 + h * (w * 4 + 1) + 5 * (h * (w * 4 + 1) / 65535))
      (fun out => by have := zlibStoredRows_size_le out rgba (w * 4) h; omega)
  omega

/-- What the bound is for. `render` already rejects `w` or `h` above `maxDim`
and `w * h` above `maxPixels` at runtime, and the bound above is monotone in
both, so the output size is capped by a constant. This is the statement that
answers "no arbitrary image size"; it needs only `encode_size_le` plus
monotonicity, both of which are arithmetic. -/
theorem encode_size_le_const (w h : Nat) (rgba : ByteArray)
    (maxDim : Nat) (hw : w ≤ maxDim) (hh : h ≤ maxDim) :
    (encode w h rgba).size
      ≤ 73 + maxDim * (maxDim * 4 + 1)
          + 5 * (maxDim * (maxDim * 4 + 1) / 65535) := by
  have hb := encode_size_le w h rgba
  have hmono : h * (w * 4 + 1) ≤ maxDim * (maxDim * 4 + 1) :=
    Nat.mul_le_mul hh (by omega)
  have hdiv : h * (w * 4 + 1) / 65535 ≤ maxDim * (maxDim * 4 + 1) / 65535 :=
    Nat.div_le_div_right hmono
  omega

end LeanSvg.Png.SizeBound
