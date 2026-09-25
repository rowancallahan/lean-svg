/-
# The command line (`LeanSvg.Cli`)

`parse` turns the argument list into a `Config`; `Main.lean` does the file
system calls with it. Proved here: the input and output paths are
command-line arguments, verbatim, and non-empty; `--warnings` mode is on
exactly when `--warnings` is an argument; the warnings path is never the
output path. `parse` is a pure function of the argument list, so the render
options come from the arguments and nothing else.

Check with `lake env lean spec/Cli.lean`.
-/
import LeanSvg.Cli

namespace LeanSvg
namespace Cli

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
