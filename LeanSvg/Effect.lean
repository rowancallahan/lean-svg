/-!
# Effect confinement

`Prog` is the *only* monad the renderer's top-level program lives in.  It is a
free monad over exactly five operations: read the input file, check whether
the output path or the warnings path (`warnPath`, the output path plus
`.warnings.txt`, T98) already exists, and write the output file or the
warnings file.  There is no constructor for anything else, so a value of type
`Prog α` cannot open sockets, spawn processes, read the environment, or touch
any other file.  This is enforced by the type checker, not by review.

The theorems below are stated against a model file system (`FS`, a total map
from paths to *optional* contents — `none` means the path is absent) and are
checked by the Lean kernel:

* `runFS_frame`         : no path other than the output and warnings paths is
                          ever modified.
* `runFS_input_only`    : the program's result depends only on the input
                          path's contents and on whether the output and
                          warnings paths are present.
* `renderProgram_spec`  : the renderer program either fails (and the file
                          system is untouched) or writes exactly the PNG bytes
                          produced by the pure `render` function to the output
                          path and, when that same call produced a non-empty
                          warnings text, exactly that text to the warnings
                          path — and it fails without touching anything if
                          either path already exists.
* `renderProgram_no_clobber`, `renderProgram_no_clobber_warnings` : if the
                          output or the warnings path already holds something,
                          running the program changes nothing at all.
* `renderProgram_never_overwrites` : every path the program changes was
                          absent before it ran.

The one trusted piece is `Prog.execIO`, the interpreter that maps the five
operations onto real `IO` calls.  It is a handful of lines long.  Everything
else in the renderer is a pure function of a `ByteArray`.
-/

namespace LeanSvg

/-- The complete set of effects available to a renderer program. -/
inductive Op where
  | readInput
  | outputExists
  | warningsExists
  | writeOutput (bytes : ByteArray)
  | writeWarnings (bytes : ByteArray)

/-- The value each operation returns. -/
abbrev Op.Res : Op → Type
  | .readInput => ByteArray
  | .outputExists => Bool
  | .warningsExists => Bool
  | .writeOutput _ => Unit
  | .writeWarnings _ => Unit

/-- Free monad over `Op`.  A `Prog α` is a finite tree of operations ending in
a pure result. -/
inductive Prog (α : Type) : Type where
  | pure : α → Prog α
  | step : (op : Op) → (Op.Res op → Prog α) → Prog α

namespace Prog

def bind : Prog α → (α → Prog β) → Prog β
  | .pure a, f => f a
  | .step op k, f => .step op fun r => bind (k r) f

instance : Monad Prog where
  pure := Prog.pure
  bind := Prog.bind

def readInput : Prog ByteArray := .step .readInput .pure
def outputExists : Prog Bool := .step .outputExists .pure
def warningsExists : Prog Bool := .step .warningsExists .pure
def writeOutput (b : ByteArray) : Prog Unit := .step (.writeOutput b) .pure
def writeWarnings (b : ByteArray) : Prog Unit := .step (.writeWarnings b) .pure

/-- The warnings file of output path `out` (T98): `out` with
`.warnings.txt` appended, so it sits next to the PNG. -/
def warnPath (out : String) : String := out ++ ".warnings.txt"

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

/-! ## Model semantics -/

/-- A model file system: every path maps to its contents, or `none` if the
path is absent. -/
abbrev FS := String → Option ByteArray

/-- Overwrite one path in the model file system with concrete contents. -/
def FS.write (fs : FS) (p : String) (b : ByteArray) : FS :=
  fun q => if q = p then some b else fs q

/-- Run a program against the model, reading from `inp` and writing to `out`
and `warnPath out`.  A missing input path reads as empty; a real `execIO` read
of a missing file raises an `IO` error outside this model instead, which is
unchanged from before this file's model gained `Option`. -/
def runFS (inp out : String) : Prog α → FS → α × FS
  | .pure a, fs => (a, fs)
  | .step .readInput k, fs => runFS inp out (k ((fs inp).getD ByteArray.empty)) fs
  | .step .outputExists k, fs => runFS inp out (k (fs out).isSome) fs
  | .step .warningsExists k, fs => runFS inp out (k (fs (warnPath out)).isSome) fs
  | .step (.writeOutput b) k, fs => runFS inp out (k ()) (fs.write out b)
  | .step (.writeWarnings b) k, fs => runFS inp out (k ()) (fs.write (warnPath out) b)

/-- **Frame theorem.** Running any program leaves every path other than `out`
and `warnPath out` unchanged. -/
theorem runFS_frame (inp out : String) (p : Prog α) (fs : FS) (q : String) (hq : q ≠ out)
    (hw : q ≠ warnPath out) :
    (runFS inp out p fs).2 q = fs q := by
  induction p generalizing fs with
  | pure a => rfl
  | step op k ih =>
    cases op with
    | readInput =>
      simp only [runFS]
      exact ih _ _
    | outputExists =>
      simp only [runFS]
      exact ih _ _
    | warningsExists =>
      simp only [runFS]
      exact ih _ _
    | writeOutput b =>
      simp only [runFS]
      rw [ih () (fs.write out b)]
      simp [FS.write, hq]
    | writeWarnings b =>
      simp only [runFS]
      rw [ih () (fs.write (warnPath out) b)]
      simp [FS.write, hw]

