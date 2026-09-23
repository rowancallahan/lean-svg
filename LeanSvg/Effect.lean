/-!
# Effect confinement

`Prog` is the *only* monad the renderer's top-level program lives in.  It is a
free monad over exactly three operations: read the input file, check whether
the output path already exists, and write the output file.  There is no
constructor for anything else, so a value of type `Prog α` cannot open
sockets, spawn processes, read the environment, or touch any other file.
This is enforced by the type checker, not by review.

The theorems below are stated against a model file system (`FS`, a total map
from paths to *optional* contents — `none` means the path is absent) and are
checked by the Lean kernel:

* `runFS_frame`         : no path other than the output path is ever modified.
* `runFS_input_only`    : the program's result depends only on the input
                          path's contents and on whether the output path is
                          present.
* `renderProgram_spec`  : the renderer program either fails (and the file
                          system is untouched) or writes exactly the bytes
                          produced by the pure `render` function to the output
                          path — and it fails without touching anything if the
                          output path already exists.
* `renderProgram_no_clobber` : if the output path already holds something,
                          running the program changes nothing at all.

The one trusted piece is `Prog.execIO`, the interpreter that maps the three
operations onto real `IO` calls.  It is a handful of lines long.  Everything
else in the renderer is a pure function of a `ByteArray`.
-/

namespace LeanSvg

/-- The complete set of effects available to a renderer program. -/
inductive Op where
  | readInput
  | outputExists
  | writeOutput (bytes : ByteArray)

/-- The value each operation returns. -/
abbrev Op.Res : Op → Type
  | .readInput => ByteArray
  | .outputExists => Bool
  | .writeOutput _ => Unit

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
def writeOutput (b : ByteArray) : Prog Unit := .step (.writeOutput b) .pure

/-! ## Model semantics -/

/-- A model file system: every path maps to its contents, or `none` if the
path is absent. -/
abbrev FS := String → Option ByteArray

/-- Overwrite one path in the model file system with concrete contents. -/
def FS.write (fs : FS) (p : String) (b : ByteArray) : FS :=
  fun q => if q = p then some b else fs q

/-- Run a program against the model, reading from `inp` and writing to `out`.
A missing input path reads as empty; a real `execIO` read of a missing file
raises an `IO` error outside this model instead, which is unchanged from
before this file's model gained `Option`. -/
def runFS (inp out : String) : Prog α → FS → α × FS
  | .pure a, fs => (a, fs)
  | .step .readInput k, fs => runFS inp out (k ((fs inp).getD ByteArray.empty)) fs
  | .step .outputExists k, fs => runFS inp out (k (fs out).isSome) fs
  | .step (.writeOutput b) k, fs => runFS inp out (k ()) (fs.write out b)

/-- **Frame theorem.** Running any program leaves every path other than `out` unchanged. -/
theorem runFS_frame (inp out : String) (p : Prog α) (fs : FS) (q : String) (hq : q ≠ out) :
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
    | writeOutput b =>
      simp only [runFS]
      rw [ih () (fs.write out b)]
      simp [FS.write, hq]

/-- **Input-only theorem, generalised.** The result of any program depends
only on the contents of `inp` and on whether `out` is present — not on what
`out` holds, since the program can query only that. So a program cannot
secretly read anything else, and cannot even distinguish two output paths
that are either both present or both absent. -/
theorem runFS_input_only (inp out : String) (p : Prog α) (fs fs' : FS)
    (hin : fs inp = fs' inp) (hout : (fs out).isSome = (fs' out).isSome) :
    (runFS inp out p fs).1 = (runFS inp out p fs').1 := by
  induction p generalizing fs fs' with
  | pure a => rfl
  | step op k ih =>
    cases op with
    | readInput =>
      simp only [runFS]
      rw [hin]
      exact ih _ _ _ hin hout
    | outputExists =>
      simp only [runFS]
      rw [hout]
      exact ih _ _ _ hin hout
    | writeOutput b =>
      simp only [runFS]
      apply ih
      · simp only [FS.write]; split <;> simp [*]
      · simp [FS.write]

/-! ## The renderer program -/

/-- The whole top-level program: read the input, refuse if the output path
already exists, otherwise run a pure `render` and either write the result or
report its error.  Nothing else. -/
def renderProgram {ε : Type} (clobberError : ε) (render : ByteArray → Except ε ByteArray) :
    Prog (Except ε Unit) :=
  .step .readInput fun inp =>
    .step .outputExists fun outExists =>
      if outExists then
        .pure (.error clobberError)
      else
        match render inp with
        | .ok png => .step (.writeOutput png) fun _ => .pure (.ok ())
        | .error e => .pure (.error e)

/-- **Specification of the renderer program.**  On the model file system: if
the output path already exists, nothing happens and the program reports
`clobberError`. Otherwise it either fails and changes nothing, or succeeds
and writes exactly `render input` to `out`. -/
theorem renderProgram_spec {ε : Type} (clobberError : ε) (render : ByteArray → Except ε ByteArray)
    (inp out : String) (fs : FS) :
    runFS inp out (renderProgram clobberError render) fs =
      if (fs out).isSome then
        (.error clobberError, fs)
      else
        match render ((fs inp).getD ByteArray.empty) with
        | .ok png => (.ok (), fs.write out png)
        | .error e => (.error e, fs) := by
  unfold renderProgram
  simp only [runFS]
  split
  · rfl
  · cases h : render ((fs inp).getD ByteArray.empty) with
    | ok png => simp only [runFS]
    | error e => simp only [runFS]

/-- **No-clobber.** If the output path already holds something when the
program starts, running it changes the file system not at all — not merely
the frame theorem's "every path but `out`", but literally nothing, because
the program refuses before doing anything else. -/
theorem renderProgram_no_clobber {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε ByteArray) (inp out : String) (fs : FS) (b : ByteArray)
    (h : fs out = some b) :
    (runFS inp out (renderProgram clobberError render) fs).2 = fs := by
  rw [renderProgram_spec]
  simp [h]

/-- On error — including the no-clobber refusal — the file system is
untouched: no output file is created or modified. -/
theorem renderProgram_error_no_write {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε ByteArray) (inp out : String) (fs : FS) (e : ε)
    (hout : fs out = none) (h : render ((fs inp).getD ByteArray.empty) = .error e) :
    (runFS inp out (renderProgram clobberError render) fs).2 = fs := by
  rw [renderProgram_spec]
  simp [hout, h]

/-- On success, the output path holds exactly the rendered bytes. The output
path cannot already have existed: no-clobber means a success only happens
when `render` is actually invoked, which only happens when `fs out = none`. -/
theorem renderProgram_ok_output {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε ByteArray) (inp out : String) (fs : FS) (png : ByteArray)
    (hout : fs out = none) (h : render ((fs inp).getD ByteArray.empty) = .ok png) :
    (runFS inp out (renderProgram clobberError render) fs).2 out = some png := by
  rw [renderProgram_spec]
  simp [hout, h, FS.write]

/-- On success, every path other than the output path is untouched. -/
theorem renderProgram_ok_frame {ε : Type} (clobberError : ε)
    (render : ByteArray → Except ε ByteArray) (inp out : String) (fs : FS) (q : String)
    (hq : q ≠ out) :
    (runFS inp out (renderProgram clobberError render) fs).2 q = fs q :=
  runFS_frame inp out _ fs q hq

/-! ## The trusted interpreter -/

/-- The only place real I/O happens.  Maps the three operations to file
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
  | .step (.writeOutput b) k => do
    IO.FS.writeBinFile out b
    execIO inp out (k ())

end Prog
end LeanSvg
