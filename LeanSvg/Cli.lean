import LeanSvg.Render

/-!
# Command line (pure)

    lean-svg <input.svg> <output.png> [--width N] [--zoom Z] [--background COLOR]
             [--viewport X Y W H] [--threads N] [--warnings]

`parse` turns the argument list into a `Config`; `Main.lean` does the file
system calls with it.  Nothing here runs in `IO`.

Proved below (no `sorry`; `scripts/axiom_audit.py` allows only the standard
three axioms):

* `parse_paths_mem`: the input and output paths are command-line arguments,
  verbatim.
* `parse_paths_ne_empty`: neither path is empty.
* `parse_warnings_iff`: `--warnings` mode is on exactly when `--warnings` is
  one of the arguments.
* `warnPath_ne`: the warnings path is never the output path.

`parse` is a pure function of the argument list, so the render options come
from the arguments and nothing else.

Trusted, not proved: the Lean runtime's `IO` primitives and `main` in
`Main.lean`, which is short enough to read by eye.
-/

namespace LeanSvg
namespace Cli

/-- What `main` needs from the command line. -/
structure Config where
  input : String
  output : String
  options : Options
  /-- `--warnings`: write the warnings text to `warnPath output`. -/
  warnings : Bool

/-- The warnings file of output path `out` (T98): `out` with
`.warnings.txt` appended, so it sits next to the PNG. -/
def warnPath (out : String) : String := out ++ ".warnings.txt"

/-- A decimal integer argument; a leading `-` is allowed. -/
def parseIntArg (s : String) : Option Int :=
  let neg := s.startsWith "-"
  let body := if neg then s.drop 1 else s
  if body.isEmpty || !body.all Char.isDigit then none
  else match body.toNat? with
    | some n => some (if neg then -(n : Int) else (n : Int))
    | none => none

/-- Positional arguments and flags, left to right.  The accumulator is
`none` before the input path, then `(input, output, options)` with output
`""` until the second positional argument.  A flag before the input path, an
unknown flag, a bad flag value or a third positional argument is `none`. -/
def parseArgs : List String → Option (String × String × Options) → Option (String × String × Options)
  | [], acc => acc
  | "--width" :: n :: rest, some (i, o, opts) =>
    match n.toNat? with
    | some w => parseArgs rest (some (i, o, { opts with width := some w }))
    | none => none
  | "--zoom" :: z :: rest, some (i, o, opts) =>
    match parseNumberAll z.toUTF8 with
    | some v => if v > 0 then parseArgs rest (some (i, o, { opts with zoom := some v })) else none
    | none => none
  | "--viewport" :: x :: y :: w :: h :: rest, some (i, o, opts) =>
    match parseIntArg x, parseIntArg y, w.toNat?, h.toNat? with
    | some vx, some vy, some vw, some vh =>
      if vw ≥ 1 && vh ≥ 1 then
        parseArgs rest (some (i, o, { opts with viewport := some (vx, vy, vw, vh) }))
      else none
    | _, _, _, _ => none
  | "--threads" :: n :: rest, some (i, o, opts) =>
    match n.toNat? with
    | some t => parseArgs rest (some (i, o, { opts with threads := t }))
    | none => none
  | "--background" :: c :: rest, some (i, o, opts) =>
    match Svg.parsePaint c.toUTF8 with
    | some (.solid col) => parseArgs rest (some (i, o, { opts with background := some col }))
    | _ => none
  | a :: rest, acc =>
    if a.startsWith "--" then none
    else match acc with
      | none => parseArgs rest (some (a, "", {}))
      | some (i, "", opts) => parseArgs rest (some (i, a, opts))
      | some _ => none

/-- `--warnings` may appear anywhere and is removed before `parseArgs` sees
the rest.  Both paths must be non-empty (an empty input path used to reach
`readBinFile ""` and fail there; the exit code, 1, is the same). -/
def parse (args : List String) : Option Config :=
  match parseArgs (args.filter (· != "--warnings")) none with
  | some (input, output, options) =>
    if input == "" || output == "" then none
    else some { input, output, options, warnings := args.contains "--warnings" }
  | none => none

/-! ## Theorems -/

/-- The warnings path is never the output path itself (it is 13 bytes longer). -/
theorem warnPath_ne (out : String) : warnPath out ≠ out := by
  intro h
  have := congrArg (fun s : String => s.toByteArray.data.toList.length) h
  -- `String.append` and `ByteArray.append` are list concatenation underneath;
  -- going through the list keeps this at `[propext]` (the library's
  -- `String.length_append` would add `Classical.choice`).
  have e : (warnPath out).toByteArray.data.toList =
      out.toByteArray.data.toList ++ (".warnings.txt" : String).toByteArray.data.toList := rfl
  simp only [e, List.length_append] at this
  have h13 : (".warnings.txt" : String).toByteArray.data.toList.length = 13 := rfl
  rw [h13] at this
  exact absurd (Nat.add_left_cancel (this.trans (Nat.add_zero _).symm)) (by decide)

/-- Every path `parseArgs` returns is `""` or one of the arguments `L`,
provided the list it reads and the accumulator it starts from are. -/
theorem parseArgs_mem (L : List String) :
    ∀ (l : List String) (acc : Option (String × String × Options)) (i o : String) (opts : Options),
    (∀ a ∈ l, a ∈ L) →
    (∀ i' o' opts', acc = some (i', o', opts') → i' ∈ L ∧ (o' = "" ∨ o' ∈ L)) →
    parseArgs l acc = some (i, o, opts) → i ∈ L ∧ (o = "" ∨ o ∈ L) := by
  intro l acc
  induction l, acc using parseArgs.induct <;> intro i o opts hl hacc h
  -- `--zoom` with a value ≤ 0, and an unknown flag: both return `none`.
  case case5 hv hneg => simp only [parseArgs, hv, hneg, ite_false] at h; simp at h
  case case14 => unfold parseArgs at h; split at h <;> grind
  all_goals simp_all [parseArgs]

/-- What `parse` returned, unfolded. -/
theorem parse_some {args : List String} {c : Config} (h : parse args = some c) :
    (∃ opts, parseArgs (args.filter (· != "--warnings")) none = some (c.input, c.output, opts)) ∧
    c.input ≠ "" ∧ c.output ≠ "" ∧ c.warnings = args.contains "--warnings" := by
  unfold parse at h
  split at h
  · split at h
    · simp at h
    · simp only [Option.some.injEq] at h
      subst h
      simp_all
  · simp at h

/-- Both paths are command-line arguments, verbatim. -/
theorem parse_paths_mem {args : List String} {c : Config} (h : parse args = some c) :
    c.input ∈ args ∧ c.output ∈ args := by
  obtain ⟨⟨opts, hp⟩, -, ho, -⟩ := parse_some h
  have := parseArgs_mem (args.filter (· != "--warnings")) _ none _ _ _ (fun _ h => h) (by simp) hp
  simp_all

/-- Neither path is empty. -/
theorem parse_paths_ne_empty {args : List String} {c : Config} (h : parse args = some c) :
    c.input ≠ "" ∧ c.output ≠ "" :=
  ⟨(parse_some h).2.1, (parse_some h).2.2.1⟩

/-- `--warnings` mode is on exactly when `--warnings` is one of the arguments. -/
theorem parse_warnings_iff {args : List String} {c : Config} (h : parse args = some c) :
    c.warnings = true ↔ "--warnings" ∈ args := by
  simp [(parse_some h).2.2.2]

end Cli
end LeanSvg