/-- **Input-only theorem, generalised.** The result of any program depends
only on the contents of `inp` and on whether `out` and `warnPath out` are
present — not on what they hold, since the program can query only that. So a
program cannot secretly read anything else, and cannot even distinguish two
file systems that agree on the input and on which of the two output paths
exist. -/
theorem runFS_input_only (inp out : String) (p : Prog α) (fs fs' : FS)
    (hin : fs inp = fs' inp) (hout : (fs out).isSome = (fs' out).isSome)
    (hwout : (fs (warnPath out)).isSome = (fs' (warnPath out)).isSome) :
    (runFS inp out p fs).1 = (runFS inp out p fs').1 := by
  induction p generalizing fs fs' with
  | pure a => rfl
  | step op k ih =>
    cases op with
    | readInput =>
      simp only [runFS]
      rw [hin]
      exact ih _ _ _ hin hout hwout
    | outputExists =>
      simp only [runFS]
      rw [hout]
      exact ih _ _ _ hin hout hwout
    | warningsExists =>
      simp only [runFS]
      rw [hwout]
      exact ih _ _ _ hin hout hwout
    | writeOutput b =>
      simp only [runFS]
      apply ih
      · simp only [FS.write]; split <;> simp [*]
      · simp [FS.write]
      · simp only [FS.write]; split <;> simp [*]
    | writeWarnings b =>
      simp only [runFS]
      apply ih
      · simp only [FS.write]; split <;> simp [*]
      · simp only [FS.write]; split <;> simp [*]
      · simp [FS.write]

/-! ## The renderer program -/

/-- The whole top-level program: read the input, refuse if the output path or
the warnings path already exists, otherwise run a pure `render` and either
write its PNG (and its warnings text, when non-empty) or report its error.
Returns whether a warnings file was written.  Nothing else. -/
def renderProgram {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) : Prog (Except ε Bool) :=
  .step .readInput fun inp =>
    .step .outputExists fun outExists =>
      .step .warningsExists fun warnExists =>
        if outExists || warnExists then
          .pure (.error clobberError)
        else
          match render inp with
          | .ok (png, warn) =>
            .step (.writeOutput png) fun _ =>
              if warn.size = 0 then .pure (.ok false)
              else .step (.writeWarnings warn) fun _ => .pure (.ok true)
          | .error e => .pure (.error e)

/-- **Specification of the renderer program.**  On the model file system: if
the output path or the warnings path already exists, nothing happens and the
program reports `clobberError`. Otherwise it either fails and changes nothing,
or succeeds and writes exactly the PNG of `render input` to `out` and, when
its warnings text is non-empty, exactly that text to `warnPath out`. -/
theorem renderProgram_spec {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) (inp out : String) (fs : FS) :
    runFS inp out (renderProgram clobberError render) fs =
      if (fs out).isSome || (fs (warnPath out)).isSome then
        (.error clobberError, fs)
      else
        match render ((fs inp).getD ByteArray.empty) with
        | .ok (png, warn) =>
          if warn.size = 0 then (.ok false, fs.write out png)
          else (.ok true, (fs.write out png).write (warnPath out) warn)
        | .error e => (.error e, fs) := by
  unfold renderProgram
  simp only [runFS]
  split
  · rfl
  · cases h : render ((fs inp).getD ByteArray.empty) with
    | ok r =>
      obtain ⟨png, warn⟩ := r
      simp only [runFS]
      split <;> simp only [runFS]
    | error e => simp only [runFS]

/-- **No-clobber.** If the output path already holds something when the
program starts, running it changes the file system not at all — not merely
the frame theorem's "every path but `out`", but literally nothing, because
the program refuses before doing anything else. -/
theorem renderProgram_no_clobber {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) (inp out : String) (fs : FS)
    (b : ByteArray) (h : fs out = some b) :
    (runFS inp out (renderProgram clobberError render) fs).2 = fs := by
  rw [renderProgram_spec]
  simp [h]

/-- **No-clobber for the warnings file.** Likewise if the warnings path
already holds something — even when this render would produce no warnings, so
a stale warnings file is never left next to a fresh PNG. -/
theorem renderProgram_no_clobber_warnings {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) (inp out : String) (fs : FS)
    (b : ByteArray) (h : fs (warnPath out) = some b) :
    (runFS inp out (renderProgram clobberError render) fs).2 = fs := by
  rw [renderProgram_spec]
  simp [h]

/-- On error — including the no-clobber refusal — the file system is
untouched: no output file is created or modified. -/
theorem renderProgram_error_no_write {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) (inp out : String) (fs : FS) (e : ε)
    (_hout : fs out = none) (h : render ((fs inp).getD ByteArray.empty) = .error e) :
    (runFS inp out (renderProgram clobberError render) fs).2 = fs := by
  rw [renderProgram_spec]
  split
  · rfl
  · simp [h]

/-- On success, the output path holds exactly the rendered bytes. Neither the
output path nor the warnings path can already have existed: no-clobber means
a success only happens when `render` is actually invoked, which only happens
when both are absent. -/
theorem renderProgram_ok_output {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) (inp out : String) (fs : FS)
    (png warn : ByteArray) (hout : fs out = none) (hwout : fs (warnPath out) = none)
    (h : render ((fs inp).getD ByteArray.empty) = .ok (png, warn)) :
    (runFS inp out (renderProgram clobberError render) fs).2 out = some png := by
  have hne := warnPath_ne out
  rw [renderProgram_spec]
  simp only [hout, hwout, h, Option.isSome_none, Bool.or_self, Bool.false_eq_true, ite_false]
  split <;> simp [FS.write, Ne.symm hne]

/-- On success with a non-empty warnings text, the warnings path holds exactly
that text. -/
theorem renderProgram_ok_warnings {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) (inp out : String) (fs : FS)
    (png warn : ByteArray) (hout : fs out = none) (hwout : fs (warnPath out) = none)
    (h : render ((fs inp).getD ByteArray.empty) = .ok (png, warn)) (hw : warn.size ≠ 0) :
    (runFS inp out (renderProgram clobberError render) fs).2 (warnPath out) = some warn := by
  rw [renderProgram_spec]
  simp [hout, hwout, h, hw, FS.write]

/-- On success with no warnings, no warnings file is created. -/
theorem renderProgram_ok_no_warnings {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) (inp out : String) (fs : FS)
    (png warn : ByteArray) (hwout : fs (warnPath out) = none)
    (h : render ((fs inp).getD ByteArray.empty) = .ok (png, warn)) (hw : warn.size = 0) :
    (runFS inp out (renderProgram clobberError render) fs).2 (warnPath out) = none := by
  have hne := warnPath_ne out
  rw [renderProgram_spec]
  split
  · exact hwout
  · simp [h, hw, FS.write, hne, hwout]

/-- On success, every path other than the output and warnings paths is untouched. -/
theorem renderProgram_ok_frame {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) (inp out : String) (fs : FS)
    (q : String) (hq : q ≠ out) (hw : q ≠ warnPath out) :
    (runFS inp out (renderProgram clobberError render) fs).2 q = fs q :=
  runFS_frame inp out _ fs q hq hw

/-- **Never overwrites.** Every path whose contents the program changes was
absent when it started: it only ever creates files. -/
theorem renderProgram_never_overwrites {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε (ByteArray × ByteArray)) (inp out : String) (fs : FS)
    (q : String) (hq : (runFS inp out (renderProgram clobberError render) fs).2 q ≠ fs q) :
    fs q = none := by
  rw [renderProgram_spec] at hq
  split at hq
  · exact absurd rfl hq
  · rename_i hfree
    simp only [Bool.or_eq_true, not_or, Bool.not_eq_true, Option.isSome_eq_false_iff,
      Option.isNone_iff_eq_none] at hfree
    split at hq
    · split at hq
      · simp only [FS.write] at hq
        split at hq
        · subst q; exact hfree.1
        · exact absurd rfl hq
      · simp only [FS.write] at hq
        split at hq
        · subst q; exact hfree.2
        · split at hq
          · subst q; exact hfree.1
          · exact absurd rfl hq
    · exact absurd rfl hq

/-! ## The trusted interpreter -/

/-- The warnings file next to the output file `out`: `warnPath` on its path. -/
def warnFile (out : System.FilePath) : System.FilePath := ⟨warnPath out.toString⟩

/-- The only place real I/O happens.  Maps the five operations to file
existence checks, reads and writes on the given paths.  This is the trusted
computing base of the effect layer. -/
def execIO (inp out : System.FilePath) : Prog α → IO α
  | .pure a => Pure.pure a
  | .step .readInput k => do
    let b ← IO.FS.readBinFile inp
    execIO inp out (k b)
  | .step .outputExists k => do
    let e ← out.pathExists
    execIO inp out (k e)
  | .step .warningsExists k => do
    let e ← (warnFile out).pathExists
    execIO inp out (k e)
  | .step (.writeOutput b) k => do
    -- `writeNew` creates exclusively (O_EXCL): a file that appeared after the
    -- `outputExists` check makes this fail rather than be overwritten.
    IO.FS.withFile out .writeNew (·.write b)
    execIO inp out (k ())
  | .step (.writeWarnings b) k => do
    -- Same exclusive create as `writeOutput`, against `warningsExists`.
    IO.FS.withFile (warnFile out) .writeNew (·.write b)
    execIO inp out (k ())

end Prog
end LeanSvg
